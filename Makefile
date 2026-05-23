.PHONY: build install icon clean run notarize release verify dmg

build:
	@./scripts/build.sh

install: build
	@./scripts/install.sh

notarize: build
	@./scripts/notarize.sh

release: notarize dmg
	@echo ""
	@echo "Release listo: build/ClipShot.app + build/ClipShot-*.dmg"

dmg:
	@./scripts/make_dmg.sh

verify:
	@codesign --verify --deep --strict --verbose=2 build/ClipShot.app
	@spctl --assess --type execute --verbose build/ClipShot.app

icon:
	@./scripts/regen_icon.sh

clean:
	@rm -rf build/

run: install
	@open /Applications/ClipShot.app
