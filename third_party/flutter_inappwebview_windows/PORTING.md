Stable flutter_inappwebview_windows 0.6.0 from pub.dev, Apache 2.0.

Modern MSVC/C++20 compatibility corrections:
- Remove redundant class qualifiers from member declarations in four headers.
- Define the dependent always_false_v template for the exhaustive visitor.
- Make string case-mutator parameters mutable and remove the undefined s2 return.

The application requests standard C++20 so Windows SDK WinRT uses standard
coroutines instead of the removed experimental coroutine implementation.
All other Dart and native implementation files are retained unchanged.
