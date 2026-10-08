import Foundation

/// What the pet expresses, derived from the most urgent thread.
public enum PetMood: Sendable, Equatable {
    case idle, waiting, failed, ready, running

    /// One-shot plays when the mood starts.
    var sequence: [PetRow] {
        switch self {
        case .idle: return []
        case .waiting: return [.waiting, .waiting, .waiting]
        case .failed: return [.failed, .failed, .failed]
        case .ready: return [.jumping, .review, .review, .review]
        case .running: return [.running, .running, .running]
        }
    }

    /// Seconds from one sequence start to the next while the mood holds, or nil to play once.
    var cadence: TimeInterval? {
        switch self {
        case .waiting: return 8
        case .running: return 20
        default: return nil
        }
    }

    /// The row shown as a still frame when Reduce Motion is on.
    var stillRow: PetRow {
        switch self {
        case .idle: return .idle
        case .waiting: return .waiting
        case .failed: return .failed
        case .ready: return .review
        case .running: return .running
        }
    }
}

public enum DragDirection: Sendable, Equatable {
    case left, right

    var row: PetRow { self == .left ? .runningLeft : .runningRight }
}

/// Decides which atlas row and frame the pet shows.
///
/// A pure state machine over a monotonic clock in seconds: feed it inputs, call
/// `update(at:)` whenever `nextDeadline` passes, then draw `row` and `frame`.
public struct PetAnimator: Sendable {
    public private(set) var row: PetRow = .idle
    public private(set) var frame = 0
    public private(set) var reduceMotion: Bool

    private var mood: PetMood = .idle
    /// Plays still to come after the current one.
    private var queue: [PetRow] = []
    /// True for the idle and drag loops, false during one-shot plays.
    private var looping = true
    private var frameEndsAt: TimeInterval
    private var nextSequenceAt: TimeInterval?
    private var drag: DragDirection?
    private var moodChangedDuringDrag = false

    /// Idle frames last this many times longer when looping.
    static let idleSlowdown: TimeInterval = 6
    /// Lag beyond which missed frames are dropped instead of replayed (e.g. after sleep).
    static let maxLag: TimeInterval = 2

    public init(now: TimeInterval, reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
        frameEndsAt = now
        startIdleLoop(at: now)
        applyStill()
    }

    /// When the shown frame next changes, or nil while nothing animates.
    public var nextDeadline: TimeInterval? {
        guard !reduceMotion else { return nil }
        if looping, drag == nil, let start = nextSequenceAt { return min(frameEndsAt, start) }
        return frameEndsAt
    }

    /// Follow the most urgent thread. Repeating the current mood changes nothing.
    public mutating func setMood(_ newMood: PetMood, at now: TimeInterval) {
        guard newMood != mood else { return }
        mood = newMood
        if drag != nil {
            moodChangedDuringDrag = true
        } else {
            startSequence(at: now)
        }
        applyStill()
    }

    /// The pointer moved onto the pet: wave once, unless something else is playing.
    public mutating func hover(at now: TimeInterval) {
        guard !reduceMotion, drag == nil, looping else { return }
        queue = []
        startPlay(.waving, at: now)
    }

    /// The pet is being dragged in `direction`.
    public mutating func drag(_ direction: DragDirection, at now: TimeInterval) {
        guard direction != drag else { return }
        drag = direction
        queue = []
        looping = true
        show(direction.row, frame: 0, at: now)
        applyStill()
    }

    public mutating func endDrag(at now: TimeInterval) {
        guard drag != nil else { return }
        drag = nil
        if moodChangedDuringDrag {
            moodChangedDuringDrag = false
            startSequence(at: now)
        } else {
            startIdleLoop(at: now)
        }
        applyStill()
    }

    public mutating func setReduceMotion(_ on: Bool, at now: TimeInterval) {
        guard on != reduceMotion else { return }
        reduceMotion = on
        if !on { startIdleLoop(at: now) }
        applyStill()
    }

    /// Advance to `now`, playing through every frame boundary that has passed.
    public mutating func update(at now: TimeInterval) {
        guard !reduceMotion else { return }
        if let deadline = nextDeadline, now - deadline > Self.maxLag {
            // Too far behind to replay every frame (e.g. after sleep): resume from now.
            if drag == nil {
                queue = []
                startIdleLoop(at: now)
            } else {
                frameEndsAt = now
            }
        }
        while let deadline = nextDeadline, deadline <= now {
            if looping, drag == nil, let start = nextSequenceAt, start <= frameEndsAt {
                startSequence(at: start)
            } else {
                advance(at: frameEndsAt)
            }
        }
    }

    // MARK: transitions

    private mutating func startSequence(at time: TimeInterval) {
        var plays = mood.sequence
        nextSequenceAt = mood.cadence.map { time + $0 }
        guard !plays.isEmpty else { return startIdleLoop(at: time) }
        startPlay(plays.removeFirst(), at: time)
        queue = plays
    }

    private mutating func startPlay(_ playRow: PetRow, at time: TimeInterval) {
        looping = false
        show(playRow, frame: 0, at: time)
    }

    private mutating func startIdleLoop(at time: TimeInterval) {
        looping = true
        if let start = nextSequenceAt, start <= time {
            startSequence(at: time)
        } else {
            show(.idle, frame: 0, at: time)
        }
    }

    private mutating func advance(at time: TimeInterval) {
        if frame + 1 < row.frameCount {
            show(row, frame: frame + 1, at: time)
        } else if looping {
            show(row, frame: 0, at: time)
        } else if !queue.isEmpty {
            startPlay(queue.removeFirst(), at: time)
        } else {
            startIdleLoop(at: time)
        }
    }

    private mutating func show(_ newRow: PetRow, frame newFrame: Int, at time: TimeInterval) {
        row = newRow
        frame = newFrame
        let slowdown = newRow == .idle ? Self.idleSlowdown : 1
        frameEndsAt = time + newRow.frameDurations[newFrame] * slowdown
    }

    /// Under Reduce Motion, hold frame 0 of the row that matches the current state.
    private mutating func applyStill() {
        guard reduceMotion else { return }
        row = drag?.row ?? mood.stillRow
        frame = 0
    }
}
