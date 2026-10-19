APP   := CmdTabMax
SWIFT := swiftc
FLAGS := -O -framework Cocoa -framework ApplicationServices \
         -F/System/Library/PrivateFrameworks -framework SkyLight
SRC   := $(APP).swift
DIST  := dist

.PHONY: all universal arm64 x86_64 clean install uninstall

all: universal

$(DIST):
	mkdir -p $@

$(DIST)/$(APP)-arm64: $(SRC) | $(DIST)
	$(SWIFT) $(FLAGS) -target arm64-apple-macosx11.0 $(SRC) -o $@

$(DIST)/$(APP)-x86_64: $(SRC) | $(DIST)
	$(SWIFT) $(FLAGS) -target x86_64-apple-macosx11.0 $(SRC) -o $@

$(DIST)/$(APP): $(DIST)/$(APP)-arm64 $(DIST)/$(APP)-x86_64
	lipo -create -output $@ $^
	rm $(DIST)/$(APP)-arm64 $(DIST)/$(APP)-x86_64
	@echo "Built universal binary: $@"

arm64:   $(DIST)/$(APP)-arm64
x86_64:  $(DIST)/$(APP)-x86_64
universal: $(DIST)/$(APP)

clean:
	rm -rf $(DIST)

# ── local install ──────────────────────────────────────────────────────────────
# Mirrors install.sh: an app bundle gives TCC a stable bundle ID to track.
APP_BUNDLE  := $(HOME)/Applications/$(APP).app
INSTALL_BIN := $(APP_BUNDLE)/Contents/MacOS/$(APP)
PLIST_SRC   := com.stoutput.cmdtabmax.plist
PLIST_DST   := $(HOME)/Library/LaunchAgents/$(PLIST_SRC)
LAUNCHD_UID := gui/$$(id -u)
VERSION     := $$(/usr/libexec/PlistBuddy -c "Print :Version" $(PLIST_SRC))

install: universal
	-launchctl bootout $(LAUNCHD_UID) $(PLIST_DST) 2>/dev/null
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(dir $(PLIST_DST))
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '    <key>CFBundleIdentifier</key><string>com.stoutput.cmdtabmax</string>' \
	  '    <key>CFBundleName</key><string>$(APP)</string>' \
	  "    <key>CFBundleVersion</key><string>$(VERSION)</string>" \
	  '    <key>CFBundleExecutable</key><string>$(APP)</string>' \
	  '    <key>LSUIElement</key><true/>' \
	  '</dict>' \
	  '</plist>' > $(APP_BUNDLE)/Contents/Info.plist
	cp $(DIST)/$(APP) $(INSTALL_BIN)
	codesign --force --deep --sign - $(APP_BUNDLE)
	# The ad-hoc signature changes every build, leaving the old grant stale
	# but still toggled on; clear it so the prompt can grant the new binary.
	-tccutil reset Accessibility com.stoutput.cmdtabmax
	touch /tmp/$(APP).fresh-install
	sed "s|__BINARY__|$(INSTALL_BIN)|g" $(PLIST_SRC) > $(PLIST_DST)
	launchctl bootstrap $(LAUNCHD_UID) $(PLIST_DST)
	@echo "Installed. $(APP) is running and will start automatically on login."
	@echo "Enable $(APP) when prompted for Accessibility access."

uninstall:
	-launchctl bootout $(LAUNCHD_UID) $(PLIST_DST) 2>/dev/null
	-rm -rf $(APP_BUNDLE)
	-rm -f $(PLIST_DST) /usr/local/bin/$(APP)
	@echo "Uninstalled."
