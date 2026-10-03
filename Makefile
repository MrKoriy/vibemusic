APP = build/Vibemusic.app
BINARY = .build/release/Vibemusic
BUNDLE = .build/release/Vibemusic_VibemusicCore.bundle
YTDLP = build/yt-dlp
YTDLP_VERSION_FILE = Scripts/yt-dlp.version
STAGE_DIR = $(HOME)/Library/Caches/Vibemusic
STAGE_APP = $(STAGE_DIR)/Vibemusic.app

YTDLP_VERSION = $(shell sed -n 's/^VERSION=//p' $(YTDLP_VERSION_FILE))
YTDLP_SHA256 = $(shell sed -n 's/^SHA256=//p' $(YTDLP_VERSION_FILE))
YTDLP_URL = https://github.com/yt-dlp/yt-dlp/releases/download/$(YTDLP_VERSION)/yt-dlp_macos
YTDLP_LATEST_API = https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest

.PHONY: all app test run install clean update-ytdlp

all: app

$(YTDLP): $(YTDLP_VERSION_FILE)
	@test -n "$(YTDLP_VERSION)" && test -n "$(YTDLP_SHA256)" || { \
		echo "ОШИБКА: $(YTDLP_VERSION_FILE) должен содержать VERSION=<tag> и SHA256=<hex>" >&2; \
		exit 1; }
	@set -e; \
	mkdir -p build; \
	if [ -f $(YTDLP) ] && echo "$(YTDLP_SHA256)  $(YTDLP)" | shasum -a 256 --check - >/dev/null 2>&1; then \
		echo "yt-dlp $(YTDLP_VERSION): уже скачан, sha256 совпадает"; \
	else \
		echo "Скачиваю yt-dlp $(YTDLP_VERSION)..."; \
		curl -L --fail -o $(YTDLP).tmp $(YTDLP_URL); \
		if ! echo "$(YTDLP_SHA256)  $(YTDLP).tmp" | shasum -a 256 --check - >/dev/null 2>&1; then \
			actual=$$(shasum -a 256 $(YTDLP).tmp | awk '{print $$1}'); \
			rm -f $(YTDLP).tmp; \
			echo "ОШИБКА: sha256 скачанного yt-dlp не совпал с пином." >&2; \
			echo "  ожидается ($(YTDLP_VERSION)): $(YTDLP_SHA256)" >&2; \
			echo "  получено:                 $$actual" >&2; \
			echo "  Возможные причины: битый ассет релиза или устаревший пин. Обнови: make update-ytdlp" >&2; \
			exit 1; \
		fi; \
		mv $(YTDLP).tmp $(YTDLP); \
	fi
	chmod +x $(YTDLP)

update-ytdlp:
	@set -e; \
	v=$$(curl -s $(YTDLP_LATEST_API) | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1); \
	test -n "$$v" || { echo "ОШИБКА: не удалось узнать последний релиз yt-dlp" >&2; exit 1; }; \
	echo "Последний стабильный релиз yt-dlp: $$v"; \
	mkdir -p build; \
	curl -L --fail -o $(YTDLP).tmp "https://github.com/yt-dlp/yt-dlp/releases/download/$$v/yt-dlp_macos"; \
	sha=$$(shasum -a 256 $(YTDLP).tmp | awk '{print $$1}'); \
	printf 'VERSION=%s\nSHA256=%s\n' "$$v" "$$sha" > $(YTDLP_VERSION_FILE); \
	mv $(YTDLP).tmp $(YTDLP); \
	chmod +x $(YTDLP); \
	echo "Запинено в $(YTDLP_VERSION_FILE): $$v ($$sha)"

app: $(YTDLP)
	swift build -c release
	mkdir -p build/AppIcon.iconset
	swift Scripts/make_icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
	rm -rf $(STAGE_APP)
	mkdir -p $(STAGE_APP)/Contents/MacOS $(STAGE_APP)/Contents/Resources $(STAGE_APP)/Contents/Helpers
	cp $(BINARY) $(STAGE_APP)/Contents/MacOS/Vibemusic
	cp App/Info.plist $(STAGE_APP)/Contents/Info.plist
	@v="$$(git rev-list --count HEAD 2>/dev/null || echo 0)-$$(git rev-parse --short HEAD 2>/dev/null || echo dev)"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$v" $(STAGE_APP)/Contents/Info.plist
	cp build/AppIcon.icns $(STAGE_APP)/Contents/Resources/AppIcon.icns
	cp $(YTDLP) $(STAGE_APP)/Contents/Helpers/yt-dlp
	@if [ -d "$(BUNDLE)" ]; then cp -R $(BUNDLE) $(STAGE_APP)/Contents/Resources/; else echo "WARN: $(BUNDLE) not found — library.json будет недоступен" >&2; fi
	xattr -cr $(STAGE_APP) 2>/dev/null || true
	codesign --force --sign - $(STAGE_APP)/Contents/Helpers/yt-dlp
	codesign --force --sign - $(STAGE_APP)
	rm -rf $(APP)
	cp -R $(STAGE_APP) $(APP)
	@echo "Готово: $(APP)"

test:
	swift test

run: app
	open $(APP)

install: app
	rm -rf /Applications/Vibemusic.app
	cp -R $(APP) /Applications/Vibemusic.app
	xattr -cr /Applications/Vibemusic.app 2>/dev/null || true
	@echo "Установлено: /Applications/Vibemusic.app"

clean:
	swift package clean
	rm -rf build $(STAGE_DIR)
