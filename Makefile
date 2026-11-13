.PHONY: all clean
all: build/talus
build/talus: Sources/main.swift Sources/Layout.swift Sources/WindowHistory.swift Sources/Configuration.swift Sources/ScreenGeometry.swift Sources/StatusIcon.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusExport.swift Sources/StatusConfiguration.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Sources/StatusCommands.swift
	mkdir -p build
	swiftc -O Sources/main.swift Sources/Layout.swift Sources/WindowHistory.swift Sources/Configuration.swift Sources/ScreenGeometry.swift Sources/StatusIcon.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusExport.swift Sources/StatusConfiguration.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Sources/StatusCommands.swift -framework Cocoa -framework Carbon -framework ApplicationServices -o $@
clean:
	rm -rf build
test:
	mkdir -p build
	swiftc Sources/Layout.swift Tests/LayoutTests.swift -o build/layout-tests
	build/layout-tests
property-test:
	mkdir -p build
	swiftc -O Sources/Layout.swift Tests/LayoutProperties.swift -o build/layout-properties
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
app: build/talus Resources/Info.plist build/Talus.icns
	mkdir -p build/Talus.app/Contents/MacOS build/Talus.app/Contents/Resources
	cp build/talus build/Talus.app/Contents/MacOS/Talus
	cp Resources/Info.plist build/Talus.app/Contents/Info.plist
	cp build/Talus.icns build/Talus.app/Contents/Resources/Talus.icns
	codesign --force --sign - build/Talus.app
config-test:
	mkdir -p build
	swiftc Sources/Configuration.swift Sources/StatusConfiguration.swift Tests/ConfigurationTests.swift -o build/config-tests
	build/config-tests
integration-test: all
	swiftc Tests/Integration/Fixture.swift -o build/integration-fixture
	swiftc Tests/Integration/Probe.swift -o build/integration-probe
	Tests/Integration/smoke.sh
test: config-test history-test stack-test screen-test
multi-integration-test: all
	swiftc Tests/Integration/Fixture.swift -o build/integration-fixture
	swiftc Tests/Integration/MultiProbe.swift -o build/multi-probe
	Tests/Integration/multi.sh
latency-test: all
	swiftc Tests/Integration/EventFixture.swift -o build/event-fixture
	swiftc Tests/Integration/EventProbe.swift -o build/event-probe
	Tests/Integration/latency.sh
screen-test:
	mkdir -p build
	swiftc Sources/ScreenGeometry.swift Tests/ScreenGeometryTests.swift -o build/screen-tests
	build/screen-tests
icon-test:
	mkdir -p build
	swiftc Sources/StatusIcon.swift Tests/StatusIconTests.swift -framework Cocoa -o build/icon-tests
	build/icon-tests
test: icon-test
status-test:
	mkdir -p build
	swiftc Sources/Spaces.swift Sources/StatusText.swift Tests/StatusTextTests.swift -framework Cocoa -framework CoreGraphics -o build/status-tests
	build/status-tests
test: status-test
status-export-test:
	mkdir -p build
	swiftc Sources/Spaces.swift Sources/StatusExport.swift Tests/StatusExportTests.swift -framework Cocoa -framework CoreGraphics -o build/status-export-tests
	build/status-export-tests
test: status-export-test
rich-status-test:
	mkdir -p build
	swiftc Sources/Configuration.swift Sources/StatusConfiguration.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusExport.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Tests/StatusRichTests.swift -framework Cocoa -framework CoreGraphics -o build/rich-status-tests
	build/rich-status-tests
test: rich-status-test
status-command-test:
	mkdir -p build
	swiftc Sources/Configuration.swift Sources/StatusConfiguration.swift Sources/StatusCommands.swift Tests/StatusCommandTests.swift -o build/status-command-tests
	build/status-command-tests
test: status-command-test
haskell-status-test:
	mkdir -p build
	swiftc Sources/Configuration.swift Sources/StatusConfiguration.swift Sources/StatusCommands.swift Sources/Spaces.swift Sources/StatusText.swift Sources/StatusExport.swift Sources/StatusRich.swift Sources/StatusMarkup.swift Tests/HaskellStatusIntegration.swift -framework Cocoa -framework CoreGraphics -o build/haskell-status-tests
	build/haskell-status-tests "$$(command -v runghc)" "$$PWD/Examples/clock.hs"
status-cleanup-test: all
	Tests/Integration/command-cleanup.sh
