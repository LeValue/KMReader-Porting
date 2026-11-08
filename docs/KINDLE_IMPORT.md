# Local files to Kindle

**Build 32:** Firs registration preserves the reference XML declaration and exact
`Content-Type: text/xml`. `Request.bodyBytes` prevents the charset parameter
introduced by `Request.body`; the former request returned HTTP 200 XML errors
on the real account. The corrected registration and persisted-session reuse passed
on `kmreader-android-desktop` without a new login. Reading-device credentials and
the separate optional OAuth fallback remain unchanged.

The upload URL's `expiryTime` is a **relative millisecond lifetime** (3600000 in
the live response), not an epoch date. A fresh positive lifetime is accepted;
the URL is never cached or replayed. Network/device failures no longer display a
new authorization action; that fallback is limited to registration HTTP 401/403.

**Build 31 changes:** valid saved send credentials no longer depend on renewing
an unrelated reading bearer. Device-loading errors retain a sanitized stage and
HTTP status, including after choosing a file. If automatic registration is denied,
**Authorize Send to Kindle** uses a separate desktop OAuth/PKCE flow and verifies
that the result belongs to the connected Kindle account before saving its keys.
These build 31 changes addressed client gaps; the real registration/upload
corrections and acceptance are recorded for build 32 above and below. Reading
credentials are preserved.

In a Kindle account, choose **Send to Kindle / Invia a Kindle** in the Windows
sidebar or the mobile app bar, choose a local file and edit its title/author.
Build 33 provides two distinct modes:

- **Add to Kindle library** (default): `archive: true`, empty `targetDevices`.
  No device list/selection is required. The file becomes available through this
  account's cloud library on compatible devices after Amazon processes it.
- Disable that switch for **Send only to selected devices**: `archive: false`,
  at least one device required. This delivers to those targets without cloud
  archiving; Amazon does not sync/share a device-only document.

An accepted response means Amazon accepted the submission. Refresh the library
for cloud uploads; synchronize the selected Kindle/app for device-only delivery.
Device-list failures do not block cloud-library uploads.

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
`/import/kindle-doc/send-to-kindle` with the explicitly selected `archive`/`targetDevices` mode. Import request signatures
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

Build 33 uses the current MyCD deletion endpoint, backs up source and state,
edits EPUB metadata/cover on a copy, and restores reading progress/bookmarks
before retirement of the previous edition. Unsupported or ambiguous migrations
preserve the original. See [KINDLE_LIBRARY_MANAGEMENT.md](KINDLE_LIBRARY_MANAGEMENT.md)
for coverage, recovery and actual account evidence. Purchased books are excluded.

## Real-account evidence, 2026-11-08

Build 33 mode checks:

- [Device-only delivery 42491041919](https://github.com/LeValue/KMReader-Porting/actions/runs/42491041919): exactly one generated EPUB, `archive: false`, the user's selected Android target, accepted by Amazon; absent from the reading account's cloud catalog on ten checks. The user confirmed receipt and successful opening in the selected Kindle Android app.
- [Cloud-only upload 42491240326](https://github.com/LeValue/KMReader-Porting/actions/runs/42491240326): one generated EPUB, `archive: true`, no targets, accepted and present in the cloud catalog.
- [Persistent bookmark readback 42505593479](https://github.com/LeValue/KMReader-Porting/actions/runs/42505593479): bookmark confirmed against the exact delivered edition, zero additional writes. Its [creation check 42505366992](https://github.com/LeValue/KMReader-Porting/actions/runs/42505366992) submitted once successfully but failed its numeric assertion because Amazon returns the position as a string. Corrected readback did not recreate it.
- Complete replacement/deletion check: [42506920429](https://github.com/LeValue/KMReader-Porting/actions/runs/42506920429), outcome to be recorded after completion.

Earlier build 32 evidence:


- Service reads: [42479547564](https://github.com/LeValue/KMReader-Porting/actions/runs/42479547564), passed.
- App cover/download/preparation: [42480022977](https://github.com/LeValue/KMReader-Porting/actions/runs/42480022977), passed.
- Corrected Firs registration, destination query and credential reuse after loading the saved session: [42482337075](https://github.com/LeValue/KMReader-Porting/actions/runs/42482337075), passed without an OAuth/browser login.
- Generated EPUB, streaming transfer, accepted delivery and subsequent PDOC catalog readback: [42483122733](https://github.com/LeValue/KMReader-Porting/actions/runs/42483122733), passed. Exactly one synthetic document was submitted; no existing document was modified/deleted and no annotations were written.
- Fresh workflow/process reopening: [42483886657](https://github.com/LeValue/KMReader-Porting/actions/runs/42483886657), passed with 9 destinations, the same fixture present and **zero** document submissions. No OAuth/browser or Firs registration was needed.
- [Native preparation and prepared-cache reuse](https://github.com/LeValue/KMReader-Porting/actions/runs/42485477861), passed for that exact generated PDOC. It has no cover/annotations; the check does not imply cover editing or bookmark migration acceptance.

The first-party web alternative authenticated GET requests, but POST device/init
requests redirected to Amazon sign-in. It is archived under
[experiments](../archive/experiments/kindle-web-import/README.md) and is not used
by the application. No response body, token, title or document identifier enters
the diagnostic reports. The opt-in upload probe retains its synthetic-document
journal only in the personal PC's DPAPI vault and never replays a pending send.
