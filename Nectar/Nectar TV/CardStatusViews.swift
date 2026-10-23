import NectarKit
import SwiftUI

extension Color {
    /// Gold, `--brh-gold` on the Brand & Visual Identity Standard (KB page 2451): the Upgrading pill.
    static let brhGold = Color(red: 0xE8 / 255, green: 0xA0 / 255, blue: 0x3A / 255)
    /// `--brh-gold-ink`: lettering on gold.
    static let brhGoldInk = Color(red: 0x1A / 255, green: 0x14 / 255, blue: 0x07 / 255)
    /// `--brh-ok`: the Upgrading pill, #142's vocabulary as the web has it (gold is for what you tap: Capping, #159).
    static let brhOk = Color(red: 0x8F / 255, green: 0xBF / 255, blue: 0x6A / 255)
    /// `--brh-err`: a stage that needs an admin.
    static let brhErr = Color(red: 0xE0 / 255, green: 0x6B / 255, blue: 0x52 / 255)
}

extension View {
    /// Where a card's title stands (#125, Capping's table, the same as the web's): the gold Upgrading pill at the
    /// top trailing corner, or a thin line at the foot for a title on its way in. Nothing for a plain owned title.
    func cardStatus(_ status: CardStatus?) -> some View {
        modifier(CardStatusOverlay(status: status))
    }
}

private struct CardStatusOverlay: ViewModifier {

    let status: CardStatus?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if case .upgrading = status { UpgradingPill().padding(10) }
            }
            .overlay(alignment: .bottom) {
                if case let .arriving(arrival) = status { ArrivalFoot(arrival: arrival).padding(10) }
            }
    }
}

/// "Upgrading", with its arrow: an owned title still looking for a better copy.
struct UpgradingPill: View {

    /// The pill's lettering: caption2 is right at a TV's distance, but on a phone it's 11 pt, under the 12 pt
    /// floor (Capping, #158), so the phone takes caption1.
    #if os(tvOS)
    static let font = Font.caption2
    #else
    static let font = Font.caption
    #endif

    var body: some View {
        Label("Upgrading", systemImage: "arrow.up")
            .lineLimit(1)
            .font(Self.font.weight(.semibold))
            .foregroundStyle(Color.brhGoldInk)
            // On green, as the web draws it; the TV followed gold in #142 before the vocabulary was settled.
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.brhOk, in: Capsule())
            .fixedSize()
            .accessibilityLabel("Upgrading")
    }
}

/// A stage on the way in: its glyph, and a thin line that fills as it's measured or sweeps while it's moving.
struct ArrivalFoot: View {

    let arrival: CardStatus.Arrival

    var body: some View {
        HStack(spacing: 8) {
            if let glyph { Image(systemName: glyph).font(UpgradingPill.font).foregroundStyle(tint) }
            Track(arrival: arrival, tint: tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(arrival.words)
    }

    private var glyph: String? { Self.glyph(arrival.state) }
    private var tint: Color { Self.tint(arrival.state) }

    static func glyph(_ state: CardStatus.Arrival.State) -> String? {
        switch state {
        case .waiting: "clock"
        case .paused: "pause.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .active: nil
        }
    }

    static func tint(_ state: CardStatus.Arrival.State) -> Color {
        switch state {
        case .active: .brhGold
        case .waiting, .paused: .secondary
        case .failed: .brhErr
        }
    }
}

struct Track: View {

    let arrival: CardStatus.Arrival
    let tint: Color
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @State
    private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                if let value = arrival.value {
                    Capsule().fill(tint).frame(width: geometry.size.width * min(max(value, 0), 1))
                } else if arrival.indeterminate {
                    // A short segment going left to right and starting again from the left, the kit's 1.6 s
                    // (Capping, #142); still, under Reduce Motion.
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * 0.3)
                        .offset(x: reduceMotion ? 0 : (sweep ? geometry.size.width : -geometry.size.width * 0.3))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: false), value: sweep)
                        .onAppear { sweep = true }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}

/// The detail page's line under the facts (#125): the pill with its sentence, or the stage in words over its line.
struct DetailStatus: View {

    let status: CardStatus

    var body: some View {
        switch status {
        case .upgrading:
            HStack(spacing: 16) {
                UpgradingPill()
                Text("Looking for a better copy").font(.callout).foregroundStyle(.secondary)
            }
        case let .arriving(arrival):
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(arrival.words)
                } icon: {
                    if let glyph = ArrivalFoot.glyph(arrival.state) { Image(systemName: glyph) }
                }
                .font(.callout)
                .foregroundStyle(arrival.state == .failed ? AnyShapeStyle(Color.brhErr) : AnyShapeStyle(.secondary))
                Track(arrival: arrival, tint: ArrivalFoot.tint(arrival.state)).frame(width: 480)
            }
        }
    }
}
