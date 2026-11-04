# ModelThumbs build, verify and install.
#
#   make build            compile and sign into build/ (no network, nothing outside build/)
#   make build CAD=1      also add STEP / IGES / BREP (needs: brew install opencascade)
#   make verify           check the signed bundle, then test it inside a sandbox
#   make test-asan        run the malformed-file tests under AddressSanitizer
#   make install          verify, then copy to ~/Applications and register the extension
#   make check-quicklook  ask Quick Look for real thumbnails of the samples
#   make uninstall        remove the installed copy
#
# Preview any step before running it: make -n <target>
#
# These targets never download or install anything, never remove quarantine flags, and
# never use a signing certificate unless you pass one with SIGN="<identity>".

APP_NAME := ModelThumbs
EXT_NAME := ModelThumbsThumbnailer
EXT_ID   := com.modelthumbs.app.thumbnailer
PREVIEW_NAME := ModelThumbsPreviewer
PREVIEW_ID   := com.modelthumbs.app.previewer

BUILD := build
OBJ   := $(BUILD)/obj
APP   := $(BUILD)/$(APP_NAME).app
EXT   := $(APP)/Contents/PlugIns/$(EXT_NAME).appex
PREVIEW := $(APP)/Contents/PlugIns/$(PREVIEW_NAME).appex

PREFIX ?= $(HOME)/Applications
DEST   := $(PREFIX)/$(APP_NAME).app
SIGN   ?= -
CAD    ?= 0

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

ARCH   := $(shell uname -m)
SDK    := $(shell xcrun --sdk macosx --show-sdk-path)
MIN_OS := 13.0

CORE := $(wildcard Sources/Core/*.swift)
OCCT_LIBS := TKernel TKMath TKG2d TKG3d TKGeomBase TKBRep TKGeomAlgo TKTopAlgo TKMesh TKShHealing \
             TKXSBase TKDE TKDESTEP TKDEIGES TKSTEP TKSTEPBase TKSTEP209 TKSTEPAttr TKIGES

CAD_SWIFT :=
ifeq ($(CAD),1)
  OCCT ?= $(shell brew --prefix opencascade 2>/dev/null)
  # Homebrew libraries target the running macOS.
  MIN_OS := $(shell sw_vers -productVersion | cut -d. -f1).0
  CAD_LIBS := $(foreach l,$(OCCT_LIBS),$(if $(wildcard $(OCCT)/lib/lib$(l).dylib),-l$(l)))
  CAD_SWIFT := -D MT_HAS_OCCT -import-objc-header Sources/CAD/mt_cad.h Sources/CAD/CADLoader.swift \
               $(OBJ)/mt_cad.o -L$(OCCT)/lib $(CAD_LIBS) -lc++
endif

TARGET := $(ARCH)-apple-macos$(MIN_OS)
SWIFTC := swiftc -O -wmo -swift-version 5 -target $(TARGET) -sdk $(SDK)

.PHONY: build verify test-asan install check-quicklook uninstall clean

build:
	rm -rf $(BUILD)
	mkdir -p $(OBJ)
ifeq ($(CAD),1)
	@test -d "$(OCCT)/include/opencascade" || { echo "OpenCASCADE not found. Install it first: brew install opencascade"; exit 1; }
	clang++ -std=c++17 -O2 -target $(TARGET) -isysroot $(SDK) -I$(OCCT)/include/opencascade -c Sources/CAD/mt_cad.cpp -o $(OBJ)/mt_cad.o -w
endif
	swiftc -O -target $(ARCH)-apple-macos13.0 -sdk $(SDK) Tools/uticheck.swift -o $(OBJ)/uticheck
	$(OBJ)/uticheck $$(python3 -I Tools/file_types.py exts $(CAD)) > $(BUILD)/system-types.txt
	$(SWIFTC) -module-name $(EXT_NAME) -parse-as-library -application-extension $(CORE) Sources/Extension/*.swift $(CAD_SWIFT) \
	  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -headerpad_max_install_names -o $(OBJ)/$(EXT_NAME)
	$(SWIFTC) -module-name $(PREVIEW_NAME) -parse-as-library -application-extension $(CORE) Sources/Preview/*.swift $(CAD_SWIFT) \
	  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -headerpad_max_install_names -o $(OBJ)/$(PREVIEW_NAME)
	$(SWIFTC) -module-name $(APP_NAME) Sources/App/main.swift -o $(OBJ)/$(APP_NAME)
	$(SWIFTC) -module-name modelthumbs_render $(CORE) Sources/CLI/main.swift $(CAD_SWIFT) \
	  -Xlinker -headerpad_max_install_names -o $(OBJ)/modelthumbs-render
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(EXT)/Contents/MacOS $(PREVIEW)/Contents/MacOS
	cp $(OBJ)/$(APP_NAME) $(OBJ)/modelthumbs-render $(APP)/Contents/MacOS/
	cp $(OBJ)/$(EXT_NAME) $(EXT)/Contents/MacOS/
	cp $(OBJ)/$(PREVIEW_NAME) $(PREVIEW)/Contents/MacOS/
	python3 -I Tools/file_types.py plists $(CAD) $(BUILD)/system-types.txt $(MIN_OS) $(APP)/Contents/Info.plist $(EXT)/Contents/Info.plist $(PREVIEW)/Contents/Info.plist
	plutil -lint $(APP)/Contents/Info.plist $(EXT)/Contents/Info.plist $(PREVIEW)/Contents/Info.plist
ifeq ($(CAD),1)
	python3 -I Tools/bundle_dylibs.py $(EXT)/Contents/MacOS/$(EXT_NAME) $(EXT)/Contents/Frameworks @executable_path/../Frameworks \
	  $(APP)/Contents/MacOS/modelthumbs-render=@executable_path/../PlugIns/$(EXT_NAME).appex/Contents/Frameworks \
	  $(PREVIEW)/Contents/MacOS/$(PREVIEW_NAME)=@executable_path/../../../$(EXT_NAME).appex/Contents/Frameworks
	find $(EXT)/Contents/Frameworks -name '*.dylib' -exec codesign --force --sign "$(SIGN)" --timestamp=none {} +
endif
	codesign --force --sign "$(SIGN)" --timestamp=none --entitlements Resources/Extension.entitlements $(EXT)
	codesign --force --sign "$(SIGN)" --timestamp=none --entitlements Resources/Extension.entitlements $(PREVIEW)
	codesign --force --sign "$(SIGN)" --timestamp=none $(APP)/Contents/MacOS/modelthumbs-render
	codesign --force --sign "$(SIGN)" --timestamp=none $(APP)
	@echo "Built $(APP). Next: make verify"

verify:
	python3 -I Tools/verify.py $(APP)

# Built without OpenCASCADE: this tests the project's own parsers.
test-asan:
	mkdir -p $(BUILD)/asan
	cd $(BUILD)/asan && swiftc -O -wmo -swift-version 5 -sanitize=address -g -target $(ARCH)-apple-macos13.0 -sdk $(SDK) \
	  -module-name modelthumbs_render $(addprefix $(CURDIR)/,$(CORE)) $(CURDIR)/Sources/CLI/main.swift -o modelthumbs-render-asan
	python3 -I Tools/verify.py --malformed-only $(BUILD)/asan/modelthumbs-render-asan

install: verify
	mkdir -p "$(PREFIX)"
	test ! -d "$(DEST)" || pluginkit -r "$(DEST)/Contents/PlugIns/$(EXT_NAME).appex"
	test ! -d "$(DEST)/Contents/PlugIns/$(PREVIEW_NAME).appex" || pluginkit -r "$(DEST)/Contents/PlugIns/$(PREVIEW_NAME).appex"
	test ! -d "$(DEST)" || $(LSREGISTER) -u "$(DEST)"
	rm -rf "$(DEST)"
	ditto $(APP) "$(DEST)"
	$(LSREGISTER) -f -R "$(DEST)"
	pluginkit -a "$(DEST)/Contents/PlugIns/$(EXT_NAME).appex" "$(DEST)/Contents/PlugIns/$(PREVIEW_NAME).appex"
	# Registration isn't instant, and the first add can be dropped right after lsregister.
	sleep 3
	pluginkit -a "$(DEST)/Contents/PlugIns/$(EXT_NAME).appex" "$(DEST)/Contents/PlugIns/$(PREVIEW_NAME).appex"
	sleep 2
	pluginkit -e use -i $(EXT_ID)
	pluginkit -e use -i $(PREVIEW_ID)
	sleep 1
	pluginkit -m -i $(EXT_ID) | grep -q '^+' || { echo "The thumbnail extension didn't register. See Troubleshooting in README.md"; exit 1; }
	pluginkit -m -i $(PREVIEW_ID) | grep -q '^+' || { echo "The preview extension didn't register. See Troubleshooting in README.md"; exit 1; }
	qlmanage -r
	qlmanage -r cache
	@echo "Installed to $(DEST). Next: make check-quicklook"

# Asks Quick Look for a thumbnail of every sample, the same way Finder does.
check-quicklook:
	mkdir -p $(BUILD)/quicklook
	swiftc -O -target $(ARCH)-apple-macos13.0 -sdk $(SDK) Tools/qlcheck.swift -o $(OBJ)/qlcheck
	$(OBJ)/qlcheck $(BUILD)/quicklook Samples/*

uninstall:
	test ! -d "$(DEST)" || pluginkit -r "$(DEST)/Contents/PlugIns/$(EXT_NAME).appex"
	test ! -d "$(DEST)/Contents/PlugIns/$(PREVIEW_NAME).appex" || pluginkit -r "$(DEST)/Contents/PlugIns/$(PREVIEW_NAME).appex"
	test ! -d "$(DEST)" || $(LSREGISTER) -u "$(DEST)"
	rm -rf "$(DEST)"
	qlmanage -r
	qlmanage -r cache

clean:
	rm -rf $(BUILD)
