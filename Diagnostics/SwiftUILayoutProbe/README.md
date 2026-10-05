# Native SwiftUI layout control

A standalone Release control for Sundown's resizing investigation. It contains no Sundown models, transcript, transport, parsing, custom layouts, or server connection. It is outside the app target.

Build with `zsh Diagnostics/SwiftUILayoutProbe/build.sh`. Launch with:

```sh
SUNDOWN_PROBE_MODE=split /private/tmp/SundownLayoutProbe.app/Contents/MacOS/LayoutProbe -ApplePersistenceIgnoreState YES
```

Modes add one layer at a time: `plain` (a text label and spacer), `split` (a native NavigationSplitView with one sidebar row and a closed inspector), `toolbar` (also native toolbar menus), and `composer` (also a multiline text field with glass). All use the same 800-point minimum and initial 1000×740 size. The label matches the existing resize test's readiness query so that test can drive the control via `TEST_RUNNER_SUNDOWN_PERF_ATTACH=/private/tmp/SundownLayoutProbe.app` with xcodebuild.

On the investigation Mac, five iterations of the existing 200-point narrower/wider drag measured CPU seconds of 0.222, 0.797, 0.811 and 0.889 respectively. These are controls for this workload on this machine, not performance budgets.

Attached/ad-hoc test runs returned zero XCTHitchMetric results even where Instruments reported app-update hitches. Do not interpret those zeros as smooth rendering. Use a working signed Xcode performance-test run or verify frame timing independently in Instruments. Time Profiler/SwiftUI sampling also perturbs performance; keep those diagnostic recordings separate from uninstrumented comparisons.
