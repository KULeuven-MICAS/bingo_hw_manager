// =============================================================================
// Master-mode task queue through the TOP
// =============================================================================
// The only harness TB that drives TASK_QUEUE_TYPE == 1: the manager fetches its
// descriptor list over AXI-Lite rather than having it pushed into a mailbox,
// with a 128-bit descriptor assembled from two 64-bit beats. It also pins
// TaskQueueMaxOutstanding end to end -- see tb_stimulus_task_fetch_top.svh.
// =============================================================================
`define TB_STIMULUS_FILE "tb_stimulus_task_fetch_top.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
`define TB_TASK_QUEUE_TYPE 1
`define TB_TASK_DESC_BUS_WIDTH 128
`define TB_TASK_QUEUE_MAX_OUTSTANDING 4

module tb_bingo_hw_manager_task_fetch_top;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
