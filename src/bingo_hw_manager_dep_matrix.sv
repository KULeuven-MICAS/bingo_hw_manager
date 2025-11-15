// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>
module bingo_hw_manager_dep_matrix #(
    // DEP_MATRIX_N: input/output of the dep matrix
    // Num of entries is DEP_MATRIX_N x DEP_MATRIX_N
    parameter int unsigned DEP_MATRIX_N = 4,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter int unsigned INPUT_WIDTH = $clog2(DEP_MATRIX_N),
    parameter type dep_check_code_t = logic [DEP_MATRIX_N-1:0],
    parameter type dep_set_code_t   = logic [DEP_MATRIX_N-1:0]
    
) (
    input  logic   clk_i,
    input  logic   rst_ni,
    input  logic            [DEP_MATRIX_N-1:0] dep_check_valid_i,
    input  dep_check_code_t [DEP_MATRIX_N-1:0] dep_check_code_i,
    output logic            [DEP_MATRIX_N-1:0] dep_check_result_o,
    input  logic            [DEP_MATRIX_N-1:0] dep_set_valid_i,
    input  dep_set_code_t   [DEP_MATRIX_N-1:0] dep_set_code_i
);
    // dependency matrix: dep_matrix_q[row][col]
    logic [DEP_MATRIX_N-1:0] dep_matrix_n [DEP_MATRIX_N-1:0];
    logic [DEP_MATRIX_N-1:0] dep_matrix_q [DEP_MATRIX_N-1:0];

    // Combinational next-state: start from current and apply simultaneous column writes.
    always_comb begin
        // default copy current state
        for (int r = 0; r < DEP_MATRIX_N; r = r + 1)
            dep_matrix_n[r] = dep_matrix_q[r];

        // If any set valid bits, update all selected columns simultaneously.
        for (int c = 0; c < DEP_MATRIX_N; c = c + 1) begin
            if (dep_set_valid_i[c]) begin
                // dep_set_code_i[c] is a vector [DEP_MATRIX_N-1:0], bit r -> value for row r at column c
                for (int r = 0; r < DEP_MATRIX_N; r = r + 1)
                    dep_matrix_n[r][c] = dep_set_code_i[c][r];
            end
        end
    end

    // Synchronous update of stored matrix
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int r = 0; r < DEP_MATRIX_N; r = r + 1)
                dep_matrix_q[r] <= '0;
        end else begin
            for (int r = 0; r < DEP_MATRIX_N; r = r + 1)
                dep_matrix_q[r] <= dep_matrix_n[r];
        end
    end

    // Simultaneous per-row checks: when dep_check_valid_i[r] is asserted, compare row r against dep_check_code_i[r]
    always_comb begin
        dep_check_result_o = '0;
        for (int r = 0; r < DEP_MATRIX_N; r = r + 1) begin
            if (dep_check_valid_i[r])
                dep_check_result_o[r] = (dep_matrix_q[r] == dep_check_code_i[r]);
            else
                dep_check_result_o[r] = 1'b0;
        end
    end

endmodule