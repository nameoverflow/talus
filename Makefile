.PHONY: all clean app dist install install-man man-lint setup-cert test check deployment-test settings-preview status-cleanup-test integration-test

GEISHA ?= $(shell command -v geisha || echo $(HOME)/.geisha/bin/geisha)
CERT_NAME ?= Talus Local Code Signing
CODESIGN_IDENTITY ?= auto
MACOS_DEPLOYMENT_TARGET = 15.0
SWIFTC = swiftc -target $(shell uname -m)-apple-macosx$(MACOS_DEPLOYMENT_TARGET)
export MACOSX_DEPLOYMENT_TARGET = $(MACOS_DEPLOYMENT_TARGET)

GSA_SOURCES = geisha.toml $(wildcard src/*.gsa) $(wildcard src/macos/*.gsa)

all: build/talus

check:
	$(GEISHA) check

build/talus: Makefile $(GSA_SOURCES)
	mkdir -p build
	$(GEISHA) build -o $@

clean:
	rm -rf build

test: deployment-test
	$(GEISHA) test

build/Talus.icns: build/talus
	mkdir -p build/Talus.iconset
	find build/Talus.iconset -type f -delete
	build/talus --render-icon build/icon-master.png
	@for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do \
	  name=$${spec%:*}; size=$${spec#*:}; \
	  sips -z $$size $$size build/icon-master.png --out build/Talus.iconset/icon_$${name}.png >/dev/null; \
	done
	iconutil -c icns build/Talus.iconset -o $@

setup-cert:
	sh Scripts/setup-local-cert.sh "$(CERT_NAME)"

app: build/Talus.app deployment-test

build/Talus.app: Makefile $(GSA_SOURCES) Resources/Info.plist build/Talus.icns
	mkdir -p build
	$(GEISHA) build --target macos-app -o $@
	@if [ "$(CODESIGN_IDENTITY)" != "auto" ]; then \
	  echo "Signing $@ with explicit identity: $(CODESIGN_IDENTITY)"; \
	  codesign --force --sign "$(CODESIGN_IDENTITY)" "$@"; \
	elif [ ! -f geisha.local.toml ]; then \
	  id="$$(sh Scripts/resolve-codesign-identity.sh "$(CODESIGN_IDENTITY)" "$(CERT_NAME)")"; \
	  echo "Signing $@ with identity: $$id"; \
	  codesign --force --sign "$$id" "$@"; \
	fi

deployment-test: build/Talus.app
	@actual="$$(xcrun vtool -show-build build/Talus.app/Contents/MacOS/Talus | awk '$$1 == "minos" { print $$2 }')"; \
	test "$$actual" = "$(MACOS_DEPLOYMENT_TARGET)" || { echo "Expected macOS $(MACOS_DEPLOYMENT_TARGET), binary requires $$actual"; exit 1; }; \
	echo "Binary minimum macOS version verified: $$actual"

install: app
	pkill -TERM -x Talus || true
	sleep 0.6
	rm -rf /Applications/Talus.app
	cp -R build/Talus.app /Applications/Talus.app
	open -g /Applications/Talus.app </dev/null >/dev/null 2>&1

MANDIR ?= $(HOME)/.local/share/man

man-lint:
	mandoc -T lint -W warning man/talus.1 man/talus.toml.5

install-man: man-lint
	install -d "$(MANDIR)/man1" "$(MANDIR)/man5"
	install -m 644 man/talus.1 "$(MANDIR)/man1/talus.1"
	install -m 644 man/talus.toml.5 "$(MANDIR)/man5/talus.toml.5"
	@echo "Installed man pages to $(MANDIR) (view with: man -M $(MANDIR) talus)"

dist: build/Talus.app deployment-test
	rm -rf build/dist build/Talus-macos.zip
	mkdir -p build/dist
	cp -R build/Talus.app build/dist/Talus.app
	@id="$$(sh Scripts/resolve-codesign-identity.sh dist "$(CERT_NAME)")"; \
	echo "Signing distributable build/dist/Talus.app with identity: $$id"; \
	codesign --force --sign "$$id" build/dist/Talus.app
	ditto -c -k --keepParent build/dist/Talus.app build/Talus-macos.zip
	@echo "Built distributable archive: build/Talus-macos.zip"

settings-preview: build/Talus.app
	mkdir -p build/settings-previews
	build/Talus.app/Contents/MacOS/Talus --render-previews build/settings-previews

status-cleanup-test: build/talus
	Tests/Integration/command-cleanup.sh

integration-test: build/talus
	$(SWIFTC) Tests/Integration/Fixture.swift -o build/integration-fixture
	$(SWIFTC) Tests/Integration/Probe.swift -o build/integration-probe
	Tests/Integration/smoke.sh

# Opt-in: briefly registers only an isolated, signed test app via SMAppService.mainApp, then removes it.
launch-at-login-integration-test: build/Talus.app
	rm -rf build/LoginItemProbe.app
	mkdir -p build/LoginItemProbe.app/Contents/MacOS
	cp build/Talus.app/Contents/MacOS/Talus build/LoginItemProbe.app/Contents/MacOS/Probe
	cp Resources/Info.plist build/LoginItemProbe.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.talus.testing.login' build/LoginItemProbe.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Probe' build/LoginItemProbe.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleName Talus Login Test' build/LoginItemProbe.app/Contents/Info.plist
	codesign --force --sign - build/LoginItemProbe.app
	build/LoginItemProbe.app/Contents/MacOS/Probe --probe-login-item
