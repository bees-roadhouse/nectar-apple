import Foundation

/// Where a title stands for this user.
enum DiscoverState {
    case inLibrary
    /// Approved: nectar is downloading it.
    case wanted
    /// Pending: waiting for an admin.
    case requested
    /// Someone has an open request for it and we don't know where it stands.
    case alreadyRequested

    var label: String {
        switch self {
        case .inLibrary: "In library"
        case .wanted: "Wanted"
        case .requested, .alreadyRequested: "Requested"
        }
    }

    /// The longer line in the detail sheet.
    var detail: String {
        switch self {
        case .inLibrary: "In your library"
        case .wanted: "Wanted · downloading"
        case .requested: "Requested · awaiting approval"
        case .alreadyRequested: "Already requested"
        }
    }
}
