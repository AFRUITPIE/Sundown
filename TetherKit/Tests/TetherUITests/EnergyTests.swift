import Foundation
import Testing
import TetherKit
@testable import TetherUI

@Suite
struct ReducedEffectsTests {
    @Test func energySavingHeatAndTheBackgroundReduceEffects() {
        #expect(!ReducedEffects.reduces(lowPower: false, thermal: .nominal, appIsActive: true))
        #expect(!ReducedEffects.reduces(lowPower: false, thermal: .fair, appIsActive: true))
        #expect(ReducedEffects.reduces(lowPower: true, thermal: .nominal, appIsActive: true))
        #expect(ReducedEffects.reduces(lowPower: false, thermal: .serious, appIsActive: true))
        #expect(ReducedEffects.reduces(lowPower: false, thermal: .critical, appIsActive: true))
        #expect(ReducedEffects.reduces(lowPower: false, thermal: .nominal, appIsActive: false))
    }
}
