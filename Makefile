# Headroom: build, assemble, sign and install.
#   make            build release binaries
#   make test       run the test suites
#   make app        assemble and sign build/Headroom.app
#   make install    install to /Applications, link the CLI and man page, restart the app
#   make icon       regenerate assets/AppIcon.icns from assets/icon.svg
#   make screenshots  render the README images in media/ from fixtures (needs Google Chrome)
#   make release    zip the signed app into dist/ with a SHA-256 checksum

VERSION  := 0.1.0-beta.1
APP      := build/Headroom.app
RELEASE  := .build/release
# First valid Apple Development identity, by SHA-1 (names can be ambiguous).
IDENTITY ?= $(shell security find-identity -v -p codesigning | grep -v REVOKED | grep "Apple Development" | head -1 | awk '{print $$2}')

.PHONY: all build test app install icon clean bench screenshots release

all: build

build:
	swift build -c release --product HeadroomApp
	swift build -c release --product headroom

test:
	swift test

bench:
	swift run -c release HeadroomBench

icon:
	Scripts/make-icon.sh

screenshots:
	python3 -I Scripts/readme_media.py

release: app
	rm -rf dist && mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent $(APP) dist/Headroom-$(VERSION).zip
	cd dist && shasum -a 256 Headroom-$(VERSION).zip > Headroom-$(VERSION).zip.sha256
	@cat dist/Headroom-$(VERSION).zip.sha256

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/brand
	cp Packaging/Info.plist $(APP)/Contents/Info.plist
	cp $(RELEASE)/HeadroomApp $(APP)/Contents/MacOS/HeadroomApp
	cp $(RELEASE)/headroom $(APP)/Contents/MacOS/headroom
	cp -R $(RELEASE)/Headroom_HeadroomKit.bundle $(APP)/Contents/Resources/
	cp assets/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp assets/brand/claude.svg assets/brand/openai.svg $(APP)/Contents/Resources/brand/
	cp Packaging/headroom.1 $(APP)/Contents/Resources/headroom.1
	strip -x $(APP)/Contents/MacOS/HeadroomApp $(APP)/Contents/MacOS/headroom
	codesign --force --timestamp=none --options runtime --sign "$(IDENTITY)" $(APP)/Contents/MacOS/headroom
	codesign --force --timestamp=none --options runtime --sign "$(IDENTITY)" $(APP)
	codesign --verify --deep --strict $(APP)
	@du -sh $(APP)/Contents/MacOS/HeadroomApp $(APP)/Contents/MacOS/headroom

install: app
	-osascript -e 'tell application id "com.headroom.app" to quit' 2>/dev/null
	-pkill -x HeadroomApp
	rm -rf /Applications/Headroom.app
	ditto $(APP) /Applications/Headroom.app
	mkdir -p $(HOME)/.local/bin $(HOME)/.local/share/man/man1
	ln -sf /Applications/Headroom.app/Contents/MacOS/headroom $(HOME)/.local/bin/headroom
	ln -sf /Applications/Headroom.app/Contents/Resources/headroom.1 $(HOME)/.local/share/man/man1/headroom.1
	open /Applications/Headroom.app

clean:
	rm -rf build .build dist
