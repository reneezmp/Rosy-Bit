# Rosy Bit — build on the M4, run on Rosy.
#
# Xcode 27 is Apple Silicon only, so the app is built on the M4 and the .app is
# copied across. The macOS SDK is still Universal for back deployment, so this
# is a normal supported path, not a hack.
#
#   make bootstrap   fetch llama-server for both architectures
#   make app         build dist/RosyBit.app (universal, ad-hoc signed)
#   make dist        zip it for copying to Rosy
#   make clean

APP_NAME   := RosyBit
DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
CONTENTS   := $(APP)/Contents
ICONS      := Support/icons
ICONSET    := $(ICONS)/AppIcon.iconset
ICNS       := $(ICONS)/AppIcon.icns

# x86_64 is what Rosy needs; arm64 lets the whole thing be tested on the M4
# before it is copied anywhere. At deployment target 13.0 this is the default
# anyway — we are nowhere near the macOS 27 threshold where ARCHS_STANDARD
# quietly drops x86_64 — but state it rather than trust it.
SWIFTFLAGS := -c release --arch x86_64 --arch arm64

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
	swift build $(SWIFTFLAGS)
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources/llama"
	@cp "$$(swift build $(SWIFTFLAGS) --show-bin-path)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@cp Support/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@cp "$(ICNS)" "$(CONTENTS)/Resources/AppIcon.icns"
	@cp "$(ICONS)/MenuBarIcon.png" "$(ICONS)/MenuBarIcon@2x.png" "$(CONTENTS)/Resources/"
	@for arch in x86_64 arm64; do \
		if [ -d "vendor/$$arch" ]; then \
			cp -R "vendor/$$arch" "$(CONTENTS)/Resources/llama/$$arch"; \
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
	case "$$archs" in *x86_64*) ;; *) echo "error: no x86_64 slice"; exit 1 ;; esac
	@for arch in x86_64 arm64; do \
		binary="$(CONTENTS)/Resources/llama/$$arch/llama-server"; \
		if [ -x "$$binary" ]; then \
			echo "  llama-server   : $$arch $$(lipo -archs "$$binary")"; \
		fi; \
	done
	@codesign --verify --strict "$(APP)" && echo "  signature      : ok"

dist: app
	cd "$(DIST)" && ditto -c -k --sequesterRsrc --keepParent \
		"$(APP_NAME).app" "$(APP_NAME).zip"
	@echo "packaged $(DIST)/$(APP_NAME).zip"

run: app
	open "$(APP)"

clean:
	rm -rf .build "$(DIST)" "$(ICNS)"
