# local_auth_windows 2.0.2

Source: https://pub.dev/packages/local_auth_windows/versions/2.0.2
Original BSD license and source are retained. Changes: remove MSVC /await for
standard C++20 coroutines and replace the nonstandard return in the
RequestVerificationForWindowAsync coroutine with co_return. Text line endings
and trailing whitespace are normalized. Windows Hello behavior is unchanged.
