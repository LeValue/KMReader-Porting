# KMReader for Android and Windows

[![Build and test](https://github.com/LeValue/KMReader-Porting/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/LeValue/KMReader-Porting/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

KMReader is a community port of [kmworks/kmreader](https://github.com/kmworks/kmreader)
for reading comics, EPUBs and PDFs from Komga, Kindle or local files.

## Download

[Download KMReader for Android or Windows](https://github.com/LeValue/KMReader-Porting/releases)
· [Installation and updates](docs/GETTING_STARTED.md)

On Android, open the APK. On Windows, extract the full ZIP and run
`KMReader/kmreader.exe`. To retain your library and progress, install updates
over the existing app or use **Settings → About → App updates**.

## Features

- **Komga** — browse, search, download and synchronize reading progress across
  accounts. Administrators can manage metadata and covers, and upload files
  through the optional [server companion](docs/KOMGA_LIBRARY_MANAGEMENT.md).
- **Local books** — import EPUB, PDF, CBZ, CBR, CB7 and CBT without an account.
- **Readers** — page layouts, reading themes, page turns, EPUB search and
  annotations, and PDF search and table of contents.
- **Kindle** — connect an Amazon.it account, read supported books, synchronize
  positions and send personal documents. Kindle support is unofficial. See the
  [Kindle guide](docs/KINDLE_IMPORT.md) for supported operations and limits.

## Documentation

- [User and developer guides](docs/README.md)
- [What's new in 1.0](docs/releases/v1.0.0.md)
- [Remaining upstream parity work](docs/PARITY.md)
- [Contributing](CONTRIBUTING.md) · [Issues](https://github.com/LeValue/KMReader-Porting/issues)

Application source uses the [MIT license](LICENSE). Third-party components
retain their own licenses. See [notices](assets/upstream-licenses.json) and
[Kindle worker licenses](assets/kindle/NOTICE.md).
