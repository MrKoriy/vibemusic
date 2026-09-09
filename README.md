# Vibemusic

macOS-приложение для фокуса, медитации и сна в стиле Liquid Glass: одна кнопка → режим → музыка с YouTube + таймер (помодоро или обратный отсчёт).

## Возможности

- 14 курируемых режимов, 69 треков (65 уникальных): deep house для работы, lo-fi, классика, эмбиент, альфа/бета/гамма-волны, бинауральный фокус, медитация, 528/432 Гц, резонанс Шумана, манифестация, дельта для сна, утренняя энергия
- Таймер: обратный отсчёт или помодоро (перерывы 5/10/15 мин, колокольчик на переходах, плавный fade-out музыки в конце)
- Своя библиотека: импорт любых ссылок YouTube (видео и плейлисты до 50 треков)
- Строка меню: остаток таймера, play/pause, переключение треков
- Медиа-клавиши и Now Playing (Control Center)
- Статистика: часы по дням, серия дней, учёт частичных сессий
- Автозапуск при входе в систему (настройки → Основные)

## Горячие клавиши

- `Space` — старт / пауза сессии
- `⌘→` / `⌘←` — следующий / предыдущий трек
- `⌘N` — открыть главное окно (если закрыли через `⌘W` и кликнули по Dock)

## Сборка и установка

```bash
make app          # сборка build/Vibemusic.app
make install      # установка в /Applications
make test         # юнит-тесты (swift test)
make run          # сборка и запуск приложения
make clean        # очистка .build, build/ и стейдж-папки в ~/Library/Caches/Vibemusic
make update-ytdlp # запинить последний стабильный yt-dlp в Scripts/yt-dlp.version
```

Сборка идёт в две ступени из-за iCloud-провенанса в рабочей папке: `.app` сначала стейджится в `~/Library/Caches/Vibemusic` (без xattr), подписывается ad-hoc и копируется в `build/`. В стейдж-копии `CFBundleVersion` проставляется как `<число коммитов>-<short SHA>` (в репозиторном `App/Info.plist` остаётся `1`); `CFBundleShortVersionString` — `1.0`.

Версия `yt-dlp` запинена в `Scripts/yt-dlp.version` (`VERSION` + `SHA256`): скачивание проверяет контрольную сумму и падает при несовпадении. Обновление пина — `make update-ytdlp` (скачивает последний стабильный релиз, обновляет файл).

Требования: macOS 15+ (нативный Liquid Glass — на macOS 26+), Xcode 26 с Swift 6.

CI (`.github/workflows/ci.yml`): на push/PR в main — `swift test`, `swift build -c release`, `plutil -lint App/Info.plist`, `Scripts/validate_library.py`; отдельный optional-job `bundle-smoke` прогоняет `make app` с кэшем `.build` и `build/yt-dlp`.

## Диагностика

Бинарник поддерживает CLI-флаги (запуск вместо GUI):

```bash
Vibemusic --resolve <videoID>            # напечатать прямую ссылку на аудиопоток
Vibemusic --meta <youtube-URL>           # метаданные трека/плейлиста: id | title | channel | duration
Vibemusic --verify <videoID>             # полный цикл: резолв → загрузка → проигрывание (AVPlayer)
Vibemusic --verify-url <stream-url>      # проверить готовую ссылку на поток через AVPlayer
Vibemusic --verify --proxy "socks5://user:pass@host:port" <videoID>   # то же через прокси
```

Пример на установленном приложении:

```bash
/Applications/Vibemusic.app/Contents/MacOS/Vibemusic --verify --proxy "socks5://user:pass@host:port" <videoID>
```

Вспомогательные инструменты в `Scripts/`:

- `avtest.swift` — прогон одной stream-ссылки через AVPlayer с логом статусов: `swift Scripts/avtest.swift <stream-url>`. Коды выхода: 0 — играет, 1 — ошибка элемента, 3 — таймаут/сталл.
- `test_server.py` — локальный upstream с поддержкой HTTP Range для отладки `--verify-url`: `python3 Scripts/test_server.py <file> [port]` (по умолчанию `http://127.0.0.1:8123`).
- `validate_library.py` — валидация `library.json` (id/title у треков и категорий), печатает `CATEGORIES=N TRACKS=M UNIQUE_IDS=K` и повторяющиеся id между категориями.
- `make_icon.swift` — генерация иконки (используется `make app`).

`VIBEMUSIC_DEBUG=1` при запуске включает отладочный лог локального стрим-сервера.

## Прокси (обход блокировок YouTube)

Настройки → Основные → «Прокси для YouTube». Формат: `socks5://user:pass@host:port`.

- Резолв ссылок (yt-dlp `--proxy`) и загрузка аудио (curl `-x`) всегда идут **одним маршрутом** — googlevideo привязывает ссылку к IP запросившего
- При включённом прокси резолв идёт **гонкой**: напрямую и через прокси параллельно, побеждает первый успешный; качка — маршрутом победителя
- Живые радио-потоки (HLS) играются напрямую
- Живой прогресс-манифесты (.m3u8/.mpd) отдаются AVPlayer напрямую

## Заметки

- `yt-dlp` лежит внутри приложения (`Contents/Helpers/yt-dlp`) — внешних зависимостей нет. Если YouTube поменяет форматы и стрим отвалится: `make update-ytdlp && make clean && make install` (обновит пин и скачает свежий yt-dlp).
- `xattr -cr /Applications/Vibemusic.app` — dev-only: чистит quarantine-провенанс у ad-hoc сборок, перенесённых на другую машину вручную. Для нотаризованных релизных сборок (см. ниже) не нужен.
- Данные: `~/Library/Application Support/Vibemusic/` (свои треки, статистика).
- Автозапуск работает, когда приложение лежит в `/Applications`.

## Планы дистрибуции

Сейчас приложение подписывается ad-hoc (без идентичности) и распространяется исходниками/ручной сборкой. Следующий шаг (не реализовано):

- сертификат **Developer ID Application** + подпись `codesign --options runtime`
- нотаризация через `notarytool` (Apple ID / App Store Connect API-ключ) + stapling
- после этого `xattr -cr` перестаёт быть нужным, а Gatekeeper пропускает сборку без предупреждений
