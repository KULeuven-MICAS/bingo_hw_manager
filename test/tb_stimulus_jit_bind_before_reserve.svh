// =============================================================================
// JIT-DFG bind-before-reserve test
// =============================================================================
// Exercises the bind_resolver pending buffer: a BIND descriptor arrives on the
// bind side-channel BEFORE its matching RESERVE has reached the queue head.
// The bind must be parked in the pending buffer (depth 2) and drained on the
// cycle after the matching RESERVE pushes into the wait queue.
//
// Three-task DFG:
//   t1 (core 0, drafter):   normal, dep_set to slot 1.
//   t_bind (core 1, BIND):  pushed BEFORE the RESERVE — parks in pending buffer.
//   t2 (core 1, RESERVE):   slot 1, dep_check on slot 0 — drains the buffer.
//   t3 (core 2, consumer):  normal, dep_check on slot 1.
//
// EXPECTED_TASK_COUNT = 3.
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 3;
localparam int unsigned DEADLOCK_THRESHOLD      = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_host_t t1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0010)
);

// BIND for slot 1 — pushed FIRST (before its matching reserve).
bingo_hw_manager_task_desc_host_t t_bind = pack_bind_task(
    16'h00B1,
    /*chip*/0, /*cluster*/0, /*core*/1,
    /*dep_check_code*/ '0,
    /*dep_check_en*/   1'b1,
    /*dep_set_en*/     1'b1,
    /*dep_set_all*/    1'b0,
    /*dep_set_chip*/   0,
    /*dep_set_cluster*/0,
    /*dep_set_code*/   bingo_hw_manager_dep_code_t'(4'b0100)
);

// RESERVE for slot 1 — arrives after the bind.
bingo_hw_manager_task_desc_host_t t2 = pack_reserve_task(
    16'd2,
    /*chip*/0, /*cluster*/0, /*core*/1,
    /*static_check_code*/ bingo_hw_manager_dep_code_t'(4'b0001)
);

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

    // Push drafter
    task_queue_master[0].write(task_queue_base[0], '0, t1, '1, resp);
    #50;
    // Push BIND BEFORE its reserve — pending buffer must absorb it.
    $display("[JIT] %0t Pushing BIND before its RESERVE (parks in pending buffer)", $time);
    task_queue_master[0].write(task_queue_base[0], '0, t_bind, '1, resp);
    #50;
    // Push RESERVE — pending bind must drain on next cycle.
    $display("[JIT] %0t Pushing RESERVE (drains pending bind)", $time);
    task_queue_master[0].write(task_queue_base[0], '0, t2, '1, resp);
    #50;
    task_queue_master[0].write(task_queue_base[0], '0, t3, '1, resp);
end
