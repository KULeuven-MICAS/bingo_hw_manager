// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// DARTS Tier 1: Conditional Execution Register File (CERF)
//
// A register file that stores activation status for up to NumGroups
// "conditional execution groups." Each group corresponds to a logical unit
// (e.g., one expert in MoE, one exit branch in early exit).
//
// The scheduler queries the CERF combinationally to decide whether a
// conditionally-annotated task should execute or be skipped. Skipped
// tasks still propagate their dependency signals (via the checkout queue)
// but are never dispatched to a core.
//
// Write interface: single 32-bit bitmask write. SW writes the full
// CERF_STATE CSR and pulses CERF_WRITE_EN to latch the value.
// Clearing is simply writing 0.

module bingo_hw_manager_cond_exec_controller #(
    parameter int unsigned NumGroups = 32,
    // Low GlobalGroups entries are the CROSS-DIE window: they are also writable
    // by an arriving cross-chiplet dep-set message, so a routing decision taken
    // on one die can gate work on another. The remaining groups are die-local
    // and only software on this chiplet ever writes them.
    parameter int unsigned GlobalGroups = 8
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // Full state output (combinational)
    output logic [NumGroups-1:0]          cerf_state_o,
    // Write port: 32-bit bitmask + enable (software on a local core)
    input  logic [NumGroups-1:0]          cerf_write_data_i,
    input  logic                          cerf_write_en_i,
    // Cross-die write port: the global window, delivered by an H2H dep-set that
    // carried a gating task's predicate. See bingo_hw_manager_top.
    input  logic [GlobalGroups-1:0]       cerf_global_write_data_i,
    input  logic                          cerf_global_write_en_i
);
    if (GlobalGroups > NumGroups) begin : gen_global_groups_check
        initial begin
            $error("GlobalGroups (%0d) exceeds NumGroups (%0d).", GlobalGroups, NumGroups);
            $finish;
        end
    end
    logic [NumGroups-1:0] cerf_q;

    // Combinational full-state output
    assign cerf_state_o = cerf_q;

    // Sequential write: latch entire bitmask on write_en
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cerf_q <= '0;
        end else if (cerf_write_en_i) begin
            // A local software write owns the WHOLE register and wins: it is an
            // explicit act by a kernel on this die, whereas the window write is
            // a side effect of a message. A global group is written by one die
            // at a time, so they are not expected to collide -- but the priority
            // is stated rather than left to chance.
            cerf_q <= cerf_write_data_i;
        end else if (cerf_global_write_en_i) begin
            cerf_q[GlobalGroups-1:0] <= cerf_global_write_data_i;
        end
    end
endmodule
