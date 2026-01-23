// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>
module bingo_hw_manager_dep_matrix #(
    // Number of rows (producer)
    parameter int unsigned DEP_MATRIX_ROWS = 4,
    // Number of columns (consumer)
    parameter int unsigned DEP_MATRIX_COLS = 4,
    /// Dependent parameters, DO NOT OVERRIDE!
    // pattern to check per row
    parameter type dep_check_code_t = logic [DEP_MATRIX_COLS-1:0],
    // pattern to write per column
    parameter type dep_set_code_t   = logic [DEP_MATRIX_ROWS-1:0]
    
) (
    input  logic   clk_i,
    input  logic   rst_ni,
    // Row check interface
    input  logic              [DEP_MATRIX_ROWS-1:0] dep_check_valid_i,
    input  dep_check_code_t   [DEP_MATRIX_ROWS-1:0] dep_check_code_i,
    output logic              [DEP_MATRIX_ROWS-1:0] dep_check_result_o,
    // Column set interface
    input  logic              [DEP_MATRIX_COLS-1:0] dep_set_valid_i,
    input  dep_set_code_t     [DEP_MATRIX_COLS-1:0] dep_set_code_i
);
    // dependency matrix: dep_matrix_q[row][col]
    logic [DEP_MATRIX_ROWS-1:0][DEP_MATRIX_COLS-1:0] dep_matrix_d, dep_matrix_q;
    logic [DEP_MATRIX_ROWS-1:0]                      dep_matrix_clear_row;

    // Compute next-state with per-column write
    always_comb begin
        dep_matrix_d = dep_matrix_q;
        for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
            if (dep_set_valid_i[c]) begin
                // Write column 'c' with the per-row bits from dep_set_code_i[c]
                for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                    // Accumulate dependencies using bitwise OR.
                    // New '1's set the bit, while '0's preserve the existing state.
                    // This prevents overwriting existing dependencies with '0's from later updates.
                    // For example a normal node followed by a dummy set
                    // The normal node set [1 0 0], the dummy set [0 1 0]
                    // The final result should be [1 1 0]
                    dep_matrix_d[r][c] = dep_matrix_d[r][c] | dep_set_code_i[c][r];
                end
            end
        end
    end

    // Sequential update with optional row clear on successful check
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dep_matrix_q <= '0;
        end else begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                if (dep_matrix_clear_row[r]) begin
                    dep_matrix_q[r] <= '0;
                end else begin
                    dep_matrix_q[r] <= dep_matrix_d[r];
                end
            end
        end
    end

    // Row check: compare stored row against dep_check_code_i[r] when valid
    always_comb begin
        dep_check_result_o = '0;
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            if (dep_check_valid_i[r]) begin
                dep_check_result_o[r] = (dep_matrix_q[r] == dep_check_code_i[r]);
            end
        end
    end

    // Clear rows that matched (valid and equal)
    always_comb begin
        dep_matrix_clear_row = '0;
        for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
            if (dep_check_valid_i[r] && dep_check_result_o[r]) begin
                dep_matrix_clear_row[r] = 1'b1;
            end
        end
    end
endmodule