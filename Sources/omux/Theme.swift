import AppKit
import SwiftTerm
import SwiftUI

/// The status colors every indicator uses: sidebar dots, badges, cards, usage bars and the
/// transcript page share these, so a state looks the same wherever it shows.
enum Palette {
    /// An agent at work, and running tool calls.
    static let working = Color(red: 0.231, green: 0.510, blue: 0.965)
    /// Waiting on you: permissions, questions, attention.
    static let needs = Color(red: 0.961, green: 0.620, blue: 0.043)
    /// Finished, passed, added lines.
    static let done = Color(red: 0.133, green: 0.773, blue: 0.369)
    /// Failed, removed lines, limits nearly spent.
    static let error = Color(red: 0.937, green: 0.267, blue: 0.267)
    /// Subagents and other secondary actors.
    static let agent = Color(red: 0.655, green: 0.545, blue: 0.980)
    /// A usage bar with room left: quiet, since nothing needs attention.
    static let quiet = Color.primary.opacity(0.35)
}

enum Theme: String, CaseIterable, Identifiable {
    case black, dark, graphite, midnight, dracula, nord, oneDark, gruvbox, solarizedDark, catppuccin, tokyoNight, monokai, rosePine, everforest,
         light, solarizedLight, catppuccinLatte, githubLight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneDark: return "One Dark"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .catppuccin: return "Catppuccin Mocha"
        case .catppuccinLatte: return "Catppuccin Latte"
        case .tokyoNight: return "Tokyo Night"
        case .rosePine: return "Rosé Pine"
        case .githubLight: return "GitHub Light"
        default: return rawValue.capitalized
        }
    }

    static var darkThemes: [Theme] { allCases.filter { !$0.isLight } }
    static var lightThemes: [Theme] { allCases.filter(\.isLight) }

    static var current: Theme {
        Theme(rawValue: UserDefaults.standard.string(forKey: Prefs.theme) ?? "") ?? .dark
    }

    var isLight: Bool { [.light, .solarizedLight, .catppuccinLatte, .githubLight].contains(self) }
    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// background, chrome (sidebar/header), foreground
    private var colors: (bg: UInt32, chrome: UInt32, fg: UInt32) {
        switch self {
        case .black: return (0x000000, 0x0F0F0F, 0xE6E6E6)
        case .dark: return (0x1C1C1F, 0x252529, 0xE6E6E6)
        case .graphite: return (0x2B2B2B, 0x363636, 0xE6E6E6)
        case .midnight: return (0x0D1117, 0x161B22, 0xC9D1D9)
        case .dracula: return (0x282A36, 0x21222C, 0xF8F8F2)
        case .nord: return (0x2E3440, 0x3B4252, 0xD8DEE9)
        case .oneDark: return (0x282C34, 0x21252B, 0xABB2BF)
        case .gruvbox: return (0x282828, 0x1D2021, 0xEBDBB2)
        case .solarizedDark: return (0x002B36, 0x073642, 0x839496)
        case .catppuccin: return (0x1E1E2E, 0x181825, 0xCDD6F4)
        case .tokyoNight: return (0x1A1B26, 0x16161E, 0xC0CAF5)
        case .monokai: return (0x272822, 0x1E1F1C, 0xF8F8F2)
        case .rosePine: return (0x191724, 0x1F1D2E, 0xE0DEF4)
        case .everforest: return (0x2D353B, 0x232A2E, 0xD3C6AA)
        case .light: return (0xFBFBFB, 0xEFEFF1, 0x1F1F1F)
        case .solarizedLight: return (0xFDF6E3, 0xEEE8D5, 0x657B83)
        case .catppuccinLatte: return (0xEFF1F5, 0xE6E9EF, 0x4C4F69)
        case .githubLight: return (0xFFFFFF, 0xF6F8FA, 0x1F2328)
        }
    }

    /// The theme's own accent: its blue, the colour most themes use for links and selection.
    var accent: NSColor { NSColor(hex: paletteHex[12]) }

    /// The six colours a swatch shows: red, green, yellow, blue, magenta, cyan.
    var swatch: [NSColor] { (1...6).map { NSColor(hex: paletteHex[$0]) } }

    var background: NSColor { NSColor(hex: colors.bg) }
    var chrome: NSColor { NSColor(hex: colors.chrome) }
    var foreground: NSColor { NSColor(hex: colors.fg) }

    /// 16 ANSI colours (normal 0-7, bright 8-15).
    var palette: [SwiftTerm.Color] {
        paletteHex.map { v in
            SwiftTerm.Color(red: UInt16((v >> 16) & 0xFF) * 257,
                            green: UInt16((v >> 8) & 0xFF) * 257,
                            blue: UInt16(v & 0xFF) * 257)
        }
    }

    private var paletteHex: [UInt32] {
        let hex: [UInt32]
        switch self {
        case .catppuccin:
            hex = [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                   0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8]
        case .catppuccinLatte:
            hex = [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
                   0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC]
        case .tokyoNight:
            hex = [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                   0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5]
        case .monokai:
            hex = [0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
                   0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5]
        case .rosePine:
            hex = [0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
                   0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4]
        case .everforest:
            hex = [0x4B565C, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
                   0x5C6A72, 0xE67E80, 0xA7C080, 0xDBBC7F, 0x7FBBB3, 0xD699B6, 0x83C092, 0x9DA9A0]
        case .githubLight:
            hex = [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                   0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F]
        case .midnight:
            hex = [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
                   0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC]
        case .dracula:
            hex = [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                   0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]
        case .nord:
            hex = [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                   0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]
        case .oneDark:
            hex = [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                   0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF]
        case .gruvbox:
            hex = [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                   0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]
        case .solarizedDark, .solarizedLight:
            hex = [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                   0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]
        case .light:
            hex = [0x000000, 0xC91B00, 0x00A600, 0x9A7B00, 0x0225C7, 0xCA30C7, 0x00A2B2, 0xBFBFBF,
                   0x686868, 0xFF6E67, 0x2EB84A, 0xC7A500, 0x6871FF, 0xFF77FF, 0x1BA8B5, 0xFFFFFF]
        case .black, .dark, .graphite:
            hex = [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                   0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF]
        }
        return hex
    }
}

extension SwiftUI.Color {
    /// The accent chosen in Settings. Not `accentColor`, which stays the system's whatever the
    /// window's tint is, so a Neutral or fixed accent never reached the views that used it.
    static var accent: SwiftUI.Color { SwiftUI.Color(nsColor: Appearance.accent) }
}

/// The accent colour and the transcript's typography and layout, from Settings.
enum Appearance {
    /// Accent choices: the system's, the theme's blue, a fixed colour, or none: Neutral greys
    /// everything but the sidebar, whose selection keeps the system's colour.
    static let accents: [(id: String, label: String)] = [("system", "System"), ("neutral", "Neutral"), ("theme", "Theme"), ("blue", "Blue"), ("purple", "Purple"), ("pink", "Pink"),
                                                        ("red", "Red"), ("orange", "Orange"), ("yellow", "Yellow"), ("green", "Green"), ("graphite", "Graphite")]

    static func accent(_ choice: String, theme: Theme) -> NSColor {
        switch choice {
        case "theme": return theme.accent
        case "blue": return NSColor(hex: 0x2F6FED)
        case "purple": return NSColor(hex: 0x8E5CF6)
        case "pink": return NSColor(hex: 0xEC4899)
        case "red": return NSColor(hex: 0xEF4444)
        case "orange": return NSColor(hex: 0xF97316)
        case "yellow": return NSColor(hex: 0xD9A50B)
        case "green": return NSColor(hex: 0x22A55B)
        case "graphite": return NSColor(hex: 0x8E8E93)
        case "neutral": return NSColor(hex: 0x808086)
        default: return .controlAccentColor
        }
    }

    static var accent: NSColor { accent(UserDefaults.standard.string(forKey: Prefs.accent) ?? "system", theme: Theme.current) }

    static let transcriptSizes = 11.0 ... 18.0
    static let transcriptFonts: [(id: String, label: String)] = [("", "System"), ("serif", "Serif"), ("rounded", "Rounded"), ("mono", "Terminal font")]
    static let widths: [(id: String, label: String)] = [("full", "Full width"), ("wide", "Wide"), ("narrow", "Narrow")]
    static let densities: [(id: String, label: String)] = [("comfortable", "Comfortable"), ("compact", "Compact")]
    static let bubbles: [(id: String, label: String)] = [("tinted", "Tinted"), ("outline", "Outline"), ("plain", "Plain")]
}

/// What the transcript page is told about how to look, beyond the theme's colours.
struct TranscriptStyle: Equatable {
    var accent = "system"
    var font = ""
    var size = 13.0
    var width = "full"
    var density = "comfortable"
    var bubbles = "tinted"
    var timestamps = true

    static var current: TranscriptStyle {
        let d = UserDefaults.standard
        return TranscriptStyle(accent: d.string(forKey: Prefs.accent) ?? "system", font: d.string(forKey: Prefs.transcriptFont) ?? "",
                               size: d.double(forKey: Prefs.transcriptSize) > 0 ? d.double(forKey: Prefs.transcriptSize) : 13,
                               width: d.string(forKey: Prefs.transcriptWidth) ?? "full", density: d.string(forKey: Prefs.transcriptDensity) ?? "comfortable",
                               bubbles: d.string(forKey: Prefs.transcriptBubbles) ?? "tinted",
                               timestamps: d.object(forKey: Prefs.transcriptTimestamps) as? Bool ?? true)
    }

    /// The CSS font stack for the body text.
    var fontStack: String {
        switch font {
        case "serif": return "'New York', 'Iowan Old Style', Georgia, serif"
        case "rounded": return "'SF Pro Rounded', -apple-system, system-ui, sans-serif"
        case "mono": return "'\(Fonts.terminal().familyName ?? "Menlo")', ui-monospace, Menlo, monospace"
        case "": return "-apple-system, 'SF Pro Text', system-ui, sans-serif"
        default: return "'\(font)', -apple-system, system-ui, sans-serif"
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

enum Fonts {
    /// Installed fixed-pitch families, for the Settings picker.
    static let monospaceFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
        .sorted()

    static let sizes = 9.0 ... 24.0
    static let defaultSize = 13.0

    static var size: Double {
        let stored = UserDefaults.standard.double(forKey: Prefs.fontSize)
        return stored > 0 ? stored : defaultSize
    }

    /// Steps the terminal font size within `sizes`; nil goes back to the default.
    static func adjustSize(by step: Double?) {
        let size = step.map { min(max(Self.size + $0, sizes.lowerBound), sizes.upperBound) } ?? defaultSize
        UserDefaults.standard.set(size, forKey: Prefs.fontSize)
    }

    /// Whether a key press is ⌘= or, on layouts where = takes Shift, ⇧⌘=. The Bigger menu
    /// item only matches "+", which needs Shift on a US keyboard, and on Turkish Q it's
    /// ⇧⌘4, which macOS takes for screenshots.
    static func isBiggerKey(_ characters: String?, _ flags: NSEvent.ModifierFlags) -> Bool {
        characters == "=" && flags.intersection([.command, .control, .option]) == .command
    }

    /// Terminal font from Settings; empty family means the system monospaced font.
    static func terminal() -> NSFont {
        let family = UserDefaults.standard.string(forKey: Prefs.fontFamily) ?? ""
        let size = Self.size
        return (family.isEmpty ? nil : NSFont(name: family, size: size))
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
