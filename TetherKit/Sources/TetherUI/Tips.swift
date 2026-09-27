import SwiftUI
import TipKit

/// What's worth knowing and easy to miss, shown once each (TipKit).
struct ComposerTip: Tip {
    var title: Text { Text("Commands and Files") }
    var message: Text? { Text("Type / for Claude Code’s commands, or @ to mention a file. Both are in this menu too.") }
    var image: Image? { Image(systemName: "command") }
}

struct InspectorTip: Tip {
    var title: Text { Text("Inspector Panes") }
    var message: Text? { Text("⌥⌘1 to ⌥⌘4 open Tasks, Session, MCP and Changes; ⌥⌘I hides the inspector.") }
    var image: Image? { Image(systemName: "sidebar.trailing") }
}

public enum TetherTips {
    /// Once at launch. In UI tests tips stay hidden, so none covers what a test clicks.
    public static func configure(showing: Bool) {
        let uiTest = ProcessInfo.processInfo.environment["TETHER_UI_TEST_MODE"] == "1"
        if uiTest || !showing { Tips.hideAllTipsForTesting() }
        try? Tips.configure([.displayFrequency(.daily)])
    }

    /// Settings ▸ General ▸ Show Tips Again.
    public static func reset() {
        try? Tips.resetDatastore()
    }
}
