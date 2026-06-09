# frozen_string_literal: true

# Array#filter_map (used in Recovery#extract_payloads) is Ruby 2.7+; on Ruby < 2.7
# activate the scoped refinement backport (no-op on 2.7+, which uses native filter_map).
using SmarterJSON::Backports if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("2.7")

module SmarterJSON
  # ParseError / EncodingError live in errors.rb (loaded first) so they can inherit
  # from the shared SmarterJSON::Error base.

  module_function

  # SmarterJSON.process(input, options = {}) — the main entry point.
  #
  # `input` is either a String of JSON content or an IO to read from. (A String
  # is always content, never a filename — use process_file for paths.) The values
  # in `options` override Parser::DEFAULT_OPTIONS.
  #
  # Without a block: always returns an Array of the documents found — [] for none,
  # [doc] for one, [d1, d2, …] for several (NDJSON / JSONL / concatenated). A
  # top-level value must be a recognized JSON value (number / literal / quoted
  # string / object / array) or an implicit-root object, else it raises. For the
  # single-document case use SmarterJSON.process_one (returns the bare value).
  # :acceleration (default true) selects the C extension when compiled and loaded
  # (SmarterJSON::HAS_ACCELERATION); otherwise the pure-Ruby parser.
  #
  # With a block: yields each top-level document as it is parsed, and returns the
  # document count. For an IO this streams document-by-document in bounded memory —
  # it reads the stream as newline-delimited documents (NDJSON / JSONL), one per
  # line.
  def process(input, options = {}, &block)
    options = Options.process_options(options)
    if input.is_a?(String)
      Recovery.process_string(input, options, &block)
    elsif input.respond_to?(:read)
      block ? stream_io(input, options, &block) : process(input.read, options)
    else
      raise ArgumentError, "SmarterJSON.process expects a String or an IO, got #{input.class}"
    end
  end

  # SmarterJSON.process_file(path, options = {}) — open a file and process it.
  #
  # The :encoding option labels the file's encoding (default "UTF-8"); it does NOT
  # trigger a transcoding pass — the parser works on the bytes in their native
  # encoding and emits string values with the same encoding tag. With a block,
  # streams document-by-document straight from disk in bounded memory (never
  # loading the whole file); the documents are read as newline-delimited
  # (NDJSON / JSONL), one per line.
  def process_file(path, options = {}, &block)
    options = Options.process_options(options)
    encoding = options[:encoding] || "UTF-8"
    if block
      File.open(path, "r:#{encoding}") { |io| stream_io(io, options, &block) }
    else
      process(File.read(path, encoding: encoding), options)
    end
  end

  # SmarterJSON.foreach(path, options = {}) — the streaming, composable sibling of
  # process_file, mirroring the stdlib convention (CSV.foreach / File.foreach): a
  # plain Enumerator (NOT Enumerator::Lazy), so .map / .select behave the normal way
  # and return an Array.
  #
  # Without a block: returns an Enumerator over each top-level document, reading the
  # file one document at a time via File.open/readpartial — it never slurps the whole
  # file the way process_file(path) does. So foreach(path).first(3) reads only ~3
  # documents off disk, and foreach(path).each { … } / .next stream in bounded memory.
  # .map / .select read the source one document at a time but still build an Array of
  # their result; for a chain that stays bounded end to end (a large filtered set off
  # a fat file) opt into .lazy at the call site: foreach(path).lazy.select { … }.each { … }.
  #
  # With a block: streams each document and returns the document count — identical
  # to process_file(path) { |doc| … }.
  #
  # Options are validated eagerly (before the Enumerator is returned), so a bad
  # option key or value fails fast rather than on first iteration.
  def foreach(path, options = {}, &block)
    options = Options.process_options(options)
    return enum_for(:foreach, path, options) unless block

    process_file(path, options, &block)
  end

  # SmarterJSON.process_one(input, options = {}) — the single-document accessor.
  #
  # Returns the first document's value (or nil when the input holds no documents).
  # When the input holds MORE than one document it returns the first and warns once
  # — it never raises, since an extra document is valid data; the warning goes to
  # on_warning if set, else Rails.logger.warn when Rails is loaded, else Kernel#warn.
  # For an IO this is bounded memory: it parses just the first document and stops as
  # soon as a second is seen, instead of materialising the whole stream the way
  # process(io).first would. (process(input).first and process(input)[0] silently
  # drop documents 2+ — a footgun; use process_one instead.)
  def process_one(input, options = {})
    options = Options.process_options(options)

    # IO: bounded memory — parse just the first document and stop once a second is
    # seen (peek-to-warn). A String is already in memory, so use the plain no-block
    # path: it returns the full (wrapper-recovered, de-duplicated) Array in one pass,
    # which also avoids the reactive-recovery double-yield the block path would hit.
    unless input.respond_to?(:read)
      docs = process(input, options)
      warn_extra_documents(options) if docs.length > 1
      return docs.first
    end

    first = nil
    count = 0
    catch(:smarter_json_first_document) do
      process(input, options) do |doc|
        count += 1
        first = doc if count == 1
        throw(:smarter_json_first_document) if count > 1
      end
    end
    warn_extra_documents(options) if count > 1
    first
  end

  # Parse a String of JSON content (the in-memory path). Returns an Array of the
  # documents found (empty for none); the C extension is used when available.
  def process_content(input, options, &block)
    if block
      if options.fetch(:acceleration, true) && HAS_ACCELERATION
        parse_c(input, options, &block)
      else
        Parser.new(input, options).each_value(&block)
      end
    elsif options.fetch(:acceleration, true) && HAS_ACCELERATION
      parse_c(input, options)
    else
      Parser.new(input, options).parse
    end
  end

  # Smart default for the nil :encoding option. A String tagged ASCII-8BIT (BINARY)
  # is how Net::HTTP and many HTTP libraries hand back a response body even when the
  # bytes are UTF-8. JSON's interchange encoding is UTF-8, so we relabel such input
  # to UTF-8 when its bytes are valid UTF-8 — otherwise string values would come back
  # tagged ASCII-8BIT and compare unequal to UTF-8 literals (a silent footgun). When
  # the bytes are NOT valid UTF-8 we raise EncodingError rather than guess a legacy
  # encoding — pass an explicit :encoding for that. An explicit (non-nil) :encoding,
  # or any non-BINARY tag, is left untouched (the per-path force_encoding / validation
  # handles it). Only relabels — never transcodes.
  def normalize_default_encoding(input, options)
    return input unless options[:encoding].nil?
    return input unless input.encoding == Encoding::ASCII_8BIT

    utf8 = input.dup.force_encoding(Encoding::UTF_8)
    return utf8 if utf8.valid_encoding?

    raise EncodingError, "input is tagged ASCII-8BIT and is not valid UTF-8 — pass encoding: to declare its encoding"
  end

  # Stream documents from an IO incrementally, yielding each recovered top-level
  # document without slurping the whole input into memory first.
  def stream_io(io, options, &block)
    count = 0
    Framer.each_document(io) do |doc|
      # Recovery.process_string yields each value and returns how many it yielded;
      # blank / comment-only framed segments yield none, so count tracks actual
      # documents (== values yielded), not raw framed segments.
      count += Recovery.process_string(doc, options, &block)
    end
    count
  end

  # process_one's "more than one document" notice — routed to on_warning if the caller
  # gave one, else Rails.logger when Rails is loaded, else Kernel#warn. Never silent,
  # never raised.
  def warn_extra_documents(options)
    message = "SmarterJSON.process_one: input has more than one document — returning the first and " \
              "dropping the rest. Use SmarterJSON.process to get every document."
    handler = options[:on_warning]
    if handler
      handler.call(Warning.new(:extra_documents, message, nil, nil))
    elsif defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger.warn(message)
    else
      Kernel.warn(message)
    end
  end

  private_class_method :process_content, :stream_io, :warn_extra_documents

  # Named byte values, shared by the Parser FSM and the Framer / Recovery byte
  # scanners so none of them spell out raw hex. Included where needed.
  module Bytes
    LBRACE     = 0x7B
    RBRACE     = 0x7D
    LBRACKET   = 0x5B
    RBRACKET   = 0x5D
    COLON      = 0x3A
    COMMA      = 0x2C
    DQUOTE     = 0x22
    SQUOTE     = 0x27
    BACKSLASH  = 0x5C
    SLASH      = 0x2F
    STAR       = 0x2A
    HASH       = 0x23
    MINUS      = 0x2D
    PLUS       = 0x2B
    DOT        = 0x2E
    ZERO       = 0x30
    NINE       = 0x39
    LOWER_E    = 0x65
    UPPER_E    = 0x45
    LOWER_T    = 0x74
    LOWER_F    = 0x66
    LOWER_N    = 0x6E
    LOWER_U    = 0x75
    LOWER_X    = 0x78
    UPPER_X    = 0x58
    UPPER_I    = 0x49
    UPPER_N    = 0x4E
    UPPER_T    = 0x54
    UPPER_F    = 0x46
    UNDERSCORE = 0x5F
    DOLLAR     = 0x24
    SPACE      = 0x20
    TAB        = 0x09
    LF         = 0x0A
    CR         = 0x0D
  end

  module Framer
    include Bytes

    CHUNK_SIZE = 16 * 1024

    module_function

    def each_document(io)
      buffer = +""
      scan = 0
      doc_start = nil
      stack = []
      mode = nil

      while (chunk = read_chunk(io))
        buffer << chunk
        loop do
          emitted, buffer, scan, doc_start, stack, mode = scan_buffer(buffer, scan, doc_start, stack, mode)
          break unless emitted

          yield emitted
        end
      end

      yield buffer unless separators_only?(buffer)
    end

    def read_chunk(io)
      if io.respond_to?(:readpartial)
        io.readpartial(CHUNK_SIZE)
      else
        io.read(CHUNK_SIZE)
      end
    rescue EOFError
      nil
    end

    def scan_buffer(buffer, scan, doc_start, stack, mode)
      while scan < buffer.bytesize
        b = buffer.getbyte(scan)
        # A multi-byte marker (// /* ''' */) whose lead byte is here but whose
        # remaining bytes have not arrived yet must not be guessed at — advancing
        # past the lead byte would misread the brace/quote that follows it once the
        # next chunk lands. Stop and let each_document append more input, then resume
        # from this same position. At true EOF the leftover is parsed whole instead.
        break if defer_for_split_marker?(buffer, scan, b, mode, doc_start)

        if mode == :double
          if b == BACKSLASH
            scan += 2
          elsif b == DQUOTE
            mode = nil
            scan += 1
          else
            scan += 1
          end
        elsif mode == :single
          if b == BACKSLASH
            scan += 2
          elsif b == SQUOTE
            mode = nil
            scan += 1
          else
            scan += 1
          end
        elsif mode == :triple
          if buffer.byteslice(scan, 3) == "'''"
            mode = nil
            scan += 3
          else
            scan += 1
          end
        elsif mode == :line_comment
          if [LF, CR].include?(b)
            mode = nil
          else
            scan += 1
            next
          end
        elsif mode == :block_comment
          if buffer.byteslice(scan, 2) == '*/'
            mode = nil
            scan += 2
          else
            scan += 1
          end
        elsif doc_start.nil?
          if whitespace_byte?(b)
            scan += 1
          elsif line_comment_start?(buffer, scan)
            mode = :line_comment
            scan += buffer.getbyte(scan) == HASH ? 1 : 2
          elsif block_comment_start?(buffer, scan)
            mode = :block_comment
            scan += 2
          elsif [LBRACE, LBRACKET].include?(b)
            doc_start = scan
            stack << b
            scan += 1
          else
            scan = buffer.bytesize
          end
        else
          if mode.nil? && line_comment_start?(buffer, scan)
            mode = :line_comment
            scan += buffer.getbyte(scan) == HASH ? 1 : 2
          elsif mode.nil? && block_comment_start?(buffer, scan)
            mode = :block_comment
            scan += 2
          elsif b == DQUOTE
            mode = :double
            scan += 1
          elsif buffer.byteslice(scan, 3) == "'''"
            mode = :triple
            scan += 3
          elsif b == SQUOTE
            mode = :single
            scan += 1
          elsif [LBRACE, LBRACKET].include?(b)
            stack << b
            scan += 1
          elsif b == RBRACE
            stack.pop if stack.last == LBRACE
            scan += 1
            if stack.empty?
              doc = buffer.byteslice(doc_start, scan - doc_start)
              buffer = buffer.byteslice(scan..-1) || +""
              return [doc, buffer, 0, nil, [], nil]
            end
          elsif b == RBRACKET
            stack.pop if stack.last == LBRACKET
            scan += 1
            if stack.empty?
              doc = buffer.byteslice(doc_start, scan - doc_start)
              buffer = buffer.byteslice(scan..-1) || +""
              return [doc, buffer, 0, nil, [], nil]
            end
          else
            scan += 1
          end
        end
      end

      [nil, buffer, scan, doc_start, stack, mode]
    end

    # True when `b` is the lead byte of a multi-byte marker but the rest of that
    # marker has not been read into the buffer yet, so we cannot decide what it is.
    # `//` and `/*` need 2 bytes; `'''` (and a closing `'''`) needs 3; a closing
    # `*/` needs 2. Backslash escapes and single-byte delimiters never need this.
    def defer_for_split_marker?(buffer, scan, b, mode, doc_start)
      avail = buffer.bytesize - scan
      case mode
      when :block_comment
        b == STAR && avail < 2
      when :triple
        b == SQUOTE && avail < 3
      when nil
        if doc_start.nil?
          b == SLASH && avail < 2
        else
          (b == SLASH && avail < 2) || (b == SQUOTE && avail < 3)
        end
      else
        false
      end
    end

    def separators_only?(buffer)
      scan = 0
      mode = nil
      while scan < buffer.bytesize
        b = buffer.getbyte(scan)
        if mode == :line_comment
          if [LF, CR].include?(b)
            mode = nil
          else
            scan += 1
            next
          end
        elsif mode == :block_comment
          if buffer.byteslice(scan, 2) == '*/'
            mode = nil
            scan += 2
          else
            scan += 1
          end
        elsif whitespace_byte?(b)
          scan += 1
        elsif line_comment_start?(buffer, scan)
          mode = :line_comment
          scan += buffer.getbyte(scan) == HASH ? 1 : 2
        elsif block_comment_start?(buffer, scan)
          mode = :block_comment
          scan += 2
        else
          return false
        end
      end
      true
    end

    def whitespace_byte?(b)
      b == SPACE || (b && b >= TAB && b <= CR)
    end

    def line_comment_start?(buffer, scan)
      b = buffer.getbyte(scan)
      return preceded_by_ws_or_start?(buffer, scan) if b == HASH

      b == SLASH && buffer.getbyte(scan + 1) == SLASH && preceded_by_ws_or_start?(buffer, scan)
    end

    def block_comment_start?(buffer, scan)
      buffer.getbyte(scan) == SLASH && buffer.getbyte(scan + 1) == STAR && preceded_by_ws_or_start?(buffer, scan)
    end

    def preceded_by_ws_or_start?(buffer, scan)
      return true if scan.zero?

      prev = buffer.getbyte(scan - 1)
      whitespace_byte?(prev)
    end
  end

  module Recovery
    include Bytes

    module_function

    def process_string(input, options, &block)
      input = SmarterJSON.send(:normalize_default_encoding, input, options)
      return SmarterJSON.send(:process_content, input, options, &block) unless input.valid_encoding?

      # Recovery is REACTIVE: parse first, and only fall back to wrapper extraction when
      # the parse actually fails (the rescue below). Every wrapper shape — code fences,
      # <json>/BEGIN_JSON tags, prose around the payload — makes the parse raise, so the
      # rescue catches it. Crucially this keeps clean input on the single-parse fast path
      # even when its string values legitimately contain ``` or <json> (real-world data
      # like GitHub event payloads is full of markdown), instead of dragging hundreds of
      # MB through the pure-Ruby candidate scan.
      #
      # The one exception is a bare leading label like "JSON: {...}", which parses
      # successfully but WRONGLY (as an implicit-root object keyed by the label), so it
      # must be intercepted before parsing.
      if leading_label?(input)
        payloads = extract_payloads(input, options)
        return replay_payloads(payloads, options, &block) unless payloads.empty?
      end

      SmarterJSON.send(:process_content, input, options, &block)
    rescue ParseError => e
      raise if e.is_a?(EncodingError)

      payloads = extract_payloads(input, options)
      return replay_payloads(payloads, options, &block) unless payloads.empty?

      raise
    end

    # Whether the input opens with a bare "JSON:" / "Final answer:" label (which would
    # otherwise parse, wrongly, as an implicit-root object keyed by the label). We use
    # String#start_with? with a Regexp rather than match?(/\A.../): start_with? checks
    # only the beginning, whereas a \A-anchored match? still retries at every byte
    # position and so scans the WHOLE input (≈0.3s on a 200 MB document) on every parse.
    # (Caller has already established the input is valid_encoding?.)
    def leading_label?(input)
      input.start_with?(/[[:space:]]*(?:JSON|Final answer)[[:space:]]*:/i)
    end

    def replay_payloads(payloads, options, &block)
      handler = options[:on_warning]
      emit_wrapper_warnings(payloads, handler)

      if block_given?
        count = 0
        payloads.each do |payload|
          SmarterJSON.send(:process_content, payload[:slice], options) do |doc|
            block.call(doc)
            count += 1
          end
        end
        return count
      end

      # Each payload's process_content now returns an Array of its documents; flatten
      # so several recovered payloads yield one flat Array<doc> (the always-array
      # contract), not an Array of Arrays.
      payloads.flat_map do |payload|
        SmarterJSON.send(:process_content, payload[:slice], options)
      end
    end

    def emit_wrapper_warnings(payloads, handler)
      return unless handler

      meta = payloads.first[:meta]
      warn(handler, :prefix_text_ignored, "ignored non-JSON text before the payload", *meta[:first_pos]) if meta[:prefix]
      warn(handler, :code_fence_stripped, "stripped markdown code fences around the payload", *meta[:first_pos]) if meta[:fence]
      warn(handler, :wrapper_tag_stripped, "stripped wrapper tags around the payload", *meta[:first_pos]) if meta[:wrapper]
      warn(handler, :suffix_text_ignored, "ignored non-JSON text after the payload", *meta[:last_pos]) if meta[:suffix]
    end

    def extract_payloads(input, options)
      payloads = candidate_ranges(input).filter_map do |range|
        slice = input.byteslice(range.begin, range.end - range.begin)
        begin
          SmarterJSON.send(:process_content, slice, options.merge(on_warning: nil))
          { slice: slice, range: range }
        rescue ParseError
          nil
        end
      end
      meta = wrapper_meta(input, payloads.map { |p| p[:range] })
      payloads.each { |payload| payload[:meta] = meta }
      payloads
    end

    def wrapper_meta(input, ranges)
      return { prefix: false, suffix: false, fence: false, wrapper: false } if ranges.empty?

      first = ranges.first
      last = ranges.last
      prefix = input.byteslice(0, first.begin)
      suffix = input.byteslice(last.end, input.bytesize - last.end)
      # Look for fence / wrapper markers only in the text we actually strip (outside
      # every recovered payload), so a ``` or <json> sitting inside a payload's own
      # string value does not trigger a "stripped a wrapper" warning.
      outside = non_payload_text(input, ranges)
      {
        prefix: substantive_text?(prefix),
        suffix: substantive_text?(suffix),
        fence: outside.include?("```"),
        wrapper: outside.match?(/<json\b|BEGIN_JSON\b/i),
        first_pos: line_col_for(input, first.begin),
        last_pos: line_col_for(input, last.begin)
      }
    end

    def non_payload_text(input, ranges)
      out = +""
      pos = 0
      ranges.each do |range|
        out << input.byteslice(pos, range.begin - pos) if range.begin > pos
        pos = range.end
      end
      out << input.byteslice(pos, input.bytesize - pos) if pos < input.bytesize
      out
    end

    def line_col_for(input, offset)
      line = 1
      col = 1
      i = 0
      while i < offset
        b = input.getbyte(i)
        break if b.nil?

        if b == LF
          line += 1
          col = 1
          i += 1
        elsif b == CR
          line += 1
          col = 1
          i += 1
          i += 1 if i < offset && input.getbyte(i) == LF
        else
          col += 1
          i += 1
        end
      end
      [line, col]
    end

    def substantive_text?(text)
      return false if text.nil? || text.empty?

      stripped = text.dup
      stripped.gsub!(%r{/\*.*?\*/}m, "")
      stripped.gsub!(/^\s*(?:#|\/\/).*$/, "")
      !stripped.strip.empty? && !stripped.strip.match?(/\A(?:```[a-zA-Z0-9_-]*)?\z/) && !stripped.strip.match?(/\A(?:<\/?json>|BEGIN_JSON|END_JSON)\z/i)
    end

    def warn(handler, type, message, line, col)
      handler.call(Warning.new(type, message, line, col))
    end

    def candidate_ranges(input)
      ranges = []
      stack = []
      start_pos = nil
      i = 0
      mode = nil
      while i < input.bytesize
        b = input.getbyte(i)
        if mode == :double
          if b == BACKSLASH
            i += 2
            next
          elsif b == DQUOTE
            mode = nil
          end
          i += 1
          next
        elsif mode == :single
          if b == BACKSLASH
            i += 2
            next
          elsif b == SQUOTE
            mode = nil
          end
          i += 1
          next
        elsif mode == :triple
          if input.byteslice(i, 3) == "'''"
            mode = nil
            i += 3
          else
            i += 1
          end
          next
        elsif mode == :line_comment
          if [LF, CR].include?(b)
            mode = nil
          else
            i += 1
            next
          end
        elsif mode == :block_comment
          if input.byteslice(i, 2) == "*/"
            mode = nil
            i += 2
          else
            i += 1
          end
          next
        else
          if input.byteslice(i, 2) == "//"
            mode = :line_comment
            i += 2
            next
          elsif input.byteslice(i, 2) == "/*"
            mode = :block_comment
            i += 2
            next
          elsif b == HASH
            mode = :line_comment
            i += 1
            next
          elsif b == DQUOTE
            mode = :double
            i += 1
            next
          elsif input.byteslice(i, 3) == "'''"
            mode = :triple
            i += 3
            next
          elsif b == SQUOTE
            mode = :single
            i += 1
            next
          elsif [LBRACE, LBRACKET].include?(b)
            start_pos = i if stack.empty?
            stack << b
          elsif b == RBRACE
            stack.pop if stack.last == LBRACE
            if stack.empty? && start_pos
              ranges << (start_pos...(i + 1))
              start_pos = nil
            end
          elsif b == RBRACKET
            stack.pop if stack.last == LBRACKET
            if stack.empty? && start_pos
              ranges << (start_pos...(i + 1))
              start_pos = nil
            end
          end
        end
        i += 1
      end
      ranges
    end
  end

  # Hand-rolled FSM single-pass parser.
  # Layer 1: strict JSON (RFC 8259).
  # Layer 2: JSON5 additions — line/block comments, trailing comma,
  #          unquoted ECMAScript identifier keys, single-quoted strings,
  #          hex numbers, leading/trailing decimal points, Infinity/NaN,
  #          explicit + sign, \-line-continuation inside strings.
  # Layer 3: HJSON-inspired additions — #/comment-marker rule, triple-quoted
  #          strings, quoteless single-line strings, implicit root object,
  #          newline-as-separator, broader unquoted keys, recognized-literals-win.
  # Layer 4: smarter_json additions — UTF-8 BOM skip, smart/curly quotes,
  #          Python literals (True/False/None) and undefined, underscores in
  #          numeric literals, and encoding validation (SmarterJSON::EncodingError).
  class Parser
    include Bytes

    NOT_NUMERIC = Object.new
    HEX_RE      = /\A[-+]?0[xX][0-9a-fA-F_]+\z/.freeze
    # Mantissa must carry at least one digit (int part, or a leading-dot fraction), so a
    # bare exponent like "-e695881" is NOT a number — it falls through to a quoteless
    # string, matching the C path. Trailing exponent stays optional.
    DEC_RE      = /\A[-+]?(?:(?:0|[1-9][0-9_]*)(?:\.[0-9_]*)?|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?\z/.freeze
    # A decimal BigDecimal() would reject as-is: a leading dot (".5") or a dot not
    # followed by a digit ("5.", "5.e3"). Matches iff normalize_for_bigdecimal
    # would change the string — so when it doesn't match, we skip normalization.
    NEEDS_DECIMAL_FIXUP = /\A[+-]?\.|\.(?:[eE]|\z)/.freeze

    # parse_string scans to the next closing-quote-or-backslash. byteindex (Ruby 3.2+,
    # MRI) does that jump at C speed; the getbyte loop in scan_string_delimiter is the
    # portable fallback (JRuby / TruffleRuby / older MRI). Both find the same byte.
    BYTEINDEX_AVAILABLE = "".respond_to?(:byteindex)
    DQUOTE_OR_BACKSLASH = /["\\]/.freeze
    SQUOTE_OR_BACKSLASH = /['\\]/.freeze

    # scan_quoteless_run's fast path jumps (in C) to the first structural terminator
    # (',' '}' ']' '{' '[') OR any whitespace ([[:space:]] covers ASCII + Unicode space,
    # incl. LF/CR which also terminate). Stopping at a terminator/EOF means the run had no
    # interior whitespace, so there's nothing to trim and no comment marker can apply.
    QL_BREAK = /[,{}\[\]]|[[:space:]]/.freeze

    # The defaults live centrally in SmarterJSON::Options (lib/smarter_json/options.rb).
    DEFAULT_OPTIONS = Options::DEFAULT_OPTIONS

    def initialize(input, options = {})
      raise ArgumentError, "input must be a String" unless input.is_a?(String)

      opts = DEFAULT_OPTIONS.merge(options)
      @symbolize_keys  = opts[:symbolize_keys]
      @duplicate_key   = opts[:duplicate_key]
      @decimal_precision = opts[:decimal_precision]
      @on_warning = opts[:on_warning]
      # store_member only needs the (per-member) Hash#key? duplicate lookup when a
      # repeat would change behavior: a warning must fire, or :first_wins must keep the
      # first. With the default (:last_wins, no handler) a duplicate just overwrites,
      # which `hash[k] = value` already does — so skip the lookup entirely.
      @check_duplicates = !@on_warning.nil? || @duplicate_key == :first_wins

      encoding = opts[:encoding]
      @input = encoding ? input.dup.force_encoding(encoding) : input
      raise EncodingError, "invalid byte sequence for #{@input.encoding.name}" unless @input.valid_encoding?

      @bytesize = @input.bytesize
      # Skip a UTF-8 BOM (EF BB BF) at the start of input.
      @pos = @input.getbyte(0) == 0xEF && @input.getbyte(1) == 0xBB && @input.getbyte(2) == 0xBF ? 3 : 0
    end

    # No block: auto-detect the document count for free (the same "is there
    # trailing content?" check that used to raise). 0 documents -> nil; 1 document
    # -> the value itself (single-document path, no Array allocated); 2+ documents
    # (NDJSON / JSONL / concatenated / whitespace-separated) -> an Array of every
    # value. Commas do NOT separate documents (only whitespace / newline /
    # concatenation do), so a bracketless comma list still raises in parse_document.
    def parse
      results = []
      until eof?
        skip_document_separators
        break if eof?

        value = parse_document
        enforce_scalar_boundary(value)
        results << value
      end
      results
    end

    # Yield each top-level value until EOF (JSONL / NDJSON / concatenated /
    # whitespace-separated). Used by the block form of SmarterJSON.process.
    def each_value
      count = 0
      until eof?
        skip_document_separators
        break if eof?

        value = parse_document
        enforce_scalar_boundary(value)
        yield value
        count += 1
      end
      count
    end

    private

    # --- top-level dispatch ---

    def parse_document
      parse_iter(implicit_root_object_ahead?)
    end

    # Between top-level documents, whitespace, comments, AND commas all separate
    # (commas collapse like the in-container lenient-comma rule). A space alone never
    # separates — that is handled inside the document by the quoteless run, so
    # `1 2 3` is one document (the string "1 2 3") while `1, 2, 3` is three.
    def skip_document_separators
      skip_whitespace_and_comments
      while byte == COMMA
        advance(1)
        skip_whitespace_and_comments
      end
    end

    # After a top-level value: a self-delimiting value (object / array / quoted string)
    # may be followed by anything (the next document self-delimits), but a bare scalar
    # (number / keyword) must be followed by a real separator — a newline, ',', a
    # comment, or EOF. A space is NOT a separator, so `1 2 3` and `42 "x" true` raise
    # rather than silently splitting; bare top-level words raise in parse_value itself.
    def enforce_scalar_boundary(value)
      return if value.is_a?(String) || value.is_a?(Hash) || value.is_a?(Array)

      skip_horizontal_whitespace
      b = byte
      return if b.nil? || b == LF || b == CR || b == COMMA
      return if b == HASH || (b == SLASH && ((c = byte_at(1)) == SLASH || c == STAR))

      raise error("a top-level number or keyword must be followed by a newline, ',', or end of input")
    end

    # Skip horizontal whitespace only (space / tab / VT / FF) — NOT newlines, which are
    # document separators. Used by the scalar-boundary check above.
    def skip_horizontal_whitespace
      while (b = byte)
        if b == SPACE || b == TAB || b == 0x0B || b == 0x0C
          advance(1)
        elsif b >= 0x80 && (n = multibyte_ws_len(@pos)).positive?
          @pos += n # multibyte horizontal whitespace (NBSP, U+2000–200A, …)
        else
          break
        end
      end
    end

    # Iterative container parser — explicit stack, NO Ruby recursion, so nesting
    # is bounded only by memory (like Oj and the C extension's fj_parse_iter),
    # never by the call stack. Mirrors the C driver to keep the two paths in
    # parity.
    def parse_iter(implicit_root)
      stack = []
      root = nil
      cur = nil
      cur_obj = false
      at_top = true

      if implicit_root
        root = {}
        stack.push(root)
        cur = root
        cur_obj = true
        at_top = false
      end

      vss = false # warnings: has a value landed in the current container since the last separator?
      input = @input # hoisted: @input never changes mid-parse; byte reads inline as input.getbyte(@pos)
      while true
        skip_whitespace_and_comments
        b = input.getbyte(@pos)
        if at_top
          if b == LBRACE
            advance(1)
            root = {}
            stack.push(root)
            cur = root
            cur_obj = true
            at_top = false
            vss = false
          elsif b == LBRACKET
            advance(1)
            root = []
            stack.push(root)
            cur = root
            cur_obj = false
            at_top = false
            vss = false
          elsif b.nil?
            # Defensive guard: parse / each_value check eof? before calling parse_iter,
            # so `at_top` never meets end-of-input here. Kept to mirror the C driver.
            # :nocov:
            raise error("unexpected end of input")
            # :nocov:
          else
            # Top-level scalar: must be a recognized JSON value (number / literal /
            # quoted string). A bare word raises — there are no top-level quoteless
            # strings (Decision 2 = B-broad). In-container quoteless still uses
            # parse_member_value; the scalar-vs-separator boundary is enforced by the
            # parse / each_value loop via enforce_scalar_boundary.
            return parse_value
          end
        elsif b == COMMA
          # Commas are collapsing separators inside a container: an empty slot (leading,
          # interior, or trailing comma) adds nothing. Skip it; the next iteration reads
          # the following value/key or the closing bracket.
          warn(:empty_slot, "extra comma — collapsed an empty slot") if @on_warning && !vss
          vss = false
          advance(1)
        elsif cur_obj
          if b == RBRACE
            advance(1)
            stack.pop
            return root if stack.empty?

            cur = stack.last
            cur_obj = cur.is_a?(Hash)
            vss = true # the just-closed container is a value in its parent
          elsif b.nil?
            return root if implicit_root && stack.size == 1

            raise error("unterminated object")
          elsif b == RBRACKET
            raise error("unexpected ']' — expected a key or '}'")
          else
            key = parse_object_key
            skip_whitespace_and_comments
            raise error("expected ':' after key #{key.inspect}") unless input.getbyte(@pos) == COLON

            advance(1)
            skip_whitespace_and_comments
            b = input.getbyte(@pos)
            if b == LBRACE || b == LBRACKET
              child = b == LBRACE ? {} : []
              advance(1) # consume { or [
              store_member(cur, key, child)
              stack.push(child)
              cur = child
              cur_obj = (b == LBRACE)
              vss = false
            elsif b == RBRACE || b == COMMA
              # key with a colon but no value -> null (don't consume } or ,; the loop does)
              store_member(cur, key, nil)
              warn(:empty_value, "key #{key.inspect} had no value — used null") if @on_warning
              vss = true
            elsif b.nil?
              raise error("unexpected end of input")
            else
              store_member(cur, key, parse_member_value)
              vss = true
            end
          end
        else # array
          if b == RBRACKET
            advance(1)
            stack.pop
            return root if stack.empty?

            cur = stack.last
            cur_obj = cur.is_a?(Hash)
            vss = true # the just-closed container is a value in its parent
          elsif b.nil?
            raise error("unterminated array")
          elsif b == RBRACE
            raise error("unexpected '}' — expected ']' or a value")
          elsif b == LBRACE || b == LBRACKET
            child = b == LBRACE ? {} : []
            advance(1) # consume { or [
            cur.push(child)
            stack.push(child)
            cur = child
            cur_obj = (b == LBRACE)
            vss = false
          else
            cur.push(parse_member_value)
            vss = true
          end
        end
      end
    end

    # At the start of a document: an unquoted identifier followed by ':' means
    # an implicit root object (no outer braces). Look ahead without consuming.
    def implicit_root_object_ahead?
      b = byte
      return false unless b && key_start_byte?(b)

      saved = @pos
      advance(1) while (c = byte) && key_continue_byte?(c)
      skip_pure_whitespace
      result = (byte == COLON)
      @pos = saved
      result
    end

    # --- byte access ---

    def byte
      @input.getbyte(@pos)
    end

    def byte_at(offset)
      @input.getbyte(@pos + offset)
    end

    def eof?
      @pos >= @bytesize
    end

    # Advance the byte cursor by n (clamped to EOF). No line/col bookkeeping — that
    # is computed lazily in line_col_at only when an error/warning is built. This is
    # the hot-path primitive every consumed byte goes through, so it stays O(1) with
    # no block, no re-read, and no per-byte branching. Mirrors the C fj_advance.
    def advance(n = 1)
      @pos += n
      @pos = @bytesize if @pos > @bytesize
    end

    # Line and 1-based BYTE column at byte position `pos`, computed lazily by scanning
    # from the start of the buffer — only on the cold path (error / warning / triple-quote
    # indent), never per byte. CR, LF, and CRLF each count as one newline; the column is
    # the byte offset within the line. Mirrors the C extension's fj_line_col so both paths
    # report identical positions.
    def line_col_at(pos = @pos)
      limit = pos < @bytesize ? pos : @bytesize
      line = 1
      col = 1
      i = 0
      while i < limit
        b = @input.getbyte(i)
        if b == LF
          line += 1
          col = 1
        elsif b == CR
          line += 1
          col = 1
          i += 1 if i + 1 < @bytesize && @input.getbyte(i + 1) == LF
        else
          col += 1
        end
        i += 1
      end
      [line, col]
    end

    # 1-based byte column at `pos` (bytes since the last line start). Used for
    # triple-quoted-string indentation stripping. Mirrors the C fj_column.
    def column_at(pos = @pos)
      c = 1
      i = pos - 1
      while i >= 0 && (b = @input.getbyte(i)) != LF && b != CR
        c += 1
        i -= 1
      end
      c
    end

    # --- whitespace (Unicode [[:space:]] / Rails blank?; see smarter_json.md §4.7) ---

    def skip_pure_whitespace
      input = @input
      pos = @pos
      while (b = input.getbyte(pos))
        if b == SPACE || (b >= TAB && b <= CR) # 0x20, or 0x09..0x0D
          pos += 1
        elsif b >= 0x80
          n = multibyte_ws_len(pos)
          break if n.zero?

          pos += n
        else
          break
        end
      end
      @pos = pos
    end

    # Number of bytes of the Unicode-whitespace char starting at pos, or 0.
    # Only meaningful for bytes >= 0x80.
    def multibyte_ws_len(pos)
      b0 = @input.getbyte(pos)
      return 0 if b0 != 0xC2 && (b0 < 0xE1 || b0 > 0xE3) # reject-gate

      b1 = @input.getbyte(pos + 1)
      return 0 if b1.nil?
      return [0xA0, 0x85].include?(b1) ? 2 : 0 if b0 == 0xC2 # NBSP, NEL

      b2 = @input.getbyte(pos + 2)
      return 0 if b2.nil?

      case b0
      when 0xE1
        return 3 if b1 == 0x9A && b2 == 0x80                 # U+1680
      when 0xE2
        if b1 == 0x80
          return 3 if (b2 >= 0x80 && b2 <= 0x8A) || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF
        elsif b1 == 0x81 && b2 == 0x9F
          return 3                                           # U+205F
        end
      when 0xE3
        return 3 if b1 == 0x80 && b2 == 0x80                 # U+3000
      end
      0
    end

    # A '#', '//', or '/*' starts a comment only when preceded by whitespace
    # or at the very start of input (the comment-marker rule).
    def skip_whitespace_and_comments
      while true
        skip_pure_whitespace
        b = byte
        if b == HASH
          break unless preceded_by_ws_or_start?

          skip_to_eol
        elsif b == SLASH
          c = byte_at(1)
          break unless (c == SLASH || c == STAR) && preceded_by_ws_or_start?

          c == STAR ? skip_block_comment : skip_to_eol
        else
          break
        end
      end
    end

    def preceded_by_ws_or_start?
      return true if @pos.zero?

      prev = @input.getbyte(@pos - 1)
      return true if prev == SPACE || (prev >= TAB && prev <= CR)
      return false if prev < 0x80

      # rare: a multibyte whitespace char ending right before @pos
      i = @pos - 1
      i -= 1 while i.positive? && (@input.getbyte(i) & 0xC0) == 0x80
      n = multibyte_ws_len(i)
      n.positive? && (i + n == @pos)
    end

    def skip_to_eol
      advance(1) while (c = byte) && c != LF && c != CR
    end

    def skip_block_comment
      advance(2) # consume /*
      until eof?
        break if byte == STAR && byte_at(1) == SLASH

        advance(1)
      end
      raise error("unterminated block comment") if eof?

      advance(2) # consume */
    end

    # Layer 1 (strict JSON) shape: whitespace + at most one comma + whitespace.
    # The Lenient Commas Option becomes a one-line change here.
    # --- values ---

    # Top-level / strict value: no quoteless fallback.
    # Precondition: callers (parse_iter) have already run skip_whitespace_and_comments,
    # so @pos is at the value's first byte — no leading skip needed here.
    def parse_value
      raise error("unexpected end of input") if eof?

      b = byte
      case b
      when DQUOTE   then parse_string(DQUOTE)
      when SQUOTE   then parse_single_or_triple
      when MINUS, PLUS, DOT, ZERO..NINE, UPPER_I then parse_number
      when UPPER_N then parse_upper_n # NaN vs None
      when LOWER_T then parse_literal_keyword("true", true)
      when LOWER_F then parse_literal_keyword("false", false)
      when LOWER_N then parse_literal_keyword("null", nil)
      when LOWER_U then parse_literal_keyword("undefined", nil)
      when UPPER_T then parse_literal_keyword("True", true)
      when UPPER_F then parse_literal_keyword("False", false)
      else
        kind = smart_quote_kind(@pos)
        return parse_smart_string(kind) if kind

        raise error("unexpected character #{display_byte(b)}")
      end
    end

    # Disambiguate NaN (number) from None (Python null) at a strict position.
    def parse_upper_n
      if byte_at(1) == 0x61 # 'a' → NaN
        parse_number
      else
        parse_literal_keyword("None", nil)
      end
    end

    # Value in object-value or array-element position: quoteless allowed.
    # Precondition: callers (parse_iter) have already run skip_whitespace_and_comments,
    # so @pos is at the value's first byte — no leading skip needed here.
    def parse_member_value
      raise error("unexpected end of input") if eof?

      b = byte
      case b
      when DQUOTE   then parse_string(DQUOTE)
      when SQUOTE   then parse_single_or_triple
      else
        kind = smart_quote_kind(@pos)
        kind ? parse_smart_string(kind) : parse_quoteless_or_literal
      end
    end

    # Smart / curly quotes (U+201C/201D double, U+2018/2019 single), UTF-8
    # E2 80 9C/9D/98/99. Returns :double, :single, or nil.
    def smart_quote_kind(pos)
      return nil unless @input.getbyte(pos) == 0xE2 && @input.getbyte(pos + 1) == 0x80

      case @input.getbyte(pos + 2)
      when 0x9C, 0x9D then :double
      when 0x98, 0x99 then :single
      end
    end

    # Content between smart quotes is taken literally (no escape processing).
    # Accepts either curly variant as opener/closer (lenient about direction).
    def parse_smart_string(kind)
      closers = kind == :double ? [0x9C, 0x9D] : [0x98, 0x99]
      advance(3)
      start = @pos
      until eof?
        if @input.getbyte(@pos) == 0xE2 && @input.getbyte(@pos + 1) == 0x80 &&
           closers.include?(@input.getbyte(@pos + 2))
          result = @input.byteslice(start, @pos - start) # byteslice preserves @input's encoding
          advance(3)
          return result
        end
        advance(1)
      end
      raise error("unterminated smart-quoted string")
    end

    def store_member(hash, key, value)
      k = @symbolize_keys ? key.to_sym : key
      if @check_duplicates && hash.key?(k)
        warn(:duplicate_key, "duplicate key #{k.inspect} — #{@duplicate_key}") if @on_warning
        return if @duplicate_key == :first_wins
      end
      hash[k] = value
    end

    def parse_object_key
      b = byte
      return parse_string(DQUOTE) if b == DQUOTE
      return parse_string(SQUOTE) if b == SQUOTE

      # A key may open with a smart/curly quote too (word-processor paste curls keys,
      # not just values) — route to the same reader values already use.
      kind = smart_quote_kind(@pos)
      return parse_smart_string(kind) if kind

      raise error("expected a key") unless b && key_start_byte?(b)

      parse_identifier_key
    end

    def key_start_byte?(b)
      (b >= 0x41 && b <= 0x5A) ||   # A-Z
        (b >= 0x61 && b <= 0x7A) || # a-z
        b == UNDERSCORE ||
        b == DOLLAR
    end

    def key_continue_byte?(b)
      key_start_byte?(b) || (b >= ZERO && b <= NINE) || b == MINUS # hyphen allowed
    end

    def parse_identifier_key
      start = @pos
      advance(1)
      advance(1) while (b = byte) && key_continue_byte?(b)
      @input.byteslice(start, @pos - start) # byteslice preserves @input's encoding
    end

    # --- quoteless strings & literal classification ---

    def parse_quoteless_or_literal
      start = @pos
      value_end = scan_quoteless_run
      # A quoteless run must consume at least one byte. If the first byte is a
      # delimiter (',' '}' ']'), the run is empty and @pos didn't move — returning
      # here would make the caller's `result << parse_member_value` loop forever.
      # Raise instead (correct today: the Lenient Commas Option is not adopted).
      raise error("expected a value") if @pos == start

      # value_end is the end of the last non-whitespace char in the run; slicing to it
      # drops trailing whitespace without a regex (the caller already skipped leading
      # whitespace, so there is none to trim at the front). Equivalent to the old
      # trim_blank(raw) but with no per-scalar String#sub allocations.
      raw = @input.byteslice(start, value_end - start) # byteslice preserves @input's encoding
      classify_quoteless(raw)
    end

    # Advance to the end of a quoteless run. Stops at structural punctuation
    # (',' '{' '}' '[' ']' — openers terminate symmetrically with closers, so a
    # self-delimiting value starts fresh: `localhost {"a":1}` -> ["localhost", {...}]),
    # a newline, EOF, or a comment marker that is preceded by whitespace. Spaces by
    # themselves are not delimiters.
    # Advance @pos to the end of the quoteless run (including any trailing whitespace,
    # so the parser resumes correctly after the value). Returns value_end: the byte
    # offset just past the last NON-whitespace char, so the caller can slice off
    # trailing whitespace without a regex.
    def scan_quoteless_run
      input = @input
      pos = @pos
      # Fast path: one C-level byteindex jumps to the first structural terminator or
      # whitespace. If it lands on a terminator (or EOF) the run had no interior whitespace,
      # so [pos, hit) is the whole value — value_end == hit (no trailing trim) and no comment
      # marker can apply (those only break after whitespace). This is the common case
      # (numbers and simple tokens). Anything with whitespace falls to the byte-by-byte loop.
      if BYTEINDEX_AVAILABLE
        hit = input.byteindex(QL_BREAK, pos) || @bytesize
        b = hit < @bytesize ? input.getbyte(hit) : nil
        if b.nil? || b == COMMA || b == RBRACE || b == RBRACKET || b == LBRACE || b == LBRACKET || b == LF || b == CR
          @pos = hit
          return hit
        end
      end

      # Slow path: the run contains whitespace — scan byte by byte to honor interior
      # whitespace, trailing-whitespace trimming (value_end is the end of the last
      # non-whitespace char), and the comment-marker-after-whitespace rule.
      value_end = pos
      prev_ws = false
      while (b = input.getbyte(pos))
        break if b == COMMA || b == RBRACE || b == RBRACKET || b == LBRACE || b == LBRACKET || b == LF || b == CR
        break if prev_ws && (b == HASH || (b == SLASH && ((c = input.getbyte(pos + 1)) == SLASH || c == STAR)))

        if b == SPACE || (b >= TAB && b <= CR) # tab/VT/FF/space (LF/CR already broke)
          prev_ws = true
          pos += 1
        elsif b >= 0x80 && (n = multibyte_ws_len(pos)).positive?
          prev_ws = true
          pos += n
        else
          prev_ws = false
          pos += 1
          value_end = pos
        end
      end
      @pos = pos
      value_end
    end

    def classify_quoteless(str)
      case str
      when "true", "True"          then return true
      when "false", "False"        then return false
      when "null", "None"          then return nil
      when "undefined"             then return nil
      when "NaN"                   then return Float::NAN
      when "Infinity", "+Infinity" then return Float::INFINITY
      when "-Infinity"             then return -Float::INFINITY
      end
      num = numeric_value(str)
      num.equal?(NOT_NUMERIC) ? str : num
    end

    # Returns an Integer/Float, or NOT_NUMERIC if the whole token isn't a number.
    def numeric_value(str)
      # Cheap hex gate: only invoke HEX_RE when the token actually looks like [+-]?0x… .
      # A Regexp#match? has real per-call cost; almost no number is hex, so the 1–3 byte
      # check skips that call on the common path (measured +21% on long-token decimals).
      if hex_prefix?(str) && HEX_RE.match?(str)
        neg = str.getbyte(0) == MINUS
        body = str.sub(/\A[-+]/, "").delete("_") # "0x...."
        v = body[2..-1].to_i(16)
        return neg ? -v : v
      end
      return NOT_NUMERIC unless DEC_RE.match?(str) && str.match?(/[0-9]/)

      # delete("_") allocates a fresh string even when there is nothing to delete; on long
      # number tokens that is a real per-value allocation. Underscores are rare, so only
      # pay it when the token actually contains one (measured +27% on long-token decimals).
      body = str.include?("_") ? str.delete("_") : str
      body.match?(/[.eE]/) ? decimal_value(body) : body.to_i
    end

    # True when the token starts with [+-]?0[xX] — the only shape HEX_RE can match.
    def hex_prefix?(str)
      c0 = str.getbyte(0)
      if c0 == ZERO
        x = str.getbyte(1)
        x == LOWER_X || x == UPPER_X
      elsif c0 == MINUS || c0 == PLUS
        str.getbyte(1) == ZERO && ((x = str.getbyte(2)) == LOWER_X || x == UPPER_X)
      else
        false
      end
    end

    # A decimal (has '.' or exponent). decimal_precision: :float -> Float,
    # :bigdecimal -> BigDecimal, :auto -> BigDecimal when the mantissa has more
    # than 16 significant digits (Oj's DEC_MAX threshold), else Float.
    def decimal_value(body)
      case @decimal_precision
      when :float      then float_or_warn(body)
      when :bigdecimal then to_big_decimal(body)
      else                  significant_digits(body) > 16 ? to_big_decimal(body) : float_or_warn(body)
      end
    end

    # A finite numeric literal whose magnitude exceeds Float range (e.g. 1e400) becomes
    # ±Infinity — a silent data change. Report it via :number_overflow (the value is still
    # returned; we warn rather than raise or invent). The Infinity/NaN *keywords* go through
    # a separate path and never reach here, so they don't warn.
    def float_or_warn(body)
      f = body.to_f
      # Only test for overflow when an on_warning handler is listening: `f.infinite?` is a
      # per-float method call we don't want on the hot number path otherwise, and with no
      # handler the warning would go nowhere anyway. Overflow is vanishingly rare.
      warn(:number_overflow, "number literal out of Float range — collapsed to #{f}") if @on_warning && f.infinite?
      f
    end

    # Count significant mantissa digits (leading zeros excluded, exponent ignored) to pick
    # Float vs BigDecimal in :auto mode. A single byte-scan — the old three-regex version
    # (strip exponent, strip non-digits, strip leading zeros, .length) ran on every float
    # and dominated the number path's cost. body is a DEC_RE-validated token (digits, at most
    # one '.', optional sign, optional e/E exponent), underscores already removed.
    def significant_digits(body)
      count = 0
      leading = true
      i = 0
      n = body.bytesize
      while i < n
        b = body.getbyte(i)
        i += 1
        break if b == LOWER_E || b == UPPER_E # exponent: its digits aren't significant

        next unless b >= ZERO && b <= NINE    # skip sign and the decimal point

        if leading && b == ZERO
          next                                # leading zero (incl. those after '.') — not significant
        else
          leading = false
          count += 1
        end
      end
      count
    end

    def to_big_decimal(body)
      # Fast path (mirrors the C extension): a clean token goes straight to
      # BigDecimal(); only a bare/trailing dot needs the normalizing rewrite,
      # which BigDecimal() would otherwise reject. (body has no underscores here
      # — numeric_value already stripped them.)
      body = normalize_for_bigdecimal(body) if NEEDS_DECIMAL_FIXUP.match?(body)
      BigDecimal(body)
    rescue ArgumentError
      # Defensive: BigDecimal() does not reject a DEC_RE-validated, normalized token,
      # so this fallback is unreachable from valid input. Kept as a safety net.
      # :nocov:
      body.to_f
      # :nocov:
    end

    # BigDecimal() rejects a bare leading/trailing dot (".5", "5.", "5.e3").
    def normalize_for_bigdecimal(body)
      body.sub(/\A([+-]?)\./, '\10.').sub(/\.([eE]|\z)/, '.0\1')
    end

    # --- quoted strings ---

    def parse_single_or_triple
      if byte_at(1) == SQUOTE && byte_at(2) == SQUOTE
        parse_triple_quoted
      else
        parse_string(SQUOTE)
      end
    end

    def parse_triple_quoted
      indent = column_at(@pos) - 1
      advance(3)
      raw_start = @pos
      until eof?
        break if byte == SQUOTE && byte_at(1) == SQUOTE && byte_at(2) == SQUOTE

        advance(1)
      end
      raise error("unterminated triple-quoted string") if eof?

      raw = @input.byteslice(raw_start, @pos - raw_start) # byteslice preserves @input's encoding
      advance(3)
      strip_triple(raw, indent)
    end

    def strip_triple(raw, indent)
      text = raw.gsub(/\r\n?/, "\n")
      leading_newline = text.start_with?("\n")
      lines = text.split("\n", -1)
      out = []
      lines.each_with_index do |line, idx|
        if idx.zero?
          leading_newline ? next : (out << line)
        else
          out << strip_indent(line, indent)
        end
      end
      out.pop if out.last && out.last =~ /\A[ \t]*\z/
      out.join("\n").force_encoding(@input.encoding)
    end

    def strip_indent(line, indent)
      i = 0
      i += 1 while i < indent && [" ", "\t"].include?(line[i])
      line[i..-1] || ""
    end

    def parse_string(quote)
      advance(1)
      start = @pos
      # Fast path (the common case — a string with no escapes): jump straight to the
      # closing quote with byteindex. It is called only here, from `start`, which is
      # always a character boundary, so byteindex never sees a mid-char offset.
      hit = scan_string_delimiter(quote)
      raise error("unterminated string") if hit.nil?

      if @input.getbyte(hit) == quote
        @pos = hit
        result = @input.byteslice(start, @pos - start) # byteslice preserves @input's encoding
        advance(1)
        return result
      end

      # Escape path: a backslash precedes the closing quote. Scan byte by byte from
      # here — byteindex can't be used past a backslash (a lenient \<multibyte> would
      # leave @pos mid-character), and this lets the decoder flag invalid escapes
      # exactly as before. decode_string_with_escapes handles the whole [start, finish].
      @pos = hit
      while (b = byte)
        if b == quote
          decoded = decode_string_with_escapes(start, @pos, quote)
          advance(1)
          return decoded
        elsif b == BACKSLASH
          advance(1)
          raise error("unterminated string escape") if eof?

          advance(1)
        else
          advance(1)
        end
      end
      raise error("unterminated string")
    end

    # Byte index of the next closing quote or backslash at/after @pos, or nil if
    # neither occurs before EOF. byteindex scans inside MRI's C; the fallback is a
    # tight getbyte loop (the ASCII delimiters never alias UTF-8 continuation bytes,
    # so byte scanning is correct for UTF-8 string content).
    def scan_string_delimiter(quote)
      if BYTEINDEX_AVAILABLE
        @input.byteindex(quote == DQUOTE ? DQUOTE_OR_BACKSLASH : SQUOTE_OR_BACKSLASH, @pos)
      else
        i = @pos
        i += 1 while i < @bytesize && (b = @input.getbyte(i)) != quote && b != BACKSLASH
        i < @bytesize ? i : nil
      end
    end

    def decode_string_with_escapes(start, finish, _quote)
      buf = String.new(encoding: Encoding::ASCII_8BIT)
      i = start
      while i < finish
        b = @input.getbyte(i)
        unless b == BACKSLASH
          buf << b
          i += 1
          next
        end
        i += 1
        esc = @input.getbyte(i)
        case esc
        when DQUOTE    then buf << '"'.b
        when SQUOTE    then buf << "'".b
        when BACKSLASH then buf << "\\".b
        when SLASH     then buf << "/".b
        when 0x62      then buf << "\b".b
        when 0x66      then buf << "\f".b
        when 0x6E      then buf << "\n".b
        when 0x72      then buf << "\r".b
        when 0x74      then buf << "\t".b
        when LF
          # JSON5 line continuation: \<LF> emits nothing
        when CR
          i += 1 if @input.getbyte(i + 1) == LF
        when LOWER_U
          cp, consumed = decode_unicode_escape(i)
          buf << [cp].pack("U").b
          i += consumed
          next
        else
          raise error("invalid escape \\#{esc&.chr || "?"}")
        end
        i += 1
      end
      buf.force_encoding(@input.encoding)
    end

    def decode_unicode_escape(i)
      raise error("incomplete \\u escape") if i + 4 >= @bytesize

      hex = @input.byteslice(i + 1, 4)
      # Match on a binary view: the 4 bytes may split a raw multibyte character, and a
      # regex on an invalid-UTF-8 String raises ArgumentError. On binary, non-hex bytes
      # simply fail the match and we raise a clean ParseError below.
      raise error("invalid \\u escape") unless hex.b.match?(/\A\h{4}\z/)

      cp = hex.to_i(16)
      consumed = 5
      if cp >= 0xD800 && cp <= 0xDBFF
        unless @input.getbyte(i + consumed) == BACKSLASH && @input.getbyte(i + consumed + 1) == LOWER_U
          raise error("unpaired high surrogate in string")
        end

        hex2 = @input.byteslice(i + consumed + 2, 4)
        raise error("invalid low surrogate \\u escape") unless hex2 && hex2.bytesize == 4 && hex2.b.match?(/\A\h{4}\z/)

        cp2 = hex2.to_i(16)
        raise error("invalid low surrogate value") unless cp2 >= 0xDC00 && cp2 <= 0xDFFF

        cp = 0x10000 + ((cp - 0xD800) << 10) + (cp2 - 0xDC00)
        consumed += 6
      end
      [cp, consumed]
    end

    # --- numbers (top-level / strict positions) ---

    def parse_number
      negative = false
      if byte == MINUS
        negative = true
        advance(1)
      elsif byte == PLUS
        advance(1)
      end

      if byte == UPPER_I
        consume_keyword!("Infinity")
        return negative ? -Float::INFINITY : Float::INFINITY
      end
      if byte == UPPER_N
        consume_keyword!("NaN")
        return Float::NAN
      end

      int_start = @pos

      if byte == ZERO
        advance(1)
        if (x = byte) == LOWER_X || x == UPPER_X
          advance(1)
          hex_start = @pos
          advance(1) while (b = byte) && (hex_digit?(b) || b == UNDERSCORE)
          raise error("invalid hex number") if @pos == hex_start

          value = @input.byteslice(hex_start, @pos - hex_start).delete("_").to_i(16)
          return negative ? -value : value
        end
      elsif byte && byte >= 0x31 && byte <= NINE
        advance(1) while (b = byte) && ((b >= ZERO && b <= NINE) || b == UNDERSCORE)
      elsif byte == DOT
        # leading decimal handled below
      else
        raise error("invalid number")
      end

      is_float = false

      if byte == DOT
        is_float = true
        advance(1)
        advance(1) while (b = byte) && ((b >= ZERO && b <= NINE) || b == UNDERSCORE)
      end

      if (e = byte) == LOWER_E || e == UPPER_E
        is_float = true
        advance(1)
        advance(1) if (s = byte) == PLUS || s == MINUS
        raise error("invalid number: expected digits in exponent") unless byte && byte >= ZERO && byte <= NINE

        advance(1) while (b = byte) && ((b >= ZERO && b <= NINE) || b == UNDERSCORE)
      end

      slice = @input.byteslice(int_start, @pos - int_start).delete("_")
      value = is_float ? decimal_value(slice) : slice.to_i
      negative ? -value : value
    end

    def hex_digit?(b)
      (b >= ZERO && b <= NINE) ||
        (b >= 0x41 && b <= 0x46) ||
        (b >= 0x61 && b <= 0x66)
    end

    def consume_keyword!(word)
      word.bytesize.times do |i|
        raise error("invalid literal #{word.inspect}") unless byte_at(i) == word.getbyte(i)
      end
      advance(word.bytesize)
    end

    def parse_literal_keyword(word, value)
      consume_keyword!(word)
      value
    end

    # Report a non-fatal lenient fix to the on_warning callable. The call-site guards
    # (`if @on_warning`) keep the message string from being built on the fast path; this
    # internal guard is the safety net so a forgotten call-site guard can't crash a
    # handler-less caller.
    def warn(type, message)
      return unless @on_warning

      line, col = line_col_at(@pos)
      @on_warning.call(Warning.new(type, message, line, col))
    end

    def error(message)
      line, col = line_col_at(@pos)
      ParseError.new(message, line, col)
    end

    def display_byte(b)
      return "EOF" if b.nil?

      if b >= 0x20 && b < 0x7F
        "'#{b.chr}'"
      else
        format("0x%02X", b)
      end
    end
  end
end
