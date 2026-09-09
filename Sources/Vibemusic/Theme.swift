import SwiftUI

enum Theme {
    static func color(for id: String) -> Color {
        switch id {
        case "work": .indigo
        case "lofi": .purple
        case "classical": Color(red: 0.88, green: 0.68, blue: 0.36)
        case "ambient": .teal
        case "alpha": .blue
        case "beta": .orange
        case "gamma": Color(red: 0.66, green: 0.32, blue: 0.96)
        case "binaural": .cyan
        case "meditation": .mint
        case "frequencies": .pink
        case "schumann": .green
        case "manifest": .yellow
        case "sleep": Color(red: 0.38, green: 0.42, blue: 0.92)
        case "morning": Color(red: 1.0, green: 0.72, blue: 0.28)
        default: .indigo
        }
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
}
