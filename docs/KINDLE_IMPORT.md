# Local files to the Kindle library

**Build 32:** imports use Amazon's first-party web Send to Kindle endpoints,
authenticated automatically from the connected reader account's refresh token.
There is no separate send login or Firs registration in this screen. Reading
credentials remain in the existing vault; short-lived web cookies and CSRF tokens
stay in memory. A revoked reader session may still require reconnecting Kindle.

In a Kindle account, choose **Send to Kindle / Invia a Kindle** in the Windows
sidebar or the mobile app bar. Choose a local file, edit its title/author and send.
The destination is that account's cloud Kindle library, including accounts with
no compatible device returned by the device-list query. Amazon's archive flow
does not promise separate immediate delivery to individually selected devices.
Refresh the library after Amazon has finished processing it.

Supported inputs: EPUB, PDF, DOC/DOCX, TXT, RTF, HTM/HTML, JPG/JPEG, PNG, GIF and
BMP, up to 200 MiB per file. PDF layout is preserved. CBZ/ZIP and purchased Kindle
containers are not supported inputs. Local reading remains available separately.
Uploading to a Komga server is future work.

The account shown on the import screen is the destination. Before Send is pressed,
the app only exchanges that account's refresh token for website cookies, checks
authentication, obtains CSRF and queries devices. It does not read the browser's
profile or require copied cookies. No document is uploaded at this stage, and no
desktop Python converter is needed for this import path.

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
The default native Dart implementation exchanges cookies for Amazon.it, verifies
`/sendtokindle/extension/checkAuth`, obtains CSRF from `/sendtokindle/empty`, queries
`/sendtokindle/get-device-list`, requests `/sendtokindle/init`, streams an unsigned
PUT and submits `/sendtokindle/send-v2` once with `archive: true`. It sends no
reader ADP headers to web or upload endpoints. CSRF presence alone is not accepted
as proof of authentication. Redirects are disabled and an uncertain final response
never replays delivery.

The web request fields were checked against Amazon's official Chrome extension
`cgdjpilhipecahhcilnafpblkieebhea` **2.1.1.7**, downloaded from Google's extension
update service (CRX SHA256 `be579908c9f6102d3d3d56484d958ba9119299199ed8d87b349e959ffb88f43a`).
No extension code or binary is bundled with KMReader.

The earlier desktop protocol remains available as `KindleImporter.legacy` for
diagnostics and its independent signature tests. It is not an automatic fallback
after a web mutation. Existing CDE read signatures are unchanged.

Earlier desktop protocol research used the MIT-licensed
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
document was uploaded during the synthetic checks.

## Real-account evidence, 2026-11-08

The personal desktop `kmreader-android-desktop` completed read-only service checks
([42479547564](https://github.com/LeValue/KMReader-Porting/actions/runs/42479547564))
and the actual app's cover/download/preparation check
([42480022977](https://github.com/LeValue/KMReader-Porting/actions/runs/42480022977)).
The reported import error was reproduced: Firs returned HTTP 200 with an XML
`error/message` instead of credentials. Matching the reference XML declaration
still produced an internal-error response; this does not establish its server cause.

The first-party web session check
([42480508219](https://github.com/LeValue/KMReader-Porting/actions/runs/42480508219))
returned HTTP 200 for cookie exchange, `isAuthed: true` and CSRF retrieval, using
the existing local reader session without a browser login. Upload acceptance is
checked separately by the opt-in generated-EPUB probe. Its private DPAPI journal
prevents replaying an earlier pending/submitted test document. Reports contain
only fixed schema fields/counters, never credentials, document IDs or titles.

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
