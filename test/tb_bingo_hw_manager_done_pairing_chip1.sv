// =============================================================================
// Done-pairing testbench -- a set-disabled task on chip 1 (chiplet path)
// =============================================================================
// The tasks of tb_bingo_hw_manager_done_pairing_chip0 on chip 1: the set-disabled
// entry's unused dep_set_chiplet_id (0) is another chip's, so before the done-pairing
// fix it left by the chiplet path. Checks the ORDER, not only completion.
// See tb_stimulus_done_pairing_en0.svh.
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
`define TB_STIMULUS_FILE "tb_stimulus_done_pairing_en0.svh"
`define TB_NUM_CHIPLET 2
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define DONE_PAIRING_CHIP 1
module tb_bingo_hw_manager_done_pairing_chip1;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
