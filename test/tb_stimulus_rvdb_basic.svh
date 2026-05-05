// =============================================================================
// RVDB basic chain — return-value-driven binding, single hop
// =============================================================================
// Three-task DFG, single chiplet, single cluster, three cores. The middle
// slot is RVDB-driven: when the source task completes with return_value=1,
// the HW indexes bind_table[0 + 1] and dispatches the synthesized bind for
// the target slot — WITHOUT any host bind round-trip.
//
//   t1 source   (core 0, slot 0): normal, no deps, dep_set to slot 1, RV=1
//   t2 reserve  (core 1, slot 1): RVDB chain (source=slot 0, table_base=0)
//   t3 consumer (core 2, slot 2): normal, dep_check on slot 1
//
// Bind table preload (via hierarchical force at sim start):
//   bind_table[0] = ignored (return_value=0 case)
//   bind_table[1] = bind for slot 1, task_id=0xB1, dep_set to slot 2
//
// EXPECTED_TASK_COUNT = 3 (t1, bound t2 dispatch with task_id 0xB1, t3).
// =============================================================================

localparam int unsigned EXPECTED_TASK_COUNT     = 3;
localparam int unsigned DEADLOCK_THRESHOLD      = 5000;
localparam int unsigned DEP_MATRIX_LOG_INTERVAL = 0;

// Source task t1 (core 0, slot 0): kernel returns value 1.
bingo_hw_manager_task_desc_full_t t1 = pack_normal_task(
    2'b00, 16'd1, 0, 0, 0,
    1'b0, '0,
    1'b1, 1'b0, 0, 0, bingo_hw_manager_dep_code_t'(4'b0010)
);

// RVDB-driven RESERVE for slot 1.
// pack_reserve_task signature does not yet accept RVDB fields (S3 TODO),
// so we build the descriptor manually here.
bingo_hw_manager_task_desc_full_t t2;
initial begin
    t2 = pack_reserve_task(
        16'd2,
        /*chip*/0, /*cluster*/0, /*core*/1,
        /*slot*/1,
        /*static_check_code*/ bingo_hw_manager_dep_code_t'(4'b0001)
    );
    // Repurposed RVDB chain config in dep_set_info bits (per 02_rtl_spec.md §1.2).
    // rvdb_chain_en      → dep_set_en         = 1
    // rvdb_source_slot   → dep_set_code[1:0]  = 0  (slot 0 is the source)
    // rvdb_table_base    → packed across {code[3:2], cluster_id, chiplet_id[2:0]} = 0
    t2.dep_set_info.dep_set_en          = 1'b1;          // rvdb_chain_en
    t2.dep_set_info.dep_set_code        = '0;            // source_slot=0, base bits low
    t2.dep_set_info.dep_set_cluster_id  = '0;            // base bits mid
    t2.dep_set_info.dep_set_chiplet_id  = '0;            // base bits high
end

// Consumer t3 (core 2, slot 2): dep_check on slot 1.
bingo_hw_manager_task_desc_full_t t3 = pack_normal_task(
    2'b00, 16'd3, 0, 0, 2,
    1'b1, bingo_hw_manager_dep_code_t'(4'b0010),
    1'b0, 1'b0, 0, 0, '0
);

// The bound descriptor that bind_table[1] will inject — task_id 0xB1, dep_set
// to slot 2 (consumer). Encoded as a 64-bit packed task_desc_t.
bingo_hw_manager_task_desc_t t_bound;
initial begin
    t_bound                              = '0;
    t_bound.task_type                    = 2'b00;        // normal post-bind
    t_bound.is_bind                      = 1'b0;
    t_bound.task_id                      = 16'h00B1;
    t_bound.assigned_chiplet_id          = '0;
    t_bound.assigned_cluster_id          = '0;
    t_bound.assigned_core_id             = 2'd1;         // core 1 (target)
    t_bound.slot_id                      = 2'd1;
    t_bound.dep_check_info.dep_check_en  = 1'b1;
    t_bound.dep_check_info.dep_check_code= '0;           // static deps already cleared
    t_bound.dep_set_info.dep_set_en      = 1'b1;
    t_bound.dep_set_info.dep_set_all_chiplet = 1'b0;
    t_bound.dep_set_info.dep_set_chiplet_id  = '0;
    t_bound.dep_set_info.dep_set_cluster_id  = '0;
    t_bound.dep_set_info.dep_set_code        = bingo_hw_manager_dep_code_t'(4'b0100); // dep_set to slot 2
end

// Static (non-automatic) packed bind-table entry — needed because `force`
// statements cannot reference automatic variables in QuestaSim.
logic [63:0] bt_entry_packed = '0;

initial begin : chip0_push
    automatic axi_pkg::resp_t resp;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[0].reset();
    done_queue_master[0].reset();

    // Configure t1's return value to 1 so RVDB indexes bind_table[1].
    task_return_value_lut[16'd1] = 8'd1;

    // Pre-load the bind_table SRAM via hierarchical force. Entry [1] holds
    // the bound descriptor for slot 1.
    @(posedge clk_i);
    bt_entry_packed = '0;
    bt_entry_packed[$bits(bingo_hw_manager_task_desc_t)-1:0] = t_bound;
    force gen_dut[0].i_dut.gen_rvdb[0].i_bind_table.mem_q[1] = bt_entry_packed;
    force gen_dut[0].i_dut.gen_rvdb[0].i_bind_table.entry_loaded_q = {64{1'b1}};
    @(posedge clk_i);
    $display("[RVDB] %0t bind_table[1] preloaded (task_id=0x%0h)", $time, t_bound.task_id);

    // Push the static prefix DFG.
    task_queue_master[0].write(task_queue_base[0], '0, t1, '1, resp);
    #50;
    task_queue_master[0].write(task_queue_base[0], '0, t2, '1, resp);
    #50;
    task_queue_master[0].write(task_queue_base[0], '0, t3, '1, resp);
    $display("[RVDB] %0t pushed t1, t2 (RVDB reserve), t3", $time);
end
