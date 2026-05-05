// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// JIT-DFG bind_resolver
//
// One instance per (cluster, core) lane. Sits between the per-core
// `waiting_dep_check_queue` output and the downstream dep_check_manager /
// dep_matrix-check / cond_exec_skip pipeline.
//
// Responsibilities:
//   1. When the queue head holds a RESERVE descriptor (`task_type==2'b11`,
//      `is_bind==0`) and a matching BIND descriptor (`is_bind==1`, same
//      `slot_id`) arrives on the bind side-channel, latch the bind's
//      executable fields into a shadow flop (`merged_q`) and pulse
//      `bind_set_valid_o` so the dep_matrix increments WAIT_FOR_BIND_COL
//      for that slot in the same cycle.
//   2. Drive `live_task_desc_o` as either:
//      - the FIFO head pass-through when the head is NOT a reserve, OR
//      - a merged view of the reserve's static fields (slot_id,
//        assigned_*) overlaid with the bind's executable fields
//        (task_type, task_id, dep_check/set_*, cond_exec_*, is_bind).
//      The downstream cond_exec_skip evaluator must read this merged view,
//      not the raw FIFO entry.
//   3. Buffer up to PENDING_BUFFER_DEPTH binds that arrive before their
//      reserve reaches the head ("bind-before-reserve" race). On every
//      eligible cycle, attempt to drain the oldest pending entry.
//   4. Clear `merged_q` when the FSM advances past the current head
//      (transition into IDLE → next reserve will have its own merge).
//   5. Maintain internal status nets for sim asserts and waveform debug:
//      - `pending_buffer_full`  (compiler bug if asserted)
//      - `unknown_slot_drop`    (bind has no matching reserve in flight)
//      - `double_bind`          (bind arrives while head already merged)
//      Not exposed as ports; consumed only by SVA inside this module.
//
// Critical wiring:
//   `live_task_desc_o` MUST feed both the dep_check pipeline AND the
//   cond_exec_skip evaluator at the top level so post-bind cond_exec_*
//   fields take effect.

module bingo_hw_manager_bind_resolver #(
    parameter type task_desc_full_t      = logic,
    parameter int unsigned NUM_SLOTS     = 4,
    parameter int unsigned PENDING_DEPTH = 2,
    /// Dependent parameters, DO NOT OVERRIDE!
    parameter int unsigned SLOT_ID_W     = (NUM_SLOTS > 1) ? $clog2(NUM_SLOTS) : 1
) (
    input  logic            clk_i,
    input  logic            rst_ni,
    input  logic            flush_i,

    // ---- Head of the per-core waiting_dep_check_queue (FIFO output) ------
    input  task_desc_full_t task_desc_at_queue_head_i,
    input  logic            queue_head_valid_i,

    // ---- dep_check_manager FSM observation -------------------------------
    // Encoding (from dep_check_manager.sv):
    //   2'b00 IDLE, 2'b01 WAIT_DEP_CHECK, 2'b10 WAIT_QUEUES, 2'b11 FINISH
    input  logic [1:0]      dep_check_manager_state_i,

    // ---- Bind side-channel input (1-deep skid upstream) ------------------
    input  task_desc_full_t bind_in_desc_i,
    input  logic            bind_in_valid_i,
    output logic            bind_in_ready_o,

    // ---- Merged live descriptor view fed downstream ----------------------
    output task_desc_full_t live_task_desc_o,
    output logic            live_task_desc_valid_o,

    // ---- Private bind-set pulse to dep_matrix ----------------------------
    output logic                  bind_set_valid_o,
    output logic [SLOT_ID_W-1:0]  bind_set_slot_o
);

    // ----- FSM state encoding -----
    localparam logic [1:0] FSM_IDLE = 2'b00;

    // ----- Helper: extract slot from a descriptor -----
    function automatic logic [SLOT_ID_W-1:0] desc_slot_id(input task_desc_full_t d);
        return d.slot_id;
    endfunction

    // ----- Shadow flop holding the bind merge for the current head -----
    task_desc_full_t merged_q;
    logic            merged_valid_q;

    // ----- Pending buffer (FIFO of binds waiting for their reserve) -----
    // Small (PENDING_DEPTH=2) — overflow is a compiler-side bug; SVA fires.
    task_desc_full_t pending_buf_q [PENDING_DEPTH];
    logic            pending_buf_valid_q [PENDING_DEPTH];
    // Number of currently-buffered binds (0..PENDING_DEPTH).
    logic [$clog2(PENDING_DEPTH+1)-1:0] pending_count_q;

    // ----- Detected conditions (combinational) -----
    logic            head_is_reserve;
    logic            head_is_unbound_reserve;
    logic [SLOT_ID_W-1:0] head_slot_id;

    assign head_slot_id           = desc_slot_id(task_desc_at_queue_head_i);
    assign head_is_reserve        = queue_head_valid_i &&
                                    (task_desc_at_queue_head_i.task_type == 2'b11) &&
                                    (task_desc_at_queue_head_i.is_bind == 1'b0);
    assign head_is_unbound_reserve = head_is_reserve && !merged_valid_q;

    // Pending-buffer head match against current queue head
    logic            pending_head_match;
    logic [SLOT_ID_W-1:0] pending_head_slot;
    assign pending_head_slot = pending_buf_valid_q[0]
                               ? desc_slot_id(pending_buf_q[0])
                               : '0;
    assign pending_head_match = pending_buf_valid_q[0] &&
                                head_is_unbound_reserve &&
                                (pending_head_slot == head_slot_id);

    // Live bind input match against current queue head
    logic            live_bind_match;
    logic            live_bind_is_bind;
    logic [SLOT_ID_W-1:0] live_bind_slot;
    assign live_bind_is_bind = bind_in_valid_i &&
                                (bind_in_desc_i.task_type == 2'b11) &&
                                (bind_in_desc_i.is_bind == 1'b1);
    assign live_bind_slot    = desc_slot_id(bind_in_desc_i);
    assign live_bind_match   = live_bind_is_bind &&
                                head_is_unbound_reserve &&
                                (live_bind_slot == head_slot_id);

    // ----- Decide which bind (if any) merges this cycle -----
    // Priority: pending buffer ahead of live (preserve order; binds that
    // arrived earlier on the wire merge first).
    logic            do_merge_from_pending;
    logic            do_merge_from_live;
    task_desc_full_t merge_src_desc;

    assign do_merge_from_pending = pending_head_match;
    assign do_merge_from_live    = live_bind_match && !pending_head_match;
    assign merge_src_desc = do_merge_from_pending
                            ? pending_buf_q[0]
                            : bind_in_desc_i;

    // ----- bind_set pulse — fires whenever a merge happens -----
    assign bind_set_valid_o = (do_merge_from_pending || do_merge_from_live);
    assign bind_set_slot_o  = head_slot_id;

    // ----- Live bind acceptance handshake -----
    // Accept a live bind if: (a) it merges this cycle, or
    //                       (b) it can be parked into a non-full pending buffer.
    logic live_bind_park;
    assign live_bind_park = live_bind_is_bind && !live_bind_match &&
                            (pending_count_q < PENDING_DEPTH);
    assign bind_in_ready_o = live_bind_is_bind &&
                             (do_merge_from_live || live_bind_park);

    // ----- Internal status signals (not exposed as ports) -----
    // Plain boolean nets, available for waveform / ILA debug. Synthesis
    // optimises away anything not consumed (only `pending_buffer_full` and
    // `double_bind` feed SVA; `unknown_slot_drop` is currently a conflated
    // alias of `pending_buffer_full`).
    //   pending_buffer_full : live bind has nowhere to go (PENDING_DEPTH overflow)
    //   unknown_slot_drop   : bind has no matching reserve in flight
    //   double_bind         : bind arrives while head already merged
    logic pending_buffer_full;
    logic unknown_slot_drop;
    logic double_bind;
    assign pending_buffer_full = live_bind_is_bind && !live_bind_match &&
                                 (pending_count_q == PENDING_DEPTH);
    assign unknown_slot_drop   = pending_buffer_full; // for now, conflated
    // double_bind: bind arrives that targets a head whose merged_q is already
    // valid (i.e., a previous bind already populated this slot's executable
    // fields). RTL silently accepts as a no-op; SVA fires in sim.
    assign double_bind = live_bind_is_bind && head_is_reserve && merged_valid_q &&
                         (live_bind_slot == head_slot_id);

    // ----- Live (downstream) descriptor mux -----
    // When merged: project bind fields over reserve's static fields.
    // Otherwise: pass through queue head unchanged.
    always_comb begin
        live_task_desc_o = task_desc_at_queue_head_i;
        if (merged_valid_q) begin
            live_task_desc_o.task_type           = merged_q.task_type;
            live_task_desc_o.is_bind             = 1'b0; // post-merge, downstream sees normal
            live_task_desc_o.task_id             = merged_q.task_id;
            live_task_desc_o.dep_check_info      = merged_q.dep_check_info;
            live_task_desc_o.dep_set_info        = merged_q.dep_set_info;
            live_task_desc_o.cond_exec_en        = merged_q.cond_exec_en;
            live_task_desc_o.cond_exec_group_id  = merged_q.cond_exec_group_id;
            live_task_desc_o.cond_exec_invert    = merged_q.cond_exec_invert;
            // Reserve owns slot_id and assigned_* (these stay from the head).
        end
    end
    assign live_task_desc_valid_o = queue_head_valid_i;

    // ----- Sequential update -----
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            merged_q        <= '0;
            merged_valid_q  <= 1'b0;
            pending_count_q <= '0;
            for (int i = 0; i < PENDING_DEPTH; i++) begin
                pending_buf_q[i]       <= '0;
                pending_buf_valid_q[i] <= 1'b0;
            end
        end else if (flush_i) begin
            merged_q        <= '0;
            merged_valid_q  <= 1'b0;
            pending_count_q <= '0;
            for (int i = 0; i < PENDING_DEPTH; i++) begin
                pending_buf_q[i]       <= '0;
                pending_buf_valid_q[i] <= 1'b0;
            end
        end else begin
            // ----- Merge step -----
            if (do_merge_from_pending) begin
                merged_q       <= pending_buf_q[0];
                merged_valid_q <= 1'b1;
                // Shift pending buffer down by one (FIFO drain)
                for (int i = 0; i < PENDING_DEPTH-1; i++) begin
                    pending_buf_q[i]       <= pending_buf_q[i+1];
                    pending_buf_valid_q[i] <= pending_buf_valid_q[i+1];
                end
                pending_buf_q[PENDING_DEPTH-1]       <= '0;
                pending_buf_valid_q[PENDING_DEPTH-1] <= 1'b0;
                pending_count_q <= pending_count_q - 1;
            end else if (do_merge_from_live) begin
                merged_q       <= bind_in_desc_i;
                merged_valid_q <= 1'b1;
            end

            // ----- Park live bind into pending buffer if it didn't merge -----
            if (live_bind_park && !do_merge_from_pending) begin
                pending_buf_q[pending_count_q]       <= bind_in_desc_i;
                pending_buf_valid_q[pending_count_q] <= 1'b1;
                pending_count_q <= pending_count_q + 1;
            end

            // ----- Clear merge when head pops -----
            // The head pops the cycle dep_check_manager transitions back to
            // IDLE (FINISH → IDLE). At that point the new head will need its
            // own merge.
            if (merged_valid_q && (dep_check_manager_state_i == FSM_IDLE)) begin
                merged_q       <= '0;
                merged_valid_q <= 1'b0;
            end
        end
    end

    // ---- Sim-only invariants -----------------------------------------------
    `ifndef SYNTHESIS
    // SVA1: pending buffer must never overflow. PENDING_DEPTH=2 is calibrated
    // for the speculative-decoding-N=4 / MoE-2-of-8 demos; deeper requires
    // re-parameterisation.
    assert_pending_buffer_no_overflow: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        !pending_buffer_full
    ) else $error("bind_resolver: pending buffer overflow — compiler emitted too many out-of-order binds");

    // SVA2: a bind that targets a head whose slot already has merged_valid_q
    // is a double-bind (compiler bug). RTL silently no-ops.
    assert_no_double_bind: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        !double_bind
    ) else $error("bind_resolver: double-bind on slot %0d", bind_set_slot_o);
    `endif

endmodule
