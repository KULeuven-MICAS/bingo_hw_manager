// =============================================================================
// JIT-DFG double-bind SVA test
// =============================================================================
// Two BIND descriptors target the same (cluster, slot) before the slot has
// dispatched. The bind_resolver's `assert_no_double_bind` SVA must fire on
// the second bind.
//
// This is NEGATIVE coverage: the test EXPECTS the simulation to log SVA
// errors. The pass criterion remains EXPECTED_TASK_COUNT completions
// (the second bind silently no-ops in RTL — sim-only assertion fires).
//
// Two-task DFG:
//   t2 (core 1): RESERVE on slot 1, no static deps.
//   t_bind1   :  BIND for slot 1, dep_set to slot 2.
//   t_bind2   :  SECOND BIND for slot 1 — triggers SVA.
//   t3 (core 2): consumer, dep_check on slot 1.
//
// EXPECTED_TASK_COUNT = 2 (bound slot 1 + consumer).
// EXPECTED ERRORS: at least 1 (the SVA fire).
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 2;
localparam int unsigned DEADLOCK_THRESHOLD      = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t t2 = pack_reserve_task(
    16'd2, 0, 0, 1, 1,
    bingo_hw_manager_dep_code_t'('0)  // no static deps
);

bingo_hw_manager_task_desc_full_t t_bind1 = pack_bind_task(
    16'h00B1, 0, 0, 1, 1,
    /*dep_check_code*/ '0,  /*dep_check_en*/ 1'b1,
    /*dep_set_en*/     1'b1, /*dep_set_all*/  1'b0,
    0, 0, bingo_hw_manager_dep_code_t'(4'b0100)
);

// Second BIND for the same slot — must fire double_bind SVA.
bingo_hw_manager_task_desc_full_t t_bind2 = pack_bind_task(
    16'h00B2, 0, 0, 1, 1,
    /*dep_check_code*/ '0,  /*dep_check_en*/ 1'b1,
    /*dep_set_en*/     1'b1, /*dep_set_all*/  1'b0,
    0, 0, bingo_hw_manager_dep_code_t'(4'b0100)
);

bingo_hw_manager_task_desc_full_t t3 = pack_normal_task(
    2'b00, 16'd3, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(4'b0010),
    1'b0, 1'b0, 0, 0, '0
);

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    task_queue_master[0].write(task_queue_base[0], '0, t2, '1, resp);
    #50;
    task_queue_master[0].write(task_queue_base[0], '0, t3, '1, resp);
    #50;
    $display("[JIT] %0t First BIND for slot 1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, t_bind1, '1, resp);
    // Second bind targets same slot before the slot has dispatched. The
    // bind_resolver's SVA must fire; RTL silently no-ops.
    #20;
    $display("[JIT] %0t Second BIND for slot 1 (expect SVA fire)", $time);
    task_queue_master[0].write(task_queue_base[0], '0, t_bind2, '1, resp);
end
