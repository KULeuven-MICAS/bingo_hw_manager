# Authors:
# - Fanchen Kong <fanchen.kong@kuleuven.be>
# - Yunhao Deng <yunhao.deng@kuleuven.be>
# The batch testing is done by the make all
# The single testing with gui is done by make sim_gui
# bash, so `set -o pipefail` below actually takes effect (/bin/sh may not support it).
SHELL         := /bin/bash
VSIM          ?= vsim
BENDER        ?= bender
TB_DIR        ?= tb
TEST_DIR      ?= test
VSIM_BUILDDIR ?= work-vsim
TB            ?= bingo_hw_manager_top
# Every testbench in test/. This used to list only `bingo_hw_manager_top`, so `make all` /
# `make sim_all` silently exercised ONE of them and a green run meant almost nothing.
TBS           ?= bingo_hw_manager_top \
                 bingo_hw_manager_tagged \
                 bingo_hw_manager_tagged_mc \
                 bingo_hw_manager_dep_matrix \
                 bingo_hw_manager_multiedge \
                 bingo_hw_manager_cerf_mc \
                 bingo_hw_manager_cerf_basic \
                 bingo_hw_manager_cerf_skip \
                 bingo_hw_manager_task_fetch \
                 bingo_hw_manager_task_fetch_top

# Source files the compiled library depends on. Without these, compile.log depends only on
# Bender.yml, so editing any .sv leaves a STALE compiled library in place and every subsequent
# `make sim-*.log` silently re-runs the previous build -- a test edit appears to change nothing.
RTL_SRCS      := $(wildcard src/*.sv) $(wildcard test/*.sv) $(wildcard test/*.svh)

SIM_TARGETS := $(addsuffix .log,$(addprefix sim-,$(TBS)))

.PHONY: help all sim_all clean

help:
	@echo ""
	@echo "compile.log:  compile files using Questasim"
	@echo "sim-#TB#.log: simulates a given testbench, available TBs are:"
	@echo "$(addprefix ###############-#,$(TBS))" | sed -e 's/ /\n/g' | sed -e 's/#/ /g'
	@echo "sim_all:      simulates all available testbenches using the /scripts/run_vsim.sh script"
	@echo "sim_gui:      simulates the specified TB with gui for debugging"
	@echo ""
	@echo "clean:        cleans generated files"
	@echo ""

all: compile.log sim_all

sim_all: $(SIM_TARGETS)

build:
	mkdir -p $@
compile.log: Bender.yml $(RTL_SRCS) | build
	set -o pipefail; export VSIM="$(VSIM)"; cd build && ../scripts/compile_vsim.sh | tee ../$@
	(! grep -n "Error:" $@)

sim-%.log: compile.log
	set -o pipefail; export VSIM="$(VSIM)"; cd build && ../scripts/run_vsim.sh --random-seed $* | tee ../$@
	(! grep -n "Error:" $@)
	(! grep -n "Fatal:" $@)

sim_gui: $(TB_DIR)/${TB}.vsim.gui
	$(TB_DIR)/${TB}.vsim.gui

# Generate + simulate a DFG pattern (requires Python + codegen)
test-pattern-%: compile.log
	python3 scripts/gen_and_sim.py --pattern $* --output-dir test/generated/
	export VSIM="$(VSIM)"; cd build && ../scripts/run_vsim.sh --random-seed bingo_hw_manager_$*

# Run all DFG pattern tests
test-all-patterns: compile.log
	python3 scripts/run_all_tests.py

# Run Python model unit tests
test-model:
	python3 -m pytest model/tests/ -v

# Run cross-validation (Python model vs RTL)
test-cross-validate:
	python3 scripts/cross_validate.py

VSIM_BENDER_TARGET = -t simulation
VSIM_BENDER_TARGET += -t test

VLOG_FLAGS += -svinputport=compat
VLOG_FLAGS += -timescale 1ns/1ps

VSIM_FLAGS += -t 1ps
VSIM_FLAGS += -voptargs=+acc
VSIM_FLAGS += -do "log -r /*; run -a"
VOPT_FLAGS = +acc
$(VSIM_BUILDDIR):
	mkdir -p $@
$(TB_DIR):
	mkdir -p $@

$(VSIM_BUILDDIR)/compile.vsim.tcl: $(VSIM_BUILDDIR)
	$(BENDER) script vsim $(VSIM_BENDER_TARGET) --vlog-arg="$(VLOG_FLAGS) -work $(dir $@) " > $@
	echo 'vlog -work $(dir $@) ' >> $@
	echo 'return 0' >> $@
$(TB_DIR)/${TB}.vsim.gui: $(VSIM_BUILDDIR)/compile.vsim.tcl |$(TB_DIR)
	touch $@
	vsim -c -do "source $<; quit" | tee $(VSIM_BUILDDIR)/vlog.log
	vopt $(VOPT_FLAGS) -work $(VSIM_BUILDDIR) tb_$(TB) -o tb_$(TB)_opt | tee $(VSIM_BUILDDIR)/vopt.log
	@! grep -P "Errors: [1-9]*," $(VSIM_BUILDDIR)/vlog.log
	@echo "#!/bin/bash" > $@
	@echo 'vsim +permissive $(VSIM_FLAGS) -work $(VSIM_BUILDDIR) \
					tb_${TB}_opt +permissive-off ' >> $@
	@chmod +x $@
clean:
	rm -rf build
	rm -f  *.log
	rm -rf *.wlf
	rm -rf $(VSIM_BUILDDIR)
	rm -rf $(TB_DIR)
	rm -rf transcript
	rm -rf *.vstf