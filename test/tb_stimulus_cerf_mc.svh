// =============================================================================
// Cross-die CERF: a routing decision on chiplet 0 gating work on chiplet 1
// =============================================================================
// Chip 0 runs two GATING tasks, each with a cross-chiplet dep_set into chip 1.
// Chip 0's CERF is written (as a gating kernel would) with groups {3, 20} active
// BEFORE those messages go out. Chip 1 starts with an all-zero CERF and never
// receives a local CERF write.
//
//   G1 (chip0 core0, GATING) -> D1 (dummy proxy, cerf_carry) -> C1 (chip1, grp 3)
//   G2 (chip0 core1, GATING) -> D2 (dummy proxy, cerf_carry) -> C2 (chip1, grp 20)
//
// The PROXY is the point. A gating task's own dep_set stays local; the dummy-set
// pass routes every remote successor through a dummy on the gating task's core,
// so that dummy is what crosses the die and what must carry the window.
//
// GlobalCerfGroups = 8, so group 3 is INSIDE the cross-die window and group 20
// is outside it. The message carries only the window, therefore:
//
//   * chip 1 must learn group 3 is active -> C1 RUNS
//   * chip 1 must NOT learn about group 20 -> C2 is SKIPPED
//
// C2 is the negative control: same die, same mechanism, same message -- the only
// difference is that its group lies outside the carried window. If C2 also ran,
// the window would not be doing anything and some other path would be leaking
// CERF state across the die.
//
// C1 and C2 check DIFFERENT producer columns (core 0 vs core 1), so their two
// edges land in different dep-matrix cells and may share tag 0.
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 3;   // G1, G2, C1 (C2 skipped; D1/D2 are dummies)
localparam int unsigned DEADLOCK_THRESHOLD      = 8000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

localparam int unsigned GRP_IN  = 3;    // inside  GlobalCerfGroups = 8
localparam int unsigned GRP_OUT = 20;   // outside GlobalCerfGroups = 8

// ---- chip 0: a gating task, then the PROXY that crosses the die ------------
// This mirrors what the compiler actually emits. The gating task's own dep_set
// stays LOCAL: bingo_transform_dfg_add_dummy_set_nodes proxies every remote
// successor through a dummy on the gating task's own core, so the dummy is what
// crosses the die and therefore what must carry the CERF window. The compiler
// marks it with cerf_carry; the hardware does not infer it.
bingo_hw_manager_task_desc_full_t g1 = pack_normal_task(
    2'b10, 16'd1, 0, 0, 0,                                    // GATING, chip0 core0
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0,                                     // no dep_set of its own
    '0, '0, 1'b0
);
bingo_hw_manager_task_desc_full_t d1 = pack_dummy_set_task(
    2'b01, 16'd101, 0, 0, 0,                                  // DUMMY on the same core
    1'b1, 1'b0, 8'd1, 0,                                      // dep_set -> chiplet 1
    bingo_hw_manager_dep_code_t'(8'b00000010),                // set row 1 (C1's core)
    3'd0, 1'b1                                                // tag, CERF_CARRY
);
bingo_hw_manager_task_desc_full_t g2 = pack_normal_task(
    2'b10, 16'd2, 0, 0, 1,                                    // GATING, chip0 core1
    1'b0, '0,
    1'b0, 1'b0, 0, 0, '0,
    '0, '0, 1'b0
);
bingo_hw_manager_task_desc_full_t d2 = pack_dummy_set_task(
    2'b01, 16'd102, 0, 0, 1,
    1'b1, 1'b0, 8'd1, 0,
    bingo_hw_manager_dep_code_t'(8'b00000100),                // set row 2 (C2's core)
    3'd0, 1'b1
);

// ---- chip 1: two conditional consumers -------------------------------------
bingo_hw_manager_task_desc_full_t c1;
bingo_hw_manager_task_desc_full_t c2;
initial begin
    c1 = pack_normal_task(
        2'b00, 16'd11, 1, 0, 1,
        1'b1, bingo_hw_manager_dep_code_t'(8'b00000001),      // check col 0 (G1)
        1'b0, 1'b0, 0, 0, '0,
        3'd0, '0
    );
    c1.cond_exec_en       = 1'b1;
    c1.cond_exec_group_id = 5'(GRP_IN);
    c1.cond_exec_invert   = 1'b0;

    c2 = pack_normal_task(
        2'b00, 16'd12, 1, 0, 2,
        1'b1, bingo_hw_manager_dep_code_t'(8'b00000010),      // check col 1 (G2)
        1'b0, 1'b0, 0, 0, '0,
        3'd0, '0
    );
    c2.cond_exec_en       = 1'b1;
    c2.cond_exec_group_id = 5'(GRP_OUT);
    c2.cond_exec_invert   = 1'b0;
end

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------
initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    // The gating kernel's own CSR write, on THIS die only.
    cerf_write_bitmask(0, (32'd1 << GRP_IN) | (32'd1 << GRP_OUT));
    @(posedge clk_i);

    $display("[TRACE] %0t,TASK_PUSHED,0,0,0,1", $time);
    task_queue_master[0].write(task_queue_base[0], '0, g1, '1, resp);
    #60;
    task_queue_master[0].write(task_queue_base[0], '0, d1, '1, resp);
    #60;
    $display("[TRACE] %0t,TASK_PUSHED,0,0,1,2", $time);
    task_queue_master[0].write(task_queue_base[0], '0, g2, '1, resp);
    #60;
    task_queue_master[0].write(task_queue_base[0], '0, d2, '1, resp);
    #60;
end

initial begin : chip1_push_sequence
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[1].reset();
    done_queue_master[1].reset();

    $display("[TRACE] %0t,TASK_PUSHED,1,0,1,11", $time);
    task_queue_master[1].write(task_queue_base[1], '0, c1, '1, resp);
    #60;
    $display("[TRACE] %0t,TASK_PUSHED,1,0,2,12", $time);
    task_queue_master[1].write(task_queue_base[1], '0, c2, '1, resp);
    #60;
end

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------
int unsigned mc_errors = 0;
logic        saw_window_arrive = 1'b0;

initial begin : cerf_mc_checker
    wait (rst_ni);
    @(posedge clk_i);
    // Chip 1 must start clean -- nothing local ever writes its CERF.
    if (gen_dut[1].i_dut.cerf_state != 32'd0) begin
        mc_errors++;
        $error("chip1 CERF is not zero at start: %08x", gen_dut[1].i_dut.cerf_state);
    end
    forever begin
        @(posedge clk_i);
        if (gen_dut[1].i_dut.cerf_state[GRP_IN] && !saw_window_arrive) begin
            saw_window_arrive = 1'b1;
            $display("[%0t] chip1 learned group %0d from the carried window; CERF=%08x",
                     $time, GRP_IN, gen_dut[1].i_dut.cerf_state);
        end
        // A group outside the window must NEVER appear on the far die.
        if (gen_dut[1].i_dut.cerf_state[GRP_OUT]) begin
            mc_errors++;
            $error("chip1 CERF group %0d is set, but it lies OUTSIDE the %0d-bit cross-die window -- CERF state is leaking across the die by some other path.",
                   GRP_OUT, `TB_GLOBAL_CERF_GROUPS);
            $finish;
        end
    end
end

final begin
    if (!saw_window_arrive) begin
        $error("chip1 NEVER learned group %0d: the gating task's predicate did not cross the die.",
               GRP_IN);
    end
    if (mc_errors != 0) begin
        $error("%0d cross-die CERF error(s)", mc_errors);
    end else if (saw_window_arrive) begin
        $display("cross-die CERF: window carried correctly, out-of-window group stayed local");
    end
end
