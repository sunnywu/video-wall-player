PROJECT := sixplayer.xcodeproj
SCHEME := sixplayer
CONFIGURATION := Release
BUILD_DIR := $(CURDIR)/build

.PHONY: build binary run package seltest selftest render whitespace clean

build:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -derivedDataPath "$(BUILD_DIR)/DerivedData" CONFIGURATION_BUILD_DIR="$(BUILD_DIR)"

binary: build
	cp "$(BUILD_DIR)/sixplayer.app/Contents/MacOS/sixplayer" "$(CURDIR)/sixplayer"

run: build
	open "$(BUILD_DIR)/sixplayer.app"

package:
	./scripts/package_app.sh

seltest:
	./run.sh seltest

selftest:
	./run.sh selftest

droptest:
	./run.sh droptest

render:
	./run.sh render

whitespace:
	./scripts/check_whitespace.sh

clean:
	rm -rf "$(BUILD_DIR)" "$(CURDIR)/dist"
