# pdftotext.mojo

> Part of [**millfolio**](https://millfolio.app) — local-first tooling in Mojo.

A **from-scratch PDF → text** extractor in Mojo. No C PDF engine, no Python — it
parses the PDF itself and decompresses `/FlateDecode` streams via
[zlib.mojo](https://github.com/millfolio/zlib.mojo). Built for headgate's
[document mode](https://github.com/millfolio/headgate/blob/main/DOCUMENT-MODE.md):
extract text from your files locally, so the bytes never leave the machine.

## Pipeline

```
PDF bytes ─▶ find `stream … endstream` objects
          ─▶ inflate the `/FlateDecode` ones (zlib.mojo)
          ─▶ from content streams (those with `BT`): pull the shown strings
             — literal `(…)` + hex `<…>` — with line breaks on Td/TD/Tm/T*/'/"
          ─▶ text
```

## CLI

```sh
tools/pdftotext file.pdf                 # extract + print text
tools/pdftotext --info file.pdf          # object / page counts
tools/pdftotext a.pdf b.pdf              # multiple files (separated by headers)
tools/pdftotext --help
```

`tools/pdftotext` builds the binary + zlib shim on first use and resolves the
shim for you — no `pixi run` needed. Symlink it onto your PATH if you like:

```sh
ln -s "$PWD/tools/pdftotext" ~/.local/bin/pdftotext
```

Equivalents: `pixi run extract -- file.pdf`, and `pixi run test` (the gates).

```mojo
from pdf import read_file, extract_text
print(extract_text(read_file("doc.pdf")))
```

Depends on the sibling `../zlib.mojo` checkout (the `ffi` task builds its shim
into this env). Build a consumer with `-I src -I ../zlib.mojo/src`. The compiled
binary dlopens `libzlibmojo.so` via `$CONDA_PREFIX/lib` — `tools/pdftotext` (or
`pixi run`) sets that; a relocated copy next to the binary works too (the
headgate distribution does this with `@loader_path`, like flare's shims).

## Status

**Works** (`pixi run test` + verified on real PDFs, e.g. macOS `cupsfilter`
output):

- **Reliable content-stream selection** — an object map (scan `N G obj`, robust
  to a broken/absent xref) → page leaves (`/Type /Page` + `/Contents`) → resolve
  `/Contents` refs → decode + concatenate per page.
- **FlateDecode** streams inflated via [zlib.mojo](https://github.com/millfolio/zlib.mojo).
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

macOS / Apple Silicon (`osx-arm64`), Mojo nightly `1.0.0b3.dev2026062206`.
