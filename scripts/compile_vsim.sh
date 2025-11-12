#!/bin/bash
set -e

[ ! -z "$VSIM" ] || VSIM=vsim

bender script vsim -t bingo_hw_manager_test -t rtl \
    --vlog-arg="-svinputport=compat" \
    --vlog-arg="-override_timescale 1ns/1ps" \
    --vlog-arg="-suppress 2583" \
    > compile.tcl
echo 'return 0' >> compile.tcl

$VSIM -c -do 'exit -code [source compile.tcl]'