# cocotb runner for rtl/common primitives.
#   make -C tb/common MODULE=test_async_fifo TOPLEVEL=async_fifo
#
# All of rtl/common is compiled every time so multi-module tests (arbiters)
# work without a per-test source list. Verilator dead-strips what the top
# does not reach.
#
# lz4 paths: Verilator's FST writer needs lz4.h, which Homebrew does not put
# on the default include path.
SIM           ?= verilator
TOPLEVEL_LANG ?= verilog
HERE          := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL           := $(HERE)/../../rtl

MODULE        ?= test_skid_buffer
TOPLEVEL      ?= skid_buffer

# Compile only what this top needs. Compiling all of rtl/common leaves several
# un-instantiated modules, Verilator picks one of them as top, and cocotb then
# cannot find its root handle. EXTRA_SRCS covers multi-module tests.
EXTRA_SRCS      ?=
VERILOG_SOURCES  = $(RTL)/pkg/trading_pkg.sv
VERILOG_SOURCES += $(wildcard $(RTL)/pkg/sat_arith_pkg.sv)
VERILOG_SOURCES += $(EXTRA_SRCS)
VERILOG_SOURCES += $(RTL)/common/$(TOPLEVEL).sv

EXTRA_ARGS += --timing --assert -Wno-fatal --top-module $(TOPLEVEL)
# Resolve submodule dependencies by name instead of listing them per test.
EXTRA_ARGS += -y $(RTL)/common -y $(RTL)/pkg +libext+.sv
EXTRA_ARGS += -CFLAGS -I/opt/homebrew/opt/lz4/include
EXTRA_ARGS += -LDFLAGS -L/opt/homebrew/opt/lz4/lib -LDFLAGS -llz4

include $(shell cocotb-config --makefiles)/Makefile.sim
