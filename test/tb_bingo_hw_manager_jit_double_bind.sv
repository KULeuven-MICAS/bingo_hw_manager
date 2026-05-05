// JIT-DFG double-bind SVA test (negative coverage)
`define TB_STIMULUS_FILE "tb_stimulus_jit_double_bind.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3
// Tell the harness to allow assertion errors without failing the run —
// this stimulus deliberately triggers `assert_no_double_bind`.
`define TB_ALLOW_SVA_ERRORS

module tb_bingo_hw_manager_jit_double_bind;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
