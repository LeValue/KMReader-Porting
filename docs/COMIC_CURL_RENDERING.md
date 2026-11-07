# Comic curl geometry and resolution (0.8.15)

The 0.8.14 mixed-format slide substitution has been removed. Comic animation
selection is no longer changed according to source/destination aspect ratio.
EPUB assets, browser preferences and rendering are unchanged.

The previous painter projected each raised vertex through a short perspective
camera, then interpolated all mesh positions into the incoming page bounds in
the final 28% of a spread turn. That could magnify the curved front and resize
artwork during landing. The new orthographic projection preserves flat distances;
front/back domains sample their respective absolute fitted rectangles, without
stretching one image into another. A central fixed spine keeps differently sized
spreads aligned. Single/double layout changes also retain curl; the stationary
old leaf is tracked independently of whether an incoming back exists.

The old painter immediately drew the entire incoming frame behind a mesh limited
to outgoing paper bounds. A taller incoming scan therefore replaced the outgoing
letterboxes at the first moving frame. The same fold boundary now controls their
reveal; margins are not bent into the paper mesh.

Prepared frames were capped at 2x/2048 pixels and fallback captures at 1x. Both
paths now use the display's pixel ratio. Prepared decoding matches Image.memory's
full viewport cache width (including its 4096-pixel source decode limit) and its
no-upscaling policy, avoiding fit changes from different rounded decode sizes.
Composed frames are drawn at native display density. Cache keys include density;
cache capacity is bounded by 64 MiB and four frames, retaining a current/next
pair when two large native frames exceed the budget. Speculative previous-page
work is skipped when only a pair fits. Existing view image cache behavior is
unchanged.

Checks include high-frequency portrait/landscape artwork at DPR 3 compared with
the live Flutter image, a zero-change crop of unturned ink during motion, initial
letterbox preservation with a larger incoming page, continuous final pixels,
reverse direction, differing back rectangles and preserved flat sheet distances.
Android native snapshots for the new pixel probe use PixelCopy and CPU PNG decode.
These are correctness/resolution checks, not claims about physical-device FPS.

## Opaque double-page curl (0.8.17)

The last 28% of a turn previously faded the stationary leaf into the destination;
the moving front also faded during the final 4%. Both timed opacity ramps are
removed. The original stationary image remains opaque outside the returning
leaf's projected free edge. That edge sweeps its replacement across the old leaf;
its reveal span follows the stationary fitted width so unequal formats finish
without residual old artwork. Actual image texture coordinates remain unchanged.
Letterboxing follows the ridge without opacity interpolation.

A fixed mesh cell can straddle the front/back normal even when the real fold is
smaller than one pixel, leaving a spurious triangle of old ink. Once the remaining
projection is below a quarter texture pixel, the exact destination retires that
subpixel geometry. This is an endpoint precision rule, not a crossfade or a change
of animation style.

Shared pixel probes inspect late-turn source/destination color separation in both
physical directions, alongside mixed-format and endpoint continuity checks. The
same cases execute on Android's delivered surface via PixelCopy and on Windows.
