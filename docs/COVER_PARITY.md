# Cover actions and parity evidence

Development follow-up after source `89859ea`. These actions are not all present
in the public candidate 6/build 36 package. Stable 1.0 acceptance remains open.

## Reference and scope

The upstream reference remains `kmworks/kmreader` at
`e2b35f8796cc830fc6e7464e161b2172d8f916e9`. Its cover-refresh action forces the
thumbnail cache to fetch the image and notifies consumers. It does not edit the
book file. Sources, relative to upstream `KMReader/`:

| Upstream operation | Reference source | Port equivalent |
|---|---|---|
| Refresh book cover | `Features/Book/Views/BookContextMenu.swift`, `refreshCover()` | Detail → Refresh cover |
| Refresh series cover | `Features/Series/Views/SeriesContextMenu.swift`, `refreshCover()` | Detail → Refresh cover |
| Refresh collection cover | `Features/Collection/Views/CollectionContextMenu.swift`, `refreshCover()` | Detail → Refresh cover |
| Refresh read-list cover | `Features/ReadList/Views/ReadListContextMenu.swift`, `refreshCover()` | Detail → Refresh cover |
| Refresh smart-list cover | `Features/SmartList/Views/SmartListContextMenu.swift`, `refreshCover()` | Server smart-list menu → Refresh cover |
| Fetch and publish cache update | `Core/Storage/Cache/ThumbnailCache.swift`, `refreshThumbnail()` | `Repository.refreshCover()` fetches fresh bytes and publishes `imageChanges` |

Administrative cover version management is also a requested port extension.
It uses stock Komga's book/series thumbnail APIs, verified against the
[1.30.1 controllers](https://github.com/gotson/komga/tree/1.30.1/komga/src/main/kotlin/org/gotson/komga/interfaces/api/rest).
It is not evidence that the Swift reference exposes an identical editor.

## Implemented behavior

- Any account with content-read permission can explicitly refresh a cover online;
  administrator permission is not required for that read. Refresh uses GET only.
- **Manage on Komga → Available covers** lists book/series images with a preview
  and the current selection. Choosing an existing image can restore document or
  library artwork without deleting an uploaded alternative.
- Only `USER_UPLOADED` images have a removal control. Confirmation explains that
  other covers and the book file remain. Native/generated and sidecar images
  cannot be deleted by this flow.
- The service reads current candidates and checks their owning book/series before
  selection/removal. An already-selected candidate or an already-absent uploaded
  image is reconciled without replaying a write.
- Changing/removing artwork invalidates the selected cover and, for a volume, its
  parent series cover. It notifies cache consumers even if SSE is unavailable.
- Removing a series' uploaded override can reveal the cover inherited from its
  books. The app follows Komga's fallback; it does not delete unrelated overrides
  to force a particular result. Any remaining cover can be selected explicitly.
- Controls react to offline state, and in-flight refreshes block repeated taps.
  Failed reads remain errors; missing/unauthorized content is not presented as a
  successful refresh. Original book bytes are preserved.

## Verification and remaining acceptance

- Service tests cover both resource kinds, same-origin/prefixed routes, read-back,
  duplicate-write prevention, stale candidates, foreign ownership, offline denial
  and refusal to delete generated images.
- Widget tests exercise book/series galleries under Android and Windows layout
  targets: selection, cancellation and confirmed removal. Separate tests cover
  read-only smart-list refresh and duplicate-tap/offline handling.
- A real disposable Komga **1.30.1** lifecycle verifies upload, selection,
  restoration, uploaded-image deletion, inherited series artwork and collection/
  read-list refresh. Decoded image pixels and unchanged original file bytes are
  checked. No personal account or library is used.
- The smart-list endpoint is an optional server extension, not stock Komga.
  Its client route/menu has host coverage; equivalent real extension-server
  acceptance remains open under AT-04.
- Native installed-device UI acceptance and visual comparison remain under
  AT-04/AT-08 and A-01. Host layout variants are not physical device tests.

This closes the documented implementation gaps for F-03's cover actions, not the
entire port or its release acceptance. See [PARITY.md](PARITY.md).
