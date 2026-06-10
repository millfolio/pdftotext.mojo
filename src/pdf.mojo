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

def _read_literal_raw(content: List[UInt8], start: Int, mut raw: List[UInt8]) -> Int:
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
                while k < 2 and i + 1 < n and content[i + 1] >= 48 and content[i + 1] <= 55:
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


def _read_hex_raw(content: List[UInt8], start: Int, mut raw: List[UInt8]) -> Int:
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
    """Read a `/Name` token at `p` (the `/`); return the name (no slash); advance p."""
    var n = len(content)
    p += 1  # skip '/'
    var s = String("")
    while p < n:
        var c = content[p]
        if _is_ws(c) or c == 47 or c == 60 or c == 62 or c == 91 or c == 93 or c == 40 or c == 41:
            break
        s += chr(Int(c))
        p += 1
    return s^


def _extract_with_fonts(content: List[UInt8], ft: FontTable) raises -> String:
    """Pull shown text from one content stream, decoding each string through the
    current font (`/Fx Tf`) — applying its /ToUnicode CMap when present, else
    Latin-1. Positioning operators (Td/TD/Tm/T*/'/") insert a newline."""
    var out = String("")
    var n = len(content)
    var i = 0
    var cur = Font()           # default: Latin-1
    var last_name = String("")
    while i < n:
        var c = content[i]
        if c == 40:  # ( literal string
            var raw = List[UInt8]()
            i = _read_literal_raw(content, i, raw)
            out += cur.decode(raw)
        elif c == 60:  # <
            if i + 1 < n and content[i + 1] == 60:
                i += 2  # << dict
            else:
                var raw = List[UInt8]()
                i = _read_hex_raw(content, i, raw)
                out += cur.decode(raw)
        elif c == 47:  # /Name
            last_name = _name_at(content, i)
        elif c == 39 or c == 34:  # ' or "
            out += "\n"
            i += 1
        elif _is_alpha(c):
            var j = i
            while j < n and (_is_alpha(content[j]) or content[j] == 42):
                j += 1
            var ln = j - i
            if ln == 2 and content[i] == 84:  # 'T'
                var b = content[i + 1]
                if b == 100 or b == 68 or b == 109 or b == 42:  # Td TD Tm T*
                    out += "\n"
                elif b == 102:  # Tf — select font
                    var idx = ft.get(last_name)
                    if idx >= 0:
                        cur = ft.fonts[idx].copy()
                    else:
                        cur = Font()
            i = j
        else:
            i += 1
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


# ── fonts + /ToUnicode CMaps ─────────────────────────────────────────────────

struct Font(Movable, Copyable):
    """A font's character-code -> Unicode-text map (from its /ToUnicode CMap). An
    empty map means decode bytes as Latin-1 — correct for base-14 WinAnsi fonts,
    where the byte already IS the character."""

    var code_len: Int          # bytes per character code (1 or 2)
    var codes: List[Int]
    var vals: List[String]

    def __init__(out self):
        self.code_len = 1
        self.codes = List[Int]()
        self.vals = List[String]()

    def has_map(self) -> Bool:
        return len(self.codes) > 0

    def _lookup(self, code: Int) -> Int:
        for i in range(len(self.codes)):
            if self.codes[i] == code:
                return i
        return -1

    def decode(self, raw: List[UInt8]) -> String:
        var o = String("")
        if not self.has_map():
            for i in range(len(raw)):
                o += chr(Int(raw[i]))
            return o^
        var i = 0
        var n = len(raw)
        while i < n:
            var code = Int(raw[i])
            if self.code_len == 2 and i + 1 < n:
                code = (code << 8) | Int(raw[i + 1])
                i += 2
            else:
                i += 1
            var idx = self._lookup(code)
            if idx >= 0:
                o += self.vals[idx]
            elif code >= 32 and code < 127:
                o += chr(code)  # unmapped but printable — keep it
        return o^


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
            f.codes.append(_bytes_to_int(src))
            f.vals.append(_utf16be(dst))


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
                    f.codes.append(code)
                    f.vals.append(_utf16be(d))
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
                f.codes.append(code)
                f.vals.append(_utf16be(bb))
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


def build_fonts(data: List[UInt8], omap: ObjMap, page_num: Int) raises -> FontTable:
    """Map each font name in the page's `/Resources /Font` dict to its loaded Font.
    v1 handles an inline `/Font << /Fx N G R … >>` (indirect /Resources is a TODO)."""
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
    /ToUnicode). Falls back to the stream-scan heuristic if no pages are found."""
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
