import SwiftUI

enum Theme {
    static let coral = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let magenta = Color(red: 0.86, green: 0.26, blue: 0.62)
    static let violet = Color(red: 0.52, green: 0.33, blue: 0.98)
    static let recordRed = Color(red: 1.0, green: 0.23, blue: 0.27)
    static let pauseAmber = Color(red: 1.0, green: 0.72, blue: 0.2)

    static let brand = LinearGradient(colors: [coral, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandWide = LinearGradient(colors: [coral, magenta, violet], startPoint: .leading, endPoint: .trailing)
}

extension View {
    /// Liquid Glass on macOS 26, translucent material before that.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    func card(radius: CGFloat = 14) -> some View {
        self.background(.background.secondary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

struct BrandButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 11 : 7)
            .background(Theme.brand, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: Theme.coral.opacity(configuration.isPressed ? 0.15 : 0.35), radius: large ? 12 : 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Round icon button used on the floating bars.
struct HUDButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var size: CGFloat = 32
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .frame(width: size, height: size)
            .background {
                if let tint {
                    Circle().fill(tint.gradient)
                } else {
                    Circle().fill(.primary.opacity(configuration.isPressed ? 0.18 : (hovering ? 0.1 : 0)))
                }
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Segmented-style toggle chip for the capture bar.
struct ChipButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Badge: View {
    var text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

struct SectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A pulsing recording dot.
struct RecordingDot: View {
    var paused: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill((paused ? Theme.pauseAmber : Theme.recordRed).opacity(0.35))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse && !paused ? 1.25 : 0.8)
                .opacity(pulse && !paused ? 0 : 1)
            Circle().fill(paused ? Theme.pauseAmber : Theme.recordRed).frame(width: 10, height: 10)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
