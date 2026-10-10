#if DEBUG
import AppKit
import OSLog
import SwiftUI
import SundownKit

/// Temporary diagnostics for the transcript's scrolling (SUNDOWN_SCROLL_TRACE=1): every change of
/// its scroll geometry and phase, with how many rows are on screen and held, logged under
/// subsystem com.haydenhong.Sundown, category ScrollTrace.
struct ScrollTrace: ViewModifier {
    let thread: ThreadModel
    let visible: TranscriptView.OnScreenRows
    static let enabled = ProcessInfo.processInfo.environment["SUNDOWN_SCROLL_TRACE"] == "1"
    private static let log = Logger(subsystem: "com.haydenhong.Sundown", category: "ScrollTrace")

    struct Geometry: Equatable {
        let offset: CGFloat
        let content: CGFloat
        let container: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    func body(content: Content) -> some View {
        if Self.enabled {
            content
                .onScrollGeometryChange(for: Geometry.self) { g in
                    Geometry(offset: g.contentOffset.y.rounded(), content: g.contentSize.height.rounded(),
                             container: g.containerSize.height.rounded(),
                             top: g.contentInsets.top.rounded(), bottom: g.contentInsets.bottom.rounded())
                } action: { old, new in
                    StressState.offset = new.offset
                    StressState.content = new.content
                    StressState.container = new.container
                    let fromEnd = new.content - new.offset - new.container
                    // Scrolled past what there is: a lazy stack there has no rows to show.
                    if new.offset > new.content - new.container + new.bottom + 120 || new.offset < -new.top - 120 {
                        Self.log.error("PASTEND offset=\(new.offset) content=\(new.content) container=\(new.container) items=\(thread.items.count)")
                    }
                    Self.log.debug("""
                        geom offset=\(new.offset) dOffset=\(new.offset - old.offset) content=\(new.content) \
                        dContent=\(new.content - old.content) fromEnd=\(fromEnd) insets=\(new.top),\(new.bottom) container=\(new.container) visible=\(visible.ids.count) \
                        items=\(thread.items.count)
                        """)
                }
                .onScrollPhaseChange { old, new in
                    Self.log.debug("phase \(String(describing: old), privacy: .public) -> \(String(describing: new), privacy: .public)")
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                    if ids.isEmpty, !thread.items.isEmpty {
                        Self.log.error("BLANK no rows visible items=\(thread.items.count) loaded=\(thread.historyLoaded)")
                    }
                }
                .onChange(of: thread.items.count) { old, new in
                    Self.log.debug("items \(old) -> \(new) hasMore=\(thread.hasMoreHistory)")
                }
        } else {
            content
        }
    }
}
#endif

#if DEBUG
/// Where each built row is, in the scroll view's own space, for a blank detector that doesn't rely
/// on the visibility callback (which goes quiet after a programmatic jump).
@MainActor final class RowFrames {
    static let shared = RowFrames()
    var frames: [String: CGRect] = [:]

    /// How many built rows overlap the visible part of the scroll view.
    func onScreen(height: CGFloat) -> Int {
        frames.values.filter { $0.maxY > 0 && $0.minY < height && $0.height > 0 }.count
    }
}

struct TraceRowFrame: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if ScrollTrace.enabled {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { RowFrames.shared.frames[id] = $0 }
                .onDisappear { RowFrames.shared.frames[id] = nil }
        } else {
            content
        }
    }
}

/// Samples the rows on screen every 100 ms; two empty samples in a row with items held is a blank.
struct BlankSampler: ViewModifier {
    let thread: ThreadModel
    private static let log = Logger(subsystem: "com.haydenhong.Sundown", category: "ScrollTrace")

    /// How much of the transcript's column is drawn: the share of sampled pixels that differ from
    /// the background, in the middle of the window's right two thirds. Near zero is a blank.
    @MainActor static func ink() -> Double? {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, let bg = rep.colorAt(x: w - 40, y: h / 2) else { return nil }
        var inked = 0, total = 0
        for y in stride(from: h * 12 / 100, to: h * 82 / 100, by: 6) {
            for x in stride(from: w * 35 / 100, to: w * 90 / 100, by: 6) {
                total += 1
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.15 { inked += 1 }
            }
        }
        return total > 0 ? Double(inked) / Double(total) : nil
    }

    /// The key window as drawn, to SUNDOWN_SNAPSHOT_DIR, so a blank can be looked at afterwards.
    @MainActor static func snapshot() {
        guard let dir = ProcessInfo.processInfo.environment["SUNDOWN_SNAPSHOT_DIR"],
              let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let name = "\(dir)/blank-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
        log.error("TRUEBLANK snapshot \(name, privacy: .public)")
    }

    func body(content: Content) -> some View {
        content.task {
            guard ScrollTrace.enabled else { return }
            var empty = 0
            var reported = false
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let n = RowFrames.shared.onScreen(height: StressState.container)
                tick += 1
                if tick % 20 == 0 { Self.log.debug("SAMPLE rows=\(n) built=\(RowFrames.shared.frames.count) ink=\(Self.ink() ?? -1)") }
                if n == 0, thread.historyLoaded, !thread.items.isEmpty {
                    empty += 1
                    if empty >= 2, !reported {
                        reported = true
                        Self.log.error("TRUEBLANK no built row on screen items=\(thread.items.count) offset=\(StressState.offset) content=\(StressState.content) built=\(RowFrames.shared.frames.count) visibleWindow=\(NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.contentView != nil }) active=\(NSApp.isActive)")
                        Self.log.error("TRUEBLANK ink=\(Self.ink() ?? -1)")
                        Self.snapshot()
                    }
                } else {
                    if reported { Self.log.error("TRUEBLANK ended after \(empty * 100) ms rows=\(n)") }
                    empty = 0
                    reported = false
                }
            }
        }
    }
}
#endif
