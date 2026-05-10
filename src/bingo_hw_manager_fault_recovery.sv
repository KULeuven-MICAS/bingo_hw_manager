// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// Autonomous, type-aware fault-recovery controller (one instance per cluster).
//
// Watches each core's in-flight indicator and increments a per-core elapsed
// counter; if a core holds an in-flight task longer than `threshold_i` cycles
// without producing a done pulse, the core is declared faulty (sticky). The
// controller then looks for the smallest-id core in the same cluster that is
// (a) not faulty, (b) currently idle, and (c) has matching capability tag,
// and drives the scoreboard's reassign port for one cycle so the logical slot
// currently bound to the faulty core is rebound to the spare.
//
// If no compatible spare exists, `no_spare_o` pulses for one cycle and the
// faulty mask still latches (preventing re-triggering every cycle). The host
// can take action via the top-level `fault_irq_o`.
//
// The reassign target slot is read directly from the scoreboard's inverse
// table, so the controller never needs to remember which slot is bound to
// which core.

module bingo_hw_manager_fault_recovery #(
    parameter int unsigned NUM_CORES         = 4,
    parameter int unsigned FaultTimeoutWidth = 32,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter type slot_id_t         = logic [$clog2(NUM_CORES)-1:0],
    parameter type core_id_t         = logic [$clog2(NUM_CORES)-1:0],
    parameter type core_capability_t = logic [1:0]
) (
    input  logic                                 clk_i,
    input  logic                                 rst_ni,

    // Master enable. When low, the FSM stays idle and reassign never fires.
    input  logic                                 en_i,
    // Cycles a core may hold an in-flight task before being declared faulty.
    input  logic [FaultTimeoutWidth-1:0]         threshold_i,
    // Host-configured per-core capability tag (e.g. GEMM vs DMA). Replacement
    // must have the same tag as the faulty core.
    input  core_capability_t [NUM_CORES-1:0]     core_capability_i,

    // Per-core "task in flight" — high while the core holds a dispatched task
    // that has not yet produced a done pulse.
    input  logic [NUM_CORES-1:0]                 core_inflight_i,
    // Per-core "completion progress" pulse — high the cycle a done_info is
    // pushed for this core. Resets the elapsed-cycle counter.
    input  logic [NUM_CORES-1:0]                 core_done_pulse_i,
    // Scoreboard's inverse table for this cluster (core -> slot mapping).
    input  slot_id_t [NUM_CORES-1:0]             inv_table_i,

    // Reassign request to the scoreboard. Pulses for one cycle.
    output logic                                 reassign_valid_o,
    output slot_id_t                             reassign_slot_o,
    output core_id_t                             reassign_core_o,

    // Pulses the cycle a fault is detected but no compatible spare exists.
    output logic                                 no_spare_o
);

    // Per-core elapsed-cycle counter; clears on done pulse, on faulty, or
    // while the FSM is disabled.
    logic [NUM_CORES-1:0][FaultTimeoutWidth-1:0] cycle_count_q, cycle_count_d;
    // Sticky faulty mask. Once set, prevents the core from being chosen as a
    // replacement and from re-triggering detection.
    logic [NUM_CORES-1:0]                        faulty_q, faulty_d;

    // Detection: which core just crossed the threshold this cycle?
    logic [NUM_CORES-1:0] new_fault_now;
    for (genvar c = 0; c < NUM_CORES; c++) begin : gen_detect
        assign new_fault_now[c] = en_i && !faulty_q[c] && core_inflight_i[c] &&
                                  (cycle_count_q[c] >= threshold_i);
    end

    // Pick lowest-id newly-faulty core this cycle (one event per cycle).
    logic     picked_new;
    core_id_t picked_new_core;
    always_comb begin
        picked_new      = 1'b0;
        picked_new_core = '0;
        for (int unsigned c = 0; c < NUM_CORES; c++) begin
            if (new_fault_now[c] && !picked_new) begin
                picked_new      = 1'b1;
                picked_new_core = core_id_t'(c);
            end
        end
    end

    // Replacement search: same cluster, same capability, idle, not faulty.
    logic     found_replacement;
    core_id_t replacement_core;
    always_comb begin
        found_replacement = 1'b0;
        replacement_core  = '0;
        if (picked_new) begin
            for (int unsigned c = 0; c < NUM_CORES; c++) begin
                if (!found_replacement &&
                    (core_id_t'(c) != picked_new_core) &&
                    !faulty_q[c] && !core_inflight_i[c] &&
                    (core_capability_i[c] == core_capability_i[picked_new_core])) begin
                    found_replacement = 1'b1;
                    replacement_core  = core_id_t'(c);
                end
            end
        end
    end

    assign reassign_valid_o = picked_new && found_replacement;
    assign reassign_slot_o  = inv_table_i[picked_new_core];
    assign reassign_core_o  = replacement_core;
    assign no_spare_o       = picked_new && !found_replacement;

    // Counter and faulty-mask updates.
    always_comb begin
        cycle_count_d = cycle_count_q;
        faulty_d      = faulty_q;
        for (int unsigned c = 0; c < NUM_CORES; c++) begin
            if (!en_i || faulty_q[c] || core_done_pulse_i[c] || !core_inflight_i[c]) begin
                cycle_count_d[c] = '0;
            end else if (cycle_count_q[c] != {FaultTimeoutWidth{1'b1}}) begin
                cycle_count_d[c] = cycle_count_q[c] + FaultTimeoutWidth'(1);
            end
        end
        if (picked_new) begin
            faulty_d[picked_new_core] = 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cycle_count_q <= '0;
            faulty_q      <= '0;
        end else begin
            cycle_count_q <= cycle_count_d;
            faulty_q      <= faulty_d;
        end
    end

`ifndef SYNTHESIS
    // Replacement must not be the faulty core itself.
    property p_replacement_differs;
        @(posedge clk_i) disable iff (!rst_ni)
        reassign_valid_o |-> (reassign_core_o != picked_new_core);
    endproperty
    assert_replacement_differs: assert property (p_replacement_differs)
        else $error("[fault_recovery] reassign chose the same core as the faulty one (%0d)",
                    picked_new_core);

    // Faulty mask is sticky once en_i has fired.
    property p_faulty_sticky;
        @(posedge clk_i) disable iff (!rst_ni)
        $rose(faulty_q[picked_new_core]) |-> ##1 faulty_q[$past(picked_new_core)];
    endproperty
`endif

endmodule
