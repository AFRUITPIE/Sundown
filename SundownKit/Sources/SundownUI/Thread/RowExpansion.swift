import SwiftUI

/// Which of the transcript's rows are open (a call, a run of calls, a turn's work or edits, a file in
/// them), by what they show, kept by the transcript rather than the row: only rows near the view are
/// built, and a row built again after the reader scrolled far away opens as they left it, at the
/// height the transcript knows it by. One box per row, so opening one redraws only that row.
@MainActor
final class RowExpansion {
    @MainActor @Observable
    final class Box {
        var isOpen = false
    }

    private var boxes: [String: Box] = [:]

    func box(_ key: String) -> Box {
        if let box = boxes[key] { return box }
        let box = Box()
        boxes[key] = box
        return box
    }
}

extension EnvironmentValues {
    /// The transcript's open rows; nil elsewhere (a preview, Tasks' transcripts), where a row keeps
    /// its own.
    @Entry var rowExpansion: RowExpansion? = nil
}

/// A row's open state: the transcript's (`RowExpansion`) under the key given, else the view's own.
struct KeptExpansion: DynamicProperty {
    @Environment(\.rowExpansion) private var store
    @State private var own: Bool

    init(_ initial: Bool = false) {
        _own = State(initialValue: initial)
    }

    @MainActor func callAsFunction(_ key: String?) -> Binding<Bool> {
        guard let store, let key else { return $own }
        let box = store.box(key)
        return Binding(get: { box.isOpen }, set: { box.isOpen = $0 })
    }
}
