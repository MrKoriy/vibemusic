import SwiftUI
import AppKit
import VibemusicCore

struct ContentView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var stats: StatsStore
    @EnvironmentObject var controller: SessionController
    @EnvironmentObject var player: PlayerCore
    @EnvironmentObject var timer: TimerEngine
    @Environment(\.openWindow) private var openWindow

    @State private var isAdding = false
    @State private var spaceMonitor: Any?
    @State private var didShowLoadDiagnostics = false

    private var selectedCategory: MusicCategory? { controller.selectedCategory }
    private var tint: Color {
        selectedCategory.map { Theme.color(for: $0.id) } ?? Theme.color(for: "work")
    }

    private var displayRemaining: TimeInterval {
        switch timer.phase {
        case .idle: return TimeInterval(controller.sessionMinutes) * 60
        default: return timer.remaining
        }
    }

    private var displayProgress: Double {
        switch timer.phase {
        case .idle: return 1
        default: return timer.total > 0 ? timer.remaining / timer.total : 0
        }
    }

    private var phaseLabel: String {
        if controller.isWaitingForStream { return "Подготовка" }
        switch timer.phase {
        case .idle: return "Готов"
        case .work: return controller.timerMode == .pomodoro ? "Фокус" : "Сессия"
        case .breakPhase: return "Перерыв"
        case .finished: return "Готово"
        }
    }

    private var subLabel: String {
        selectedCategory?.title ?? "Выберите режим"
    }

    var body: some View {
        ZStack {
            AmbientBackground(tint: tint)
            ScrollView(showsIndicators: false) {
                // GlassEffectContainer НЕ оборачивает весь скролл: контейнер
                // рассчитан на соседние мелкие формы, а весь контент с LazyVGrid
                // внутри него уходит в бесконечный цикл пересчёта раскладки (98% CPU).
                VStack(spacing: 24) {
                    header
                    timerSection
                    sessionControls
                    durationRow
                    categoriesGrid
                    todayFooter
                    PlayerBar(player: player, controller: controller, volume: volumeBinding)
                }
                .padding(.horizontal, 34)
                .padding(.top, 20)
                .padding(.bottom, 30)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
            if let toast = player.statusText {
                toastView(toast)
            }
        }
        .frame(minWidth: 980, minHeight: 720)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isAdding) {
            AddLinkView()
                .environmentObject(store)
                .frame(minWidth: 480, minHeight: 560)
        }
        .background(hiddenShortcuts)
        .onAppear {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.openMain = { openWindow(id: "main") }
            }
            NowPlayingManager.shared.activate(player: player, controller: controller)
            MenuBarController.shared.install(controller: controller, player: player)
            reportBrokenDataIfNeeded()
            installSpaceMonitor()
        }
        .onDisappear {
            if let monitor = spaceMonitor {
                NSEvent.removeMonitor(monitor)
                spaceMonitor = nil
            }
        }
    }

    // MARK: - Секции

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("VIBEMUSIC")
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(5)
                    .foregroundStyle(.white.opacity(0.95))
                Text("фокус · медитация · сон")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.40))
            }
            Spacer()
            HStack(spacing: 10) {
                Button {
                    controller.shuffle.toggle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(controller.shuffle ? tint : .white.opacity(0.62))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassCircle(diameter: 34)
                .help("Перемешивание треков")
                .accessibilityLabel("Перемешивание треков")
                .accessibilityHint("Включает и выключает случайный порядок воспроизведения")

                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassCircle(diameter: 34)
                .help("Добавить ссылку из YouTube")
                .accessibilityLabel("Добавить ссылку")
                .accessibilityHint("Открывает окно добавления треков из YouTube")
            }
        }
    }

    private var timerSection: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 240))
                .frame(width: 460, height: 460)
                .blur(radius: 42)
                .drawingGroup()
                .allowsHitTesting(false)
            TimerRing(
                remaining: displayRemaining,
                progress: displayProgress,
                tint: tint,
                phaseLabel: phaseLabel,
                subLabel: subLabel,
                cyclesLabel: (controller.timerMode == .pomodoro && timer.completedCycles > 0)
                    ? "циклов завершено: \(timer.completedCycles)" : nil,
                isRunning: player.isPlaying
            )
        }
    }

    private var sessionToggleAccessibilityLabel: String {
        switch timer.phase {
        case .work, .breakPhase:
            return controller.isSessionPaused ? "Продолжить сессию" : "Приостановить сессию"
        default:
            return "Запустить сессию"
        }
    }

    private var sessionControls: some View {
        HStack(spacing: 26) {
            PlayerButton(systemName: "arrow.counterclockwise", size: 46) {
                controller.resetSession()
            }
            .help("Сбросить сессию")
            .accessibilityLabel("Сбросить сессию")
            .accessibilityHint("Останавливает таймер и воспроизведение")

            PlayerButton(
                systemName: sessionToggleIcon,
                size: 70,
                tint: tint.opacity(0.45)
            ) {
                controller.toggleSession()
            }
            .help("Старт / пауза (пробел)")
            .accessibilityLabel(sessionToggleAccessibilityLabel)
            .accessibilityHint("Запускает и ставит на паузу таймер с музыкой; работает и клавиша пробел")

            PlayerButton(systemName: "forward.end.fill", size: 46) {
                controller.skipPhase()
            }
            .help("Следующая фаза")
            .accessibilityLabel("Следующая фаза")
            .accessibilityHint("Переключает таймер на перерыв или следующий цикл")
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: controller.isSessionPaused)
    }

    private var sessionToggleIcon: String {
        let active = timer.phase == .work || timer.phase == .breakPhase || controller.isWaitingForStream
        let frozen = controller.isSessionPaused || timer.isFrozen
        return active && !frozen ? "pause.fill" : "play.fill"
    }

    private var durationRow: some View {
        HStack(spacing: 10) {
            ModeSegmented(
                options: [("Отсчёт", .countdown), ("Помодоро", .pomodoro)],
                selection: controller.timerMode,
                tint: tint
            ) { controller.setMode($0) }

            Spacer()

            ForEach(AppDefaults.presetDurations, id: \.self) { minutes in
                DurationChip(
                    label: Theme.shortDuration(minutes),
                    isSelected: controller.sessionMinutes == minutes,
                    tint: tint
                ) {
                    controller.setDuration(minutes)
                }
            }

            Menu {
                ForEach(AppDefaults.allDurations, id: \.self) { minutes in
                    Button("\(Theme.shortDuration(minutes)) (\(minutes) мин)") {
                        controller.setDuration(minutes)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                    Text(AppDefaults.presetDurations.contains(controller.sessionMinutes) ? "ещё" : Theme.shortDuration(controller.sessionMinutes))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(AppDefaults.presetDurations.contains(controller.sessionMinutes) ? .white.opacity(0.55) : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Другая длительность")

            if controller.timerMode == .pomodoro {
                Menu {
                    ForEach(AppDefaults.breakChoices, id: \.self) { minutes in
                        Button("\(minutes) мин") { controller.breakMinutes = minutes }
                    }
                } label: {
                    Text("перерыв \(controller.breakMinutes) м")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var categoriesGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("РЕЖИМЫ")
                .font(.system(size: 11, weight: .bold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.32))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                spacing: 12
            ) {
                ForEach(store.allCategories) { category in
                    CategoryTile(
                        category: category,
                        tint: Theme.color(for: category.id),
                        isActive: controller.selectedCategoryID == category.id
                    ) {
                        handleTap(category)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var todayFooter: some View {
        Group {
            if stats.todayMinutes > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(tint.opacity(0.8))
                    Text("Сегодня: \(Theme.timeString(TimeInterval(stats.todayMinutes * 60))) · серия \(stats.currentStreak) дн.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func toastView(_ message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow.opacity(0.9))
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .liquidGlass(in: Capsule())
            .padding(.bottom, 12)
        }
        .id(message)
        .task(id: message) {
            do {
                try await Task.sleep(nanoseconds: 6_000_000_000)
            } catch {
                // Задача отменена: сообщение уже сменилось — новое не трогаем.
                return
            }
            guard player.statusText == message else { return }
            player.statusText = nil
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.statusText)
        .allowsHitTesting(false)
    }

    // MARK: - Служебное

    /// Space = старт/пауза сессии. Локальный монитор keyDown срабатывает
    /// только на нажатие клавиши (не крутит runloop, в отличие от
    /// didUpdateNotification). Пробел перехватывается лишь когда ничего
    /// не в фокусе: текстовые поля и контролы получают его первыми.
    private func installSpaceMonitor() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               let keyWindow = NSApp.keyWindow,
               !keyWindow.isSheet,
               keyWindow.firstResponder === keyWindow {
                MainActor.assumeIsolated {
                    controller.toggleSession()
                }
                return nil
            }
            return event
        }
    }

    private func reportBrokenDataIfNeeded() {
        guard !didShowLoadDiagnostics else { return }
        didShowLoadDiagnostics = true
        if let message = store.lastLoadError ?? store.curatedLoadError ?? stats.lastLoadError {
            player.statusText = message
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(player.volume) },
            set: { controller.setVolume(Float($0)) }
        )
    }

    private var hiddenShortcuts: some View {
        Group {
            // Space обрабатывает локальный keyDown-монитор (installSpaceMonitor):
            // keyboardShortcut-кнопка перехватывала бы пробел у текстовых полей.
            Button("") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .disabled(isAdding)
    }

    private func handleTap(_ category: MusicCategory) {
        if category.id == LibraryStore.myCategoryID && category.tracks.isEmpty {
            isAdding = true
            return
        }
        controller.select(category)
    }
}

// MARK: - Плеер

struct PlayerBar: View {
    @ObservedObject var player: PlayerCore
    @ObservedObject var controller: SessionController
    @Binding var volume: Double

    @State private var scrub: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        HStack(spacing: 14) {
            PlayerButton(systemName: "backward.fill", size: 36) { player.previous() }
                .help("Предыдущий трек")
                .accessibilityLabel("Предыдущий трек")
                .accessibilityHint("Включает предыдущий трек очереди")
            PlayerButton(
                systemName: player.isPlaying ? "pause.fill" : "play.fill",
                size: 46,
                tint: Theme.color(for: controller.selectedCategoryID ?? "work").opacity(0.4)
            ) { controller.toggleSession() }
                .help("Пауза сессии (Space)")
                .accessibilityLabel(player.isPlaying ? "Приостановить сессию" : "Запустить сессию")
                .accessibilityHint("Ставит сессию на паузу и возвращает к работе; работает и клавиша пробел")
            PlayerButton(systemName: "forward.fill", size: 36) { player.next() }
                .help("Следующий трек")
                .accessibilityLabel("Следующий трек")
                .accessibilityHint("Включает следующий трек очереди")

            if player.needsRetry {
                PlayerButton(systemName: "arrow.clockwise", size: 36) { player.retry() }
                    .help("Повторить загрузку трека")
                    .accessibilityLabel("Повторить загрузку")
                    .accessibilityHint("Перезапускает загрузку трека после ошибки")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if player.isLoading || player.isBuffering {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(player.current?.title ?? "Ничего не играет")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let track = player.current {
                        switch track.status {
                        case .live:
                            Text("LIVE")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.red.opacity(0.15)))
                        case .unknown:
                            Text("длительность неизвестна")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        case .vod:
                            EmptyView()
                        }
                    }
                }
                Text(player.current?.channel ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer()

            if player.duration > 0 {
                GlassSlider(
                    value: isScrubbing ? scrub : player.elapsed,
                    range: 0...max(player.duration, 1),
                    tint: .white,
                    onScrub: { newValue in
                        if !isScrubbing { isScrubbing = true }
                        scrub = newValue
                    },
                    onCommit: { newValue in
                        isScrubbing = false
                        player.seek(to: newValue)
                    }
                )
                .frame(width: 170)
                .accessibilityLabel("Позиция воспроизведения")
                Text("\(Theme.timeString(player.elapsed)) / \(Theme.timeString(player.duration))")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 106, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Image(systemName: volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
                GlassSlider(
                    value: volume,
                    range: 0...1,
                    tint: .white.opacity(0.7),
                    onScrub: { controller.setVolume(Float($0)) }
                )
                .frame(width: 92)
                .accessibilityLabel("Громкость")
                .accessibilityHint("Регулирует громкость воспроизведения")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
