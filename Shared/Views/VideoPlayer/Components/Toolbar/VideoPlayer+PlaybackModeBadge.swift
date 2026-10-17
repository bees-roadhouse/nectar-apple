//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

extension VideoPlayer.PlaybackControls.Toolbar {

    /// Names how the server is delivering the current item (direct play, remux, audio transcode, transcode),
    /// so a transcode is visible without opening the session supplement.
    struct PlaybackModeBadge: View {

        @StateObject
        private var provider: PlaybackInformationProvider

        init(itemID: String) {
            _provider = StateObject(wrappedValue: PlaybackInformationProvider(itemID: itemID))
        }

        var body: some View {
            if let mode = provider.currentSession?.playbackDeliveryMode {
                Label(mode.displayTitle, systemImage: mode.systemImage)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(mode == .transcode ? .orange : .secondary)
            }
        }
    }
}
