# Local files to the Kindle library

**Build 31 changes:** valid saved send credentials no longer depend on renewing
an unrelated reading bearer. Device-loading errors retain a sanitized stage and
HTTP status, including after choosing a file. If automatic registration is denied,
**Authorize Send to Kindle** uses a separate desktop OAuth/PKCE flow and verifies
that the result belongs to the connected Kindle account before saving its keys.
This addresses concrete client gaps; the original Windows account failure still
needs live acceptance. Reading credentials are preserved.

In a Kindle account, choose **Send to Kindle / Invia a Kindle** in the Windows
sidebar or the mobile app bar. Choose a local file, edit its title/author, select
at least one destination device and send. Amazon archives the personal document
in that account's cloud library as well as delivering it to those devices.
Refresh the library after Amazon has finished processing it.

Supported inputs: EPUB, PDF, DOC/DOCX, TXT, RTF, HTM/HTML, JPG/JPEG, PNG, GIF and
BMP, up to 200 MiB per file. PDF layout is preserved. CBZ/ZIP and purchased Kindle
containers are not supported inputs. Local reading remains available separately.
Uploading to a Komga server is future work.

The account shown on the import screen is the destination. Nothing is sent until
the Send button is pressed, except the account's device-list request and, on
first use, registration of a separate **KMReader Send to Kindle** client. Its
credentials are saved in the existing account credential vault. Reading-device
credentials, existing documents and other accounts are preserved. No desktop
Python converter is needed for this import path.

## Delivery and failure behavior

- File data is streamed with a fixed content length; the app does not buffer a
  200 MiB document in memory. Progress updates are bounded to approximately 10/s.
- Cancel aborts active HTTP work. Cancellation before final submission prevents
  delivery; after submission, a lost confirmation has an **uncertain** result.
- An accepted response means Amazon accepted processing, not that conversion or
  device delivery has completed. A library refresh may initially show nothing.
- A lost/malformed final reply or server error never replays the delivery write.
  The screen blocks a second send and asks the reader to check the Kindle library
  first. A server-side conversion rejection may arrive later through Amazon.
- Presigned upload URLs receive no account/signing headers. Only HTTPS Amazon,
  AWS and CloudFront destinations are allowed, with redirects disabled.
- If account registration, permission or the service is unavailable, the screen
  provides the official [Amazon Send to Kindle](https://www.amazon.it/sendtokindle)
  page. It does not report a failed upload as successful.

## Protocol and verification limits

Amazon publishes the supported customer workflow, not a stable REST contract.
This is a native Dart implementation of the Send to Kindle protocol: a separate
Firs registration, `kd.amazon.com/import/kindle-doc/get-device-list`,
`/import/upload-url`, an unsigned streaming PUT, then
`/import/kindle-doc/send-to-kindle` with `archive: true`. Import request signatures
use a raw SHA-256 digest in PKCS#1 v1.5 padding. Existing CDE read signatures retain
their DigestInfo format.

Protocol research used the MIT-licensed
[maxdjohnson/stkclient](https://github.com/maxdjohnson/stkclient/tree/b68b5e15363900762fd296c62d11a049b9de7d79)
implementation (API, signer and response models). No package or Python runtime
dependency was added. The synthetic signature vector was independently computed
using RSA modular exponentiation and the existing synthetic test key.

Host tests cover request bodies/signatures, separate credential persistence,
device selection, exact file bytes, unsigned transfer, cancellation, invalid
inputs/destinations, acceptance and uncertain results without duplicate writes.
Widget tests exercise file selection through the platform channel and prevent
resending after acceptance or an uncertain reply. These do not prove Amazon will
authorize a particular real account or complete a real conversion. Live account
acceptance and target-device delivery must be recorded separately; no production
document was uploaded during these automated checks.

## Catalog responsiveness and dictionaries

All dictionary classifications, including purchased dictionaries, are hidden.
Legacy cache entries without classification are recognized for known dictionary
titles, including the Oxford and Dutch dictionaries in the reported dashboard.
The first catalog request waits for cache migration, so stale indexed dictionary
rows cannot appear before a later sync. This removes catalog metadata only;
cloud documents, saved files and reading progress are retained.

Old snapshots did not retain every purchased-dictionary classification. Their
next online sync therefore requests complete metadata once, even when the cache
is recent; only classified snapshots resume incremental synchronization. Known
legacy titles are hidden immediately offline too. Unknown legacy titles can only
be classified when that full online metadata response arrives.

Catalog decoding, merge/sort, encoding and index fingerprinting run in worker
isolates. SQLite indexing yields between batches of 24 books, including obsolete
row removal, and cover preparations are limited to three concurrent requests.
Closing an account stops queued cover/index work before disposing persistence.
A 2,400-book regression checks that UI events run during initial indexing.
These address concrete UI-blocking paths; they do not establish the cause of
every freeze on an individual Windows installation. Check the final build on the
affected machine with its existing catalog and record any remaining stall.

The dashboard's **Recently Added Books** row includes EPUB/PDF documents; **Recently
Added Comics** includes Komga's DIVINA profile (comic archives). These filters
apply before pagination and are shared with See All. No release-date cutoff
excludes older novels or documents without publication metadata. Kindle book
addition dates use Amazon's purchase/creation date where supplied, otherwise the
first time the app sees the document, retained across refreshes. Publication dates
remain separate metadata. Legacy dashboard section IDs are kept so order, hidden
sections and card preferences survive the label change.

## Requested remote management

Build 31 adds PDOC management from the document detail screen: remote deletion
with backup/journal/catalog verification, and updated copies with edited EPUB
metadata/cover. Complete overwrite with bookmark/reading-state migration is still
missing and is never reported as successful. See
[KINDLE_LIBRARY_MANAGEMENT.md](KINDLE_LIBRARY_MANAGEMENT.md) for implemented behavior,
recovery states, historical API limitations and remaining real-account acceptance.
Purchased Kindle Store books remain outside this management scope.
