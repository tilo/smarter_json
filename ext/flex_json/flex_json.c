#include "flex_json.h"
#include <math.h>
#include <string.h>
#ifdef __ARM_NEON
#include <arm_neon.h>
#endif
#include "vendor/ryu.h" /* Ryū string->double, correctly rounded (Ulf Adams, Apache-2.0) */

/*
 * flex_json C extension — self-contained parser (no callbacks into Ruby parse
 * logic). One entry point, FlexJSON.parse_c (made private on the Ruby side).
 *
 * Covers strict JSON, JSON5, and the HJSON-inspired layer (quoteless strings
 * with recognized-literals-win classification, triple-quoted strings, implicit
 * root object, newline-as-separator, broader unquoted keys). The flex_json
 * layer (smart quotes, Python literals, Unicode whitespace) is pure-Ruby only
 * for now; those acceleration:true parity specs stay red until ported here.
 */

static VALUE mFlexJSON;
static VALUE cParseError;
static VALUE cEncodingError;
static ID    fj_bigdecimal_id; /* cached BigDecimal() method id (set in Init) */

typedef struct {
  const char *buf;
  long len;
  long pos;
  rb_encoding *enc;
  int depth;
  int symbolize_keys;
  int dup_first_wins;
  int dup_raise;
  int bigdecimal_load;  /* 0 = float, 1 = auto, 2 = bigdecimal */
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

/* 1-based column of the current byte position (bytes since the last line start).
 * Used for triple-quoted indentation stripping (flex_json.md §2.3). */
static long fj_column(fj_state *st) {
  long c = 1, i = st->pos - 1;
  while (i >= 0 && st->buf[i] != 0x0A && st->buf[i] != 0x0D) { c++; i--; }
  return c;
}

/* Construct FlexJSON::ParseError(message, line, col) and raise it. */
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
 * available), or 0. Matches Ruby's [[:space:]]; see flex_json.md §4.7.
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
    if (mask != 0) {
      mask &= 0x8888888888888888ull;
      return p + (__builtin_ctzll(mask) >> 2);
    }
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
  if (b == quote) {
    VALUE s = rb_enc_str_new(st->buf + start, st->pos - start, st->enc);
    fj_advance(st, 1);
    return s;
  }
  if (b == -1) fj_error(st, "unterminated string");

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
      char c = (char)b;
      rb_str_buf_cat(buf, &c, 1);
      fj_advance(st, 1);
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

/* Copy a byte range into a fresh String, dropping underscores. */
static VALUE fj_strip_underscores(const char *p, long n) {
  VALUE s = rb_str_buf_new(n);
  long i;
  for (i = 0; i < n; i++) if (p[i] != '_') rb_str_buf_cat(s, p + i, 1);
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
 * underscore (flex_json leniency) or a dot that BigDecimal() rejects: a leading
 * dot (".5") or a dot not followed by a digit ("5.", "5.e3"). */
static int fj_decimal_is_clean(const char *p, long n) {
  long i = 0;
  if (memchr(p, '_', (size_t)n) != NULL) return 0;
  if (i < n && (p[i] == '+' || p[i] == '-')) i++;
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
  if (i < n && (p[i] == '+' || p[i] == '-')) buf[w++] = p[i++];
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

/* Convert an integer token [p, p+n). Fast path: accumulate the digits into a
 * uint64 in one pass (skipping '_') and return directly — no library call, no
 * allocation. Tokens with more than 18 digits (which may exceed int64) fall back
 * to the bignum path (rb_cstr_to_inum / rb_str_to_inum). */
static VALUE fj_int_value(const char *p, long n) {
  uint64_t m = 0;
  int neg = 0, digits = 0;
  long i = 0;

  if (i < n && (p[i] == '+' || p[i] == '-')) { neg = (p[i] == '-'); i++; }
  for (; i < n; i++) {
    if (p[i] == '_') continue;
    if (++digits > 18) break; /* may exceed int64 — use the bignum path */
    m = m * 10 + (uint64_t)(p[i] - '0');
  }
  if (digits >= 1 && digits <= 18) {
    int64_t v = (int64_t)m;
    return LL2NUM(neg ? -v : v);
  }
  if (memchr(p, '_', (size_t)n) == NULL) return rb_cstr_to_inum(p, 10, 0);
  return rb_str_to_inum(fj_strip_underscores(p, n), 10, 0);
}

/* Convert a decimal token [p, p+n). :bigdecimal (or :auto with >16 significant
 * digits) -> BigDecimal. Otherwise Float: extract the base-10 mantissa and
 * exponent in one pass (skipping '_') and convert with Ryū — correctly rounded,
 * no strtod. Mantissa digits and the e10 = exponent - fractional_digits formula
 * mirror the json gem exactly; >17 mantissa digits or the subnormal range fall
 * back to rb_cstr_to_dbl. */
static VALUE fj_decimal_value(fj_state *st, const char *p, long n) {
  uint64_t m10 = 0;
  int m10digits = 0, neg = 0, frac = 0, in_frac = 0, overflow = 0;
  int64_t e10 = 0;
  long i = 0;

  if (st->bigdecimal_load == 2 || (st->bigdecimal_load == 1 && fj_sig_digits(p, n) > 16)) {
    return fj_to_bigdecimal_token(p, n);
  }

  if (i < n && (p[i] == '+' || p[i] == '-')) { neg = (p[i] == '-'); i++; }
  for (; i < n; i++) {
    char c = p[i];
    if (c == '_') continue;
    if (c == '.') { in_frac = 1; continue; }
    if (c == 'e' || c == 'E') break;
    if (++m10digits > 18) { overflow = 1; break; } /* keep m10 within uint64 */
    m10 = m10 * 10 + (uint64_t)(c - '0');
    if (in_frac) frac++;
  }
  if (!overflow && i < n && (p[i] == 'e' || p[i] == 'E')) {
    int eneg = 0;
    i++;
    if (i < n && (p[i] == '+' || p[i] == '-')) { eneg = (p[i] == '-'); i++; }
    for (; i < n; i++) {
      if (p[i] == '_') continue;
      e10 = e10 * 10 + (p[i] - '0');
      if (e10 > 1000000) { overflow = 1; break; } /* extreme exponent — let strtod handle it */
    }
    if (eneg) e10 = -e10;
  }
  e10 -= frac;

  /* Ryū fast path: <=17 mantissa digits and not in the subnormal range. */
  if (!overflow && m10digits >= 1 && m10digits <= 17 && (long)m10digits + e10 >= -307) {
    if (m10 == 0) return rb_float_new(neg ? -0.0 : 0.0);
    return rb_float_new(ryu_s2d_from_parts(m10, m10digits, (int32_t)e10, neg != 0));
  }

  /* Fallback for >17 digits / extreme or subnormal exponents. */
  if (memchr(p, '_', (size_t)n) == NULL) return rb_float_new(rb_cstr_to_dbl(p, 0));
  return rb_float_new(rb_str_to_dbl(fj_strip_underscores(p, n), 0));
}

/* Top-level / strict-position number (JSON5 grammar). Conversion uses the
 * C API rb_str_to_inum / rb_str_to_dbl — identical to Ruby's to_i/to_f. */
static VALUE fj_parse_number(fj_state *st) {
  long start = st->pos; /* includes a leading sign */
  int b = fj_byte(st);
  int is_float = 0;
  int neg_sign = 0;

  if (b == '-' || b == '+') { neg_sign = (b == '-'); fj_advance(st, 1); }

  b = fj_byte(st);
  if (b == 'I') { fj_consume_keyword(st, "Infinity"); return rb_float_new(neg_sign ? -INFINITY : INFINITY); }
  if (b == 'N') { fj_consume_keyword(st, "NaN"); return rb_float_new(NAN); }

  if (b == '0') {
    fj_advance(st, 1);
    b = fj_byte(st);
    if (b == 'x' || b == 'X') {
      long hs;
      VALUE hx;
      fj_advance(st, 1);
      hs = st->pos;
      while ((b = fj_byte(st)) != -1 && (fj_hex_val(b) >= 0 || b == '_')) fj_advance(st, 1);
      if (st->pos == hs) fj_error(st, "invalid hex number");
      hx = rb_str_buf_new(16);
      if (neg_sign) rb_str_buf_cat(hx, "-", 1);
      { long i; for (i = hs; i < st->pos; i++) if (st->buf[i] != '_') rb_str_buf_cat(hx, st->buf + i, 1); }
      return rb_str_to_inum(hx, 16, 0);
    }
  } else if (b >= '1' && b <= '9') {
    while ((b = fj_byte(st)) != -1 && ((b >= '0' && b <= '9') || b == '_')) fj_advance(st, 1);
  } else if (b == '.') {
    /* leading decimal handled below */
  } else {
    fj_error(st, "invalid number");
  }

  if (fj_byte(st) == '.') {
    is_float = 1;
    fj_advance(st, 1);
    while ((b = fj_byte(st)) != -1 && ((b >= '0' && b <= '9') || b == '_')) fj_advance(st, 1);
  }
  b = fj_byte(st);
  if (b == 'e' || b == 'E') {
    is_float = 1;
    fj_advance(st, 1);
    b = fj_byte(st);
    if (b == '+' || b == '-') fj_advance(st, 1);
    if (!((b = fj_byte(st)) >= '0' && b <= '9')) fj_error(st, "invalid number: expected digits in exponent");
    while ((b = fj_byte(st)) != -1 && ((b >= '0' && b <= '9') || b == '_')) fj_advance(st, 1);
  }

  {
    const char *np = st->buf + start;
    long nlen = st->pos - start;
    return is_float ? fj_decimal_value(st, np, nlen) : fj_int_value(np, nlen);
  }
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
static inline VALUE fj_key_str(const char *p, long n, rb_encoding *enc) {
#ifdef HAVE_RB_ENC_INTERNED_STR
  return rb_enc_interned_str(p, n, enc);
#else
  return rb_enc_str_new(p, n, enc);
#endif
}

static VALUE fj_parse_identifier_key(fj_state *st) {
  long start = st->pos;
  int b;
  fj_advance(st, 1);
  while ((b = fj_byte(st)) != -1 && fj_is_key_continue(b)) fj_advance(st, 1);
  return fj_key_str(st->buf + start, st->pos - start, st->enc);
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
        VALUE k      = fj_key_str(st->buf + cstart, i - cstart, st->enc);
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
  if (i < n && (p[i] == '+' || p[i] == '-')) i++;
  if (i + 1 < n && p[i] == '0' && (p[i + 1] == 'x' || p[i + 1] == 'X')) i += 2; else return 0;
  hs = i;
  while (i < n && (fj_hex_val((unsigned char)p[i]) >= 0 || p[i] == '_')) i++;
  if (i == hs) return 0;
  return i == n;
}

/* Returns 0 (not a number), 1 (integer), 2 (float). Mirrors DEC_RE. */
static int fj_validate_decimal(const char *p, long n) {
  long i = 0;
  int has_digit = 0, is_float = 0;
  if (i < n && (p[i] == '+' || p[i] == '-')) i++;
  if (i < n && p[i] == '0') { i++; has_digit = 1; }
  else if (i < n && p[i] >= '1' && p[i] <= '9') {
    has_digit = 1; i++;
    while (i < n && ((p[i] >= '0' && p[i] <= '9') || p[i] == '_')) i++;
  }
  if (i < n && p[i] == '.') {
    is_float = 1; i++;
    while (i < n && ((p[i] >= '0' && p[i] <= '9') || p[i] == '_')) { if (p[i] != '_') has_digit = 1; i++; }
  }
  if (i < n && (p[i] == 'e' || p[i] == 'E')) {
    long es;
    is_float = 1; i++;
    if (i < n && (p[i] == '+' || p[i] == '-')) i++;
    es = i;
    while (i < n && ((p[i] >= '0' && p[i] <= '9') || p[i] == '_')) i++;
    if (i == es) return 0;
  }
  if (i != n) return 0;
  if (!has_digit) return 0;
  return is_float ? 2 : 1;
}

static VALUE fj_classify_quoteless(fj_state *st, const char *p0, long n0) {
  const char *p = p0;
  long n = n0;
  int code, c0;
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

  if ((c0 >= '0' && c0 <= '9') || c0 == '.' || c0 == '+' || c0 == '-') {
    if (c0 == '+' && fj_tok_eq(p, n, "+Infinity")) return rb_float_new(INFINITY);
    if (c0 == '-' && fj_tok_eq(p, n, "-Infinity")) return rb_float_new(-INFINITY);
    if (fj_is_hex_token(p, n)) {
      long i = 0;
      int neg = 0;
      VALUE hx;
      if (p[i] == '+' || p[i] == '-') { neg = (p[i] == '-'); i++; }
      i += 2; /* skip 0x */
      hx = rb_str_buf_new(n);
      if (neg) rb_str_buf_cat(hx, "-", 1);
      for (; i < n; i++) if (p[i] != '_') rb_str_buf_cat(hx, p + i, 1);
      return rb_str_to_inum(hx, 16, 0);
    }
    code = fj_validate_decimal(p, n);
    if (code) return (code == 2) ? fj_decimal_value(st, p, n) : fj_int_value(p, n);
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
static VALUE fj_parse_quoteless_or_literal(fj_state *st) {
  long start = st->pos;
  int prev_ws = 0, b, nx;
  for (;;) {
    b = fj_byte(st);
    if (b == -1) break;
    if (b == ',' || b == '}' || b == ']' || b == 0x0A || b == 0x0D) break;
    nx = fj_byte_at(st, 1);
    if (prev_ws && (b == '#' || (b == '/' && (nx == '/' || nx == '*')))) break;
    if (fj_is_ws(b)) {
      prev_ws = 1;
      fj_advance(st, 1);
    } else if (b >= 0x80) {
      long m = fj_mbws(st->buf + st->pos, st->len - st->pos);
      if (m > 0) { prev_ws = 1; st->pos += m; }
      else { prev_ws = 0; fj_advance(st, 1); }
    } else {
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

static void fj_store_member(fj_state *st, VALUE hash, VALUE key, VALUE value) {
  VALUE k = st->symbolize_keys ? rb_funcall(key, rb_intern("to_sym"), 0) : key;
  if (RTEST(rb_funcall(hash, rb_intern("key?"), 1, k))) {
    if (st->dup_first_wins) return;
    if (st->dup_raise) fj_error(st, "duplicate key");
  }
  rb_hash_aset(hash, k, value);
}

/* Value in object-value or array-element position (scalar only — containers
 * are handled by the iterative driver below). Quoteless allowed. Assumes the
 * caller has already skipped whitespace/comments and checked for EOF. */
static VALUE fj_parse_member_value(fj_state *st) {
  int b = fj_byte(st);
  switch (b) {
    case '"':  return fj_parse_string(st, '"');
    case '\'': return fj_parse_single_or_triple(st);
    default: {
      int kind = fj_smart_quote_kind(st);
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

/* Iterative container parser — explicit stack, no C recursion, so nesting is
 * bounded only by memory (like Oj), not the C call stack. Each new container is
 * attached to its parent immediately, and the working stack is a Ruby Array, so
 * the whole partial tree stays reachable from `root` (GC-safe) and the stack
 * frees itself. */
static VALUE fj_parse_iter(fj_state *st, int implicit_root) {
  VALUE stack = rb_ary_new();
  VALUE root = Qnil;
  VALUE cur = Qundef;   /* innermost container, or Qundef while at top level */
  int cur_obj = 0;

  if (implicit_root) {
    root = rb_hash_new();
    rb_ary_push(stack, root);
    cur = root;
    cur_obj = 1;
  }

  for (;;) {
    int b;

    if (cur == Qundef) { /* top level: parse exactly one value */
      fj_skip_ws_comments(st);
      b = fj_byte(st);
      if (b == '{') { fj_advance(st, 1); root = rb_hash_new(); rb_ary_push(stack, root); cur = root; cur_obj = 1; continue; }
      if (b == '[') { fj_advance(st, 1); root = rb_ary_new();  rb_ary_push(stack, root); cur = root; cur_obj = 0; continue; }
      if (b == -1) fj_error(st, "unexpected end of input");
      return fj_parse_value(st);
    }

    if (cur_obj) {
      VALUE key;
      fj_skip_ws_comments(st);
      b = fj_byte(st);
      if (b == '}') {
        fj_advance(st, 1);
        rb_ary_pop(stack);
        if (RARRAY_LEN(stack) == 0) return root;
        cur = rb_ary_entry(stack, RARRAY_LEN(stack) - 1);
        cur_obj = RB_TYPE_P(cur, T_HASH);
        fj_skip_ws_comments(st);
        if (fj_byte(st) == ',') fj_advance(st, 1);
        continue;
      }
      if (b == -1) {
        if (implicit_root && RARRAY_LEN(stack) == 1) return root;
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
        VALUE c = (b == '{') ? rb_hash_new() : rb_ary_new();
        fj_advance(st, 1); /* consume the opening '{' or '[' */
        fj_store_member(st, cur, key, c);
        rb_ary_push(stack, c);
        cur = c;
        cur_obj = (b == '{');
        continue;
      }
      if (b == -1) fj_error(st, "unexpected end of input");
      fj_store_member(st, cur, key, fj_parse_member_value(st));
      fj_skip_ws_comments(st); /* skip_separator_run */
      if (fj_byte(st) == ',') fj_advance(st, 1);
    } else { /* array */
      fj_skip_ws_comments(st);
      b = fj_byte(st);
      if (b == ']') {
        fj_advance(st, 1);
        rb_ary_pop(stack);
        if (RARRAY_LEN(stack) == 0) return root;
        cur = rb_ary_entry(stack, RARRAY_LEN(stack) - 1);
        cur_obj = RB_TYPE_P(cur, T_HASH);
        fj_skip_ws_comments(st);
        if (fj_byte(st) == ',') fj_advance(st, 1);
        continue;
      }
      if (b == -1) fj_error(st, "unterminated array");
      if (b == '}') fj_error(st, "unexpected '}' — expected ']' or a value");
      if (b == '{' || b == '[') {
        VALUE c = (b == '{') ? rb_hash_new() : rb_ary_new();
        fj_advance(st, 1); /* consume the opening '{' or '[' */
        rb_ary_push(cur, c);
        rb_ary_push(stack, c);
        cur = c;
        cur_obj = (b == '{');
        continue;
      }
      rb_ary_push(cur, fj_parse_member_value(st));
      fj_skip_ws_comments(st); /* skip_separator_run */
      if (fj_byte(st) == ',') fj_advance(st, 1);
    }
  }
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

  enc_opt = rb_hash_aref(opts, ID2SYM(rb_intern("encoding")));
  if (!NIL_P(enc_opt)) {
    input = rb_funcall(rb_str_dup(input), rb_intern("force_encoding"), 1, enc_opt);
  }
  if (!RTEST(rb_funcall(input, rb_intern("valid_encoding?"), 0))) {
    VALUE name = rb_funcall(rb_funcall(input, rb_intern("encoding"), 0), rb_intern("name"), 0);
    VALUE msg = rb_sprintf("invalid byte sequence for %" PRIsVALUE, name);
    rb_exc_raise(rb_funcall(cEncodingError, rb_intern("new"), 3, msg, Qnil, Qnil));
  }

  st.buf = RSTRING_PTR(input);
  st.len = RSTRING_LEN(input);
  st.pos = 0;
  st.enc = rb_enc_get(input);
  st.depth = 0;

  st.symbolize_keys = RTEST(rb_hash_aref(opts, ID2SYM(rb_intern("symbolize_keys"))));
  dk = rb_hash_aref(opts, ID2SYM(rb_intern("duplicate_key")));
  st.dup_first_wins = (dk == ID2SYM(rb_intern("first_wins")));
  st.dup_raise = (dk == ID2SYM(rb_intern("raise")));

  {
    VALUE bd = rb_hash_aref(opts, ID2SYM(rb_intern("bigdecimal_load")));
    if (bd == ID2SYM(rb_intern("float"))) st.bigdecimal_load = 0;
    else if (bd == ID2SYM(rb_intern("bigdecimal"))) st.bigdecimal_load = 2;
    else st.bigdecimal_load = 1; /* :auto (default), including nil */
  }

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

  fj_skip_ws_comments(&st);
  if (fj_eof(&st)) fj_error(&st, "unexpected end of input");
  value = fj_parse_iter(&st, fj_implicit_root_ahead(&st));
  fj_skip_ws_comments(&st);
  if (!fj_eof(&st)) {
    fj_error(&st, "unexpected content after top-level value — pass a block to FlexJSON.parse to read multiple documents");
  }
  return value;
}

void Init_flex_json(void) {
  mFlexJSON = rb_define_module("FlexJSON");
  cParseError = rb_const_get(mFlexJSON, rb_intern("ParseError"));
  cEncodingError = rb_const_get(mFlexJSON, rb_intern("EncodingError"));
  fj_bigdecimal_id = rb_intern("BigDecimal");
  rb_define_module_function(mFlexJSON, "parse_c", fj_parse_c, 2);
}
