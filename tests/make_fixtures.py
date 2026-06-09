#!/usr/bin/env python3
"""Generate deterministic real-PDF fixtures for pdftotext.mojo's tests.

Produces two valid PDFs (proper xref table + catalog/pages/page tree):

  hello.pdf  — base-14 Helvetica/WinAnsi font; the content stream is FlateDecode
               and shows ASCII literal strings (text == string bytes).
  cmap.pdf   — a font with a /ToUnicode CMap; the content shows a hex string of
               *codes* (01 02 03 03 04) that only spell "Hello" once the CMap is
               applied (without it you'd get bytes 1..4 = garbage).

Run:  python3 tests/make_fixtures.py   ->   tests/fixtures/{hello,cmap}.pdf
"""

import os
import zlib

OUT = os.path.join(os.path.dirname(__file__), "fixtures")


def build_pdf(objs: list[bytes]) -> bytes:
    """Assemble objects (1-indexed bodies) into a PDF with a classic xref table."""
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]  # object 0 is the free head
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref_pos = len(out)
    n = len(objs) + 1
    out += f"xref\n0 {n}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets[1:]:
        out += f"{off:010d} 00000 n \n".encode()
    out += b"trailer\n"
    out += f"<< /Size {n} /Root 1 0 R >>\n".encode()
    out += f"startxref\n{xref_pos}\n%%EOF\n".encode()
    return bytes(out)


def stream_obj(dict_body: bytes, data: bytes, flate: bool) -> bytes:
    if flate:
        data = zlib.compress(data)
        dict_body = b"/Filter /FlateDecode " + dict_body
    return (
        b"<< /Length %d %s>>\nstream\n" % (len(data), dict_body) + data + b"\nendstream"
    )


def hello_pdf() -> bytes:
    content = (
        b"BT /F1 24 Tf 72 720 Td (Hello, headgate!) Tj "
        b"0 -30 Td (PDF parsing in pure Mojo.) Tj ET"
    )
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        stream_obj(b"", content, flate=True),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica "
        b"/Encoding /WinAnsiEncoding >>",
    ]
    return build_pdf(objs)


def cmap_pdf() -> bytes:
    # content shows codes 01 02 03 03 04 -> "Hello" via the ToUnicode CMap.
    content = b"BT /F1 24 Tf 72 720 Td <0102030304> Tj ET"
    tounicode = (
        b"/CIDInit /ProcSet findresource begin\n"
        b"12 dict begin\nbegincmap\n"
        b"/CMapType 2 def\n"
        b"1 begincodespacerange\n<00> <ff>\nendcodespacerange\n"
        b"4 beginbfchar\n"
        b"<01> <0048>\n<02> <0065>\n<03> <006c>\n<04> <006f>\n"
        b"endbfchar\n"
        b"endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend"
    )
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        stream_obj(b"", content, flate=True),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /CustomSubset "
        b"/ToUnicode 6 0 R >>",
        stream_obj(b"", tounicode, flate=False),
    ]
    return build_pdf(objs)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for name, data in (("hello.pdf", hello_pdf()), ("cmap.pdf", cmap_pdf())):
        path = os.path.join(OUT, name)
        with open(path, "wb") as f:
            f.write(data)
        print(f"wrote {path} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
