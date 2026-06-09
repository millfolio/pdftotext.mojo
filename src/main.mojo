"""pdftotext — CLI: extract text from a PDF file.

    pdftotext <file.pdf>     # prints the extracted text to stdout
"""

from std.sys import argv
from pdf import read_file, extract_text


def main() raises:
    var a = argv()
    if len(a) < 2:
        print("usage: pdftotext <file.pdf>")
        return
    var data = read_file(String(a[1]))
    print(extract_text(data))
