PREFIX ?= $(HOME)/Applications
# The app lives next to the profile launchers it creates. With the default PREFIX and no DEST, scripts/install-app.sh
# picks the folder: ~/Applications/Baton, or ~/Applications/Claude Profiles until Baton moves it from its earlier name.
DEST ?= $(if $(filter $(HOME)/Applications,$(PREFIX)),,$(PREFIX)/Baton)
# The folder the app is in (or goes to), as the install script picks it.
WHERE = sh scripts/install-app.sh --where $(if $(DEST),"$(DEST)")

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
	sh scripts/install-app.sh $(if $(DEST),"$(DEST)")
	@echo "Optional CLI: ln -sf \"$$($(WHERE))/Baton.app/Contents/Helpers/baton\" /usr/local/bin/baton"

uninstall:
	rm -rf "$$($(WHERE))/Baton.app"
	@echo "Profiles, sign-ins and launchers are kept. Remove them from the app first if you no longer need them."

clean:
	rm -rf .build .build-app build
