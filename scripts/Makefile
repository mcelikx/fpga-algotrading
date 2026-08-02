# =============================================================================
# scripts/Makefile — the front door for every flow in this project
# -----------------------------------------------------------------------------
# Project : FPGA Algorithmic Trading System (Nasdaq Equities)
# Governs : manuals/01-fpga-design/05-verification-and-simulation.md §1, §7
#           manuals/06-operations/01-build-and-release.md §2, §5, §6
#           manuals/00-foundations/05-timing-closure.md §8
#
# USAGE
#   make -C scripts <target>          from anywhere
#   make -f scripts/Makefile <target> equivalent
#
# THE ORDER MATTERS. CLAUDE.md §4: "Run lint -> sim -> synth -> P&R, in that
# order. Do not report 'done' until place-and-route timing closes."
# Each tier catches a class of bug the tier below cannot, and each costs
# roughly 10x more time than the one before it. Running them out of order buys
# nothing and wastes hours.
#
#   make lint         seconds     latches, widths, forbidden constructs
#   make sim          minutes     functional correctness vs. the golden model
#   make synth        ~30 min     latch inference, unconstrained clocks, Fmax est
#   make impl         hours       ⚠️ THE ONLY STAGE THAT MEANS TIMING CLOSURE
#   make seed-sweep   many hours  ⚠️ THE ONLY THING THAT MEANS CLOSURE AT ALL
#
# =============================================================================

# --- Locations ---------------------------------------------------------------
MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
SCRIPTS_DIR   := $(patsubst %/,%,$(dir $(MAKEFILE_PATH)))
ROOT          := $(abspath $(SCRIPTS_DIR)/..)

# --- Tunables (override on the command line: `make impl SEED=7`) -------------
PART        ?= xcvu9p-flga2104-2-i          ## target device+speed grade
TOP         ?= fpga_top                     ## top module
SEED        ?= 1                            ## implementation seed
THREADS     ?= 8                            ## pinned; see build-and-release §1
SWEEP_N     ?= 16                           ## seeds in a sweep
SWEEP_J     ?= 4                            ## parallel Vivado processes
SIM         ?= verilator                    ## cocotb SIM: verilator | icarus | xsim
WAVES       ?= 0                            ## 1 = dump waves (slow; off in CI)
BUILD_DIR   ?=                              ## explicit build dir, else dated
VIVADO      ?= vivado
PYTHON      ?= python3

# Blocks that have a cocotb test directory. `make sim-<block>` runs just one.
BLOCKS      := feed book risk order net strategy

VIVADO_BATCH := $(VIVADO) -mode batch -nojournal -notrace

.DEFAULT_GOAL := help

# =============================================================================
.PHONY: help
help: ## Show this help
	@echo "=========================================================================="
	@echo " FPGA trading system — build and verification targets"
	@echo "=========================================================================="
	@grep -E '^[a-zA-Z][a-zA-Z0-9_-]*:.*?## .*$$' $(MAKEFILE_PATH) \
	  | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1;36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo " Variables (override on the command line):"
	@grep -E '^[A-Z_]+ *\?=.*##' $(MAKEFILE_PATH) \
	  | awk 'BEGIN {FS = "\\?=| *## "}; {printf "  \033[1;33m%-12s\033[0m %-28s %s\n", $$1, $$2, $$3}'
	@echo ""
	@echo " ⚠️  Tier order is lint -> sim -> synth -> impl -> seed-sweep."
	@echo "     Timing closure is claimed from seed-sweep, never from synth."
	@echo "=========================================================================="

# =============================================================================
# TIER 0 — LINT
# =============================================================================
.PHONY: lint
lint: ## Verilator --lint-only -Wall + forbidden-construct scan (seconds)
	@$(SCRIPTS_DIR)/lint.sh

.PHONY: lint-strict
lint-strict: ## Lint with NO fatal suppression — the target state for the tree
	@$(SCRIPTS_DIR)/lint.sh --strict --tb

# =============================================================================
# TIER 1-3 — SIMULATION (cocotb)
# =============================================================================
# Each tb/<block>/ holds a cocotb Makefile that sets TOPLEVEL / MODULE and
# includes $(shell cocotb-config --makefiles)/Makefile.sim. This target just
# dispatches to them so there is ONE command to remember.
#
# ⚠️ Every random test logs its seed on its first line of output
#    (05-verification-and-simulation.md §6: "A random failure you cannot
#    reproduce is not a finding, it is a rumour."). Reproduce with:
#        make sim-book SEED=<the logged seed>

.PHONY: sim
sim: ## Run the full cocotb regression across every block (minutes)
	@rc=0; \
	for b in $(BLOCKS); do \
	  if [ -d "$(ROOT)/tb/$$b" ]; then \
	    echo "=== sim: $$b ==="; \
	    $(MAKE) --no-print-directory -C "$(ROOT)/tb/$$b" \
	      SIM=$(SIM) WAVES=$(WAVES) SEED=$(SEED) || rc=1; \
	  fi; \
	done; \
	exit $$rc

# `make sim-book`, `make sim-risk`, … — one block, for the edit/run loop.
.PHONY: $(addprefix sim-,$(BLOCKS))
$(addprefix sim-,$(BLOCKS)): sim-%: ## Run one block's tests (sim-feed, sim-book, sim-risk, sim-order, sim-net, sim-strategy)
	@test -d "$(ROOT)/tb/$*" || { echo "no such tb dir: tb/$*"; exit 1; }
	$(MAKE) --no-print-directory -C "$(ROOT)/tb/$*" \
	    SIM=$(SIM) WAVES=$(WAVES) SEED=$(SEED)

.PHONY: replay
replay: ## Tier 3: pcap replay vs. the golden book model — the highest-value test
	@echo "⚠️  Tier 3 is THE tier that matters (05-verification-and-simulation.md §4)."
	@echo "    Hardware book output must be bit-identical to tb/common/golden_book.py"
	@echo "    over the whole corpus. This is merge gate 3."
	$(MAKE) --no-print-directory -C "$(ROOT)/tb/book" \
	    SIM=$(SIM) WAVES=$(WAVES) TESTCASE=test_pcap_replay_vs_golden

.PHONY: sim-clean
sim-clean: ## Remove simulator build products under tb/
	@find "$(ROOT)/tb" \( -name sim_build -o -name __pycache__ -o -name '*.vcd' \
	    -o -name '*.fst' -o -name 'results.xml' \) -prune -exec rm -rf {} + 2>/dev/null || true
	@echo "tb/ simulator artifacts removed"

# =============================================================================
# TIER 4 — SYNTHESIS
# =============================================================================
.PHONY: synth
synth: ## synth_design only — fails on latch inference or an unconstrained clock
	@echo "⚠️  Synthesis timing is an ESTIMATE, optimistic by 20-40%."
	@echo "    05-timing-closure.md §2: never report a synth number as closure."
	$(VIVADO_BATCH) -source $(SCRIPTS_DIR)/build.tcl -tclargs \
	    --part $(PART) --top $(TOP) --seed $(SEED) --threads $(THREADS) \
	    --stop-after synth $(if $(BUILD_DIR),--out $(BUILD_DIR),)

# =============================================================================
# TIER 4 — IMPLEMENTATION
# =============================================================================
.PHONY: impl
impl: ## Full P&R through route_design — post-route WNS/TNS/WHS (hours)
	$(VIVADO_BATCH) -source $(SCRIPTS_DIR)/build.tcl -tclargs \
	    --part $(PART) --top $(TOP) --seed $(SEED) --threads $(THREADS) \
	    --stop-after route $(if $(BUILD_DIR),--out $(BUILD_DIR),)

.PHONY: bitstream
bitstream: ## Full flow through write_bitstream — the deliverable
	@echo "⚠️  write_bitstream is blocked while constraints/io.xdc still declares"
	@echo "    BOARD_PINS_ARE_PLACEHOLDERS. Reports and checkpoints still produced."
	$(VIVADO_BATCH) -source $(SCRIPTS_DIR)/build.tcl -tclargs \
	    --part $(PART) --top $(TOP) --seed $(SEED) --threads $(THREADS) \
	    --stop-after bitstream $(if $(BUILD_DIR),--out $(BUILD_DIR),)

# =============================================================================
# CLOSURE
# =============================================================================
.PHONY: seed-sweep
seed-sweep: ## Run SWEEP_N seeds in parallel and print the WNS DISTRIBUTION
	@echo "⚠️  Closure on one lucky seed is not closure."
	@echo "    06-operations/01-build-and-release.md §6 — the project criterion is"
	@echo "    the distribution, not the best result."
	@$(SCRIPTS_DIR)/seed_sweep.sh -n $(SWEEP_N) -j $(SWEEP_J) -p $(PART)

.PHONY: qor
qor: ## Parse the newest build's reports -> one-line JSON + a human table
	@d=$${BUILD_DIR:-$$(ls -dt $(ROOT)/builds/*/ 2>/dev/null | head -1)}; \
	if [ -z "$$d" ]; then echo "no builds/ directory found — run 'make impl' first"; exit 1; fi; \
	echo "reading $$d"; \
	$(PYTHON) $(SCRIPTS_DIR)/report_qor.py --build "$$d" --table

.PHONY: qor-trend
qor-trend: ## Append the newest build's QoR line to ci/qor.jsonl for trending
	@mkdir -p $(ROOT)/ci
	@d=$${BUILD_DIR:-$$(ls -dt $(ROOT)/builds/*/ 2>/dev/null | head -1)}; \
	if [ -z "$$d" ]; then echo "no builds/ found"; exit 1; fi; \
	$(PYTHON) $(SCRIPTS_DIR)/report_qor.py --build "$$d" >> $(ROOT)/ci/qor.jsonl; \
	echo "appended $$d to ci/qor.jsonl"
	@echo "06-operations/01-build-and-release.md §5: plot this. Timing and"
	@echo "resources degrade gradually and then suddenly; the graph gives"
	@echo "weeks of warning."

# =============================================================================
# CI COMPOSITES
# =============================================================================
.PHONY: ci-push
ci-push: lint sim ## Merge gate for every push (< 10 min budget)

.PHONY: ci-pr
ci-pr: lint sim replay ## Merge gate for a PR (adds pcap replay vs. the oracle)

.PHONY: ci-nightly
ci-nightly: lint sim replay seed-sweep ## Nightly: everything, including the sweep
	@echo "⚠️  A red nightly does not block a merge, but it blocks the next"
	@echo "    release, and a WNS regression is a P1 with a named owner."

# =============================================================================
# HOUSEKEEPING
# =============================================================================
.PHONY: clean
clean: sim-clean ## Remove simulation artifacts (build outputs are NOT touched)
	@rm -f $(ROOT)/vivado*.log $(ROOT)/vivado*.jou $(ROOT)/*.str 2>/dev/null || true
	@rm -rf $(ROOT)/.Xil 2>/dev/null || true
	@echo "clean done."
	@echo "NOTE: builds/ is deliberately NOT removed. A build directory is an"
	@echo "      audit artifact (06-operations/01-build-and-release.md §3) — the"
	@echo "      only way to answer 'what was running at 14:32:07'. Delete them"
	@echo "      explicitly with 'make distclean' when you mean it."

.PHONY: distclean
distclean: clean ## ⚠️ Also delete builds/ — destroys build audit artifacts
	@printf 'Delete ALL of builds/ ? This removes bitstreams, checkpoints and\n'
	@printf 'manifests that are the audit record for this project. [y/N] '
	@read ans; [ "$$ans" = "y" ] || { echo "aborted"; exit 1; }
	@rm -rf $(ROOT)/builds
	@echo "builds/ removed."

.PHONY: env
env: ## Print the toolchain versions that shape a build (pin these)
	@echo "repo root : $(ROOT)"
	@echo "part      : $(PART)"
	@echo "threads   : $(THREADS)"
	@printf 'vivado    : '; $(VIVADO) -version 2>/dev/null | head -1 || echo "NOT FOUND"
	@printf 'verilator : '; verilator --version 2>/dev/null || echo "NOT FOUND"
	@printf 'python    : '; $(PYTHON) --version 2>/dev/null || echo "NOT FOUND"
	@printf 'cocotb    : '; $(PYTHON) -c "import cocotb;print(cocotb.__version__)" 2>/dev/null || echo "NOT FOUND"
	@printf 'git sha   : '; git -C $(ROOT) rev-parse --short=7 HEAD 2>/dev/null || echo "unknown"
	@printf 'git dirty : '; test -z "$$(git -C $(ROOT) status --porcelain 2>/dev/null)" && echo no || echo "⚠️ YES"
	@echo ""
	@echo "⚠️ Every line above is a build input. 06-operations/01-build-and-release.md"
	@echo "   §1: change the tool version and placement, routing, WNS — and the"
	@echo "   fast-path latency — can all change with no source change at all."
