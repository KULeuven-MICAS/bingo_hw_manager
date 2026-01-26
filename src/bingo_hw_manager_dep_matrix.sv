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
    output logic              [DEP_MATRIX_COLS-1:0] dep_set_ready_o,
    input  dep_set_code_t     [DEP_MATRIX_COLS-1:0] dep_set_code_i
);
    // dependency matrix: dep_matrix_q[row][col]
    logic [DEP_MATRIX_ROWS-1:0][DEP_MATRIX_COLS-1:0] dep_matrix_d, dep_matrix_q;
    logic [DEP_MATRIX_ROWS-1:0]                      dep_matrix_clear_row;

    // Generate ready signal based on overlap check
    // If the bit to be set is already 1 in the matrix, ready is low.
    logic [DEP_MATRIX_COLS-1:0] overlap_find;
    always_comb begin
        overlap_find = '0;
        dep_set_ready_o = '1; // Default to ready
        for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
            for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                // Check for overlap: current state is 1 AND new set bit is 1
                if (!overlap_find[c] && dep_set_valid_i[c] && dep_matrix_q[r][c] && dep_set_code_i[c][r]) begin
                    overlap_find[c] = 1'b1;
                end
            end
            dep_set_ready_o[c] = ~overlap_find[c];
        end
    end

    // Compute next-state with per-column write
    always_comb begin
        dep_matrix_d = dep_matrix_q;
        for (int c = 0; c < DEP_MATRIX_COLS; c++) begin
            // Perform update only if Valid and Ready (no overlap)
            if (dep_set_valid_i[c] && dep_set_ready_o[c]) begin
                // Write column 'c' with the per-row bits from dep_set_code_i[c]
                for (int r = 0; r < DEP_MATRIX_ROWS; r++) begin
                    // Accumulate dependencies using bitwise OR.
                    // New '1's set the bit, while '0's preserve the existing state.
                    // This prevents overwriting existing dependencies with '0's from later updates.
                    // The ready signal ensures we don't 'double set' an existing '1'.
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
                    // Only clear the bits that were checked (and thus satisfied)
                    // We keep the other dependencies that are set but not requested this time.
                    // For example if current row is [1 1 1] and check code is [1 0 1]
                    // The result row will be [0 1 0]
                    dep_matrix_q[r] <= dep_matrix_d[r] & ~dep_check_code_i[r];
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
                // Check if the required bits are set.
                // Instead of strict equality check, we check if the requested bits are present in the matrix row.
                // (dep_matrix_q[r] & dep_check_code_i[r]) masks out the non-interested bits in the matrix.
                // If the result equal to dep_check_code_i[r], it means all required dependencies are satisfied.
                // e.g. matrix=[1 1 1], check=[1 0 1] -> (matrix & check) = [1 0 1] == check -> satisfied
                dep_check_result_o[r] = ((dep_matrix_q[r] & dep_check_code_i[r]) == dep_check_code_i[r]);
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