// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>
// This module is a master port to send the h2h chiplet done signal to other chiplets
// The set signal will increase the other chiplets' dep check sum by 1
module bingo_hw_manager_h2h_dep_set #(
    parameter int unsigned ChipIdWidth          = 8,
    parameter int unsigned HostAxiLiteAddrWidth = 48,
    parameter int unsigned HostAxiLiteDataWidth = 64,
    parameter type h2h_axi_lite_out_req_t                = logic,
    parameter type h2h_axi_lite_out_resp_t               = logic,
    parameter type bingo_hw_manager_chiplet_dep_set_task_desc_full_t = logic,
    // typedef struct packed{
    //     logic [ReservedBitsForChipletSetTaskDesc-1:0]   reserved_bits;
    //     bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_3;
    //     bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_2;
    //     bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_1;
    //     bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_0;
    //     logic [1:0]                                     num_dep_set;
    //     logic                                           dep_set_all;
    //     bingo_hw_manager_assigned_core_id_t             assigned_core_id;
    //     bingo_hw_manager_assigned_chiplet_id_t          assigned_chiplet_id;
    //     bingo_hw_manager_task_id_t                      task_id;
    //     bingo_hw_manager_task_type_t                    task_type;
    // } bingo_hw_manager_chiplet_dep_set_task_desc_full_t;
    // } bingo_hw_manager_chiplet_dep_set_task_desc_full_t; 
    // Now we put maximum 4 dependencies for each h2h done issue task
    // If want more, the runtime should issue multiple tasks
    // Dependent parameters, DO NOT OVERRIDE!
    parameter type host_axi_lite_addr_t = logic [HostAxiLiteAddrWidth-1:0],
    parameter type host_axi_lite_data_t = logic [HostAxiLiteDataWidth-1:0],
    parameter type host_axi_lite_strb_t = logic [HostAxiLiteDataWidth/8-1:0]
) (
    /// Clock
    input logic clk_i,
    /// Asynchronous reset, active low
    input logic rst_ni,
    // Assume all the chiplet has the same h2h done mailbox base address
    input  host_axi_lite_addr_t                              h2h_mailbox_base_addr_i,
    /// The chiplet done issue interface to other chiplets
    /// HW Manager -----> Other chiplets
    output h2h_axi_lite_out_req_t                            h2h_to_remote_axi_lite_req_o,
    input  h2h_axi_lite_out_resp_t                           h2h_to_remote_axi_lite_resp_i,
    //  Get the h2h set info from the task queue
    //  The data/valid/ready interface from FIFO
    //  After sending all the h2h done signals, it will assert ready
    input bingo_hw_manager_chiplet_dep_set_task_desc_full_t  h2h_dep_set_task_desc_i,
    input logic                                              h2h_dep_set_task_desc_valid_i,
    output logic                                             h2h_dep_set_task_desc_ready_o
);

    logic h2h_dep_set_counter_en;
    logic h2h_dep_set_counter_clear;
    logic [1:0] h2h_done_counter_q;
    counter #(
        .WIDTH(2)
    ) i_h2h_dep_set_counter (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .clear_i   (h2h_dep_set_counter_clear),
        .en_i      (h2h_dep_set_counter_en),
        .load_i    (1'b0),
        .down_i    (1'b0),
        .d_i       ('0),
        .q_o       (h2h_done_counter_q),
        .overflow_o(/*unused*/)
    );
    assign h2h_dep_set_counter_en = h2h_to_remote_axi_lite_req_o.w_valid && h2h_to_remote_axi_lite_resp_i.w_ready;
    typedef enum logic [1:0]{
        h2h_dep_set_IDLE,
        h2h_dep_set_SEND_AW,
        h2h_dep_set_SEND_W,
        h2h_dep_set_FINISH
    } h2h_dep_set_fsm_t;

    h2h_dep_set_fsm_t cur_state, next_state;
    // State Update
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            cur_state <= h2h_dep_set_IDLE;
        end else begin
            cur_state <= next_state;
        end
    end

    // Next State Logic
    always_comb begin : h2h_dep_set_fsm_next_state_logic
        // Default values
        next_state = cur_state;
        case (cur_state)
            h2h_dep_set_IDLE: begin
                if (h2h_dep_set_task_desc_valid_i) begin
                    next_state = h2h_dep_set_SEND_AW;
                end
            end
            h2h_dep_set_SEND_AW: begin
                if (h2h_to_remote_axi_lite_req_o.aw_valid && h2h_to_remote_axi_lite_resp_i.aw_ready) begin
                    next_state = h2h_dep_set_SEND_W;
                end
            end
            h2h_dep_set_SEND_W: begin
                // Here we need to decide whether to go to FINISH or SEND_AW again
                // case 0: if set_all=1 -> go to finish
                // case 1: if set_all=0 and counter_q == num_dep-1 -> we have sent all -> go to finish
                // case 2: if set_all=0 and counter_q < num_dep-1 -> go to send_aw again
                if (h2h_to_remote_axi_lite_req_o.w_valid && h2h_to_remote_axi_lite_resp_i.w_ready) begin
                    if (h2h_dep_set_task_desc_i.dep_set_all) begin
                        next_state = h2h_dep_set_FINISH;
                    end else begin
                        if (h2h_done_counter_q == (h2h_dep_set_task_desc_i.num_dep_set)) begin
                            next_state = h2h_dep_set_FINISH;
                        end else begin
                            next_state = h2h_dep_set_SEND_AW;
                        end
                    end
                end
            end
            h2h_dep_set_FINISH: begin
                next_state = h2h_dep_set_IDLE;
            end
            default: begin
                next_state = h2h_dep_set_IDLE;
            end
        endcase
    end
    // Output Logic
    always_comb begin : h2h_dep_set_fsm_output_logic
        // Default values
        h2h_dep_set_task_desc_ready_o = 1'b0;
        h2h_dep_set_counter_clear = 1'b0;
        h2h_to_remote_axi_lite_req_o.aw = '0;
        h2h_to_remote_axi_lite_req_o.aw_valid = 1'b0;
        h2h_to_remote_axi_lite_req_o.w = '0;
        h2h_to_remote_axi_lite_req_o.w_valid = 1'b0;
        case (cur_state)
            h2h_dep_set_IDLE: begin
                h2h_dep_set_task_desc_ready_o = 1'b0;
                h2h_dep_set_counter_clear = 1'b0;
                h2h_to_remote_axi_lite_req_o.aw = '0;
                h2h_to_remote_axi_lite_req_o.aw_valid = 1'b0;
                h2h_to_remote_axi_lite_req_o.w = '0;
                h2h_to_remote_axi_lite_req_o.w_valid = 1'b0;
            end
            // To make it easy, make two states for sending AW and W channels
            h2h_dep_set_SEND_AW: begin
                // In the SEND AW, it will first check if this is a set all
                // if set_all=1 -> Aw = {8'0xFF,           40'h2h_mailbox_base_addr_i}
                // if set_all=0 -> Aw = {8'current_chip_id,40'h2h_mailbox_base_addr_i}
                h2h_to_remote_axi_lite_req_o.aw_valid = 1'b1;
                if (h2h_dep_set_task_desc_i.dep_set_all) begin
                    h2h_to_remote_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-1 -: ChipIdWidth] = '1; // all 1 means broadcast
                    h2h_to_remote_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-ChipIdWidth-1:0] = h2h_mailbox_base_addr_i[HostAxiLiteAddrWidth-ChipIdWidth-1:0];
                    h2h_to_remote_axi_lite_req_o.aw.prot = '0;
                end else begin
                    case (h2h_done_counter_q)
                        2'b00:  h2h_to_remote_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-1 -: ChipIdWidth] = h2h_dep_set_task_desc_i.dep_set_chiplet_id_0;
                        2'b01:  h2h_to_remote_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-1 -: ChipIdWidth] = h2h_dep_set_task_desc_i.dep_set_chiplet_id_1;
                        2'b10:  h2h_to_remote_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-1 -: ChipIdWidth] = h2h_dep_set_task_desc_i.dep_set_chiplet_id_2;
                        2'b11:  h2h_to_remote_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-1 -: ChipIdWidth] = h2h_dep_set_task_desc_i.dep_set_chiplet_id_3;
                        default: h2h_to_remote_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-1 -: ChipIdWidth] = '0;
                    endcase
                    h2h_to_remote_axi_lite_req_o.aw.addr[HostAxiLiteAddrWidth-ChipIdWidth-1:0] = h2h_mailbox_base_addr_i[HostAxiLiteAddrWidth-ChipIdWidth-1:0];
                    h2h_to_remote_axi_lite_req_o.aw.prot = '0;
                end
                h2h_dep_set_task_desc_ready_o = 1'b0;
                h2h_dep_set_counter_clear = 1'b0;
                h2h_to_remote_axi_lite_req_o.w = '0;
                h2h_to_remote_axi_lite_req_o.w_valid = 1'b0;
            end
            h2h_dep_set_SEND_W: begin
                // In the send w, it will always send the task id as data
                h2h_to_remote_axi_lite_req_o.w_valid = 1'b1;
                h2h_to_remote_axi_lite_req_o.w.data = { {(HostAxiLiteDataWidth-$bits(h2h_dep_set_task_desc_i.task_id)){1'b0}}, h2h_dep_set_task_desc_i.task_id };
                h2h_to_remote_axi_lite_req_o.w.strb = '1;
                h2h_dep_set_task_desc_ready_o = 1'b0;
                h2h_dep_set_counter_clear = 1'b0;
                h2h_to_remote_axi_lite_req_o.aw = '0;
                h2h_to_remote_axi_lite_req_o.aw_valid = 1'b0;
            end
            h2h_dep_set_FINISH: begin
                h2h_dep_set_task_desc_ready_o = 1'b1;
                h2h_dep_set_counter_clear = 1'b1;
                h2h_to_remote_axi_lite_req_o.aw = '0;
                h2h_to_remote_axi_lite_req_o.aw_valid = 1'b0;
                h2h_to_remote_axi_lite_req_o.w = '0;
                h2h_to_remote_axi_lite_req_o.w_valid = 1'b0;
            end
        endcase
    end
    // Tie off the ar/r channels
    always_comb begin: tie_off_axi_lite_r_ar_channels
        h2h_to_remote_axi_lite_req_o.ar = '0;
        h2h_to_remote_axi_lite_req_o.ar_valid  = 1'b0;
        h2h_to_remote_axi_lite_req_o.r_ready   = 1'b0;
    end
    // Compose b channels
    always_comb begin: compose_axi_lite_b_channels
        // D2D will return a fake B later
        // So we do not care about B response here
        h2h_to_remote_axi_lite_req_o.b_ready = 1'b1;
    end
endmodule