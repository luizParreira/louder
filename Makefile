.DEFAULT_GOAL := help
.PHONY: help build test app run install dmg release-artifacts clean

help:
	@echo "Targets:"
	@echo "  build              swift build (debug)"
	@echo "  test               swift test"
	@echo "  app                build build/Louder.app (universal, ad-hoc signed)"
	@echo "  run                open build/Louder.app"
	@echo "  install            install build/Louder.app to /Applications (or ~/Applications)"
	@echo "  dmg                build app, then DMG, zip and checksums"
	@echo "  release-artifacts  app + dmg + zip + sha256 (incl. stable-named Louder.zip)"
	@echo "  clean              remove .build and build"

build:
	swift build

test:
	swift test

app:
	./scripts/bundle.sh

run: app
	open build/Louder.app

install: app
	./scripts/install-local.sh

dmg: app
	./scripts/make-dmg.sh

release-artifacts: dmg

clean:
	rm -rf .build build
