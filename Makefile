PREFIX ?= $(HOME)/.local/bin
BINARY := .build/release/touchrun

.PHONY: build test install uninstall clean

build:
	swift build -c release

test:
	swift run TouchRunTests

install: build
	mkdir -p "$(PREFIX)"
	cp "$(BINARY)" "$(PREFIX)/touchrun"
	codesign --force --sign - "$(PREFIX)/touchrun"
	@echo "Installed to $(PREFIX)/touchrun"

uninstall:
	rm -f "$(PREFIX)/touchrun"

clean:
	swift package clean
