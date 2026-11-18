# Installation and first use

KMReader Preview is a community reader for Android and Windows. Current public
release: [1.0.0 candidate 10, build 40](https://github.com/LeValue/KMReader-Porting/releases/tag/v1.0.0-candidate.10).
It is a development prerelease; stable 1.0 and full upstream parity are not complete.

## Install

### Android

1. Download `KMReader-1.0.0-android-universal-preview.apk` from the release page.
   It supports Android 7.0/API 24 and later on ARM64, ARMv7 and x86_64.
2. Open the APK. If prompted, allow installation from the browser or file manager
   you used. Complete the Android installer confirmation.
3. To update KMReader Preview, install over the existing app without uninstalling.
   Official project previews retain the same package and signing certificate.

### Windows

1. Download `KMReader-1.0.0-windows-x64-preview.zip` for Windows 10/11 x64.
2. Extract the complete ZIP into a writable application folder. Keep the `data`,
   DLL and `kindle` files together; copying only the executable will not work.
3. Run `KMReader/kmreader.exe`. The ebook reader needs Microsoft's
   [WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/).
   The bundle includes the MSVC runtime; the executable is not Authenticode signed.

Each release includes `SHA256SUMS.txt`. Compare the downloaded file's SHA256 with
its entry using `Get-FileHash` on Windows or `sha256sum` on Linux.

If the in-app updater in build 38 or earlier fails, use the current public
packages to upgrade once. On Android install the official APK over Preview.
On Windows close the old app, extract the full ZIP and start the executable
from the extracted folder. The default storage in the Windows profile is
shared across these installation folders.

## Connect Komga

Add a server account using its reachable Komga URL and your account credentials
or API key. Include any URL prefix used by your reverse proxy, such as `/komga`.
The app needs network access to that address; it does not expose your home server
or configure remote networking for you. For access outside your local network,
configure your server's HTTPS endpoint or VPN separately.

Browse a library, open a volume and choose the reader settings you prefer.
Downloaded volumes are available offline. When reconnected, progress is
synchronized; conflicting remote progress changes require explicit resolution.
Credentials use OS secure storage, and cached content/progress are separated by
server and account.

### Administrator tools

With a Komga administrator account:

- Open a volume or series and choose **Manage on Komga** to edit metadata or covers.
- **Delete from Komga** removes the volume's original server file for every user
  after confirmation. It is different from removing a local download.
- **Settings → Server → Add to Komga** uploads a new EPUB/PDF/CBZ/CBR after installing
  the optional [Debian server companion](KOMGA_LIBRARY_MANAGEMENT.md) (guide in Italian).
  The server companion is needed only for new-file uploads. Metadata, covers and
  deletion use native Komga APIs. Duplicate filenames are rejected.

The companion is tested on Linux with Komga 1.30.1. Configure the allowed library
paths and proxy on your own server; installing the client does not install it.

## Read local files

Open **Local Books → Import Files** and choose an EPUB, PDF or CBZ/ZIP.
The app copies the file into its storage and keeps reading progress locally.
No server account is required. Removing the imported copy preserves the original
file you selected. Local RAR/CBR reading is not currently supported.

## Use Kindle

Add a Kindle account under **Settings → Servers** and complete Amazon sign-in.
The unofficial adapter currently targets Amazon.it. Reading may require document
preparation; Windows distributions include its separate conversion worker.

Starting with build 38, KMReader offers a newer Kindle reading position when you
open a supported Kindle ebook or return to the foreground with the reader open.
It also checks for new positions periodically while that reader is active.
Choose **Go to position** to continue there or **Stay here** to keep reading.
In **Settings → Servers**, turn on **Automatically resume from Kindle** to skip
confirmation. **Sync reading position with Kindle** controls both sharing your
reading position and checking for incoming positions. Automatic resume is off
by default.

For a local document, open **Send to Kindle**, choose a file and review its
metadata. **Add to Kindle library** makes it available through the account's
cloud library. Turn that switch off to deliver only to selected devices.
Amazon acceptance can precede processing and appearance in the catalog.
Supported upload formats and troubleshooting are in [Send to Kindle](KINDLE_IMPORT.md).

[Personal-document management](KINDLE_LIBRARY_MANAGEMENT.md) supports confirmed
deletion and metadata/cover updates using a replacement when necessary. Reading
state is restored only when it can be verified against the new edition. Purchased
books cannot be edited this way. Read the documented limits before replacing a
document with notes/highlights or a format other than EPUB.

## Build 37 updater changes

Build 37 adds recovery of interrupted update downloads, explicit failure stages
and hashing outside the UI isolate. The public build 36 does not gain these
changes retroactively. If an older updater cannot complete its download, install
the current verified public APK manually over KMReader Preview,
without uninstalling. Subsequent transfers can use the corrected updater.
The app never bypasses Android signing/version checks to force an installation.

## Updates and troubleshooting

From build 35 onward, open **Settings → About → App updates**. Update files are
public; no GitHub account is needed. Downloads are checked against the release
manifest. Android asks for installer permission/confirmation; Windows closes,
backs up/replaces the installation and reopens. Keep the application folder
writable and retain the complete bundle.

If you use an older build, bootstrap with the current public download. Do not
uninstall the existing Preview app to update it. Development/debug builds signed
with a different key cannot replace a signed project preview.

For problems, check the [current release notes](releases/v1.0.0.md) and
[open issues](https://github.com/LeValue/KMReader-Porting/issues). Report the app
build from About, OS version, content format and steps to reproduce. For reader
issues, include animation mode, direction, input method and whether the problem
occurs at a chapter boundary. Remove credentials, account identifiers, private
addresses and personal content before sharing logs or screenshots.
