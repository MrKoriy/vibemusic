import Foundation
import Testing
@testable import Vibemusic

private func args(_ parts: String...) -> [String] {
    ["Vibemusic"] + parts
}

private func cliRun(_ verb: CLIBootstrap.CLIOptions.Verb, proxy: String? = nil) -> CLIBootstrap.ParseOutcome {
    .run(CLIBootstrap.CLIOptions(verb: verb, proxy: proxy))
}

// MARK: - CLIBootstrap.parse

@Test func cliParseTable() {
    let cases: [([String], CLIBootstrap.ParseOutcome)] = [
        // Нет флагов — обычный запуск приложения.
        (args(), .launchApp),
        (args("abc12345678"), .launchApp),

        // Глаголы со значением.
        (args("--verify", "abc12345678"), cliRun(.verify(videoID: "abc12345678"))),
        (args("--resolve", "abc12345678"), cliRun(.resolve(target: "abc12345678"))),
        (args("--meta", "https://youtube.com/watch?v=x"), cliRun(.meta(source: "https://youtube.com/watch?v=x"))),
        (args("--verify-url", "https://example.com/a.m3u8"), cliRun(.verifyURL(url: "https://example.com/a.m3u8"))),

        // Прокси + глагол.
        (args("--proxy", "socks5://u:p@h:1", "--verify", "abc12345678"), cliRun(.verify(videoID: "abc12345678"), proxy: "socks5://u:p@h:1")),
        (args("--resolve", "abc12345678", "--proxy", "socks5://u:p@h:1"), cliRun(.resolve(target: "abc12345678"), proxy: "socks5://u:p@h:1")),

        // --proxy без глагола — ошибка (раньше молчаливый exit 0).
        (args("--proxy", "socks5://u:p@h:1"), .invalid("--proxy используется только вместе с --verify, --resolve, --meta или --verify-url")),
        (args("--proxy", "socks5://u:p@h:1", "abc12345678"), .invalid("--proxy используется только вместе с --verify, --resolve, --meta или --verify-url")),
        (args("--proxy"), .invalid("--proxy требует значение: socks5://user:pass@host:port")),

        // Неизвестные флаги.
        (args("--bogus"), .invalid("неизвестный флаг: --bogus")),
        (args("--verify", "abc12345678", "--bogus"), .invalid("неизвестный флаг: --bogus")),

        // Глагол без значения и без позиционного аргумента.
        (args("--resolve"), .invalid("--resolve требует значение")),
        (args("--verify"), .invalid("--verify требует значение")),
        (args("--meta"), .invalid("--meta требует значение")),

        // Глагол без значения, но с позиционным аргументом — fallback.
        (args("abc12345678", "--resolve"), cliRun(.resolve(target: "abc12345678"))),
        (args("--verify", "abc12345678", "leftover"), cliRun(.verify(videoID: "abc12345678"))),

        // Приоритет глаголов: verify > verify-url > resolve > meta.
        (args("--resolve", "x", "--meta", "y"), cliRun(.resolve(target: "x"))),
        (args("--meta", "y", "--verify-url", "https://e.com/a"), cliRun(.verifyURL(url: "https://e.com/a"))),
        (args("--meta", "y", "--verify", "abc12345678"), cliRun(.verify(videoID: "abc12345678"))),

        // «--» не является флагом этого CLI — строгий парсинг отклоняет его.
        (args("--", "abc12345678"), .invalid("неизвестный флаг: --")),
    ]

    for (arguments, expected) in cases {
        #expect(CLIBootstrap.parse(arguments) == expected)
    }
}

@Test func cliParseIsPure() {
    let input = ["Vibemusic", "--proxy", "socks5://u:p@h:1", "--verify", "abc12345678"]
    #expect(CLIBootstrap.parse(input) == CLIBootstrap.parse(input))
    #expect(input == ["Vibemusic", "--proxy", "socks5://u:p@h:1", "--verify", "abc12345678"])
}

// MARK: - AddLinkView.classify

@Test func addLinkClassifyTable() {
    let cases: [(String, AddLinkView.LinkTarget)] = [
        ("", .auto),
        ("   ", .auto),
        ("abc12345678", .video),
        ("https://www.youtube.com/watch?v=abc12345678", .video),
        ("https://youtu.be/abc12345678", .video),
        ("https://www.youtube.com/watch?v=abc12345678&list=PLxyz", .mixed),
        ("https://www.youtube.com/playlist?list=PLxyz", .playlist),
        ("https://www.youtube.com/watch?list=PLxyz", .playlist),
        ("https://www.youtube.com/watch?v=&list=PLxyz", .playlist),
        ("not a url at all", .auto),
    ]
    // LinkTarget без Equatable — сверяем через stringRepresentation.
    func key(_ target: AddLinkView.LinkTarget) -> String {
        switch target {
        case .video: return "video"
        case .playlist: return "playlist"
        case .mixed: return "mixed"
        case .auto: return "auto"
        }
    }
    for (raw, expected) in cases {
        #expect(key(AddLinkView.classify(raw)) == key(expected))
    }
}
