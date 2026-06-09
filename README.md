# pdftotext.mojo

> Part of [**millrace**](https://millrace.me) — local-first tooling in Mojo.

A **from-scratch PDF → text** extractor in Mojo. No C PDF engine, no Python — it
parses the PDF itself and decompresses `/FlateDecode` streams via
[zlib.mojo](https://github.com/millrace/zlib.mojo). Built for headgate's
[document mode](https://github.com/millrace/headgate/blob/main/DOCUMENT-MODE.md):
extract text from your files locally, so the bytes never leave the machine.

## Pipeline

```
PDF bytes ─▶ find `stream … endstream` objects
          ─▶ inflate the `/FlateDecode` ones (zlib.mojo)
          ─▶ from content streams (those with `BT`): pull the shown strings
             — literal `(…)` + hex `<…>` — with line breaks on Td/TD/Tm/T*/'/"
          ─▶ text
```

## Use

```sh
pixi run extract -- path/to/file.pdf      # prints extracted text
pixi run test                             # extraction gate (incl. FlateDecode via zlib.mojo)
```

```mojo
from pdf import read_file, extract_text
print(extract_text(read_file("doc.pdf")))
```

Depends on the sibling `../zlib.mojo` checkout (the `ffi` task builds its shim
into this env). Build a consumer with `-I src -I ../zlib.mojo/src`.

## Status — early; v1

**Works** (deterministic gate, `pixi run test`): content-stream text operators
(literal + hex strings, line breaks) and the **full FlateDecode path through
zlib.mojo** — a compressed content stream is inflated and its text extracted.

**Not yet** (the next phases — real-world robustness):

1. **Reliable content-stream selection.** v1 finds streams by scanning for
   `stream`/`endstream` and keeps those containing `BT`. Real PDFs need the
   xref + page-tree walk to pick the page `/Contents` exactly (and to handle
   PDF 1.5+ cross-reference / object streams). Until then, some real PDFs
   extract partially or not at all.
2. **Font encoding → Unicode.** Strings are decoded as single-byte Latin-1/ASCII.
   Fonts with a `/ToUnicode` CMap, custom `/Differences` encodings, or CID/Type0
   (2-byte) fonts need that map applied, or the output is glyph-code garbage.
3. **More filters** — LZW, ASCII85, ASCIIHex (v1 is FlateDecode + raw only).
4. **Encrypted PDFs, scanned/image PDFs (OCR)** — out of scope.

So: solid on born-digital, FlateDecode, simple-font PDFs; the xref/page-tree
parser and `/ToUnicode` support are what turn "some PDFs" into "most PDFs".

macOS / Apple Silicon (`osx-arm64`), Mojo nightly `1.0.0b2.dev2026060706`.
