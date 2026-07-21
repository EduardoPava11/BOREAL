# BOREAL — top-level build wrapper.
#
# This Makefile is the canonical entry point for building, testing,
# and bootstrapping the project. Every target shells out to the
# underlying tools (xcodegen, xcodebuild, swiftc) so nothing here
# duplicates real build logic — it's a documented surface that says
# "here is how this app is built."
#
# Quick reference:
#   make setup         — verify prereqs + regenerate BOREAL.xcodeproj
#   make build         — Debug build for the simulator (no signing)
#   make test          — the spec gate (laws, goldens, oracle, Swift
#                        kernels, trainer parity G-a)
#   make test-xcode    — xcodebuild test (BOREALTests: the spec gate's
#                        parity legs replayed inside Xcode — G5 closed)
#   make device        — Release build for generic iOS device
#   make sim           — alias for `make build`
#   make clean         — wipe spec harness builds + Xcode DerivedData
#   make docs          — open SETUP.md
#
# Variables (override on the command line):
#   make SIM="iPhone 17 Pro" build     — pick simulator destination

.PHONY: setup build test test-spec test-xcode device sim clean docs help

# Defaults.
SIM ?= iPhone 17 Pro
DEST_SIM := -destination 'platform=iOS Simulator,name=$(SIM)'
DEST_DEV := -destination 'generic/platform=iOS'
SIGN     := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
PROJECT  := BOREAL.xcodeproj
SCHEME   := BOREAL

help:
	@echo "BOREAL build targets:"
	@echo "  make setup      verify prereqs and regenerate $(PROJECT)"
	@echo "  make build      Debug simulator build (no signing)"
	@echo "  make test       spec gate (laws/goldens/oracle/Swift/trainer G-a) + xcodebuild test"
	@echo "  make test-xcode xcodebuild test (BOREALTests kernel parity — G5 closed)"
	@echo "  make device     Release device build"
	@echo "  make sim        alias for 'make build'"
	@echo "  make clean      wipe spec harness builds + Xcode DerivedData"
	@echo "  make docs       open SETUP.md"

setup:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "ERROR: xcodegen not found. Install: brew install xcodegen"; \
		exit 1; \
	}
	@echo "✓ xcodegen: $$(xcodegen --version 2>&1 | head -1)"
	@xcodegen generate
	@echo ""
	@echo "✓ Ready. Try: make build  |  make test"

build: sim
sim:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		$(DEST_SIM) -configuration Debug build $(SIGN)

device:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		$(DEST_DEV) -configuration Release build

test: test-spec test-xcode

test-spec:
	$(MAKE) -C spec gate

test-xcode:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		$(DEST_SIM) -configuration Debug test $(SIGN)

# TF0: the Mac verdict CLI (tools/replay — verify/render/noise/abfuse).
#   make replay ARGS="verify ~/Downloads/BOREAL-20260720-.../"
replay:
	@mkdir -p spec/_build
	swiftc -O BOREAL/Kernels/*.swift tools/replay/main.swift -o spec/_build/replay
	spec/_build/replay $(ARGS)

# TF4: everything — the spec gate, the Xcode suite, and (when BUNDLE is
# given) a field-telemetry replay against a real bundle.
test-all: test-spec test-xcode
ifdef BUNDLE
	$(MAKE) replay ARGS="verify $(BUNDLE)"
else
	@echo "test-all: no BUNDLE=<dir> given — field replay skipped"
endif

clean:
	rm -rf spec/_build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean || true
	@echo "✓ cleaned"

docs:
	@open SETUP.md
