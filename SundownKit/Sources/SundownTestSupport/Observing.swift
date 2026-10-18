import Observation
import Testing

/// Whether what an `observing` call read has changed since. Observation's `onChange` is
/// `@Sendable`, so the flag it sets needs a reference to live in.
public final class Changed: @unchecked Sendable {
    public var happened = false
}

/// Watches what `reading` reads, as a view's body would: the result says whether any of it changed.
public func observing(_ reading: () -> Void) -> Changed {
    let changed = Changed()
    withObservationTracking(reading) { changed.happened = true }
    return changed
}

/// Fails unless nothing `reading` reads changes during `change`: what a view showing it would be
/// told to redraw for.
public func expectUnchanged(
    reading: () -> Void, during change: () -> Void, _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let observed = observing(reading)
    change()
    #expect(!observed.happened, comment, sourceLocation: sourceLocation)
}

/// `expectUnchanged(reading:during:)`, for a change that's awaited.
public func expectUnchanged(
    isolation: isolated (any Actor)? = #isolation,
    reading: () -> Void, during change: () async -> Void, _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let observed = observing(reading)
    await change()
    #expect(!observed.happened, comment, sourceLocation: sourceLocation)
}
