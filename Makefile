EXEC     := Mumble
CONFIG   := debug

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/MumbleBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/MumbleBuild
APPNAME  := Mumble.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Accessibility and Microphone grants to the signature's *designated
## requirement*, not to the app's path. An ad-hoc signature ("-") has no certificate, so its
## requirement can only pin the cdhash — which changes on literally every build. That is why
## the grant had to be re-issued after every `make install`: macOS saw a different app.
##
## Signing with any real certificate makes the requirement name the leaf certificate and the
## bundle ID instead of the hash, and both of those survive rebuilds. It also survives a
## certificate *renewal*, because the requirement matches the certificate's common name
## (which carries the team ID) rather than its serial.
##
## Preference order:
##   1. Developer ID Application — stable and also passes Gatekeeper if the app is ever
##      distributed.
##   2. Apple Development — equally stable for a locally-installed app; the usual case on a
##      machine that has Xcode signed in.
##   3. A self-signed identity named by LOCAL_SIGN_CN, for a machine with no Apple certs.
##      See `make signing` for how to create one.
## Revoked certificates are filtered out: `find-identity` still lists them, and codesign
## refuses them with an unhelpful error.
LOCAL_SIGN_CN := Mumble Local Signing

## Selected by SHA-1 fingerprint rather than by name: a keychain routinely holds several
## certificates sharing one common name (an expired or revoked one alongside its
## replacement), and `codesign --sign "<name>"` fails outright with "ambiguous" when it does.
## The fingerprint is unique, and the name is carried alongside only so the build log is
## readable.
SIGN_ROW := $(shell \
	ids="$$(security find-identity -v -p codesigning 2>/dev/null | grep -v CSSMERR)"; \
	for pattern in "Developer ID Application" "Apple Development" "$(LOCAL_SIGN_CN)"; do \
		hit="$$(printf '%s\n' "$$ids" | grep -F "$$pattern" | head -1)"; \
		if [ -n "$$hit" ]; then \
			printf '%s ' "$$(printf '%s' "$$hit" | awk '{print $$2}')"; \
			printf '%s' "$$(printf '%s' "$$hit" | sed -E 's/.*"(.*)".*/\1/')"; \
			break; \
		fi; \
	done)

SIGN_ID   := $(firstword $(SIGN_ROW))
SIGN_NAME := $(wordlist 2,99,$(SIGN_ROW))
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID   := -
SIGN_NAME := ad-hoc
endif

.PHONY: all build app run install clean icon signing doctor

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_NAME)]"
	@# Loud, because the failure mode is silent and annoying: an ad-hoc build installs and
	@# runs fine, and only reveals itself when the hotkey stops working an hour later.
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo ""; \
		echo "  WARNING: ad-hoc signature. macOS will drop the Accessibility and"; \
		echo "  Microphone grants on every rebuild. Run 'make signing' for the fix."; \
		echo ""; \
	fi

## Only ever targets the Mumble executable — never the separate `murmur` app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Installing to /Applications keeps the path stable, which is what the Accessibility pane
## lists the app by. The grant itself is kept across rebuilds by the signing identity above,
## not by this path.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"
	@# Said every time rather than only on first install. Neither permission can be
	@# requested silently, and an app that is running but deaf and mute looks broken in a
	@# way that gives no hint what to do about it.
	@echo ""
	@echo "  Next: System Settings > Privacy & Security > Accessibility > add Mumble."
	@echo "        Quit and reopen Mumble, then hold your push-to-talk key and talk."
	@echo "        The microphone prompt appears on the first recording."

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"

## Reports which identity `make app` will sign with, and why it matters. Run this first if
## the Accessibility grant ever starts dropping again.
signing:
	@echo "signing identity: $(SIGN_NAME)"
	@echo "fingerprint:      $(SIGN_ID)"
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo ""; \
		echo "Ad-hoc. Every rebuild produces a new code identity, so macOS revokes the"; \
		echo "Accessibility and Microphone grants each time. To fix it, either:"; \
		echo ""; \
		echo "  a) Sign in to Xcode with an Apple ID (Xcode > Settings > Accounts) so an"; \
		echo "     'Apple Development' certificate lands in the login keychain, or"; \
		echo "  b) Create a self-signed code-signing certificate in Keychain Access"; \
		echo "     (Keychain Access > Certificate Assistant > Create a Certificate,"; \
		echo "     name it '$(LOCAL_SIGN_CN)', type 'Code Signing'), then set it to"; \
		echo "     'Always Trust' for code signing."; \
		echo ""; \
		echo "Then re-run 'make install' and grant Accessibility once more."; \
	else \
		echo ""; \
		echo "Stable. The Accessibility grant is keyed to this certificate and the bundle"; \
		echo "ID, so it survives rebuilds. If you switch certificates you will have to"; \
		echo "grant access one more time."; \
	fi
	@echo ""
	@echo "installed app's requirement:"
	@codesign -d -r- "/Applications/$(APPNAME)" 2>/dev/null | sed -n 's/^designated => /  /p' \
		|| echo "  (not installed yet)"

## Preflight for a machine that has never built this before.
##
## Everything here is a thing that has actually gone wrong on a fresh Mac: the wrong macOS,
## no Swift toolchain, `xcode-select` pointed at the Command Line Tools (which cannot build
## a SwiftUI app), or no signing identity — the last of which builds and installs perfectly
## and then quietly drops the Accessibility grant an hour later.
doctor:
	@echo "Mumble preflight"
	@echo ""
	@os=$$(sw_vers -productVersion); major=$$(echo "$$os" | cut -d. -f1); \
	if [ "$$major" -ge 26 ]; then \
		echo "  macOS         $$os"; \
	else \
		echo "  macOS         $$os  — NEEDS 26 or later"; \
		echo "                  SpeechAnalyzer and Liquid Glass are both macOS 26 APIs."; \
	fi
	@if ! command -v swift >/dev/null 2>&1; then \
		echo "  Swift         missing — install Xcode from the App Store"; \
	else \
		echo "  Swift         $$(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)"; \
	fi
	@dev=$$(xcode-select -p 2>/dev/null); \
	case "$$dev" in \
		*CommandLineTools*) \
			echo "  Developer dir $$dev"; \
			echo "                  — this is the Command Line Tools, which cannot build a"; \
			echo "                    SwiftUI app. Install Xcode, then:"; \
			echo "                    sudo xcode-select -s /Applications/Xcode.app" ;; \
		"") echo "  Developer dir missing — install Xcode from the App Store" ;; \
		*) echo "  Developer dir $$dev" ;; \
	esac
	@echo "  Signing       $(SIGN_NAME)"
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo "                  — ad-hoc. The app will work, but macOS drops the"; \
		echo "                    Accessibility and Microphone grants on every rebuild."; \
		echo "                    Run 'make signing' for the two ways to fix it."; \
	fi
	@if [ -d "/Applications/$(APPNAME)" ]; then \
		echo "  Installed     /Applications/$(APPNAME)"; \
	else \
		echo "  Installed     not yet — run 'make install'"; \
	fi
	@echo ""
	@echo "  Permissions cannot be checked from here: the TCC database is protected."
	@echo "  After 'make install', grant Accessibility and Microphone, then relaunch."
