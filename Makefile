PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
PRODUCT = hex-cli
BUILD_DIR = .build/arm64-apple-macosx/release

.PHONY: build release test install uninstall clean

build:
	swift build

release:
	swift build -c release --disable-sandbox

test: build
	swift test

install: release
	install -d $(BINDIR)
	install -m 755 $(BUILD_DIR)/$(PRODUCT) $(BINDIR)/$(PRODUCT)

uninstall:
	rm -f $(BINDIR)/$(PRODUCT)

clean:
	swift package clean
	rm -rf .build

# Cut a release: `make tag VERSION=0.2.0`
tag:
	@test -n "$(VERSION)" || (echo "Usage: make tag VERSION=x.y.z" && exit 1)
	@sed -i '' 's/let hexCLIVersion = ".*"/let hexCLIVersion = "$(VERSION)"/' Sources/HexCLI/Version.swift
	git add Sources/HexCLI/Version.swift
	git commit -m "Bump version to $(VERSION)"
	git tag -a "v$(VERSION)" -m "v$(VERSION)"
	@echo "Tagged v$(VERSION). Push with: git push origin main --tags"
