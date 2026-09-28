PREFIX ?= $(HOME)/Applications
# The app lives next to the profile launchers it creates. With the default PREFIX and no DEST, scripts/install-app.sh
# picks the folder: ~/Applications/Baton, or ~/Applications/Claude Profiles until Baton renames it from its earlier name.
DEST ?= $(if $(filter $(HOME)/Applications,$(PREFIX)),,$(PREFIX)/Baton)
# The folder the app is in (or goes to), as the install script picks it.
WHERE = sh scripts/install-app.sh --where $(if $(DEST),"$(DEST)")

.PHONY: build test app verify notarize package release install uninstall clean

build:
	swift build

# The Command Line Tools now and then stop with "plugin for module 'TestingMacros' not found". On that error, and
# only then, the tests are built once more on a single job and run without rebuilding (docs/TESTING.md).
test:
	@mkdir -p .build; log=.build/make-test.log; \
	{ swift test 2>&1; echo $$? > "$$log.status"; } | tee "$$log"; \
	status=$$(cat "$$log.status"); \
	if [ "$$status" != 0 ] && grep -q "plugin for module 'TestingMacros' not found" "$$log"; then \
		echo "Retrying once: building the tests on one job, then running them without rebuilding (docs/TESTING.md)."; \
		swift build --build-tests -j 1 && swift test --skip-build; \
	else \
		exit "$$status"; \
	fi

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

# The CLI hint names the folder Baton.app stays in: while the old folder keeps its name (a Claude window was open),
# a link into it would break at the rename, so the hint then names the Baton folder and waits for the rename. A DEST of
# the old folder that has been renamed since resolves to the Baton folder (install-app.sh --where).
install: app
	sh scripts/install-app.sh $(if $(DEST),"$(DEST)")
	@dir="$$($(WHERE))"; dir="$${dir%/}"; \
	if [ "$$dir" = "$(HOME)/Applications/Claude Profiles" ]; then \
		echo "Optional CLI, once that folder is renamed to Baton: ln -sf \"$(HOME)/Applications/Baton/Baton.app/Contents/Helpers/baton\" /usr/local/bin/baton"; \
	elif [ -x "$$dir/Baton.app/Contents/Helpers/baton" ]; then \
		echo "Optional CLI, if you have no baton link yet: ln -sf \"$$dir/Baton.app/Contents/Helpers/baton\" /usr/local/bin/baton"; \
	fi

# To the Trash, never deleted, with the install script's own helper.
uninstall:
	@app="$$($(WHERE))/Baton.app"; \
	if [ -e "$$app" ]; then sh -c '. scripts/install-lib.sh; to_trash "$$1"' uninstall "$$app" && echo "Moved $$app to the Trash."; \
	else echo "No Baton.app in $$($(WHERE))."; fi
	@echo "Profiles, sign-ins and launchers are kept. Remove them from the app first if you no longer need them."

clean:
	rm -rf .build .build-app build
