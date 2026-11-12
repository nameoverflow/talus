.PHONY: all clean
all: build/talus
build/talus: Sources/main.swift Sources/Layout.swift Sources/WindowHistory.swift Sources/Configuration.swift
	mkdir -p build
	swiftc -O Sources/main.swift Sources/Layout.swift Sources/WindowHistory.swift Sources/Configuration.swift -framework Cocoa -framework Carbon -framework ApplicationServices -o $@
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
workspace-test:
	mkdir -p build
	swiftc Sources/WindowStack.swift Sources/Workspaces.swift Tests/WorkspaceTests.swift -o build/workspace-tests
	build/workspace-tests
history-test:
	mkdir -p build
	swiftc Sources/WindowHistory.swift Tests/WindowHistoryTests.swift -o build/history-tests
	build/history-tests
app: build/talus Resources/Info.plist
	mkdir -p build/Talus.app/Contents/MacOS
	cp build/talus build/Talus.app/Contents/MacOS/Talus
	cp Resources/Info.plist build/Talus.app/Contents/Info.plist
	codesign --force --sign - build/Talus.app
config-test:
	mkdir -p build
	swiftc Sources/Configuration.swift Tests/ConfigurationTests.swift -o build/config-tests
	build/config-tests
integration-test: all
	swiftc Tests/Integration/Fixture.swift -o build/integration-fixture
	swiftc Tests/Integration/Probe.swift -o build/integration-probe
	Tests/Integration/smoke.sh
test: config-test history-test stack-test workspace-test
