import AppKit
import Testing
import TetherProtocol
@testable import TetherUI

/// The session menus are mostly icons, so a symbol name that doesn't exist on this OS is a blank
/// control, not a compile error. Every name the mappings can produce is resolved here.
@Suite
struct SessionSymbolTests {
    private func expectResolves(_ name: String, _ comment: Comment) {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, comment)
    }

    @Test func fixedSymbolsResolve() {
        for name in [SessionSymbol.model, SessionSymbol.fastMode, SessionSymbol.automaticEffort] {
            expectResolves(name, "\(name) does not exist on this OS")
        }
    }

    @Test func permissionModeSymbolsResolve() {
        for mode in PermissionMode.allCases + [PermissionMode(rawValue: "somethingNewerServersSend")] {
            expectResolves(mode.symbol, "\(mode.rawValue) → \(mode.symbol) does not exist on this OS")
        }
    }

    /// Every catalog shape the app can meet: one level up to all of them, plus a level the model
    /// doesn't list and Automatic.
    @Test func effortSymbolsResolve() {
        let catalogs: [[EffortLevel]] = (1...EffortLevel.allCases.count).map { Array(EffortLevel.allCases.prefix($0)) }
        for levels in catalogs {
            expectResolves(EffortLevel?.none.symbol(in: levels), "Automatic symbol does not exist on this OS")
            for level in EffortLevel.allCases {
                let symbol = Optional(level).symbol(in: levels)
                expectResolves(symbol, "\(level.rawValue) in \(levels.map(\.rawValue)) → \(symbol) does not exist")
            }
        }
    }

    /// The needle has to move across the levels, or the icon says nothing.
    @Test func theNeedleFollowsTheValue() {
        let three: [EffortLevel] = [.low, .medium, .high]
        #expect(EffortLevel.low.symbol(in: three) == "gauge.with.dots.needle.0percent")
        #expect(EffortLevel.medium.symbol(in: three) == "gauge.with.dots.needle.50percent")
        #expect(EffortLevel.high.symbol(in: three) == "gauge.with.dots.needle.100percent")

        let four: [EffortLevel] = [.low, .medium, .high, .max]
        #expect(EffortLevel.medium.symbol(in: four) == "gauge.with.dots.needle.33percent")
        #expect(EffortLevel.high.symbol(in: four) == "gauge.with.dots.needle.67percent")

        // A level this model doesn't offer can't claim a position on its gauge.
        #expect(EffortLevel.xhigh.symbol(in: three) == SessionSymbol.automaticEffort)
        #expect(EffortLevel?.none.symbol(in: three) == SessionSymbol.automaticEffort)
    }

    @Test func effortLabelsReadAsWords() {
        #expect(EffortLevel?.none.label == "Automatic")
        #expect(EffortLevel.medium.label == "Medium")
        #expect(EffortLevel.xhigh.label == "Extra High")
    }
}
