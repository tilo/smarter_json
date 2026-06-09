# frozen_string_literal: true

require "smarter_json"
require "tempfile"
require "stringio"

# The contract for SmarterJSON.foreach(source) — the streaming, composable sibling of
# process_file. `source` is a file path or an IO (StringIO / socket / open File). It
# mirrors the stdlib convention (CSV.foreach / File.foreach):
#
#   foreach(source)               -> a plain Enumerator over each top-level document
#   foreach(source) { |doc| ... } -> streams each document, returns the document count
#
# Eager    : process_file(path)  reads the whole file and returns an Array of documents.
# Streaming: foreach(path)       reads one document at a time from disk (never slurping
#            the whole file). The no-block form returns a plain Enumerator (NOT lazy),
#            so .map / .select return Arrays and .first(n) / .next stay bounded; add
#            .lazy at the call site for a chain that's bounded end to end.
RSpec.describe SmarterJSON, ".foreach" do
  let(:fixtures_dir) { File.expand_path("fixtures", __dir__) }
  let(:ndjson) { File.join(fixtures_dir, "multi_doc.ndjson") } # => [{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }]

  # Parity harness: every example runs on the C path and the pure-Ruby path.
  [true, false].each do |acceleration|
    context "acceleration: #{acceleration}" do
      it "without a block returns an Enumerator" do
        expect(SmarterJSON.foreach(ndjson, acceleration: acceleration)).to be_a(Enumerator)
      end

      it "returns a plain Enumerator (not lazy), so .map / .select return Arrays — like CSV.foreach" do
        enum = SmarterJSON.foreach(ndjson, acceleration: acceleration)
        expect(enum).not_to be_a(Enumerator::Lazy)
        mapped = SmarterJSON.foreach(ndjson, acceleration: acceleration).map { |doc| doc["id"] }
        expect(mapped).to be_a(Array) # not an Enumerator::Lazy needing .to_a / .force
        expect(mapped).to eq([1, 2, 3])
      end

      it "the Enumerator yields the same documents process_file returns (eager/lazy parity)" do
        eager = SmarterJSON.process_file(ndjson, acceleration: acceleration)
        lazy  = SmarterJSON.foreach(ndjson, acceleration: acceleration).to_a
        expect(lazy).to eq(eager)
        expect(lazy).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
      end

      it "with a block streams each document and returns the document count" do
        out = []
        rv = SmarterJSON.foreach(ndjson, acceleration: acceleration) { |doc| out << doc }
        expect(out).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
        expect(rv).to eq(out.length) # same return contract as process_file's block form
      end

      it "composes — select / map run over the stream" do
        ids = SmarterJSON.foreach(ndjson, acceleration: acceleration)
                         .select { |doc| doc["id"].odd? }
                         .map    { |doc| doc["id"] }
        expect(ids).to eq([1, 3])
      end

      it "supports external iteration with .next and raises StopIteration past the end" do
        enum = SmarterJSON.foreach(ndjson, acceleration: acceleration)
        expect(enum.next).to eq({ "id" => 1 })
        expect(enum.next).to eq({ "id" => 2 })
        expect(enum.next).to eq({ "id" => 3 })
        expect { enum.next }.to raise_error(StopIteration)
      end

      it "streams from disk instead of slurping the whole file (bounded memory)" do
        # The eager process_file loads the entire file with File.read; foreach must
        # not — it reads incrementally via File.open/readpartial, so a huge file costs
        # the same memory as a small one. Pin that mechanism: foreach yields every
        # document without ever calling File.read. (Eager and lazy return identical
        # documents — the parity test above — so the difference is memory, not result.)
        expect(File).not_to receive(:read)
        docs = SmarterJSON.foreach(ndjson, acceleration: acceleration).to_a
        expect(docs).to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
      end

      it "passes options through (symbolize_keys)" do
        docs = SmarterJSON.foreach(ndjson, symbolize_keys: true, acceleration: acceleration).to_a
        expect(docs).to eq([{ id: 1 }, { id: 2 }, { id: 3 }])
      end

      it "validates options eagerly (fails fast, before any iteration)" do
        expect { SmarterJSON.foreach(ndjson, bogus: 1, acceleration: acceleration) }
          .to raise_error(ArgumentError, /unknown option/)
      end

      it "yields nothing for an empty file" do
        Tempfile.create(["empty", ".ndjson"]) do |f|
          expect(SmarterJSON.foreach(f.path, acceleration: acceleration).to_a).to eq([])
          expect(SmarterJSON.foreach(f.path, acceleration: acceleration) { |_| }).to eq(0)
        end
      end

      it "yields a single document for a one-document file" do
        Tempfile.create(["one", ".ndjson"]) do |f|
          f.write(%({"only": true}))
          f.flush
          expect(SmarterJSON.foreach(f.path, acceleration: acceleration).to_a).to eq([{ "only" => true }])
        end
      end

      # foreach also accepts an IO (a socket, a StringIO, an open File) — the same
      # source process(io) { … } streams, but composable. A String argument is always
      # a path (like process_file); an IO is streamed directly.
      it "accepts an IO (StringIO) and yields each document" do
        io = StringIO.new(%({"id":1}\n{"id":2}\n{"id":3}\n))
        expect(SmarterJSON.foreach(io, acceleration: acceleration).to_a)
          .to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
      end

      it "streams an IO with a block and returns the document count" do
        io = StringIO.new(%({"a":1}\n{"b":2}\n))
        out = []
        rv = SmarterJSON.foreach(io, acceleration: acceleration) { |doc| out << doc }
        expect(out).to eq([{ "a" => 1 }, { "b" => 2 }])
        expect(rv).to eq(2)
      end

      it "composes (.select / .map) over an IO" do
        io = StringIO.new(%({"id":1}\n{"id":2}\n{"id":3}\n))
        odds = SmarterJSON.foreach(io, acceleration: acceleration).select { |d| d["id"].odd? }.map { |d| d["id"] }
        expect(odds).to eq([1, 3])
      end

      it "accepts an open File handle as an IO" do
        io = File.open(ndjson, "r:UTF-8")
        expect(SmarterJSON.foreach(io, acceleration: acceleration).to_a)
          .to eq([{ "id" => 1 }, { "id" => 2 }, { "id" => 3 }])
      ensure
        io&.close
      end

      it "an IO source is single-pass (an IO can only be read once)" do
        io = StringIO.new(%({"id":1}\n{"id":2}\n))
        enum = SmarterJSON.foreach(io, acceleration: acceleration)
        expect(enum.to_a).to eq([{ "id" => 1 }, { "id" => 2 }]) # first pass drains the IO
        expect(enum.to_a).to eq([]) # IO now at EOF — nothing left
      end
    end
  end
end
