import Foundation

/// The house motion, shared with the web so a fade feels the same on every screen (Capping, nectar-apple #118).
public enum Motion {

    /// Artwork fading in over its blur, and anything else that crossfades: the web's house fade.
    public static let fade: TimeInterval = 0.2
}
