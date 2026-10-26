import Foundation

/// Times as the screens say them, shared by the TV and the iPhone app (#158).
enum Durations {

    /// "1h 21m" or "21m"
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// "1:21:52" or "21:52"
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
