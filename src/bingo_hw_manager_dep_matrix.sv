// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// Counter-based dependency matrix.
//
// Each cell is an 8-bit saturating counter instead of a single bit.
// This allows multiple dep_set operations to accumulate on the same cell
// without overlap rejection, eliminating the deadlock caused by the
// interaction of overlap detection + done queue HOL blocking.
//
// Operations:
//   set_column(col, set_code): increment counter[r][col] for each row r in set_code
//   check_row(row, check_code): true if counter[row][c] >= 1 for all c in check_code
//   clear_row(row, check_code): decrement counter[row][c] by 1 for each c in check_code
//
// dep_set_ready_o is always 1 — no backpressure, no deadlock.
//
// JIT-DFG extension:
//   When DEP_MATRIX_COLS = DEP_MATRIX_ROWS + 1, the highest-index column
//   (WAIT_FOR_BIND_COL = DEP_MATRIX_COLS - 1) is reserved for JIT bind events.
//   It is set ONLY via the private bind_set_valid_i / bind_set_slot_i port
//   pulsed by bind_resolver instances; never via dep_set_code_i.
//   When DEP_MATRIX_COLS == DEP_MATRIX_ROWS, the bind ports are inert and the
//   module behaves exactly as before.

module bingo_hw_manager_dep_matrix #(
    // Number of rows (one per core — the consumer/dependent side)
    parameter int unsigned DEP_MATRIX_ROWS = 4,
    // Number of columns (one per core — the producer/signaling side, plus optional WAIT_FOR_BIND col)
    parameter int unsigned DEP_MATRIX_COLS = 4,
    // Counter width per cell (8 bits supports up to 255 pending signals)
    parameter int unsigned COUNTER_WIDTH = 8,
    /// Dependent parameters, DO NOT OVERRIDE!
    // pattern to check per row (which columns to check)
    parameter type dep_check_code_t = logic [DEP_MATRIX_COLS-1:0],
    // pattern to write per column (which rows to signal)
    parameter type dep_set_code_t   = logic [DEP_MATRIX_ROWS-1:0],
    // slot/row index width for the JIT bind set port
    parameter int unsigned SLOT_ID_W = (DEP_MATRIX_ROWS > 1) ? $clog2(DEP_MATRIX_ROWS) : 1
) (
    input  logic   clk_i,
    input  logic   rst_ni,
    // Row check interface
    input  logic              [DEP_MATRIX_ROWS-1:0] dep_check_valid_i,
    input  dep_check_code_t   [DEP_MATRIX_ROWS-1:0] dep_check_code_i,
    output logic              [DEP_MATRIX_ROWS-1:0] dep_check_result_o,
    // Column set interface
    input  logic              [DEP_MATRIX_COLS-1:0] dep_set_valid_i,
    output logic              [DEP_MATRIX_COLS-1:0] dep_set_ready_o,
    input  dep_set_code_t     [DEP_MATRIX_COLS-1:0] dep_set_code_i,
    // JIT-DFG private bind set port — increments counter[bind_set_slot_i][DEP_MATRIX_COLS-1]
    // when bind_set_valid_i is pulsed. Tie to '0 if JIT-DFG is not used.
    input  logic                                    bind_set_valid_i,
    input  logic              [SLOT_ID_W-1:0]       bind_set_slot_i
);

    // Counter matrix: counter_q[row][col] counts pending signals
    logic [COUNTER_WIDTH-1:0] counter_d [DEP_MATRIX_ROWS][DEP_MATRIX_COLS];
    logic [COUNTER_WIDTH-1:0] counter_q [DEP_MATRIX_ROWS][DEP_MATRIX_COLS];
    logic [DEP_MATRIX_ROWS-1:0] dep_matrix_clear_row;
    // Per-(row, col) "required but currently unsatisfied" mask used by the row check.
    logic [DEP_MATRIX_ROWS-1:0][DEP_MATRIX_COLS-1:0] dep_check_unsatisfied;

    // dep_set_ready is ALWAYS high — no overlap rejection, no backpressure
    assign dep_set_ready_o = '1;

    // Compute next-state: increment counters for set operations
    always_comb begin
        // Default: hold current state
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                counter_d[r][c] = counter_q[r][c];
            end
        end

        // Increment for each valid set operation
        for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
            if (dep_set_valid_i[c]) begin
                for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                    if (dep_set_code_i[c][r]) begin
                        // Saturating increment
                        if (counter_d[r][c] < {COUNTER_WIDTH{1'b1}}) begin
                            counter_d[r][c] = counter_d[r][c] + 1;
                        end
                    end
                end
            end
        end

        // JIT-DFG: bind_set increments counter[slot][WAIT_FOR_BIND_COL].
        // WAIT_FOR_BIND_COL is conventionally the highest column index.
        // Same-cycle composition with dep_set is safe because the saturating
        // increment cannot lose signals (cell saturates at 0xFF).
        if (bind_set_valid_i && (DEP_MATRIX_COLS > DEP_MATRIX_ROWS)
                && (bind_set_slot_i < DEP_MATRIX_ROWS)) begin
            if (counter_d[bind_set_slot_i][DEP_MATRIX_COLS-1] < {COUNTER_WIDTH{1'b1}}) begin
                counter_d[bind_set_slot_i][DEP_MATRIX_COLS-1] =
                    counter_d[bind_set_slot_i][DEP_MATRIX_COLS-1] + 1;
            end
        end
    end

    // Sequential update: apply set increments and check decrements
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    counter_q[r][c] <= '0;
                end
            end
        end else begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                    if (dep_matrix_clear_row[r] && dep_check_code_i[r][c]) begin
                        // Decrement by 1 for each checked column (saturate at 0)
                        // Apply on top of any set increment from this cycle
                        if (counter_d[r][c] > 0) begin
                            counter_q[r][c] <= counter_d[r][c] - 1;
                        end else begin
                            counter_q[r][c] <= '0;
                        end
                    end else begin
                        counter_q[r][c] <= counter_d[r][c];
                    end
                end
            end
        end
    end

    // Row check: all required counters >= 1.
    // For each (row, col), mark a bit if that column is required by the check
    // code but its counter is currently zero. A row is satisfied iff none of
    // its bits are set (NOR-reduction over the row's mask).
    //
    // The result is combinational over (matrix, dep_check_code_i) and is
    // computed regardless of dep_check_valid_i. Consumption (the saturating
    // decrement) is still gated on valid — see dep_matrix_clear_row below.
    // This lets non-destructive observers query the matrix without forcing a
    // clear, while preserving the "valid && result ⇒ consume" contract for
    // requesting rows.
    always_comb begin
        dep_check_unsatisfied = '0;
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
                dep_check_unsatisfied[r][c] = dep_check_code_i[r][c]
                                            && (counter_q[r][c] == '0);
            end
            dep_check_result_o[r] = ~|dep_check_unsatisfied[r];
        end
    end

    // Clear rows that matched (valid and all satisfied)
    always_comb begin
        dep_matrix_clear_row = '0;
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            if (dep_check_valid_i[r] && dep_check_result_o[r]) begin
                dep_matrix_clear_row[r] = 1'b1;
            end
        end
    end

    // ---- JIT-DFG invariants (sim only) -----------------------------------
    // The WAIT_FOR_BIND column (highest index) must never be set by the
    // public dep_set path when JIT mode is active (COLS > ROWS). It is
    // exclusively driven by bind_set_valid_i.
    `ifndef SYNTHESIS
    if (DEP_MATRIX_COLS > DEP_MATRIX_ROWS) begin : gen_jit_sva
        assert_wait_for_bind_col_not_public_set: assert property (
            @(posedge clk_i) disable iff (!rst_ni)
            !dep_set_valid_i[DEP_MATRIX_COLS-1]
        ) else $error("dep_matrix: public dep_set targeted WAIT_FOR_BIND column %0d", DEP_MATRIX_COLS-1);
    end
    `endif

endmodule
