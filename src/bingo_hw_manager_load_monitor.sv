// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// DARTS Tier 3: Per-(Core, Cluster) Load Monitor
//
// Tracks the number of pending tasks per (core, cluster) pair.
// Increments on dispatch (ready queue pop), decrements on completion (done queue push).
// Exposes per-core and total pending counts for host-driven load balancing.

module bingo_hw_manager_load_monitor #(
    parameter int unsigned NumCores    = 4,
    parameter int unsigned NumClusters = 2,
    parameter int unsigned CounterWidth = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Dispatch events (from ready queue pop)
    input  logic [NumCores-1:0][NumClusters-1:0] task_dispatched_i,
    // Completion events (from done queue push)
    input  logic [NumCores-1:0][NumClusters-1:0] task_done_i,
    // Status outputs (CSR readable)
    output logic [CounterWidth-1:0] pending_per_core_o [NumCores][NumClusters],
    output logic [CounterWidth+2:0] total_pending_o
);
    logic [CounterWidth-1:0] pending_q [NumCores][NumClusters];

    // Per-(core, cluster) saturating counters
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int c = 0; c < NumCores; c++)
                for (int cl = 0; cl < NumClusters; cl++)
                    pending_q[c][cl] <= '0;
        end else begin
            for (int c = 0; c < NumCores; c++) begin
                for (int cl = 0; cl < NumClusters; cl++) begin
                    if (task_dispatched_i[c][cl] && !task_done_i[c][cl]) begin
                        if (pending_q[c][cl] < {CounterWidth{1'b1}})
                            pending_q[c][cl] <= pending_q[c][cl] + 1;
                    end else if (!task_dispatched_i[c][cl] && task_done_i[c][cl]) begin
                        if (pending_q[c][cl] > 0)
                            pending_q[c][cl] <= pending_q[c][cl] - 1;
                    end
                    // Simultaneous dispatch+done: no change
                end
            end
        end
    end

    // Output
    always_comb begin
        total_pending_o = '0;
        for (int c = 0; c < NumCores; c++) begin
            for (int cl = 0; cl < NumClusters; cl++) begin
                pending_per_core_o[c][cl] = pending_q[c][cl];
                total_pending_o = total_pending_o + pending_q[c][cl];
            end
        end
    end
endmodule
