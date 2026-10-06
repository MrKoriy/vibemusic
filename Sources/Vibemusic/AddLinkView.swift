import SwiftUI
import VibemusicCore

struct AddLinkView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var loaded: [Track] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var importMode: ImportMode = .playlist

    enum ImportMode: String, CaseIterable, Identifiable {
        case video
        case playlist

        var id: String { rawValue }
    }

    enum LinkTarget {
        case video
        case playlist
        case mixed
        case auto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Добавить из YouTube")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть окно")
                .accessibilityHint("Закрывает окно без добавления треков")
            }

            HStack(spacing: 10) {
                TextField("Ссылка на видео или плейлист", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(load)
                Button(action: load) {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text("Загрузить")
                    }
                    .frame(width: 110)
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                .accessibilityHint("Загружает метаданные треков по указанной ссылке")
            }

            if linkTarget == .mixed {
                Picker("Что добавить", selection: $importMode) {
                    Text("Видео").tag(ImportMode.video)
                    Text("Плейлист (до 50)").tag(ImportMode.playlist)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            if !loaded.isEmpty {
                Text("Будет добавлено: \(loaded.count) треков")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.mint)
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(loaded) { track in
                            trackRow(track, showDelete: false) {}
                        }
                    }
                }
                .frame(maxHeight: 200)
                .padding(10)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Divider()
                .overlay(.white.opacity(0.1))

            HStack {
                Text("Мои ссылки — \(store.userTracks.count)")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }

            if store.userTracks.isEmpty {
                Text("Пока пусто. Вставьте ссылку на видео или плейлист — он появится в режиме «Мои ссылки».")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.vertical, 12)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.userTracks) { track in
                            trackRow(track, showDelete: true) {
                                store.removeUserTrack(id: track.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Spacer()

            HStack {
                Button(isLoading ? "Отменить загрузку" : "Отмена") {
                    if isLoading {
                        loadTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                Spacer()
                Button("Добавить в библиотеку") {
                    store.addUserTracks(loaded)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(loaded.isEmpty)
            }
        }
        .padding(22)
        .background(Color(white: 0.045))
        .preferredColorScheme(.dark)
        .onDisappear {
            loadTask?.cancel()
        }
    }

    private func trackRow(_ track: Track, showDelete: Bool, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            if showDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Удалить трек")
                .accessibilityHint("Убирает трек из «Мои ссылки»")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(track.channel ?? "YouTube")
                        .foregroundStyle(.white.opacity(0.4))
                    if let durationLabel = track.durationLabel {
                        Text("· \(durationLabel)")
                            .foregroundStyle(.white.opacity(0.4))
                    } else if track.isLive {
                        Text("· в эфире")
                            .foregroundStyle(.red.opacity(0.7))
                    } else {
                        Text("· длительность неизвестна")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .font(.system(size: 10))
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }

    private var linkTarget: LinkTarget {
        Self.classify(urlText)
    }

    /// Разбор ссылки через URLComponents: v= и list= → выбор пользователя,
    /// только list= → плейлист, без list= → видео, иначе авто-детект резолвера.
    /// nonisolated: чистая логика, вызывается и из тестов без главного актора.
    nonisolated static func classify(_ raw: String) -> LinkTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .auto }
        if trimmed.count == 11, trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return .video
        }
        guard let components = URLComponents(string: trimmed) else { return .auto }
        let items = components.queryItems ?? []
        let videoID = (items.first { $0.name == "v" }?.value ?? "").trimmingCharacters(in: .whitespaces)
        let playlistID = (items.first { $0.name == "list" }?.value ?? "").trimmingCharacters(in: .whitespaces)
        let shortPath = components.path.dropFirst()
        let hasVideo = !videoID.isEmpty || (components.host == "youtu.be" && !shortPath.isEmpty)
        let hasPlaylist = !playlistID.isEmpty
        switch (hasVideo, hasPlaylist) {
        case (true, true): return .mixed
        case (false, true): return .playlist
        case (true, false): return .video
        case (false, false): return .auto
        }
    }

    private func load() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isLoading else { return }
        let playlistFlag: Bool?
        switch linkTarget {
        case .mixed:
            playlistFlag = importMode == .playlist
        case .playlist:
            playlistFlag = true
        case .video:
            playlistFlag = false
        case .auto:
            playlistFlag = nil
        }
        isLoading = true
        errorText = nil
        loaded = []
        loadTask = Task {
            defer { isLoading = false }
            do {
                let proxy = ProxyConfig.load().toolURL
                let worker = Task.detached(priority: .userInitiated) {
                    try await YTResolver.importTracks(from: raw, proxy: proxy, playlist: playlistFlag)
                }
                let tracks = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                loaded = tracks
            } catch is CancellationError {
                // Отмена пользователем — тихо возвращаемся к вводу ссылки.
            } catch {
                guard !Task.isCancelled else { return }
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
