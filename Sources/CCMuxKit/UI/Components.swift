import CCMuxCore
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
    /// Replaces the reset countdown, together with the tooltip that explains it. The
    /// summary pools several accounts whose resets fall at different times, so printing
    /// one of them in the usual place would read as the moment this bar empties — which is
    /// not a thing that happens. One optional rather than two, so a note without its
    /// explanation cannot be expressed.
    var reset: (note: String, help: String)?

    /// Extracted from the body so the invariant is testable without rendering: the text
    /// has to be a function of *both* the window and the instant, because a window that
    /// never changes is precisely the case that used to go stale.
    static func resetText(_ window: UsageWindow, now: Date) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }
        // Both halves from the same instant. `Format.clock` date-qualifies anything not
        // happening today, so reading the clock separately means that just after midnight
        // the countdown can still be measuring from yesterday while the time beside it has
        // already moved on, and a reset at 23:59 renders as a dated tomorrow.
        return "\(Format.countdown(to: resetsAt, from: now)) · "
            + Format.clock(resetsAt, now: now)
    }

    private var tint: Color {
        if window.headroom <= threshold { return .red }
        // The amber band sits above the red one by construction; a fixed 20% would go
        // behind red as soon as the threshold was raised past it.
        if window.headroom <= threshold + PollPolicy.escalationMarginPercent { return .orange }
        return .accentColor
    }

    /// Ticks itself rather than being handed the time.
    ///
    /// A countdown is the only thing on this bar that changes on its own, and an account
    /// pinned at 100% hands back a byte-identical window on every poll — so with time read
    /// ambiently SwiftUI has nothing to diff, skips the body, and the countdown freezes at
    /// whatever it last drew. Owning the tick here keeps the redraw to the one bar that
    /// needs it: a published clock on the engine would republish the whole object and
    /// redraw every window, which is the discipline `Engine.reload` exists to keep.
    ///
    /// Scoped to the case that actually draws a countdown. With a `reset` override the
    /// text is computed by the caller, and with no `resetsAt` there is nothing to count
    /// down to; ticking either would be redrawing something that cannot change.
    @ViewBuilder
    var body: some View {
        if reset == nil, window.resetsAt != nil {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        } else {
            content(now: .now)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(String(format: "%.0f%% used", window.percent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
                if let reset {
                    Text("· \(reset.note)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help(reset.help)
                } else if let text = Self.resetText(window, now: now) {
                    Text("· \(text)")
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
