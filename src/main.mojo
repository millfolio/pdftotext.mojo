"""pdftotext — CLI: extract text from PDF files.

    pdftotext <file.pdf> [more.pdf ...]   extract text and print it
    pdftotext --info <file.pdf>           print object/page counts (no text)
    pdftotext --help

Run it via `tools/pdftotext` (resolves the zlib shim) or `pixi run extract -- …`.
Control characters in extracted text are escaped (\\xNN) so output never garbles
the terminal; if the zlib decoder can't load, it exits with an error rather than
emitting raw compressed bytes.
"""

from std.sys import argv
from pdf import read_file, extract_text, _build_objmap, page_objs
from zlib import inflate


def _usage():
    print("usage: pdftotext [--info] <file.pdf> [more.pdf ...]")
    print("  -i, --info   print object/page counts instead of the text")
    print("  -h, --help   show this help")


def _zlib_ok() -> Bool:
    """Self-check: inflate a tiny known buffer (zlib of 'ok' -> 2 bytes). Fails if
    libzlibmojo.so can't be loaded — in which case PDF /FlateDecode can't decode.
    """
    var probe = List[Int]()
    probe.append(0x78)
    probe.append(0x9C)
    probe.append(0xCB)
    probe.append(0xCF)
    probe.append(0x06)
    probe.append(0x00)
    probe.append(0x01)
    probe.append(0x4B)
    probe.append(0x00)
    probe.append(0xDB)
    var b = List[UInt8]()
    for i in range(len(probe)):
        b.append(UInt8(probe[i]))
    try:
        return len(inflate(b)) == 2
    except:
        return False


def _hexdigit(n: Int) -> String:
    return chr(48 + n) if n < 10 else chr(87 + n)  # 0-9, a-f


def _escape_controls(s: String) -> String:
    """Escape control characters as \\xNN (keep tab/newline; pass UTF-8 through)
    so extracted text can never garble the terminal."""
    var out = String("")
    for cp in s.codepoints():
        var v = Int(cp)
        if v == 9 or v == 10:
            out += chr(v)
        elif v < 32 or v == 127:
            out += "\\x" + _hexdigit((v >> 4) & 0xF) + _hexdigit(v & 0xF)
        else:
            out += chr(v)
    return out^


def main() raises:
    var a = argv()
    var info = False
    var files = List[String]()
    for i in range(1, len(a)):
        var arg = String(a[i])
        if arg == "-h" or arg == "--help":
            _usage()
            return
        elif arg == "-i" or arg == "--info":
            info = True
        else:
            files.append(arg)

    if len(files) == 0:
        _usage()
        return

    # Text extraction needs the zlib shim for /FlateDecode. Fail loudly rather
    # than silently dropping (or worse, dumping) compressed bytes.
    if not info and not _zlib_ok():
        print("error: cannot load the zlib decoder (libzlibmojo.so) —")
        print("  PDF /FlateDecode streams can't be decompressed.")
        print(
            "  Run via 'tools/pdftotext <file>' (it sets CONDA_PREFIX), or set"
        )
        print("  CONDA_PREFIX to the pixi env so the shim resolves.")
        return

    for fi in range(len(files)):
        var path = files[fi]
        if len(files) > 1:
            print("===== ", path, " =====", sep="")
        var data = read_file(path)
        if info:
            var omap = _build_objmap(data)
            var pages = page_objs(data, omap)
            print("file:    ", path, sep="")
            print("  bytes:   ", len(data))
            print("  objects: ", len(omap.nums))
            print("  pages:   ", len(pages))
        else:
            print(_escape_controls(extract_text(data)))
