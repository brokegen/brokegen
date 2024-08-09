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

.PHONY: build-xcode
build: build-xcode
build-xcode: server-onedir
build-xcode:
	xcodebuild archive \
		-quiet \
		-project xcode/Brokegen.xcodeproj \
		-scheme Debug \
		-config Debug \
		-sdk macosx \
		-archivePath build/"macOS App.xcarchive" \
		-derivedDataPath build/xcode-derived-data/ \
		-destination 'generic/platform=macOS'

.PHONY: dist/Brokegen.app.tzst
dist: dist/Brokegen.app.tzst
dist/Brokegen.app.tzst: build-xcode-release
dist/Brokegen.app.tzst: build/xcode-macos-export-options.plist
	xcodebuild -quiet \
		-exportArchive \
		-archivePath build/"macOS App (Release).xcarchive" \
		-exportPath dist/ \
		-exportOptionsPlist build/xcode-macos-export-options.plist
	cd dist \
		&& tar cvf Brokegen.app.tzst --zstd --options zstd:compression-level=22 Brokegen.app
	rm -rf dist/Brokegen.app

.PHONY: build-xcode-release
build: build-xcode-release
build-xcode-release: server-onefile
build-xcode-release:
	xcodebuild archive \
		-quiet \
		-project xcode/Brokegen.xcodeproj \
		-scheme Release \
		-config Release \
		-sdk macosx \
		-archivePath build/"macOS App (Release).xcarchive" \
		-derivedDataPath build/xcode-derived-data/ \
		-destination 'generic/platform=macOS'

.PHONY: clean-xcode
clean: clean-xcode
clean-xcode:
	rm -rf build/xcode-derived-data/
	rm -rf build/"macOS App.xcarchive"/
	rm -rf build/"macOS App.xcarchive"/
	rm -f build/xcode-macos-export-options.plist
	rm -rf dist/Brokegen.app
