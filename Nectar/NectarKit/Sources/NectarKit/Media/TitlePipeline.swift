import Foundation

/// Where a title stands on its way into the library, as nectar sends it on every film and series card and on the
/// item document (nectar #686 slice 1, #773; #592's `TitlePipeline`). `nil` when nothing is happening.
public struct TitlePipeline: Decodable, Equatable, Sendable {

    /// The bytes of a download in flight, while `stage` is downloading, paused or attention.
    public struct Download: Decodable, Equatable, Sendable {
        public let bytesDone: Double?
        public let bytesTotal: Double?
        public let etaSeconds: Double?
        /// "verifying" or "extracting" once the bytes are in.
        public let phase: String?

        enum CodingKeys: String, CodingKey {
            case bytesDone = "bytes_done"
            case bytesTotal = "bytes_total"
            case etaSeconds = "eta_seconds"
            case phase
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bytesDone = c.lenientDouble(.bytesDone)
            bytesTotal = c.lenientDouble(.bytesTotal)
            etaSeconds = c.lenientDouble(.etaSeconds)
            phase = try c.decodeIfPresent(String.self, forKey: .phase)
        }
    }

    /// requested, searching, no_release, paused, downloading, importing, attention, upgrading, available or denied.
    /// A string, so a stage nectar adds later decodes, and reads as nothing.
    public let stage: String
    public let download: Download?
}

/// What a card shows of where its title stands, the TV's port of the web's `cardPill` and `cardArrival`
/// (`web-solid/src/card_stage.ts`, words from `pipeline_view.ts`), so a title reads the same on both (Capping, #125).
/// Nate's rule (2026-10-21): a card shows the gold Upgrading pill, the only in-library state it shows, or a stage on
/// the way in as a thin line at its foot with the words in the focused card's caption. Nothing for a plain owned
/// title, a denied request, or a stage the TV doesn't know.
public enum CardStatus: Equatable, Sendable {
    case upgrading
    case arriving(Arrival)

    public struct Arrival: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// Nothing measures it yet: a clock.
            case waiting
            case active
            case paused
            /// It needs an admin.
            case failed
        }

        public let words: String
        public let state: State
        /// 0...1 when something measures it.
        public let value: Double?
        /// A sweep, for a stage that's moving but unmeasured.
        public let indeterminate: Bool

        public init(words: String, state: State, value: Double?, indeterminate: Bool) {
            self.words = words
            self.state = state
            self.value = value
            self.indeterminate = indeterminate
        }
    }

    /// The words for the focused card's caption, or nil for the pill.
    public var words: String? {
        if case let .arriving(arrival) = self { return arrival.words }
        return nil
    }

    public static func of(_ pipeline: TitlePipeline?) -> CardStatus? {
        guard let pipeline else { return nil }
        let total = pipeline.download?.bytesTotal ?? 0
        let fraction = total > 0 ? (pipeline.download?.bytesDone ?? 0) / total : nil
        switch pipeline.stage {
        case "upgrading":
            return .upgrading
        case "requested":
            return .arriving(.init(words: "Waiting for approval", state: .waiting, value: nil, indeterminate: false))
        case "no_release":
            return .arriving(.init(words: "No release yet", state: .waiting, value: nil, indeterminate: false))
        case "searching":
            return .arriving(.init(words: "Looking for a release", state: .active, value: nil, indeterminate: true))
        case "importing":
            return .arriving(.init(words: "Adding to the library", state: .active, value: nil, indeterminate: true))
        case "paused":
            return .arriving(.init(words: "Paused", state: .paused, value: fraction, indeterminate: false))
        case "attention":
            return .arriving(.init(words: "Couldn't download · an admin has been told", state: .failed, value: fraction, indeterminate: false))
        case "downloading":
            switch pipeline.download?.phase {
            case "verifying": return .arriving(.init(words: "Checking the download", state: .active, value: nil, indeterminate: true))
            case "extracting": return .arriving(.init(words: "Unpacking", state: .active, value: nil, indeterminate: true))
            default: break
            }
            guard let fraction else { return .arriving(.init(words: "Downloading", state: .active, value: nil, indeterminate: true)) }
            let left = eta(pipeline.download?.etaSeconds)
            let words = "\(size(fraction * total)) of \(size(total))" + (left.map { " · \($0)" } ?? "")
            return .arriving(.init(words: words, state: .active, value: fraction, indeterminate: false))
        default:
            return nil
        }
    }

    private static let gigabyte = Double(1 << 30)
    private static let megabyte = Double(1 << 20)

    static func size(_ bytes: Double) -> String {
        bytes >= gigabyte ? String(format: "%.1f GB", bytes / gigabyte) : "\(max(1, Int((bytes / megabyte).rounded()))) MB"
    }

    static func eta(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 60 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min left" }
        return "\(minutes / 60) h \(minutes % 60) min left"
    }
}
