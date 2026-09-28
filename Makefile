PREFIX ?= $(HOME)/Applications
# The app lives next to the profile launchers it creates. With the default PREFIX and no DEST, scripts/install-app.sh
# picks the folder: ~/Applications/Baton, or ~/Applications/Claude Profiles until Baton renames it from its earlier name.
DEST ?= $(if $(filter $(HOME)/Applications,$(PREFIX)),,$(PREFIX)/Baton)
# The folder the app is in (or goes to), as the install script picks it.
WHERE = sh scripts/install-app.sh --where $(if $(DEST),"$(DEST)")

.PHONY: build test app verify notarize package release install uninstall clean

build:
	swift build

# The toolchain sometimes loses the swift-testing macro plugin ("plugin for module 'TestingMacros' not found");
# building the tests on one job and running them without a rebuild gets past it.
test:
	swift test || (swift build --build-tests -j 1 && swift test --skip-build)

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
	@echo "Optional CLI, if you have no baton link yet: ln -sf \"$$($(WHERE))/Baton.app/Contents/Helpers/baton\" /usr/local/bin/baton"

uninstall:
	rm -rf "$$($(WHERE))/Baton.app"
	@echo "Profiles, sign-ins and launchers are kept. Remove them from the app first if you no longer need them."

clean:
	rm -rf .build .build-app build
