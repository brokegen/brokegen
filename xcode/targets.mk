define nosign_export_options
endef

build/xcode-macos-export-options.plist:
	plutil -create xml1 "$@"
	plutil -insert "method" -string "mac-application" "$@"

.PHONY: dist-xcode
dist: dist-xcode
dist-xcode: build-xcode
dist-xcode: build/xcode-macos-export-options.plist
	xcodebuild \
			-exportArchive \
			-archivePath build/"macOS App.xcarchive" \
			-exportPath dist/ \
			-exportOptionsPlist build/xcode-macos-export-options.plist

.PHONY: build-xcode
build: build-xcode
build-xcode: server ollama-proxy
build-xcode:
	xcodebuild archive \
		-project xcode/Brokegen.xcodeproj \
		-scheme Release \
		-config Release \
		-sdk macosx \
		-archivePath build/"macOS App.xcarchive" \
		-derivedDataPath build/xcode-derived-data/

.PHONY: run-xcode
run-xcode:
	@:

.PHONY: clean-xcode
clean: clean-xcode
clean-xcode:
	rm -rf build/xcode-derived-data/
	rm -rf build/"macOS App.xcarchive"/
	rm -f build/xcode-macos-export-options.plist
	rm -rf dist/Brokegen.app
