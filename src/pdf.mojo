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
    """Index of the first occurrence of `pat` in `data` at/after `start`, or -1."""
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

def _emit_byte(mut out: String, b: UInt8):
    # v1: map a single byte to a codepoint (Latin-1 / ASCII-correct).
    out += chr(Int(b))


def _read_literal(content: List[UInt8], start: Int, mut out: String) -> Int:
    """Parse a `(...)` literal string beginning at `start` (the `(`); append its
    decoded text to `out`; return the index just past the closing `)`."""
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
            if e == 110:    # \n
                _emit_byte(out, 10)
            elif e == 114:  # \r
                _emit_byte(out, 13)
            elif e == 116:  # \t
                _emit_byte(out, 9)
            elif e == 98:   # \b
                _emit_byte(out, 8)
            elif e == 102:  # \f
                _emit_byte(out, 12)
            elif e == 10 or e == 13:
                pass        # line continuation — emit nothing
            elif e >= 48 and e <= 55:  # \ddd octal (1-3 digits)
                var v = Int(e) - 48
                var k = 0
                while k < 2 and i + 1 < n and content[i + 1] >= 48 and content[i + 1] <= 55:
                    i += 1
                    v = v * 8 + (Int(content[i]) - 48)
                    k += 1
                _emit_byte(out, UInt8(v & 0xFF))
            else:
                _emit_byte(out, e)  # \( \) \\ and any other -> literal
            i += 1
        elif c == 40:  # nested (
            depth += 1
            _emit_byte(out, c)
            i += 1
        elif c == 41:  # )
            depth -= 1
            if depth == 0:
                i += 1
                break
            _emit_byte(out, c)
            i += 1
        else:
            _emit_byte(out, c)
            i += 1
    return i


def _read_hex(content: List[UInt8], start: Int, mut out: String) -> Int:
    """Parse a `<...>` hex string at `start` (the `<`); append decoded bytes."""
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
                _emit_byte(out, UInt8((hi << 4) | hv))
                hi = -1
        i += 1
    if hi >= 0:  # odd digit: low nibble is 0
        _emit_byte(out, UInt8(hi << 4))
    return i


def extract_content(content: List[UInt8]) raises -> String:
    """Pull shown text from one content stream. Strings are emitted in order;
    positioning operators (Td/TD/Tm/T*/'/") insert a newline."""
    var out = String("")
    var n = len(content)
    var i = 0
    while i < n:
        var c = content[i]
        if c == 40:  # ( literal string
            i = _read_literal(content, i, out)
        elif c == 60:  # <
            if i + 1 < n and content[i + 1] == 60:
                i += 2  # << dictionary — skip
            else:
                i = _read_hex(content, i, out)
        elif c == 39 or c == 34:  # ' or " -> next-line show operators
            out += "\n"
            i += 1
        elif _is_alpha(c):
            var j = i
            while j < n and (_is_alpha(content[j]) or content[j] == 42):  # incl '*'
                j += 1
            # positioning operators that move to a new line/origin
            var two = (j - i) == 2
            if two and content[i] == 84:  # 'T'
                var b = content[i + 1]
                if b == 100 or b == 68 or b == 109 or b == 42:  # Td TD Tm T*
                    out += "\n"
            i = j
        else:
            i += 1
    return out^


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
    """Skip whitespace then read a non-negative integer at `p`; advance `p`. -1 if none."""
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
    """Parse `N G R` at `p` (after skipping ws); return N (object number) or -1."""
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


def decode_object_stream(data: List[UInt8], omap: ObjMap, objnum: Int) raises -> List[UInt8]:
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
            return raw^
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


def page_content(data: List[UInt8], omap: ObjMap, page_num: Int) raises -> List[UInt8]:
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


def extract_text(data: List[UInt8]) raises -> String:
    """Top level: walk the object map to the page leaves, decode each page's
    /Contents, and extract its text. Falls back to the stream-scan heuristic if no
    pages are found (broken/structureless PDFs)."""
    var omap = _build_objmap(data)
    var pages = page_objs(data, omap)
    if len(pages) == 0:
        return _extract_fallback(data)
    var out = String("")
    for pi in range(len(pages)):
        if pi > 0:
            out += "\n"
        var content = page_content(data, omap, pages[pi])
        out += extract_content(content)
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
