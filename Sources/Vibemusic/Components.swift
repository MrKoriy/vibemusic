import SwiftUI
import AppKit
import VibemusicCore

struct AmbientBackground: View {
    var tint: Color

    @State private var hue: Double = 0.72

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: Self.points,
            colors: Self.gridColors(hue: hue, t: 420.0)
        )
        .animation(.easeInOut(duration: 1.2), value: hue)
        .ignoresSafeArea()
        .onChange(of: tint) {
            var delta = Self.hue(of: tint) - hue
            delta -= delta.rounded()
            hue += delta
        }
    }

    static let points: [SIMD2<Float>] = [
        SIMD2(0.0, 0.0), SIMD2(0.5, 0.0), SIMD2(1.0, 0.0),
        SIMD2(0.0, 0.5), SIMD2(0.5, 0.5), SIMD2(1.0, 0.5),
        SIMD2(0.0, 1.0), SIMD2(0.5, 1.0), SIMD2(1.0, 1.0),
    ]

    static func hue(of color: Color) -> Double {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return 0.72 }
        return Double(rgb.hueComponent)
    }

    static func gridColors(hue: Double, t: Double) -> [Color] {
        (0..<3).flatMap { row in
            (0..<3).map { col in
                cell(row: row, col: col, hue: hue, t: t)
            }
        }
    }

    static func cell(row: Int, col: Int, hue: Double, t: Double) -> Color {
        let x = Double(col) / 2.0
        let y = Double(row) / 2.0
        let wobble = sin(t * 0.16 + Double(row * 3 + col) * 0.8)
        let hueShift = (x - 0.5) * 0.24 - (y - 0.5) * 0.10 + wobble * 0.06
        let saturation = 0.60 + 0.20 * (0.5 + 0.5 * cos(t * 0.11 + Double(col) * 1.4))
        let brightness = 0.50 + 0.26 * (0.5 + 0.5 * sin(t * 0.14 + Double(row) * 1.2 + Double(col) * 0.6))
        var h = hue + hueShift
        h = h.truncatingRemainder(dividingBy: 1.0)
        if h < 0 { h += 1 }
        return Color(
            hue: h,
            saturation: min(max(saturation, 0.50), 0.88),
            brightness: min(max(brightness, 0.42), 0.82)
        )
    }
}

struct CategoryTile: View {
    let category: MusicCategory
    let tint: Color
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(isActive ? 0.24 : 0.12))
                    Circle()
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                    Image(systemName: Theme.symbol(for: category.id))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: isHovered)
                }
                .frame(width: 46, height: 46)
                Text(category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(category.tracks.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 26, style: .continuous),
            tint: isActive ? tint.opacity(0.5) : nil,
            interactive: true
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(tint.opacity(isActive ? 0.95 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        )
        .scaleEffect(isHovered ? 1.045 : 1)
        .offset(y: isHovered ? -3 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct DurationChip: View {
    let label: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Capsule(), tint: isSelected ? tint.opacity(0.5) : nil)
        .overlay(
            Capsule().strokeBorder(.white.opacity(isSelected ? 0.5 : 0.15), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .scaleEffect(isHovered && !isSelected ? 1.05 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct TimerRing: View {
    let remaining: TimeInterval
    let progress: Double
    let tint: Color
    let phaseLabel: String
    let subLabel: String
    let cyclesLabel: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 22)
                .padding(15)
            Circle()
                .trim(from: 0, to: max(0.0015, progress))
                .stroke(
                    AngularGradient(
                        colors: [.white.opacity(0.98), tint, .white.opacity(0.85)],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 22, lineCap: .round)
                )
                .padding(15)
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.65), radius: 20)
                .animation(.linear(duration: 1), value: progress)

            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 1)
                .padding(9)

            VStack(spacing: 7) {
                Text(Theme.timeString(remaining))
                    .font(.system(size: 60, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                Text(phaseLabel)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(.white)
                    .textCase(.uppercase)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(tint.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                Text(subLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                if let cyclesLabel {
                    Text(cyclesLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(34)
        }
        .frame(width: 320, height: 320)
        .liquidGlass(in: Circle(), tint: tint.opacity(0.22))
    }
}

struct PlayerButton: View {
    let systemName: String
    let size: CGFloat
    var tint: Color? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle(), tint: tint, interactive: true)
        .scaleEffect(isHovered ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
