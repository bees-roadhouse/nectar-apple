import AVFoundation
import NectarKit
import SwiftUI

/// The Playback tab in the player's swipe-down info panel (#82), for admins: how nectar is sending this title
/// and why, what the file is, the audio track, and what's arriving now (refreshed every two seconds).
struct PlaybackInfoPanel: View {

    let model: PlayerModel
    let player: AVPlayer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 40, verticalSpacing: 14) {
                ForEach(lines) { line in
                    GridRow {
                        Text(line.label)
                            .foregroundStyle(.secondary)
                        Text(line.value)
                            .monospacedDigit()
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 60)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lines: [PlaybackInfo.Line] {
        guard case let .playing(_, decision) = model.phase else { return [] }
        let item = player.currentItem
        return PlaybackInfo.lines(
            decision: decision,
            source: model.source,
            observedBitrate: item?.accessLog()?.events.last?.observedBitrate,
            presentation: item?.presentationSize
        )
    }
}
