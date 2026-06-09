"""pdftotext — CLI: extract text from PDF files.

    pdftotext <file.pdf> [more.pdf ...]   extract text and print it
    pdftotext --info <file.pdf>           print object/page counts (no text)
    pdftotext --help

Run it via `tools/pdftotext` (resolves the zlib shim) or `pixi run extract -- …`.
"""

from std.sys import argv
from pdf import read_file, extract_text, _build_objmap, page_objs


def _usage():
    print("usage: pdftotext [--info] <file.pdf> [more.pdf ...]")
    print("  -i, --info   print object/page counts instead of the text")
    print("  -h, --help   show this help")


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
            print(extract_text(data))
