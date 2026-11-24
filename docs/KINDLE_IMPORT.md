# Use Kindle with KMReader

Connect an Amazon.it account in **Settings → Servers**. KMReader uses an
unofficial integration. Amazon-side changes can affect sign-in, catalog,
document preparation and synchronization.

## Send a document

Open **Send to Kindle**, select a file, and review its title and author.

- **Add to Kindle library** saves the document in the selected account's cloud library.
- **Send only to selected devices** delivers to the chosen Kindle targets. Turn
  off **Add to Kindle library** for this mode.

Supported inputs are EPUB, PDF, DOC/DOCX, TXT, RTF, HTM/HTML, JPG/JPEG, PNG, GIF
and BMP up to 200 MiB. The Send client uses credentials stored in the account vault.

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

## Reading position and annotations

When a matching Kindle edition reports a different reading position, KMReader
offers to open it. **Stay here** keeps the current EPUB location and queues its
mapped Kindle position against the exact cloud update shown. The same proposal
stays dismissed on reopen. A later cloud change can still be offered. The date
appears only when Amazon provides a distinct modification timestamp. **Resume
automatically from Kindle** skips the confirmation and is off by default.
Use **Go to latest Kindle position** in the EPUB reader menu to fetch and apply
the cloud position explicitly.

**Bookmarks and annotations** lists local entries and Kindle entries for the
same edition. New bookmarks, notes and highlights in a mapped personal Kindle
EPUB are queued offline and verified by reading them back from Amazon. An
ambiguous response triggers readback without resubmission. The queue is scoped
to the personal document and its edition.

In an editable personal EPUB with a verified Kindle mapping, deleting a note
also removes its linked highlight. Deleting a highlight removes the notes linked
to it. The app keeps each removal pending until Amazon confirms that the mark is
absent. Cloud editing of an existing note is limited.

Select text in an EPUB to highlight it, write a note or search the book. The
selection menu can look up a single word in Wiktionary and sends the word only
on request. Notes and highlights use the exact selected range. Tap a marked
passage to read its note. Existing Kindle notes and highlights are imported
when their original positions can be mapped.

## Manage documents

See [personal document management](KINDLE_LIBRARY_MANAGEMENT.md) for editing
metadata and covers, deleting documents and the limits of restoring reading state.
