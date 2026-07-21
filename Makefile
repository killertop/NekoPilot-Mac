.PHONY: help sidecar dev test check build hooks bump clean

help:
	@echo "Available targets:"
	@echo "  sidecar  Build pinned upstream sing-box for Apple Silicon"
	@echo "  dev      Start the native SwiftUI/AppKit application"
	@echo "  test     Run Swift unit and native core checks"
	@echo "  check    Enforce the Swift/Go Apple Silicon architecture"
	@echo "  build    Build and verify the native Apple Silicon package"
	@echo "  hooks    Install repository-local Swift build/test hooks"
	@echo "  bump     Increment native/VERSION patch number"
	@echo "  clean    Remove generated Swift and package outputs"

sidecar:
	native/scripts/build-sing-box-macos-arm64.sh

dev: sidecar
	NEKOPILOT_SING_BOX="$(CURDIR)/native/.build/sidecar/sing-box" swift run --package-path native NekoPilot

test:
	swift build --package-path native
	swift test --package-path native
	swift run --package-path native NekoPilotCoreChecks

check:
	native/scripts/check-release-policy.sh

build: sidecar check
	native/scripts/package-macos.sh

hooks:
	native/scripts/install-git-hooks.sh

bump:
	native/scripts/version.sh --bump-patch

clean:
	swift package --package-path native clean
	rm -rf -- native/dist
