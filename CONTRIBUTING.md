# Contributing

Bug reports, documentation improvements and focused code contributions are welcome.
This is a community Android/Windows port of [KMReader](https://github.com/kmworks/kmreader).
The [porting checklist](docs/PARITY.md) and [roadmap](docs/ROADMAP_1.0.md) describe
open work; stable 1.0 is not yet complete.

## Issues

Search [existing issues](https://github.com/LeValue/KMReader-Porting/issues) first.
For bugs, include:

- App version/build, platform and OS version.
- Source: Komga (with server version), Kindle or local import; relevant file format.
- Steps, expected behavior and observed behavior.
- Relevant logs/screenshots, and a small redistributable fixture if possible.

For animation bugs, include the animation mode, direction, touch/mouse/tap input,
and whether the turn crosses a chapter boundary. For feature requests, describe
the user task and current limitation.

Public issues and attachments are visible to everyone. Do not include passwords,
API keys, OAuth links, cookies, credential vaults, private server addresses or
personal account/book data. Do not attach books you lack permission to share.
Synthetic fixtures are preferred for reproductions.

## Local development

Follow [development setup](docs/DEVELOPMENT.md) and keep the pinned SDK and
lockfile. Local debug builds do not require the project's private signing key.
Windows packages need the separately built Kindle worker; ordinary Flutter
compilation alone does not produce the complete distribution.

Before submitting a change, run the relevant checks:

```sh
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
python3 tool/preview_metadata.py
python3 -m unittest discover -s tool/tests
flutter analyze
flutter test
```

Additional browser, native, backend and worker checks are documented in
[testing](docs/TESTING.md). Report actual pass/skip results and platform limits.
Documentation-only changes need link and accuracy checks rather than app builds.

## Pull requests

Keep changes focused and explain the problem, resulting behavior and validation.
Link an issue when relevant. Use existing feature/service boundaries, preserve
account isolation and include meaningful regression coverage for behavior fixes.
Discuss broad dependency upgrades or architecture changes before combining them
with unrelated work. Routine contributions should not bump the release version.

`tool/kindle_personal` is an active shared app dependency despite its historical
name; consult [its dependency map](docs/KINDLE_RUNTIME.md) before moving/removing
scripts. Keep build output, signing material, sessions and personal fixtures out
of Git. Preserve license notices for copied or modified third-party code.

## Maintainer-only operations

Public preview signing, release publication and personal-account/self-hosted
runner diagnostics require maintainer access. They are not prerequisites for
contributing. The normal hosted CI uses synthetic fixtures. Do not dispatch a
workflow against someone else's device, account or self-hosted runner as part
of a contribution. See [release procedures](docs/RELEASING.md) for packaging gates.
