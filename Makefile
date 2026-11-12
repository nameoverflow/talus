.PHONY: all clean
all: build/talus
build/talus: Sources/main.swift Sources/Layout.swift
	mkdir -p build
	swiftc -O Sources/main.swift Sources/Layout.swift -framework Cocoa -framework Carbon -framework ApplicationServices -o $@
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
