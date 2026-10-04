// =============================================================================
// Done-pairing testbench -- a normal task's enabled remote set
// =============================================================================
// A normal task on chip 0 sets a dependency on chip 1: the set must wait for the
// task's done, as a local set does. Checks the ORDER, not only completion.
// See tb_stimulus_done_pairing_remote.svh.
// =============================================================================
// test files compiled before this one in the same vlog call may leave these defined
`undef TB_GLOBAL_CERF_GROUPS
`undef TB_TASK_DESC_BUS_WIDTH
`undef TB_TASK_QUEUE_MAX_OUTSTANDING
`undef TB_TASK_QUEUE_TYPE
`undef TB_STIMULUS_FILE
`undef TB_NUM_CHIPLET
`undef TB_NUM_CLUSTERS_PER_CHIPLET
`undef TB_NUM_CORES_PER_CLUSTER
`undef DONE_PAIRING_CHIP
`define TB_STIMULUS_FILE "tb_stimulus_done_pairing_remote.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
module tb_bingo_hw_manager_done_pairing_remote;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
