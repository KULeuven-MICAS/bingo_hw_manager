// =============================================================================
// Master-mode task queue, through the TOP (TASK_QUEUE_TYPE == 1)
// =============================================================================
// Every other harness TB pushes descriptors into the AXI-Lite SLAVE mailbox. This
// one exercises the path HeMAiA actually uses: the manager FETCHES its descriptor
// list from memory over AXI-Lite, assembling a 128-bit descriptor from two
// 64-bit beats.
//
// It also pins `TaskQueueMaxOutstanding` end to end. The parameter defaults to 1
// in bingo_hw_manager_task_queue_master, so if the top did not pass it down, the
// master would issue one read at a time and the peak number of ARs in flight
// could never exceed 1. This TB sets it to 4 and REQUIRES a peak above 1 --
// a plumbing break cannot pass.
//
// The graph is a six-task serial chain across three cores:
//   t1(core0) -> t2(core1) -> t3(core2) -> t4(core0) -> t5(core1) -> t6(core2)
// Consecutive uses of a dep-matrix cell are ordered by the chain itself, so one
// tag suffices and the test stays about the FETCH, not about tagging.
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 6;
localparam int unsigned DEADLOCK_THRESHOLD      = 20000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

localparam int unsigned N_DESC          = 6;
localparam int unsigned BEATS_PER_DESC  = TASK_DESC_BUS_WIDTH / HOST_DW;
localparam int unsigned EXPECTED_BEATS  = N_DESC * BEATS_PER_DESC;

// core c signals core (c+1)%3; the last task signals nobody.
function automatic bingo_hw_manager_dep_code_t row_of(input int core);
    return bingo_hw_manager_dep_code_t'(1 << core);
endfunction

initial begin : chip0_task_list
    wait (rst_ni);
    @(posedge clk_i);

    // t1: core 0, no check, sets core 1
    task_list[0][0] = pack_normal_task(
        2'b00, 16'd1, 0, 0, 0,
        1'b0, '0,
        1'b1, 1'b0, 0, 0, row_of(1), '0, '0);
    // t2: core 1, checks core 0, sets core 2
    task_list[0][1] = pack_normal_task(
        2'b00, 16'd2, 0, 0, 1,
        1'b1, row_of(0),
        1'b1, 1'b0, 0, 0, row_of(2), '0, '0);
    // t3: core 2, checks core 1, sets core 0
    task_list[0][2] = pack_normal_task(
        2'b00, 16'd3, 0, 0, 2,
        1'b1, row_of(1),
        1'b1, 1'b0, 0, 0, row_of(0), '0, '0);
    // t4: core 0, checks core 2, sets core 1
    task_list[0][3] = pack_normal_task(
        2'b00, 16'd4, 0, 0, 0,
        1'b1, row_of(2),
        1'b1, 1'b0, 0, 0, row_of(1), '0, '0);
    // t5: core 1, checks core 0, sets core 2
    task_list[0][4] = pack_normal_task(
        2'b00, 16'd5, 0, 0, 1,
        1'b1, row_of(0),
        1'b1, 1'b0, 0, 0, row_of(2), '0, '0);
    // t6: core 2, checks core 1, signals nobody
    task_list[0][5] = pack_normal_task(
        2'b00, 16'd6, 0, 0, 2,
        1'b1, row_of(1),
        1'b0, 1'b0, 0, 0, '0, '0, '0);

    task_list_n[0] = N_DESC;
    @(posedge clk_i);
    $display("[%0t] task list ready: %0d descriptors of %0d bits (%0d beats each)",
             $time, N_DESC, TASK_DESC_BUS_WIDTH, BEATS_PER_DESC);
    tq_go[0] = 1'b1;          // the manager fetches it from here
end

initial begin : tq_go_init
    tq_go = '0;
end

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------
final begin
    if (tq_beats_served[0] != EXPECTED_BEATS) begin
        $error("fetched %0d beats, expected %0d (%0d descriptors x %0d beats)",
               tq_beats_served[0], EXPECTED_BEATS, N_DESC, BEATS_PER_DESC);
    end else begin
        $display("task fetch: %0d beats served, %0d descriptors assembled",
                 tq_beats_served[0], N_DESC);
    end

    // THE PLUMBING CHECK. The master defaults to MaxOutstanding = 1. If the top
    // did not pass TaskQueueMaxOutstanding down, the peak could not exceed 1.
    if (TASK_QUEUE_MAX_OUTSTANDING <= 1) begin
        $error("this TB must run with TB_TASK_QUEUE_MAX_OUTSTANDING > 1 to mean anything");
    end else if (tq_peak_outstanding[0] <= 1) begin
        $error("peak outstanding AR = %0d with TaskQueueMaxOutstanding = %0d: the top is NOT passing the parameter to the task-queue master (it fell back to the default of 1).",
               tq_peak_outstanding[0], TASK_QUEUE_MAX_OUTSTANDING);
    end else if (tq_peak_outstanding[0] > TASK_QUEUE_MAX_OUTSTANDING) begin
        $error("peak outstanding AR = %0d EXCEEDS TaskQueueMaxOutstanding = %0d",
               tq_peak_outstanding[0], TASK_QUEUE_MAX_OUTSTANDING);
    end else begin
        $display("task fetch: peak %0d ARs in flight (limit %0d) -- the top's parameter reached the master",
                 tq_peak_outstanding[0], TASK_QUEUE_MAX_OUTSTANDING);
    end
end
