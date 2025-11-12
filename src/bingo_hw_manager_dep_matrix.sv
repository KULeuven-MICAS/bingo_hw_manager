// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>
module bingo_hw_manager_dep_matrix #(
    parameter int unsigned DEP_MATRIX_N = 4,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter int unsigned INPUT_WIDTH = $clog2(DEP_MATRIX_N)
    
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic [INPUT_WIDTH-1:0]   dep_check_idx_i,
    input  logic [DEP_MATRIX_N-1:0]  dep_check_code_i,
    input  logic                     dep_check_valid_i,
    output logic                     dep_check_result_o,
    input  logic [INPUT_WIDTH-1:0]   dep_set_idx_i,
    input  logic [DEP_MATRIX_N-1:0]  dep_set_code_i,
    input  logic                     dep_set_valid_i
);
    // dependency matrix: dep_matrix_q[row][col]
    logic [DEP_MATRIX_N-1:0] dep_matrix_n [DEP_MATRIX_N-1:0];
    logic [DEP_MATRIX_N-1:0] dep_matrix_q [DEP_MATRIX_N-1:0];

    // Build next-state: start from current matrix, then update the column
    always_comb begin
        // default: copy current state
        for (int i = 0; i < DEP_MATRIX_N; i = i + 1)
            dep_matrix_n[i] = dep_matrix_q[i];

        // update the dep_set_idx_i'th column with dep_set_code_i only when valid
        if (dep_set_valid_i) begin
            // dep_set_code_i provides one bit per row: dep_set_code_i[row]
            // guard the column-write with valid to avoid accidental writes
            for (int i = 0; i < DEP_MATRIX_N; i = i + 1)
                dep_matrix_n[i][dep_set_idx_i] = dep_set_code_i[i];
        end
    end

    // Synchronous register update and range assertions
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            // initialize matrix to zeros on reset
            for (int i = 0; i < DEP_MATRIX_N; i = i + 1)
                dep_matrix_q[i] <= '0;
        end else begin
            // bounds checks: assert indices are within [0, DEP_MATRIX_N-1] only when corresponding valid is asserted
            if (dep_check_valid_i) begin
                assert (dep_check_idx_i < DEP_MATRIX_N)
                    else $fatal("dep_check_idx_i out of range: %0d (DEP_MATRIX_N=%0d)", dep_check_idx_i, DEP_MATRIX_N);
            end
            if (dep_set_valid_i) begin
                assert (dep_set_idx_i < DEP_MATRIX_N)
                    else $fatal("dep_set_idx_i out of range: %0d (DEP_MATRIX_N=%0d)", dep_set_idx_i, DEP_MATRIX_N);
            end

            // update registers (dep_matrix_n already reflects whether a column write should occur)
            for (int i = 0; i < DEP_MATRIX_N; i = i + 1)
                dep_matrix_q[i] <= dep_matrix_n[i];
        end
    end

    // Compare the requested row to the check code (combinational read)
    always_comb begin
        // Only perform comparison when check is valid and index is in range.
        if (dep_check_valid_i && (dep_check_idx_i < DEP_MATRIX_N))
            dep_check_result_o = (dep_matrix_q[dep_check_idx_i] == dep_check_code_i);
        else
            dep_check_result_o = 1'b0;
    end

endmodule