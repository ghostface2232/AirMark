# Table raster policy, recovery launch I/O, live resize

Host: Mac17,3, arm64, macOS 27.0 (26A428), Xcode 27.0 (27A266a), Swift 6.4. Debug `swift test`
unless stated otherwise. Observations on this machine, not PLAN.md budget certifications. Baseline is
the end of `Validation/2026-09-18-recovery-sessions/`: 99 tests in 15 suites, 52 in 4 suites.

## 1. One raster policy, and a cache key that names it

### Problem

`drawTable` read two inputs the cache key did not carry:

- the host window's screen color space, and
- `NSParagraphStyle.defaultWritingDirection(forLanguage: nil)`.

The key hashes `RenderEnvironment`, which carries the scale but neither of these. Two windows at the
same scale on differently profiled screens therefore shared one entry, and whichever rendered first
decided the bytes for both. The comment claimed a bitmap "carries its color space, so a result shared
with a window on another screen is converted rather than shown wrong", which is true of drawing and
beside the point for a key: a key that does not name an input cannot tell the two results apart.

### Change

`TableRenderer.raster(for:)` is now the only place the policy lives, and `RenderService.key` hashes
exactly what it reads:

- **scale** — `environment.scale`, the requesting window's, already in the key.
- **color space** — a fixed sRGB. The screen stops being an input rather than becoming an input the
  key has to name.
- **alignment** — added to the key for table elements.

`drawTable` no longer takes `host`.

### Why fixed sRGB is safe, measured

A table draws neutral grays over an alpha channel and is composited onto the text view's background.
Grays have the same coordinates in sRGB and in Display P3 — same white point, same transfer curve,
the primaries never enter — so the same table drawn into either profile is identical:

```
TABLE_PROFILE sRGB and Display P3 bytes identical: true, 792000 bytes
```

`tableRasterIsSRGBWhicheverScreenAsks` asserts that equality, so it is a guard rather than a remark:
give a table a saturated color and the bytes diverge, the test fails, and the policy has to be
revisited instead of silently becoming wrong.

### Result

| test | before | after |
|---|---|---|
| `tableRasterIsSRGBWhicheverScreenAsks` (replaces `tableColorSpaceComesFromTheHostWindowsScreen`) | — | pass |
| `tableCacheKeyCoversTheRasterAndNothingElse` | — | pass |
| `tableRasterFollowsTheRequestingWindow` | pass | pass |
| `matchesTheAppKitReference` | pass | pass |

The new cache test covers both conditions asked for. 1× and 2× produce different keys, two renders and
pixel dimensions that follow the scale; two hosts at one scale — one in a window on a screen, one in no
window, which is where the old code read two different color spaces — produce one key, one render, and
the second call returns the identical `CGImage` from the cache.

Mutating the key to drop the scale, which is the same fault the color space had, fails it on 4
assertions, including a 1× window being handed the 2× bitmap. Full suite: 100 + 52 passing.
