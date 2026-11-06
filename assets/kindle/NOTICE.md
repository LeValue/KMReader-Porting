Kindle KFX conversion uses John Howell's kfxlib (2016–2026), GPL-3.0-or-later.
Pinned source: https://github.com/kafkasl/ksync/tree/fc00a7b7a04badfbd61f3e42aaaa5e45e1d0cfd7/vendor/kfxlib
The original kfxlib sources are unmodified; conversion markers are implemented
in KMReader's separate mapped_kfx.py. COPYING is available beside this notice.

The conversion worker is distributed under GPL-3.0-or-later, with its
corresponding source and build scripts. KMReader communicates with this worker
through local files and process IPC on Windows and Android. The original MIT
code and upstream notices retain their licenses. Complete KMReader source and build scripts are at:
https://github.com/LeValue/KMReader-Porting
Use the exact source revision in the build metadata. The pinned kfxlib source
above and the requirements in android/app/build.gradle.kts reproduce the worker.

Python starts only in a private Android worker process for file preparation.
The worker receives local content paths, never Amazon credentials. The app's
normal reader uses the prepared publication and does not load Python.
