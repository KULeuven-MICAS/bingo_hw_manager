// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>
// This module handles the handshake between teh wait dep check queues and the matrix dep check + ready/checkout queues

module bingo_hw_manager_dep_check_manager (
    /// Clock
    input logic clk_i,
    /// Asynchronous reset, active low
    input logic rst_ni,
    // From the wait dep check queue
    input logic wait_dep_check_queue_valid_i,
    output logic wait_dep_check_queue_ready_o,
    // To the matrix dep check + ready/checkout queues
    // To dep matrix check
    output logic dep_check_valid_o,
    input logic dep_check_ready_i,
    // To ready queue and checkout queue
    output logic ready_and_checkout_queue_valid_o,
    input logic ready_and_checkout_queue_ready_i
);
    typedef enum logic [1:0]{
        IDLE,
        WAIT_DEP_CHECK,
        WAIT_QUEUES,
        FINISH
    } dep_check_manager_fsm_t;

    dep_check_manager_fsm_t cur_state, next_state;
    // State Update
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            cur_state <= IDLE;
        end else begin
            cur_state <= next_state;
        end
    end
    // Next State Logic
    always_comb begin : dep_check_manager_fsm_next_state_logic
        // Default values
        next_state = cur_state;
        case (cur_state)
            IDLE: begin
                if (wait_dep_check_queue_valid_i) begin
                    next_state = WAIT_DEP_CHECK;
                end
            end
            WAIT_DEP_CHECK: begin
                if (dep_check_ready_i) begin
                    next_state = WAIT_QUEUES;
                end
            end
            WAIT_QUEUES: begin
                if (ready_and_checkout_queue_ready_i) begin
                    next_state = FINISH;
                end
            end
            FINISH: begin
                next_state = IDLE;
            end
            default: begin
                next_state = IDLE;
            end
        endcase
    end
    // Output Logic
    always_comb begin : dep_check_manager_fsm_output_logic
        // Default values
        wait_dep_check_queue_ready_o = 1'b0;
        dep_check_valid_o = 1'b0;
        ready_and_checkout_queue_valid_o = 1'b0;
        case (cur_state)
            IDLE: begin
                wait_dep_check_queue_ready_o = 1'b0;
                dep_check_valid_o = 1'b0;
                ready_and_checkout_queue_valid_o = 1'b0;
            end
            WAIT_DEP_CHECK: begin
                wait_dep_check_queue_ready_o = 1'b0;
                dep_check_valid_o = 1'b1;
                ready_and_checkout_queue_valid_o = 1'b0;
            end
            WAIT_QUEUES: begin
                wait_dep_check_queue_ready_o = 1'b0;
                dep_check_valid_o = 1'b0;
                ready_and_checkout_queue_valid_o = 1'b1;
            end
            FINISH: begin
                wait_dep_check_queue_ready_o = 1'b1;
                dep_check_valid_o = 1'b0;
                ready_and_checkout_queue_valid_o = 1'b0;
            end
            default: begin
                wait_dep_check_queue_ready_o = 1'b0;
                dep_check_valid_o = 1'b0;
                ready_and_checkout_queue_valid_o = 1'b0;
            end
        endcase
    end
endmodule