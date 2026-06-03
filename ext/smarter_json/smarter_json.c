#include "smarter_json.h"
#include <math.h>
#include <string.h>
#ifdef __ARM_NEON
#include <arm_neon.h>
#endif
#include "vendor/ryu.h" /* Ryū string->double, correctly rounded (Ulf Adams, Apache-2.0) */

/* Branch hints / prefetch on the hot scan loops. No-ops on compilers without the
 * builtins (the code is correct either way; these only steer code layout). */
#if defined(__GNUC__) || defined(__clang__)
#  define FJ_LIKELY(x)   __builtin_expect(!!(x), 1)
#  define FJ_UNLIKELY(x) __builtin_expect(!!(x), 0)
#  define FJ_PREFETCH(p) __builtin_prefetch(p)
#else
#  define FJ_LIKELY(x)   (x)
#  define FJ_UNLIKELY(x) (x)
#  define FJ_PREFETCH(p) ((void)0)
#endif

/*
 * smarter_json C extension — self-contained parser (no callbacks into Ruby parse
 * logic). One entry point, SmarterJSON.parse_c (made private on the Ruby side).
 *
 * Covers strict JSON, JSON5, and the HJSON-inspired layer (quoteless strings
 * with recognized-literals-win classification, triple-quoted strings, implicit
 * root object, newline-as-separator, broader unquoted keys). The smarter_json
 * layer (smart quotes, Python literals, Unicode whitespace) is pure-Ruby only
 * for now; those acceleration:true parity specs stay red until ported here.
 */

static VALUE mSmarterJSON;
static VALUE cParseError;
static VALUE cEncodingError;
static VALUE cWarning;
static ID    fj_new_id;
static ID    fj_call_id;    /* cached :call (invoking the on_warning handler) */
static VALUE fj_sym_empty_slot;
static VALUE fj_sym_empty_value;
static VALUE fj_sym_duplicate_key;
static ID    fj_bigdecimal_id; /* cached BigDecimal() method id (set in Init) */
static ID    fj_to_sym_id;     /* cached :to_sym (symbolize_keys) */
static ID    fj_key_p_id;      /* cached :key? (non-default duplicate_key modes) */
static ID    fj_force_encoding_id;
static ID    fj_valid_encoding_p_id;
static ID    fj_encoding_id;
static ID    fj_name_id;
static VALUE fj_sym_encoding;
static VALUE fj_sym_symbolize_keys;
static VALUE fj_sym_first_wins;
static VALUE fj_sym_bigdecimal_load;
static VALUE fj_sym_float;
static VALUE fj_sym_bigdecimal;
static VALUE fj_sym_on_warning;

/* Per-parse direct-mapped key cache: key bytes -> the interned (frozen,
 * globally-rooted) String, so repeated keys skip the global fstring lookup.
 * Only used when rb_enc_interned_str is available — the cached strings are then
 * kept alive by the interned-string table, so the cache needs no GC marking. */
#define FJ_KCACHE_BITS 9
#define FJ_KCACHE_SIZE (1 << FJ_KCACHE_BITS)
typedef struct { long len; VALUE str; } fj_kc_slot;

typedef struct {
  const char *buf;
  long len;
  long pos;
  rb_encoding *enc;
  int depth;
  int symbolize_keys;
  int dup_first_wins;
  int bigdecimal_load;  /* 0 = float, 1 = auto, 2 = bigdecimal */
  fj_kc_slot *kcache;   /* per-parse key cache (NULL when interning unavailable) */
  VALUE on_warning;     /* on_warning: callable invoked per non-fatal lenient fix, else Qnil */
} fj_state;

/* Line/column at the current byte position, computed lazily (only when raising
 * an error) by scanning from the start of the buffer. CR, LF, and CRLF each
 * count as one newline; col is bytes since the last line start (1-based).
 * Keeping this off the hot path is the point — fj_advance never touches it. */
static void fj_line_col(fj_state *st, long *line, long *col) {
  long l = 1, c = 1, i;
  long limit = (st->pos < st->len) ? st->pos : st->len;
  for (i = 0; i < limit; i++) {
    unsigned char b = (unsigned char)st->buf[i];
    if (b == 0x0A) { l++; c = 1; }
    else if (b == 0x0D) { l++; c = 1; if (i + 1 < st->len && (unsigned char)st->buf[i + 1] == 0x0A) i++; }
    else c++;
  }
  *line = l;
  *col = c;
}

/* Report a non-fatal lenient fix to the on_warning callable — a no-op (and builds no
 * Warning) when no handler was given. The internal Qnil guard is the safety net; the
 * call sites also guard so the line/col scan is skipped on the fast path. */
static void fj_warn(fj_state *st, VALUE type_sym, const char *msg) {
  long line, col;
  if (st->on_warning == Qnil) return;
  fj_line_col(st, &line, &col);
  rb_funcall(st->on_warning, fj_call_id, 1,
             rb_funcall(cWarning, fj_new_id, 4, type_sym,
                        rb_utf8_str_new_cstr(msg), LONG2NUM(line), LONG2NUM(col)));
}

/* 1-based column of the current byte position (bytes since the last line start).
 * Used for triple-quoted indentation stripping (smarter_json.md §2.3). */
static long fj_column(fj_state *st) {
  long c = 1, i = st->pos - 1;
  while (i >= 0 && st->buf[i] != 0x0A && st->buf[i] != 0x0D) { c++; i--; }
  return c;
}

/* Construct SmarterJSON::ParseError(message, line, col) and raise it. */
NORETURN(static void fj_error(fj_state *st, const char *msg));
static void fj_error(fj_state *st, const char *msg) {
  long line, col;
  VALUE exc;
  fj_line_col(st, &line, &col);
  exc = rb_funcall(cParseError, rb_intern("new"), 3,
                   rb_str_new_cstr(msg), LONG2NUM(line), LONG2NUM(col));
  rb_exc_raise(exc);
}

static int fj_byte(fj_state *st) {
  return (st->pos < st->len) ? (unsigned char)st->buf[st->pos] : -1;
}

static int fj_byte_at(fj_state *st, long off) {
  long p = st->pos + off;
  return (p >= 0 && p < st->len) ? (unsigned char)st->buf[p] : -1;
}

static int fj_eof(fj_state *st) { return st->pos >= st->len; }

/* Advance the byte cursor by n (clamped to EOF). No line/col bookkeeping — that
 * is computed lazily in fj_line_col only when an error is raised. */
static void fj_advance(fj_state *st, long n) {
  st->pos += n;
  if (st->pos > st->len) st->pos = st->len;
}

/* ASCII whitespace: space, or 0x09..0x0D (tab, LF, VT, FF, CR). */
static int fj_is_ws(int b) { return b == 0x20 || (b >= 0x09 && b <= 0x0D); }

/* Length (1..3) of the Unicode whitespace char starting at p (n bytes
 * available), or 0. Matches Ruby's [[:space:]]; see smarter_json.md §4.7.
 * Reject-gate: only C2/E1/E2/E3 can begin a whitespace char. */
static long fj_mbws(const char *p, long n) {
  int b0, b1, b2;
  if (n < 1) return 0;
  b0 = (unsigned char)p[0];
  if (b0 != 0xC2 && (b0 < 0xE1 || b0 > 0xE3)) return 0;
  if (n < 2) return 0;
  b1 = (unsigned char)p[1];
  if (b0 == 0xC2) return (b1 == 0xA0 || b1 == 0x85) ? 2 : 0;
  if (n < 3) return 0;
  b2 = (unsigned char)p[2];
  if (b0 == 0xE1) return (b1 == 0x9A && b2 == 0x80) ? 3 : 0;
  if (b0 == 0xE2) {
    if (b1 == 0x80 && ((b2 >= 0x80 && b2 <= 0x8A) || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF)) return 3;
    if (b1 == 0x81 && b2 == 0x9F) return 3;
    return 0;
  }
  if (b0 == 0xE3) return (b1 == 0x80 && b2 == 0x80) ? 3 : 0;
  return 0;
}

static void fj_skip_pure_ws(fj_state *st) {
  for (;;) {
    int b = fj_byte(st);
    if (b == -1) break;
    if (fj_is_ws(b)) {
      fj_advance(st, 1);
    } else if (b >= 0x80) {
      long m = fj_mbws(st->buf + st->pos, st->len - st->pos);
      if (m == 0) break;
      st->pos += m;
    } else {
      break;
    }
  }
}

/* A comment marker only starts a comment when preceded by whitespace or at the
 * very start of input (the comment-marker rule). */
static int fj_preceded_by_ws_or_start(fj_state *st) {
  long i, m;
  unsigned char prev;
  if (st->pos == 0) return 1;
  prev = (unsigned char)st->buf[st->pos - 1];
  if (fj_is_ws(prev)) return 1;
  if (prev < 0x80) return 0;
  i = st->pos - 1; /* back up to the lead byte of a multibyte char */
  while (i > 0 && ((unsigned char)st->buf[i] & 0xC0) == 0x80) i--;
  m = fj_mbws(st->buf + i, st->len - i);
  return (m > 0 && i + m == st->pos);
}

static void fj_skip_to_eol(fj_state *st) {
  int b;
  while ((b = fj_byte(st)) != -1 && b != 0x0A && b != 0x0D) fj_advance(st, 1);
}

static void fj_skip_block_comment(fj_state *st) {
  fj_advance(st, 2); /* consume the opening slash-star */
  while (!fj_eof(st)) {
    if (fj_byte(st) == '*' && fj_byte_at(st, 1) == '/') { fj_advance(st, 2); return; }
    fj_advance(st, 1);
  }
  fj_error(st, "unterminated block comment");
}

static void fj_skip_ws_comments(fj_state *st) {
  for (;;) {
    int b, n;
    fj_skip_pure_ws(st);
    b = fj_byte(st);
    if (b == -1) return;
    n = fj_byte_at(st, 1);
    int is_marker = (b == '#') || (b == '/' && (n == '/' || n == '*'));
    if (!is_marker) return;
    if (!fj_preceded_by_ws_or_start(st)) return;
    if (b == '/' && n == '*') fj_skip_block_comment(st);
    else fj_skip_to_eol(st);
  }
}

/* forward declarations (mutual recursion) */
static VALUE fj_parse_value(fj_state *st);
static VALUE fj_parse_member_value(fj_state *st);

static void fj_append_utf8(VALUE buf, unsigned long cp) {
  char tmp[4];
  if (cp <= 0x7F) {
    tmp[0] = (char)cp; rb_str_buf_cat(buf, tmp, 1);
  } else if (cp <= 0x7FF) {
    tmp[0] = (char)(0xC0 | (cp >> 6));
    tmp[1] = (char)(0x80 | (cp & 0x3F));
    rb_str_buf_cat(buf, tmp, 2);
  } else if (cp <= 0xFFFF) {
    tmp[0] = (char)(0xE0 | (cp >> 12));
    tmp[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    tmp[2] = (char)(0x80 | (cp & 0x3F));
    rb_str_buf_cat(buf, tmp, 3);
  } else {
    tmp[0] = (char)(0xF0 | (cp >> 18));
    tmp[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    tmp[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    tmp[3] = (char)(0x80 | (cp & 0x3F));
    rb_str_buf_cat(buf, tmp, 4);
  }
}

static int fj_hex_val(int b) {
  if (b >= '0' && b <= '9') return b - '0';
  if (b >= 'a' && b <= 'f') return b - 'a' + 10;
  if (b >= 'A' && b <= 'F') return b - 'A' + 10;
  return -1;
}

static unsigned long fj_read_hex4(fj_state *st) {
  unsigned long v = 0;
  int i;
  for (i = 0; i < 4; i++) {
    int h = fj_hex_val(fj_byte(st));
    if (h < 0) fj_error(st, "invalid \\u escape");
    v = (v << 4) | (unsigned long)h;
    fj_advance(st, 1);
  }
  return v;
}

/* Scan [p, end) for the first `quote` or backslash; returns a pointer to it, or
 * `end` if neither occurs. NEON (16 bytes/iteration) on arm64, scalar elsewhere.
 * With lazy line/col the caller advances past the whole run in O(1). */
static const char *fj_scan_str(const char *p, const char *end, int quote) {
#ifdef __ARM_NEON
  const uint8x16_t vq  = vdupq_n_u8((uint8_t)quote);
  const uint8x16_t vbs = vdupq_n_u8('\\');
  while (p + 16 <= end) {
    uint8x16_t chunk = vld1q_u8((const uint8_t *)p);
    uint8x16_t m     = vorrq_u8(vceqq_u8(chunk, vq), vceqq_u8(chunk, vbs));
    /* movemask emulation (Oj's technique): pack to 4 bits/byte, then ctz/4. */
    uint8x8_t  res   = vshrn_n_u16(vreinterpretq_u16_u8(m), 4);
    uint64_t   mask  = vget_lane_u64(vreinterpret_u64_u8(res), 0);
    if (FJ_UNLIKELY(mask != 0)) {  /* most 16-byte chunks contain no quote/backslash */
      mask &= 0x8888888888888888ull;
      return p + (__builtin_ctzll(mask) >> 2);
    }
    FJ_PREFETCH(p + 64);
    p += 16;
  }
#endif
  for (; p < end; p++) {
    if (*p == (char)quote || *p == '\\') return p;
  }
  return end;
}

static VALUE fj_parse_string(fj_state *st, int quote) {
  long start;
  VALUE buf;
  int b;
  const char *hit;
  fj_advance(st, 1); /* opening quote */
  start = st->pos;
  /* Fast scan to the closing quote or the first backslash. */
  hit = fj_scan_str(st->buf + st->pos, st->buf + st->len, quote);
  fj_advance(st, hit - (st->buf + st->pos));
  b = fj_byte(st);
  if (FJ_LIKELY(b == quote)) {  /* common case: a string with no escapes */
    VALUE s = rb_enc_str_new(st->buf + start, st->pos - start, st->enc);
    fj_advance(st, 1);
    return s;
  }
  if (FJ_UNLIKELY(b == -1)) fj_error(st, "unterminated string");

  buf = rb_str_buf_new(st->pos - start + 16);
  rb_enc_associate(buf, rb_ascii8bit_encoding());
  if (st->pos > start) rb_str_buf_cat(buf, st->buf + start, st->pos - start);

  while ((b = fj_byte(st)) != -1) {
    if (b == quote) {
      fj_advance(st, 1);
      rb_enc_associate(buf, st->enc);
      return buf;
    } else if (b == '\\') {
      int e;
      fj_advance(st, 1);
      e = fj_byte(st);
      if (e == -1) fj_error(st, "unterminated string escape");
      switch (e) {
        case '"':  rb_str_buf_cat(buf, "\"", 1); fj_advance(st, 1); break;
        case '\'': rb_str_buf_cat(buf, "'", 1);  fj_advance(st, 1); break;
        case '\\': rb_str_buf_cat(buf, "\\", 1); fj_advance(st, 1); break;
        case '/':  rb_str_buf_cat(buf, "/", 1);  fj_advance(st, 1); break;
        case 'b':  rb_str_buf_cat(buf, "\b", 1); fj_advance(st, 1); break;
        case 'f':  rb_str_buf_cat(buf, "\f", 1); fj_advance(st, 1); break;
        case 'n':  rb_str_buf_cat(buf, "\n", 1); fj_advance(st, 1); break;
        case 'r':  rb_str_buf_cat(buf, "\r", 1); fj_advance(st, 1); break;
        case 't':  rb_str_buf_cat(buf, "\t", 1); fj_advance(st, 1); break;
        case 0x0A: fj_advance(st, 1); break; /* \<LF>: line continuation */
        case 0x0D: fj_advance(st, 1); if (fj_byte(st) == 0x0A) fj_advance(st, 1); break;
        case 'u': {
          unsigned long cp;
          fj_advance(st, 1);
          cp = fj_read_hex4(st);
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            unsigned long lo;
            if (fj_byte(st) != '\\' || fj_byte_at(st, 1) != 'u') {
              fj_error(st, "unpaired high surrogate in string");
            }
            fj_advance(st, 2);
            lo = fj_read_hex4(st);
            if (lo < 0xDC00 || lo > 0xDFFF) fj_error(st, "invalid low surrogate value");
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          }
          fj_append_utf8(buf, cp);
          break;
        }
        default:
          fj_error(st, "invalid escape");
      }
    } else {
      /* Literal run between escapes: NEON-scan to the next quote/backslash and
       * bulk-copy the whole run in one rb_str_buf_cat, rather than byte by byte. */
      const char *p0 = st->buf + st->pos;
      const char *h  = fj_scan_str(p0, st->buf + st->len, quote);
      rb_str_buf_cat(buf, p0, h - p0);
      fj_advance(st, h - p0);
    }
  }
  fj_error(st, "unterminated string");
  return Qnil; /* unreachable */
}

static void fj_consume_keyword(fj_state *st, const char *word) {
  long n = (long)strlen(word), i;
  for (i = 0; i < n; i++) {
    if (fj_byte_at(st, i) != (unsigned char)word[i]) fj_error(st, "invalid literal");
  }
  fj_advance(st, n);
}

/* Copy a byte range into a fresh String, dropping underscores. Copies whole
 * underscore-free runs in bulk, rather than one byte at a time. */
static VALUE fj_strip_underscores(const char *p, long n) {
  VALUE s = rb_str_buf_new(n);
  long i = 0;
  while (i < n) {
    long start = i;
    while (i < n && p[i] != '_') i++;
    if (i > start) rb_str_buf_cat(s, p + start, i - start);
    if (i < n) i++; /* skip '_' */
  }
  return s;
}

/* Significant mantissa digits in the token [p, p+n) (leading zeros excluded,
 * trailing zeros and the fraction included; exponent and underscores excluded)
 * — Oj's dec_cnt + 1. */
static long fj_sig_digits(const char *p, long n) {
  long i, cnt = 0;
  int started = 0;
  for (i = 0; i < n; i++) {
    char c = p[i];
    if (c == 'e' || c == 'E') break;
    if (c >= '0' && c <= '9') {
      if (!started) { if (c != '0') { started = 1; cnt = 1; } }
      else cnt++;
    }
  }
  return cnt;
}

/* A decimal token can go straight to BigDecimal() unchanged unless it has an
 * underscore (smarter_json leniency) or a dot that BigDecimal() rejects: a leading
 * dot (".5") or a dot not followed by a digit ("5.", "5.e3"). */
static int fj_decimal_is_clean(const char *p, long n) {
  long i = 0;
  if (memchr(p, '_', (size_t)n) != NULL) return 0;
  if (i < n && (p[i] == '-' || p[i] == '+')) i++;
  if (i < n && p[i] == '.') return 0;
  for (; i < n; i++) {
    if (p[i] == '.') {
      char nx = (i + 1 < n) ? p[i + 1] : '\0';
      if (nx < '0' || nx > '9') return 0;
    }
  }
  return 1;
}

/* Build a BigDecimal from a decimal token. Fast path (the common case): the raw
 * token bytes go straight to BigDecimal() via the cached method id — the same
 * shape Oj uses, no normalization, no extra allocation beyond the String. Only
 * when the token has an underscore or a bare/trailing dot do we clean it, in a
 * single C pass (no per-byte rb_str appends), then one rb_str_new. The grammar
 * was already validated by the caller, so BigDecimal() can't raise on a clean
 * token — no rescue frame (one fewer than Oj). */
static VALUE fj_to_bigdecimal_token(const char *p, long n) {
  char  stack[64];
  char *buf;
  long  i = 0, w = 0;
  VALUE s;

  if (fj_decimal_is_clean(p, n)) {
    return rb_funcall(rb_cObject, fj_bigdecimal_id, 1, rb_str_new(p, n));
  }

  buf = (n + 2 <= (long)sizeof(stack)) ? stack : ruby_xmalloc((size_t)(n + 2));
  if (i < n && (p[i] == '-' || p[i] == '+')) buf[w++] = p[i++];
  if (i < n && p[i] == '.') buf[w++] = '0';                    /* ".5" -> "0.5" */
  for (; i < n; i++) {
    if (p[i] == '_') continue;
    buf[w++] = p[i];
    if (p[i] == '.') {
      char nx = (i + 1 < n) ? p[i + 1] : '\0';
      if (nx == 'e' || nx == 'E' || nx == '\0') buf[w++] = '0'; /* "5." -> "5.0" */
    }
  }
  s = rb_str_new(buf, w);
  if (buf != stack) ruby_xfree(buf);
  return rb_funcall(rb_cObject, fj_bigdecimal_id, 1, s);
}

/* Shared conversion tail: turn the parts extracted during a scan into a Ruby
 * value. Both fj_parse_number (strict-position scan) and fj_try_decimal
 * (quoteless path) call these, so the Integer/Float a token produces is identical
 * no matter which path scanned it. [p, n) is the raw token slice (with any sign),
 * needed only by the bignum / strtod fallbacks. */
static VALUE fj_int_from_parts(uint64_t m, int digits, int neg, int overflow, const char *p, long n) {
  if (!overflow && digits >= 1 && digits <= 18) {
    int64_t v = (int64_t)m;
    return LL2NUM(neg ? -v : v);
  }
  /* >18 digits (may exceed int64) -> bignum from the slice. */
  if (memchr(p, '_', (size_t)n) == NULL) return rb_cstr_to_inum(p, 10, 0);
  return rb_str_to_inum(fj_strip_underscores(p, n), 10, 0);
}

/* e10 is the final base-10 exponent (already adjusted by the fraction length). */
static VALUE fj_float_from_parts(uint64_t m10, int m10digits, int64_t e10, int neg, int overflow, const char *p, long n) {
  /* Ryū fast path: <=17 mantissa digits and not in the subnormal range. */
  if (!overflow && m10digits >= 1 && m10digits <= 17 && (long)m10digits + e10 >= -307) {
    if (m10 == 0) return rb_float_new(neg ? -0.0 : 0.0);
    return rb_float_new(ryu_s2d_from_parts(m10, m10digits, (int32_t)e10, neg != 0));
  }
  /* Fallback for >17 digits / extreme or subnormal exponents. */
  if (memchr(p, '_', (size_t)n) == NULL) return rb_float_new(rb_cstr_to_dbl(p, 0));
  return rb_float_new(rb_str_to_dbl(fj_strip_underscores(p, n), 0));
}

/* Scan an already-bounded quoteless token [p, p+n) exactly once: validate it as a
 * JSON5 decimal *and* extract the mantissa/exponent in the same pass, then build
 * the value through the shared fj_*_from_parts helpers. Returns 1 (and sets *out)
 * for a valid number; returns 0 when the token is not a number, so the caller can
 * keep it as a quoteless string. This replaces the old validate-then-convert
 * sequence (fj_validate_decimal + fj_decimal_value/fj_int_value), which scanned
 * the token three-plus times. The accept/reject grammar matches the old
 * fj_validate_decimal exactly. (+Infinity/-Infinity and hex are handled by the
 * caller before this point, so they never reach here.) The digit runs skip the
 * per-byte '_' test, dropping to a slow step only when an underscore appears. */
static int fj_try_decimal(fj_state *st, const char *p, long n, VALUE *out) {
  long i = 0;
  int  is_float = 0, neg = 0, has_digit = 0, overflow = 0;
  uint64_t m10 = 0;
  int  m10digits = 0, frac = 0;
  int64_t e10 = 0;

  if (i < n && (p[i] == '-' || p[i] == '+')) { neg = (p[i] == '-'); i++; }

  /* Integer part: a single '0', or [1-9] then digits/underscores. */
  if (i < n && p[i] == '0') {
    has_digit = 1; m10digits = 1; i++;
  } else if (i < n && p[i] >= '1' && p[i] <= '9') {
    has_digit = 1;
    for (;;) {
      while (i < n && p[i] >= '0' && p[i] <= '9') {
        if (m10digits < 18) { m10 = m10 * 10 + (uint64_t)(p[i] - '0'); m10digits++; }
        else overflow = 1;
        i++;
      }
      if (i < n && p[i] == '_') { i++; continue; }  /* slow step: underscores are rare */
      break;
    }
  }

  /* Fraction. */
  if (i < n && p[i] == '.') {
    is_float = 1; i++;
    for (;;) {
      while (i < n && p[i] >= '0' && p[i] <= '9') {
        has_digit = 1;
        if (m10digits < 18) { m10 = m10 * 10 + (uint64_t)(p[i] - '0'); m10digits++; frac++; }
        else overflow = 1;
        i++;
      }
      if (i < n && p[i] == '_') { i++; continue; }
      break;
    }
  }

  /* Exponent: [eE] [+-]? then digits/underscores (at least one required). */
  if (i < n && (p[i] == 'e' || p[i] == 'E')) {
    long es;
    int eneg = 0;
    is_float = 1; i++;
    if (i < n && (p[i] == '-' || p[i] == '+')) { eneg = (p[i] == '-'); i++; }
    es = i;
    while (i < n && ((p[i] >= '0' && p[i] <= '9') || p[i] == '_')) {
      if (p[i] != '_' && !overflow) {
        e10 = e10 * 10 + (p[i] - '0');
        if (e10 > 1000000) overflow = 1;  /* extreme exponent -> strtod fallback on the slice */
      }
      i++;
    }
    if (i == es) return 0;  /* 'e' with no exponent digits -> not a number */
    if (eneg) e10 = -e10;
  }

  if (i != n)     return 0;  /* token not fully consumed -> not a number (string) */
  if (!has_digit) return 0;  /* e.g. "." or "+" -> not a number (string) */

  if (!is_float) {
    *out = fj_int_from_parts(m10, m10digits, neg, overflow, p, n);
    return 1;
  }
  e10 -= frac;
  /* :bigdecimal always; :auto only when significant digits > 16. m10digits is >=
   * the significant-digit count, so m10digits <= 16 skips the fj_sig_digits scan. */
  if (st->bigdecimal_load == 2 ||
      (st->bigdecimal_load == 1 && m10digits > 16 && fj_sig_digits(p, n) > 16)) {
    *out = fj_to_bigdecimal_token(p, n);
  } else {
    *out = fj_float_from_parts(m10, m10digits, e10, neg, overflow, p, n);
  }
  return 1;
}

/* Top-level / strict-position number (JSON5 grammar). Single pass: the scan that
 * finds the token boundary also accumulates the mantissa/exponent, so the common
 * integer/float case never re-reads the token (no second extraction pass, and no
 * separate fj_sig_digits pass). Scanning is a raw pointer loop that relies on the
 * RSTRING_PTR NUL terminator as a sentinel — no per-byte bounds check — and the
 * digit runs skip the per-byte '_' test (the leniency tax), dropping to a slow
 * step only when an underscore actually appears. The extracted parts go through
 * the same fj_*_from_parts helpers the quoteless path uses, so a token produces
 * the identical Ruby value no matter which path scanned it. */
static VALUE fj_parse_number(fj_state *st) {
  const char *buf = st->buf;
  const char *p   = buf + st->pos;  /* buf[len] == '\0' (RSTRING_PTR) is the scan sentinel */
  const char *np  = p;              /* token start, includes a leading sign */
  long   nlen;
  int    is_float = 0, neg = 0, overflow = 0;
  uint64_t m10 = 0;                 /* mantissa: integer + fraction digits */
  int    m10digits = 0;             /* mantissa digit chars (caps the Ryū fast path at 17) */
  int    frac = 0;                  /* fraction digit chars: e10 -= frac */
  int64_t e10 = 0;

  if (*p == '-' || *p == '+') { neg = (*p == '-'); p++; }

  /* Cold branches (rare, not perf-critical): sync the cursor, reuse scalar helpers. */
  if (*p == 'I') { st->pos = p - buf; fj_consume_keyword(st, "Infinity"); return rb_float_new(neg ? -INFINITY : INFINITY); }
  if (*p == 'N') { st->pos = p - buf; fj_consume_keyword(st, "NaN");      return rb_float_new(NAN); }
  if (*p == '0' && (p[1] == 'x' || p[1] == 'X')) {
    const char *hs, *q;
    VALUE hx;
    p += 2;
    hs = p;
    while (fj_hex_val((unsigned char)*p) >= 0 || *p == '_') p++;
    if (p == hs) { st->pos = p - buf; fj_error(st, "invalid hex number"); }
    hx = rb_str_buf_new(16);
    if (neg) rb_str_buf_cat(hx, "-", 1);
    for (q = hs; q < p; q++) if (*q != '_') rb_str_buf_cat(hx, q, 1);
    st->pos = p - buf;
    return rb_str_to_inum(hx, 16, 0);
  }

  /* Integer part: a single '0', or [1-9] then digits/underscores. */
  if (*p == '0') {
    m10digits = 1;  /* one leading zero, counted as a single mantissa digit */
    p++;
  } else if (*p >= '1' && *p <= '9') {
    for (;;) {
      while (*p >= '0' && *p <= '9') {
        if (m10digits < 18) { m10 = m10 * 10 + (uint64_t)(*p - '0'); m10digits++; }
        else overflow = 1;
        p++;
      }
      if (*p == '_') { p++; continue; }  /* slow step: underscores are rare */
      break;
    }
  } else if (*p == '.') {
    /* leading decimal point: no integer part */
  } else {
    st->pos = p - buf;
    fj_error(st, "invalid number");
  }

  /* Fraction. */
  if (*p == '.') {
    is_float = 1;
    p++;
    for (;;) {
      while (*p >= '0' && *p <= '9') {
        if (m10digits < 18) { m10 = m10 * 10 + (uint64_t)(*p - '0'); m10digits++; frac++; }
        else overflow = 1;
        p++;
      }
      if (*p == '_') { p++; continue; }
      break;
    }
  }

  /* Exponent. */
  if (*p == 'e' || *p == 'E') {
    int eneg = 0;
    is_float = 1;
    p++;
    if (*p == '-' || *p == '+') { eneg = (*p == '-'); p++; }
    if (!(*p >= '0' && *p <= '9')) { st->pos = p - buf; fj_error(st, "invalid number: expected digits in exponent"); }
    while ((*p >= '0' && *p <= '9') || *p == '_') {
      if (*p != '_' && !overflow) {
        e10 = e10 * 10 + (*p - '0');
        if (e10 > 1000000) overflow = 1;  /* extreme exponent -> strtod fallback on the slice */
      }
      p++;
    }
    if (eneg) e10 = -e10;
  }

  st->pos = p - buf;
  nlen = p - np;

  if (!is_float) {
    return fj_int_from_parts(m10, m10digits, neg, overflow, np, nlen);
  }
  e10 -= frac;
  /* BigDecimal decision (same rule as fj_try_decimal): :bigdecimal always; :auto only
   * when significant digits > 16. Since m10digits >= significant digits, m10digits
   * <= 16 guarantees not-BigDecimal and lets us skip the fj_sig_digits scan
   * entirely (the common case — e.g. every coordinate in canada.json). */
  if (st->bigdecimal_load == 2 ||
      (st->bigdecimal_load == 1 && m10digits > 16 && fj_sig_digits(np, nlen) > 16)) {
    return fj_to_bigdecimal_token(np, nlen);
  }
  return fj_float_from_parts(m10, m10digits, e10, neg, overflow, np, nlen);
}

static VALUE fj_parse_literal(fj_state *st, const char *word, VALUE value) {
  fj_consume_keyword(st, word);
  return value;
}

static int fj_is_key_start(int b) {
  return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || b == '_' || b == '$';
}

static int fj_is_key_continue(int b) {
  return fj_is_key_start(b) || (b >= '0' && b <= '9') || b == '-';
}

/* Intern an object key (frozen, deduplicated) so repeated keys across records
 * share one String and skip a per-occurrence allocation. On Ruby < 3.0 (no
 * rb_enc_interned_str) this falls back to a plain string — Hash#[]= still dedups
 * the key on store, just without saving the allocation. Keys only: values are
 * rarely repeated, so interning them wouldn't pay off (this matches Oj). */
static inline VALUE fj_key_str(fj_state *st, const char *p, long n) {
#ifdef HAVE_RB_ENC_INTERNED_STR
  if (st->kcache != NULL) {
    uint64_t    h = 1469598103934665603ULL; /* FNV-1a over the key bytes */
    long        i;
    fj_kc_slot *slot;
    for (i = 0; i < n; i++) { h ^= (unsigned char)p[i]; h *= 1099511628211ULL; }
    slot = &st->kcache[(size_t)((h ^ (h >> FJ_KCACHE_BITS)) & (FJ_KCACHE_SIZE - 1))];
    if (slot->str != Qfalse && slot->len == n &&
        memcmp(RSTRING_PTR(slot->str), p, (size_t)n) == 0) {
      return slot->str; /* hit — skip the global fstring lookup */
    }
    slot->str = rb_enc_interned_str(p, n, st->enc);
    slot->len = n;
    return slot->str;
  }
  return rb_enc_interned_str(p, n, st->enc);
#else
  return rb_enc_str_new(p, n, st->enc);
#endif
}

static VALUE fj_parse_identifier_key(fj_state *st) {
  long start = st->pos;
  int b;
  fj_advance(st, 1);
  while ((b = fj_byte(st)) != -1 && fj_is_key_continue(b)) fj_advance(st, 1);
  return fj_key_str(st, st->buf + start, st->pos - start);
}

static VALUE fj_parse_object_key(fj_state *st) {
  int b = fj_byte(st);

  /* Quoted key. The common case has no escapes: intern straight from the buffer
   * with no throwaway allocation. An escaped key (rare) falls through to the
   * full string parser; Hash#[]= still dedups it on store. */
  if (b == '"' || b == '\'') {
    long i = st->pos + 1;
    while (i < st->len) {
      char c = st->buf[i];
      if (c == (char)b) {
        long  cstart = st->pos + 1;
        VALUE k      = fj_key_str(st, st->buf + cstart, i - cstart);
        fj_advance(st, i - st->pos + 1); /* consume opening quote .. closing quote */
        return k;
      }
      if (c == '\\') break;
      i++;
    }
    return fj_parse_string(st, b);
  }

  if (fj_is_key_start(b)) return fj_parse_identifier_key(st);

  fj_error(st, "expected a key");
  return Qnil; /* unreachable */
}

/* --- quoteless classification (recognized-literals-win), pure C --- */

static int fj_tok_eq(const char *p, long n, const char *word) {
  long wl = (long)strlen(word);
  return n == wl && memcmp(p, word, (size_t)n) == 0;
}

static int fj_is_hex_token(const char *p, long n) {
  long i = 0, hs;
  if (i < n && (p[i] == '-' || p[i] == '+')) i++;
  if (i + 1 < n && p[i] == '0' && (p[i + 1] == 'x' || p[i + 1] == 'X')) i += 2; else return 0;
  hs = i;
  while (i < n && (fj_hex_val((unsigned char)p[i]) >= 0 || p[i] == '_')) i++;
  if (i == hs) return 0;
  return i == n;
}

static VALUE fj_classify_quoteless(fj_state *st, const char *p0, long n0) {
  const char *p = p0;
  long n = n0;
  int c0;
  /* trim leading/trailing whitespace (ASCII or multibyte Unicode) */
  for (;;) {
    if (n > 0 && fj_is_ws((unsigned char)p[0])) { p++; n--; continue; }
    if (n > 0 && (unsigned char)p[0] >= 0x80) {
      long m = fj_mbws(p, n);
      if (m > 0) { p += m; n -= m; continue; }
    }
    break;
  }
  for (;;) {
    if (n > 0 && fj_is_ws((unsigned char)p[n - 1])) { n--; continue; }
    if (n > 0 && (unsigned char)p[n - 1] >= 0x80) {
      long j = n - 1;
      while (j > 0 && ((unsigned char)p[j] & 0xC0) == 0x80) j--;
      long m = fj_mbws(p + j, n - j);
      if (m > 0 && j + m == n) { n = j; continue; }
    }
    break;
  }

  /* Dispatch on the first byte: a digit or '.' can only be a number or a
   * string (no named literal starts that way), so we skip the literal
   * comparisons entirely. '+'/'-' can additionally be ±Infinity. Letters fall
   * through to the literal checks. */
  c0 = (n > 0) ? (unsigned char)p[0] : 0;

  if ((c0 >= '0' && c0 <= '9') || c0 == '.' || c0 == '-' || c0 == '+') {
    if (c0 == '+' && fj_tok_eq(p, n, "+Infinity")) return rb_float_new(INFINITY);
    if (c0 == '-' && fj_tok_eq(p, n, "-Infinity")) return rb_float_new(-INFINITY);
    if (fj_is_hex_token(p, n)) {
      long i = 0;
      int neg = 0;
      VALUE hx;
      if (p[i] == '-' || p[i] == '+') { neg = (p[i] == '-'); i++; }
      i += 2; /* skip 0x */
      hx = rb_str_buf_new(n);
      if (neg) rb_str_buf_cat(hx, "-", 1);
      for (; i < n; i++) if (p[i] != '_') rb_str_buf_cat(hx, p + i, 1);
      return rb_str_to_inum(hx, 16, 0);
    }
    {
      VALUE num;
      if (fj_try_decimal(st, p, n, &num)) return num;
    }
    return rb_enc_str_new(p, n, st->enc);
  }

  if (fj_tok_eq(p, n, "true")  || fj_tok_eq(p, n, "True"))  return Qtrue;
  if (fj_tok_eq(p, n, "false") || fj_tok_eq(p, n, "False")) return Qfalse;
  if (fj_tok_eq(p, n, "null")  || fj_tok_eq(p, n, "None") || fj_tok_eq(p, n, "undefined")) return Qnil;
  if (fj_tok_eq(p, n, "NaN")) return rb_float_new(NAN);
  if (fj_tok_eq(p, n, "Infinity")) return rb_float_new(INFINITY);

  return rb_enc_str_new(p, n, st->enc);
}

/* Quoteless single-line string: scan to a delimiter (structural punctuation,
 * newline, EOF, or a whitespace-preceded comment marker), then classify. */
/* Per-byte classes for the quoteless-token boundary scan. ASCII only; bytes
 * >= 0x80 are handled separately (possible multibyte whitespace). LF/CR are
 * TERM, not WS — they end the token, matching the old terminator check that ran
 * before the whitespace check. */
enum { FJ_QL_ORD = 0, FJ_QL_TERM, FJ_QL_WS, FJ_QL_CMT };
static const unsigned char fj_ql_class[256] = {
  [','] = FJ_QL_TERM, ['}'] = FJ_QL_TERM, [']'] = FJ_QL_TERM,
  [0x0A] = FJ_QL_TERM, [0x0D] = FJ_QL_TERM,
  [0x09] = FJ_QL_WS, [0x0B] = FJ_QL_WS, [0x0C] = FJ_QL_WS, [' '] = FJ_QL_WS,
  ['#'] = FJ_QL_CMT, ['/'] = FJ_QL_CMT,
};

static VALUE fj_parse_quoteless_or_literal(fj_state *st) {
  long start = st->pos;
  int prev_ws = 0, b, nx;
  for (;;) {
    b = fj_byte(st);
    if (b == -1) break;
    if (b >= 0x80) {  /* possible multibyte whitespace */
      long m = fj_mbws(st->buf + st->pos, st->len - st->pos);
      if (m > 0) { prev_ws = 1; st->pos += m; }
      else { prev_ws = 0; fj_advance(st, 1); }
      continue;
    }
    /* One table lookup classifies the byte; the common ordinary byte takes the
     * fast path with no further comparisons and no lookahead read. */
    {
      unsigned char cls = fj_ql_class[b];
      if (FJ_LIKELY(cls == FJ_QL_ORD)) { prev_ws = 0; fj_advance(st, 1); continue; }
      if (cls == FJ_QL_TERM) break;
      if (cls == FJ_QL_WS) { prev_ws = 1; fj_advance(st, 1); continue; }
      /* FJ_QL_CMT: '#' or '/' — a comment marker only when preceded by whitespace.
       * The lookahead byte (nx) is read only here, not on every byte. */
      if (prev_ws) {
        if (b == '#') break;
        nx = fj_byte_at(st, 1);
        if (nx == '/' || nx == '*') break;  /* b == '/' */
      }
      prev_ws = 0;
      fj_advance(st, 1);
    }
  }
  return fj_classify_quoteless(st, st->buf + start, st->pos - start);
}

/* --- triple-quoted strings (pure C, mirroring strip_triple) --- */

static VALUE fj_strip_indent(VALUE line, long indent, rb_encoding *enc) {
  const char *p = RSTRING_PTR(line);
  long m = RSTRING_LEN(line), i = 0;
  while (i < indent && i < m && (p[i] == ' ' || p[i] == '\t')) i++;
  return rb_enc_str_new(p + i, m - i, enc);
}

static int fj_blank_line(VALUE line) {
  const char *p = RSTRING_PTR(line);
  long m = RSTRING_LEN(line), i;
  for (i = 0; i < m; i++) if (p[i] != ' ' && p[i] != '\t') return 0;
  return 1;
}

static VALUE fj_strip_triple(const char *p, long n, long indent, rb_encoding *enc) {
  VALUE lines = rb_ary_new();
  VALUE out, res;
  int leading_newline = (n > 0 && (p[0] == '\n' || p[0] == '\r'));
  long i = 0, lstart = 0, len, idx;

  while (i < n) {
    if (p[i] == '\n' || p[i] == '\r') {
      rb_ary_push(lines, rb_enc_str_new(p + lstart, i - lstart, enc));
      if (p[i] == '\r' && i + 1 < n && p[i + 1] == '\n') i++;
      i++;
      lstart = i;
    } else {
      i++;
    }
  }
  rb_ary_push(lines, rb_enc_str_new(p + lstart, n - lstart, enc));

  out = rb_ary_new();
  len = RARRAY_LEN(lines);
  for (idx = 0; idx < len; idx++) {
    VALUE line = rb_ary_entry(lines, idx);
    if (idx == 0) {
      if (leading_newline) continue;
      rb_ary_push(out, line);
    } else {
      rb_ary_push(out, fj_strip_indent(line, indent, enc));
    }
  }
  if (RARRAY_LEN(out) > 0 && fj_blank_line(rb_ary_entry(out, RARRAY_LEN(out) - 1))) {
    rb_ary_pop(out);
  }
  res = rb_ary_join(out, rb_str_new_cstr("\n"));
  rb_enc_associate(res, enc);
  return res;
}

static VALUE fj_parse_triple_quoted(fj_state *st) {
  long indent = fj_column(st) - 1;
  long raw_start;
  VALUE r;
  fj_advance(st, 3);
  raw_start = st->pos;
  while (!fj_eof(st)) {
    if (fj_byte(st) == '\'' && fj_byte_at(st, 1) == '\'' && fj_byte_at(st, 2) == '\'') break;
    fj_advance(st, 1);
  }
  if (fj_eof(st)) fj_error(st, "unterminated triple-quoted string");
  r = fj_strip_triple(st->buf + raw_start, st->pos - raw_start, indent, st->enc);
  fj_advance(st, 3);
  return r;
}

static VALUE fj_parse_single_or_triple(fj_state *st) {
  if (fj_byte_at(st, 1) == '\'' && fj_byte_at(st, 2) == '\'') return fj_parse_triple_quoted(st);
  return fj_parse_string(st, '\'');
}

/* Smart/curly quotes: U+201C/201D double (E2 80 9C/9D), U+2018/2019 single
 * (E2 80 98/99). Returns 2 (double), 1 (single), or 0. */
static int fj_smart_quote_kind(fj_state *st) {
  int b2;
  if (fj_byte(st) != 0xE2 || fj_byte_at(st, 1) != 0x80) return 0;
  b2 = fj_byte_at(st, 2);
  if (b2 == 0x9C || b2 == 0x9D) return 2;
  if (b2 == 0x98 || b2 == 0x99) return 1;
  return 0;
}

/* Content between smart quotes is literal (no escape processing); lenient
 * about open/close direction. */
static VALUE fj_parse_smart_string(fj_state *st, int kind) {
  long start;
  fj_advance(st, 3); /* opening smart quote */
  start = st->pos;
  while (!fj_eof(st)) {
    if (fj_byte(st) == 0xE2 && fj_byte_at(st, 1) == 0x80) {
      int b2 = fj_byte_at(st, 2);
      int closer = (kind == 2) ? (b2 == 0x9C || b2 == 0x9D) : (b2 == 0x98 || b2 == 0x99);
      if (closer) {
        VALUE s = rb_enc_str_new(st->buf + start, st->pos - start, st->enc);
        fj_advance(st, 3);
        return s;
      }
    }
    fj_advance(st, 1);
  }
  fj_error(st, "unterminated smart-quoted string");
  return Qnil; /* unreachable */
}

/* --- containers --- */

/* Value in object-value or array-element position (scalar only — containers
 * are handled by the iterative driver below). Quoteless allowed. Assumes the
 * caller has already skipped whitespace/comments and checked for EOF. */
/* Fast path for a plain decimal number in object-value / array-element position.
 * Scans a clean JSON5 decimal straight from the cursor in one pass and commits
 * ONLY when the number immediately abuts a value terminator (',', '}', ']',
 * newline, or EOF) — true for essentially all real JSON, where a number touches
 * its delimiter. On any deviation (trailing whitespace, a letter, a second '.',
 * '0x…', '±Infinity', …) it restores the cursor and returns 0, so the caller
 * falls back to the full quoteless scanner, which preserves every lenient rule
 * ("1 2 3" as a string, hex, Infinity). This bypasses the quoteless boundary scan
 * + classify dispatch (and the per-number Infinity/hex probes) for the common
 * case. Value construction goes through the same fj_*_from_parts helpers the
 * other number paths use, so results can't drift. Returns 1 and sets *out, or 0
 * with the cursor unchanged. */
static int fj_try_member_number(fj_state *st, VALUE *out) {
  const char *buf = st->buf;
  const char *p   = buf + st->pos;  /* RSTRING_PTR NUL terminator is the scan sentinel */
  const char *np  = p;
  long  nlen;
  int   is_float = 0, neg = 0, overflow = 0, t;
  uint64_t m10 = 0;
  int   m10digits = 0, frac = 0;
  int64_t e10 = 0;

  if (*p == '-' || *p == '+') { neg = (*p == '-'); p++; }
  /* Only a digit or '.' may open the numeric body; 'I'/'N'/etc. are left to the
   * quoteless path (it handles ±Infinity and quoteless strings). */
  if (!((*p >= '0' && *p <= '9') || *p == '.')) return 0;

  /* Integer part: a single '0', or [1-9] then digits/underscores. */
  if (*p == '0') {
    m10digits = 1; p++;
  } else if (*p >= '1' && *p <= '9') {
    for (;;) {
      while (*p >= '0' && *p <= '9') {
        if (FJ_LIKELY(m10digits < 18)) { m10 = m10 * 10 + (uint64_t)(*p - '0'); m10digits++; }
        else overflow = 1;
        p++;
      }
      if (*p == '_') { p++; continue; }
      break;
    }
  }

  /* Fraction. */
  if (*p == '.') {
    is_float = 1; p++;
    for (;;) {
      while (*p >= '0' && *p <= '9') {
        if (FJ_LIKELY(m10digits < 18)) { m10 = m10 * 10 + (uint64_t)(*p - '0'); m10digits++; frac++; }
        else overflow = 1;
        p++;
      }
      if (*p == '_') { p++; continue; }
      break;
    }
  }

  /* Exponent. */
  if (*p == 'e' || *p == 'E') {
    const char *es;
    int eneg = 0;
    is_float = 1; p++;
    if (*p == '-' || *p == '+') { eneg = (*p == '-'); p++; }
    es = p;
    while ((*p >= '0' && *p <= '9') || *p == '_') {
      if (*p != '_' && !overflow) { e10 = e10 * 10 + (*p - '0'); if (e10 > 1000000) overflow = 1; }
      p++;
    }
    if (p == es) return 0;       /* 'e' with no exponent digits -> let quoteless decide */
    if (eneg) e10 = -e10;
  }

  if (m10digits == 0) return 0;  /* e.g. "." or "+." -> not a number here */

  /* Commit only if the number abuts a value terminator; otherwise (whitespace,
   * letters, a second '.', "0x…", …) leave it to the quoteless scanner. */
  t = (unsigned char)*p;
  if (!(t == ',' || t == '}' || t == ']' || t == 0x0A || t == 0x0D || p == buf + st->len)) {
    return 0;
  }

  st->pos = p - buf;
  nlen = p - np;
  if (!is_float) {
    *out = fj_int_from_parts(m10, m10digits, neg, overflow, np, nlen);
    return 1;
  }
  e10 -= frac;
  if (st->bigdecimal_load == 2 ||
      (st->bigdecimal_load == 1 && m10digits > 16 && fj_sig_digits(np, nlen) > 16)) {
    *out = fj_to_bigdecimal_token(np, nlen);
  } else {
    *out = fj_float_from_parts(m10, m10digits, e10, neg, overflow, np, nlen);
  }
  return 1;
}

static VALUE fj_parse_member_value(fj_state *st) {
  int b = fj_byte(st);
  switch (b) {
    case '"':  return fj_parse_string(st, '"');
    case '\'': return fj_parse_single_or_triple(st);
    default: {
      int kind;
      if (b == '-' || b == '+' || b == '.' || (b >= '0' && b <= '9')) {
        VALUE num;
        if (fj_try_member_number(st, &num)) return num;
      }
      kind = fj_smart_quote_kind(st);
      if (kind) return fj_parse_smart_string(st, kind);
      return fj_parse_quoteless_or_literal(st);
    }
  }
}

/* Top-level / strict scalar (no quoteless; containers handled by the driver). */
static VALUE fj_parse_value(fj_state *st) {
  int b = fj_byte(st);
  switch (b) {
    case '"':  return fj_parse_string(st, '"');
    case '\'': return fj_parse_single_or_triple(st);
    case 't':  return fj_parse_literal(st, "true", Qtrue);
    case 'f':  return fj_parse_literal(st, "false", Qfalse);
    case 'n':  return fj_parse_literal(st, "null", Qnil);
    case 'T':  return fj_parse_literal(st, "True", Qtrue);
    case 'F':  return fj_parse_literal(st, "False", Qfalse);
    case 'u':  return fj_parse_literal(st, "undefined", Qnil);
    case 'N':  /* NaN (number) vs None (Python null) */
      if (fj_byte_at(st, 1) == 'a') return fj_parse_number(st);
      return fj_parse_literal(st, "None", Qnil);
    default:
      if (b == '-' || b == '+' || b == '.' || b == 'I' || (b >= '0' && b <= '9')) {
        return fj_parse_number(st);
      }
      {
        int kind = fj_smart_quote_kind(st);
        if (kind) return fj_parse_smart_string(st, kind);
      }
      fj_error(st, "unexpected character");
  }
  return Qnil; /* unreachable */
}

/* --- container building: pre-sized hash + bulk insert (json/Oj style) --- */

#ifndef HAVE_RB_HASH_NEW_CAPA
#define rb_hash_new_capa(n) rb_hash_new()
#endif

#ifndef HAVE_RB_HASH_BULK_INSERT
static void fj_hash_bulk_insert(long count, const VALUE *pairs, VALUE hash) {
  long i;
  for (i = 0; i + 1 < count; i += 2) rb_hash_aset(hash, pairs[i], pairs[i + 1]);
}
#define rb_hash_bulk_insert fj_hash_bulk_insert
#else
/* Ruby 2.6 *exports* rb_hash_bulk_insert as a symbol (so have_func / HAVE_* is set
 * and the shim above is skipped) but does NOT declare it in any public header. Modern
 * clang treats the resulting implicit call as a hard error, so declare the prototype
 * ourselves. On 2.7+ the header already declares it identically, which is harmless. */
void rb_hash_bulk_insert(long, const VALUE *, VALUE);
#endif

/* Build a Hash from `count` interleaved key,value slots. Fast path (String keys,
 * default :last_wins): pre-size + bulk insert. symbolize_keys / :first_wins use a
 * per-member loop into the same pre-sized hash. */
static VALUE fj_build_object(fj_state *st, const VALUE *pairs, long count) {
  long  entries = count / 2, i;
  VALUE hash    = rb_hash_new_capa(entries);

  /* Fast path: bulk insert. Skipped when an on_warning handler is present, which needs
   * the per-member loop below to report each dropped duplicate key. */
  if (!st->symbolize_keys && !st->dup_first_wins && st->on_warning == Qnil) {
    rb_hash_bulk_insert(count, pairs, hash);
    return hash;
  }

  for (i = 0; i + 1 < count; i += 2) {
    VALUE k = st->symbolize_keys ? rb_funcall(pairs[i], fj_to_sym_id, 0) : pairs[i];
    if (st->dup_first_wins || st->on_warning != Qnil) {
      if (RTEST(rb_funcall(hash, fj_key_p_id, 1, k))) {
        fj_warn(st, fj_sym_duplicate_key, "duplicate key");
        if (st->dup_first_wins) continue;
      }
    }
    rb_hash_aset(hash, k, pairs[i + 1]);
  }
  return hash;
}

/* --- working stacks: a GC-marked C value stack + a frame/mark stack ---
 * Pending values for not-yet-closed containers live on an explicit C array (not
 * a Ruby Array, so no Ruby-object op per value). Both buffers sit in one
 * TypedData object: GC marks the pending values via fj_pstack_mark, and frees
 * the buffers even if parsing raises mid-document. */
typedef struct { long mark; int is_obj; } fj_frame;

typedef struct {
  VALUE    *vptr;  long vhead;  long vcapa;  /* pending values (GC-marked) */
  fj_frame *fptr;  long fhead;  long fcapa;  /* open-container frames (no VALUEs) */
} fj_pstack;

static void fj_pstack_mark(void *p) {
  fj_pstack *ps = (fj_pstack *)p;
  long i;
  for (i = 0; i < ps->vhead; i++) rb_gc_mark(ps->vptr[i]);
}
static void fj_pstack_free(void *p) {
  fj_pstack *ps = (fj_pstack *)p;
  if (ps->vptr != NULL) xfree(ps->vptr);
  if (ps->fptr != NULL) xfree(ps->fptr);
  xfree(ps);
}
static size_t fj_pstack_memsize(const void *p) {
  const fj_pstack *ps = (const fj_pstack *)p;
  return sizeof(fj_pstack) + (size_t)ps->vcapa * sizeof(VALUE) + (size_t)ps->fcapa * sizeof(fj_frame);
}
static const rb_data_type_t fj_pstack_type = {
  "smarter_json/pstack",
  { fj_pstack_mark, fj_pstack_free, fj_pstack_memsize, },
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY,
};

static inline void fj_vpush(fj_pstack *ps, VALUE v) {
  if (ps->vhead >= ps->vcapa) { ps->vcapa *= 2; REALLOC_N(ps->vptr, VALUE, ps->vcapa); }
  ps->vptr[ps->vhead++] = v;
}
static inline void fj_fpush(fj_pstack *ps, long mark, int is_obj) {
  if (ps->fhead >= ps->fcapa) { ps->fcapa *= 2; REALLOC_N(ps->fptr, fj_frame, ps->fcapa); }
  ps->fptr[ps->fhead].mark   = mark;
  ps->fptr[ps->fhead].is_obj = is_obj;
  ps->fhead++;
}

/* Iterative container parser — no C recursion. Each container's members/elements
 * are collected on the value stack and built at its closing brace with a
 * pre-sized hash + bulk insert (objects) or rb_ary_new_from_values (arrays). */
static VALUE fj_parse_iter(fj_state *st, int implicit_root) {
  fj_pstack *ps;
  VALUE      ps_obj = TypedData_Make_Struct(rb_cObject, fj_pstack, &fj_pstack_type, ps);
  VALUE      result = Qnil;
  int        vss = 0; /* warnings: has a value landed in the current container since the last separator? */

  ps->vptr = ALLOC_N(VALUE, 64);    ps->vhead = 0; ps->vcapa = 64;
  ps->fptr = ALLOC_N(fj_frame, 16); ps->fhead = 0; ps->fcapa = 16;

  if (implicit_root) fj_fpush(ps, 0, 1);

  for (;;) {
    int  b;
    long mark;
    int  is_obj;

    if (ps->fhead == 0) { /* top level: parse exactly one value */
      fj_skip_ws_comments(st);
      b = fj_byte(st);
      if (b == '{') { fj_advance(st, 1); fj_fpush(ps, ps->vhead, 1); vss = 0; continue; }
      if (b == '[') { fj_advance(st, 1); fj_fpush(ps, ps->vhead, 0); vss = 0; continue; }
      if (b == -1) fj_error(st, "unexpected end of input");
      result = fj_parse_value(st);
      break;
    }

    mark   = ps->fptr[ps->fhead - 1].mark;
    is_obj = ps->fptr[ps->fhead - 1].is_obj;

    if (is_obj) {
      VALUE key;
      fj_skip_ws_comments(st);
      b = fj_byte(st);
      if (b == ',') { /* collapsing separator: skip empty member */
        if (st->on_warning != Qnil && !vss) fj_warn(st, fj_sym_empty_slot, "extra comma, collapsed an empty slot");
        vss = 0;
        fj_advance(st, 1);
        continue;
      }
      if (b == '}') {
        VALUE hash;
        fj_advance(st, 1);
        hash = fj_build_object(st, &ps->vptr[mark], ps->vhead - mark);
        ps->vhead = mark;
        ps->fhead--;
        if (ps->fhead == 0) { result = hash; break; }
        fj_vpush(ps, hash);
        vss = 1;
        continue;
      }
      if (b == -1) {
        if (implicit_root && ps->fhead == 1) {
          result = fj_build_object(st, &ps->vptr[mark], ps->vhead - mark);
          break;
        }
        fj_error(st, "unterminated object");
      }
      if (b == ']') fj_error(st, "unexpected ']' — expected a key or '}'");
      key = fj_parse_object_key(st);
      fj_skip_ws_comments(st);
      if (fj_byte(st) != ':') fj_error(st, "expected ':' after object key");
      fj_advance(st, 1);
      fj_skip_ws_comments(st);
      b = fj_byte(st);
      if (b == '{' || b == '[') {
        fj_vpush(ps, key);
        fj_advance(st, 1);
        fj_fpush(ps, ps->vhead, (b == '{'));
        vss = 0;
        continue;
      }
      if (b == '}' || b == ',') { /* key with a colon but no value -> null */
        fj_vpush(ps, key);
        fj_vpush(ps, Qnil);
        fj_warn(st, fj_sym_empty_value, "empty value, used null");
        vss = 1;
        continue;
      }
      if (b == -1) fj_error(st, "unexpected end of input");
      fj_vpush(ps, key);
      fj_vpush(ps, fj_parse_member_value(st));
      vss = 1;
    } else { /* array */
      fj_skip_ws_comments(st);
      b = fj_byte(st);
      if (b == ',') { /* collapsing separator: skip empty slot */
        if (st->on_warning != Qnil && !vss) fj_warn(st, fj_sym_empty_slot, "extra comma, collapsed an empty slot");
        vss = 0;
        fj_advance(st, 1);
        continue;
      }
      if (b == ']') {
        VALUE ary;
        fj_advance(st, 1);
        ary = rb_ary_new_from_values(ps->vhead - mark, &ps->vptr[mark]);
        ps->vhead = mark;
        ps->fhead--;
        if (ps->fhead == 0) { result = ary; break; }
        fj_vpush(ps, ary);
        vss = 1;
        continue;
      }
      if (b == -1) fj_error(st, "unterminated array");
      if (b == '}') fj_error(st, "unexpected '}' — expected ']' or a value");
      if (b == '{' || b == '[') {
        fj_advance(st, 1);
        fj_fpush(ps, ps->vhead, (b == '{'));
        vss = 0;
        continue;
      }
      fj_vpush(ps, fj_parse_member_value(st));
      vss = 1;
    }
  }

  RB_GC_GUARD(ps_obj);
  return result;
}

/* At the start of a document: identifier followed by ':' means implicit root
 * object (no outer braces). Look ahead without consuming. */
static int fj_implicit_root_ahead(fj_state *st) {
  int b = fj_byte(st), result;
  long sp;
  if (b == -1 || !fj_is_key_start(b)) return 0;
  sp = st->pos;
  fj_advance(st, 1);
  while ((b = fj_byte(st)) != -1 && fj_is_key_continue(b)) fj_advance(st, 1);
  fj_skip_pure_ws(st);
  result = (fj_byte(st) == ':');
  st->pos = sp;
  return result;
}

static VALUE fj_parse_c(VALUE self, VALUE input, VALUE opts) {
  fj_state st;
  VALUE value, enc_opt, dk;

  Check_Type(input, T_STRING);

  enc_opt = rb_hash_aref(opts, fj_sym_encoding);
  if (!NIL_P(enc_opt)) {
    input = rb_funcall(rb_str_dup(input), fj_force_encoding_id, 1, enc_opt);
  }
  if (!RTEST(rb_funcall(input, fj_valid_encoding_p_id, 0))) {
    VALUE name = rb_funcall(rb_funcall(input, fj_encoding_id, 0), fj_name_id, 0);
    VALUE msg = rb_sprintf("invalid byte sequence for %" PRIsVALUE, name);
    rb_exc_raise(rb_funcall(cEncodingError, fj_new_id, 3, msg, Qnil, Qnil));
  }

  st.buf = RSTRING_PTR(input);
  st.len = RSTRING_LEN(input);
  st.pos = 0;
  st.enc = rb_enc_get(input);
  st.depth = 0;
#ifdef HAVE_RB_ENC_INTERNED_STR
  fj_kc_slot kcache[FJ_KCACHE_SIZE];
  memset(kcache, 0, sizeof(kcache));
  st.kcache = kcache;
#else
  st.kcache = NULL;
#endif

  st.symbolize_keys = RTEST(rb_hash_aref(opts, fj_sym_symbolize_keys));
  dk = rb_hash_aref(opts, fj_sym_duplicate_key);
  st.dup_first_wins = (dk == fj_sym_first_wins);

  {
    VALUE bd = rb_hash_aref(opts, fj_sym_bigdecimal_load);
    if (bd == fj_sym_float) st.bigdecimal_load = 0;
    else if (bd == fj_sym_bigdecimal) st.bigdecimal_load = 2;
    else st.bigdecimal_load = 1; /* :auto (default), including nil */
  }

  st.on_warning = rb_hash_aref(opts, fj_sym_on_warning); /* Qnil when absent */

  if (st.len >= 3 && (unsigned char)st.buf[0] == 0xEF &&
      (unsigned char)st.buf[1] == 0xBB && (unsigned char)st.buf[2] == 0xBF) {
    st.pos = 3;
  }

  /* With a block: yield each top-level value until EOF (JSONL / NDJSON /
   * concatenated). Same loop as the Ruby each_value path, on the C parser. */
  if (rb_block_given_p()) {
    for (;;) {
      fj_skip_ws_comments(&st);
      if (fj_eof(&st)) break;
      rb_yield(fj_parse_iter(&st, fj_implicit_root_ahead(&st)));
    }
    return Qnil;
  }

  /* No block: auto-detect the document count for free — it is the same "is there
   * trailing content after the first value?" check that used to raise. 0 documents
   * -> nil; 1 document -> the value itself (single-document hot path, no Array
   * allocated); 2+ documents (NDJSON / JSONL / concatenated / whitespace-separated)
   * -> an Array of every top-level value. Commas do NOT separate documents (only
   * whitespace / newline / concatenation do), so a bracketless comma list still
   * raises in fj_parse_iter — the unsupported implicit-root array. */
  fj_skip_ws_comments(&st);
  if (fj_eof(&st)) return Qnil;
  value = fj_parse_iter(&st, fj_implicit_root_ahead(&st));
  fj_skip_ws_comments(&st);
  if (fj_eof(&st)) return value;
  {
    VALUE arr = rb_ary_new();
    rb_ary_push(arr, value);
    do {
      rb_ary_push(arr, fj_parse_iter(&st, fj_implicit_root_ahead(&st)));
      fj_skip_ws_comments(&st);
    } while (!fj_eof(&st));
    return arr;
  }
}

void Init_smarter_json(void) {
  mSmarterJSON = rb_define_module("SmarterJSON");
  cParseError = rb_const_get(mSmarterJSON, rb_intern("ParseError"));
  cEncodingError = rb_const_get(mSmarterJSON, rb_intern("EncodingError"));
  cWarning = rb_const_get(mSmarterJSON, rb_intern("Warning"));
  fj_bigdecimal_id = rb_intern("BigDecimal");
  fj_to_sym_id = rb_intern("to_sym");
  fj_key_p_id = rb_intern("key?");
  fj_new_id = rb_intern("new");
  fj_call_id = rb_intern("call");
  fj_force_encoding_id = rb_intern("force_encoding");
  fj_valid_encoding_p_id = rb_intern("valid_encoding?");
  fj_encoding_id = rb_intern("encoding");
  fj_name_id = rb_intern("name");
  fj_sym_empty_slot = ID2SYM(rb_intern("empty_slot"));
  fj_sym_empty_value = ID2SYM(rb_intern("empty_value"));
  fj_sym_duplicate_key = ID2SYM(rb_intern("duplicate_key"));
  fj_sym_encoding = ID2SYM(rb_intern("encoding"));
  fj_sym_symbolize_keys = ID2SYM(rb_intern("symbolize_keys"));
  fj_sym_first_wins = ID2SYM(rb_intern("first_wins"));
  fj_sym_bigdecimal_load = ID2SYM(rb_intern("bigdecimal_load"));
  fj_sym_float = ID2SYM(rb_intern("float"));
  fj_sym_bigdecimal = ID2SYM(rb_intern("bigdecimal"));
  fj_sym_on_warning = ID2SYM(rb_intern("on_warning"));
  rb_define_module_function(mSmarterJSON, "parse_c", fj_parse_c, 2);
}
