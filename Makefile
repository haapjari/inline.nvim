DBG_MAKEFILE ?=
ifeq ($(DBG_MAKEFILE),1)
    $(warning ***** starting Makefile for goal(s) "$(MAKECMDGOALS)")
else
    MAKEFLAGS += -s
endif

SHELL := /usr/bin/env bash -o errexit -o pipefail -o nounset

MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --warn-undefined-variables

.SUFFIXES:

OUT_DIR := _output
TOOLS_DIR := $(OUT_DIR)/tools
HACK_DIR := hack

LUA_FILES := $(shell find lua -name '*.lua' -type f)
TEST_FILES := $(shell find tests -name '*_spec.lua' -type f 2>/dev/null)

# tool versions
LUACHECK_VERSION ?= 1.2.0
NVIM_VERSION ?= 0.11.0

# neovim binary - override with: make test NVIM=/path/to/nvim
# checks: user override -> PATH -> local install
NVIM ?= $(shell command -v nvim 2>/dev/null || echo "$(TOOLS_DIR)/nvim/usr/bin/nvim")

# ============================================================================
# HELP TARGETS
# ============================================================================

.PHONY: all
all: verify

.PHONY: help
help:
	@echo "Commands"
	@echo ""
	@echo "Primary:"
	@echo "  all            - run verify (default)"
	@echo "  test           - run tests with plenary"
	@echo "  verify         - run all verification checks"
	@echo "  clean          - remove build artifacts"
	@echo ""
	@echo "Verification:"
	@echo "  verify-syntax  - check lua syntax"
	@echo "  verify-lint    - run luacheck"
	@echo ""
	@echo "Development:"
	@echo "  tools          - install development tools (luacheck, nvim)"
	@echo "  setup-hooks    - install git pre-commit hooks"
	@echo ""
	@echo "Variables:"
	@echo "  DBG_MAKEFILE=1 - show make debugging output"
	@echo "  NVIM=/path     - path to neovim binary (default: auto-detect)"

# ============================================================================
# TOOLS TARGETS
# ============================================================================

.PHONY: tools
tools: tool-luacheck tool-nvim
	@echo "all tools installed!"

.PHONY: tool-nvim
tool-nvim:
	@if command -v nvim >/dev/null 2>&1; then \
		echo "nvim already installed: $$(nvim --version | head -1)"; \
	elif [ -x "$(TOOLS_DIR)/nvim/usr/bin/nvim" ]; then \
		echo "nvim already installed: $$($(TOOLS_DIR)/nvim/usr/bin/nvim --version | head -1)"; \
	else \
		echo "installing nvim $(NVIM_VERSION) to $(TOOLS_DIR)..."; \
		mkdir -p $(TOOLS_DIR); \
		curl -fsSL -o $(TOOLS_DIR)/nvim.appimage \
			"https://github.com/neovim/neovim/releases/download/v$(NVIM_VERSION)/nvim-linux-x86_64.appimage"; \
		chmod +x $(TOOLS_DIR)/nvim.appimage; \
		cd $(TOOLS_DIR) && ./nvim.appimage --appimage-extract >/dev/null && mv squashfs-root nvim; \
		rm -f $(TOOLS_DIR)/nvim.appimage; \
		echo "nvim installed to $(TOOLS_DIR)/nvim/usr/bin/nvim"; \
	fi

.PHONY: tool-luacheck
tool-luacheck:
	@if command -v luacheck >/dev/null 2>&1; then \
		echo "luacheck already installed: $$(luacheck --version | head -1)"; \
	elif [ -x "$$HOME/.luarocks/bin/luacheck" ]; then \
		echo "luacheck installed at ~/.luarocks/bin/luacheck"; \
		echo "add to PATH: export PATH=\"\$$HOME/.luarocks/bin:\$$PATH\""; \
	else \
		echo "installing luacheck $(LUACHECK_VERSION)..."; \
		command -v luarocks >/dev/null 2>&1 || { \
			echo "error: luarocks not found"; \
			echo "install luarocks first:"; \
			echo "  apt install luarocks"; \
			echo "  # or: brew install luarocks"; \
			exit 1; \
		}; \
		luarocks --local install luacheck $(LUACHECK_VERSION); \
		echo ""; \
		echo "luacheck installed. add to your shell profile:"; \
		echo "  export PATH=\"\$$HOME/.luarocks/bin:\$$PATH\""; \
		echo ""; \
		echo "then restart your shell or run:"; \
		echo "  source ~/.bashrc  # or ~/.zshrc"; \
	fi

# ============================================================================
# VERIFY TARGETS
# ============================================================================

.PHONY: verify
verify: verify-syntax verify-lint
	@echo "all verification checks passed!"

.PHONY: verify-syntax
verify-syntax:
	@echo "checking lua syntax..."
	@for f in $(LUA_FILES); do \
		luac -p "$$f" || exit 1; \
	done
	@echo "  syntax ok"

.PHONY: verify-lint
verify-lint:
	@if command -v luacheck >/dev/null 2>&1; then \
		echo "running luacheck..."; \
		luacheck lua/ tests/ --config .luacheckrc; \
	else \
		echo "luacheck not found, skipping lint"; \
		echo "  install with: luarocks install luacheck"; \
	fi

# ============================================================================
# TEST TARGETS
# ============================================================================

.PHONY: test
test:
	@echo "running tests..."
	@if [ -z "$(TEST_FILES)" ]; then \
		echo "  no test files found"; \
	elif [ ! -x "$(NVIM)" ]; then \
		echo "  nvim not found, skipping tests"; \
		echo "  run 'make tools' to install, or set NVIM=/path/to/nvim"; \
	else \
		$(NVIM) --headless -u tests/minimal_init.lua \
			-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"; \
	fi

# ============================================================================
# CLEANING TARGETS
# ============================================================================

.PHONY: setup-hooks
setup-hooks:
	@$(HACK_DIR)/setup-hooks.sh

.PHONY: clean
clean:
	@echo "cleaning build artifacts..."
	rm -rf $(OUT_DIR)
