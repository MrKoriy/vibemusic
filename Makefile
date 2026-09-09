APP = build/Vibemusic.app
BINARY = .build/release/Vibemusic
YTDLP = build/yt-dlp
STAGE_DIR = $(HOME)/Library/Caches/Vibemusic
STAGE_APP = $(STAGE_DIR)/Vibemusic.app

.PHONY: all app test run install clean

all: app

$(YTDLP):
	mkdir -p build
	curl -L --fail -o $(YTDLP) https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
	chmod +x $(YTDLP)

app: $(YTDLP)
	swift build -c release
	mkdir -p build/AppIcon.iconset
	swift Scripts/make_icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
	rm -rf $(STAGE_APP)
	mkdir -p $(STAGE_APP)/Contents/MacOS $(STAGE_APP)/Contents/Resources $(STAGE_APP)/Contents/Helpers
	cp $(BINARY) $(STAGE_APP)/Contents/MacOS/Vibemusic
	cp App/Info.plist $(STAGE_APP)/Contents/Info.plist
	cp build/AppIcon.icns $(STAGE_APP)/Contents/Resources/AppIcon.icns
	cp $(YTDLP) $(STAGE_APP)/Contents/Helpers/yt-dlp
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
