// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// RVDB bind table — per-cluster SRAM/register array storing pre-computed
// bind descriptors indexed by `(chain.table_base + return_value)`.
//
// Loaded once at init by `bingo_hw_manager_bind_table_loader` (a small
// AXI-Lite-master FSM that fetches NUM_ENTRIES entries from L1 TCDM at the
// host-supplied base address).
//
// At runtime the read port is driven combinationally by the `rvdb_lookup_unit`
// when a chain's source slot completes; the entry is cast back into a packed
// task descriptor and injected into the target core's bind side-channel.

module bingo_hw_manager_bind_table #(
    parameter int unsigned NUM_ENTRIES = 64,
    parameter int unsigned ENTRY_WIDTH = 64,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter int unsigned ADDR_WIDTH  = (NUM_ENTRIES > 1) ? $clog2(NUM_ENTRIES) : 1
) (
    input  logic                   clk_i,
    input  logic                   rst_ni,
    // Load port — driven by the bind-table loader during init.
    // load_en_i pulses for one cycle per entry; load_addr_i is the entry index.
    input  logic                   load_en_i,
    input  logic [ADDR_WIDTH-1:0]  load_addr_i,
    input  logic [ENTRY_WIDTH-1:0] load_data_i,
    // Read port — driven by rvdb_lookup_unit. Combinational read, single cycle.
    input  logic [ADDR_WIDTH-1:0]  read_addr_i,
    output logic [ENTRY_WIDTH-1:0] read_data_o,
    // Status — high once all entries have been loaded at least once.
    // Cleared on reset; the loader also pulses load_en_i with a "complete"
    // marker (indicated by load_addr_i == NUM_ENTRIES-1) — but we conservatively
    // gate on a per-entry seen vector.
    output logic                   loaded_o
);

    // Storage. For NUM_ENTRIES=64 × ENTRY_WIDTH=64 this is 512 bytes — small
    // enough to be inferred as flip-flops by every synthesiser; tools that
    // recognise small SRAMs will infer a dense memory macro instead.
    logic [ENTRY_WIDTH-1:0] mem_q [NUM_ENTRIES];
    logic [NUM_ENTRIES-1:0] entry_loaded_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            entry_loaded_q <= '0;
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                mem_q[i] <= '0;
            end
        end else if (load_en_i) begin
            mem_q[load_addr_i]          <= load_data_i;
            entry_loaded_q[load_addr_i] <= 1'b1;
        end
    end

    // Combinational read.
    assign read_data_o = mem_q[read_addr_i];
    // "All entries loaded" — a coarse indicator that the table is usable.
    // Workloads typically fill all entries at init, so this transitions
    // exactly once after the loader's bulk fetch.
    assign loaded_o    = &entry_loaded_q;

endmodule
