APP := build/RexWeb.app
PREFIX ?= $(HOME)/.local
APPDIR ?= $(HOME)/Applications
ARCH := $(shell uname -m)

CAPP := chromium/dist/RexWebChromium.app

# What to sign RexWeb.app with. "-" is an ad hoc signature, which changes with
# every build, so macOS forgets permissions granted to the app. Name a signing
# identity here or in local.mk to keep them: see `security find-identity -v -p codesigning`.
SIGN ?= -
-include local.mk

.PHONY: build install uninstall clean chromium install-chromium
build: $(APP)

$(APP): $(wildcard Sources/*.swift) Info.plist bin/rexweb-pane bin/rexweb AGENTS.md
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O -swift-version 5 -target $(ARCH)-apple-macos14 Sources/*.swift -o $(APP)/Contents/MacOS/RexWeb
	cp Info.plist $(APP)/Contents/Info.plist
	cp bin/rexweb-pane bin/rexweb AGENTS.md $(APP)/Contents/Resources/
	codesign --force --sign "$(SIGN)" $(APP)
	touch $(APP)

install: build
	-pkill -x RexWeb
	mkdir -p $(APPDIR) $(PREFIX)/bin
	rm -rf $(APPDIR)/RexWeb.app && cp -R $(APP) $(APPDIR)/
	ln -sf $(APPDIR)/RexWeb.app/Contents/Resources/rexweb $(PREFIX)/bin/rexweb
	@echo "installed $(APPDIR)/RexWeb.app and $(PREFIX)/bin/rexweb"

# The Chromium engine is a second, optional app. CefSwift's plugin downloads
# CEF on the first build and assembles the bundle with its helper apps.
chromium:
	cd chromium && swift package --allow-writing-to-package-directory --allow-network-connections all cef bundle --product RexWebChromium
	cp bin/rexweb-pane bin/rexweb AGENTS.md $(CAPP)/Contents/Resources/
	codesign --force --sign - $(CAPP)

install-chromium: chromium
	-pkill -x RexWebChromium
	mkdir -p $(APPDIR)
	rm -rf $(APPDIR)/RexWebChromium.app && cp -R $(CAPP) $(APPDIR)/
	@echo "installed $(APPDIR)/RexWebChromium.app"

uninstall:
	-pkill -x RexWeb
	-pkill -x RexWebChromium
	rm -rf $(APPDIR)/RexWebChromium.app
	-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u $(APPDIR)/RexWeb.app 2>/dev/null
	rm -rf $(APPDIR)/RexWeb.app $(PREFIX)/bin/rexweb

clean:
	rm -rf build chromium/dist chromium/.build
