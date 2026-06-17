import SwiftUI

/// BOREAL's visual language — a dark "instrument" aesthetic for a pro RAW/HDR
/// tool: pure black ground, content-first, monospaced technical read-outs, one
/// warm accent. Centralized so every screen reads as one device, not stock SwiftUI.
enum Theme {
    static let bg        = Color.black
    static let surface   = Color(white: 0.11)          // panels
    static let surfaceHi = Color(white: 0.17)          // raised controls
    static let hairline  = Color.white.opacity(0.10)
    static let text      = Color.white
    static let textDim   = Color.white.opacity(0.55)
    static let accent    = Color(red: 1.0, green: 0.74, blue: 0.26)   // warm amber
    static let corner: CGFloat = 16
}

extension Font {
    /// Monospaced technical read-out (EV, sizes, labels) — numbers don't jitter.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// A standard dark panel (rounded surface + hairline).
    func panel(_ padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
    }
}

/// The wordmark — tracked monospace caps, used on the launch/home/idle states.
struct Wordmark: View {
    var size: CGFloat = 22
    var body: some View {
        Text("B O R E A L")
            .font(.mono(size, .heavy))
            .foregroundStyle(Theme.text)
            .tracking(2)
    }
}

/// A full-bleed white pill — the primary call to action (Import).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.text.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.corner))
    }
}

/// A bordered dark pill — secondary actions (Share).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(configuration.isPressed ? Theme.surfaceHi : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
    }
}
