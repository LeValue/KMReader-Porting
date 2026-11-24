# Development checks

From the repository root with the pinned toolchain:

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
flutter analyze --no-pub
flutter test --no-pub
python3 -m unittest discover -s tool/tests
```

The hosted [CI workflow](../.github/workflows/ci.yml) also runs the browser,
Komga, Android and Windows suites with synthetic data. Use the fixture
generators in `test/support/` and `tool/` for additions.
