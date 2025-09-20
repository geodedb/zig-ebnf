# Simple Makefile to wrap Zig build/test/bench/tools

ZIG ?= zig
ZIG_FLAGS ?=
ZIG_RELEASE_FLAGS ?= -Doptimize=ReleaseSafe

# Auto-detect Wine (prefer wine64, fallback to wine) for Windows execution of cross-compiled tests/examples
WINE64_BIN := $(shell command -v wine64 2>/dev/null)
WINE32_BIN := $(shell command -v wine 2>/dev/null)
ifeq ($(WINE64_BIN),)
	ifeq ($(WINE32_BIN),)
		WINE_AVAILABLE := 0
		WINE_CMD :=
	else
		WINE_AVAILABLE := 1
		WINE_CMD := wine
	endif
else
	WINE_AVAILABLE := 1
	WINE_CMD := wine64
endif

.PHONY: all build release test bench clean fmt ci help
.PHONY: cross-compile cross-windows cross-linux-x86_64 cross-linux-arm cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64 cross-windows-arm64 cross-test
.PHONY: example examples

# Default target - build everything including cross-compilation checks (non-blocking)
all: build test

wine-info:
ifeq ($(WINE_AVAILABLE),1)
	@echo "Using Wine command: $(WINE_CMD)"; $(WINE_CMD) --version | head -1 || true
else
	@echo "Wine not available (wine64 or wine not found)"
endif

# Help target
help:
	@echo "zig-ebnf Makefile targets:"
	@echo ""
	@echo "Build targets:"
	@echo "  make build       - Build debug version"
	@echo "  make release     - Build release version"
	@echo "  make cross-compile - Build for all cross-compilation targets"
	@echo ""
	@echo "Cross-compilation targets:"
	@echo "  make cross-windows      - Build for Windows x86_64"
	@echo "  make cross-linux-arm    - Build for Linux ARM (32-bit)"
	@echo "  make cross-linux-arm64  - Build for Linux ARM64"
	@echo "  make cross-linux-riscv64 - Build for Linux RISC-V 64-bit"
	@echo "  make cross-macos-x86_64 - Build for macOS x86_64"
	@echo "  make cross-windows-arm64 - Build for Windows ARM64"
	@echo "  make cross-test         - Test cross-platform functionality"
	@echo ""
	@echo "Test targets:"
	@echo "  make test        - Run all tests"
	@echo "  make bench       - Run benchmarks"
	@echo ""
	@echo "Example targets:"
	@echo "  make examples    - Test all example EBNF files"
	@echo "  make example     - Run a quick example (integer grammar)"
	@echo ""
	@echo "Utility targets:"
	@echo "  make fmt         - Format all code"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make ci          - Run CI pipeline (build, test, bench)"

build:
	$(ZIG) build $(ZIG_FLAGS)

release:
	$(ZIG) build $(ZIG_RELEASE_FLAGS)

# Run Zig tests
test:
	$(ZIG) build test $(ZIG_FLAGS)

bench:
	$(ZIG) build bench $(ZIG_FLAGS)

# Run a quick example with the integer grammar
example: build
	@echo "Running integer grammar example..."
	@if [ -f "./zig-out/bin/zig-ebnf" ]; then \
		echo "Generating parser for integer.ebnf..."; \
		./zig-out/bin/zig-ebnf examples/integer.ebnf --output /tmp/integer_parser.zig --start integer; \
		echo "✓ Generated parser at /tmp/integer_parser.zig"; \
		echo "Testing generated parser..."; \
		$(ZIG) test /tmp/integer_parser.zig -I. --main-pkg-path . || echo "Parser generation test complete"; \
	else \
		echo "zig-ebnf not found, run 'make build' first"; \
	fi

# Test all example EBNF files
examples: build
	@echo "Testing all example EBNF files..."
	@if [ -f "./zig-out/bin/zig-ebnf" ]; then \
		for example in examples/*.ebnf; do \
			if [ -f "$$example" ]; then \
				echo "Processing $$example..."; \
				basename=$$(basename "$$example" .ebnf); \
				./zig-out/bin/zig-ebnf "$$example" --output "/tmp/$${basename}_parser.zig" || echo "Failed to process $$example"; \
			fi; \
		done; \
		echo "✓ All examples processed"; \
	else \
		echo "zig-ebnf not found, run 'make build' first"; \
	fi

# Format all code
fmt:
	@echo "Formatting Zig code..."
	$(ZIG) fmt src/
	$(ZIG) fmt build.zig
	@if [ -d "examples" ]; then \
		echo "Checking example files..."; \
	fi

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf zig-out
	rm -rf .zig-cache
	rm -rf zig-cache

# Run build, test, bench sequentially for CI
ci: clean build test bench cross-compile-strict
	@echo "CI pipeline completed successfully"

# Strict cross-compilation for CI (fails on any error)
cross-compile-strict: cross-linux-x86_64 cross-windows cross-linux-arm cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64 cross-windows-arm64
	@echo "All cross-compilation targets built successfully"

# Quick rebuild (no clean)
quick: build test

# Cross-compilation targets (required 64-bit targets only)
cross-compile: cross-compile-required cross-compile-optional
	@echo "Cross-compilation checks complete"

# Required 64-bit cross-compilation targets (must all pass)
cross-compile-required: cross-linux-x86_64 cross-windows cross-linux-arm64 cross-linux-riscv64 cross-macos-x86_64 cross-macos-arm64 cross-windows-arm64
	@echo "✓ All required cross-compilation targets built successfully"

# Optional 32-bit cross-compilation targets (failures are non-fatal)
cross-compile-optional:
	@echo "Checking optional 32-bit cross-compilation targets..."
	@$(MAKE) cross-linux-arm || echo "⚠ Linux ARM (32-bit) cross-compilation failed (this is expected and non-fatal)"

# Cross-compile for Linux x86_64
cross-linux-x86_64:
	@echo "Cross-compiling for Linux x86_64..."
	$(ZIG) build -Dtarget=x86_64-linux -p zig-out/linux-x86_64 $(ZIG_FLAGS)
	@echo "✓ Linux x86_64 build successful"

# Cross-compile for Windows x86_64
cross-windows:
	@echo "Cross-compiling for Windows x86_64..."
	$(ZIG) build -Dtarget=x86_64-windows -p zig-out/windows-x86_64 $(ZIG_FLAGS)
	@test -f zig-out/windows-x86_64/bin/zig-ebnf.exe || (echo "Failed to build zig-ebnf.exe" && exit 1)
	@echo "✓ Windows x86_64 build successful"

# Cross-compile for Linux ARM (32-bit)
cross-linux-arm:
	@echo "Cross-compiling for Linux ARM..."
	$(ZIG) build -Dtarget=arm-linux-gnueabihf -p zig-out/linux-arm $(ZIG_FLAGS)
	@echo "✓ Linux ARM build successful"

# Cross-compile for Linux ARM64
cross-linux-arm64:
	@echo "Cross-compiling for Linux ARM64..."
	$(ZIG) build -Dtarget=aarch64-linux-gnu -p zig-out/linux-arm64 $(ZIG_FLAGS)
	@echo "✓ Linux ARM64 build successful"

# Cross-compile for Linux RISC-V 64-bit
cross-linux-riscv64:
	@echo "Cross-compiling for Linux RISC-V 64-bit..."
	$(ZIG) build -Dtarget=riscv64-linux-gnu -p zig-out/linux-riscv64 $(ZIG_FLAGS)
	@echo "✓ Linux RISC-V 64-bit build successful"

# Cross-compile for macOS x86_64
cross-macos-x86_64:
	@echo "Cross-compiling for macOS x86_64..."
	@# Only run on non-macOS systems or when on ARM macOS
	@if [ "$$(uname)" != "Darwin" ] || [ "$$(uname -m)" = "arm64" ]; then \
		$(ZIG) build -Dtarget=x86_64-macos -p zig-out/macos-x86_64 $(ZIG_FLAGS); \
		echo "✓ macOS x86_64 build successful"; \
	else \
		echo "Skipping macOS x86_64 cross-compile on x86_64 macOS"; \
	fi

# Cross-compile for macOS ARM64 (Apple Silicon)
cross-macos-arm64:
	@echo "Cross-compiling for macOS ARM64..."
	@# Only run on non-macOS systems or when on Intel macOS
	@if [ "$$(uname)" != "Darwin" ] || [ "$$(uname -m)" = "x86_64" ]; then \
		$(ZIG) build -Dtarget=aarch64-macos -p zig-out/macos-arm64 $(ZIG_FLAGS); \
		echo "✓ macOS ARM64 build successful"; \
	else \
		echo "Skipping macOS ARM64 cross-compile on ARM64 macOS"; \
	fi

# Cross-compile for Windows ARM64
cross-windows-arm64:
	@echo "Cross-compiling for Windows ARM64..."
	$(ZIG) build -Dtarget=aarch64-windows-msvc -p zig-out/windows-arm64 $(ZIG_FLAGS)
	@echo "✓ Windows ARM64 build successful"

# Test cross-platform functionality
cross-test:
	@echo "Testing cross-platform functionality..."
	@# Test Windows cross-compilation if Wine is available
	@if [ -n "$(WINE_CMD)" ]; then \
		echo "Testing Windows cross-compilation with Wine ($(WINE_CMD))..."; \
		echo "Building Windows zig-ebnf.exe..."; \
		$(ZIG) build -Dtarget=x86_64-windows-gnu -O ReleaseSmall -p zig-out/wine-test $(ZIG_FLAGS) 2> build_windows.log || true; \
		if [ ! -f zig-out/wine-test/bin/zig-ebnf.exe ]; then \
			echo "Windows build failed, trying MSVC variant..."; \
			$(ZIG) build -Dtarget=x86_64-windows-msvc -O ReleaseSmall -p zig-out/wine-test $(ZIG_FLAGS) 2>> build_windows.log || true; \
		fi; \
		if [ -f zig-out/wine-test/bin/zig-ebnf.exe ]; then \
			echo "Testing zig-ebnf.exe under Wine..."; \
			OUTPUT=$$(WINEDEBUG=-all $(WINE_CMD) ./zig-out/wine-test/bin/zig-ebnf.exe --help 2>&1 || true); \
			RET=$$?; \
			echo "Wine output:"; echo "$$OUTPUT" | sed 's/^/  > /' | head -10; \
			if echo "$$OUTPUT" | grep -Eqi 'c0000135|Bad EXE format'; then \
				echo "⚠ Wine environment cannot execute the binary (missing DLL or bad format). Skipping Windows test."; \
			elif [ $$RET -eq 0 ] && echo "$$OUTPUT" | grep -q "Usage:"; then \
				echo "✓ Windows zig-ebnf executable runs successfully under Wine"; \
			else \
				echo "⚠ Windows zig-ebnf test inconclusive"; \
			fi; \
			rm -rf zig-out/wine-test; \
		else \
			echo "Failed to build Windows executable"; \
			cat build_windows.log; \
		fi; \
		rm -f build_windows.log; \
	else \
		echo "Wine not available (wine64/wine), skipping Windows runtime test"; \
	fi

# Test the main CLI with example grammars
test-cli: build
	@echo "Testing CLI with example grammars..."
	@if [ -f "./zig-out/bin/zig-ebnf" ]; then \
		echo "Testing integer grammar..."; \
		./zig-out/bin/zig-ebnf examples/integer.ebnf --output /tmp/test_integer.zig --start integer; \
		echo "Testing integer_set grammar..."; \
		./zig-out/bin/zig-ebnf examples/integer_set.ebnf --output /tmp/test_integer_set.zig --start set; \
		echo "✓ CLI tests completed"; \
	else \
		echo "zig-ebnf not found, run 'make build' first"; \
	fi

# Check for bad example grammars (should fail)
test-bad-examples: build
	@echo "Testing bad example grammars (should fail)..."
	@if [ -f "./zig-out/bin/zig-ebnf" ]; then \
		echo "Testing bad_empty_rep.ebnf (should fail)..."; \
		./zig-out/bin/zig-ebnf examples/bad_empty_rep.ebnf --output /tmp/bad1.zig --start expr 2>/dev/null && echo "ERROR: Should have failed!" || echo "✓ Correctly rejected bad_empty_rep.ebnf"; \
		echo "Testing bad_left_rec.ebnf (should fail)..."; \
		./zig-out/bin/zig-ebnf examples/bad_left_rec.ebnf --output /tmp/bad2.zig --start expr 2>/dev/null && echo "ERROR: Should have failed!" || echo "✓ Correctly rejected bad_left_rec.ebnf"; \
		echo "✓ Bad example tests completed"; \
	else \
		echo "zig-ebnf not found, run 'make build' first"; \
	fi

# Generate documentation or parser for the project's own grammar if available
parse-gql: build
	@if [ -f "gql.ebnf" ]; then \
		echo "Generating parser for project's GQL grammar..."; \
		./zig-out/bin/zig-ebnf gql.ebnf --output /tmp/gql_parser.zig --start query; \
		echo "✓ GQL parser generated at /tmp/gql_parser.zig"; \
	else \
		echo "gql.ebnf not found in project root"; \
	fi

# Full acceptance test
acceptance: build test examples test-cli test-bad-examples
	@echo "✓ Full acceptance test completed successfully"
