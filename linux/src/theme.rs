//! The 11 themes, with the exact colors of `Theme.swift`.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Theme {
    pub raw: &'static str,
    pub label: &'static str,
    pub light: bool,
    pub background: u32,
    pub chrome: u32,
    pub foreground: u32,
    /// ANSI 0-7, then bright 8-15.
    pub palette: [u32; 16],
}

const DEFAULT_PALETTE: [u32; 16] = [
    0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5, //
    0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
];
const SOLARIZED: [u32; 16] = [
    0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5, //
    0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
];

#[rustfmt::skip]
pub const THEMES: [Theme; 11] = [
    Theme { raw: "black", label: "Black", light: false, background: 0x000000, chrome: 0x0F0F0F, foreground: 0xE6E6E6, palette: DEFAULT_PALETTE },
    Theme { raw: "dark", label: "Dark", light: false, background: 0x1C1C1F, chrome: 0x252529, foreground: 0xE6E6E6, palette: DEFAULT_PALETTE },
    Theme { raw: "graphite", label: "Graphite", light: false, background: 0x2B2B2B, chrome: 0x363636, foreground: 0xE6E6E6, palette: DEFAULT_PALETTE },
    Theme {
        raw: "midnight", label: "Midnight", light: false, background: 0x0D1117, chrome: 0x161B22, foreground: 0xC9D1D9,
        palette: [
            0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4, //
            0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC,
        ],
    },
    Theme {
        raw: "dracula", label: "Dracula", light: false, background: 0x282A36, chrome: 0x21222C, foreground: 0xF8F8F2,
        palette: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2, //
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        ],
    },
    Theme {
        raw: "nord", label: "Nord", light: false, background: 0x2E3440, chrome: 0x3B4252, foreground: 0xD8DEE9,
        palette: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0, //
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
        ],
    },
    Theme {
        raw: "oneDark", label: "One Dark", light: false, background: 0x282C34, chrome: 0x21252B, foreground: 0xABB2BF,
        palette: [
            0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF, //
            0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
        ],
    },
    Theme {
        raw: "gruvbox", label: "Gruvbox", light: false, background: 0x282828, chrome: 0x1D2021, foreground: 0xEBDBB2,
        palette: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984, //
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
        ],
    },
    Theme { raw: "solarizedDark", label: "Solarized Dark", light: false, background: 0x002B36, chrome: 0x073642, foreground: 0x839496, palette: SOLARIZED },
    Theme {
        raw: "light", label: "Light", light: true, background: 0xFBFBFB, chrome: 0xEFEFF1, foreground: 0x1F1F1F,
        palette: [
            0x000000, 0xC91B00, 0x00A600, 0x9A7B00, 0x0225C7, 0xCA30C7, 0x00A2B2, 0xBFBFBF, //
            0x686868, 0xFF6E67, 0x2EB84A, 0xC7A500, 0x6871FF, 0xFF77FF, 0x1BA8B5, 0xFFFFFF,
        ],
    },
    Theme { raw: "solarizedLight", label: "Solarized Light", light: true, background: 0xFDF6E3, chrome: 0xEEE8D5, foreground: 0x657B83, palette: SOLARIZED },
];

impl Theme {
    pub fn named(raw: &str) -> Theme {
        THEMES
            .iter()
            .copied()
            .find(|t| t.raw == raw)
            .unwrap_or(THEMES[1])
    }
}

pub fn rgba(hex: u32) -> gtk::gdk::RGBA {
    gtk::gdk::RGBA::new(
        ((hex >> 16) & 0xFF) as f32 / 255.0,
        ((hex >> 8) & 0xFF) as f32 / 255.0,
        (hex & 0xFF) as f32 / 255.0,
        1.0,
    )
}

pub fn css_hex(hex: u32) -> String {
    format!("#{hex:06x}")
}

/// System colors for status, PR and tab colors (approximations of Apple's
/// palette, dark then light variant).
pub mod semantic {
    pub const BLUE: (u32, u32) = (0x0A84FF, 0x007AFF);
    pub const ORANGE: (u32, u32) = (0xFF9F0A, 0xFF9500);
    pub const GREEN: (u32, u32) = (0x30D158, 0x34C759);
    pub const RED: (u32, u32) = (0xFF453A, 0xFF3B30);
    pub const PURPLE: (u32, u32) = (0xBF5AF2, 0xAF52DE);
    pub const YELLOW: (u32, u32) = (0xFFD60A, 0xFFCC00);
    pub const MINT: (u32, u32) = (0x63E6E2, 0x00C7BE);
    pub const TEAL: (u32, u32) = (0x40C8E0, 0x30B0C7);
    pub const CYAN: (u32, u32) = (0x64D2FF, 0x32ADE6);
    pub const INDIGO: (u32, u32) = (0x5E5CE6, 0x5856D6);
    pub const PINK: (u32, u32) = (0xFF375F, 0xFF2D55);
    pub const BROWN: (u32, u32) = (0xAC8E68, 0xA2845E);
    pub const GRAY: (u32, u32) = (0x8E8E93, 0x8E8E93);
}
