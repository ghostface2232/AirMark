# Render queue refill, Space and Return input paths

Host: Mac17,3, 24 GiB RAM, arm64, macOS 27.0 (26A428), Swift 6.4. OS cache state uncontrolled. These are observations on this machine, not PLAN.md budget certifications. Each "before" run is the commit's test or benchmark against the unchanged implementation.

## 1. Render queue refill

At most 12 renders run at once. When one finished it freed its slot but nothing asked for the next element, so elements past the first 12 waited for an unrelated scroll, resize or parse.

- `render-refill-before.txt`: `swift test --disable-sandbox --filter elementsBeyondTheInFlightLimitRenderWithoutScrolling` (Debug) at `85943dc` with only the new test. 30 images in one paragraph on screen: 24 of 30 rendered on first display (an incidental layout pass started a second batch); after releasing every pixel and making one request, 12 of 30.
- `render-refill-after.txt`: the same test after the change: 30 of 30 both times, 30 requests per pass (no duplicates), at most 12 in flight.
- `render-refill-release-before.txt` / `render-refill-release-after.txt`: `AIRMARK_MEMORY=1 swift test -c release --disable-sandbox --filter 'MemoryTests|elementsBeyondTheInFlightLimitRenderWithoutScrolling'`. In Release the stall is worse (12 of 30 on first display). The 150-image scroll is unchanged within its earlier run-to-run range: peak growth 71.2 → 65.5MB, requests down/up 178/138 → 176/138, 14 images holding pixels in both.

A finished render (stored or recorded as a failure) releases its slot, checked against its token, and calls `scheduleRenders()` from the task. That call cannot recurse: `scheduleRenders` only creates tasks, whose bodies run later. A cancelled, stale or postponed render returns before that point; whoever cancelled it schedules again, and a postponed render in a hidden window would otherwise request itself in a loop. The element just finished is skipped because it now has pixels or an error.
