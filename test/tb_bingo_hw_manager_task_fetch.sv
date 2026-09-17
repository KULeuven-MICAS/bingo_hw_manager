`timescale 1ns/1ps
`include "axi/typedef.svh"

// Unit testbench for bingo_hw_manager_task_queue_master.
//
// WHY THIS EXISTS. The six pre-existing testbenches all drive TASK_QUEUE_TYPE==0, the AXI-Lite
// SLAVE task queue, so NONE of them ever instantiates the fetch master -- yet TYPE==1 (this
// module) is the path HeMAiA actually uses. The multi-beat descriptor fetch was therefore
// completely uncovered. This TB drives the master directly against a behavioural AXI-Lite task
// memory and checks three things the 64->128 bit widening depends on:
//
//   1. EXACTNESS      every descriptor arrives bit-identical, at both Beats==1 (the degenerate
//                     case, which must reproduce the old single-beat behaviour) and Beats==2.
//   2. ADDRESSING     the AR sequence is base + i*DescBytes + beat*BeatBytes, i.e. the descriptor
//                     stride is the DESCRIPTOR width and not the bus width. Getting this wrong is
//                     silent: every descriptor still arrives, just from the wrong offsets.
//   3. ATOMICITY      under FIFO back-pressure the master must never commit a half-assembled
//                     descriptor. The checker asserts that the number of FIFO pushes never
//                     exceeds the number of COMPLETED descriptors.
//
// The count check matters more than it looks: a torn descriptor is still a legal bit pattern, so
// nothing downstream can notice one. Only a producer-side invariant can.

module tb_bingo_hw_manager_task_fetch();

  localparam time CLK_PERIOD = 10ns;
  localparam int unsigned AW = 48;
  localparam int unsigned DW = 64;   // one AXI-Lite beat; fixed by the SoC narrow fabric

  logic clk_i, rst_ni;
  int   errors = 0;

  initial begin
    clk_i = 1'b0;
    forever #(CLK_PERIOD/2) clk_i = ~clk_i;
  end

  // Two independent instances: the degenerate 1-beat case and the 2-beat case.
  int unsigned errs_1beat, errs_2beat;

  fetch_case #(.AW(AW), .DW(DW), .DESC_W(64),  .NUM_TASK(7),  .CASE_NAME("Beats=1")) i_case1 (
    .clk_i(clk_i), .rst_ni(rst_ni), .errors_o(errs_1beat));
  fetch_case #(.AW(AW), .DW(DW), .DESC_W(128), .NUM_TASK(11), .CASE_NAME("Beats=2")) i_case2 (
    .clk_i(clk_i), .rst_ni(rst_ni), .errors_o(errs_2beat));

  initial begin
    rst_ni = 1'b0;
    repeat (5) @(posedge clk_i);
    rst_ni = 1'b1;
    // Both cases self-terminate; give them a generous ceiling.
    repeat (4000) @(posedge clk_i);
    errors = errs_1beat + errs_2beat;
    $display("--------------------------------------------------");
    if (errors == 0) begin
      $display("|           SIMULATION PASSED                   |");
    end else begin
      $display("|           SIMULATION FAILED (%0d errors)       |", errors);
    end
    $display("--------------------------------------------------");
    $finish;
  end

endmodule


// One (descriptor width) scenario: task memory + master + checker.
module fetch_case #(
  parameter int unsigned AW = 48,
  parameter int unsigned DW = 64,
  parameter int unsigned DESC_W = 128,
  parameter int unsigned NUM_TASK = 8,
  parameter string       CASE_NAME = "case"
) (
  input  logic clk_i,
  input  logic rst_ni,
  output int unsigned errors_o
);

  localparam int unsigned BEATS      = DESC_W / DW;
  localparam int unsigned BEAT_BYTES = DW / 8;
  localparam int unsigned DESC_BYTES = DESC_W / 8;
  localparam logic [AW-1:0] BASE     = 48'h0000_1000_0000;

  typedef logic [AW-1:0]   addr_t;
  typedef logic [DW-1:0]   data_t;
  typedef logic [DW/8-1:0] strb_t;
  `AXI_LITE_TYPEDEF_ALL(tb, addr_t, data_t, strb_t)

  tb_req_t  req;
  tb_resp_t rsp;

  // ---- golden task list -------------------------------------------------------------------
  logic [DESC_W-1:0] golden [NUM_TASK];
  initial begin
    for (int unsigned i = 0; i < NUM_TASK; i++) begin
      // A distinctive pattern per descriptor, different in EVERY beat, so a swapped or dropped
      // beat cannot alias to the right answer.
      for (int unsigned b = 0; b < BEATS; b++) begin
        golden[i][b*DW +: DW] = {32'hDEAD_0000 | i[15:0], 16'hBE00 | b[7:0], 16'hA5A5};
      end
    end
  end

  // ---- behavioural AXI-Lite task memory ---------------------------------------------------
  // Serves one read at a time with a variable-latency response, and RECORDS every address it is
  // asked for so the checker can verify the stride.
  addr_t seen_addr [$];
  logic  ar_hs;
  assign ar_hs = req.ar_valid && rsp.ar_ready;

  addr_t pend_addr;
  logic  pend_valid;
  int unsigned lat;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp.ar_ready <= 1'b0;
      rsp.r_valid  <= 1'b0;
      rsp.r        <= '0;
      pend_valid   <= 1'b0;
      pend_addr    <= '0;
      lat          <= 0;
    end else begin
      // accept an AR only when no response is in flight
      rsp.ar_ready <= !pend_valid && !rsp.r_valid;
      if (req.ar_valid && rsp.ar_ready && !pend_valid) begin
        pend_addr  <= req.ar.addr;
        pend_valid <= 1'b1;
        lat        <= (req.ar.addr[5:3] % 3);  // 0..2 cycles, deterministic jitter
        seen_addr.push_back(req.ar.addr);
      end
      if (pend_valid) begin
        if (lat != 0) begin
          lat <= lat - 1;
        end else if (!rsp.r_valid) begin
          // serve the beat: index the golden list by descriptor and beat
          automatic int unsigned off  = int'((pend_addr - BASE));
          automatic int unsigned didx = off / DESC_BYTES;
          automatic int unsigned bidx = (off % DESC_BYTES) / BEAT_BYTES;
          rsp.r.data <= (didx < NUM_TASK) ? golden[didx][bidx*DW +: DW] : {DW{1'bx}};
          rsp.r.resp <= 2'b00;
          rsp.r_valid <= 1'b1;
          pend_valid  <= 1'b0;
        end
      end
      if (rsp.r_valid && req.r_ready) begin
        rsp.r_valid <= 1'b0;
      end
    end
  end
  // write channels unused
  always_comb begin
    rsp.aw_ready = 1'b0;
    rsp.w_ready  = 1'b0;
    rsp.b_valid  = 1'b0;
    rsp.b        = '0;
  end

  // ---- DUT ---------------------------------------------------------------------------------
  logic [31:0] start_q;
  logic [DESC_W-1:0] q_data;
  logic              q_pop, q_empty;
  logic [31:0]       reset_start;
  logic              reset_start_en;

  bingo_hw_manager_task_queue_master #(
    .TaskQueueDepth (4                    ),   // deliberately SMALL: forces back-pressure
    .TaskIdWidth    (12                   ),
    .CfgBusWidth    (32                   ),
    .req_lite_t     (tb_req_t             ),
    .resp_lite_t    (tb_resp_t            ),
    .addr_t         (addr_t               ),
    .data_t         (data_t               ),
    .desc_t         (logic [DESC_W-1:0]   )
  ) i_dut (
    .clk_i                      (clk_i          ),
    .rst_ni                     (rst_ni         ),
    .task_list_base_addr_i      (BASE           ),
    .num_task_i                 (NUM_TASK       ),
    .start_i                    (start_q        ),
    .reset_start_o              (reset_start    ),
    .reset_start_en_o           (reset_start_en ),
    .task_queue_axi_lite_req_o  (req            ),
    .task_queue_axi_lite_resp_i (rsp            ),
    .task_queue_data_o          (q_data         ),
    .task_queue_pop_i           (q_pop          ),
    .task_queue_empty_o         (q_empty        )
  );

  // ---- atomicity invariant -----------------------------------------------------------------
  // Count accepted R beats and FIFO pushes. A push may only ever happen on a beat that completes
  // a descriptor, so pushes*BEATS must never exceed beats accepted.
  int unsigned n_beats, n_push;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      n_beats <= 0; n_push <= 0;
    end else begin
      if (rsp.r_valid && req.r_ready) n_beats <= n_beats + 1;
      if (i_dut.task_queue_push)      n_push  <= n_push + 1;
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni && (n_push * BEATS > n_beats)) begin
      $error("[%s] ATOMICITY: %0d pushes for only %0d accepted beats (BEATS=%0d) -- a partial descriptor was committed",
             CASE_NAME, n_push, n_beats, BEATS);
    end
  end

  // ---- trace (debug) -----------------------------------------------------------------------
  // Deliberately kept: when this TB fails, the first question is always "did the DUT emit the
  // wrong thing, or did the checker consume it wrongly?". These two lines answer it in one run.
  always_ff @(posedge clk_i) begin
    if (rst_ni && i_dut.task_queue_push)
      $display("[%s] t=%0t PUSH 0x%0h", CASE_NAME, $time, i_dut.task_queue_data_in);
    if (rst_ni && q_pop && !q_empty)
      $display("[%s] t=%0t POP  0x%0h", CASE_NAME, $time, q_data);
  end

  // ---- checker -----------------------------------------------------------------------------
  int unsigned errs;
  assign errors_o = errs;

  initial begin
    errs    = 0;
    start_q = 32'd0;
    q_pop   = 1'b0;
    wait (rst_ni);
    // Drive and sample on the NEGEDGE, the convention the other TBs in this repo use: the DUT's
    // registered outputs (q_empty, q_data) settle on the posedge, so reading them in the same
    // delta as that edge races the non-blocking updates and can pop an empty FIFO.
    repeat (3) @(negedge clk_i);
    start_q = 32'd1;
    @(negedge clk_i);
    start_q = 32'd0;

    for (int unsigned i = 0; i < NUM_TASK; i++) begin
      // Irregular pop cadence so the 4-deep FIFO genuinely fills and back-pressures mid-descriptor.
      // The +1 is load-bearing: with a bare `i % 5` the zero-wait iterations re-assert q_pop in the
      // same delta they clear it, so q_pop never goes low between iterations and a single posedge
      // gap becomes two pops -- which reads as "descriptor i+1 == descriptor i".
      repeat ((i % 5) + 1) @(negedge clk_i);
      while (q_empty) @(negedge clk_i);
      if (q_data !== golden[i]) begin
        $error("[%s] descriptor %0d mismatch:\n  got      0x%0h\n  expected 0x%0h",
               CASE_NAME, i, q_data, golden[i]);
        errs++;
      end
      q_pop = 1'b1;
      @(negedge clk_i);   // the pop lands on the posedge in between
      q_pop = 1'b0;
    end

    // ---- address stride check --------------------------------------------------------------
    if (seen_addr.size() != NUM_TASK * BEATS) begin
      $error("[%s] expected %0d AR transactions (%0d tasks x %0d beats), saw %0d",
             CASE_NAME, NUM_TASK*BEATS, NUM_TASK, BEATS, seen_addr.size());
      errs++;
    end else begin
      for (int unsigned i = 0; i < NUM_TASK; i++) begin
        for (int unsigned b = 0; b < BEATS; b++) begin
          automatic addr_t exp = BASE + (i * DESC_BYTES) + (b * BEAT_BYTES);
          if (seen_addr[i*BEATS + b] !== exp) begin
            $error("[%s] AR[%0d,beat %0d] = 0x%0h, expected 0x%0h (descriptor stride must be %0d bytes)",
                   CASE_NAME, i, b, seen_addr[i*BEATS + b], exp, DESC_BYTES);
            errs++;
          end
        end
      end
    end

    // ---- no extra fetches ------------------------------------------------------------------
    repeat (40) @(negedge clk_i);
    if (!q_empty) begin
      $error("[%s] master produced MORE than %0d descriptors", CASE_NAME, NUM_TASK);
      errs++;
    end

    if (errs == 0)
      $display("[%s] OK: %0d descriptors, %0d beats each, stride %0d B, atomic under back-pressure",
               CASE_NAME, NUM_TASK, BEATS, DESC_BYTES);
  end

endmodule
