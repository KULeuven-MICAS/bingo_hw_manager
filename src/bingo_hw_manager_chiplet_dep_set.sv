// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>
// This module is a master port to send the chiplet chiplet dep set signal to other chiplets
// The inputs are from the Wait Dep Check Queues (in total NUM_CORES_PER_CLUSTER queues).

module bingo_hw_manager_chiplet_dep_set #(
    parameter int unsigned ChipIdWidth                = 8,
    parameter int unsigned HostAxiLiteAddrWidth       = 48,
    parameter int unsigned HostAxiLiteDataWidth       = 64,
    parameter type host_axi_lite_req_t                = logic,
    parameter type host_axi_lite_resp_t               = logic,
    parameter type bingo_hw_manager_task_desc_full_t  = logic,
    // Dependent parameters, DO NOT OVERRIDE!
    parameter type host_axi_lite_addr_t = logic [HostAxiLiteAddrWidth-1:0],
    parameter type host_axi_lite_data_t = logic [HostAxiLiteDataWidth-1:0],
    parameter type host_axi_lite_strb_t = logic [HostAxiLiteDataWidth/8-1:0]
) (
    /// Clock
    input logic clk_i,
    /// Asynchronous reset, active low
    input logic rst_ni,
    // Assume all the chiplet has the same chiplet mailbox base address
    input  host_axi_lite_addr_t                              chiplet_mailbox_base_addr_i,
    /// The chiplet done issue interface to other chiplets
    /// HW Manager -----> Other chiplets
    output host_axi_lite_req_t                               to_remote_chiplet_axi_lite_req_o,
    input  host_axi_lite_resp_t                              to_remote_chiplet_axi_lite_resp_i,
    //  Get the chiplet set info from the wait dep check queues
    //  The data/valid/ready interface from FIFO
    input bingo_hw_manager_task_desc_full_t                  chiplet_dep_set_task_desc_i,
    input logic                                              chiplet_dep_set_task_desc_valid_i,
    output logic                                             chiplet_dep_set_task_desc_ready_o
);

    typedef enum logic [1:0]{
        chiplet_dep_set_IDLE,
        chiplet_dep_set_SEND_AW,
        chiplet_dep_set_SEND_W,
        chiplet_dep_set_FINISH
    } chiplet_dep_set_fsm_t;

    chiplet_dep_set_fsm_t cur_state, next_state;
    // State Update
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            cur_state <= chiplet_dep_set_IDLE;
        end else begin
            cur_state <= next_state;
        end
    end

    // Next State Logic
    always_comb begin : chiplet_dep_set_fsm_next_state_logic
        // Default values
        next_state = cur_state;
        case (cur_state)
            chiplet_dep_set_IDLE: begin
                if (chiplet_dep_set_task_desc_valid_i) begin
                    next_state = chiplet_dep_set_SEND_AW;
                end
            end
            chiplet_dep_set_SEND_AW: begin
                if (to_remote_chiplet_axi_lite_req_o.aw_valid && to_remote_chiplet_axi_lite_resp_i.aw_ready) begin
                    next_state = chiplet_dep_set_SEND_W;
                end
            end
            chiplet_dep_set_SEND_W: begin
                if (to_remote_chiplet_axi_lite_req_o.w_valid && to_remote_chiplet_axi_lite_resp_i.w_ready) begin
                    next_state = chiplet_dep_set_FINISH;
                end
            end
            chiplet_dep_set_FINISH: begin
                next_state = chiplet_dep_set_IDLE;
            end
            default: begin
                next_state = chiplet_dep_set_IDLE;
            end
        endcase
    end
    // Output Logic
    always_comb begin : chiplet_dep_set_fsm_output_logic
        // Default values
        chiplet_dep_set_task_desc_ready_o = 1'b0;
        to_remote_chiplet_axi_lite_req_o.aw = '0;
        to_remote_chiplet_axi_lite_req_o.aw_valid = 1'b0;
        to_remote_chiplet_axi_lite_req_o.w = '0;
        to_remote_chiplet_axi_lite_req_o.w_valid = 1'b0;
        case (cur_state)
            chiplet_dep_set_IDLE: begin
                chiplet_dep_set_task_desc_ready_o = 1'b0;
                to_remote_chiplet_axi_lite_req_o.aw = '0;
                to_remote_chiplet_axi_lite_req_o.aw_valid = 1'b0;
                to_remote_chiplet_axi_lite_req_o.w = '0;
                to_remote_chiplet_axi_lite_req_o.w_valid = 1'b0;
            end
            // To make it easy, make two states for sending AW and W channels
            chiplet_dep_set_SEND_AW: begin
                // In the SEND AW, it will first check if this is a set all
                // if set_all=1 -> Aw = {8'0xFF,           40'chiplet_mailbox_base_addr_i}
                // if set_all=0 -> Aw = {8'current_chip_id,40'chiplet_mailbox_base_addr_i}
                chiplet_dep_set_task_desc_ready_o = 1'b0;
                to_remote_chiplet_axi_lite_req_o.aw_valid = 1'b1;
                to_remote_chiplet_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-ChipIdWidth-1:0] = chiplet_mailbox_base_addr_i[HostAxiLiteAddrWidth-ChipIdWidth-1:0];
                to_remote_chiplet_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-1 -: ChipIdWidth] = chiplet_dep_set_task_desc_i.dep_set_info.dep_set_all_chiplet ? '1 : chiplet_dep_set_task_desc_i.dep_set_info.dep_set_chiplet_id; 
                to_remote_chiplet_axi_lite_req_o.aw.prot = '0;
                to_remote_chiplet_axi_lite_req_o.w = '0;
                to_remote_chiplet_axi_lite_req_o.w_valid = 1'b0;
            end
            chiplet_dep_set_SEND_W: begin
                // In the send w, it will always send the task id as data
                chiplet_dep_set_task_desc_ready_o = 1'b0;
                to_remote_chiplet_axi_lite_req_o.w_valid = 1'b1;
                to_remote_chiplet_axi_lite_req_o.w.data = chiplet_dep_set_task_desc_i;
                to_remote_chiplet_axi_lite_req_o.w.strb = '1;
                to_remote_chiplet_axi_lite_req_o.aw = '0;
                to_remote_chiplet_axi_lite_req_o.aw_valid = 1'b0;
            end
            chiplet_dep_set_FINISH: begin
                chiplet_dep_set_task_desc_ready_o = 1'b1;
                to_remote_chiplet_axi_lite_req_o.aw = '0;
                to_remote_chiplet_axi_lite_req_o.aw_valid = 1'b0;
                to_remote_chiplet_axi_lite_req_o.w = '0;
                to_remote_chiplet_axi_lite_req_o.w_valid = 1'b0;
            end
        endcase
    end
    // Tie off the ar/r channels
    always_comb begin: tie_off_axi_lite_r_ar_channels
        to_remote_chiplet_axi_lite_req_o.ar = '0;
        to_remote_chiplet_axi_lite_req_o.ar_valid  = 1'b0;
        to_remote_chiplet_axi_lite_req_o.r_ready   = 1'b0;
    end
    // Compose b channels
    always_comb begin: compose_axi_lite_b_channels
        // D2D will return a fake B later
        // So we do not care about B response here
        to_remote_chiplet_axi_lite_req_o.b_ready = 1'b1;
    end
endmodule