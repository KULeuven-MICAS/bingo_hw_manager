// =============================================================================
// Multi-edge stimulus: ONE descriptor expressing a 3-way JOIN
// =============================================================================
// Three producers on cores 1, 2 and 3 all signal consumer core 0, and the
// consumer checks all three columns in a SINGLE dep_check op sharing one tag:
//
//     P1(core1) --\
//     P2(core2) ----> J(core0)   dep_check_code = 4'b1110, tag 0
//     P3(core3) --/
//
// Today the compiler would split this into J plus two dummy_check descriptors.
// It does not have to: dep_check_code is an atomically AND-reduced column
// bitmask and the matrix clears ONLY on a full match, so a partially satisfied
// join consumes nothing and cannot deadlock.
//
// The producers are pushed with large gaps so the join is provably blocked in
// between. The block below probes the DUT's own dep_check_result for row 0 and
// fails if it EVER goes high before the third producer has set its column --
// that is the property the dummy_check chain used to provide, now provided by
// the primitive.
//
// A second join (J2) follows on the same cell set with the same tag, so this
// also proves the tag is released and reusable once the first join drained.
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 8;
localparam int unsigned DEADLOCK_THRESHOLD      = 8000;  // cycles
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;     // disabled

// ---- stage 1 ---------------------------------------------------------------
bingo_hw_manager_task_desc_full_t p1 = pack_normal_task(
    1'b0, 16'd1, 0, 0, 1,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0001),  // set row0
    '0, 3'd0
);
bingo_hw_manager_task_desc_full_t p2 = pack_normal_task(
    1'b0, 16'd2, 0, 0, 2,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0001),
    '0, 3'd0
);
bingo_hw_manager_task_desc_full_t p3 = pack_normal_task(
    1'b0, 16'd3, 0, 0, 3,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0001),
    '0, 3'd0
);
// THE JOIN: one descriptor, three columns, one tag.
bingo_hw_manager_task_desc_full_t j1 = pack_normal_task(
    1'b0, 16'd4, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(4'b1110),              // cols 1,2,3
    1'b0, 1'b0, 0, 0, '0,
    3'd0, '0
);

// ---- stage 2: same cells, same tag -- proves the tag is reusable ------------
bingo_hw_manager_task_desc_full_t p4 = pack_normal_task(
    1'b0, 16'd5, 0, 0, 1,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0001),
    '0, 3'd0
);
bingo_hw_manager_task_desc_full_t p5 = pack_normal_task(
    1'b0, 16'd6, 0, 0, 2,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0001),
    '0, 3'd0
);
bingo_hw_manager_task_desc_full_t p6 = pack_normal_task(
    1'b0, 16'd7, 0, 0, 3,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0001),
    '0, 3'd0
);
bingo_hw_manager_task_desc_full_t j2 = pack_normal_task(
    1'b0, 16'd8, 0, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(4'b1110),
    1'b0, 1'b0, 0, 0, '0,
    3'd0, '0
);

// ---------------------------------------------------------------------------
// Push sequence. The join goes in FIRST, so it is sitting at its lane head and
// checking while the producers trickle in one at a time.
// ---------------------------------------------------------------------------
initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,4", $time);
    task_queue_master[0].write(task_queue_base[0], '0, j1, '1, resp);
    #200;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,1,1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, p1, '1, resp);
    #1000;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,2,2", $time);
    task_queue_master[0].write(task_queue_base[0], '0, p2, '1, resp);
    #1000;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,3,3", $time);
    task_queue_master[0].write(task_queue_base[0], '0, p3, '1, resp);
    #1000;

    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,8", $time);
    task_queue_master[0].write(task_queue_base[0], '0, j2, '1, resp);
    #200;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,1,5", $time);
    task_queue_master[0].write(task_queue_base[0], '0, p4, '1, resp);
    #300;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,2,6", $time);
    task_queue_master[0].write(task_queue_base[0], '0, p5, '1, resp);
    #300;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,3,7", $time);
    task_queue_master[0].write(task_queue_base[0], '0, p6, '1, resp);
    #300;
end

// ---------------------------------------------------------------------------
// The join must NEVER pass on a partial column set.
// ---------------------------------------------------------------------------
int unsigned join_passes = 0;
initial begin : multiedge_join_checker
    automatic logic [2:0] cols_live;
    wait (rst_ni);
    forever begin
        @(posedge clk_i);
        // Live tag-0 bits on row 0 for columns 1..3, read out of the scoreboard.
        cols_live[0] = gen_dut[0].i_dut.gen_dep_matrix[0].i_dep_matrix.sb_q[0][1][0];
        cols_live[1] = gen_dut[0].i_dut.gen_dep_matrix[0].i_dep_matrix.sb_q[0][2][0];
        cols_live[2] = gen_dut[0].i_dut.gen_dep_matrix[0].i_dep_matrix.sb_q[0][3][0];
        if (gen_dut[0].i_dut.dep_check_result[0][0]) begin
            join_passes++;
            if (cols_live !== 3'b111) begin
                $error("MULTI-EDGE JOIN FAILURE at %0t: dep_check_result high with columns {1,2,3} = %b -- a partial join passed.",
                       $time, cols_live);
            end else begin
                $display("[%0t] join passed with all three columns live (pass #%0d)",
                         $time, join_passes);
            end
        end
    end
end

final begin
    if (join_passes == 0) begin
        $error("MULTI-EDGE JOIN never passed -- the multi-column check is not being satisfied at all.");
    end else begin
        $display("multi-edge join checker: %0d passing cycles, all with every column present",
                 join_passes);
    end
end
