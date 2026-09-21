// =============================================================================
// Bingo HW Manager Multi-Edge Testbench -- a JOIN as ONE descriptor
// =============================================================================
// Same harness as tb_bingo_hw_manager_top, driving a stimulus in which a
// consumer checks THREE producer columns in a single dep_check op instead of
// the dummy_check chain the compiler emits today. Proves in RTL that the
// multi-column check is all-or-nothing (never passes on a partial set) and that
// its tag is released for reuse once it drains.
// =============================================================================
`define TB_STIMULUS_FILE "tb_stimulus_multiedge.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 4

module tb_bingo_hw_manager_multiedge;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
