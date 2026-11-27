.PHONY: all clean app dist install setup-cert test check deployment-test settings-preview status-cleanup-test integration-test

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
	@id="$$(sh Scripts/resolve-codesign-identity.sh "$(CODESIGN_IDENTITY)" "$(CERT_NAME)")"; \
	echo "Signing $@ with identity: $$id"; \
	codesign --force --sign "$$id" "$@"

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
