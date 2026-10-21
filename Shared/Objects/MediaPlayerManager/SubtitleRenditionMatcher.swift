//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Finds the HLS subtitle rendition a Jellyfin subtitle stream plays as.
///
/// A server names each rendition after its stream's display title (the HLS `NAME`, which AVFoundation exposes as the
/// option's common-metadata title, not as `displayName`) and marks forced ones, so the name decides first, then the
/// language with the forced flag. Position and language alone are the last resorts: image streams in the file have no
/// rendition, so positions can line up by accident and point at the wrong track.
enum SubtitleRenditionMatcher {

    struct Stream: Equatable {
        let index: Int
        let displayTitle: String?
        let language: String?
        let isForced: Bool
    }

    struct Rendition: Equatable {
        /// The HLS `NAME`.
        let name: String?
        let language: String?
        let isForced: Bool
    }

    /// The position in `renditions` that plays `stream`, or nil when none does.
    /// - Parameter embeddedIndexes: the file's embedded subtitle stream indexes in order, for the positional fallback.
    static func rendition(for stream: Stream, in renditions: [Rendition], embeddedIndexes: [Int]) -> Int? {
        if let title = stream.displayTitle, let named = renditions.firstIndex(where: { $0.name == title }) {
            return named
        }

        let language = baseLanguage(stream.language)

        if let language,
           let match = renditions.firstIndex(where: { baseLanguage($0.language) == language && $0.isForced == stream.isForced })
        {
            return match
        }

        if embeddedIndexes.count == renditions.count, let position = embeddedIndexes.firstIndex(of: stream.index) {
            return position
        }

        if renditions.count == 1 {
            return 0
        }

        if let language {
            return renditions.firstIndex { baseLanguage($0.language) == language }
        }

        return nil
    }

    /// "en", "eng" and "en-US" are one language; an empty or undetermined tag is none.
    static func baseLanguage(_ tag: String?) -> String? {
        guard let tag = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !tag.isEmpty, tag != "und" else { return nil }

        let code = Locale.Language(identifier: tag).languageCode
        return code?.identifier(.alpha2) ?? code?.identifier
    }
}
