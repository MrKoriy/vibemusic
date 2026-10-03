import SwiftUI
import AppKit

/// Дизайн-токены приложения: палитра категорий, типографика, ритм отступов.
enum Theme {
    // MARK: - Палитра

    static func color(for id: String) -> Color {
        switch id {
        case "work": Color(red: 0.56, green: 0.55, blue: 0.98)
        case "lofi": Color(red: 0.72, green: 0.46, blue: 0.98)
        case "classical": Color(red: 0.93, green: 0.72, blue: 0.38)
        case "ambient": Color(red: 0.32, green: 0.77, blue: 0.72)
        case "alpha": Color(red: 0.42, green: 0.60, blue: 0.98)
        case "beta": Color(red: 0.97, green: 0.60, blue: 0.26)
        case "gamma": Color(red: 0.68, green: 0.35, blue: 0.98)
        case "binaural": Color(red: 0.34, green: 0.84, blue: 0.92)
        case "meditation": Color(red: 0.44, green: 0.86, blue: 0.70)
        case "frequencies": Color(red: 0.95, green: 0.50, blue: 0.68)
        case "schumann": Color(red: 0.42, green: 0.78, blue: 0.50)
        case "manifest": Color(red: 0.96, green: 0.78, blue: 0.32)
        case "sleep": Color(red: 0.47, green: 0.51, blue: 0.95)
        case "morning": Color(red: 1.00, green: 0.69, blue: 0.31)
        default: Color(red: 0.56, green: 0.55, blue: 0.98)
        }
    }

    /// Дополнительный цвет фона: соседний оттенок, приглушённый —
    /// для второго пятна амбиента, чтобы фон не был монотонным.
    static func companion(for color: Color) -> Color {
        let base = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(calibratedRed: 0.56, green: 0.55, blue: 0.98, alpha: 1)
        var hue = base.hueComponent + 0.06
        hue -= hue.rounded()
        if hue < 0 { hue += 1 }
        return Color(
            hue: Double(hue),
            saturation: 0.5,
            brightness: 0.52
        )
    }

    static func symbol(for id: String) -> String {
        switch id {
        case "work": "headphones"
        case "lofi": "music.note"
        case "classical": "pianokeys"
        case "ambient": "sparkles"
        case "alpha": "brain"
        case "beta": "bolt"
        case "gamma": "atom"
        case "binaural": "waveform"
        case "meditation": "figure.mind.and.body"
        case "frequencies": "tuningfork"
        case "schumann": "globe"
        case "manifest": "wand.and.stars"
        case "sleep": "moon.zzz"
        case "morning": "sun.max"
        default: "link"
        }
    }

    // MARK: - Форматирование

    static func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static func shortDuration(_ minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) ч" }
        return "\(minutes) м"
    }

    /// «12 треков», «1 трек», «3 трека».
    static func tracksWord(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1, mod100 != 11 { return "трек" }
        if (2...4).contains(mod10), !(12...14).contains(mod100) { return "трека" }
        return "треков"
    }

    // MARK: - NSColor (обложки Now Playing)

    // Native NSColor table for deterministic artwork — avoids NSColor(SwiftUI.Color) bridge
    // which returns nil for semantic colors like .indigo in some contexts.
    static func nsColor(for id: String) -> NSColor {
        switch id {
        case "work": NSColor(calibratedRed: 0.56, green: 0.55, blue: 0.98, alpha: 1)
        case "lofi": NSColor(calibratedRed: 0.72, green: 0.46, blue: 0.98, alpha: 1)
        case "classical": NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.38, alpha: 1)
        case "ambient": NSColor(calibratedRed: 0.32, green: 0.77, blue: 0.72, alpha: 1)
        case "alpha": NSColor(calibratedRed: 0.42, green: 0.60, blue: 0.98, alpha: 1)
        case "beta": NSColor(calibratedRed: 0.97, green: 0.60, blue: 0.26, alpha: 1)
        case "gamma": NSColor(calibratedRed: 0.68, green: 0.35, blue: 0.98, alpha: 1)
        case "binaural": NSColor(calibratedRed: 0.34, green: 0.84, blue: 0.92, alpha: 1)
        case "meditation": NSColor(calibratedRed: 0.44, green: 0.86, blue: 0.70, alpha: 1)
        case "frequencies": NSColor(calibratedRed: 0.95, green: 0.50, blue: 0.68, alpha: 1)
        case "schumann": NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.50, alpha: 1)
        case "manifest": NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.32, alpha: 1)
        case "sleep": NSColor(calibratedRed: 0.47, green: 0.51, blue: 0.95, alpha: 1)
        case "morning": NSColor(calibratedRed: 1.0, green: 0.69, blue: 0.31, alpha: 1)
        default: NSColor(calibratedRed: 0.56, green: 0.55, blue: 0.98, alpha: 1)
        }
    }
}
