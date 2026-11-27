/// Matches hotkey presses with the microphone starts they wait on. A start runs
/// off the main thread and can outlast the press that asked for it, so each start
/// carries an id, and one that finishes after it was abandoned is discarded.
struct MicrophoneStart {
    /// Whether the hotkey is down for the current dictation.
    private var holding = false
    private var latestID = 0
    private var inFlight: Int?

    enum Press: Equatable {
        /// Start the microphone, and give up on the start with this id if it is slow.
        case start(id: Int)
        /// A start from an earlier press is still running; it records this press.
        case adopt
        /// The hotkey is already down.
        case ignore
    }

    enum Arrival: Equatable {
        /// A press is waiting for this start.
        case wanted
        /// The press that waited for this start ended before it finished.
        case unwanted
        /// This start was given up on, and nothing is waiting for it.
        case abandoned
    }

    mutating func press() -> Press {
        guard !holding else { return .ignore }
        holding = true
        if inFlight != nil { return .adopt }
        latestID += 1
        inFlight = latestID
        return .start(id: latestID)
    }

    mutating func release() {
        holding = false
    }

    /// Reports what the start with `id` is for, now that it has finished.
    mutating func arrived(_ id: Int) -> Arrival {
        guard inFlight == id else { return .abandoned }
        inFlight = nil
        return holding ? .wanted : .unwanted
    }

    /// Gives up on the start with `id` if it is still running, and reports whether it was.
    mutating func timedOut(_ id: Int) -> Bool {
        guard inFlight == id else { return false }
        inFlight = nil
        return true
    }
}
