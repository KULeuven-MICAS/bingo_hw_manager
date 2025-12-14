`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"
`include "axi/port.svh"

// This testbench tests the basic functionality of bingo_hw_manager_top.sv
// It will instantiate 4 top modules to simulate 4 chiplets
// At the beginning, the host will push tasks into the local task queue
// Then the hw manager will handle the task dependency management and communicate with other chiplets via h2h mailboxes
// The device cores will read tasks from the local ready queue and send done info back to the hw manager via the local done queue
import axi_pkg::*;
import axi_test::*;

module tb_bingo_hw_manager_top;

    // ---------------------------------------------------------------------------
    // Local configuration
    // ---------------------------------------------------------------------------
    localparam int unsigned NUM_CHIPLET = 4;
    localparam int unsigned NUM_CLUSTERS_PER_CHIPLET = 2;
    localparam int unsigned NUM_CORES_PER_CLUSTER    = 3;
    localparam int unsigned READY_AGENT_NUM = NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET;
    localparam int unsigned ChipIdWidth = 8;
    localparam int unsigned HOST_AW = 48;
    localparam int unsigned HOST_DW = 64;
    localparam int unsigned DEV_AW  = 48;
    localparam int unsigned DEV_DW  = 32;
    typedef logic [HOST_AW-1:0]   host_axi_lite_addr_t;
    typedef logic [HOST_DW-1:0]   host_axi_lite_data_t;
    typedef logic [HOST_DW/8-1:0] host_axi_lite_strb_t;
    typedef logic [DEV_AW-1:0]    device_axi_lite_addr_t;
    typedef logic [DEV_DW-1:0]    device_axi_lite_data_t;
    typedef logic [DEV_DW/8-1:0]  device_axi_lite_strb_t;
    typedef logic [ChipIdWidth-1:0] chip_id_t;
    localparam host_axi_lite_addr_t TASK_QUEUE_BASE  = 48'h1000_0000;
    localparam host_axi_lite_addr_t DONE_QUEUE_BASE  = 48'h2000_0000;
    localparam host_axi_lite_addr_t READY_QUEUE_BASE = 48'h3000_0000;
    localparam host_axi_lite_addr_t READY_QUEUE_STRIDE = 48'h1000; // 4 KiB
    localparam host_axi_lite_addr_t H2H_DONE_QUEUE_BASE = 48'h4000_0000;

    // --------Type definitions and signal declarations--------------------//
    // ---- Start of Type definitions -------------------------------------//
    localparam int unsigned TaskIdWidth = 12;
    // Task Type
    // 0: Normal Task
    // 1: Dummy Task
    typedef logic                                        bingo_hw_manager_task_type_t;
    // Task ID
    typedef logic [TaskIdWidth-1:0                     ] bingo_hw_manager_task_id_t;
    // Assigned Chiplet ID
    typedef logic [ChipIdWidth-1:0                     ] bingo_hw_manager_assigned_chiplet_id_t;
    // Assigned Cluster ID
    typedef logic [$clog2(NUM_CLUSTERS_PER_CHIPLET)-1:0] bingo_hw_manager_assigned_cluster_id_t;
    // Assigned Core ID
    typedef logic [$clog2(NUM_CORES_PER_CLUSTER)-1:0   ] bingo_hw_manager_assigned_core_id_t;
    // Dependency check info struct
    typedef logic [NUM_CORES_PER_CLUSTER-1:0]            bingo_hw_manager_dep_code_t;
    typedef struct packed{
        bingo_hw_manager_dep_code_t                  dep_check_code;
        logic                                        dep_check_en;
    } bingo_hw_manager_dep_check_info_t;
    // Dependency set info struct
    typedef struct packed{
        bingo_hw_manager_dep_code_t                  dep_set_code;
        bingo_hw_manager_assigned_cluster_id_t       dep_set_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id;
        logic                                        dep_set_all_chiplet;
        logic                                        dep_set_en;
    } bingo_hw_manager_dep_set_info_t;

    // Task info struct
    typedef struct packed{
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
    } bingo_hw_manager_task_desc_t;

    localparam int unsigned TaskDescWidth = $bits(bingo_hw_manager_task_desc_t);
    localparam int unsigned ReservedBitsForTaskDesc = HOST_DW - TaskDescWidth;
    if (TaskDescWidth>HOST_DW) begin : gen_task_desc_width_check
        initial begin
        $error("Task Decriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", TaskDescWidth, HOST_DW);
        $finish;
        end
    end
    // 64bit Task Descriptor with reserved bits
    typedef struct packed{
        logic [ReservedBitsForTaskDesc-1:0]          reserved_bits;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
    } bingo_hw_manager_task_desc_full_t;

    // Done info struct
    typedef struct packed{
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_t;

    localparam int unsigned DoneInfoWidth = $bits(bingo_hw_manager_done_info_t);
    localparam int unsigned ReservedBitsForDoneInfo = DEV_DW - DoneInfoWidth;
    if (DoneInfoWidth>DEV_DW) begin : gen_done_info_width_check
        initial begin
        $error("Task Decriptor width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", DoneInfoWidth, DEV_DW);
        $finish;
        end
    end

    typedef struct packed{
        logic [ReservedBitsForDoneInfo-1:0]        reserved_bits;
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_full_t;

    typedef struct packed{
        bingo_hw_manager_assigned_cluster_id_t     dep_matrix_id;
        logic [NUM_CORES_PER_CLUSTER-1:0]          dep_matrix_col;
        bingo_hw_manager_dep_code_t                dep_set_code;
    } bingo_hw_manager_dep_matrix_set_meta_t;

    typedef struct packed{
        bingo_hw_manager_task_id_t           task_id;
        bingo_hw_manager_dep_set_info_t      dep_set_info;
    } bingo_hw_manager_checkout_task_desc_t;
  // ---------------------------------------------------------------------------
  // Task descriptor packing helper
  // ---------------------------------------------------------------------------

  function automatic bingo_hw_manager_task_desc_full_t pack_normal_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_check_en,
    input bingo_hw_manager_dep_code_t            dep_check_code,
    input logic                                  dep_set_en,
    input logic                                  dep_set_all_chiplet,
    input bingo_hw_manager_assigned_chiplet_id_t dep_set_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t dep_set_cluster_id,
    input bingo_hw_manager_dep_code_t            dep_set_code
  );

    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info.dep_check_en      = dep_check_en;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_all_chiplet = dep_set_all_chiplet;
    tmp.dep_set_info.dep_set_chiplet_id  = dep_set_chiplet_id;
    tmp.dep_set_info.dep_set_cluster_id  = dep_set_cluster_id;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.reserved_bits                    = '0;
    return tmp;
  endfunction


  function automatic bingo_hw_manager_task_desc_full_t pack_dummy_check_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_check_en,
    input bingo_hw_manager_dep_code_t            dep_check_code  
  );
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = '1;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info.dep_check_en      = 1'b1;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_set_info                     = '0;
    tmp.reserved_bits                    = '0;
    return tmp;
  endfunction

  function automatic bingo_hw_manager_task_desc_full_t pack_dummy_set_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_set_en,
    input logic                                  dep_set_all_chiplet,
    input bingo_hw_manager_assigned_chiplet_id_t dep_set_chiplet_id,
    input bingo_hw_manager_assigned_cluster_id_t dep_set_cluster_id,
    input bingo_hw_manager_dep_code_t            dep_set_code
  );
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = '1;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info                   = '0;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_all_chiplet = dep_set_all_chiplet;
    tmp.dep_set_info.dep_set_chiplet_id  = dep_set_chiplet_id;
    tmp.dep_set_info.dep_set_cluster_id  = dep_set_cluster_id;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.reserved_bits                    = '0;
    return tmp;
  endfunction
  // ---------------------------------------------------------------------------
  // Clock / reset
  // ---------------------------------------------------------------------------
  logic clk_i;
  logic rst_ni;

  initial clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  initial begin
    rst_ni = 1'b0;
    repeat (8) @(posedge clk_i);
    rst_ni = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // AXI-Lite type aliases (from axi/typedef.svh)
  // ---------------------------------------------------------------------------
  `AXI_LITE_TYPEDEF_ALL(host, host_axi_lite_addr_t, host_axi_lite_data_t, host_axi_lite_strb_t)
  `AXI_LITE_TYPEDEF_ALL(dev , device_axi_lite_addr_t, device_axi_lite_data_t, device_axi_lite_strb_t)

  // AXI-Lite virtual interfaces for local task queue
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW),
                .AXI_DATA_WIDTH(HOST_DW)
  ) local_task_if_chip0(.clk_i(clk_i));

  AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW),
                .AXI_DATA_WIDTH(HOST_DW)
  ) local_task_if_chip1(.clk_i(clk_i));

  AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW),
                .AXI_DATA_WIDTH(HOST_DW)
  ) local_task_if_chip2(.clk_i(clk_i));

  AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW),
                .AXI_DATA_WIDTH(HOST_DW)
  ) local_task_if_chip3(.clk_i(clk_i));

  // AXI-Lite virtual interfaces for local done queue
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_done_if_chip0(.clk_i(clk_i));


  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_done_if_chip1(.clk_i(clk_i));

  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_done_if_chip2(.clk_i(clk_i));

  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_done_if_chip3(.clk_i(clk_i));
  // AXI-Lite virtual interfaces for local ready queue
  // Chip0
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip0_cluster0_core0(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip0_cluster0_core1(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip0_cluster0_core2(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip0_cluster1_core0(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip0_cluster1_core1(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip0_cluster1_core2(.clk_i(clk_i));
  // Chip1
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip1_cluster0_core0(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip1_cluster0_core1(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip1_cluster0_core2(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip1_cluster1_core0(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip1_cluster1_core1(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip1_cluster1_core2(.clk_i(clk_i));
  // Chip2
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip2_cluster0_core0(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip2_cluster0_core1(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip2_cluster0_core2(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip2_cluster1_core0(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip2_cluster1_core1(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip2_cluster1_core2(.clk_i(clk_i));
  // Chip3
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip3_cluster0_core0(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip3_cluster0_core1(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip3_cluster0_core2(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip3_cluster1_core0(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip3_cluster1_core1(.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if_chip3_cluster1_core2(.clk_i(clk_i));
  // Local Task Queue interface
  host_req_t  [NUM_CHIPLET-1:0] local_task_queue_req;
  host_resp_t [NUM_CHIPLET-1:0] local_task_queue_resp;
  // Connect the wires to if
  `AXI_LITE_ASSIGN_TO_REQ  (local_task_queue_req[0] , local_task_if_chip0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_task_if_chip0 , local_task_queue_resp[0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_task_queue_req[1] , local_task_if_chip1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_task_if_chip1 , local_task_queue_resp[1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_task_queue_req[2] , local_task_if_chip2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_task_if_chip2 , local_task_queue_resp[2]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_task_queue_req[3] , local_task_if_chip3);
  `AXI_LITE_ASSIGN_FROM_RESP(local_task_if_chip3 , local_task_queue_resp[3]);  

  // Local Done Queue interface
  dev_req_t  [NUM_CHIPLET-1:0] local_done_queue_req;
  dev_resp_t [NUM_CHIPLET-1:0] local_done_queue_resp;
  // Connect the wires to if
  `AXI_LITE_ASSIGN_TO_REQ  (local_done_queue_req[0] , local_done_if_chip0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_done_if_chip0 , local_done_queue_resp[0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_done_queue_req[1] , local_done_if_chip1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_done_if_chip1 , local_done_queue_resp[1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_done_queue_req[2] , local_done_if_chip2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_done_if_chip2 , local_done_queue_resp[2]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_done_queue_req[3] , local_done_if_chip3);
  `AXI_LITE_ASSIGN_FROM_RESP(local_done_if_chip3 , local_done_queue_resp[3]);


  // Local Ready Queue interface
  dev_req_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_req_chip0;
  dev_resp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_resp_chip0;
  dev_req_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_req_chip1;
  dev_resp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_resp_chip1;
  dev_req_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_req_chip2;
  dev_resp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_resp_chip2;
  dev_req_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_req_chip3;
  dev_resp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_resp_chip3;
  // Connect the wires to if
  // Chip0
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip0[0][0] , local_ready_if_chip0_cluster0_core0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip0_cluster0_core0 , local_ready_queue_resp_chip0[0][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip0[1][0] , local_ready_if_chip0_cluster0_core1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip0_cluster0_core1 , local_ready_queue_resp_chip0[1][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip0[2][0] , local_ready_if_chip0_cluster0_core2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip0_cluster0_core2 , local_ready_queue_resp_chip0[2][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip0[0][1] , local_ready_if_chip0_cluster1_core0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip0_cluster1_core0 , local_ready_queue_resp_chip0[0][1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip0[1][1] , local_ready_if_chip0_cluster1_core1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip0_cluster1_core1 , local_ready_queue_resp_chip0[1][1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip0[2][1] , local_ready_if_chip0_cluster1_core2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip0_cluster1_core2 , local_ready_queue_resp_chip0[2][1]);
  // Chip1
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip1[0][0] , local_ready_if_chip1_cluster0_core0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip1_cluster0_core0 , local_ready_queue_resp_chip1[0][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip1[1][0] , local_ready_if_chip1_cluster0_core1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip1_cluster0_core1 , local_ready_queue_resp_chip1[1][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip1[2][0] , local_ready_if_chip1_cluster0_core2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip1_cluster0_core2 , local_ready_queue_resp_chip1[2][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip1[0][1] , local_ready_if_chip1_cluster1_core0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip1_cluster1_core0 , local_ready_queue_resp_chip1[0][1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip1[1][1] , local_ready_if_chip1_cluster1_core1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip1_cluster1_core1 , local_ready_queue_resp_chip1[1][1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip1[2][1] , local_ready_if_chip1_cluster1_core2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip1_cluster1_core2 , local_ready_queue_resp_chip1[2][1]);
  // Chip2
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip2[0][0] , local_ready_if_chip2_cluster0_core0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip2_cluster0_core0 , local_ready_queue_resp_chip2[0][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip2[1][0] , local_ready_if_chip2_cluster0_core1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip2_cluster0_core1 , local_ready_queue_resp_chip2[1][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip2[2][0] , local_ready_if_chip2_cluster0_core2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip2_cluster0_core2 , local_ready_queue_resp_chip2[2][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip2[0][1] , local_ready_if_chip2_cluster1_core0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip2_cluster1_core0 , local_ready_queue_resp_chip2[0][1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip2[1][1] , local_ready_if_chip2_cluster1_core1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip2_cluster1_core1 , local_ready_queue_resp_chip2[1][1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip2[2][1] , local_ready_if_chip2_cluster1_core2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip2_cluster1_core2 , local_ready_queue_resp_chip2[2][1]);
  // Chip3
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip3[0][0] , local_ready_if_chip3_cluster0_core0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip3_cluster0_core0 , local_ready_queue_resp_chip3[0][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip3[1][0] , local_ready_if_chip3_cluster0_core1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip3_cluster0_core1 , local_ready_queue_resp_chip3[1][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip3[2][0] , local_ready_if_chip3_cluster0_core2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip3_cluster0_core2 , local_ready_queue_resp_chip3[2][0]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip3[0][1] , local_ready_if_chip3_cluster1_core0);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip3_cluster1_core0 , local_ready_queue_resp_chip3[0][1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip3[1][1] , local_ready_if_chip3_cluster1_core1);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip3_cluster1_core1 , local_ready_queue_resp_chip3[1][1]);
  `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req_chip3[2][1] , local_ready_if_chip3_cluster1_core2);
  `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if_chip3_cluster1_core2 , local_ready_queue_resp_chip3[2][1]);




  // ---------------------------
  // H2H Chiplet Xbar
  // ---------------------------
  localparam axi_pkg::xbar_cfg_t H2HAxiLiteXbarCfg = '{
      NoSlvPorts:         4, 
      NoMstPorts:         4, 
      MaxSlvTrans:        4,
      MaxMstTrans:        4,
      FallThrough:        0,
      LatencyMode:        axi_pkg::CUT_ALL_PORTS,
      PipelineStages:     0,
      AxiIdWidthSlvPorts: 0,
      AxiIdUsedSlvPorts:  0,
      UniqueIds:          0,
      AxiAddrWidth:       HOST_AW,
      AxiDataWidth:       HOST_DW,
      NoAddrRules:        4
  };
  // Define the xbar rule type
  typedef struct packed {
      logic [31:0] idx;
      logic [47:0] start_addr;
      logic [47:0] end_addr;
  } xbar_rule_48_t;
  host_req_t     [3:0] h2h_axi_lite_xbar_in_req;
  host_resp_t    [3:0] h2h_axi_lite_xbar_in_resp;
  host_req_t     [3:0] h2h_axi_lite_xbar_out_req;
  host_resp_t    [3:0] h2h_axi_lite_xbar_out_resp;
  xbar_rule_48_t [3:0] H2HAxiLiteXbarAddrmap;
  assign H2HAxiLiteXbarAddrmap = '{
    '{ idx: 0, start_addr: 48'h0,        end_addr: {8'h0,40'h8000_0000}},  // 0th chiplet
    '{ idx: 1, start_addr: {8'h1,40'h0}, end_addr: {8'h1,40'h8000_0000}},  // 1th chiplet
    '{ idx: 2, start_addr: {8'h2,40'h0}, end_addr: {8'h2,40'h8000_0000}},  // 2th chiplet
    '{ idx: 3, start_addr: {8'h3,40'h0}, end_addr: {8'h3,40'h8000_0000}}   // 3th chiplet
  };
  axi_lite_xbar #(
    .Cfg       (H2HAxiLiteXbarCfg),
    .aw_chan_t (host_aw_chan_t   ),
    .w_chan_t  (host_w_chan_t    ),
    .b_chan_t  (host_b_chan_t    ),
    .ar_chan_t (host_ar_chan_t   ),
    .r_chan_t  (host_r_chan_t    ),
    .axi_req_t (host_req_t       ),
    .axi_resp_t( host_resp_t     ),
    .rule_t    ( xbar_rule_48_t  )
  ) i_axi_lite_xbar_h2h_chiplet(
    .clk_i  ( clk_i ),
    .rst_ni ( rst_ni ),
    .test_i ( '0 ),
    .slv_ports_req_i       ( h2h_axi_lite_xbar_in_req   ),
    .slv_ports_resp_o      ( h2h_axi_lite_xbar_in_resp  ),
    .mst_ports_req_o       ( h2h_axi_lite_xbar_out_req  ),
    .mst_ports_resp_i      ( h2h_axi_lite_xbar_out_resp ),
    .addr_map_i            ( H2HAxiLiteXbarAddrmap      ),
    .en_default_mst_port_i ( '0 ),
    .default_mst_port_i    ( '0 )    
  );




  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  // AXI Driver Interfaces

  axi_lite_driver #(
    .AW(HOST_AW),
    .DW(HOST_DW)
  ) local_task_drv_chip0;

  axi_lite_driver #(
    .AW(HOST_AW),
    .DW(HOST_DW)
  ) local_task_drv_chip1;

  axi_lite_driver #(
    .AW(HOST_AW),
    .DW(HOST_DW)
  ) local_task_drv_chip2;

  axi_lite_driver #(
    .AW(HOST_AW),
    .DW(HOST_DW)
  ) local_task_drv_chip3;

  initial begin
    local_task_drv_chip0 = new(local_task_if_chip0);
    local_task_drv_chip0.reset_master();
    local_task_drv_chip1 = new(local_task_if_chip1);
    local_task_drv_chip1.reset_master();
    local_task_drv_chip2 = new(local_task_if_chip2);
    local_task_drv_chip2.reset_master();
    local_task_drv_chip3 = new(local_task_if_chip3);
    local_task_drv_chip3.reset_master();
  end


  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_done_drv_chip0;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_done_drv_chip1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_done_drv_chip2;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_done_drv_chip3;

  initial begin
    local_done_drv_chip0 = new(local_done_if_chip0);
    local_done_drv_chip0.reset_master();
    local_done_drv_chip1 = new(local_done_if_chip1);
    local_done_drv_chip1.reset_master();
    local_done_drv_chip2 = new(local_done_if_chip2);
    local_done_drv_chip2.reset_master();
    local_done_drv_chip3 = new(local_done_if_chip3);
    local_done_drv_chip3.reset_master();
  end

  // Ready queue drivers
  // Chip0
  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip0_cluster0_core0;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip0_cluster0_core1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip0_cluster0_core2;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip0_cluster1_core0;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip0_cluster1_core1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip0_cluster1_core2;
  // Chip1
  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip1_cluster0_core0;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip1_cluster0_core1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip1_cluster0_core2;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip1_cluster1_core0;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip1_cluster1_core1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip1_cluster1_core2;
  // Chip2
  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip2_cluster0_core0;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip2_cluster0_core1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip2_cluster0_core2;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip2_cluster1_core0;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip2_cluster1_core1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip2_cluster1_core2;
  // Chip3
  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip3_cluster0_core0;
  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip3_cluster0_core1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip3_cluster0_core2;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip3_cluster1_core0;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip3_cluster1_core1;

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv_chip3_cluster1_core2;
  initial begin
    // Initialize the drivers
    // Chip0
    local_ready_drv_chip0_cluster0_core0 = new(local_ready_if_chip0_cluster0_core0);
    local_ready_drv_chip0_cluster0_core0.reset_master();
    local_ready_drv_chip0_cluster0_core1 = new(local_ready_if_chip0_cluster0_core1);
    local_ready_drv_chip0_cluster0_core1.reset_master();
    local_ready_drv_chip0_cluster0_core2 = new(local_ready_if_chip0_cluster0_core2);
    local_ready_drv_chip0_cluster0_core2.reset_master();
    local_ready_drv_chip0_cluster1_core0 = new(local_ready_if_chip0_cluster1_core0);
    local_ready_drv_chip0_cluster1_core0.reset_master();
    local_ready_drv_chip0_cluster1_core1 = new(local_ready_if_chip0_cluster1_core1);
    local_ready_drv_chip0_cluster1_core1.reset_master();
    local_ready_drv_chip0_cluster1_core2 = new(local_ready_if_chip0_cluster1_core2);
    local_ready_drv_chip0_cluster1_core2.reset_master();
    // Chip1
    local_ready_drv_chip1_cluster0_core0 = new(local_ready_if_chip1_cluster0_core0);
    local_ready_drv_chip1_cluster0_core0.reset_master();
    local_ready_drv_chip1_cluster0_core1 = new(local_ready_if_chip1_cluster0_core1);
    local_ready_drv_chip1_cluster0_core1.reset_master();
    local_ready_drv_chip1_cluster0_core2 = new(local_ready_if_chip1_cluster0_core2);
    local_ready_drv_chip1_cluster0_core2.reset_master();
    local_ready_drv_chip1_cluster1_core0 = new(local_ready_if_chip1_cluster1_core0);
    local_ready_drv_chip1_cluster1_core0.reset_master();
    local_ready_drv_chip1_cluster1_core1 = new(local_ready_if_chip1_cluster1_core1);
    local_ready_drv_chip1_cluster1_core1.reset_master();
    local_ready_drv_chip1_cluster1_core2 = new(local_ready_if_chip1_cluster1_core2);
    local_ready_drv_chip1_cluster1_core2.reset_master();
    // Chip2
    local_ready_drv_chip2_cluster0_core0 = new(local_ready_if_chip2_cluster0_core0);
    local_ready_drv_chip2_cluster0_core0.reset_master();
    local_ready_drv_chip2_cluster0_core1 = new(local_ready_if_chip2_cluster0_core1);
    local_ready_drv_chip2_cluster0_core1.reset_master();
    local_ready_drv_chip2_cluster0_core2 = new(local_ready_if_chip2_cluster0_core2);
    local_ready_drv_chip2_cluster0_core2.reset_master();
    local_ready_drv_chip2_cluster1_core0 = new(local_ready_if_chip2_cluster1_core0);
    local_ready_drv_chip2_cluster1_core0.reset_master();
    local_ready_drv_chip2_cluster1_core1 = new(local_ready_if_chip2_cluster1_core1);
    local_ready_drv_chip2_cluster1_core1.reset_master();
    local_ready_drv_chip2_cluster1_core2 = new(local_ready_if_chip2_cluster1_core2);
    local_ready_drv_chip2_cluster1_core2.reset_master();
    // Chip3
    local_ready_drv_chip3_cluster0_core0 = new(local_ready_if_chip3_cluster0_core0);
    local_ready_drv_chip3_cluster0_core0.reset_master();
    local_ready_drv_chip3_cluster0_core1 = new(local_ready_if_chip3_cluster0_core1);
    local_ready_drv_chip3_cluster0_core1.reset_master();
    local_ready_drv_chip3_cluster0_core2 = new(local_ready_if_chip3_cluster0_core2);
    local_ready_drv_chip3_cluster0_core2.reset_master();
    local_ready_drv_chip3_cluster1_core0 = new(local_ready_if_chip3_cluster1_core0);
    local_ready_drv_chip3_cluster1_core0.reset_master();
    local_ready_drv_chip3_cluster1_core1 = new(local_ready_if_chip3_cluster1_core1);
    local_ready_drv_chip3_cluster1_core1.reset_master();
    local_ready_drv_chip3_cluster1_core2 = new(local_ready_if_chip3_cluster1_core2);
    local_ready_drv_chip3_cluster1_core2.reset_master(); 
  end

  device_axi_lite_addr_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_base_addr_2d;
  // Core0 Cluster0
  assign ready_base_addr_2d[0][0] = READY_QUEUE_BASE + (0 * READY_QUEUE_STRIDE);
  // Core1 Cluster0
  assign ready_base_addr_2d[1][0] = READY_QUEUE_BASE + (1 * READY_QUEUE_STRIDE);
  // Core2 Cluster0
  assign ready_base_addr_2d[2][0] = READY_QUEUE_BASE + (2 * READY_QUEUE_STRIDE);
  // Core0 Cluster1
  assign ready_base_addr_2d[0][1] = READY_QUEUE_BASE + (3 * READY_QUEUE_STRIDE);
  // Core1 Cluster1
  assign ready_base_addr_2d[1][1] = READY_QUEUE_BASE + (4 * READY_QUEUE_STRIDE);
  // Core2 Cluster1
  assign ready_base_addr_2d[2][1] = READY_QUEUE_BASE + (5 * READY_QUEUE_STRIDE);

  chip_id_t [NUM_CHIPLET-1:0] chip_id;
  assign chip_id[0] = 8'h0;
  assign chip_id[1] = 8'h1;
  assign chip_id[2] = 8'h2;
  assign chip_id[3] = 8'h3;
  bingo_hw_manager_top #(
    .NUM_CHIPLET              (NUM_CHIPLET              ),
    .NUM_CORES_PER_CLUSTER    (NUM_CORES_PER_CLUSTER    ),
    .NUM_CLUSTERS_PER_CHIPLET (NUM_CLUSTERS_PER_CHIPLET ),
    .HostAxiLiteAddrWidth     (HOST_AW                  ),
    .HostAxiLiteDataWidth     (HOST_DW                  ),
    .DeviceAxiLiteAddrWidth   (DEV_AW                   ),
    .DeviceAxiLiteDataWidth   (DEV_DW                   ),
    .host_axi_lite_req_t      (host_req_t               ),
    .host_axi_lite_resp_t     (host_resp_t              ),
    .device_axi_lite_req_t    (dev_req_t                ),
    .device_axi_lite_resp_t   (dev_resp_t               )
  ) i_dut_chip0 (
    .clk_i                              (clk_i                                                    ),
    .rst_ni                             (rst_ni                                                   ),
    .chip_id_i                          (chip_id[0]                                                ),
    .task_queue_base_addr_i             ({chip_id[0],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
    .task_queue_axi_lite_req_i          (local_task_queue_req[0]                                  ),
    .task_queue_axi_lite_resp_o         (local_task_queue_resp[0]                                 ),
    .chiplet_mailbox_base_addr_i        ({chip_id[0],H2H_DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
    .to_remote_chiplet_axi_lite_req_o   (h2h_axi_lite_xbar_in_req[0]                              ),
    .to_remote_chiplet_axi_lite_resp_i  (h2h_axi_lite_xbar_in_resp[0]                             ),
    .from_remote_axi_lite_req_i         (h2h_axi_lite_xbar_out_req[0]                             ),
    .from_remote_axi_lite_resp_o        (h2h_axi_lite_xbar_out_resp[0]                            ),
    .done_queue_base_addr_i             ({chip_id[0],DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
    .done_queue_axi_lite_req_i          (local_done_queue_req[0]                                  ),
    .done_queue_axi_lite_resp_o         (local_done_queue_resp[0]                                 ),
    .ready_queue_base_addr_i            (ready_base_addr_2d                                       ),
    .ready_queue_axi_lite_req_i         (local_ready_queue_req_chip0                              ),
    .ready_queue_axi_lite_resp_o        (local_ready_queue_resp_chip0                             )
  );    
  bingo_hw_manager_top #(
    .NUM_CHIPLET              (NUM_CHIPLET              ),
    .NUM_CORES_PER_CLUSTER    (NUM_CORES_PER_CLUSTER    ),
    .NUM_CLUSTERS_PER_CHIPLET (NUM_CLUSTERS_PER_CHIPLET ),
    .HostAxiLiteAddrWidth     (HOST_AW                  ),
    .HostAxiLiteDataWidth     (HOST_DW                  ),
    .DeviceAxiLiteAddrWidth   (DEV_AW                   ),
    .DeviceAxiLiteDataWidth   (DEV_DW                   ),
    .host_axi_lite_req_t      (host_req_t               ),
    .host_axi_lite_resp_t     (host_resp_t              ),
    .device_axi_lite_req_t    (dev_req_t                ),
    .device_axi_lite_resp_t   (dev_resp_t               )
  ) i_dut_chip1 (
    .clk_i                              (clk_i                                                    ),
    .rst_ni                             (rst_ni                                                   ),
    .chip_id_i                          (chip_id[1]                                                ),
    .task_queue_base_addr_i             ({chip_id[1],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
    .task_queue_axi_lite_req_i          (local_task_queue_req[1]                                  ),
    .task_queue_axi_lite_resp_o         (local_task_queue_resp[1]                                 ),
    .chiplet_mailbox_base_addr_i        ({chip_id[1],H2H_DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
    .to_remote_chiplet_axi_lite_req_o   (h2h_axi_lite_xbar_in_req[1]                              ),
    .to_remote_chiplet_axi_lite_resp_i  (h2h_axi_lite_xbar_in_resp[1]                             ),
    .from_remote_axi_lite_req_i         (h2h_axi_lite_xbar_out_req[1]                             ),
    .from_remote_axi_lite_resp_o        (h2h_axi_lite_xbar_out_resp[1]                            ),
    .done_queue_base_addr_i             ({chip_id[1],DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
    .done_queue_axi_lite_req_i          (local_done_queue_req[1]                                  ),
    .done_queue_axi_lite_resp_o         (local_done_queue_resp[1]                                 ),
    .ready_queue_base_addr_i            (ready_base_addr_2d                                       ),
    .ready_queue_axi_lite_req_i         (local_ready_queue_req_chip1                              ),
    .ready_queue_axi_lite_resp_o        (local_ready_queue_resp_chip1                             )
  );    
  bingo_hw_manager_top #(
    .NUM_CHIPLET              (NUM_CHIPLET              ),
    .NUM_CORES_PER_CLUSTER    (NUM_CORES_PER_CLUSTER    ),
    .NUM_CLUSTERS_PER_CHIPLET (NUM_CLUSTERS_PER_CHIPLET ),
    .HostAxiLiteAddrWidth     (HOST_AW                  ),
    .HostAxiLiteDataWidth     (HOST_DW                  ),
    .DeviceAxiLiteAddrWidth   (DEV_AW                   ),
    .DeviceAxiLiteDataWidth   (DEV_DW                   ),
    .host_axi_lite_req_t      (host_req_t               ),
    .host_axi_lite_resp_t     (host_resp_t              ),
    .device_axi_lite_req_t    (dev_req_t                ),
    .device_axi_lite_resp_t   (dev_resp_t               )
  ) i_dut_chip2 (
    .clk_i                              (clk_i                                                    ),
    .rst_ni                             (rst_ni                                                   ),
    .chip_id_i                          (chip_id[2]                                                ),
    .task_queue_base_addr_i             ({chip_id[2],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
    .task_queue_axi_lite_req_i          (local_task_queue_req[2]                                  ),
    .task_queue_axi_lite_resp_o         (local_task_queue_resp[2]                                 ),
    .chiplet_mailbox_base_addr_i        ({chip_id[2],H2H_DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
    .to_remote_chiplet_axi_lite_req_o   (h2h_axi_lite_xbar_in_req[2]                              ),
    .to_remote_chiplet_axi_lite_resp_i  (h2h_axi_lite_xbar_in_resp[2]                             ),
    .from_remote_axi_lite_req_i         (h2h_axi_lite_xbar_out_req[2]                             ),
    .from_remote_axi_lite_resp_o        (h2h_axi_lite_xbar_out_resp[2]                            ),
    .done_queue_base_addr_i             ({chip_id[2],DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
    .done_queue_axi_lite_req_i          (local_done_queue_req[2]                                  ),
    .done_queue_axi_lite_resp_o         (local_done_queue_resp[2]                                 ),
    .ready_queue_base_addr_i            (ready_base_addr_2d                                       ),
    .ready_queue_axi_lite_req_i         (local_ready_queue_req_chip2                              ),
    .ready_queue_axi_lite_resp_o        (local_ready_queue_resp_chip2                             )
  );
  bingo_hw_manager_top #(
    .NUM_CHIPLET              (NUM_CHIPLET              ),
    .NUM_CORES_PER_CLUSTER    (NUM_CORES_PER_CLUSTER    ),
    .NUM_CLUSTERS_PER_CHIPLET (NUM_CLUSTERS_PER_CHIPLET ),
    .HostAxiLiteAddrWidth     (HOST_AW                  ),
    .HostAxiLiteDataWidth     (HOST_DW                  ),
    .DeviceAxiLiteAddrWidth   (DEV_AW                   ),
    .DeviceAxiLiteDataWidth   (DEV_DW                   ),
    .host_axi_lite_req_t      (host_req_t               ),
    .host_axi_lite_resp_t     (host_resp_t              ),
    .device_axi_lite_req_t    (dev_req_t                ),
    .device_axi_lite_resp_t   (dev_resp_t               )
  ) i_dut_chip3 (
    .clk_i                              (clk_i                                                    ),
    .rst_ni                             (rst_ni                                                   ),
    .chip_id_i                          (chip_id[3]                                                ),
    .task_queue_base_addr_i             ({chip_id[3],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
    .task_queue_axi_lite_req_i          (local_task_queue_req[3]                                  ),
    .task_queue_axi_lite_resp_o         (local_task_queue_resp[3]                                 ),
    .chiplet_mailbox_base_addr_i        ({chip_id[3],H2H_DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
    .to_remote_chiplet_axi_lite_req_o   (h2h_axi_lite_xbar_in_req[3]                              ),
    .to_remote_chiplet_axi_lite_resp_i  (h2h_axi_lite_xbar_in_resp[3]                             ),
    .from_remote_axi_lite_req_i         (h2h_axi_lite_xbar_out_req[3]                             ),
    .from_remote_axi_lite_resp_o        (h2h_axi_lite_xbar_out_resp[3]                            ),
    .done_queue_base_addr_i             ({chip_id[3],DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
    .done_queue_axi_lite_req_i          (local_done_queue_req[3]                                  ),
    .done_queue_axi_lite_resp_o         (local_done_queue_resp[3]                                 ),
    .ready_queue_base_addr_i            (ready_base_addr_2d                                       ),
    .ready_queue_axi_lite_req_i         (local_ready_queue_req_chip3                              ),
    .ready_queue_axi_lite_resp_o        (local_ready_queue_resp_chip3                             )
  );
  // ---------------------------------------------------------------------------
  // Stimulus threads
  // ---------------------------------------------------------------------------
bingo_hw_manager_task_desc_full_t chip0_cluster0_core0_gemm = pack_normal_task(
    1'b0, // task_type
    16'd1, // task_id
    0, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b0, // dep_check_en
    '0, // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    0, // dep_set_chiplet_id
    1, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip0_cluster1_core1_dma = pack_normal_task(
    1'b0, // task_type
    16'd2, // task_id
    0, // assigned_chiplet_id
    1, // assigned_cluster_id
    1, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    0, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000100) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip0_cluster0_core2_simd = pack_normal_task(
    1'b0, // task_type
    16'd3, // task_id
    0, // assigned_chiplet_id
    0, // assigned_cluster_id
    2, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000010), // dep_check_code
    1'b0, // dep_set_en
    1'b0, // dep_set_all_chiplet
    0, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    '0 // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip1_cluster0_core2_simd = pack_normal_task(
    1'b0, // task_type
    16'd4, // task_id
    1, // assigned_chiplet_id
    0, // assigned_cluster_id
    2, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000100), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    1, // dep_set_chiplet_id
    1, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip1_cluster0_core1_dma = pack_normal_task(
    1'b0, // task_type
    16'd5, // task_id
    1, // assigned_chiplet_id
    0, // assigned_cluster_id
    1, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000100), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    1, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip1_cluster1_core0_gemm = pack_normal_task(
    1'b0, // task_type
    16'd6, // task_id
    1, // assigned_chiplet_id
    1, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000100), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    1, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip1_cluster0_core0_gemm = pack_normal_task(
    1'b0, // task_type
    16'd7, // task_id
    1, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000011), // dep_check_code
    1'b0, // dep_set_en
    1'b0, // dep_set_all_chiplet
    0, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    '0 // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip2_cluster0_core0_gemm = pack_normal_task(
    1'b0, // task_type
    16'd8, // task_id
    2, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000100), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    2, // dep_set_chiplet_id
    1, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip2_cluster0_core1_dma = pack_normal_task(
    1'b0, // task_type
    16'd9, // task_id
    2, // assigned_chiplet_id
    0, // assigned_cluster_id
    1, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    2, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip2_cluster1_core1_dma = pack_normal_task(
    1'b0, // task_type
    16'd10, // task_id
    2, // assigned_chiplet_id
    1, // assigned_cluster_id
    1, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    2, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip2_cluster0_core0_gemm_2 = pack_normal_task(
    1'b0, // task_type
    16'd11, // task_id
    2, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000010), // dep_check_code
    1'b0, // dep_set_en
    1'b0, // dep_set_all_chiplet
    0, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    '0 // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip3_cluster0_core0_gemm_1 = pack_normal_task(
    1'b0, // task_type
    16'd12, // task_id
    3, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    3, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip3_cluster0_core1_dma = pack_normal_task(
    1'b0, // task_type
    16'd13, // task_id
    3, // assigned_chiplet_id
    0, // assigned_cluster_id
    1, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    3, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip3_cluster1_core1_dma = pack_normal_task(
    1'b0, // task_type
    16'd14, // task_id
    3, // assigned_chiplet_id
    1, // assigned_cluster_id
    1, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    3, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip3_cluster0_core0_gemm_2 = pack_normal_task(
    1'b0, // task_type
    16'd15, // task_id
    3, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001), // dep_check_code
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    3, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t chip3_cluster0_core0_gemm_3 = pack_normal_task(
    1'b0, // task_type
    16'd16, // task_id
    3, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000011), // dep_check_code
    1'b0, // dep_set_en
    1'b0, // dep_set_all_chiplet
    0, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    '0 // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_set_chip0_cluster0_core2_simd_to_chip1_cluster0_core2_simd = pack_dummy_set_task(
    1'b1, // task_type
    16'd17,  // task_id
    0, // assigned_chiplet_id
    2, // assigned_core_id
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    1, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000100) // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_set_chip0_cluster0_core2_simd_to_chip2_cluster0_core0_gemm = pack_dummy_set_task(
    1'b1, // task_type
    16'd18,  // task_id
    0, // assigned_chiplet_id
    2, // assigned_core_id
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    2, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_set_chip1_cluster0_core2_simd_0 = pack_dummy_set_task(
    1'b1, // task_type
    16'd19,  // task_id
    1, // assigned_chiplet_id
    2, // assigned_core_id
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    1, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_set_chip1_cluster0_core0_gemm_to_chip3_cluster0_core0_gemm_1 = pack_dummy_set_task(
    1'b1, // task_type
    16'd20,  // task_id
    1, // assigned_chiplet_id
    0, // assigned_core_id
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    3, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_set_chip2_cluster0_core0_gemm_0 = pack_dummy_set_task(
    1'b1, // task_type
    16'd21,  // task_id
    2, // assigned_chiplet_id
    0, // assigned_core_id
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    2, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_set_chip2_cluster0_core0_gemm_2_to_chip3_cluster0_core0_gemm_1 = pack_dummy_set_task(
    1'b1, // task_type
    16'd22,  // task_id
    2, // assigned_chiplet_id
    0, // assigned_core_id
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    3, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_set_chip3_cluster0_core0_gemm_1_0 = pack_dummy_set_task(
    1'b1, // task_type
    16'd23,  // task_id
    3, // assigned_chiplet_id
    0, // assigned_core_id
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    3, // dep_set_chiplet_id
    0, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_set_chip3_cluster0_core0_gemm_1_1 = pack_dummy_set_task(
    1'b1, // task_type
    16'd24,  // task_id
    3, // assigned_chiplet_id
    0, // assigned_core_id
    1'b1, // dep_set_en
    1'b0, // dep_set_all_chiplet
    3, // dep_set_chiplet_id
    1, // dep_set_cluster_id
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_set_code
);

bingo_hw_manager_task_desc_full_t dummy_check_chip2_cluster0_core0_gemm_2_1 = pack_dummy_check_task(
    1'b1, // task_type
    16'd25, // task_id
    2, // assigned_chiplet_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_check_code
);

bingo_hw_manager_task_desc_full_t dummy_check_chip3_cluster0_core0_gemm_1_0 = pack_dummy_check_task(
    1'b1, // task_type
    16'd26, // task_id
    3, // assigned_chiplet_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_check_code
);

bingo_hw_manager_task_desc_full_t dummy_check_chip3_cluster0_core0_gemm_3_1 = pack_dummy_check_task(
    1'b1, // task_type
    16'd27, // task_id
    3, // assigned_chiplet_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_check_code
);
  host_axi_lite_addr_t [NUM_CHIPLET-1:0] task_queue_base;
  assign task_queue_base[0] = {chip_id[0],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]};
  assign task_queue_base[1] = {chip_id[1],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]};
  assign task_queue_base[2] = {chip_id[2],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]};
  assign task_queue_base[3] = {chip_id[3],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]};
  // Host pushes tasks for chiplet 0
  initial begin : chip0_push_sequence
    automatic axi_pkg::resp_t resp_chip0;
    wait (rst_ni);
    @(posedge clk_i);

    fork
      local_task_drv_chip0.send_aw(task_queue_base[0], '0);
      local_task_drv_chip0.send_w(chip0_cluster0_core0_gemm, {HOST_DW/8{1'b1}});
      local_task_drv_chip0.recv_b(resp_chip0);
    join_none
    #50;
    fork
      local_task_drv_chip0.send_aw(task_queue_base[0], '0);
      local_task_drv_chip0.send_w(chip0_cluster1_core1_dma, {HOST_DW/8{1'b1}});
      local_task_drv_chip0.recv_b(resp_chip0);
    join_none
    #50;
    fork
      local_task_drv_chip0.send_aw(task_queue_base[0], '0);
      local_task_drv_chip0.send_w(chip0_cluster0_core2_simd, {HOST_DW/8{1'b1}});
      local_task_drv_chip0.recv_b(resp_chip0);
    join_none
    #50;
    fork
      local_task_drv_chip0.send_aw(task_queue_base[0], '0);
      local_task_drv_chip0.send_w(dummy_set_chip0_cluster0_core2_simd_to_chip1_cluster0_core2_simd, {HOST_DW/8{1'b1}});
      local_task_drv_chip0.recv_b(resp_chip0);
    join_none
    #50;
    fork
      local_task_drv_chip0.send_aw(task_queue_base[0], '0);
      local_task_drv_chip0.send_w(dummy_set_chip0_cluster0_core2_simd_to_chip2_cluster0_core0_gemm, {HOST_DW/8{1'b1}});
      local_task_drv_chip0.recv_b(resp_chip0);
    join_none
    #50;
  end

  // Host pushes tasks for chiplet 1
  initial begin : chip1_push_sequence
    automatic axi_pkg::resp_t resp_chip1;
    wait (rst_ni);
    @(posedge clk_i);

    fork
      local_task_drv_chip1.send_aw(task_queue_base[1], '0);
      local_task_drv_chip1.send_w(chip1_cluster0_core2_simd, {HOST_DW/8{1'b1}});
      local_task_drv_chip1.recv_b(resp_chip1);
    join_none
    #50;
    fork
      local_task_drv_chip1.send_aw(task_queue_base[1], '0);
      local_task_drv_chip1.send_w(chip1_cluster1_core0_gemm, {HOST_DW/8{1'b1}});
      local_task_drv_chip1.recv_b(resp_chip1);
    join_none
    #50;
    fork
      local_task_drv_chip1.send_aw(task_queue_base[1], '0);
      local_task_drv_chip1.send_w(dummy_set_chip1_cluster0_core2_simd_0, {HOST_DW/8{1'b1}});
      local_task_drv_chip1.recv_b(resp_chip1);
    join_none
    #50;
    fork
      local_task_drv_chip1.send_aw(task_queue_base[1], '0);
      local_task_drv_chip1.send_w(chip1_cluster0_core1_dma, {HOST_DW/8{1'b1}});
      local_task_drv_chip1.recv_b(resp_chip1);
    join_none
    #50;
    fork
      local_task_drv_chip1.send_aw(task_queue_base[1], '0);
      local_task_drv_chip1.send_w(chip1_cluster0_core0_gemm, {HOST_DW/8{1'b1}});
      local_task_drv_chip1.recv_b(resp_chip1);
    join_none
    #50;
    fork
      local_task_drv_chip1.send_aw(task_queue_base[1], '0);
      local_task_drv_chip1.send_w(dummy_set_chip1_cluster0_core0_gemm_to_chip3_cluster0_core0_gemm_1, {HOST_DW/8{1'b1}});
      local_task_drv_chip1.recv_b(resp_chip1);
    join_none
    #50;
  end

  // Host pushes tasks for chiplet 2
  initial begin : chip2_push_sequence
    automatic axi_pkg::resp_t resp_chip2;
    wait (rst_ni);
    @(posedge clk_i);

    fork
      local_task_drv_chip2.send_aw(task_queue_base[2], '0);
      local_task_drv_chip2.send_w(chip2_cluster0_core0_gemm, {HOST_DW/8{1'b1}});
      local_task_drv_chip2.recv_b(resp_chip2);
    join_none
    #50;
    fork
      local_task_drv_chip2.send_aw(task_queue_base[2], '0);
      local_task_drv_chip2.send_w(chip2_cluster1_core1_dma, {HOST_DW/8{1'b1}});
      local_task_drv_chip2.recv_b(resp_chip2);
    join_none
    #50;
    fork
      local_task_drv_chip2.send_aw(task_queue_base[2], '0);
      local_task_drv_chip2.send_w(dummy_set_chip2_cluster0_core0_gemm_0, {HOST_DW/8{1'b1}});
      local_task_drv_chip2.recv_b(resp_chip2);
    join_none
    #50;
    fork
      local_task_drv_chip2.send_aw(task_queue_base[2], '0);
      local_task_drv_chip2.send_w(chip2_cluster0_core1_dma, {HOST_DW/8{1'b1}});
      local_task_drv_chip2.recv_b(resp_chip2);
    join_none
    #50;
    fork
      local_task_drv_chip2.send_aw(task_queue_base[2], '0);
      local_task_drv_chip2.send_w(dummy_check_chip2_cluster0_core0_gemm_2_1, {HOST_DW/8{1'b1}});
      local_task_drv_chip2.recv_b(resp_chip2);
    join_none
    #50;
    fork
      local_task_drv_chip2.send_aw(task_queue_base[2], '0);
      local_task_drv_chip2.send_w(chip2_cluster0_core0_gemm_2, {HOST_DW/8{1'b1}});
      local_task_drv_chip2.recv_b(resp_chip2);
    join_none
    #50;
    fork
      local_task_drv_chip2.send_aw(task_queue_base[2], '0);
      local_task_drv_chip2.send_w(dummy_set_chip2_cluster0_core0_gemm_2_to_chip3_cluster0_core0_gemm_1, {HOST_DW/8{1'b1}});
      local_task_drv_chip2.recv_b(resp_chip2);
    join_none
    #50;
  end

  // Host pushes tasks for chiplet 3
  initial begin : chip3_push_sequence
    automatic axi_pkg::resp_t resp_chip3;
    wait (rst_ni);
    @(posedge clk_i);

    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(dummy_check_chip3_cluster0_core0_gemm_1_0, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(chip3_cluster0_core0_gemm_1, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(chip3_cluster0_core0_gemm_2, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(dummy_set_chip3_cluster0_core0_gemm_1_0, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(dummy_set_chip3_cluster0_core0_gemm_1_1, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(chip3_cluster0_core1_dma, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(chip3_cluster1_core1_dma, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(dummy_check_chip3_cluster0_core0_gemm_3_1, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
    fork
      local_task_drv_chip3.send_aw(task_queue_base[3], '0);
      local_task_drv_chip3.send_w(chip3_cluster0_core0_gemm_3, {HOST_DW/8{1'b1}});
      local_task_drv_chip3.recv_b(resp_chip3);
    join_none
    #50;
  end



  task automatic chip0_cluster0_core0_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip0 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip0_cluster0_core0.send_ar(status_addr, '0);
      local_ready_drv_chip0_cluster0_core0.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip0_cluster0_core0.send_ar(data_addr, '0);
      local_ready_drv_chip0_cluster0_core0.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip0.send_aw(done_addr, '0);
      local_done_drv_chip0.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip0.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip0_cluster0_core1_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip0 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip0_cluster0_core1.send_ar(status_addr, '0);
      local_ready_drv_chip0_cluster0_core1.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip0_cluster0_core1.send_ar(data_addr, '0);
      local_ready_drv_chip0_cluster0_core1.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip0.send_aw(done_addr, '0);
      local_done_drv_chip0.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip0.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip0_cluster0_core2_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip0 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip0_cluster0_core2.send_ar(status_addr, '0);
      local_ready_drv_chip0_cluster0_core2.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip0_cluster0_core2.send_ar(data_addr, '0);
      local_ready_drv_chip0_cluster0_core2.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip0.send_aw(done_addr, '0);
      local_done_drv_chip0.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip0.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip0_cluster1_core0_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip0 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip0_cluster1_core0.send_ar(status_addr, '0);
      local_ready_drv_chip0_cluster1_core0.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip0_cluster1_core0.send_ar(data_addr, '0);
      local_ready_drv_chip0_cluster1_core0.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip0.send_aw(done_addr, '0);
      local_done_drv_chip0.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip0.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip0_cluster1_core1_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip0 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip0_cluster1_core1.send_ar(status_addr, '0);
      local_ready_drv_chip0_cluster1_core1.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip0_cluster1_core1.send_ar(data_addr, '0);
      local_ready_drv_chip0_cluster1_core1.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip0.send_aw(done_addr, '0);
      local_done_drv_chip0.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip0.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip0_cluster1_core2_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip0 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip0_cluster1_core2.send_ar(status_addr, '0);
      local_ready_drv_chip0_cluster1_core2.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip0_cluster1_core2.send_ar(data_addr, '0);
      local_ready_drv_chip0_cluster1_core2.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip0 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip0.send_aw(done_addr, '0);
      local_done_drv_chip0.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip0.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip1_cluster0_core0_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip1 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip1_cluster0_core0.send_ar(status_addr, '0);
      local_ready_drv_chip1_cluster0_core0.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip1_cluster0_core0.send_ar(data_addr, '0);
      local_ready_drv_chip1_cluster0_core0.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip1.send_aw(done_addr, '0);
      local_done_drv_chip1.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip1.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip1_cluster0_core1_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip1 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip1_cluster0_core1.send_ar(status_addr, '0);
      local_ready_drv_chip1_cluster0_core1.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip1_cluster0_core1.send_ar(data_addr, '0);
      local_ready_drv_chip1_cluster0_core1.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip1.send_aw(done_addr, '0);
      local_done_drv_chip1.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip1.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip1_cluster0_core2_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip1 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip1_cluster0_core2.send_ar(status_addr, '0);
      local_ready_drv_chip1_cluster0_core2.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip1_cluster0_core2.send_ar(data_addr, '0);
      local_ready_drv_chip1_cluster0_core2.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip1.send_aw(done_addr, '0);
      local_done_drv_chip1.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip1.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip1_cluster1_core0_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip1 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip1_cluster1_core0.send_ar(status_addr, '0);
      local_ready_drv_chip1_cluster1_core0.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip1_cluster1_core0.send_ar(data_addr, '0);
      local_ready_drv_chip1_cluster1_core0.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip1.send_aw(done_addr, '0);
      local_done_drv_chip1.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip1.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip1_cluster1_core1_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip1 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip1_cluster1_core1.send_ar(status_addr, '0);
      local_ready_drv_chip1_cluster1_core1.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip1_cluster1_core1.send_ar(data_addr, '0);
      local_ready_drv_chip1_cluster1_core1.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip1.send_aw(done_addr, '0);
      local_done_drv_chip1.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip1.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip1_cluster1_core2_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip1 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip1_cluster1_core2.send_ar(status_addr, '0);
      local_ready_drv_chip1_cluster1_core2.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip1_cluster1_core2.send_ar(data_addr, '0);
      local_ready_drv_chip1_cluster1_core2.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip1 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip1.send_aw(done_addr, '0);
      local_done_drv_chip1.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip1.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip2_cluster0_core0_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip2 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip2_cluster0_core0.send_ar(status_addr, '0);
      local_ready_drv_chip2_cluster0_core0.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip2_cluster0_core0.send_ar(data_addr, '0);
      local_ready_drv_chip2_cluster0_core0.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip2.send_aw(done_addr, '0);
      local_done_drv_chip2.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip2.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip2_cluster0_core1_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip2 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip2_cluster0_core1.send_ar(status_addr, '0);
      local_ready_drv_chip2_cluster0_core1.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip2_cluster0_core1.send_ar(data_addr, '0);
      local_ready_drv_chip2_cluster0_core1.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip2.send_aw(done_addr, '0);
      local_done_drv_chip2.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip2.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip2_cluster0_core2_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip2 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip2_cluster0_core2.send_ar(status_addr, '0);
      local_ready_drv_chip2_cluster0_core2.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip2_cluster0_core2.send_ar(data_addr, '0);
      local_ready_drv_chip2_cluster0_core2.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip2.send_aw(done_addr, '0);
      local_done_drv_chip2.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip2.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip2_cluster1_core0_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip2 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip2_cluster1_core0.send_ar(status_addr, '0);
      local_ready_drv_chip2_cluster1_core0.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip2_cluster1_core0.send_ar(data_addr, '0);
      local_ready_drv_chip2_cluster1_core0.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip2.send_aw(done_addr, '0);
      local_done_drv_chip2.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip2.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip2_cluster1_core1_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip2 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip2_cluster1_core1.send_ar(status_addr, '0);
      local_ready_drv_chip2_cluster1_core1.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip2_cluster1_core1.send_ar(data_addr, '0);
      local_ready_drv_chip2_cluster1_core1.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip2.send_aw(done_addr, '0);
      local_done_drv_chip2.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip2.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip2_cluster1_core2_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip2 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip2_cluster1_core2.send_ar(status_addr, '0);
      local_ready_drv_chip2_cluster1_core2.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip2_cluster1_core2.send_ar(data_addr, '0);
      local_ready_drv_chip2_cluster1_core2.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip2 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip2.send_aw(done_addr, '0);
      local_done_drv_chip2.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip2.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip3_cluster0_core0_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip3 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip3_cluster0_core0.send_ar(status_addr, '0);
      local_ready_drv_chip3_cluster0_core0.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip3_cluster0_core0.send_ar(data_addr, '0);
      local_ready_drv_chip3_cluster0_core0.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip3.send_aw(done_addr, '0);
      local_done_drv_chip3.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip3.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip3_cluster0_core1_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip3 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip3_cluster0_core1.send_ar(status_addr, '0);
      local_ready_drv_chip3_cluster0_core1.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip3_cluster0_core1.send_ar(data_addr, '0);
      local_ready_drv_chip3_cluster0_core1.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip3.send_aw(done_addr, '0);
      local_done_drv_chip3.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip3.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip3_cluster0_core2_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip3 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip3_cluster0_core2.send_ar(status_addr, '0);
      local_ready_drv_chip3_cluster0_core2.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip3_cluster0_core2.send_ar(data_addr, '0);
      local_ready_drv_chip3_cluster0_core2.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip3.send_aw(done_addr, '0);
      local_done_drv_chip3.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip3.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip3_cluster1_core0_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip3 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip3_cluster1_core0.send_ar(status_addr, '0);
      local_ready_drv_chip3_cluster1_core0.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip3_cluster1_core0.send_ar(data_addr, '0);
      local_ready_drv_chip3_cluster1_core0.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip3.send_aw(done_addr, '0);
      local_done_drv_chip3.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip3.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip3_cluster1_core1_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip3 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip3_cluster1_core1.send_ar(status_addr, '0);
      local_ready_drv_chip3_cluster1_core1.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip3_cluster1_core1.send_ar(data_addr, '0);
      local_ready_drv_chip3_cluster1_core1.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip3.send_aw(done_addr, '0);
      local_done_drv_chip3.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip3.recv_b(resp);
      join_none
    end
  endtask

  task automatic chip3_cluster1_core2_ready_queue_worker(input chip_id_t chip,
                                         input int cluster,
                                         input int core);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    device_axi_lite_addr_t         done_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;
    int idx = core + cluster * NUM_CORES_PER_CLUSTER;
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t Chip3 READY[Core%0d,Cluster%0d] worker started, idx %0d", $time, core, cluster, idx);
    forever begin
      fork 
      local_ready_drv_chip3_cluster1_core2.send_ar(status_addr, '0);
      local_ready_drv_chip3_cluster1_core2.recv_r(status, resp);
      join_none
      repeat (5) @(posedge clk_i);
      // Check the status
      // If no task is ready, retry after some time
      if (status[0]) begin
        repeat (10) @(posedge clk_i);
        continue;
      end
      // Here the core sees a task is ready
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] Reading Ready Queue...", $time, core, cluster);
      // Read the task id
      fork
      local_ready_drv_chip3_cluster1_core2.send_ar(data_addr, '0);
      local_ready_drv_chip3_cluster1_core2.recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip3 READY[Core%0d,Cluster%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      local_done_drv_chip3.send_aw(done_addr, '0);
      local_done_drv_chip3.send_w(done_payload, {DEV_DW/8{1'b1}});
      local_done_drv_chip3.recv_b(resp);
      join_none
    end
  endtask

initial begin : ready_queue_pollers
    wait (rst_ni);
    repeat (5) @(posedge clk_i);
    fork
      chip0_cluster0_core0_ready_queue_worker(0, 0, 0);
      chip0_cluster0_core1_ready_queue_worker(0, 0, 1);
      chip0_cluster0_core2_ready_queue_worker(0, 0, 2);
      chip0_cluster1_core0_ready_queue_worker(0, 1, 0);
      chip0_cluster1_core1_ready_queue_worker(0, 1, 1);
      chip0_cluster1_core2_ready_queue_worker(0, 1, 2);
      chip1_cluster0_core0_ready_queue_worker(1, 0, 0);
      chip1_cluster0_core1_ready_queue_worker(1, 0, 1);
      chip1_cluster0_core2_ready_queue_worker(1, 0, 2);
      chip1_cluster1_core0_ready_queue_worker(1, 1, 0);
      chip1_cluster1_core1_ready_queue_worker(1, 1, 1);
      chip1_cluster1_core2_ready_queue_worker(1, 1, 2);
      chip2_cluster0_core0_ready_queue_worker(2, 0, 0);
      chip2_cluster0_core1_ready_queue_worker(2, 0, 1);
      chip2_cluster0_core2_ready_queue_worker(2, 0, 2);
      chip2_cluster1_core0_ready_queue_worker(2, 1, 0);
      chip2_cluster1_core1_ready_queue_worker(2, 1, 1);
      chip2_cluster1_core2_ready_queue_worker(2, 1, 2);
      chip3_cluster0_core0_ready_queue_worker(3, 0, 0);
      chip3_cluster0_core1_ready_queue_worker(3, 0, 1);
      chip3_cluster0_core2_ready_queue_worker(3, 0, 2);
      chip3_cluster1_core0_ready_queue_worker(3, 1, 0);
      chip3_cluster1_core1_ready_queue_worker(3, 1, 1);
      chip3_cluster1_core2_ready_queue_worker(3, 1, 2);
    join_none
  end


  // Timeout
  initial begin
    #5000;
    $fatal(1, "Timeout");
  end

endmodule