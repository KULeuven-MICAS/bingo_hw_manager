// =============================================================================
// Done-pairing testbench -- a set-disabled task on chip 0 (local drop path)
// =============================================================================
// A normal task with dep_set_en = 0 must still consume its done entry, or the next
// task's set on that core fires before that task is done. On chip 0 the entry's
// unused dep_set_chiplet_id (0) is the chip's own, so it leaves by the local drop
// path. Checks the ORDER, not only completion. See tb_stimulus_done_pairing_en0.svh.
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
`define DONE_PAIRING_CHIP 0
module tb_bingo_hw_manager_done_pairing_chip0;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
