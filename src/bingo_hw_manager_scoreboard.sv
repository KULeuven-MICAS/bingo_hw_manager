// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// Task-Slot Scoreboard — decouples logical slot_id from physical core_id.
//
// Stores a per-cluster slot→core mapping table (forward view) and a mirror
// core→slot lookup (inverse view) used to stamp done_info.slot_id from the
// (core, cluster) that completed the task.
//
// Write port is driven on task entry into the waiting_dep_check_queue, at
// which point the descriptor's slot_id and assigned_core_id are both stable.
//
// The reassign port is a hook for fault-tolerant slot reclaim: a future
// fault-recovery controller may retarget slot s to a different physical core
// without touching any downstream dependency encoding (because the dep_matrix
// is slot-indexed). Currently tied off.
//
// Reset value: identity (table[i] = i, inv_table[i] = i) so the scoreboard is
// coherent with the legacy "slot_id == core_id" software behaviour even
// before any task has been pushed. table_valid starts at 0 so assertions can
// distinguish "never written" from "written to identity".

module bingo_hw_manager_scoreboard #(
    parameter int unsigned NUM_SLOTS = 4,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter type slot_id_t = logic [$clog2(NUM_SLOTS)-1:0],
    parameter type core_id_t = logic [$clog2(NUM_SLOTS)-1:0]
) (
    input  logic     clk_i,
    input  logic     rst_ni,

    // Write port: driven on waiting_dep_check_queue push
    input  logic     we_i,
    input  slot_id_t write_slot_i,
    input  core_id_t write_core_i,

    // Reassign port (fault-recovery hook). Takes priority over we_i if both
    // fire in the same cycle; leaves a distinct trace for assertions.
    input  logic     reassign_valid_i,
    input  slot_id_t reassign_slot_i,
    input  core_id_t reassign_core_i,

    // Combinational read port (forward view: slot -> core)
    input  slot_id_t read_slot_i,
    output core_id_t read_core_o,
    output logic     read_valid_o,

    // Combinational inverse read port (core -> slot) — used by the done path to
    // stamp done_info.slot_id at the (core, cluster) that completed.
    input  core_id_t inv_read_core_i,
    output slot_id_t inv_read_slot_o,

    // Full-table observation (for SVA, cross-validation, fault-recovery)
    output core_id_t [NUM_SLOTS-1:0] table_core_o,
    output logic     [NUM_SLOTS-1:0] table_valid_o,
    // Full inverse table (core -> slot) — used by the top level to stamp
    // done_info.slot_id at every (core, cluster) that completes.
    output slot_id_t [NUM_SLOTS-1:0] inv_table_o
);

    // Forward table (slot -> core)
    core_id_t table_core_q     [NUM_SLOTS];
    // Inverse table (core -> slot) — invariant: inv_table_q[table_core_q[s]] == s
    // after any write that establishes table_core_q[s].
    slot_id_t inv_table_q      [NUM_SLOTS];
    logic     table_valid_q    [NUM_SLOTS];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            // Identity mapping: aligns with today's static "slot_id == core_id" software.
            for (int unsigned s = 0; s < NUM_SLOTS; s++) begin
                table_core_q[s]  <= core_id_t'(s);
                inv_table_q[s]   <= slot_id_t'(s);
                table_valid_q[s] <= 1'b0;
            end
        end else begin
            // Reassign takes priority over we_i.
            if (reassign_valid_i) begin
                table_core_q[reassign_slot_i]   <= reassign_core_i;
                inv_table_q[reassign_core_i]    <= reassign_slot_i;
                table_valid_q[reassign_slot_i]  <= 1'b1;
            end else if (we_i) begin
                table_core_q[write_slot_i]   <= write_core_i;
                inv_table_q[write_core_i]    <= write_slot_i;
                table_valid_q[write_slot_i]  <= 1'b1;
            end
        end
    end

    assign read_core_o      = table_core_q[read_slot_i];
    assign read_valid_o     = table_valid_q[read_slot_i];
    assign inv_read_slot_o  = inv_table_q[inv_read_core_i];

    for (genvar s = 0; s < NUM_SLOTS; s++) begin : gen_table_obs
        assign table_core_o[s]  = table_core_q[s];
        assign table_valid_o[s] = table_valid_q[s];
        assign inv_table_o[s]   = inv_table_q[s];
    end

`ifndef SYNTHESIS
    // SVA: when we write a slot whose current forward-binding points to a
    // *different* core (and the slot has been written before), flag it as a
    // compiler-invariant violation. `reassign_valid_i` is exempt because it is
    // the legitimate way to retarget a live slot.
    property p_slot_uniqueness;
        @(posedge clk_i) disable iff (!rst_ni)
        (we_i && !reassign_valid_i && table_valid_q[write_slot_i]) |->
            (table_core_q[write_slot_i] == write_core_i);
    endproperty
    assert_slot_uniqueness: assert property (p_slot_uniqueness)
        else $error("[scoreboard] slot %0d remapped from core %0d to core %0d without reassign",
                    write_slot_i, table_core_q[write_slot_i], write_core_i);
`endif

endmodule
