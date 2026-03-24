PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
FISH_COMPLETIONS_DIR ?= $(PREFIX)/share/fish/vendor_completions.d
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
	install -d $(FISH_COMPLETIONS_DIR)
	install -m 644 completions/$(PRODUCT).fish $(FISH_COMPLETIONS_DIR)/$(PRODUCT).fish

uninstall:
	rm -f $(BINDIR)/$(PRODUCT)
	rm -f $(FISH_COMPLETIONS_DIR)/$(PRODUCT).fish

clean:
	swift package clean
	rm -rf .build

# Add a changeset: `make changeset TYPE=patch MSG="Fix thing"`
changeset:
	@test -n "$(TYPE)" -a -n "$(MSG)" || (echo "Usage: make changeset TYPE=patch|minor|major MSG=\"description\"" && exit 1)
	bun run tools/add-changeset.ts $(TYPE) $(MSG)

# Consume changesets, bump version, update CHANGELOG, tag
release-prep:
	bun run tools/release.ts
	@echo "Push with: git push origin main --tags"

release-prep-dry:
	bun run tools/release.ts --dry-run
