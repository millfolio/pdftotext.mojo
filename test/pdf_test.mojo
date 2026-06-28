"""pdf extraction gate: content-stream text ops + a FlateDecode round-trip
(deflate a content stream via zlib.mojo, assemble a minimal PDF, extract)."""

from pdf import extract_text, extract_content, read_file
from pdf import _collect_frags, _layout_frags, FontTable
from zlib import deflate


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        out.append(p[i])
    return out^


def _extend(mut a: List[UInt8], b: List[UInt8]):
    for i in range(len(b)):
        a.append(b[i])


def main() raises:
    # 1. Content-stream text operators (uncompressed path): literal strings +
    #    newline on positioning ops.
    var c1 = _b(
        "BT /F1 12 Tf 72 700 Td (Hello, PDF!) Tj 0 -14 Td (Second line) Tj ET"
    )
    var t1 = extract_content(c1)
    if t1.find("Hello, PDF!") == -1 or t1.find("Second line") == -1:
        raise Error("content extraction failed: [" + t1 + "]")

    # 1b. Glyph-by-glyph positioning must NOT explode into one char per line.
    #     A line laid out as per-glyph `(c) Tj <step> 0 Td` (a kerning/justify
    #     engine, e.g. some bank statements) stays one line; the wide gap with no
    #     glyph becomes a single space; the real vertical move starts a new line;
    #     a TJ array with a large kern opens a word space ("Total due").
    var c1b = _b(
        "BT /F1 12 Tf 72 700 Td (o) Tj 7 0 Td (o) Tj 7 0 Td (n) Tj 7 0 Td "
        "12 0 Td (a) Tj 7 0 Td (s) Tj 7 0 Td 12 0 Td (y) Tj 7 0 Td (o) Tj "
        "7 0 Td (u) Tj 7 0 Td -200 -16 Td "
        "[(T) -40 (o) -20 (t) -15 (a) -10 (l) 250 (d) -20 (u) -15 (e)] TJ ET"
    )
    var t1b = extract_content(c1b)
    if t1b.find("oon as you") == -1:
        raise Error("per-glyph line collapsed/garbled: [" + t1b + "]")
    if t1b.find("Total due") == -1:
        raise Error("TJ word gap not honored: [" + t1b + "]")
    # the per-glyph line must be a SINGLE line (one newline, before "Total")
    if t1b.find("o\no") != -1:
        raise Error("char-per-line regression: [" + t1b + "]")

    # 2. Full path through zlib.mojo: a /FlateDecode stream is inflated, then text
    #    extracted. Build the compressed stream in-process with zlib.deflate.
    var content = _b("BT /F1 12 Tf 72 700 Td (Flate works!) Tj ET")
    var comp = deflate(content)
    var pdf = List[UInt8]()
    _extend(pdf, _b("%PDF-1.4\n1 0 obj << /Filter /FlateDecode >>\nstream\n"))
    _extend(pdf, comp)
    _extend(pdf, _b("\nendstream\nendobj\n"))
    var t2 = extract_text(pdf)
    if t2.find("Flate works!") == -1:
        raise Error("FlateDecode extraction failed: [" + t2 + "]")

    # 3. Real-PDF fixture: full path through the object map + page tree (xref,
    #    catalog/pages/page, FlateDecode content, base-14 Helvetica/WinAnsi).
    var t3 = extract_text(read_file("tests/fixtures/hello.pdf"))
    if (
        t3.find("Hello, headgate!") == -1
        or t3.find("PDF parsing in pure Mojo.") == -1
    ):
        raise Error("hello.pdf extraction failed: [" + t3 + "]")

    # 4. /ToUnicode: the content shows hex codes <0102030304>; only the font's
    #    CMap turns them into "Hello".
    var t4 = extract_text(read_file("tests/fixtures/cmap.pdf"))
    if t4.find("Hello") == -1:
        raise Error("cmap.pdf /ToUnicode extraction failed: [" + t4 + "]")

    # 5. LAYOUT-PRESERVING extraction: a 2-row × 3-column table drawn with each
    #    cell ABSOLUTELY positioned (Tm), and — critically — the amount column
    #    drawn FIRST (out of visual order) to prove rows are regrouped by y, not by
    #    draw order. Each row must come back on ONE line, columns left-to-right,
    #    top row (higher y) first, with the date adjacent to its own description.
    var lay = _b(
        "BT /F1 8 Tf "
        "1 0 0 1 400 700 Tm (4.50) Tj "  # amount col drawn first (row 1)
        "1 0 0 1 360 688 Tm (89.99) Tj "  # amount col drawn first (row 2)
        "1 0 0 1 72 700 Tm (4/20) Tj "  # date col (row 1)
        "1 0 0 1 150 700 Tm (Coffee Shop) Tj "
        "1 0 0 1 72 688 Tm (4/21) Tj "  # date col (row 2)
        "1 0 0 1 150 688 Tm (Hardware Store) Tj ET"
    )
    var tl = _layout_frags(_collect_frags(lay, FontTable()))
    var lines = tl.split("\n")
    var row1 = String("")
    var row2 = String("")
    for li in range(len(lines)):
        var s = String(lines[li])
        if s.find("4/20") != -1:
            row1 = s
        elif s.find("4/21") != -1:
            row2 = s
    # row 1: date, description, amount all on ONE line, in column order.
    if (
        row1.find("4/20") == -1
        or row1.find("Coffee Shop") == -1
        or row1.find("4.50") == -1
    ):
        raise Error("layout row 1 not regrouped onto one line: [" + row1 + "]")
    if not (row1.find("4/20") < row1.find("Coffee Shop") < row1.find("4.50")):
        raise Error("layout row 1 columns out of x-order: [" + row1 + "]")
    if (
        row2.find("4/21") == -1
        or row2.find("Hardware Store") == -1
        or row2.find("89.99") == -1
    ):
        raise Error("layout row 2 not regrouped onto one line: [" + row2 + "]")
    # top row (y=700) must precede the lower row (y=688) despite draw order.
    if tl.find("4/20") > tl.find("4/21"):
        raise Error("layout rows not top-to-bottom: [" + tl + "]")
    # column gap → multiple spaces between description and amount (alignment).
    if row1.find("Shop  ") == -1:
        raise Error("layout did not pad the column gap: [" + row1 + "]")

    print("pdf extraction OK")
    print("  text ops  -> Hello, PDF! / Second line")
    print("  per-glyph -> 'oon as you' / 'Total due' (no char-per-line)")
    print("  flate     -> ", t2)
    print("  hello.pdf -> both lines via page tree")
    print("  cmap.pdf  -> 'Hello' via /ToUnicode")
