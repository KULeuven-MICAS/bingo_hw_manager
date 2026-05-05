// =============================================================================
// JIT-DFG orphan force-drain test
// =============================================================================
// Demonstrates the host-side cleanup path for an orphan reservation: a
// RESERVE descriptor whose original BIND never arrives (e.g., the host's
// resolver never returned, a remote chiplet crashed, etc.). The host
// timeout-watchdog issues a force-drain BIND with a sentinel task_id that
// indicates "no-op": dep_set is suppressed so downstream slots are not
// falsely unblocked.
//
// Two-task DFG:
//   t2 (core 1): RESERVE on slot 1, no static deps.
//                Sits forever blocked on WAIT_FOR_BIND.
//   t_drain   :  Force-drain BIND — task_id 0xDEAD, dep_set_en=0.
//                After the merge, the slot dispatches as a normal task
//                with no dep_set; the watchdog has reclaimed the slot.
//
// EXPECTED_TASK_COUNT = 1 (just the drained slot 1).
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 1;
localparam int unsigned DEADLOCK_THRESHOLD      = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

bingo_hw_manager_task_desc_full_t t2 = pack_reserve_task(
    16'd2, 0, 0, 1, 1,
    bingo_hw_manager_dep_code_t'('0)
);

// Force-drain BIND: kernel sentinel task_id (host kernel table maps this to a
// no-op), dep_check_en=1 so the WAIT_FOR_BIND counter is decremented along
// with the check pass, dep_set_en=0 so no downstream slots are touched.
bingo_hw_manager_task_desc_full_t t_drain = pack_bind_task(
    16'hDEAD, 0, 0, 1, 1,
    /*dep_check_code*/ '0, /*dep_check_en*/ 1'b1,
    /*dep_set_en*/     1'b0, /*dep_set_all*/ 1'b0,
    0, 0, '0
);

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    task_queue_master[0].write(task_queue_base[0], '0, t2, '1, resp);
    #50;
    // Simulate watchdog timeout: host issues a force-drain bind.
    #500;
    $display("[JIT] %0t Watchdog issuing force-drain BIND (task_id=0xDEAD)", $time);
    task_queue_master[0].write(task_queue_base[0], '0, t_drain, '1, resp);
end
