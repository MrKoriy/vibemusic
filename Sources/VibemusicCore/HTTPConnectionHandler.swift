import Foundation
import Network
import os

// MARK: - HTTP

/// Разобранный Range-заголовок.
enum RangeSpec: Equatable {
    /// bytes=start-end или bytes=start-
    case offset(start: Int64, end: Int64?)
    /// bytes=-N — последние N байт файла (разрешается после ensureTotal)
    case suffix(length: Int64)
}

final class HTTPConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let hub: StreamHub
    private var buffer = Data()
    private var pumpTask: Task<Void, Never>?
    private var isFinished = false

    init(connection: NWConnection, hub: StreamHub) {
        self.connection = connection
        self.hub = hub
    }

    func run() {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveMore()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: hub.handlerQueue)
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let data {
                self.buffer.append(data)
            }
            if error != nil {
                self.finish()
                return
            }
            if let terminator = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = self.buffer.subdata(in: 0..<terminator.upperBound)
                self.handle(headerData: headerData)
            } else if self.buffer.count > 65536 {
                self.respondSimple(status: "404 Not Found")
            } else {
                self.receiveMore()
            }
        }
    }

    private func handle(headerData: Data) {
        guard let text = String(data: headerData, encoding: .utf8) else {
            respondSimple(status: "404 Not Found")
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respondSimple(status: "404 Not Found")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respondSimple(status: "405 Method Not Allowed")
            return
        }
        let path = String(parts[1])
        let token = path.dropFirst().split(separator: ".").first.map(String.init) ?? ""

        var rangeHeader: String?
        for line in lines.dropFirst() {
            let keyValue = line.split(separator: ":", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            if keyValue[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                rangeHeader = keyValue[1].trimmingCharacters(in: .whitespaces)
            }
        }

        guard let stream = hub.stream(for: token) else {
            respondSimple(status: "404 Not Found")
            return
        }
        let range = rangeHeader.flatMap(Self.parseRange)
        StreamHub.log("request token=\(token.prefix(8)) range=\(rangeHeader ?? "none")")
        networkLogger.debug("request token=\(String(token.prefix(8)), privacy: .public) range=\(rangeHeader ?? "none", privacy: .public)")

        pumpTask = Task {
            await self.serve(stream: stream, range: range)
        }
    }

    /// Аудит B-4: поддерживает bounded (bytes=0-99), open-ended (bytes=100-)
    /// и суффиксный (bytes=-500) синтаксис. Невалидные строки → nil.
    static func parseRange(_ value: String) -> RangeSpec? {
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6)
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let startText = bounds[0].trimmingCharacters(in: .whitespaces)
        let endText = bounds[1].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            guard let length = Int64(endText), length > 0 else { return nil }
            return .suffix(length: length)
        }
        guard let start = Int64(startText), start >= 0 else { return nil }
        let end = endText.isEmpty ? nil : Int64(endText)
        return .offset(start: start, end: end)
    }

    /// Разрешает RangeSpec в конкретные (start, end) при известном total.
    /// Суффикс N > total → весь файл.
    static func resolvedBounds(_ spec: RangeSpec?, total: Int64) -> (start: Int64, end: Int64) {
        switch spec {
        case nil:
            return (0, total - 1)
        case .suffix(let length):
            let count = min(length, total)
            return (total - count, total - 1)
        case .offset(let start, let end):
            let upperBound = min(end ?? (total - 1), total - 1)
            return (start, upperBound)
        }
    }

    /// Content-Type для ответа клиенту: реальный тип upstream с вырезанными
    /// переводами строк (защита от подделки заголовков), дефолт — audio/mp4.
    static func sanitizedContentType(_ value: String) -> String {
        let cleaned = value
            .components(separatedBy: .newlines)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? LocalStream.defaultContentType : cleaned
    }

    private func serve(stream: LocalStream, range: RangeSpec?) async {
        do {
            let total = try await stream.ensureTotal()
            guard total > 0 else {
                respondSimple(status: "404 Not Found")
                return
            }

            let resolved = Self.resolvedBounds(range, total: total)
            let start = resolved.start
            let end = resolved.end
            guard start >= 0, start <= end else {
                respond416(total: total)
                return
            }

            let length = end - start + 1
            var head = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\n"
            head += "Content-Type: \(Self.sanitizedContentType(stream.resolvedContentType()))\r\n"
            if range != nil {
                head += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
            }
            head += "Content-Length: \(length)\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Connection: close\r\n\r\n"
            try await send(Data(head.utf8))

            var cursor = start
            while cursor <= end {
                try Task.checkCancellation()
                let chunk = try await stream.fetchChunk(offset: cursor)
                let lower = stream.chunkLowerBound(cursor)
                let inChunk = Int(cursor - lower)
                let available = Int64(chunk.count) - Int64(inChunk)
                guard available > 0 else { throw URLError(.badServerResponse) }
                let take = min(available, end - cursor + 1)
                try await send(chunk.subdata(in: inChunk..<inChunk + Int(take)))
                cursor += take
            }
        } catch {
            StreamHub.log("serve error: \(error.localizedDescription)")
            networkLogger.error("serve failed: \(error.localizedDescription)")
        }
        finish()
    }

    private func respond416(total: Int64) {
        let head = "HTTP/1.1 416 Range Not Satisfiable\r\n"
            + "Content-Range: bytes */\(total)\r\n"
            + "Content-Length: 0\r\n"
            + "Connection: close\r\n\r\n"
        pumpTask = Task {
            try? await self.send(Data(head.utf8))
            self.finish()
        }
    }

    private func respondSimple(status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        pumpTask = Task {
            try? await self.send(Data(head.utf8))
            self.finish()
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Разрывает цикл удержания connection → stateUpdateHandler → self → connection.
    /// Идемпотентен: безопасно вызывать из любого места и несколько раз.
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        pumpTask?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
