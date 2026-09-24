import AppKit
import Foundation
import Testing
import TetherKit
import TetherProtocol
@testable import TetherUI

/// The host fields apply as they lose focus, so what counts as a commit is worth pinning down:
/// a commit here can reconnect the host, and an empty one would make it unreachable.
@Suite
struct HostFieldTests {
    @Test func aChangedValueCommitsTrimmed() {
        #expect(HostField.commit("  build-box  ", current: "staging") == "build-box")
    }

    @Test func anUnchangedValueIsNotWorthAReconnect() {
        #expect(HostField.commit("build-box", current: "build-box") == nil)
        #expect(HostField.commit("  build-box ", current: "build-box") == nil)
    }

    @Test func anEmptyNameOrDestinationIsRefused() {
        #expect(HostField.commit("", current: "build-box") == nil)
        #expect(HostField.commit("   \n", current: "build-box") == nil)
    }

    /// The server command is the one field whose empty value means something: "Automatic".
    @Test func aFieldThatAllowsEmptyCommitsIt() {
        #expect(HostField.commit("", current: "npm start", allowsEmpty: true) == "")
        #expect(HostField.commit("", current: "", allowsEmpty: true) == nil)
    }
}

@Suite
struct EnvVariableTests {
    @Test func rowsAreTheStoredEnvironmentInOrder() {
        let rows = EnvVariable.rows(["AWS_REGION": "us-west-2", "AWS_PROFILE": "tether"])

        #expect(rows.map(\.name) == ["AWS_PROFILE", "AWS_REGION"])
        #expect(rows.map(\.value) == ["tether", "us-west-2"])
    }

    @Test func roundTripsThroughTheTable() {
        let environment = ["AWS_PROFILE": "tether", "AWS_REGION": "us-west-2"]
        #expect(EnvVariable.environment(EnvVariable.rows(environment)) == environment)
    }

    @Test func halfTypedRowsAreNotStored() {
        let rows = [EnvVariable(name: "  AWS_PROFILE ", value: "tether"),
                    EnvVariable(name: "  ", value: "orphaned"),
                    EnvVariable()]

        #expect(EnvVariable.environment(rows) == ["AWS_PROFILE": "tether"])
    }

    @Test func aRepeatedNameKeepsTheLastValue() {
        let rows = [EnvVariable(name: "AWS_REGION", value: "us-east-1"),
                    EnvVariable(name: "AWS_REGION", value: "us-west-2")]

        #expect(EnvVariable.environment(rows) == ["AWS_REGION": "us-west-2"])
    }

    /// A row keeps its identity while its name is being typed, or the table would reorder itself
    /// under the cursor.
    @Test func rowsAreIdentifiedIndependentlyOfTheirName() {
        var row = EnvVariable(name: "A", value: "1")
        let id = row.id
        row.name = "B"

        #expect(row.id == id)
    }
}

/// Settings shows connection state as a symbol plus a word — a name that doesn't resolve on this
/// OS would leave the row saying nothing but a colour.
@MainActor
@Suite
struct HostStatusTests {
    private let states: [HostConnection.State] = [.connected, .connecting("Handshaking…"),
                                                  .failed("Connection refused"), .disconnected]

    @Test func everyStateSymbolResolves() {
        for state in states {
            #expect(NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil) != nil,
                    "\(state.symbol) does not exist on this OS")
        }
    }

    @Test func statesReadAsWords() {
        #expect(HostConnection.State.connected.label == "Connected")
        #expect(HostConnection.State.failed("Connection refused").label == "Not Connected")
        #expect(HostConnection.State.disconnected.label == "Not Connected")
        // Connecting shows the daemon's own progress message.
        #expect(HostConnection.State.connecting("Handshaking…").detailLabel == "Handshaking…")
    }

    @Test func onlyAFailureCarriesAMessage() {
        #expect(HostConnection.State.failed("Connection refused").failureMessage == "Connection refused")
        #expect(HostConnection.State.connected.failureMessage == nil)
        #expect(HostConnection.State.connecting("Handshaking…").failureMessage == nil)
    }
}

/// Permission modes name themselves the same way in the toolbar menu and in Settings.
@Suite
struct PermissionLabelTests {
    @Test func menuRowsAreTitleCase() {
        #expect(PermissionMode.default.longLabel == "Ask Before Edits")
        #expect(PermissionMode.acceptEdits.longLabel == "Accept Edits")
        #expect(PermissionMode.plan.longLabel == "Plan Mode")
        #expect(PermissionMode.auto.longLabel == "Auto")
        #expect(PermissionMode.dontAsk.longLabel == "Don't Ask")
        #expect(PermissionMode.bypassPermissions.longLabel == "Bypass Permissions")
    }

    /// Forward compatibility: a mode a newer daemon introduces still has to display as words.
    @Test func anUnknownModeIsNotShownAsAWireValue() {
        #expect(PermissionMode(rawValue: "askForRisky").longLabel == "Ask For Risky")
        #expect(PermissionMode(rawValue: "askForRisky").label == "Ask For Risky")
    }

    @Test func everySelectableModeIsOffered() {
        #expect(PermissionMode.selectable.count == 6)
        #expect(PermissionMode.selectable.first == .default)
        // The one that stops Claude asking is last.
        #expect(PermissionMode.selectable.last == .bypassPermissions)
    }
}
