import AppKit
@testable import SundownFixtures
import SwiftUI
import Testing
import TetherProtocol
@testable import SundownKit
@testable import SundownUI

/// What the model and effort controls say for a chat, from what the host's Claude Code reports.
@MainActor
@Suite
struct SessionSettingsTests {
    /// A Bedrock host whose Claude Code settings set `modelPicker`: provider IDs under the names
    /// written there, as `model/list` returns them.
    private static let bedrock: [ModelInfo] = [
        .init(value: "default", resolvedModel: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", displayName: "Default",
              description: "Use the default model"),
        .init(value: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", resolvedModel: "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
              displayName: "Sonnet (production)", description: "Day-to-day work",
              supportsEffort: true, supportedEffortLevels: [.low, .medium, .high]),
        .init(value: "us.anthropic.claude-opus-4-6-v1", resolvedModel: "us.anthropic.claude-opus-4-6-v1",
              displayName: "Opus for reviews", description: "Custom model (us.anthropic.claude-opus-4-6-v1)",
              supportsEffort: true, supportedEffortLevels: [.low, .medium, .high, .max]),
    ]

    private func chat(model: String?, effort: EffortLevel? = nil, appliedEffort: EffortLevel? = nil) -> ThreadModel {
        let thread = ThreadModel(id: "chat")
        thread.setInfo(.init(threadId: "chat", status: .idle, cwd: "/repo", model: model, effort: effort,
                             appliedEffort: appliedEffort, lastSeq: 0))
        return thread
    }

    private func settings(_ thread: ThreadModel, models: [ModelInfo]) -> SessionSettings {
        let connection = HostConnection(host: .local)
        connection.previewSeed(state: .connected, models: models)
        return SessionSettings(thread: thread, connection: connection)
    }

    /// The model is called what Claude Code calls it (its `displayName`, a host's `modelPicker`
    /// label), never a name rebuilt from the model ID, which made Bedrock IDs nonsense (#58).
    @Test func modelsGoByClaudeCodesNames() {
        let sonnet = settings(chat(model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"), models: Self.bedrock)
        #expect(sonnet.modelLabel == "Sonnet (production)", "The model's name isn't Claude Code's: \(sonnet.modelLabel)")
        let opus = settings(chat(model: "us.anthropic.claude-opus-4-6-v1"), models: Self.bedrock)
        #expect(opus.modelLabel == "Opus for reviews", "A modelPicker label isn't the model's name: \(opus.modelLabel)")

        _ = NSApplication.shared
        let menu = NSHostingMenu(rootView: ModelPicker(settings: sonnet))
        menu.update()
        let titles = menu.items.flatMap { [$0] + ($0.submenu?.items ?? []) }.map(\.title).filter { !$0.isEmpty }
        #expect(titles.contains("Sonnet (production)"), "The Chat menu's models aren't Claude Code's names: \(titles)")
        #expect(titles.contains("Opus for reviews"), "The Chat menu's models aren't Claude Code's names: \(titles)")
    }

    /// With no effort chosen, a chat's effort is the one Claude Code applied (`appliedEffort`),
    /// not a guess (#71).
    @Test func aChatShowsTheEffortClaudeCodeApplied() {
        let unchosen = settings(chat(model: "opus", appliedEffort: .high), models: ModelInfo.sampleCatalog)
        #expect(unchosen.effectiveEffort == .high, "The effort in use isn't the one Claude Code applied")
        #expect(unchosen.effortLabel == "High")

        // One chosen is the chat's own.
        let chosen = settings(chat(model: "opus", effort: .low, appliedEffort: .low), models: ModelInfo.sampleCatalog)
        #expect(chosen.effectiveEffort == .low)
    }

    /// A model Claude Code lists with no effort levels has no effort to set, so the control is
    /// disabled and says None (#71).
    @Test func effortIsOffForAModelWithoutLevels() {
        let haiku = settings(chat(model: "haiku"), models: ModelInfo.sampleCatalog)
        #expect(haiku.effortUnavailable, "Effort is offered for a model without effort levels")
        #expect(haiku.effortLabel == "None")

        let opus = settings(chat(model: "opus"), models: ModelInfo.sampleCatalog)
        #expect(!opus.effortUnavailable)
    }
}
