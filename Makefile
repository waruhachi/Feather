NAME := Feather
SCHEME := Feather
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)
TRANSPORT_CACHE := $(TMP)/transport
.NOTPARALLEL:
.PHONY: all clean dependencies transport $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

dependencies:
	sh tools/dependency-patches/apply.sh

transport:
	python3 tools/idevice-transport/build.py --cache "$(TRANSPORT_CACHE)"

iphoneos: transport

$(PLATFORMS): dependencies
	rm -rf _build

	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
		xcodebuild -resolvePackageDependencies -project Feather.xcodeproj -scheme $(SCHEME) -destination "$$DEST" -derivedDataPath "$(TMP)/$@" -onlyUsePackageVersionsFromResolvedFile && \
			python3 tools/idevice-transport/build.py --cache "$(TRANSPORT_CACHE)" --install-in "$(TMP)/$@" || exit $$?; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	xcodebuild \
		-project Feather.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		$(if $(filter iphoneos,$@),-disableAutomaticPackageResolution) \
		-skipPackagePluginValidation \
		$(if $(FEATHER_BUILD_NUMBER),FEATHER_BUILD_NUMBER="$(FEATHER_BUILD_NUMBER)") \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/Feather.app
	chmod -R 0755 _build/Payload/Feather.app
	@for extension in _build/Payload/Feather.app/PlugIns/*.appex; do \
		if [ -d "$$extension" ]; then codesign --force --sign - --timestamp=none "$$extension" || exit $$?; fi; \
	done
	@for framework in _build/Payload/Feather.app/Contents/Frameworks/*.framework; do \
		if [ -d "$$framework" ]; then codesign --force --sign - --timestamp=none "$$framework" || exit $$?; fi; \
	done
	codesign --force --sign - --timestamp=none _build/Payload/Feather.app

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/Feather.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/Feather.app "packages/Feather_Catalyst.zip"; \
	fi
