// JIT-DFG orphan force-drain test
`define TB_STIMULUS_FILE "tb_stimulus_jit_orphan_force_drain.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3

module tb_bingo_hw_manager_jit_orphan_force_drain;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
