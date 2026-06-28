"""pdf — extract text from a PDF document (v1, from scratch in Mojo).

Pipeline:
  1. Scan the file for `stream … endstream` objects.
  2. Inflate the ones marked `/FlateDecode` (via zlib.mojo); pass others through.
  3. From each *content* stream (those containing `BT`), pull the shown strings —
     literal `(…)` and hex `<…>` operands of the text operators — inserting line
     breaks on the positioning operators (Td/TD/Tm/T*/'/").

Scope (v1): born-digital PDFs whose content streams are uncompressed or
FlateDecode, with text in WinAnsi/Latin-1-ish single-byte encodings. NOT yet:
xref/page-tree-accurate stream selection, `/ToUnicode` CMaps, CID/Type0 fonts,
LZW/ASCII85 filters, encrypted PDFs, OCR. Those are the next phases — see README.
"""

from zlib import inflate


# ── byte helpers ─────────────────────────────────────────────────────────────


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        out.append(p[i])
    return out^


def _find(data: List[UInt8], pat: List[UInt8], start: Int) -> Int:
    """Index of the first occurrence of `pat` in `data` at/after `start`, or -1.
    """
    var n = len(data)
    var m = len(pat)
    if m == 0 or m > n:
        return -1
    var i = start
    while i <= n - m:
        var ok = True
        for j in range(m):
            if data[i + j] != pat[j]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _window_has(data: List[UInt8], pat: List[UInt8], lo: Int, hi: Int) -> Bool:
    var idx = _find(data, pat, lo if lo > 0 else 0)
    return idx != -1 and idx < hi


def _is_alpha(c: UInt8) -> Bool:
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)


def _is_digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


def _is_ws(c: UInt8) -> Bool:
    return c == 32 or c == 9 or c == 10 or c == 13 or c == 12 or c == 0


def _hexval(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 65 and c <= 70:
        return Int(c) - 55
    if c >= 97 and c <= 102:
        return Int(c) - 87
    return -1


# ── stream extraction ────────────────────────────────────────────────────────


def decode_streams(data: List[UInt8]) raises -> List[List[UInt8]]:
    """Return the decoded bytes of every content stream (those containing `BT`),
    inflating `/FlateDecode` streams via zlib.mojo."""
    var kw_stream = _ascii("stream")
    var kw_endstream = _ascii("endstream")
    var kw_flate = _ascii("/FlateDecode")
    var kw_bt = _ascii("BT")

    var out = List[List[UInt8]]()
    var pos = 0
    var n = len(data)
    while True:
        var s = _find(data, kw_stream, pos)
        if s == -1:
            break
        # data starts after "stream" + its EOL (CRLF or LF).
        var ds = s + 6
        if ds < n and data[ds] == 13:  # CR
            ds += 1
        if ds < n and data[ds] == 10:  # LF
            ds += 1
        var e = _find(data, kw_endstream, ds)
        if e == -1:
            break
        pos = e + len(kw_endstream)

        # Raw stream bytes (drop a single trailing EOL before endstream).
        var re = e
        if re > ds and data[re - 1] == 10:
            re -= 1
        if re > ds and data[re - 1] == 13:
            re -= 1
        var raw = List[UInt8]()
        for i in range(ds, re):
            raw.append(data[i])

        # FlateDecode? look in the dict just before "stream".
        var lo = s - 2000
        if lo < 0:
            lo = 0
        var decoded: List[UInt8]
        if _window_has(data, kw_flate, lo, s):
            try:
                decoded = inflate(raw)
            except:
                continue  # not actually inflatable — skip
        else:
            decoded = raw^

        # Keep only content streams (they carry text — `BT`).
        if _find(decoded, kw_bt, 0) != -1:
            out.append(decoded^)
    return out^


# ── content-stream text extraction ───────────────────────────────────────────


def _read_literal_raw(
    content: List[UInt8], start: Int, mut raw: List[UInt8]
) -> Int:
    """Parse a `(...)` literal string at `start` (the `(`); append its decoded
    BYTES (escapes resolved) to `raw`; return the index past the closing `)`."""
    var n = len(content)
    var i = start + 1
    var depth = 1
    while i < n:
        var c = content[i]
        if c == 92:  # backslash escape
            i += 1
            if i >= n:
                break
            var e = content[i]
            if e == 110:
                raw.append(10)
            elif e == 114:
                raw.append(13)
            elif e == 116:
                raw.append(9)
            elif e == 98:
                raw.append(8)
            elif e == 102:
                raw.append(12)
            elif e == 10 or e == 13:
                pass  # line continuation
            elif e >= 48 and e <= 55:  # \ddd octal
                var v = Int(e) - 48
                var k = 0
                while (
                    k < 2
                    and i + 1 < n
                    and content[i + 1] >= 48
                    and content[i + 1] <= 55
                ):
                    i += 1
                    v = v * 8 + (Int(content[i]) - 48)
                    k += 1
                raw.append(UInt8(v & 0xFF))
            else:
                raw.append(e)
            i += 1
        elif c == 40:
            depth += 1
            raw.append(c)
            i += 1
        elif c == 41:
            depth -= 1
            if depth == 0:
                i += 1
                break
            raw.append(c)
            i += 1
        else:
            raw.append(c)
            i += 1
    return i


def _read_hex_raw(
    content: List[UInt8], start: Int, mut raw: List[UInt8]
) -> Int:
    """Parse a `<...>` hex string at `start`; append decoded bytes; return index
    past `>`."""
    var n = len(content)
    var i = start + 1
    var hi = -1
    while i < n:
        var c = content[i]
        if c == 62:  # >
            i += 1
            break
        var hv = _hexval(c)
        if hv >= 0:
            if hi < 0:
                hi = hv
            else:
                raw.append(UInt8((hi << 4) | hv))
                hi = -1
        i += 1
    if hi >= 0:
        raw.append(UInt8(hi << 4))
    return i


def _name_at(content: List[UInt8], mut p: Int) -> String:
    """Read a `/Name` token at `p` (the `/`); return the name (no slash); advance p.
    """
    var n = len(content)
    p += 1  # skip '/'
    var s = String("")
    while p < n:
        var c = content[p]
        if (
            _is_ws(c)
            or c == 47
            or c == 60
            or c == 62
            or c == 91
            or c == 93
            or c == 40
            or c == 41
        ):
            break
        s += chr(Int(c))
        p += 1
    return s^


# Layout thresholds. The text pen position is tracked in *text-space* units. We
# don't read per-glyph widths from the font, so we ESTIMATE each shown glyph's
# advance as a fraction of the font size (_GLYPH_EM em) and keep a running
# estimate of how far the rendered text has already moved the pen (`pen_w`). A
# positioning move (Td/Tm) only opens a *space* when it jumps ahead of that
# estimate by more than _H_WORDGAP_EM em — otherwise the move is just the
# carriage advancing over the glyph it already drew (real-world PDFs that place
# every glyph with its own `(c) Tj  N 0 Td` would otherwise get a space wedged
# between *every* pair of letters — "W ells Fargo custom er"). The vertical
# newline threshold scales with the font size too (a small move is a
# sub/superscript; a line is roughly a full line of leading).
alias _GLYPH_EM = 0.5  # estimated glyph advance, in em (× font size)
alias _V_NEWLINE_EM = 0.3  # |Δy| beyond this × font size ⇒ newline
alias _V_NEWLINE_MIN = 4.0  # …but never less than this many units (small fonts)
# A positioning move opens a space only when it jumps past the estimated glyph
# width by more than this × font size. A real space-only gap (no space glyph) is
# ≥ a full space (~0.25 em) on top of a glyph; the slack here absorbs the spread
# between our flat 0.5-em estimate and a wide glyph's true advance (W, m ≈ 0.85
# em) so per-glyph-positioned text doesn't get a space wedged between letters.
alias _H_WORDGAP_EM = 0.55  # Δx beyond glyphs + this × font size ⇒ space
alias _TJ_WORDGAP = 200.0  # |TJ adjustment| (‰ em) beyond this ⇒ space


def _est_width(s: String, font_size: Float64) -> Float64:
    """Estimate the rendered width (text-space units) of an already-decoded show
    string: each codepoint advances ≈_GLYPH_EM of the font size. Crude (no real
    glyph metrics) but enough to tell a glyph's own advance from a word gap."""
    var cps = 0
    for _cp in s.codepoint_slices():
        cps += 1
    return Float64(cps) * _GLYPH_EM * font_size


struct Buf(Movable):
    """An output buffer over `List[UInt8]` so `+=` is amortized O(1). Mojo's
    `String +=` reallocates per append — O(n^2) on the per-glyph text hot path,
    which hung extraction for minutes on large / per-glyph-positioned PDFs."""

    var data: List[UInt8]

    def __init__(out self):
        self.data = List[UInt8]()

    def __iadd__(mut self, s: String):
        var b = s.as_bytes()
        for i in range(len(b)):
            self.data.append(b[i])

    def last_byte(self) -> Int:
        """Last byte, or -1 if empty (trailing space/newline dedupe)."""
        var n = len(self.data)
        if n == 0:
            return -1
        return Int(self.data[n - 1])

    def to_string(self) -> String:
        return String(unsafe_from_utf8=Span(self.data))


def _read_number(content: List[UInt8], mut p: Int) -> Float64:
    """Skip whitespace, then read a (possibly signed/decimal) PDF number at `p`;
    advance `p` past it. Non-numbers leave `p` unchanged and return 0."""
    var n = len(content)
    while p < n and _is_ws(content[p]):
        p += 1
    var start = p
    var sign = 1.0
    if p < n and (content[p] == 43 or content[p] == 45):  # + -
        if content[p] == 45:
            sign = -1.0
        p += 1
    var ipart = 0.0
    var any = False
    while p < n and _is_digit(content[p]):
        ipart = ipart * 10.0 + Float64(Int(content[p]) - 48)
        p += 1
        any = True
    var frac = 0.0
    var scale = 1.0
    if p < n and content[p] == 46:  # '.'
        p += 1
        while p < n and _is_digit(content[p]):
            scale *= 10.0
            frac = frac * 10.0 + Float64(Int(content[p]) - 48)
            p += 1
            any = True
    if not any:
        p = start
        return 0.0
    return sign * (ipart + frac / scale)


def _show_tj_array(
    content: List[UInt8],
    start: Int,
    cur: Font,
    mut out: Buf,
    font_size: Float64,
    mut pen_w: Float64,
) raises -> Int:
    """Show a `TJ` operand array `[ (s) num <h> num … ]` at `start` (the `[`):
    concatenate the strings, turning a number whose magnitude opens a word-sized
    gap into a single space. Return the index past `]`. Accumulates the estimated
    rendered width of the shown glyphs into `pen_w`."""
    var n = len(content)
    var i = start + 1  # past '['
    while i < n:
        var _s = i
        var c = content[i]
        if c == 93:  # ]
            i += 1
            break
        elif c == 40:  # ( literal
            var raw = List[UInt8]()
            i = _read_literal_raw(content, i, raw)
            var s = cur.decode(raw)
            pen_w += _est_width(s, font_size)
            out += s^
        elif c == 60:  # < hex
            var raw = List[UInt8]()
            i = _read_hex_raw(content, i, raw)
            var s = cur.decode(raw)
            pen_w += _est_width(s, font_size)
            out += s^
        elif _is_digit(c) or c == 45 or c == 43 or c == 46:  # a kerning number
            var adj = _read_number(content, i)
            # TJ numbers are subtracted from the pen (in ‰ em): a positive value
            # moves text LEFT/together, a *positive* gap opens to the right when
            # large. A large magnitude either way ≈ a word break in practice. The
            # move also shifts the pen: −adj/1000 em (it carries into pen_w so a
            # following Td measures the gap from the right place).
            pen_w += -(adj / 1000.0) * font_size
            if adj > _TJ_WORDGAP or adj < -_TJ_WORDGAP:
                var lb = out.last_byte()
                if (
                    lb != -1 and lb != 32 and lb != 10
                ):  # not after space/newline
                    out += " "
        else:
            i += 1
        # Safety: _read_number RESETS its position when a +/-/. isn't a real number
        # (no digits), so the kerning branch can leave `i` parked → infinite loop
        # (stream 4 spun 2B times frozen at one byte). Guarantee progress.
        if i == _s:
            i += 1
    return i


def _extract_with_fonts(content: List[UInt8], ft: FontTable) raises -> String:
    """Pull shown text from one content stream, decoding each string through the
    current font (`/Fx Tf`) — applying its /ToUnicode CMap when present, else
    Latin-1.

    Line/word breaks follow the *text geometry*, not the mere presence of a
    positioning operator: a newline is emitted only on a real vertical baseline
    move (|Δy| > _V_NEWLINE), and a space only when a horizontal advance opens a
    word-sized gap. This keeps a glyph-by-glyph-positioned line (each char in its
    own Tj with a Td between, or a TJ array of single glyphs) from exploding into
    one character per line."""
    var out = Buf()
    var n = len(content)
    var i = 0
    var cur = Font()  # default: Latin-1
    var last_name = String("")
    # Text pen position (text-space units). Td/TD are relative to the line start;
    # Tm/cm set it absolutely. We don't have glyph widths, so x only tracks the
    # *positioning* operators — enough to tell a word gap from a glyph advance.
    var x = 0.0
    var y = 0.0
    var have_pos = False  # seen a position yet (first move sets the origin)
    var font_size = 12.0  # current /Fx <size> Tf size (for the word gap)
    # Estimated width (text-space units) of the glyphs shown since the last
    # positioning move — subtracted from the next Td/Tm step so the carriage
    # advancing over its own glyphs isn't mistaken for a word gap.
    var pen_w = 0.0
    while i < n:
        var _start = i
        var c = content[i]
        if c == 40:  # ( literal string
            var raw = List[UInt8]()
            i = _read_literal_raw(content, i, raw)
            var s = cur.decode(raw)
            pen_w += _est_width(s, font_size)
            out += s^
        elif c == 91:  # [ — TJ operand array (kerned show)
            i = _show_tj_array(content, i, cur, out, font_size, pen_w)
        elif c == 60:  # <
            if i + 1 < n and content[i + 1] == 60:
                i += 2  # << dict
            else:
                var raw = List[UInt8]()
                i = _read_hex_raw(content, i, raw)
                var s = cur.decode(raw)
                pen_w += _est_width(s, font_size)
                out += s^
        elif c == 47:  # /Name
            last_name = _name_at(content, i)
        elif c == 39 or c == 34:  # ' or " — next-line-and-show
            out += "\n"
            pen_w = 0.0
            i += 1
        elif _is_digit(c) or c == 45 or c == 43 or c == 46:
            # A numeric operand (or a run of them) — peek at the operator that
            # follows so positioning ops can update the pen. We read up to six
            # numbers (a Tm matrix), keeping the last two as (dx/x, dy/y).
            var nums = List[Float64]()
            var j = i
            while len(nums) < 6:
                var save = j
                var v = _read_number(content, j)
                if j == save:
                    break
                nums.append(v)
                # stop if the next non-ws isn't another number
                var k = j
                while k < n and _is_ws(content[k]):
                    k += 1
                if k >= n or not (
                    _is_digit(content[k])
                    or content[k] == 45
                    or content[k] == 43
                    or content[k] == 46
                ):
                    break
            i = j
            # whitespace, then the operator token
            while i < n and _is_ws(content[i]):
                i += 1
            if i + 1 < n and content[i] == 84:  # 'T'
                var b = content[i + 1]
                var cnt = len(nums)
                var gap = _H_WORDGAP_EM * font_size
                if (b == 100 or b == 68) and cnt >= 2:  # Td / TD: dx dy
                    var dx = nums[cnt - 2]
                    var dy = nums[cnt - 1]
                    _advance(
                        out,
                        x,
                        y,
                        have_pos,
                        x + dx,
                        y + dy,
                        gap,
                        pen_w,
                        font_size,
                    )
                    have_pos = True
                    pen_w = 0.0
                elif (
                    b == 109 and cnt >= 6
                ):  # Tm a b c d e f (e,f = translation)
                    _advance(
                        out,
                        x,
                        y,
                        have_pos,
                        nums[4],
                        nums[5],
                        gap,
                        pen_w,
                        font_size,
                    )
                    have_pos = True
                    pen_w = 0.0
                elif b == 42:  # T* — next line (leading); always a newline
                    if have_pos:
                        out += "\n"
                    have_pos = True
                    pen_w = 0.0
                elif b == 102 and cnt >= 1:  # Tf — font size precedes the op
                    font_size = nums[cnt - 1]
                    if font_size < 0:
                        font_size = -font_size
        elif _is_alpha(c):
            var j = i
            while j < n and (_is_alpha(content[j]) or content[j] == 42):
                j += 1
            var ln = j - i
            if ln == 2 and content[i] == 84:  # 'T'
                var b = content[i + 1]
                if b == 42:  # T* with no numeric operand
                    if have_pos:
                        out += "\n"
                    have_pos = True
                    pen_w = 0.0
                elif b == 102:  # Tf — select font
                    var idx = ft.get(last_name)
                    if idx >= 0:
                        cur = ft.fonts[idx].copy()
                    else:
                        cur = Font()
            i = j
        else:
            i += 1
        # Safety net: every branch above must advance `i`. The numeric/operator
        # path can leave `i` parked on a token it didn't consume (e.g. a non-number
        # where _read_number leaves p put) → an infinite loop on some content
        # (file_1 hung 4+ min). Guarantee forward progress.
        if i == _start:
            i += 1
    return out.to_string()


def _advance(
    mut out: Buf,
    mut x: Float64,
    mut y: Float64,
    have_pos: Bool,
    nx: Float64,
    ny: Float64,
    word_gap: Float64,
    pen_w: Float64,
    font_size: Float64,
):
    """Move the text pen to (nx, ny), emitting a newline on a real vertical move
    and a space on a word-sized horizontal gap on the same line.

    `pen_w` is the estimated width of the glyphs drawn since the previous move:
    the carriage is *expected* to advance that far, so only the *excess* over it
    counts toward a word gap. Without this, a PDF that places each glyph with its
    own `(c) Tj  N 0 Td` step wedges a space between every pair of letters."""
    if have_pos:
        var nl = _V_NEWLINE_EM * font_size
        if nl < _V_NEWLINE_MIN:
            nl = _V_NEWLINE_MIN
        var dy = ny - y
        if dy > nl or dy < -nl:
            out += "\n"
        else:
            var dx = (nx - x) - pen_w  # gap beyond the glyphs already drawn
            if dx > word_gap:
                var lb = out.last_byte()
                if (
                    lb != -1 and lb != 32 and lb != 10
                ):  # not after space/newline
                    out += " "
    x = nx
    y = ny


# ── layout-preserving extraction (column-aligned) ─────────────────────────────
# `_extract_with_fonts` STREAMS text in draw order, which collapses a table's
# columns: a row's date / description / amount / running-balance cells arrive on
# separate lines (any vertical jitter or column-major draw order breaks them up),
# so the reconstructed text loses the column structure a statement parser needs.
# The layout path instead COLLECTS every shown run with its (x, y) text-space
# position, then regroups runs into visual ROWS by y (regardless of draw order)
# and orders each row left-to-right by x with spacing proportional to the gaps —
# i.e. pdftotext's `-layout`. A transaction row then comes out on ONE line with
# its columns aligned, so amount vs running-balance vs the deposit/withdrawal
# column are recoverable.


@fieldwise_init
struct _Frag(Copyable, Movable):
    """One shown text run captured at its text-space pen position."""

    var y: Float64
    var x: Float64
    var fs: Float64
    var text: String


def _collect_frags(content: List[UInt8], ft: FontTable) raises -> List[_Frag]:
    """Mirror `_extract_with_fonts`'s operator parsing, but append a `_Frag` per
    shown run (at the current pen) instead of streaming — and update the pen on
    Td/Tm/T* WITHOUT emitting spaces/newlines (the layout pass derives those from
    geometry)."""
    var frags = List[_Frag]()
    var n = len(content)
    var i = 0
    var cur = Font()
    var last_name = String("")
    # Proper text positioning: the text LINE matrix (tlm) is the start of the
    # current line; Td/TD/T*/Tm move IT, and the pen starts there and advances by
    # the glyph widths as text is shown. Td is relative to the LINE START, not the
    # pen — using the pen (which already advanced over the shown glyphs) makes both
    # x and y drift by each run's width, staircasing a table instead of aligning it.
    var tlm_x = 0.0
    var tlm_y = 0.0
    var pen_x = 0.0
    var pen_y = 0.0
    var leading = 0.0
    var font_size = 12.0
    while i < n:
        var _start = i
        var c = content[i]
        if c == 40:  # ( literal string
            var raw = List[UInt8]()
            i = _read_literal_raw(content, i, raw)
            var s = cur.decode(raw)
            if s.byte_length() > 0:
                var w = _est_width(s, font_size)
                frags.append(_Frag(pen_y, pen_x, font_size, s^))
                pen_x += w
        elif c == 91:  # [ — TJ array; concatenate into one run
            i += 1
            var s = String("")
            while i < n:
                var _s = i
                var cc = content[i]
                if cc == 93:  # ]
                    i += 1
                    break
                elif cc == 40:
                    var raw = List[UInt8]()
                    i = _read_literal_raw(content, i, raw)
                    s += cur.decode(raw)
                elif cc == 60:
                    var raw = List[UInt8]()
                    i = _read_hex_raw(content, i, raw)
                    s += cur.decode(raw)
                elif _is_digit(cc) or cc == 45 or cc == 43 or cc == 46:
                    var adj = _read_number(content, i)
                    if (
                        (adj > _TJ_WORDGAP or adj < -_TJ_WORDGAP)
                        and s.byte_length() > 0
                        and not s.endswith(" ")
                    ):
                        s += " "
                else:
                    i += 1
                if i == _s:
                    i += 1
            if s.byte_length() > 0:
                var w = _est_width(s, font_size)
                frags.append(_Frag(pen_y, pen_x, font_size, s^))
                pen_x += w
        elif c == 60:  # <
            if i + 1 < n and content[i + 1] == 60:
                i += 2  # << dict
            else:
                var raw = List[UInt8]()
                i = _read_hex_raw(content, i, raw)
                var s = cur.decode(raw)
                if s.byte_length() > 0:
                    var w = _est_width(s, font_size)
                    frags.append(_Frag(pen_y, pen_x, font_size, s^))
                    pen_x += w
        elif c == 47:  # /Name
            last_name = _name_at(content, i)
            i += 1
        elif c == 39 or c == 34:  # ' or " — next-line-and-show
            tlm_y -= leading if leading > 0.0 else font_size
            pen_x = tlm_x
            pen_y = tlm_y
            i += 1
        elif _is_digit(c) or c == 45 or c == 43 or c == 46:
            var nums = List[Float64]()
            var j = i
            while len(nums) < 6:
                var save = j
                var v = _read_number(content, j)
                if j == save:
                    break
                nums.append(v)
                var k = j
                while k < n and _is_ws(content[k]):
                    k += 1
                if k >= n or not (
                    _is_digit(content[k])
                    or content[k] == 45
                    or content[k] == 43
                    or content[k] == 46
                ):
                    break
            i = j
            while i < n and _is_ws(content[i]):
                i += 1
            if i + 1 < n and content[i] == 84:  # 'T'
                var b = content[i + 1]
                var cnt = len(nums)
                if (
                    b == 100 or b == 68
                ) and cnt >= 2:  # Td / TD — relative to LINE start
                    tlm_x += nums[cnt - 2]
                    tlm_y += nums[cnt - 1]
                    if b == 68:  # TD also sets leading = -ty
                        leading = -nums[cnt - 1]
                    pen_x = tlm_x
                    pen_y = tlm_y
                elif b == 109 and cnt >= 6:  # Tm a b c d e f — absolute
                    tlm_x = nums[4]
                    tlm_y = nums[5]
                    pen_x = nums[4]
                    pen_y = nums[5]
                elif b == 76 and cnt >= 1:  # TL — set leading
                    leading = nums[cnt - 1]
                    if leading < 0.0:
                        leading = -leading
                elif b == 102 and cnt >= 1:  # Tf size
                    font_size = nums[cnt - 1]
                    if font_size < 0:
                        font_size = -font_size
        elif _is_alpha(c):
            var j = i
            while j < n and (_is_alpha(content[j]) or content[j] == 42):
                j += 1
            var ln = j - i
            if ln == 2 and content[i] == 84:  # 'T_'
                var b = content[i + 1]
                if b == 42:  # T* — next line by leading
                    tlm_y -= leading if leading > 0.0 else font_size
                    pen_x = tlm_x
                    pen_y = tlm_y
                elif b == 102:  # Tf select
                    var idx = ft.get(last_name)
                    if idx >= 0:
                        cur = ft.fonts[idx].copy()
                    else:
                        cur = Font()
            elif (
                ln == 2 and content[i] == 66 and content[i + 1] == 84
            ):  # BT — reset
                tlm_x = 0.0
                tlm_y = 0.0
                pen_x = 0.0
                pen_y = 0.0
            i = j
        else:
            i += 1
        if i == _start:
            i += 1
    return frags^


def _layout_frags(frags: List[_Frag]) raises -> String:
    """Regroup `frags` into visual rows by y (a Dict bucket per quantized baseline,
    so draw order doesn't matter), top-to-bottom; within a row, order left-to-right
    by x and pad with spaces proportional to the horizontal gaps."""
    if len(frags) == 0:
        return String("")
    comptime Y_TOL = 2.5  # text-space units; runs within this share a row
    var bucket = Dict[Int, Int]()  # y-key -> index into groups
    var keys = List[Int]()
    var groups = List[List[_Frag]]()
    for f in range(len(frags)):
        var yv = frags[f].y / Y_TOL
        var key = Int(yv + 0.5) if yv >= 0.0 else Int(yv - 0.5)
        if key in bucket:
            groups[bucket[key]].append(frags[f].copy())
        else:
            bucket[key] = len(groups)
            keys.append(key)
            var g = List[_Frag]()
            g.append(frags[f].copy())
            groups.append(g^)
    # rows top-to-bottom: PDF y increases UPWARD, so sort keys DESCENDING.
    for a in range(1, len(keys)):
        var kk = keys[a]
        var gg = groups[a].copy()
        var b = a - 1
        while b >= 0 and keys[b] < kk:
            keys[b + 1] = keys[b]
            groups[b + 1] = groups[b].copy()
            b -= 1
        keys[b + 1] = kk
        groups[b + 1] = gg^
    var out = String("")
    for g in range(len(groups)):
        # left-to-right within the row.
        for a in range(1, len(groups[g])):
            var kf = groups[g][a].copy()
            var b = a - 1
            while b >= 0 and groups[g][b].x > kf.x:
                groups[g][b + 1] = groups[g][b].copy()
                b -= 1
            groups[g][b + 1] = kf^
        var line = String("")
        var penx = 0.0
        for t in range(len(groups[g])):
            ref fr = groups[g][t]
            if t > 0:
                # Only a gap BEYOND the glyphs already drawn, and past a word-sized
                # threshold, opens space — so per-glyph-positioned text (each letter
                # its own frag) doesn't get a space wedged between every letter.
                # Column gaps (≫ a word) get proportional spaces so columns align.
                var gap = fr.x - penx
                var space_w = fr.fs * 0.25
                if space_w <= 0.0:
                    space_w = 2.0
                if gap > _H_WORDGAP_EM * fr.fs:
                    var nsp = Int(gap / space_w + 0.5)
                    if nsp < 1:
                        nsp = 1
                    if nsp > 60:
                        nsp = 60
                    for _sp in range(nsp):
                        line += " "
            line += fr.text
            penx = fr.x + _est_width(fr.text, fr.fs)
        out += line + "\n"
    return out^


def extract_content(content: List[UInt8]) raises -> String:
    """Latin-1 text from one content stream (no font map). Kept for the
    no-resources case + tests."""
    var ft = FontTable()
    return _extract_with_fonts(content, ft)


# ── object map + page tree (reliable content-stream selection) ───────────────


struct ObjMap(Movable):
    """Object number -> byte offset of its body (just after `N G obj`). Built by
    scanning for `obj` keywords — robust to a broken/absent xref, and avoids
    parsing xref *streams*. (Objects inside compressed /ObjStm are not seen — a
    later phase.)"""

    var nums: List[Int]
    var offs: List[Int]

    def __init__(out self):
        self.nums = List[Int]()
        self.offs = List[Int]()

    def get(self, num: Int) -> Int:
        for i in range(len(self.nums)):
            if self.nums[i] == num:
                return self.offs[i]
        return -1


def _build_objmap(data: List[UInt8]) -> ObjMap:
    var m = ObjMap()
    var kw = _ascii("obj")
    var n = len(data)
    var pos = 0
    while True:
        var o = _find(data, kw, pos)
        if o == -1:
            break
        pos = o + 3
        # "obj" must be a token: next char a delimiter (not part of "object" etc).
        if o + 3 < n and _is_alpha(data[o + 3]):
            continue
        # Back up over: ws, gen digits, ws, num digits.
        var p = o - 1
        while p >= 0 and _is_ws(data[p]):
            p -= 1
        var ge = p
        while p >= 0 and _is_digit(data[p]):
            p -= 1
        if p == ge:
            continue
        while p >= 0 and _is_ws(data[p]):
            p -= 1
        var ne = p
        while p >= 0 and _is_digit(data[p]):
            p -= 1
        if p == ne:
            continue
        var num = 0
        for k in range(p + 1, ne + 1):
            num = num * 10 + (Int(data[k]) - 48)
        m.nums.append(num)
        m.offs.append(o + 3)
    return m^


def _read_int_fwd(data: List[UInt8], mut p: Int) -> Int:
    """Skip whitespace then read a non-negative integer at `p`; advance `p`. -1 if none.
    """
    var n = len(data)
    while p < n and _is_ws(data[p]):
        p += 1
    var v = 0
    var any = False
    while p < n and _is_digit(data[p]):
        v = v * 10 + (Int(data[p]) - 48)
        p += 1
        any = True
    return v if any else -1


def _parse_ref(data: List[UInt8], mut p: Int) -> Int:
    """Parse `N G R` at `p` (after skipping ws); return N (object number) or -1.
    """
    var save = p
    var num = _read_int_fwd(data, p)
    if num < 0:
        p = save
        return -1
    var gen = _read_int_fwd(data, p)
    if gen < 0:
        p = save
        return -1
    var n = len(data)
    while p < n and _is_ws(data[p]):
        p += 1
    if p < n and data[p] == 82:  # 'R'
        p += 1
        return num
    p = save
    return -1


def _obj_end(data: List[UInt8], start: Int) -> Int:
    var e = _find(data, _ascii("endobj"), start)
    return e if e != -1 else len(data)


def _contents_refs(data: List[UInt8], lo: Int, hi: Int) -> List[Int]:
    """Object numbers referenced by `/Contents` (a single ref or an array)."""
    var out = List[Int]()
    var key = _ascii("/Contents")
    var k = _find(data, key, lo)
    if k == -1 or k >= hi:
        return out^
    var p = k + len(key)
    var n = len(data)
    while p < n and _is_ws(data[p]):
        p += 1
    if p < n and data[p] == 91:  # '['
        p += 1
        while True:
            while p < n and _is_ws(data[p]):
                p += 1
            if p >= n or data[p] == 93:  # ']'
                break
            var r = _parse_ref(data, p)
            if r < 0:
                break
            out.append(r)
    else:
        var r = _parse_ref(data, p)
        if r >= 0:
            out.append(r)
    return out^


def decode_object_stream(
    data: List[UInt8], omap: ObjMap, objnum: Int
) raises -> List[UInt8]:
    """Decoded bytes of object `objnum`'s stream (inflating /FlateDecode)."""
    var start = omap.get(objnum)
    if start < 0:
        return List[UInt8]()
    var hi = _obj_end(data, start)
    var s = _find(data, _ascii("stream"), start)
    if s == -1 or s >= hi:
        return List[UInt8]()
    var ds = s + 6
    var n = len(data)
    if ds < n and data[ds] == 13:
        ds += 1
    if ds < n and data[ds] == 10:
        ds += 1
    var e = _find(data, _ascii("endstream"), ds)
    if e == -1:
        return List[UInt8]()
    var re = e
    if re > ds and data[re - 1] == 10:
        re -= 1
    if re > ds and data[re - 1] == 13:
        re -= 1
    var raw = List[UInt8]()
    for i in range(ds, re):
        raw.append(data[i])
    if _window_has(data, _ascii("/FlateDecode"), start, s):
        try:
            return inflate(raw)
        except:
            # Inflate failed (corrupt stream, or the zlib shim couldn't load —
            # e.g. run bare without CONDA_PREFIX). NEVER emit the raw compressed
            # bytes as "text"; drop the stream so the failure shows as missing
            # text, not terminal-garbling binary.
            return List[UInt8]()
    return raw^


def _is_page_leaf(data: List[UInt8], lo: Int, hi: Int) -> Bool:
    """A page leaf has /Contents and a `/Page` type (not `/Pages`)."""
    if not _window_has(data, _ascii("/Contents"), lo, hi):
        return False
    var key = _ascii("/Page")
    var k = _find(data, key, lo)
    while k != -1 and k < hi:
        var after = k + len(key)
        if after >= len(data) or data[after] != 115:  # not 's' -> "/Page"
            return True
        k = _find(data, key, k + 1)
    return False


def page_objs(data: List[UInt8], omap: ObjMap) -> List[Int]:
    """Object numbers of the page leaves, in object-number order (a good proxy for
    reading order; the page-tree /Kids order is a refinement for later)."""
    # selection sort of object numbers (small N).
    var order = List[Int]()
    for i in range(len(omap.nums)):
        order.append(omap.nums[i])
    for i in range(len(order)):
        var mi = i
        for j in range(i + 1, len(order)):
            if order[j] < order[mi]:
                mi = j
        var t = order[i]
        order[i] = order[mi]
        order[mi] = t

    var pages = List[Int]()
    for i in range(len(order)):
        var start = omap.get(order[i])
        var hi = _obj_end(data, start)
        if _is_page_leaf(data, start, hi):
            pages.append(order[i])
    return pages^


def page_content(
    data: List[UInt8], omap: ObjMap, page_num: Int
) raises -> List[UInt8]:
    """Concatenated decoded content streams for one page."""
    var start = omap.get(page_num)
    var hi = _obj_end(data, start)
    var refs = _contents_refs(data, start, hi)
    var out = List[UInt8]()
    for i in range(len(refs)):
        var c = decode_object_stream(data, omap, refs[i])
        for j in range(len(c)):
            out.append(c[j])
        out.append(10)  # separate streams with a newline
    return out^


# ── fonts + /ToUnicode CMaps ─────────────────────────────────────────────────


struct Font(Copyable, Movable):
    """A font's character-code -> Unicode-text map (from its /ToUnicode CMap). An
    empty map means decode bytes as Latin-1 — correct for base-14 WinAnsi fonts,
    where the byte already IS the character."""

    var code_len: Int  # bytes per character code (1 or 2)
    var map: Dict[Int, String]  # char code -> Unicode text; O(1) lookup (was a
    #                             linear List scan per char → O(n^2) on big CMaps)

    def __init__(out self):
        self.code_len = 1
        self.map = Dict[Int, String]()

    def has_map(self) -> Bool:
        return len(self.map) > 0

    def decode(self, raw: List[UInt8]) raises -> String:
        # Build into a byte buffer (amortized O(1) append), not String += per char
        # (O(n^2) — a fallback literal/blob can be huge, which hung extraction).
        var buf = List[UInt8]()
        if not self.has_map():
            for i in range(len(raw)):
                var b = Int(raw[i])
                if b < 128:
                    buf.append(UInt8(b))
                else:  # Latin-1 codepoint → 2-byte UTF-8
                    buf.append(UInt8(0xC0 | (b >> 6)))
                    buf.append(UInt8(0x80 | (b & 0x3F)))
            return String(unsafe_from_utf8=Span(buf))
        var i = 0
        var n = len(raw)
        while i < n:
            var code = Int(raw[i])
            if self.code_len == 2 and i + 1 < n:
                code = (code << 8) | Int(raw[i + 1])
                i += 2
            else:
                i += 1
            if code in self.map:
                var sb = self.map[code].as_bytes()
                for k in range(len(sb)):
                    buf.append(sb[k])
            elif code >= 32 and code < 127:
                buf.append(UInt8(code))  # unmapped but printable — keep it
        return String(unsafe_from_utf8=Span(buf))


struct FontTable(Movable):
    var names: List[String]
    var fonts: List[Font]

    def __init__(out self):
        self.names = List[String]()
        self.fonts = List[Font]()

    def get(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1


def _hex_bytes(data: List[UInt8], mut p: Int) -> List[UInt8]:
    """Read a `<..>` hex token at `p` (the `<`); advance past `>`."""
    var out = List[UInt8]()
    var n = len(data)
    if p >= n or data[p] != 60:
        return out^
    p += 1
    var hi = -1
    while p < n and data[p] != 62:
        var hv = _hexval(data[p])
        if hv >= 0:
            if hi < 0:
                hi = hv
            else:
                out.append(UInt8((hi << 4) | hv))
                hi = -1
        p += 1
    if p < n:
        p += 1  # skip '>'
    if hi >= 0:
        out.append(UInt8(hi << 4))
    return out^


def _bytes_to_int(b: List[UInt8]) -> Int:
    var v = 0
    for i in range(len(b)):
        v = (v << 8) | Int(b[i])
    return v


def _utf16be(b: List[UInt8]) -> String:
    """Decode UTF-16BE bytes (the /ToUnicode dst format) to a String."""
    var o = String("")
    var i = 0
    var n = len(b)
    while i + 1 < n:
        var u = (Int(b[i]) << 8) | Int(b[i + 1])
        i += 2
        if u >= 0xD800 and u <= 0xDBFF and i + 1 < n:  # surrogate pair
            var lo = (Int(b[i]) << 8) | Int(b[i + 1])
            i += 2
            o += chr(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00))
        else:
            o += chr(u)
    return o^


def _parse_bfchar(cmap: List[UInt8], lo: Int, hi: Int, mut f: Font):
    var p = lo
    while p < hi:
        while p < hi and cmap[p] != 60:  # to '<'
            p += 1
        if p >= hi:
            break
        var src = _hex_bytes(cmap, p)
        while p < hi and cmap[p] != 60:
            p += 1
        if p >= hi:
            break
        var dst = _hex_bytes(cmap, p)
        if len(src) > 0:
            f.map[_bytes_to_int(src)] = _utf16be(dst)


def _parse_bfrange(cmap: List[UInt8], lo: Int, hi: Int, mut f: Font):
    var p = lo
    while p < hi:
        while p < hi and cmap[p] != 60:
            p += 1
        if p >= hi:
            break
        var b_lo = _hex_bytes(cmap, p)
        while p < hi and cmap[p] != 60:
            p += 1
        if p >= hi:
            break
        var b_hi = _hex_bytes(cmap, p)
        while p < hi and _is_ws(cmap[p]):
            p += 1
        if p >= hi:
            break
        var clo = _bytes_to_int(b_lo)
        var chi = _bytes_to_int(b_hi)
        if cmap[p] == 91:  # [ <d0> <d1> ... ]
            p += 1
            var code = clo
            while p < hi and cmap[p] != 93:
                while p < hi and _is_ws(cmap[p]):
                    p += 1
                if p < hi and cmap[p] == 60:
                    var d = _hex_bytes(cmap, p)
                    f.map[code] = _utf16be(d)
                    code += 1
                else:
                    break
            if p < hi and cmap[p] == 93:
                p += 1
        else:  # <dst> incrementing
            var d = _hex_bytes(cmap, p)
            var base = _bytes_to_int(d)
            var code = clo
            while code <= chi:
                var u = base + (code - clo)
                var bb = List[UInt8]()
                bb.append(UInt8((u >> 8) & 0xFF))
                bb.append(UInt8(u & 0xFF))
                f.map[code] = _utf16be(bb)
                code += 1


def _parse_cmap(cmap: List[UInt8], mut f: Font):
    # code length from the first codespacerange entry.
    var csr = _find(cmap, _ascii("begincodespacerange"), 0)
    if csr != -1:
        var p = csr + 19
        while p < len(cmap) and cmap[p] != 60:
            p += 1
        var b = _hex_bytes(cmap, p)
        if len(b) > 0:
            f.code_len = len(b)
    var bc = _find(cmap, _ascii("beginbfchar"), 0)
    while bc != -1:
        var end = _find(cmap, _ascii("endbfchar"), bc)
        if end == -1:
            break
        _parse_bfchar(cmap, bc + 11, end, f)
        bc = _find(cmap, _ascii("beginbfchar"), end + 1)
    var br = _find(cmap, _ascii("beginbfrange"), 0)
    while br != -1:
        var end = _find(cmap, _ascii("endbfrange"), br)
        if end == -1:
            break
        _parse_bfrange(cmap, br + 12, end, f)
        br = _find(cmap, _ascii("beginbfrange"), end + 1)


def _load_font(data: List[UInt8], omap: ObjMap, fontref: Int) raises -> Font:
    var f = Font()
    var start = omap.get(fontref)
    if start < 0:
        return f^
    var hi = _obj_end(data, start)
    var tk = _find(data, _ascii("/ToUnicode"), start)
    if tk == -1 or tk >= hi:
        return f^  # base-14/WinAnsi font — Latin-1
    var p = tk + 10
    var uref = _parse_ref(data, p)
    if uref < 0:
        return f^
    var cmap = decode_object_stream(data, omap, uref)
    _parse_cmap(cmap, f)
    return f^


def build_fonts(
    data: List[UInt8], omap: ObjMap, page_num: Int
) raises -> FontTable:
    """Map each font name in the page's `/Resources /Font` dict to its loaded Font.
    v1 handles an inline `/Font << /Fx N G R … >>` (indirect /Resources is a TODO).
    """
    var ft = FontTable()
    var start = omap.get(page_num)
    var hi = _obj_end(data, start)
    var fk = _find(data, _ascii("/Font"), start)
    if fk == -1 or fk >= hi:
        return ft^
    var p = fk + 5
    var n = len(data)
    while p < n and _is_ws(data[p]):
        p += 1
    if not (p + 1 < n and data[p] == 60 and data[p + 1] == 60):
        return ft^  # /Font is an indirect ref — TODO
    p += 2
    while p < hi:
        while p < hi and _is_ws(data[p]):
            p += 1
        if p + 1 < hi and data[p] == 62 and data[p + 1] == 62:  # >>
            break
        if p < hi and data[p] == 47:  # /name
            var nm = _name_at(data, p)
            var fref = _parse_ref(data, p)
            if fref >= 0:
                ft.names.append(nm^)
                ft.fonts.append(_load_font(data, omap, fref))
        else:
            p += 1
    return ft^


def extract_text(data: List[UInt8]) raises -> String:
    """Top level: walk the object map to the page leaves, decode each page's
    /Contents, and extract its text through that page's fonts (applying
    /ToUnicode). Falls back to the stream-scan heuristic if no pages are found.
    """
    var omap = _build_objmap(data)
    var pages = page_objs(data, omap)
    if len(pages) == 0:
        return _extract_fallback(data)
    var out = String("")
    for pi in range(len(pages)):
        if pi > 0:
            out += "\n"
        var content = page_content(data, omap, pages[pi])
        var ft = build_fonts(data, omap, pages[pi])
        out += _extract_with_fonts(content, ft)
    return out^


def extract_text_layout(data: List[UInt8]) raises -> String:
    """Like `extract_text`, but LAYOUT-PRESERVING: each page's runs are regrouped
    into visual rows (by y) and aligned left-to-right (by x), so table columns —
    a statement's date / description / amount / running-balance — stay on one line.
    Used by the indexer's transaction extraction; `extract_text` (stream order)
    still backs chunking/search."""
    var omap = _build_objmap(data)
    var pages = page_objs(data, omap)
    if len(pages) == 0:
        return _extract_fallback(data)
    var out = String("")
    for pi in range(len(pages)):
        if pi > 0:
            out += "\n"
        var content = page_content(data, omap, pages[pi])
        var ft = build_fonts(data, omap, pages[pi])
        out += _layout_frags(_collect_frags(content, ft))
    return out^


def _extract_fallback(data: List[UInt8]) raises -> String:
    """Heuristic: decode every BT-bearing stream and concatenate its text."""
    var streams = decode_streams(data)
    var out = String("")
    for idx in range(len(streams)):
        if idx > 0:
            out += "\n"
        out += extract_content(streams[idx])
    return out^


def read_file(path: String) raises -> List[UInt8]:
    """Read a file as raw bytes."""
    var out = List[UInt8]()
    with open(path, "r") as f:
        var b = f.read_bytes()
        for i in range(len(b)):
            out.append(b[i])
    return out^
