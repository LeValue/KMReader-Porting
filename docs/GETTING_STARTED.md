# Install and start reading

Download KMReader from [GitHub Releases](https://github.com/LeValue/KMReader-Porting/releases).

- **Android 7 or later** — choose the APK for your architecture (`arm64`,
  `armv7` or `x64`), open it and confirm installation. Most current phones use
  `arm64`. KMReader selects the matching APK for in-app updates.
- **Windows 10 or 11 x64** — if the release includes a setup executable, run it
  and choose the install location, install scope, Start menu shortcut and optional desktop shortcut.
  For portable use, extract the full ZIP into a writable folder and run
  `KMReader/kmreader.exe`. EPUB reading uses the
  [WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/).
  Windows packages include the MSVC runtime and are distributed without an
  Authenticode signature.

Each release includes `SHA256SUMS.txt`. On Windows, use `Get-FileHash` to
check a download.

## Update

Open **Settings → About → App updates**. Android asks for confirmation in the
system installer. Windows backs up the application files, applies the update
and reopens the app.

To upgrade manually, install the official APK or Windows setup over the
existing app. For a portable Windows install, close KMReader and extract the
complete ZIP. Use the setup executable to update an all-users installation in
a protected directory. The Android release
keeps the package ID and signing certificate of KMReader Preview, so Android
can update it in place. The Windows app stores library data separately from
the installation folder.

## Read with Komga

Add your Komga URL under **Settings → Servers**. Include any reverse-proxy
prefix and sign in with your Komga credentials or API key. Use HTTPS when
connecting outside a trusted network. Browse a library and download a volume
to read offline. KMReader synchronizes progress when the server is available.

See [Komga library management](KOMGA_LIBRARY_MANAGEMENT.md) for administration
and batch uploads.

## Read without an account

Open **Local Books → Import Files** to import EPUB, PDF or comic archives.
KMReader keeps a copy and remembers reading progress. Removing an imported
copy preserves the original file.

PDFs open in the comics reader with page turns, search and a table of contents.
The native PDF view is available under reader settings for text selection.

## Read with Kindle

Add an Amazon.it account under **Settings → Servers**. The Kindle integration
offers supported reading positions in the EPUB reader and can send personal
documents. See [Kindle](KINDLE_IMPORT.md) for setup, sync and limitations.

## Get help

Use the version from **Settings → About** when reporting a problem. Include
the OS, file format and steps to reproduce. Remove credentials, private URLs
and personal content before sharing a log or screenshot.
[Report a problem](https://github.com/LeValue/KMReader-Porting/issues)
