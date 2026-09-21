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
//   1. Every read this master issues carries the SAME AXI ID, and AXI requires same-ID responses
//      to return in issue order. The beats of a descriptor therefore arrive in order and cannot
//      interleave with anything else this master does, no matter how many are in flight. This
//      used to be enforced the blunt way -- one outstanding read -- and it did not need to be.
//   2. The FIFO push is the single commit point: partial beats live in `desc_partial_q` and are
//      never visible downstream. A consumer either sees a whole descriptor or nothing.
//
// WHY PIPELINE IT. The manager walks the descriptor list in order, and a core cannot be granted a
// task the manager has not fetched yet. Serialised fetching therefore costs one AXI-Lite round
// trip to L3 per beat with every core idle, and on a fine-grained graph that dominates the run.
// Overlapping the round trips is the whole fix.
//
// `MaxOutstanding = 1` reproduces the old strictly-serial behaviour, so this is opt-in.
// The task list itself is immutable while the manager runs (the host writes it before `start_i`
// and this master never writes), so there is no concurrent writer to tear against either.
module bingo_hw_manager_task_queue_master #(
    parameter int unsigned TaskQueueDepth = 16,
    /// AXI-Lite reads this master may keep in flight. 1 = the original serial behaviour.
    /// The upper useful bound is the L3 round trip divided by the per-beat issue rate; beyond
    /// that the fabric, not this master, is the limit. It must not exceed TaskQueueDepth, since
    /// in the worst case every beat in flight completes a descriptor that needs a FIFO slot.
    parameter int unsigned MaxOutstanding = 1,
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

    // SEND_AR/WAIT_R collapsed into one RUN state: issuing and retiring are now independent,
    // so there is no state in which the master is doing only one of them.
    typedef enum logic [1:0]{
        IDLE,
        RUN,
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
    // Retire side (R) -- declared first because the issue side's credit counter reads it
    //////////////////////////////
    logic [BeatCntW-1:0]   beat_q;
    logic                  beat_last;
    logic                  beat_accept;
    logic [DescWidth-1:0]  desc_partial_q;
    // The bounds the parameter comment promises, enforced rather than trusted.
    // 0 outstanding can never issue a read, and more beats in flight than the
    // FIFO can hold risks a completed descriptor with nowhere to go.
    if (MaxOutstanding == 0) begin : gen_max_outstanding_zero_check
        initial begin
        $error("MaxOutstanding must be >= 1 (0 can never issue a read).");
        $finish;
        end
    end
    if (MaxOutstanding > TaskQueueDepth) begin : gen_max_outstanding_depth_check
        initial begin
        $error("MaxOutstanding (%0d) exceeds TaskQueueDepth (%0d): a beat in flight may complete a descriptor with no FIFO slot to land in.", MaxOutstanding, TaskQueueDepth);
        $finish;
        end
    end

    logic [DescWidth-1:0]  desc_assembled;

    assign beat_last   = (Beats == 1) ? 1'b1 : (beat_q == BeatCntW'(Beats - 1));
    assign beat_accept = task_queue_axi_lite_resp_i.r_valid && task_queue_axi_lite_req_o.r_ready;

    //////////////////////////////
    // Issue side (AR) -- runs ahead of the retire side by up to MaxOutstanding beats
    //////////////////////////////
    logic [TaskIdWidth-1:0] issue_task_q;   // descriptor the next AR belongs to
    logic [BeatCntW-1:0]    issue_beat_q;   // beat within that descriptor
    logic                   issue_done_q;   // every AR for the whole list has been accepted
    logic                   ar_fire;
    logic                   issue_beat_last;
    logic                   can_issue;

    // Outstanding = ARs accepted minus R beats accepted. One extra bit so the compare against
    // MaxOutstanding cannot alias when both edges land in the same cycle.
    logic [$clog2(MaxOutstanding+1):0] outstanding_q;

    assign ar_fire         = task_queue_axi_lite_req_o.ar_valid && task_queue_axi_lite_resp_i.ar_ready;
    assign issue_beat_last = (Beats == 1) ? 1'b1 : (issue_beat_q == BeatCntW'(Beats - 1));
    // Gate on the FIFO too, not just on credits: in the worst case every beat in flight is a
    // descriptor's last, so each needs a slot. Refusing to issue when the queue is full is the
    // cheap conservative form -- an in-flight last beat simply backpressures on r_ready instead.
    assign can_issue = (cur_state == RUN) && !issue_done_q
                    && (outstanding_q < MaxOutstanding) && !task_queue_full;

    always_ff @(posedge clk_i, negedge rst_ni) begin
        if (!rst_ni) begin
            issue_task_q  <= '0;
            issue_beat_q  <= '0;
            issue_done_q  <= 1'b0;
            outstanding_q <= '0;
        end else if (task_counter_clear) begin
            issue_task_q  <= '0;
            issue_beat_q  <= '0;
            issue_done_q  <= 1'b0;
            outstanding_q <= '0;
        end else begin
            if (ar_fire) begin
                if (!issue_beat_last) begin
                    issue_beat_q <= issue_beat_q + 1'b1;
                end else begin
                    issue_beat_q <= '0;
                    if (issue_task_q == TaskIdWidth'(num_task_i - 1)) issue_done_q <= 1'b1;
                    else                                             issue_task_q <= issue_task_q + 1'b1;
                end
            end
            // Both can fire in the same cycle; the net change is then zero.
            case ({ar_fire, beat_accept})
                2'b10:   outstanding_q <= outstanding_q + 1'b1;
                2'b01:   outstanding_q <= outstanding_q - 1'b1;
                default: outstanding_q <= outstanding_q;
            endcase
        end
    end

    //////////////////////////////
    // Beat assembly
    //////////////////////////////
    // `beat_q` selects which slice of the descriptor the next AR addresses. Beat 0 is the LEAST
    // significant word: the software emitter writes the descriptor low word first at the lower
    // address, so ascending address == ascending significance. Keep the two in step or every
    // descriptor arrives byte-swapped in halves.
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
        next_state = cur_state;
        case (cur_state)
            IDLE: begin
                if (start_i) next_state = RUN;
            end
            RUN: begin
                // The list is finished when the LAST descriptor RETIRES, not when its AR is
                // issued -- with reads in flight those are different cycles.
                if (beat_accept && beat_last && (task_counter_q == (num_task_i - 1))) begin
                    next_state = FINISH;
                end
            end
            FINISH: begin
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // Output Logic
    always_comb begin : task_queue_master_fsm_output_logic
        task_queue_axi_lite_req_o.ar       = '0;
        task_queue_axi_lite_req_o.ar_valid = 1'b0;
        task_counter_en                    = 1'b0;
        task_counter_clear                 = 1'b0;
        reset_start_o                      = '0;
        reset_start_en_o                   = 1'b0;
        case (cur_state)
            IDLE: begin
                // nothing: defaults hold the master quiet until start_i
            end
            RUN: begin
                // ISSUE. Address comes from the ISSUE counters, which run ahead of the retire
                // counters. descriptor stride + within-descriptor beat offset; DescBytes, not the
                // bus width -- conflating the two is what made the old formula work only while a
                // descriptor was exactly one beat.
                task_queue_axi_lite_req_o.ar.addr = task_list_base_addr_i
                                                  + (issue_task_q * DescBytes)
                                                  + (issue_beat_q * BeatBytes);
                task_queue_axi_lite_req_o.ar.prot = 3'b000;
                task_queue_axi_lite_req_o.ar_valid = can_issue;
                // RETIRE. The descriptor index advances once per DESCRIPTOR, not once per beat.
                task_counter_en = beat_accept && beat_last;
            end
            FINISH: begin
                task_counter_clear = 1'b1;
                reset_start_o      = '0;
                reset_start_en_o   = 1'b1;
            end
            default: begin
                // defaults
            end
        endcase
    end

    // Compose the R channel to the task queue fifo.
    // Qualified by RUN rather than by a wait state: responses may now arrive while further ARs are
    // still being issued, so there is no state in which a legitimate beat should be refused. What
    // must NOT happen is accepting a beat outside the run (a stray response would splice into the
    // wrong half of a descriptor), hence the state qualifier is kept. Intermediate beats only need
    // a register, so they do not consult the FIFO; only the committing beat needs a slot.
    assign task_queue_axi_lite_req_o.r_ready = (cur_state == RUN) && (!beat_last || !task_queue_full);
    assign task_queue_push     = beat_accept && beat_last;
    assign task_queue_data_in  = desc_t'(desc_assembled);
endmodule
