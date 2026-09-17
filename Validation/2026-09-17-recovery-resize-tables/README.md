# Multi-document recovery, live resize, table raster

## Execution environment: nothing here was run

These three changes were written in a Linux container with **no Swift toolchain and no macOS SDK**
(`swift`, `swiftc` and `xcodebuild` are all absent; `download.swift.org` is blocked by the network
policy). Every target in this package needs AppKit, CoreText or WebKit, and `AirMarkCore` additionally
needs SwiftPM to fetch `swift-markdown`. So for this change:

- **No test was compiled or executed**, before or after.
- **No benchmark or Release measurement was taken**, so there is no before/after number.
- The "baseline" recorded below is what the code did, read from the source, not an observed run.

Each task's tests are written to fail on the previous code and pass on the new code, and the file
`baseline-expected.md` in this directory states, per test, which assertion fails before the change and
why. That is a claim about the code, not a result. **Do not treat any of it as validation.** Before
this branch is merged, run on macOS:

```sh
swift test --disable-sandbox
swift test -c release --disable-sandbox
swift test -c release --disable-sandbox --filter LaunchPlan
swift test -c release --disable-sandbox --filter ResizeTests
swift test -c release --disable-sandbox --filter TableRenderTests
AIRMARK_TEST_RESULTS=/tmp/airmark-recovery-resize.xcresult bash Scripts/test-ui.sh -configuration Release
```

and record the actual output here, replacing this section.
