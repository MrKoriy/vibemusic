import SwiftUI
import AppKit
import VibemusicCore

/// Спокойный амбиент: глубокая тёмная база + два медленно дышащих пятна
/// цвета категории. Никаких кричащих сеток и насыщенных градиентов —
/// фон задаёт настроение, а не спорит с контентом.
struct AmbientBackground: View {
    var tint: Color

    private let driftPeriod: Double = 26

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { (timeline: TimelineViewDefaultContext) in
            ambientCanvas(date: timeline.date)
        }
        .ignoresSafeArea()
        .drawingGroup()
    }

    private func ambientCanvas(date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: driftPeriod)
        let phase = (t / driftPeriod) * 2 * .pi
        return Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(white: 0.045))
            )

            func blob(_ gradient: Gradient, radius: CGFloat, center: CGPoint) {
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(
                    Path(rect),
                    with: .radialGradient(
                        gradient,
                        center: CGPoint(x: rect.midX, y: rect.midY),
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }

            let w = size.width
            let h = size.height
            let dx = sin(phase) * w * 0.05
            let dy = cos(phase * 0.7) * h * 0.04

            blob(Gradient(colors: [tint.opacity(0.17), tint.opacity(0)]),
                 radius: w * 0.45,
                 center: CGPoint(x: w * 0.24 + dx, y: h * 0.20 + dy))
            blob(Gradient(colors: [Theme.companion(for: tint).opacity(0.10), .clear]),
                 radius: w * 0.38,
                 center: CGPoint(x: w * 0.82 - dy, y: h * 0.78 - dx))
            blob(Gradient(colors: [Color.white.opacity(0.035), .clear]),
                 radius: w * 0.5,
                 center: CGPoint(x: w * 0.5, y: -h * 0.15))

            // Виньетка: края чуть темнее — фокус к центру.
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [.clear, Color.black.opacity(0.44)]),
                    center: CGPoint(x: w / 2, y: h / 2),
                    startRadius: min(w, h) * 0.38,
                    endRadius: max(w, h) * 0.78
                )
            )
        }
    }
}

/// Сегмент-переключатель (Отсчёт / Помодоро): капсула-контейнер,
/// выбранный сегмент залит цветом сессии.
struct ModeSegmented: View {
    let options: [(label: String, value: TimerEngine.Mode)]
    let selection: TimerEngine.Mode
    let tint: Color
    let onSelect: (TimerEngine.Mode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.55)))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(isSelected ? tint.opacity(0.42) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
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
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(isActive ? 0.75 : 0.50), tint.opacity(isActive ? 0.35 : 0.16)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    Circle()
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    Image(systemName: Theme.symbol(for: category.id))
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: isHovered)
                }
                .frame(width: 44, height: 44)
                .shadow(color: tint.opacity(isActive ? 0.55 : 0.25), radius: isActive ? 12 : 6, y: 2)

                VStack(spacing: 3) {
                    Text(category.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("\(category.tracks.count) \(Theme.tracksWord(category.tracks.count))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous),
            tint: isActive ? tint.opacity(0.30) : nil,
            interactive: true
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint.opacity(isActive ? 0.85 : 0), lineWidth: 1.25)
                .allowsHitTesting(false)
        )
        .shadow(color: tint.opacity(isActive ? 0.35 : 0), radius: 16, y: 4)
        .scaleEffect(isHovered && !isActive ? 1.03 : 1)
        .offset(y: isHovered && !isActive ? -2 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isActive)
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
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.62)))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Capsule(), tint: isSelected ? tint.opacity(0.38) : nil)
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(isSelected ? 0.35 : 0.10), lineWidth: 0.75)
                .allowsHitTesting(false)
        )
        .scaleEffect(isHovered && !isSelected ? 1.06 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Кольцо таймера: тонкий прогресс, точка на конце дуги, спокойная типографика.
/// Дуга стартует с 12 часов и идёт по часовой; головка дуги — точка с хвостом-кометой.
struct TimerRing: View {
    let remaining: TimeInterval
    let progress: Double
    let tint: Color
    let phaseLabel: String
    let subLabel: String
    let cyclesLabel: String?
    /// true, пока звук реально играет — кольцо мягко «дышит».
    var isRunning: Bool = false

    @State private var breath = false
    @State private var glowPulse = false
    @State private var flashOpacity: Double = 0

    private let ringSize: CGFloat = 300
    private let lineWidth: CGFloat = 10

    private var clampedProgress: Double {
        max(0, min(1, progress))
    }

    private var headAngle: Angle {
        .degrees(-90 + 360 * clampedProgress)
    }

    private var headPosition: CGPoint {
        let radius = (ringSize - lineWidth) / 2 - 6
        let angle = headAngle.radians
        return CGPoint(
            x: ringSize / 2 + radius * cos(angle),
            y: ringSize / 2 + radius * sin(angle)
        )
    }

    var body: some View {
        ZStack {
            // Дорожка.
            Circle()
                .stroke(.white.opacity(0.07), lineWidth: lineWidth)

            // Хронограф-риски: медленно ползут, пока идёт отсчёт (1 об/мин).
            RingTicks(isRunning: isRunning)
                .padding(16)

            // Прогресс. Circle().trim стартует с 3 часов — поворот на -90°
            // ставит начало дуги на 12 часов, в тон точке-головке.
            ZStack {
                Circle()
                    .trim(from: 0, to: max(0.002, clampedProgress))
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.55), tint, .white.opacity(0.85)],
                            center: .center, startAngle: .zero, endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .shadow(color: tint.opacity(0.45), radius: 12)

                // Хвост кометы: три затухающих слоя позади головки.
                ZStack {
                    cometSegment(from: clampedProgress - 0.024, to: clampedProgress, opacity: 0.34)
                    cometSegment(from: clampedProgress - 0.052, to: clampedProgress - 0.024, opacity: 0.18)
                    cometSegment(from: clampedProgress - 0.086, to: clampedProgress - 0.052, opacity: 0.08)
                }

                // Вспышка кольца при смене фазы (работа → перерыв → …).
                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .opacity(flashOpacity)
            }
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 1), value: progress)

            if clampedProgress > 0.004 {
                // Головка: светящаяся точка с пульсирующим ореолом.
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.30))
                        .frame(width: 19, height: 19)
                        .scaleEffect(glowPulse ? 1.25 : 0.8)
                        .opacity(glowPulse ? 0.5 : 0.22)
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                        .shadow(color: tint.opacity(0.9), radius: 4)
                }
                .animation(
                    isRunning ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : nil,
                    value: glowPulse
                )
                .position(headPosition)
                .animation(.linear(duration: 1), value: progress)
            }

            VStack(spacing: 8) {
                Text(Theme.timeString(remaining))
                    .font(.system(size: 58, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.30), radius: 8, y: 2)

                HStack(spacing: 6) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                    Text(phaseLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(2.4)
                        .foregroundStyle(.white.opacity(0.82))
                        .textCase(.uppercase)
                }

                Text(subLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)

                if let cyclesLabel {
                    Text(cyclesLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.top, 1)
                }
            }
            .padding(30)
        }
        .frame(width: ringSize, height: ringSize)
        .scaleEffect(breath && isRunning ? 1.012 : 1)
        .animation(.easeInOut(duration: 4.5), value: breath)
        .onAppear {
            breath = true
            glowPulse = true
        }
        .onChange(of: phaseLabel) {
            // Смена фазы: короткая вспышка кольца.
            withTransaction(Transaction(animation: nil)) { flashOpacity = 0.5 }
            withAnimation(.easeOut(duration: 1.1)) { flashOpacity = 0 }
        }
    }

    /// Слой хвоста кометы: участок дуги позади головки с затуханием.
    @ViewBuilder
    private func cometSegment(from: Double, to: Double, opacity: Double) -> some View {
        if to > from, from >= 0 {
            Circle()
                .trim(from: from, to: to)
                .stroke(
                    .white.opacity(opacity),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                )
        }
    }
}

/// Хронограф-риски вокруг кольца: пунктирная окружность, медленно
/// вращающаяся, пока отсчёт идёт (6°/с — полный оборот за минуту).
private struct RingTicks: View {
    var isRunning: Bool

    var body: some View {
        if isRunning {
            TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let rotation = seconds.truncatingRemainder(dividingBy: 60) * 6.0
                ticks(rotation: rotation)
            }
        } else {
            ticks(rotation: 0)
        }
    }

    private func ticks(rotation: Double) -> some View {
        Circle()
            .stroke(
                .white.opacity(0.10),
                style: StrokeStyle(lineWidth: 1, dash: [1.5, 7])
            )
            .rotationEffect(.degrees(rotation))
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
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle(), tint: tint, interactive: true)
        .scaleEffect(isHovered ? 1.05 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Тонкий кастомный слайдер (позиция трека / громкость): капсула-дорожка,
/// заливка до бегунка, маленький светлый бегунок. Нативный macOS Slider
/// не стилизуется и ломает визуальный ритм.
struct GlassSlider: View {
    let value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .white
    var isEnabled: Bool = true
    /// Непрерывное обновление при перетаскивании.
    let onScrub: (Double) -> Void
    /// Фиксация значения (отпускание бегунка).
    var onCommit: ((Double) -> Void)? = nil

    @State private var dragValue: Double?
    @State private var isHovered = false

    private var displayValue: Double {
        min(max(dragValue ?? value, range.lowerBound), range.upperBound)
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (displayValue - range.lowerBound) / span
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let trackHeight: CGFloat = 4
            let thumbRadius: CGFloat = 5

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(height: trackHeight)
                    .frame(maxHeight: .infinity, alignment: .center)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(thumbRadius * 2, geometry.size.width * fraction), height: trackHeight)
                    .frame(maxHeight: .infinity, alignment: .center)

                Circle()
                    .fill(.white)
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .shadow(color: tint.opacity(0.8), radius: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: (geometry.size.width - thumbRadius * 2) * fraction)
                    .opacity(isEnabled ? 1 : 0.4)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
            .gesture(
                isEnabled ? dragGesture(width: geometry.size.width) : nil
            )
            .onHover { isHovered = $0 }
            .frame(height: height)
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Позиция воспроизведения")
        .accessibilityValue("\(Int(displayValue))")
        .accessibilityAdjustableAction { direction in
            let span = range.upperBound - range.lowerBound
            let step = span / 40
            let next: Double
            switch direction {
            case .increment: next = displayValue + step
            case .decrement: next = displayValue - step
            @unknown default: next = displayValue
            }
            let clamped = min(max(next, range.lowerBound), range.upperBound)
            onScrub(clamped)
            onCommit?(clamped)
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let rawFraction = min(max(gesture.location.x / max(width, 1), 0), 1)
                let span = range.upperBound - range.lowerBound
                let next = range.lowerBound + span * rawFraction
                dragValue = next
                onScrub(next)
            }
            .onEnded { _ in
                onCommit?(displayValue)
                dragValue = nil
            }
    }
}
