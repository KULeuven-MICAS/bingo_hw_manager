`timescale 1ns/1ps

module tb_bingo_hw_manager_dep_matrix();

    // testbench parameters (match DUT default)
    localparam int unsigned N = 4;
    localparam int unsigned INPUT_WIDTH = (N > 1) ? $clog2(N) : 1;

    // clock / reset
    logic clk_i;
    logic rst_ni;

    // DUT signals (match new DUT interface)
    logic [N-1:0]                      dep_check_valid_i;
    logic [N-1:0]                      dep_check_result_o;
    logic [N-1:0]                      dep_set_valid_i;

    // arrays of vectors: indexed by row/column, each element is N-bit wide
    logic [N-1:0]                      dep_check_code_i [N-1:0];
    logic [N-1:0]                      dep_set_code_i   [N-1:0];

    // helper variables
    logic [INPUT_WIDTH-1:0] col;
    logic [N-1:0]           pattern;
    logic [N-1:0]           expected_row;

    // Instantiate DUT
    bingo_hw_manager_dep_matrix #(
        .DEP_MATRIX_N(N)
    ) dut (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .dep_check_valid_i(dep_check_valid_i),
        .dep_check_code_i(dep_check_code_i),
        .dep_check_result_o(dep_check_result_o),
        .dep_set_valid_i(dep_set_valid_i),
        .dep_set_code_i(dep_set_code_i)
    );

    // Clock generator: 10 ns period
    initial clk_i = 0;
    always #5 clk_i = ~clk_i;

    // Task: drive a column write (synchronous in DUT)
    task automatic set_column(input int unsigned col_in,
                              input logic [N-1:0] code);
    begin
        // prepare arrays: clear all entries, then assign selected column entry
        for (int i = 0; i < N; i++) begin
            dep_set_code_i[i] = '0;
        end

        // apply at clock edge
        @(posedge clk_i);
        dep_set_code_i[col_in]  <= code;
        dep_set_valid_i         <= {N{1'b0}};
        dep_set_valid_i[col_in] <= 1'b1;

        // allow DUT to sample on next posedge (synchronous update)
        @(posedge clk_i);
        #1;

        // clear signals on next posedge
        @(posedge clk_i);
        dep_set_valid_i         <= '0;
        for (int i = 0; i < N; i++) dep_set_code_i[i] <= '0;
    end
    endtask

    // Task: check a single row (combinational result)
    task automatic check_row(input int unsigned row,
                             input logic [N-1:0] expected_code,
                             input bit expected_result);
    begin
        // prepare all check_code entries to zero, then set target row value
        for (int i = 0; i < N; i++) dep_check_code_i[i] = '0;

        @(posedge clk_i);
        dep_check_code_i[row]   <= expected_code;
        dep_check_valid_i       <= {N{1'b0}};
        dep_check_valid_i[row]  <= 1'b1;

        // allow combinational result to settle within the same cycle
        #1;
        if (dep_check_result_o[row] !== expected_result) begin
            $error("CHECK FAILED: row=%0d expected_code=%b expected_res=%0d got_res=%0d",
                   row, expected_code, expected_result, dep_check_result_o[row]);
            $fatal;
        end else begin
            $display("CHECK OK: row=%0d code=%b result=%0d", row, expected_code, dep_check_result_o[row]);
        end

        // clear at next clock
        @(posedge clk_i);
        dep_check_valid_i[row] <= 1'b0;
        dep_check_code_i[row]  <= '0;
    end
    endtask

    // Test sequence
    initial begin
        // initialize inputs and valids
        for (int i = 0; i < N; i++) begin
            dep_check_code_i[i] = {N{1'b0}}; // Initialize to all zeros
            dep_set_code_i[i]   = {N{1'b0}}; // Initialize to all zeros
        end
        dep_check_valid_i = {N{1'b0}}; // Initialize to all zeros
        dep_set_valid_i   = {N{1'b0}}; // Initialize to all zeros
        col               = '0;        // Initialize to zero
        pattern           = '0;        // Initialize to zero
        expected_row      = '0;        // Initialize to zero

        // apply reset (active low)
        rst_ni = 1'b0;
        repeat (2) @(posedge clk_i);
        rst_ni = 1'b1;
        @(posedge clk_i);
        #1;

        $display("RESET released, expect all rows to be zero");

        // After reset DUT matrix should be zeros => checking row with zero code should pass
        for (int i = 0; i < N; i++) begin
            check_row(i, {N{1'b0}}, 1'b1); // row == 0 should match code 0 -> result 1
        end

        // Set column 1 to pattern 4'b1010 (bit index => row index)
        col     = 1;
        pattern = 4'b1010;
        $display("Setting column %0d with pattern %b", col, pattern);
        set_column(col, pattern);

        // After the set_column sequence the matrix has been updated. Verify each row
        for (int i = 0; i < N; i++) begin
            // build expected_row: a vector with a '1' at position 'col' if pattern[i] is 1
            expected_row = '0;
            if (pattern[i])
                expected_row[col] = 1'b1;

            // check correct code -> expect match (1)
            check_row(i, expected_row, 1'b1);
            // check an incorrect code (flip the expected bit) -> expect no match (0)
            check_row(i, expected_row ^ (1 << col), 1'b0);
        end

        $display("All tests passed");
        #10 $finish;
    end

    // Timeout safety
    initial begin
        #10000;
        $fatal("TIMEOUT");
    end

endmodule