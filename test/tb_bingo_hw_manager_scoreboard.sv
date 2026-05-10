// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>

// Standalone unit testbench for bingo_hw_manager_scoreboard.
//
// Mirrors the structure of tb_bingo_hw_manager_dep_matrix.sv: directed
// stimulus inside a single `initial` block, helper tasks for write / reassign
// / read, and `$error` on mismatch.
//
// Covers:
//   1. Identity reset (table_core = identity, table_valid = 0).
//   2. Normal write through we_i.
//   3. Reassign retargets a live slot.
//   4. Reassign priority over we_i when both fire in the same cycle.
//   5. Inverse-table mirror invariant after each write/reassign.
//   6. Repeated identical writes do not trip the slot-uniqueness SVA.
//   7. Forward read coherence with reassign (read_core_o tracks rebind).

`timescale 1ns/1ps

module tb_bingo_hw_manager_scoreboard();

    // Larger than the typical NUM_CORES_PER_CLUSTER=4 so the tests can target
    // distinct "spare" cores (e.g. slot=2 -> core=5) without aliasing.
    localparam int unsigned NUM_SLOTS    = 8;
    localparam int unsigned ID_WIDTH     = $clog2(NUM_SLOTS);

    typedef logic [ID_WIDTH-1:0] slot_id_t;
    typedef logic [ID_WIDTH-1:0] core_id_t;

    // Clock / reset
    logic clk_i;
    logic rst_ni;

    // DUT signals
    logic     we;
    slot_id_t write_slot;
    core_id_t write_core;
    logic     reassign_valid;
    slot_id_t reassign_slot;
    core_id_t reassign_core;
    slot_id_t read_slot;
    core_id_t read_core;
    logic     read_valid;
    core_id_t inv_read_core;
    slot_id_t inv_read_slot;
    core_id_t [NUM_SLOTS-1:0] table_core;
    logic     [NUM_SLOTS-1:0] table_valid;
    slot_id_t [NUM_SLOTS-1:0] inv_table;

    bingo_hw_manager_scoreboard #(
        .NUM_SLOTS (NUM_SLOTS),
        .slot_id_t (slot_id_t),
        .core_id_t (core_id_t)
    ) dut (
        .clk_i            (clk_i         ),
        .rst_ni           (rst_ni        ),
        .we_i             (we            ),
        .write_slot_i     (write_slot    ),
        .write_core_i     (write_core    ),
        .reassign_valid_i (reassign_valid),
        .reassign_slot_i  (reassign_slot ),
        .reassign_core_i  (reassign_core ),
        .read_slot_i      (read_slot     ),
        .read_core_o      (read_core     ),
        .read_valid_o     (read_valid    ),
        .inv_read_core_i  (inv_read_core ),
        .inv_read_slot_o  (inv_read_slot ),
        .table_core_o     (table_core    ),
        .table_valid_o    (table_valid   ),
        .inv_table_o      (inv_table     )
    );

    initial clk_i = 0;
    always #5 clk_i = ~clk_i;

    // Error counter for end-of-test summary
    int unsigned err_count = 0;

    task automatic clear_inputs();
        we             = 1'b0;
        write_slot     = '0;
        write_core     = '0;
        reassign_valid = 1'b0;
        reassign_slot  = '0;
        reassign_core  = '0;
    endtask

    // Pulse we_i for one cycle.
    task automatic do_write(input slot_id_t s, input core_id_t c);
        @(posedge clk_i);
        write_slot <= s;
        write_core <= c;
        we         <= 1'b1;
        @(posedge clk_i);
        we         <= 1'b0;
        write_slot <= '0;
        write_core <= '0;
    endtask

    // Pulse reassign_valid_i for one cycle.
    task automatic do_reassign(input slot_id_t s, input core_id_t c);
        @(posedge clk_i);
        reassign_slot  <= s;
        reassign_core  <= c;
        reassign_valid <= 1'b1;
        @(posedge clk_i);
        reassign_valid <= 1'b0;
        reassign_slot  <= '0;
        reassign_core  <= '0;
    endtask

    // Drive we_i and reassign_valid_i simultaneously to check priority.
    task automatic do_write_and_reassign(input slot_id_t ws, input core_id_t wc,
                                         input slot_id_t rs, input core_id_t rc);
        @(posedge clk_i);
        write_slot     <= ws;
        write_core     <= wc;
        we             <= 1'b1;
        reassign_slot  <= rs;
        reassign_core  <= rc;
        reassign_valid <= 1'b1;
        @(posedge clk_i);
        we             <= 1'b0;
        reassign_valid <= 1'b0;
        write_slot     <= '0;
        write_core     <= '0;
        reassign_slot  <= '0;
        reassign_core  <= '0;
    endtask

    task automatic expect_eq_int(input string label, input int got, input int exp);
        if (got !== exp) begin
            $error("[%0t] %s: expected %0d, got %0d", $time, label, exp, got);
            err_count++;
        end else begin
            $display("[%0t] %s: %0d (OK)", $time, label, got);
        end
    endtask

    task automatic check_inverse_mirror(input string ctx);
        for (int unsigned s = 0; s < NUM_SLOTS; s++) begin
            if (table_valid[s]) begin
                if (inv_table[table_core[s]] !== slot_id_t'(s)) begin
                    $error("[%0t] %s: inverse mirror broken at slot=%0d core=%0d inv=%0d",
                           $time, ctx, s, table_core[s], inv_table[table_core[s]]);
                    err_count++;
                end
            end
        end
    endtask

    initial begin
        // ---- Reset ----
        clear_inputs();
        read_slot     = '0;
        inv_read_core = '0;
        rst_ni        = 1'b0;
        repeat (3) @(posedge clk_i);
        rst_ni        = 1'b1;
        @(posedge clk_i);

        // ---- Test 1: identity reset ----
        $display("[Test 1] Identity reset");
        for (int unsigned s = 0; s < NUM_SLOTS; s++) begin
            read_slot     = slot_id_t'(s);
            inv_read_core = core_id_t'(s);
            #1;
            expect_eq_int($sformatf("table_core[%0d]", s), int'(table_core[s]),  s);
            expect_eq_int($sformatf("inv_table[%0d]", s),  int'(inv_table[s]),   s);
            expect_eq_int($sformatf("table_valid[%0d]", s),int'(table_valid[s]), 0);
            expect_eq_int($sformatf("read_core_o(slot=%0d)", s),  int'(read_core), s);
            expect_eq_int($sformatf("read_valid_o(slot=%0d)", s), int'(read_valid), 0);
            expect_eq_int($sformatf("inv_read_slot_o(core=%0d)", s), int'(inv_read_slot), s);
        end

        // ---- Test 2: normal write ----
        $display("[Test 2] Normal write through we_i (slot=2, core=2)");
        do_write(2, 2);
        #1;
        expect_eq_int("table_core[2]",  int'(table_core[2]),  2);
        expect_eq_int("table_valid[2]", int'(table_valid[2]), 1);
        expect_eq_int("inv_table[2]",   int'(inv_table[2]),   2);
        check_inverse_mirror("after T2");

        // ---- Test 3: reassign retargets a live slot ----
        $display("[Test 3] Reassign slot=2 from core=2 to core=5");
        do_reassign(2, 5);
        #1;
        expect_eq_int("table_core[2]",  int'(table_core[2]),  5);
        expect_eq_int("table_valid[2]", int'(table_valid[2]), 1);
        expect_eq_int("inv_table[5]",   int'(inv_table[5]),   2);
        // Per scoreboard.sv comment: inv_table[2] is NOT auto-cleared by reassign.
        // It still holds whatever was last written there (the reset identity, =2).
        // This is documented behavior; we just check it isn't 5 (which would be
        // an aliasing bug).
        if (inv_table[2] === 5) begin
            $error("[%0t] inv_table[2] aliased to 5 after reassign — bug",
                   $time);
            err_count++;
        end
        check_inverse_mirror("after T3");

        // ---- Test 7 (early): forward read coherence with reassign ----
        $display("[Test 7] Forward read coherence after reassign");
        read_slot = slot_id_t'(2);
        #1;
        expect_eq_int("read_core_o(slot=2 after reassign)", int'(read_core), 5);
        expect_eq_int("read_valid_o(slot=2 after reassign)", int'(read_valid), 1);

        // ---- Test 4: reassign priority over we_i in the same cycle ----
        $display("[Test 4] Reassign priority over we_i (both fire on slot=3)");
        do_write_and_reassign(3 /*ws*/, 3 /*wc*/, 3 /*rs*/, 6 /*rc*/);
        #1;
        expect_eq_int("table_core[3]",  int'(table_core[3]),  6);
        expect_eq_int("table_valid[3]", int'(table_valid[3]), 1);
        expect_eq_int("inv_table[6]",   int'(inv_table[6]),   3);
        check_inverse_mirror("after T4");

        // ---- Test 5: inverse-table mirror invariant after a sequence ----
        $display("[Test 5] Inverse-table mirror invariant across a sequence");
        do_write(0, 0);
        do_reassign(0, 7);
        do_write(1, 1);
        #1;
        check_inverse_mirror("after T5 sequence");
        expect_eq_int("table_core[0]", int'(table_core[0]), 7);
        expect_eq_int("inv_table[7]",  int'(inv_table[7]),  0);
        expect_eq_int("table_core[1]", int'(table_core[1]), 1);
        expect_eq_int("inv_table[1]",  int'(inv_table[1]),  1);

        // ---- Test 6: repeated identical writes do not trip slot-uniqueness ----
        $display("[Test 6] Repeated identical writes (slot=4, core=4) twice");
        do_write(4, 4);
        do_write(4, 4); // would trip p_slot_uniqueness only if write_core differed
        #1;
        expect_eq_int("table_core[4]",  int'(table_core[4]),  4);
        expect_eq_int("table_valid[4]", int'(table_valid[4]), 1);
        check_inverse_mirror("after T6");

        // ---- End ----
        repeat (3) @(posedge clk_i);
        if (err_count == 0) begin
            $display("[tb_bingo_hw_manager_scoreboard] ALL TESTS PASSED");
        end else begin
            $error("[tb_bingo_hw_manager_scoreboard] %0d FAILURES", err_count);
        end
        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $error("[tb_bingo_hw_manager_scoreboard] Watchdog timeout");
        $finish;
    end

endmodule
