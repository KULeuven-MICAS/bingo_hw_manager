// RVDB basic chain TB — verifies return-value-driven binding end-to-end.
`define TB_STIMULUS_FILE "tb_stimulus_rvdb_basic.svh"
`define TB_NUM_CHIPLET 1
`define TB_NUM_CLUSTERS_PER_CHIPLET 1
`define TB_NUM_CORES_PER_CLUSTER 3

module tb_bingo_hw_manager_rvdb_basic;
  `include "tb_bingo_hw_manager_harness.svh"
endmodule
