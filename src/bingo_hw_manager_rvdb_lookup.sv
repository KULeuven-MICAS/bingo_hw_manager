// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// RVDB lookup unit — one instance per cluster.
//
// On every cycle observes the per-(core,cluster) done-queue pop events. When a
// core's done-queue pops a completed task, the unit:
//
//   1. Reads the rvdb_config[source_slot] entry. If valid, the slot is the
//      source of an RVDB chain.
//   2. Computes table_addr = config.table_base + return_value.
//   3. Reads the per-cluster bind_table at table_addr.
//   4. Casts the result to a packed task descriptor, sets task_type=2'b11
//      and is_bind=1, and routes it as a synthetic BIND into the target core's
//      bind side-channel.
//
// At most one synthetic bind per cluster per cycle (priority-encoded across
// cores when multiple done-pops fire simultaneously). The 3-way bind mux at
// the bind_resolver inputs (local / remote / rvdb) accepts this synthetic bind
// identically to a host-issued bind.

module bingo_hw_manager_rvdb_lookup #(
    parameter int unsigned NUM_CORES_PER_CLUSTER = 4,
    parameter type         task_desc_full_t      = logic,
    parameter type         done_info_full_t      = logic,
    parameter int unsigned BIND_TABLE_ENTRIES    = 64,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter int unsigned SLOT_ID_W             = (NUM_CORES_PER_CLUSTER > 1) ? $clog2(NUM_CORES_PER_CLUSTER) : 1,
    parameter int unsigned BIND_TABLE_ADDR_W     = (BIND_TABLE_ENTRIES > 1) ? $clog2(BIND_TABLE_ENTRIES) : 1
) (
    input  logic                                  clk_i,
    input  logic                                  rst_ni,

    // ---- Per-core done-queue pop observation ------------------------------
    // Asserts for one cycle when a core's done queue retires a task. The
    // associated done_info_full_t carries the slot_id (which is the source
    // slot index for chain config) and the 8-bit return_value.
    input  logic            [NUM_CORES_PER_CLUSTER-1:0] done_pop_i,
    input  done_info_full_t [NUM_CORES_PER_CLUSTER-1:0] done_info_i,

    // ---- rvdb_config[] read port -----------------------------------------
    // Indexed by source_slot_id (= done_info.slot_id). Returns
    // {valid, target_slot, table_base}.
    output logic [SLOT_ID_W-1:0]                  cfg_read_addr_o,
    input  logic                                  cfg_valid_i,
    input  logic [SLOT_ID_W-1:0]                  cfg_target_slot_i,
    input  logic [BIND_TABLE_ADDR_W-1:0]          cfg_table_base_i,

    // ---- Bind table read port --------------------------------------------
    output logic [BIND_TABLE_ADDR_W-1:0]          bt_read_addr_o,
    input  task_desc_full_t                       bt_read_data_i,
    // High once the bind_table has been fully populated by the loader.
    // Synthetic-bind injection is suppressed until this is asserted, so an
    // RVDB chain configured but reading an un-loaded entry never fires with
    // garbage data.
    input  logic                                  bt_loaded_i,

    // ---- Synthetic bind output (per core in this cluster) ----------------
    // Drives the rvdb-side input of each bind_resolver's 3-way bind mux.
    output logic            [NUM_CORES_PER_CLUSTER-1:0] synthetic_bind_valid_o,
    output task_desc_full_t [NUM_CORES_PER_CLUSTER-1:0] synthetic_bind_desc_o
);

    // Find the lowest-indexed core whose done queue popped this cycle (first-match).
    // Multiple simultaneous pops are flagged by `multi_pop_collision` for SVA,
    // and we serve only one — the others' RVDB lookups would be dropped if their
    // configs were valid.
    logic                          any_pop;
    logic [SLOT_ID_W-1:0]          selected_core;
    logic [SLOT_ID_W-1:0]          source_slot;
    logic [7:0]                    return_value;
    done_info_full_t               selected_done_info;

    always_comb begin
        any_pop            = |done_pop_i;
        selected_core      = '0;
        selected_done_info = '0;
        for (int i = NUM_CORES_PER_CLUSTER-1; i >= 0; i--) begin
            if (done_pop_i[i]) begin
                selected_core      = i[SLOT_ID_W-1:0];
                selected_done_info = done_info_i[i];
            end
        end
    end
    assign source_slot  = selected_done_info.slot_id;
    assign return_value = selected_done_info.return_value;

    // Drive the rvdb_config read port with the selected source_slot.
    assign cfg_read_addr_o = source_slot;

    // Compute the bind_table address. Saturate on out-of-bound:
    // clamp to NUM_ENTRIES - 1.
    // Sum is widened to 9 bits to comfortably hold the worst case
    // (table_base up to 2^ADDR_W-1 + return_value up to 0xFF).
    logic [8:0] table_addr_raw;
    logic       addr_overflow;
    assign table_addr_raw = 9'(cfg_table_base_i) + 9'(return_value);
    assign addr_overflow  = (table_addr_raw >= BIND_TABLE_ENTRIES);
    assign bt_read_addr_o = addr_overflow
                            ? BIND_TABLE_ADDR_W'(BIND_TABLE_ENTRIES-1)
                            : table_addr_raw[BIND_TABLE_ADDR_W-1:0];

    // Synthetic bind fires only when (a) a chain config exists for the source
    // slot AND (b) the bind_table has been fully loaded. The latter prevents
    // a chain configured before its bind_table entries are valid from
    // injecting a bind with un-initialised data.
    logic            do_inject;
    assign do_inject = any_pop && cfg_valid_i && bt_loaded_i;

    // Construct the synthetic bind descriptor: take the bind_table entry
    // (which is already a packed task descriptor) and ensure the JIT BIND
    // markers (task_type=2'b11, is_bind=1) and target_slot/cluster fields are set.
    task_desc_full_t synth_desc;
    always_comb begin
        synth_desc           = bt_read_data_i;
        synth_desc.task_type = 2'b11;
        synth_desc.is_bind   = 1'b1;
        // Target the chain's configured destination slot. The bind_table entry
        // carries the kernel/dep_set/cond_exec payload; the target slot comes
        // from the rvdb_config.
        synth_desc.slot_id   = cfg_target_slot_i;
    end

    // Per-core fanout: route the synthetic bind to the target core's
    // bind side-channel. Only one core per cycle.
    always_comb begin
        synthetic_bind_valid_o = '0;
        for (int co = 0; co < NUM_CORES_PER_CLUSTER; co++) begin
            synthetic_bind_desc_o[co] = synth_desc;
            if (do_inject && (cfg_target_slot_i == co[SLOT_ID_W-1:0])) begin
                synthetic_bind_valid_o[co] = 1'b1;
            end
        end
    end


    // ---- Internal debug signals (not exposed as ports) -------------------
    // Kept as named nets so SVA + waveform debug can observe them. With no
    // external consumers, synthesis will optimise the unused ones away.
    //   multi_pop_collision : >1 core pop in same cycle (we serialise)
    //   unknown_chain_drop  : pop on a slot whose rvdb_config is invalid (no chain)
    //   table_addr_oob      : (table_base + return_value) exceeds BIND_TABLE_ENTRIES (saturating)
    logic multi_pop_collision;
    logic unknown_chain_drop;
    logic table_addr_oob;
    assign multi_pop_collision = ($countones(done_pop_i) > 1);
    assign unknown_chain_drop  = any_pop && !cfg_valid_i;
    assign table_addr_oob      = do_inject && addr_overflow;

    // ---- Sim-only invariants ---------------------------------------------
    `ifndef SYNTHESIS
    // SVA: multiple cores popping in the same cycle would cause us to drop
    // all but one chain's lookup. Compiler should serialise chains so this
    // doesn't happen in practice.
    assert_no_multi_pop_collision: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        !multi_pop_collision
    ) else $warning("rvdb_lookup: simultaneous done-pop on multiple cores — only one chain serviced");
    `endif

endmodule
