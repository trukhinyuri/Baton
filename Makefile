PREFIX ?= $(HOME)/Applications
# The app lives next to the profile launchers it creates.
DEST = $(PREFIX)/Claude Profiles

.PHONY: build test app verify notarize package release install uninstall clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

# Universal binaries, hardened runtime, commit in Info.plist, and --version under Rosetta.
verify:
	scripts/verify-build.sh

# Skips with a message unless NOTARY_KEYCHAIN_PROFILE is set.
notarize:
	scripts/notarize.sh

package:
	scripts/package.sh

# What the release workflow runs, minus the upload.
release: app verify notarize package

install: app
	sh scripts/install-app.sh "$(DEST)"
	@echo "Optional CLI: ln -sf \"$(DEST)/Claude Profiles.app/Contents/Helpers/claude-profiles\" /usr/local/bin/claude-profiles"

uninstall:
	rm -rf "$(DEST)/Claude Profiles.app"
	@echo "Profiles, sign-ins and launchers are kept. Remove them from the app first if you no longer need them."

clean:
	rm -rf .build build
