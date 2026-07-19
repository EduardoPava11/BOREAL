# BOREAL Haskell Specs — 64-burst → 16×16 LAB latent
# Run: make test          (all specs)
#      make test-one F=geometry/CropShape.hs

RUNGHC = runghc
# -package-env=- ignores the GHCup default env that hides base libs
FLAGS  = -W -package-env=-

# ── File lists by layer ──────────────────────────────────

GEOMETRY  = geometry/CropShape.hs
PALETTE   = palette/PaletteGrid.hs
EXPOSURE  = exposure/EvNormalize.hs exposure/EvPlan.hs
COLORPATH = colorpath/ColorQuant.hs
GIFTARGET = giftarget/GifIndex.hs
MULTISCALE = multiscale/MultiScaleLaws.hs
GIFWIRE   = gifwire/GifWireLaws.hs
CYCLESET  = cycleset/CycleSetLaws.hs
BINOMIAL  = binomial/BinomialLaws.hs
HIERARCHY = hierarchy/HierarchyLaws.hs
THEOREM   = theorem/MaxSignalLaws.hs
DITHERWALK = ditherwalk/DitherWalkLaws.hs
TESSGRID  = tessgrid/TessGridLaws.hs
BATTLE    = battle/BattleLaws.hs

CORE = $(GEOMETRY) $(PALETTE) $(EXPOSURE) $(COLORPATH) $(GIFTARGET) $(MULTISCALE) $(GIFWIRE) $(CYCLESET) $(BINOMIAL) $(HIERARCHY) $(THEOREM) $(DITHERWALK) $(TESSGRID) $(BATTLE)

# ── Targets ──────────────────────────────────────────────

.PHONY: test test-verbose test-one emit gate ga list

# Regenerate the golden fixtures (single-source from Boreal/*).
emit:
	$(RUNGHC) $(FLAGS) emit/EmitGoldens.hs

# Swift kernel parity: compile the app's pure-Swift kernels against the
# same goldens (Phase 5: Swift + Metal is the kernel language).
swift-verify:
	@mkdir -p _build
	swiftc -O ../BOREAL/Kernels/*.swift verify-swift/main.swift -o _build/verify-swift
	_build/verify-swift ../fixtures

# Trainer parity (gate G-a): the NumPy training pipeline (nn/v1) is
# bit-exact against the same goldens the Swift kernels answer to.
# goldens_test resolves fixtures relative to its own file — cwd-safe.
ga:
	python3 ../nn/v1/goldens_test.py

# The full gate: laws → fixtures → Python oracle → Swift kernels →
# trainer parity (G-a).
gate: test emit
	python3 oracle/validate_goldens.py
	$(MAKE) swift-verify
	$(MAKE) ga

test:
	@echo "════ BOREAL Spec Suite ════"
	@pass=0; fail=0; \
	for f in $(CORE); do \
		printf "  %-40s" "$$f"; \
		if $(RUNGHC) $(FLAGS) $$f > /dev/null 2>&1; then \
			echo "✓"; pass=$$((pass+1)); \
		else \
			echo "✗"; fail=$$((fail+1)); \
		fi; \
	done; \
	echo ""; \
	echo "  $$pass passed, $$fail failed out of $$(( pass + fail ))"

test-verbose:
	@for f in $(CORE); do \
		echo ""; \
		echo "════ $$f ════"; \
		$(RUNGHC) $(FLAGS) $$f || true; \
	done

# Run a single spec: make test-one F=geometry/CropShape.hs
test-one:
	$(RUNGHC) $(FLAGS) $(F)

list:
	@for f in $(CORE); do echo "  $$f"; done

# Replay a device LAB report bundle through the same kernels on the Mac
# and assert bit-exact agreement: make verify-device DIR=~/Downloads
verify-device:
	@mkdir -p _build
	swiftc -O ../BOREAL/Kernels/*.swift verify-device/main.swift -o _build/verify-device
	_build/verify-device $(DIR)
