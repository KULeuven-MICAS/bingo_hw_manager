// =============================================================================
// JIT-DFG basic reserve → bind → dispatch test
// =============================================================================
// Three-task DFG, single chiplet, single cluster, three cores:
//
//   t1 (core 0, drafter):   normal kernel, dep_set to slot 1.
//   t2 (core 1, JIT slot):  RESERVE on slot 1, dep_check on slot 0
//                           (drafter). Blocks on WAIT_FOR_BIND until the
//                           BIND descriptor lands.
//   t_bind (core 1):        BIND for slot 1, kernel = task_id 0xB1, dep_set
//                           to slot 2.
//   t3 (core 2, consumer):  normal kernel, dep_check on slot 1.
//
// Expected: 3 task_id completions (1, 0xB1, 3).
// EXPECTED_TASK_COUNT = 3 (drafter, bound, consumer).
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 3;
localparam int unsigned DEADLOCK_THRESHOLD      = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

// Task 1 (drafter): core 0, no deps, dep_set to slot 1
bingo_hw_manager_task_desc_host_t t1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0010)
);

// Task 2 (JIT slot): RESERVE on slot 1, target core 1, dep_check on slot 0.
// dep_check_code is the static prerequisite (drafter); the WAIT_FOR_BIND_COL
// bit is OR'd in automatically at the dep_matrix port (T3.3).
bingo_hw_manager_task_desc_host_t t2 = pack_reserve_task(
    16'd2,
    /*chiplet*/0, /*cluster*/0, /*core*/1,
    /*static_check_code*/ bingo_hw_manager_dep_code_t'(4'b0001)
);

// BIND for slot 1: kernel task_id 0xB1, dep_set to slot 2 (consumer)
// dep_check_en=1 with dep_check_code=0 because by the time the bind merges,
// the slot's static deps (drafter) are already cleared. Setting dep_check_en=1
// ensures the dep_matrix path engages and the WAIT_FOR_BIND counter gets
// decremented as part of the check pass.
bingo_hw_manager_task_desc_host_t t_bind = pack_bind_task(
    16'h00B1,
    /*chiplet*/0, /*cluster*/0, /*core*/1,
    /*dep_check_code*/ '0,
    /*dep_check_en*/   1'b1,
    /*dep_set_en*/     1'b1,
    /*dep_set_all*/    1'b0,
    /*dep_set_chip*/   0,
    /*dep_set_cluster*/0,
    /*dep_set_code*/   bingo_hw_manager_dep_code_t'(4'b0100)
);

// Task 3 (consumer): core 2, dep_check on slot 1, no dep_set
bingo_hw_manager_task_desc_host_t t3 = pack_normal_task(
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

    // Push the static prefix
    task_queue_master[0].write(task_queue_base[0], '0, t1, '1, resp);
    #50;
    task_queue_master[0].write(task_queue_base[0], '0, t2, '1, resp);
    #50;
    task_queue_master[0].write(task_queue_base[0], '0, t3, '1, resp);

    // Simulate host's resolver computing the bind after some delay.
    // Push the BIND descriptor to fill in slot 1's executable fields.
    #200;
    $display("[JIT] %0t Issuing BIND for slot 1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, t_bind, '1, resp);
end
