define nosign_export_options
endef

build/xcode-macos-export-options.plist:
	[ -d build/ ] || mkdir build/
	plutil -create xml1 "$@"
	plutil -insert "method" -string "mac-application" "$@"

.PHONY: dist-xcode
dist-xcode: build-xcode
dist-xcode: build/xcode-macos-export-options.plist
	xcodebuild -quiet \
		-exportArchive \
		-archivePath build/"macOS App.xcarchive" \
		-exportPath dist/ \
		-exportOptionsPlist build/xcode-macos-export-options.plist
	# TODO: This clean-up should be less manual. Or within the xcode build.
	rm dist/Brokegen.app/Contents/Resources/brokegen-server
	rm dist/Brokegen.app/Contents/Resources/ollama-darwin
	rm -rf dist/"Brokegen (Debug)".app
	mv dist/Brokegen.app dist/"Brokegen (Debug)".app

.PHONY: build-xcode
build: build-xcode
build-xcode: server
build-xcode:
	xcodebuild archive \
		-quiet \
		-project xcode/Brokegen.xcodeproj \
		-scheme Debug \
		-config Debug \
		-sdk macosx \
		-archivePath build/"macOS App.xcarchive" \
		-derivedDataPath build/xcode-derived-data/

.PHONY: dist-xcode-release
dist: dist-xcode-release
dist-xcode-release: build-xcode-release
dist-xcode-release: build/xcode-macos-export-options.plist
	xcodebuild -quiet \
		-exportArchive \
		-archivePath build/"macOS App (Release).xcarchive" \
		-exportPath dist/ \
		-exportOptionsPlist build/xcode-macos-export-options.plist
	# TODO: This clean-up should be less manual. Or within the xcode build.
	rm -rf dist/"Brokegen (Release)".app
	mv dist/Brokegen.app dist/"Brokegen (Release)".app

.PHONY: build-xcode-release
build: build-xcode-release
build-xcode-release: server
build-xcode-release:
	xcodebuild archive \
		-quiet \
		-project xcode/Brokegen.xcodeproj \
		-scheme Release \
		-config Release \
		-sdk macosx \
		-archivePath build/"macOS App (Release).xcarchive" \
		-derivedDataPath build/xcode-derived-data/

.PHONY: clean-xcode
clean: clean-xcode
clean-xcode:
	rm -rf build/xcode-derived-data/
	rm -rf build/"macOS App.xcarchive"/
	rm -rf build/"macOS App.xcarchive"/
	rm -f build/xcode-macos-export-options.plist
	rm -rf dist/Brokegen.app
