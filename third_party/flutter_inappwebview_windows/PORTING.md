Stable flutter_inappwebview_windows 0.6.0 from pub.dev, Apache 2.0.

Modern MSVC/C++20 compatibility corrections:
- Remove redundant class qualifiers from member declarations in four headers.
- Define the dependent always_false_v template for the exhaustive visitor.
- Make string case-mutator parameters mutable and remove the undefined s2 return.

The application requests standard C++20 so Windows SDK WinRT uses standard
coroutines instead of the removed experimental coroutine implementation.
Mouse pressure/release forwarding now updates the virtual cursor from the actual
Flutter pointer event before forwarding its button state. This prevents stale
coordinates after moving/resizing the reader or using a control outside the
WebView. Existing per-pointer release/cancel ownership remains intact.
The capture pool uses three buffers and drains queued captures to the newest
frame. This lets WebView2 produce its next frame while Flutter samples the last
texture, without accumulating stale frames. Optional frame limiting compares
high-resolution durations without truncating to whole milliseconds. Capture
callbacks retain the existing UI-thread lifetime/locking model.
Other source changes are limited to line-ending/trailing-whitespace normalization.
