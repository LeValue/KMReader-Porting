`page.tiff` and `page.jp2` are generated 64 × 96 RGB test images (solid green
and solid blue). They contain no third-party artwork. TIFF uses raw RGB strips;
JPEG2000 is lossless. They can be regenerated with Pillow's TIFF/JPEG2000 writers.
The live Komga fixture mixes PNG, TIFF and JPEG2000 in one CBZ to exercise actual
server-side format conversion and offline client storage.

`reader-modes.pdf` contains five generated colored pages with searchable text
and outline entries. `reader-encrypted.pdf` contains the same pages encrypted
with AES-128; its public test password is `fixture-only`. Both were created
using ReportLab/pypdf; no third-party documents or artwork are included.
