# Resizing and scrolling investigation — 29 September 2026

The evidence points to CPU-side update/layout work, with a significant app-controlled contribution from eagerly laying out the entire active turn. It does not establish an Apple framework defect. Native split-view layout also has substantial cost, so the relevant control is a comparable native shell, not an empty window.

## Measurements

Five repeated Release resize measurements on a 12-core M4 Pro, 24 GiB, macOS 27.0.1 / Xcode 27:

| Screen | CPU seconds per measurement |
| --- | ---: |
| Standalone label/spacer window | 0.222 |
| Standalone native split view | 0.797 |
| Split view with native toolbar menus | 0.811 |
| Also a simple glass composer | 0.889 |
| Tether New Chat, earlier clean run | 0.962 |
| Tether settled transcript, diagnostic logging run | 1.192 |
| Tether long live turn, full eager turn | 5.909 |
| Long live turn, temporary eight-row eager cap | 3.668 |
| Long live turn, signed Xcode confirmation | 5.874 |
| Eight-row live cap, signed Xcode confirmation | 3.623 |
| Full live turn, streaming effects disabled | 3.639 |
| Full live turn, text selection disabled | 4.555 |
| Final native anchoring, no transcript glide | 4.614 |

The controls use the same existing corner-drag workload. The signed Xcode confirmation also measured 557.4 ms/s hitch time ratio and 5.009 seconds elapsed per measurement, validating that the zero readings in the ad-hoc/attached runs were misleading. The live test waits until eight Markdown answers have accumulated and checks the turn remains active after all measured drags. Live CPU includes streaming and automation waits, not resize alone; replies continue accumulating during the measurement. The signed cap comparison measured 547.0 ms/s hitch rate and 3.112 seconds elapsed, versus 557.4 ms/s and 5.009 seconds with the full eager turn. CPU and elapsed time both fell about 38%; CPU per elapsed second was essentially unchanged, and hitch rate did not clearly improve. The cap comparison is a diagnostic result, not a shipped optimization or a fix for the jank. It changes view identity when rows cross containers and therefore needs a design that preserves reader state before production use. The original active-turn behavior was restored. Disabling text fade, glide and the transcript status symbol animation also failed to improve hitch rate: 605.3 ms/s, CPU 3.639 seconds and elapsed 3.189 seconds. Both CPU and elapsed are needed to interpret these changes; a smaller aggregate CPU time does not imply smoother motion. The all-effects-off experiment was reverted. A separate text-selection-disabled experiment measured 476.6 ms/s hitch rate, CPU 4.555 seconds and elapsed 3.734 seconds. This suggests selectable text contributes to layout cost, but does not isolate a framework bug or eliminate severe hitching. Text selection remains enabled.

Earlier controlled signed Xcode measurements found a 17% CPU / 15% hitch-rate improvement from bounding the *finished* turn's eager tail, now committed. Ordinary scrolling did not show a clear improvement.

## Update causes and frame pipeline

A fresh SwiftUI-template recording of actual resize gestures captured 103 hitch events. Instruments labeled 92 as potentially expensive app updates; 11 were unclassified. App-update intervals had p95 81.4 ms; matched render-server CPU intervals p95 2.6 ms and GPU intervals p95 3.6 ms. Intervals include setup/automation and can be nested, so they are not independent frame counts and must not be summed. The GPU was not the first bottleneck in this workload.

Instruments confirmed “Trace file had no SwiftUI data.” Both exported update/cause tables and the UI summary were empty. Launch-under-Instruments attempts also stalled. Temporary `Self._logChanges()` instrumentation provided a useful fallback during the same resize test: 282 scroll-position body changes, 57 item-view changes and 48 Markdown view creations; only four window-root changes, and no repeated RootView, ThreadView, TranscriptContent, BottomBar or Composer bodies. This supports the existing separation of scroll state from row content. It does not replace the full framework layout cause graph. Temporary logging was removed.

Native scroll-event recordings without intermediate XCTest queries still contained significant accessibility work (645 of 1,458 main-thread samples contained accessibility frames). Dependency-graph work appeared in 308, sizeThatFits in 60, text layout in 54 and Markdown in five; inclusive categories overlap. Input automation and accessibility activation remain confounders, so this is not a claim that accessibility causes ordinary human scrolling jank. Parsing did not dominate this warmed sample.

## Measurement limits

Attached/ad-hoc probe and fixture tests returned zero hitch metrics, while a separate Animation Hitches recording of the minimal split view showed expensive-app-update events during the drag period. Those zero metrics are unusable as evidence of smoothness. CPU metrics and window-size assertions worked. Signed Xcode test results and explicit frame timelines are the hitch evidence used above.

Bounding the layout work of a long active turn is a possible efficiency improvement, provided expanded tools, selection, bottom-following and reader position survive. The experiment did not establish that this would fix hitch rate; per-frame causes still need attribution. Do not move arbitrary live rows between containers just to reduce CPU. Compare against the saved native shell control, measure CPU and elapsed time, and verify hitch collection is working. Spare CPU cores cannot parallelize the main-thread view hierarchy; background preparation already uses Swift concurrency for parsing, diffs, search and images.

## Native scrolling simplification

The final app removes the added transcript keyframe glide and the explicit bottom-scroll command issued on every container-size change. It retains SwiftUI's bottom size-change anchor and normal user scrolling, plus deliberate navigation commands such as Jump to Latest. This reduces extra visual motion and avoids repeatedly requesting a scroll during window resizing. We have not established that it eliminates the reported scrollbar flashing; the scrollbar still follows native macOS behavior and preferences.

Six UI tests passed: resizing while at the end and after Jump to Latest, inspector opening/closing, streamed text fading and selection, ordinary Jump to Latest, response streaming, folding changes, and prompt navigation. A signed five-iteration long-live-turn run on the final configuration measured CPU 4.614 seconds, elapsed 3.889 seconds, and hitch rate 540.1 ms/s. Compared with the original 557.4 ms/s baseline, this does not establish a meaningful hitch improvement. Aggregate CPU and elapsed both fell about 22%; the growing workload and automation duration complicate comparisons. The rationale for this change is simpler native scrolling and less added motion, not a claim that resize jank is solved.

## Reproduction

`Tether Performance` scheme: `testResizingNewChat`, `testResizingTheWindow`, `testResizingLongTurn`, `testScrollingTheTranscript`, and the new `testResizingDuringLongLiveTurn`. The fixture uses no Claude processes or real hosts. The standalone control is in `SwiftUILayoutProbe/`.

Local recordings and console evidence for this investigation are in `/private/tmp`: `tether-swiftui-resize.trace`, `tether-minimal-split.trace`, `tether-native-scroll.trace`, `tether-body-changes.jsonl`, `tether-probe-*-test.log`, `tether-long-live-test.log`, and `tether-live-cap-experiment.log`. Preserve or re-record before relying on temporary files later.

Apple references: [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance), [app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness), [frame hitches](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app).
