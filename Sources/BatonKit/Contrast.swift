import Foundation

/// WCAG 2 contrast between `#RRGGBB` colours. Text below 18 pt (14 pt bold) needs 4.5:1 against what is behind it.
public enum Contrast {
    public static let minimum = 4.5

    /// From 1 (the same colour) to 21 (black on white).
    public static func ratio(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Relative luminance of an sRGB colour, from 0 (black) to 1 (white).
    static func luminance(_ hex: String) -> Double {
        let (r, g, b) = components(hex)
        let linear = { (value: Double) -> Double in value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// `hex` darkened just enough for white text on it to reach `minimum`, or `hex` itself when it does already: a
    /// badge colour chosen from an earlier, lighter palette.
    public static func behindWhiteText(_ hex: String) -> String {
        let (r, g, b) = components(hex)
        var factor = 1.0
        var color = hex.uppercased()
        while ratio(color, "#FFFFFF") < minimum, factor > 0 {
            factor -= 0.01
            color = String(format: "#%02X%02X%02X", Int((r * factor * 255).rounded()), Int((g * factor * 255).rounded()), Int((b * factor * 255).rounded()))
        }
        return color
    }

    /// Red, green and blue from 0 to 1; grey for malformed input, as `NSColor(hex:)` reads it.
    static func components(_ hex: String) -> (Double, Double, Double) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

/// Small text the app draws in its own colours, because the system's are too faint for 4.5:1 in the light appearance:
/// secondary text (the system's is black at 50%, about 3.9:1 on a list row) and warnings (system orange is about 2:1).
/// Each colour reaches 4.5:1 on every background of its appearance in `backgrounds`.
public enum TextColors {
    public static let secondary = (light: "#616161", dark: "#B0B0B0")
    public static let warning = (light: "#A64B00", dark: "#FF9230")

    /// What the text sits on. Light, as macOS 27 draws Baton (measured in the README pictures): sheet, window title
    /// bar, list row, window, the second shade of a list and the limit banner; then the window of macOS 14 and 15.
    /// Dark: the window and a range of lighter rows and panels.
    public static let backgrounds = (
        light: ["#FFFFFF", "#FBFBFB", "#F8F8F8", "#F6F6F6", "#F4F5F5", "#F7E9DD", "#ECECEC"],
        dark: ["#1E1E1E", "#282828", "#323232", "#3C3C3C"]
    )

    /// A selected list row as macOS draws it with the default blue accent (measured): the accent colour while the list
    /// has focus, grey while it hasn't. `secondary` is 1.15:1 and 2.89:1 on the blue, and 4.35:1 on the dark grey.
    public static let selectedRows = (light: ["#0064E1", "#DCDCDC"], dark: ["#0059D1", "#464646"])
    /// What the system draws a selected row's title in on each of `selectedRows`: white on the blue, and black or
    /// white at 85% on the grey.
    public static let selectedRowText = (light: ["#FFFFFF", "#222222"], dark: ["#FFFFFF", "#E3E3E3"])

    /// Secondary text in a list row, such as the details line and time in the Continue sheet: `secondary` on an
    /// unselected row; `nil` on a selected one, for the system's colour of the row's title (`selectedRowText`), which
    /// follows the selection as it turns blue and back.
    public static func rowDetail(isSelected: Bool) -> (light: String, dark: String)? { isSelected ? nil : secondary }
}
