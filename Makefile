# Development and installation shortcuts for Iara. Run from the root:
#   make help
# Every target calls an existing script. See GUIDE.md ("Make targets").
# DRY_RUN=1 prints what a target would do to your directories instead.
# Requires GNU make.

.DEFAULT_GOAL := help
.PHONY: help tools fmt fmt-check lint test check bench \
	dev gallery install install-default update repair rollback restore \
	backups uninstall clean

# Not NVIM: Neovim sets that to its server address in terminals.
NVIM_BIN ?= nvim
export NVIM_BIN
STYLUA = .tools/bin/stylua
STYLUA_ARGS = --config-path .stylua.toml --respect-ignores \
	init.lua lua scripts tests
LAUNCHER ?= $(HOME)/.local/bin/iara
BENCH_PATHS ?= 100000
GALLERY ?= start
TEST ?=
BACKUP ?=
DRY_RUN ?=

CONFIG_HOME = $${XDG_CONFIG_HOME:-$$HOME/.config}
DATA_HOME = $${XDG_DATA_HOME:-$$HOME/.local/share}
# The current release's own bootstrap, reached through the data directory
# so that it works when ~/.config/iara is missing; an installation made
# before releases has only the configuration link.
STORED_BOOTSTRAP = $(DATA_HOME)/iara/current/config/scripts/bootstrap.lua
INSTALLED_BOOTSTRAP = "$$(f=$(STORED_BOOTSTRAP); [ -e "$$f" ] \
	|| f=$(CONFIG_HOME)/iara/scripts/bootstrap.lua; echo "$$f")"
# The log file keeps `nvim -l` from writing into the `nvim` state dir.
INSTALL = NVIM_LOG_FILE=/dev/null "$(NVIM_BIN)" --clean -l scripts/install.lua
BOOTSTRAP = NVIM_LOG_FILE=/dev/null NVIM_APPNAME=iara "$(NVIM_BIN)" --clean -l
INSTALL_FLAGS = $(DRY_RUN:1=--dry-run)
# Prefix for commands that change the user's directories.
RUN = $(DRY_RUN:1=@echo would run:)
TEMP_DIRS = -name 'iara-test.*' -o -name 'iara-tools.*' \
	-o -name 'iara-parsers.*' -o -name 'iara-gallery-*'

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(firstword $(MAKEFILE_LIST)) \
		| awk -F':.*## ' '{ printf "  %-16s %s\n", $$1, $$2 }'
	@echo "Variables: TEST=path BACKUP=dir DRY_RUN=1 LAUNCHER=path"
	@echo "  BENCH_PATHS=count GALLERY=scenarios NVIM_BIN=path"

tools: ## Install pinned StyLua, mini.nvim, parsers into .tools/
	scripts/tools.sh

fmt: ## Format Lua files with StyLua
	$(STYLUA) $(STYLUA_ARGS)

fmt-check: ## Check Lua formatting without writing
	$(STYLUA) --check $(STYLUA_ARGS)

lint: ## Run the quality checker (length, complexity, width)
	NVIM_LOG_FILE=/dev/null "$(NVIM_BIN)" --clean -l scripts/quality.lua .

test: ## Run the test suite, or one file with TEST=tests/test_x.lua
	scripts/test.sh $(TEST)

check: ## Run fmt-check, lint, and every test (scripts/check.sh)
	scripts/check.sh

bench: ## Benchmark filename scoring (BENCH_PATHS=100000)
	NVIM_LOG_FILE=/dev/null "$(NVIM_BIN)" --clean -l \
		tests/bench_fuzzy.lua "$(BENCH_PATHS)"

dev: ## Run the checkout with an isolated Iara profile
	scripts/dev.sh

gallery: ## Render color gallery screens (GALLERY=start find-files)
	"$(NVIM_BIN)" --clean -l scripts/gallery.lua $(GALLERY)

install: ## Install as `iara` (backs up an existing Iara first)
	$(INSTALL) install $(INSTALL_FLAGS) --launcher $(LAUNCHER)

install-default: ## Make `nvim` open Iara (backs up NvChad first)
	$(INSTALL) default $(INSTALL_FLAGS) --launcher $(LAUNCHER)

update: ## Build and promote a release from this checkout
	$(RUN) $(BOOTSTRAP) scripts/bootstrap.lua --update

repair: ## Complete the current release (its stored bootstrap)
	$(RUN) $(BOOTSTRAP) $(INSTALLED_BOOTSTRAP) --repair

rollback: ## Switch back to the previous release
	$(RUN) $(BOOTSTRAP) $(INSTALLED_BOOTSTRAP) --rollback

restore: ## Restore the latest backup, or BACKUP=dir
	$(INSTALL) restore $(INSTALL_FLAGS) $(BACKUP:%=--backup %)

backups: ## List backups and whether they were restored
	$(INSTALL) backups

uninstall: ## Move Iara's directories into a backup
	$(INSTALL) uninstall $(INSTALL_FLAGS) --launcher $(LAUNCHER)

clean: ## Remove development temporary directories under TMPDIR
	$(RUN) find "$${TMPDIR:-/tmp}" -mindepth 1 -maxdepth 1 -type d \
		\( $(TEMP_DIRS) \) -exec rm -rf {} +
