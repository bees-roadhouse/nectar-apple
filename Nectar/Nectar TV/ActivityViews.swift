import NectarKit
import SwiftUI

/// Home's Now Downloading row: what's in flight, live. Hidden when nothing is.
struct NowDownloadingRow: View {

    let model: ActivityModel
    let open: () -> Void

    var body: some View {
        if !model.board.active.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text("Now downloading").font(.title3.bold())
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 40) {
                        ForEach(model.board.active) { download in
                            Button(action: open) { DownloadTile(download: download) }
                                .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// Activity, full screen: in flight, then the last day's failures and why.
struct ActivityView: View {

    let model: ActivityModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity").font(.largeTitle.bold())
                    Text(model.connected ? "Live" : "Reconnecting…").font(.caption).foregroundStyle(.secondary)
                }
                if model.board.active.isEmpty {
                    Text("Nothing downloading right now.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.board.active) { download in
                        Button {} label: { DownloadTile(download: download, wide: true) }
                            .buttonStyle(.plain)
                    }
                }
                if !model.board.failed.isEmpty {
                    Text("Didn't finish").font(.title3.bold())
                    ForEach(model.board.failed) { download in
                        Button {} label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(download.title).font(.headline)
                                Text(download.reason ?? "No reason given").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(24)
                            .frame(width: 1400, alignment: .leading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}

/// A transfer: its title, a bar, the percent and time left.
private struct DownloadTile: View {

    let download: Download
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(download.title).font(.headline).lineLimit(2)
            ProgressView(value: min(max(download.percent, 0), 100), total: 100).tint(.white)
            HStack {
                Text("\(Int(download.percent.rounded()))%")
                Spacer()
                if let left = ActivityModel.timeLeft(download) { Text(left) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: wide ? 1400 : 480, height: wide ? nil : 170, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
