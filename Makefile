# Rosy Bit — build wherever there is a Swift toolchain.
#
# Two supported routes:
#
#   On the M4, with full Xcode. Builds universal, so the result runs on both
#   machines and can be exercised locally before it is copied to Rosy. Xcode 27
#   is Apple Silicon only, but the macOS SDK is still Universal for back
#   deployment, so targeting Rosy from here is a normal supported path.
#
#   On Rosy, with only the Command Line Tools. A universal build needs XCBuild,
#   which ships inside full Xcode; without it SwiftPM builds the host
#   architecture alone. That is all Rosy needs, and it skips the copy, the
#   quarantine and the lipo check entirely.
#
# Which one happens is detected below. Force either with UNIVERSAL=1 or 0.
#
#   make bootstrap   fetch llama-server
#   make app         build dist/RosyBit.app (ad-hoc signed)
#   make dist        zip it for copying to Rosy
#   make clean

APP_NAME   := RosyBit
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
CONTENTS   := $(APP)/Contents
ICONS      := Support/icons
ICONSET    := $(ICONS)/AppIcon.iconset
ICNS       := $(ICONS)/AppIcon.icns

# Passing --arch twice routes SwiftPM through XCBuild, which only exists inside
# full Xcode — with the Command Line Tools alone it fails with "xcbuild
# executable ... does not exist". So ask what the toolchain actually is rather
# than assuming, and fall back to a host-architecture build, which is a
# perfectly good app for the machine building it.
#
# At deployment target 13.0 x86_64 is included by default anyway — we are
# nowhere near the macOS 27 threshold where ARCHS_STANDARD quietly drops it —
# but state it rather than trust it.
DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
ifeq ($(origin UNIVERSAL), undefined)
  ifneq (,$(findstring Xcode.app,$(DEVELOPER_DIR)))
    UNIVERSAL := 1
  else
    UNIVERSAL := 0
  endif
endif

ifeq ($(UNIVERSAL),1)
  SWIFTFLAGS := -c release --arch x86_64 --arch arm64
else
  SWIFTFLAGS := -c release
endif

.PHONY: all app icons dist run clean bootstrap check-vendor verify

all: app

bootstrap:
	./scripts/fetch-llama-server.sh

icons: $(ICNS)

$(ICNS): $(wildcard $(ICONSET)/*.png)
	iconutil -c icns "$(ICONSET)" -o "$(ICNS)"

check-vendor:
	@if [ ! -x vendor/x86_64/llama-server ] && [ ! -x vendor/arm64/llama-server ]; then \
		echo "error: vendor/ is empty."; \
		echo "       run ./scripts/fetch-llama-server.sh first"; \
		exit 1; \
	fi
	@if [ ! -x vendor/x86_64/llama-server ]; then \
		echo "WARNING: no Intel slice in vendor/ — this build will not serve on Rosy."; \
	fi

app: check-vendor icons
	@if [ "$(UNIVERSAL)" = "1" ]; then \
		echo "building universal (full Xcode at $(DEVELOPER_DIR))"; \
	else \
		echo "building for $$(uname -m) only — Command Line Tools have no XCBuild."; \
		echo "  fine if this machine is the one that will run it;"; \
		echo "  for a universal build use a Mac with full Xcode."; \
	fi
	swift build $(SWIFTFLAGS)
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources/llama"
	@cp "$$(swift build $(SWIFTFLAGS) --show-bin-path)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@cp Support/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@cp "$(ICNS)" "$(CONTENTS)/Resources/AppIcon.icns"
	@cp "$(ICONS)/MenuBarIcon.png" "$(ICONS)/MenuBarIcon@2x.png" "$(CONTENTS)/Resources/"
	@# Stage only the slices the app itself has. A host-only build has no use
	@# for the other architecture's llama-server, and it is 55MB of dead weight.
	@for arch in $$(lipo -archs "$(CONTENTS)/MacOS/$(APP_NAME)"); do \
		if [ -d "vendor/$$arch" ]; then \
			cp -R "vendor/$$arch" "$(CONTENTS)/Resources/llama/$$arch"; \
		else \
			echo "WARNING: app has a $$arch slice but vendor/$$arch is missing"; \
		fi; \
	done
	@echo "signing (ad-hoc) ..."
	@find "$(CONTENTS)/Resources/llama" -type f \( -name 'llama-server' -o -name '*.dylib' \) \
		-exec codesign --force --timestamp=none --sign - {} \;
	@codesign --force --timestamp=none --sign - "$(APP)"
	@$(MAKE) --no-print-directory verify
	@echo "built $(APP)"

# Gotcha: an app that is not Intel-capable fails on Rosy in a way that looks
# like a Gatekeeper problem. Catch it here instead.
verify:
	@archs="$$(lipo -archs "$(CONTENTS)/MacOS/$(APP_NAME)")"; \
	echo "  app archs      : $$archs"; \
	case "$$archs" in *x86_64*) ;; *) \
		echo "  NOTE           : no x86_64 slice — fine here, but not for Rosy."; \
		echo "                   make dist refuses to package this." ;; esac
	@for arch in x86_64 arm64; do \
		binary="$(CONTENTS)/Resources/llama/$$arch/llama-server"; \
		if [ -x "$$binary" ]; then \
			echo "  llama-server   : $$arch $$(lipo -archs "$$binary")"; \
		else \
			echo "  llama-server   : $$arch MISSING"; \
		fi; \
	done
	@codesign --verify --strict "$(APP)" && echo "  signature      : ok"

# `make app` tolerates an arm64-only bundle so the UI can be exercised on the
# M4. The zip is what actually goes to Rosy, so it does not.
dist: app
	@archs="$$(lipo -archs "$(CONTENTS)/MacOS/$(APP_NAME)")"; \
	case "$$archs" in *x86_64*) ;; *) \
		echo "error: app has no x86_64 slice ($$archs) — it cannot run on Rosy."; \
		echo "       build with full Xcode for universal, or build on Rosy itself."; \
		exit 1 ;; esac
	@if [ ! -x "$(CONTENTS)/Resources/llama/x86_64/llama-server" ]; then \
		echo "error: no Intel llama-server in the bundle — this cannot serve on Rosy."; \
		echo "       run ./scripts/fetch-llama-server.sh x86_64 && make app"; \
		exit 1; \
	fi
	cd "$(DIST)" && ditto -c -k --sequesterRsrc --keepParent \
		"$(APP_NAME).app" "$(APP_NAME).zip"
	@echo "packaged $(DIST)/$(APP_NAME).zip"

run: app
	open "$(APP)"

clean:
	rm -rf .build "$(DIST)" "$(ICNS)"
