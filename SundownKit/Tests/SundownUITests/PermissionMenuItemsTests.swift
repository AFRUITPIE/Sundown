import AppKit
import SwiftUI
import Testing
import SundownKit
import TetherProtocol
@testable import SundownUI

/// A preview can't open a menu, so these read the menu SwiftUI builds from the permissions menu's
/// content. On macOS 27 a Picker's rows become menu items without their second `Text`; the
/// Toggles `PermissionModeItems` uses keep it as the item's subtitle.
@MainActor
@Suite
struct PermissionMenuItemsTests {
    private func menu(mode: PermissionMode, bypass: Bool = false) -> NSMenu {
        _ = NSApplication.shared
        var settings = SessionSettings(thread: .sample(model: "sonnet", effort: .medium, permissionMode: mode),
                                       connection: .sample())
        settings.offersBypass = bypass
        let menu = NSHostingMenu(rootView: PermissionModeItems(settings: settings))
        menu.update()
        return menu
    }

    @Test func eachModeSaysWhatItDoes() {
        let items = menu(mode: .default, bypass: true).items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == PermissionMode.selectable.map(\.longLabel))
        #expect(items.map(\.subtitle) == PermissionMode.selectable.map(\.summary))
        #expect(items.allSatisfy { $0.image != nil })
    }

    @Test func theChosenModeIsChecked() {
        let items = menu(mode: .plan).items.filter { !$0.isSeparatorItem }
        #expect(items.filter { $0.state == .on }.map(\.title) == [PermissionMode.plan.longLabel])
    }

    @Test func bypassIsListedOnlyWhenOffered() {
        let titles = menu(mode: .default).items.map(\.title)
        #expect(!titles.contains(PermissionMode.bypassPermissions.longLabel))
    }

    @Test(arguments: PermissionMode.selectable)
    func everyListedModeHasALine(mode: PermissionMode) {
        #expect(mode.summary?.isEmpty == false, "\(mode.rawValue) has no line under its name")
    }

    @Test func anUnknownModeHasNoLine() {
        #expect(PermissionMode(rawValue: "somethingNewerServersSend").summary == nil)
    }
}
