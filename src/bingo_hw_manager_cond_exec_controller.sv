// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// DARTS Tier 1: Conditional Execution Register File (CERF)
//
// A small register file that stores activation status for up to NumGroups
// "conditional execution groups." Each group corresponds to a logical unit
// (e.g., one expert in MoE, one exit branch in early exit).
//
// The scheduler queries the CERF combinationally to decide whether a
// conditionally-annotated task should execute or be skipped. Skipped
// tasks still propagate their dependency signals (via the checkout queue)
// but are never dispatched to a core.
//
// Write interface: CSR-based, driven by the gating core after it
// computes which groups should be active (e.g., top-K expert selection).

module bingo_hw_manager_cond_exec_controller #(
    parameter int unsigned NumGroups = 16
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // Full state output (combinational, avoids multi-port read)
    output logic [NumGroups-1:0]          cerf_state_o,
    // Write port (from host/gating core via CSR)
    input  logic                          write_en_i,
    input  logic [$clog2(NumGroups)-1:0]  write_group_id_i,
    input  logic                          write_val_i,
    // Bulk clear (for new inference batch)
    input  logic                          clear_all_i
);
    logic [NumGroups-1:0] cerf_q;

    // Combinational full-state output
    assign cerf_state_o = cerf_q;

    // Sequential write with priority: clear_all > write
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cerf_q <= '0;
        end else if (clear_all_i) begin
            cerf_q <= '0;
        end else if (write_en_i) begin
            cerf_q[write_group_id_i] <= write_val_i;
        end
    end
endmodule
