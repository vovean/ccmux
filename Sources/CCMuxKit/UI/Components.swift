import SwiftUI

public struct RedDot: View {
    var size: CGFloat = 8

    public init(size: CGFloat = 8) { self.size = size }

    public var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            .accessibilityLabel("Needs attention")
    }
}

struct UsageBar: View {
    let window: UsageWindow
    let threshold: Double

    private var tint: Color {
        if window.headroom <= threshold { return .red }
        // The amber band sits above the red one by construction; a fixed 20% would go
        // behind red as soon as the threshold was raised past it.
        if window.headroom <= threshold + PollPolicy.escalationMarginPercent { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(String(format: "%.0f%% used", window.percent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
                if let resetsAt = window.resetsAt {
                    Text("· \(Format.countdown(to: resetsAt)) · \(Format.clock(resetsAt))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geometry.size.width
                                          * min(1, max(0, window.percent / 100))))
                }
            }
            .frame(height: 5)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
    }
}

struct EmptyHint: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }
}
