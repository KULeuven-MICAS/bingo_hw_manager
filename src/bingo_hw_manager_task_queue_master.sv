// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>


// Reads `num_task_i` task descriptors from `task_list_base_addr_i` and presents them to the
// rest of the manager through a FIFO.
//
// A DESCRIPTOR IS NO LONGER A BUS BEAT.
// ------------------------------------
// `data_t` is one AXI-Lite read beat; `desc_t` is one task descriptor. The descriptor may be an
// integer multiple of the beat width (`Beats`), because the host narrow fabric it travels over is
// fixed at 64 bit while the descriptor has outgrown that. The two used to be the same parameter,
// and three separate things silently rode on that equality: the FIFO element type, the R-channel
// width, and the address stride. They are now separate by construction.
//
// ATOMICITY. AXI-Lite has no bursts, so a multi-beat descriptor is several independent
// transactions. Two properties make the assembled descriptor atomic anyway:
//   1. This FSM keeps exactly ONE read outstanding (SEND_AR waits for its own R before issuing the
//      next AR), so the beats of a descriptor cannot interleave with anything else this master
//      does, and they arrive in issue order. No reordering protocol, no tags.
//   2. The FIFO push is the single commit point: partial beats live in `desc_partial_q` and are
//      never visible downstream. A consumer either sees a whole descriptor or nothing.
// The task list itself is immutable while the manager runs (the host writes it before `start_i`
// and this master never writes), so there is no concurrent writer to tear against either.
module bingo_hw_manager_task_queue_master #(
    parameter int unsigned TaskQueueDepth = 16,
    parameter int unsigned TaskIdWidth = 12,
    parameter int unsigned CfgBusWidth = 32,
    parameter type     req_lite_t   = logic,
    parameter type     resp_lite_t  = logic,
    parameter type     addr_t       = logic,
    /// One AXI-Lite data beat on the host narrow fabric.
    parameter type     data_t       = logic [63:0],
    /// One whole task descriptor. $bits(desc_t) MUST be an integer multiple of $bits(data_t).
    parameter type     desc_t       = logic [63:0],
    // Dependent parameters, DO NOT OVERRIDE
    parameter int unsigned BeatWidth = $bits(data_t),
    parameter int unsigned DescWidth = $bits(desc_t),
    parameter int unsigned Beats     = DescWidth / BeatWidth,
    parameter int unsigned BeatBytes = BeatWidth / 8,
    parameter int unsigned DescBytes = DescWidth / 8,
    parameter int unsigned BeatCntW  = (Beats > 1) ? $clog2(Beats) : 1
) (
    input  logic       clk_i,   // Clock
    input  logic       rst_ni,  // Asynchronous reset active low
    input  addr_t                  task_list_base_addr_i,  // The task list base address specified by the host
    input  logic [CfgBusWidth-1:0] num_task_i,       // The number of tasks specified by the host
    input  logic [CfgBusWidth-1:0] start_i,          // Start signal
    output logic [CfgBusWidth-1:0] reset_start_o,    // Reset start signal to zero
    output logic                   reset_start_en_o, // Reset start enable signal
    // AXI Lite Master Interface to get task
    output req_lite_t              task_queue_axi_lite_req_o,
    input  resp_lite_t             task_queue_axi_lite_resp_i,
    // Received task descriptor to internal Bingo HW Manager modules
    // Standard FIFO Interface
    output desc_t                  task_queue_data_o,
    input  logic                   task_queue_pop_i,
    output logic                   task_queue_empty_o
);

    // A descriptor must tile the bus exactly; a remainder would silently drop its top bits.
    if (DescWidth % BeatWidth != 0) begin : gen_desc_width_check
        initial begin
            $error("Task descriptor width (%0d) is not an integer multiple of the AXI-Lite beat width (%0d).",
                   DescWidth, BeatWidth);
            $finish;
        end
    end

    typedef enum logic [1:0]{
        IDLE,
        SEND_AR,
        WAIT_R,
        FINISH
    } task_queue_master_fsm_t;
    task_queue_master_fsm_t cur_state, next_state;
    //////////////////////////////
    // Task Queue FIFO signals
    //////////////////////////////
    logic       task_queue_full;
    logic       task_queue_push;
    desc_t      task_queue_data_in;

    //////////////////////////////
    // Counter signals
    //////////////////////////////
    logic                   task_counter_en;
    logic                   task_counter_clear;
    logic [TaskIdWidth-1:0] task_counter_q;
    counter #(
        .WIDTH ( TaskIdWidth )
    ) i_task_counter (
        .clk_i          ( clk_i                     ),
        .rst_ni         ( rst_ni                    ),
        .clear_i        ( task_counter_clear        ),
        .en_i           ( task_counter_en           ),
        .load_i         ( 1'b0                      ),
        .down_i         ( 1'b0                      ),
        .d_i            ( '0                        ),
        .q_o            ( task_counter_q            ),
        .overflow_o     ( /*not used*/              )
    );

    //////////////////////////////
    // Beat assembly
    //////////////////////////////
    // `beat_q` selects which slice of the descriptor the next AR addresses. Beat 0 is the LEAST
    // significant word: the software emitter writes the descriptor low word first at the lower
    // address, so ascending address == ascending significance. Keep the two in step or every
    // descriptor arrives byte-swapped in halves.
    logic [BeatCntW-1:0]   beat_q;
    logic                  beat_last;
    logic                  beat_accept;
    logic [DescWidth-1:0]  desc_partial_q;
    logic [DescWidth-1:0]  desc_assembled;

    assign beat_last   = (Beats == 1) ? 1'b1 : (beat_q == BeatCntW'(Beats - 1));
    assign beat_accept = task_queue_axi_lite_resp_i.r_valid && task_queue_axi_lite_req_o.r_ready;

    // Hold every beat but the last; splice the last one in combinationally so the descriptor is
    // pushed on the same handshake that completes it (no extra state, no bubble).
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            beat_q         <= '0;
            desc_partial_q <= '0;
        end else begin
            if (task_counter_clear) begin
                beat_q         <= '0;
                desc_partial_q <= '0;
            end else if (beat_accept) begin
                if (beat_last) begin
                    beat_q         <= '0;
                    desc_partial_q <= '0;
                end else begin
                    desc_partial_q[beat_q*BeatWidth +: BeatWidth] <= task_queue_axi_lite_resp_i.r.data;
                    beat_q                                       <= beat_q + 1'b1;
                end
            end
        end
    end

    always_comb begin : assemble_descriptor
        desc_assembled                              = desc_partial_q;
        desc_assembled[beat_q*BeatWidth +: BeatWidth] = task_queue_axi_lite_resp_i.r.data;
    end

    fifo_v3 #(
        .FALL_THROUGH ( 1'b0                   ),
        .DEPTH        ( TaskQueueDepth         ),
        .dtype        ( desc_t                 )
    ) i_task_queue (
        .clk_i       ( clk_i                ),
        .rst_ni      ( rst_ni               ),
        .testmode_i  ( 1'b0                 ),
        .flush_i     ( 1'b0                 ),
        .full_o      ( task_queue_full      ),
        .empty_o     ( task_queue_empty_o   ),
        .usage_o     ( /*not used*/         ),
        .data_i      ( task_queue_data_in   ),
        .push_i      ( task_queue_push      ),
        .data_o      ( task_queue_data_o    ),
        .pop_i       ( task_queue_pop_i     )
    );
    // We do not need the write channels for the task queue master
    always_comb begin : tie_off_write_channels
        task_queue_axi_lite_req_o.w = '0;
        task_queue_axi_lite_req_o.w_valid = 1'b0;
        task_queue_axi_lite_req_o.aw = '0;
        task_queue_axi_lite_req_o.aw_valid = 1'b0;
        task_queue_axi_lite_req_o.b_ready = 1'b0;
    end

    // State Update
    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            cur_state <= IDLE;
        end else begin
            cur_state <= next_state;
        end
    end

    // Next State Logic
    always_comb begin : task_queue_master_fsm_next_state_logic
        // Default values
        next_state = cur_state;
        case (cur_state)
            IDLE: begin
                if (start_i) begin
                    next_state = SEND_AR;
                end
            end
            SEND_AR: begin
                if (task_queue_axi_lite_req_o.ar_valid && task_queue_axi_lite_resp_i.ar_ready) begin
                    next_state = WAIT_R;
                end
            end
            WAIT_R: begin
                if (beat_accept) begin
                    // Only the LAST beat completes a descriptor; intermediate beats just fetch the
                    // next slice of the same one, so the terminal compare must not be evaluated
                    // for them or the list would end `Beats` times too early.
                    if (!beat_last) begin
                        next_state = SEND_AR;
                    end else if (task_counter_q == (num_task_i - 1)) begin
                        next_state = FINISH;
                    end else begin
                        next_state = SEND_AR;
                    end
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
    always_comb begin : task_queue_master_fsm_output_logic
        // Default values
        task_queue_axi_lite_req_o.ar = '0;
        task_queue_axi_lite_req_o.ar_valid = 1'b0;
        task_counter_en = 1'b0;
        task_counter_clear = 1'b0;
        reset_start_o = '0;
        reset_start_en_o = 1'b0;
        case (cur_state)
            IDLE: begin
                task_queue_axi_lite_req_o.ar = '0;
                task_queue_axi_lite_req_o.ar_valid = 1'b0;
                task_counter_en = 1'b0;
                task_counter_clear = 1'b0;
            end
            SEND_AR: begin
                // descriptor stride + within-descriptor beat offset. DescBytes, not the bus width:
                // conflating the two is what made the old formula work only while a descriptor was
                // exactly one beat.
                task_queue_axi_lite_req_o.ar.addr = task_list_base_addr_i
                                                  + (task_counter_q * DescBytes)
                                                  + (beat_q * BeatBytes);
                task_queue_axi_lite_req_o.ar.prot = 3'b000;
                task_queue_axi_lite_req_o.ar_valid = 1'b1;
                task_counter_en = 1'b0;
                task_counter_clear = 1'b0;
                reset_start_o = '0;
                reset_start_en_o = 1'b0;
            end
            WAIT_R: begin
                // The descriptor index advances once per DESCRIPTOR, not once per beat.
                task_counter_en = beat_accept && beat_last;
            end
            FINISH: begin
                task_queue_axi_lite_req_o.ar = '0;
                task_queue_axi_lite_req_o.ar_valid = 1'b0;
                task_counter_en = 1'b0;
                task_counter_clear = 1'b1;
                reset_start_o = '0;
                reset_start_en_o = 1'b1;
            end
        endcase
    end
    // Compose the R channel to the task queue fifo.
    // r_ready is qualified by WAIT_R: the old unconditional `~full` accepted a beat in ANY state,
    // which with more than one beat in flight would splice a stray response into the wrong half of
    // a descriptor. Intermediate beats only need a register, so they do not consult the FIFO; only
    // the committing beat needs space.
    assign task_queue_axi_lite_req_o.r_ready = (cur_state == WAIT_R) && (!beat_last || !task_queue_full);
    assign task_queue_push     = beat_accept && beat_last;
    assign task_queue_data_in  = desc_t'(desc_assembled);
endmodule
