import SwiftUI
import VibemusicCore

struct AddLinkView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var loaded: [Track] = []
    @State private var isLoading = false
    @State private var errorText: String?

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
                Button("Отмена") { dismiss() }
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
        .background(Color(red: 0.07, green: 0.06, blue: 0.15))
        .preferredColorScheme(.dark)
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
                    } else {
                        Text("· в эфире")
                            .foregroundStyle(.red.opacity(0.7))
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

    private func load() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isLoading else { return }
        isLoading = true
        errorText = nil
        loaded = []
        Task {
            do {
                let proxy = ProxyConfig.load().toolURL
                let tracks = try await Task.detached(priority: .userInitiated) {
                    try YTResolver.importTracks(from: raw, proxy: proxy)
                }.value
                await MainActor.run {
                    loaded = tracks
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
