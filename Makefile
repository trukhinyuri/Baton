PREFIX ?= $(HOME)/Applications
# The app lives next to the profile launchers it creates.
DEST = $(PREFIX)/Claude Profiles

.PHONY: build test app install uninstall clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install: app
	sh scripts/install-app.sh "$(DEST)"
	@echo "Optional CLI: ln -sf \"$(DEST)/Claude Profiles.app/Contents/Helpers/claude-profiles\" /usr/local/bin/claude-profiles"

uninstall:
	rm -rf "$(DEST)/Claude Profiles.app"
	@echo "Profiles, sign-ins and launchers are kept. Remove them from the app first if you no longer need them."

clean:
	rm -rf .build build
