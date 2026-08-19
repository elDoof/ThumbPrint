import AppKit
import SwiftUI

/// Shared visual vocabulary for the four screens.
///
/// Every screen is one page of a wizard, so they have to feel like the same
/// object at different moments — same page padding, same card treatment, same
/// section labels. Keeping those decisions here is what stops the screens from
/// drifting apart the next time one of them is edited.
enum Metrics {
    static let windowMinWidth: CGFloat = 580
    static let windowMinHeight: CGFloat = 580

    static let pagePadding: CGFloat = 26
    static let sectionSpacing: CGFloat = 20

    static let cardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 12

    /// Concentric radius: a shape inset by `cardPadding` inside a `cardRadius`
    /// card needs `cardRadius - cardPadding` to stay optically parallel with it.
    /// Clamped at 4 so deep insets don't produce a visually square inner edge.
    static let innerRadius: CGFloat = max(4, cardRadius - cardPadding)

    /// Pointer targets stay at or above this. Drive rows exceed it comfortably
    /// once they carry a capacity bar; the mode cards are sized to match.
    static let minHitHeight: CGFloat = 44
}

// MARK: - Surfaces

/// A raised surface: hairline border for separation, two shallow shadows for
/// depth. Two shadows rather than one because a single large-radius shadow
/// reads as a blur, while a tight shadow plus a soft one reads as a card
/// sitting just above the page.
private struct CardSurface: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

extension View {
    func card(
        padding: CGFloat = Metrics.cardPadding,
        radius: CGFloat = Metrics.cardRadius
    ) -> some View {
        modifier(CardSurface(padding: padding, radius: radius))
    }

    /// A card that supplies its own internal padding — lists of rows, where the
    /// rows need to bleed to the card's edges so their hover fill does too.
    func cardEdgeToEdge(radius: CGFloat = Metrics.cardRadius) -> some View {
        modifier(CardSurface(padding: 0, radius: radius))
    }

    /// Standard page chrome. Every screen is the same size so the window never
    /// resizes as the job moves between phases.
    func pageLayout() -> some View {
        self
            .padding(Metrics.pagePadding)
            .frame(
                minWidth: Metrics.windowMinWidth,
                minHeight: Metrics.windowMinHeight,
                alignment: .topLeading
            )
    }
}

// MARK: - Type

/// Small uppercase label that introduces a group. Tracked out slightly because
/// uppercase text at caption size sets too tight by default.
struct SectionLabel: View {
    let text: String
    var systemImage: String?

    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(text.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.7)
        }
        .foregroundStyle(.secondary)
    }
}

/// Page title plus one line of orientation. Consistent across all four screens.
struct PageHeader: View {
    let title: String
    let subtitle: String
    var systemImage: String?
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 38)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

/// The app's own icon, read from the running bundle rather than copied into an
/// asset catalogue — so it can never drift out of sync with `ThumbPrint.icns`,
/// and replacing the icon needs no code change.
///
/// Deliberately only on the start screen. The other pages lead with SF Symbols
/// that carry state — progress, success, failure — which a fixed logo can't.
struct AppIconBadge: View {
    var size: CGFloat = 60

    var body: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                // No running NSApplication (SwiftUI previews), so fall back to
                // a symbol rather than collapsing the layout to nothing.
                Image(systemName: "externaldrive.badge.timemachine")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        // The icon already carries its own rounded-square silhouette, so it
        // needs lift, not a container. One soft shadow, offset down, is enough
        // to seat it on the page without competing with the cards below.
        .shadow(color: .black.opacity(0.22), radius: 7, y: 3)
        // The title beside it says the same thing, so this is decorative.
        .accessibilityHidden(true)
    }
}

// MARK: - Capacity

/// How full a drive is. Reads at a glance in the picker, where the useful
/// question is "will the thing I'm copying actually fit on that one".
struct CapacityBar: View {
    let used: Int64
    let total: Int64
    var tint: Color = .accentColor

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.09))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.7), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // A drive with a few megabytes on it should still show a
                    // sliver rather than nothing, so the bar never reads as
                    // "unknown" when it means "nearly empty".
                    .frame(width: fraction > 0 ? max(4, geo.size.width * fraction) : 0)
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.28), value: fraction)
    }
}

// MARK: - Stats

/// One number in a row of numbers. Values are monospaced-digit so a changing
/// count doesn't shove its neighbours around.
struct StatTile: View {
    let value: String
    let title: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Row of `StatTile`s on a single card, split by hairlines.
struct StatRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .cardEdgeToEdge()
    }
}

/// The divider used between stat tiles — short, so it separates without
/// cutting the card in half.
struct StatDivider: View {
    var body: some View {
        Divider().frame(height: 34)
    }
}

// MARK: - Notices

/// Coloured advisory block. One shape for blockers, warnings, and successes so
/// they read as the same category of message at different severities.
struct NoticeBox: View {
    enum Kind {
        case success, warning, blocker, info

        var tint: Color {
            switch self {
            case .success: return .green
            case .warning: return .orange
            case .blocker: return .red
            case .info: return .accentColor
            }
        }

        var symbol: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .blocker: return "xmark.octagon.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    let kind: Kind
    let text: String
    var isSelectable = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
                .font(.callout)
                // Optical alignment: the glyph's mass sits slightly below its
                // box, so nudge it down to line up with the first text baseline.
                .offset(y: 1)

            Group {
                if isSelectable {
                    Text(text).textSelection(.enabled)
                } else {
                    Text(text)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(kind.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Interaction

/// Tactile press for custom (non-`Button`-styled) rows and cards. Small enough
/// to feel like a physical press rather than an animation.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Disk image rows

/// A disk image sitting in the same list as the drives, so "save to a file" reads
/// as one more place to copy to rather than a separate mode.
///
/// Deliberately shaped like `DriveRow` — same icon column, same two lines of
/// text, same selected/hover treatment — because to everything downstream a
/// mounted image genuinely is just another volume, and the picker shouldn't
/// suggest otherwise.
struct ImageFileRow: View {
    let title: String
    let subtitle: String
    var systemImage: String = "externaldrive.badge.timemachine"
    var isSelected: Bool = false
    var isPlaceholder: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : systemImage)
                    .font(.system(size: 21))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(isPlaceholder ? .regular : .medium))
                        .foregroundStyle(isPlaceholder ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if !isSelected {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(minHeight: Metrics.minHitHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .background(rowBackground)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.13)
        } else if isHovering {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }
}
