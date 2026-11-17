.PHONY: all clean app dist install setup-cert rust-test
CERT_NAME ?= Talus Local Code Signing
CODESIGN_IDENTITY ?= auto
CORE_LIB = Core/target/release/libtalus_core.a
CORE_HEADER = Core/include/talus_core.h
CORE_FLAGS = -import-objc-header $(CORE_HEADER) $(CORE_LIB)
CORE_SOURCES = Core/Cargo.toml $(wildcard Core/src/*.rs)

all: build/talus

$(CORE_LIB): $(CORE_SOURCES)
	cargo build --release --manifest-path Core/Cargo.toml

APP_SOURCES = Sources/main.swift Sources/Layout.swift Sources/WindowHistory.swift Sources/VirtualWorkspaces.swift Sources/TOML.swift Sources/Configuration.swift Sources/ScreenGeometry.swift Sources/StatusIcon.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusExport.swift Sources/StatusConfiguration.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Sources/StatusCommands.swift Sources/SettingsWindow.swift
build/talus: $(APP_SOURCES) $(CORE_LIB) $(CORE_HEADER)
	mkdir -p build
	swiftc -O $(APP_SOURCES) $(CORE_FLAGS) -framework Cocoa -framework SwiftUI -framework UniformTypeIdentifiers -framework Carbon -framework ApplicationServices -o $@
clean:
	rm -rf build
	cargo clean --manifest-path Core/Cargo.toml
rust-test:
	cargo test --manifest-path Core/Cargo.toml
test: rust-test $(CORE_LIB)
	mkdir -p build
	swiftc Sources/Layout.swift Tests/LayoutTests.swift $(CORE_FLAGS) -o build/layout-tests
	build/layout-tests
property-test: $(CORE_LIB)
	mkdir -p build
	swiftc -O Sources/Layout.swift Tests/LayoutProperties.swift $(CORE_FLAGS) -o build/layout-properties
	build/layout-properties
stack-test:
	mkdir -p build
	swiftc Sources/WindowStack.swift Tests/WindowStackTests.swift -o build/stack-tests
	build/stack-tests
XMONAD_SRC ?= ../xmonad-macos/src
xmonad-oracle:
	mkdir -p build/oracle
	ghc -O -i$(XMONAD_SRC) -outputdir build/oracle Tests/StackOracle.hs -o build/oracle/haskell
	swiftc Sources/WindowStack.swift Tests/StackOracle.swift -o build/oracle/swift
	build/oracle/haskell > build/oracle/expected
	build/oracle/swift > build/oracle/actual
	diff -u build/oracle/expected build/oracle/actual
history-test:
	mkdir -p build
	swiftc Sources/WindowHistory.swift Tests/WindowHistoryTests.swift -o build/history-tests
	build/history-tests
build/Talus.icns: Scripts/DrawAppIcon.swift
	mkdir -p build/Talus.iconset
	find build/Talus.iconset -type f -delete
	swift Scripts/DrawAppIcon.swift build/icon-master.png
	@for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do \
	  name=$${spec%:*}; size=$${spec#*:}; \
	  sips -z $$size $$size build/icon-master.png --out build/Talus.iconset/icon_$${name}.png >/dev/null; \
	done
	iconutil -c icns build/Talus.iconset -o $@
setup-cert:
	sh Scripts/setup-local-cert.sh "$(CERT_NAME)"
app: build/talus Resources/Info.plist build/Talus.icns
	mkdir -p build/Talus.app/Contents/MacOS build/Talus.app/Contents/Resources
	cp build/talus build/Talus.app/Contents/MacOS/Talus
	cp Resources/Info.plist build/Talus.app/Contents/Info.plist
	cp build/Talus.icns build/Talus.app/Contents/Resources/Talus.icns
	@id="$$(sh Scripts/resolve-codesign-identity.sh "$(CODESIGN_IDENTITY)" "$(CERT_NAME)")"; \
	echo "Signing build/Talus.app with identity: $$id"; \
	codesign --force --sign "$$id" build/Talus.app
install: app
	pkill -TERM -x Talus || true
	sleep 0.6
	rm -rf /Applications/Talus.app
	cp -R build/Talus.app /Applications/Talus.app
	open -g /Applications/Talus.app
dist: build/talus Resources/Info.plist build/Talus.icns
	rm -rf build/dist build/Talus-macos.zip
	mkdir -p build/dist/Talus.app/Contents/MacOS build/dist/Talus.app/Contents/Resources
	cp build/talus build/dist/Talus.app/Contents/MacOS/Talus
	cp Resources/Info.plist build/dist/Talus.app/Contents/Info.plist
	cp build/Talus.icns build/dist/Talus.app/Contents/Resources/Talus.icns
	@id="$$(sh Scripts/resolve-codesign-identity.sh dist "$(CERT_NAME)")"; \
	echo "Signing distributable build/dist/Talus.app with identity: $$id"; \
	codesign --force --sign "$$id" build/dist/Talus.app
	ditto -c -k --keepParent build/dist/Talus.app build/Talus-macos.zip
	@echo "Built distributable archive: build/Talus-macos.zip"
toml-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/TOML.swift Tests/TOMLTests.swift $(CORE_FLAGS) -o build/toml-tests
	build/toml-tests
config-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/TOML.swift Sources/Configuration.swift Sources/StatusConfiguration.swift Tests/ConfigurationTests.swift $(CORE_FLAGS) -o build/config-tests
	build/config-tests
settings-ui-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/TOML.swift Sources/Configuration.swift Sources/StatusConfiguration.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Sources/SettingsWindow.swift Tests/SettingsViewModelTests.swift $(CORE_FLAGS) -framework Cocoa -framework SwiftUI -framework UniformTypeIdentifiers -framework CoreGraphics -o build/settings-ui-tests
	build/settings-ui-tests
settings-window-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/TOML.swift Sources/Configuration.swift Sources/StatusConfiguration.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Sources/SettingsWindow.swift Tests/SettingsWindowLayoutTests.swift $(CORE_FLAGS) -framework Cocoa -framework SwiftUI -framework UniformTypeIdentifiers -framework CoreGraphics -o build/settings-window-tests
	build/settings-window-tests
test: settings-window-test
integration-test: all
	swiftc Tests/Integration/Fixture.swift -o build/integration-fixture
	swiftc Tests/Integration/Probe.swift -o build/integration-probe
	Tests/Integration/smoke.sh
virtual-workspace-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/VirtualWorkspaces.swift Tests/VirtualWorkspaceTests.swift $(CORE_FLAGS) -o build/virtual-workspace-tests
	build/virtual-workspace-tests
test: toml-test config-test settings-ui-test virtual-workspace-test history-test stack-test screen-test
multi-integration-test: all
	swiftc Tests/Integration/Fixture.swift -o build/integration-fixture
	swiftc Tests/Integration/MultiProbe.swift -o build/multi-probe
	Tests/Integration/multi.sh
latency-test: all
	swiftc Tests/Integration/EventFixture.swift -o build/event-fixture
	swiftc Tests/Integration/EventProbe.swift -o build/event-probe
	Tests/Integration/latency.sh
screen-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/ScreenGeometry.swift Tests/ScreenGeometryTests.swift $(CORE_FLAGS) -o build/screen-tests
	build/screen-tests
icon-test:
	mkdir -p build
	swiftc Sources/StatusIcon.swift Tests/StatusIconTests.swift -framework Cocoa -o build/icon-tests
	build/icon-tests
test: icon-test
status-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/Spaces.swift Sources/StatusText.swift Tests/StatusTextTests.swift $(CORE_FLAGS) -framework Cocoa -framework CoreGraphics -o build/status-tests
	build/status-tests
test: status-test
status-export-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/Spaces.swift Sources/StatusExport.swift Tests/StatusExportTests.swift $(CORE_FLAGS) -framework Cocoa -framework CoreGraphics -o build/status-export-tests
	build/status-export-tests
test: status-export-test
rich-status-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/TOML.swift Sources/Configuration.swift Sources/StatusConfiguration.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusExport.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Tests/StatusRichTests.swift $(CORE_FLAGS) -framework Cocoa -framework CoreGraphics -o build/rich-status-tests
	build/rich-status-tests
test: rich-status-test
status-command-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/TOML.swift Sources/Configuration.swift Sources/StatusConfiguration.swift Sources/StatusCommands.swift Tests/StatusCommandTests.swift $(CORE_FLAGS) -o build/status-command-tests
	build/status-command-tests
test: status-command-test
haskell-status-test: $(CORE_LIB)
	mkdir -p build
	swiftc Sources/TOML.swift Sources/Configuration.swift Sources/StatusConfiguration.swift Sources/StatusCommands.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusExport.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Tests/HaskellStatusIntegration.swift $(CORE_FLAGS) -framework Cocoa -framework CoreGraphics -o build/haskell-status-tests
	build/haskell-status-tests "$$(command -v runghc)" "$$PWD/Examples/clock.hs"
status-cleanup-test: all
	Tests/Integration/command-cleanup.sh
