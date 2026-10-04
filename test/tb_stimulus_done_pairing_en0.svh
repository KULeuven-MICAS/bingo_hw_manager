// =============================================================================
// Done pairing, set-disabled task: a normal task with dep_set_en = 0 must still consume its done
// =============================================================================
// Everything runs on chip `DONE_PAIRING_CHIP, cluster 0:
//   core 1:  A  normal, dep set DISABLED; its unused dep_set_chiplet_id is 0 (what the
//               compiler emits)
//            B  normal, sets row 0 (core 0) of this chip's cluster 0
//   core 0:  C  normal, checks column 1 (core 1)
// B's set may fire only once B is done, so C may enter core 0's ready queue only after B's
// done has entered core 1's done queue.
// On chip 0, A's checkout entry leaves by the local drop path. On chip 1, its chiplet id (0)
// is not the chip's own: before the done-pairing fix it left by the chiplet path, which neither
// waited for nor popped its done entry.
// The harness only checks that every task completes. The ORDER check at the bottom is what
// this test adds.
// =============================================================================
`ifndef DONE_PAIRING_CHIP
`define DONE_PAIRING_CHIP 0
`endif

localparam int unsigned EXPECTED_TASK_COUNT     = 3;
localparam int unsigned DEADLOCK_THRESHOLD      = 3000;  // cycles
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;     // disabled

bingo_hw_manager_task_desc_full_t a = pack_normal_task(
    2'b00, 16'd1, `DONE_PAIRING_CHIP, 0, 1,
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0                                          // dep set disabled
);
bingo_hw_manager_task_desc_full_t b = pack_normal_task(
    2'b00, 16'd2, `DONE_PAIRING_CHIP, 0, 1,
    1'b0, '0,
    1'b1, 1'b0, `DONE_PAIRING_CHIP, 0, bingo_hw_manager_dep_code_t'(8'b00000001), // row 0
    '0, 3'd0
);
bingo_hw_manager_task_desc_full_t c = pack_normal_task(
    2'b00, 16'd3, `DONE_PAIRING_CHIP, 0, 0,
    1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),             // check column 1
    1'b0, 1'b0, `DONE_PAIRING_CHIP, 0, '0,
    3'd0, '0
);

initial begin : push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    $display("[TRACE] %0t,TASK_PUSHED,%0d,0,1,1", $time, `DONE_PAIRING_CHIP);
    task_queue_master[`DONE_PAIRING_CHIP].write(task_queue_base[`DONE_PAIRING_CHIP], '0, a, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,%0d,0,1,2", $time, `DONE_PAIRING_CHIP);
    task_queue_master[`DONE_PAIRING_CHIP].write(task_queue_base[`DONE_PAIRING_CHIP], '0, b, '1, resp);
    #50;
    $display("[TRACE] %0t,TASK_PUSHED,%0d,0,0,3", $time, `DONE_PAIRING_CHIP);
    task_queue_master[`DONE_PAIRING_CHIP].write(task_queue_base[`DONE_PAIRING_CHIP], '0, c, '1, resp);
end

// ORDER check: C (task 3) may enter core 0's ready queue only after B's (task 2) done has
// entered core 1's done queue.
bit done_pairing_b_done = 1'b0;
always @(posedge clk_i) begin
    if (gen_dut[`DONE_PAIRING_CHIP].i_dut.done_q_push[1][0] &&
        gen_dut[`DONE_PAIRING_CHIP].i_dut.done_q_data_in[1][0].task_id == 16'd2)
        done_pairing_b_done = 1'b1;
    if (gen_dut[`DONE_PAIRING_CHIP].i_dut.ready_queue_push[0][0] &&
        gen_dut[`DONE_PAIRING_CHIP].i_dut.ready_queue_data_in[0][0].task_id == 16'd3) begin
        if (!done_pairing_b_done)
            $fatal(1, "[DONE_PAIRING] FAIL: C (task 3) became ready at %0t, before B (task 2) was done",
                   $time);
        $display("[DONE_PAIRING] PASS: C (task 3) became ready at %0t, after B (task 2) was done",
                 $time);
    end
end
