// =============================================================================
// Done pairing, remote set: a normal task's ENABLED set to another chip must wait for its done
// =============================================================================
//   chip 0, core 1:  A  normal, sets row 0 (core 0) of chip 1's cluster 0 (the chiplet path)
//   chip 1, core 0:  C  normal, checks column 1 (the remote set's column is A's core)
// A's set may fire only once A is done, so C may enter chip 1's core-0 ready queue only after
// A's done has entered chip 0's core-1 done queue. (The HeMAiA compiler routes every remote set
// through a dummy task, which has no done, so this case is latent there.)
// The harness only checks that every task completes. The ORDER check at the bottom is what
// this test adds.
// =============================================================================
localparam int unsigned EXPECTED_TASK_COUNT     = 2;
localparam int unsigned DEADLOCK_THRESHOLD      = 3000;  // cycles
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;     // disabled

bingo_hw_manager_task_desc_full_t a = pack_normal_task(
    2'b00, 16'd1, 0, 0, 1,
    1'b0, '0,
    1'b1, 1'b0, 1, 0, bingo_hw_manager_dep_code_t'(8'b00000001),  // chip 1, row 0
    '0, 3'd0
);
bingo_hw_manager_task_desc_full_t c = pack_normal_task(
    2'b00, 16'd2, 1, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),               // check column 1
    1'b0, 1'b0, 1, 0, '0,
    3'd0, '0
);

initial begin : push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    $display("[TRACE] %0t,TASK_PUSHED,1,0,0,2", $time);
    task_queue_master[1].write(task_queue_base[1], '0, c, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,1,1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, a, '1, resp);
end

// ORDER check: C (task 2) may enter chip 1's core-0 ready queue only after A's (task 1) done
// has entered chip 0's core-1 done queue.
bit done_pairing_a_done = 1'b0;
always @(posedge clk_i) begin
    if (gen_dut[0].i_dut.done_q_push[1][0] &&
        gen_dut[0].i_dut.done_q_data_in[1][0].task_id == 16'd1)
        done_pairing_a_done = 1'b1;
    if (gen_dut[1].i_dut.ready_queue_push[0][0] &&
        gen_dut[1].i_dut.ready_queue_data_in[0][0].task_id == 16'd2) begin
        if (!done_pairing_a_done)
            $fatal(1, "[DONE_PAIRING] FAIL: C (task 2) became ready at %0t, before A (task 1) was done",
                   $time);
        $display("[DONE_PAIRING] PASS: C (task 2) became ready at %0t, after A (task 1) was done",
                 $time);
    end
end
