.PHONY: all clean
all: build/swiftmonad
build/swiftmonad: Sources/main.swift Sources/Layout.swift
	mkdir -p build
	swiftc -O Sources/main.swift Sources/Layout.swift -framework Cocoa -framework Carbon -framework ApplicationServices -o $@
clean:
	rm -rf build
test:
	mkdir -p build
	swiftc Sources/Layout.swift Tests/LayoutTests.swift -o build/layout-tests
	build/layout-tests
