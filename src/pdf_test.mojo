"""pdf extraction gate: content-stream text ops + a FlateDecode round-trip
(deflate a content stream via zlib.mojo, assemble a minimal PDF, extract)."""

from pdf import extract_text, extract_content
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
        "BT /F1 12 Tf 72 700 Td (Hello, PDF!) Tj 0 -14 Td (Second line) Tj ET")
    var t1 = extract_content(c1)
    if t1.find("Hello, PDF!") == -1 or t1.find("Second line") == -1:
        raise Error("content extraction failed: [" + t1 + "]")

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

    print("pdf extraction OK")
    print("  text ops -> Hello, PDF! / Second line")
    print("  flate    -> ", t2)
