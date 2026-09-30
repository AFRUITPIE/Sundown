import Foundation
import Observation
import SwiftUI

/// Whether to leave out motion that only decorates — a chat's spinning glyph, the transcript's
/// a reply's words fading in, Thinking's shimmer — because the Mac is saving energy (Low
/// Power Mode), is running hot (serious or critical), or has another app in front. Each ran every
/// frame while a turn did. Treated as Reduce Motion is, where the effect is drawn
/// (`EnvironmentValues.reducesEffects`). This follows the Mac's power and heat; whether the app is
/// in front is `AppModel.isActive`, which the app delegate keeps.
@MainActor
@Observable
final class ReducedEffects {
    /// Low Power Mode, or a serious or critical thermal state.
    private(set) var savingEnergy = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        observers = [
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: refresh),
        ]
        update()
    }

    private func update() {
        let info = ProcessInfo.processInfo
        let on = Self.reduces(lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState, appIsActive: true)
        if on != savingEnergy { savingEnergy = on }
    }

    nonisolated static func reduces(lowPower: Bool, thermal: ProcessInfo.ThermalState, appIsActive: Bool) -> Bool {
        lowPower || thermal == .serious || thermal == .critical || !appIsActive
    }
}

extension EnvironmentValues {
    /// Leave out decorative motion to save energy, as under Reduce Motion (`ReducedEffects`).
    @Entry var reducesEffects = false
}
