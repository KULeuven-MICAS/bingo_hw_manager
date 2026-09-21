// =============================================================================
// Cross-die CERF testbench -- a predicate riding the dependency edge
// =============================================================================
// Two chiplets. A gating task on chip 0 gates a conditional task on chip 1 by
// carrying its CERF window inside the cross-chiplet dep-set message. Includes a
// negative control: a second conditional task whose group lies outside the
// window must stay skipped. See tb_stimulus_cerf_mc.svh.
// =============================================================================
`define TB_STIMULUS_FILE "tb_stimulus_cerf_mc.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_GLOBAL_CERF_GROUPS 8

module tb_bingo_hw_manager_cerf_mc;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
