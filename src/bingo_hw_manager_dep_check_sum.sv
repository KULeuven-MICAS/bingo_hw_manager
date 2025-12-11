// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// This module is the check sum module
// The host will issue the approprate chiplet blocking task into the task queue
// this task will holds the information on in total it needs how many other chiplets this task requires
// Then it will wait until the h2h done queue to fill with the task to increase the counter until the counter reaches the required dep_check_sum_i
module bingo_hw_manager_dep_check_sum #(
    parameter int unsigned CHECKSUM_WIDTH = 8,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter type dep_check_sum_t = logic [CHECKSUM_WIDTH-1:0]
) (
    input  logic           clk_i,
    input  logic           rst_ni,
    input  logic           dep_check_sum_valid_i,
    output logic           dep_check_sum_ready_o,
    input  dep_check_sum_t dep_check_sum_i,
    input  logic           dep_set_sum_valid_i,
    output logic           dep_set_sum_ready_o
);
    logic counter_clear;
    logic counter_en;
    dep_check_sum_t counter_q;
    counter #(
        .WIDTH(CHECKSUM_WIDTH)
    ) i_counter (
        .clk_i     (clk_i        ),
        .rst_ni    (rst_ni       ),
        .clear_i   (counter_clear),
        .en_i      (counter_en   ),
        .load_i    (1'b0         ),
        .down_i    (1'b0         ),
        .d_i       ('0           ),
        .q_o       (counter_q    ),
        .overflow_o(/* unused */)
    );
    always_comb begin : compose_counter_signal
        dep_check_sum_ready_o = (counter_q == dep_check_sum_i);
        dep_set_sum_ready_o = (counter_q < dep_check_sum_i) && dep_check_sum_valid_i;
        counter_en = dep_check_sum_valid_i && dep_set_sum_valid_i && dep_set_sum_ready_o;
        counter_clear = dep_check_sum_ready_o;
    end
endmodule