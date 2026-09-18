# Multi-document recovery, live resize, table raster — superseded

This directory held a set of claims about what the code at `cb8c3df` did and what the new tests would
do, written without a Swift toolchain. Nothing in it was ever run, and the code it described has since
changed: the resize settle is 50 ms with an end-of-drag event rather than a 150 ms poll, the table
raster is a fixed sRGB rather than the host screen's colour space, and the launch restores the last
session rather than every record ever written as open.

The claims file has been removed rather than left to be read as results.

What actually happened to these three changes, measured on macOS:
`Validation/2026-09-18-recovery-sessions/`, `Validation/2026-09-18-raster-recovery-resize/` and
`Validation/2026-09-18-recovery-resize-table-bench/`.
