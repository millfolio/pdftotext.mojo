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
pixi run test                             # extraction gates (fixtures + zlib path)
```

```mojo
from pdf import read_file, extract_text
print(extract_text(read_file("doc.pdf")))
```

Depends on the sibling `../zlib.mojo` checkout (the `ffi` task builds its shim
into this env). Build a consumer with `-I src -I ../zlib.mojo/src`. The compiled
binary needs to find `libzlibmojo.so` at runtime — run it through `pixi run`
(sets `CONDA_PREFIX`) or with the shim relocated next to it (the headgate
distribution does this with `@loader_path`, like flare's shims). Running
`./build/pdftotext` bare with no `CONDA_PREFIX` won't find the shim.

## Status

**Works** (`pixi run test` + verified on real PDFs, e.g. macOS `cupsfilter`
output):

- **Reliable content-stream selection** — an object map (scan `N G obj`, robust
  to a broken/absent xref) → page leaves (`/Type /Page` + `/Contents`) → resolve
  `/Contents` refs → decode + concatenate per page.
- **FlateDecode** streams inflated via [zlib.mojo](https://github.com/millrace/zlib.mojo).
- **Text operators** — literal `(…)` + hex `<…>` strings, line breaks on Td/TD/Tm/T*/'/".
- **`/ToUnicode` CMaps** — per-font `bfchar`/`bfrange` maps applied (1- or 2-byte
  codes); base-14 WinAnsi fonts fall back to Latin-1.

**Not yet** (next):

1. **PDF 1.5+ compressed objects** — xref *streams* + `/ObjStm` (objects the
   `N G obj` scan can't see). A heuristic stream-scan fallback covers some of
   these meanwhile.
2. **Indirect `/Resources` / `/Font`** (v1 reads an inline `/Font << … >>`),
   `/Differences` encodings, CID/Type0 width handling.
3. **More filters** — LZW, ASCII85, ASCIIHex (v1 is FlateDecode + raw).
4. **Encrypted / scanned-image (OCR) PDFs** — out of scope.

macOS / Apple Silicon (`osx-arm64`), Mojo nightly `1.0.0b2.dev2026060706`.
