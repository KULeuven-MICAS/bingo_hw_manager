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
    localparam host_axi_lite_addr_t TASK_QUEUE_BASE  = 48'h1000_0000;
    localparam host_axi_lite_addr_t DONE_QUEUE_BASE  = 48'h2000_0000;
    localparam host_axi_lite_addr_t READY_QUEUE_BASE = 48'h3000_0000;
    localparam host_axi_lite_addr_t READY_QUEUE_STRIDE = 48'h1000; // 4 KiB
    localparam host_axi_lite_addr_t H2H_DONE_QUEUE_BASE = 48'h4000_0000;

    localparam int unsigned TaskIdWidth = 16;
    // Task Type
    // 00: Normal Task
    // 01: Dummy Task to ensure local dep management
    // 10：Chiplet Dep Check Task
    // 11: Chiplet Dep Set Task
    typedef logic [1:0                                 ] bingo_hw_manager_task_type_t;
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
        logic                                        dep_check_en;
        bingo_hw_manager_dep_code_t                  dep_check_code;
    } bingo_hw_manager_dep_check_info_t;
    // Dependency set info struct
    typedef struct packed{
        logic                                        dep_set_en;
        bingo_hw_manager_dep_code_t                  dep_set_code;
        bingo_hw_manager_assigned_cluster_id_t       dep_set_cluster_id;
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
    localparam int unsigned ReservedBitsForTaskDesc = HostAxiLiteDataWidth - TaskDescWidth;
    if (TaskDescWidth>HostAxiLiteDataWidth) begin : gen_task_desc_width_check
        initial begin
        $error("Task Decriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", TaskDescWidth, HostAxiLiteDataWidth);
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

    // Dep Set Type
    typedef struct packed{
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id_3;
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id_2;
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id_1;
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id_0;
        logic [2:0]                                  num_dep;
        logic                                        dep_set_all;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
    } bingo_hw_manager_chiplet_dep_set_task_desc_t;

    localparam int unsigned ChipletSetTaskDescWidth = $bits(bingo_hw_manager_chiplet_dep_set_task_desc_t);
    localparam int unsigned ReservedBitsForChipletSetTaskDesc = HostAxiLiteDataWidth - ChipletSetTaskDescWidth;
    if (ChipletSetTaskDescWidth>HostAxiLiteDataWidth) begin : gen_task_desc_width_check
        initial begin
        $error("Chiplet Set Task Descriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", ChipletSetTaskDescWidth, HostAxiLiteDataWidth);
        $finish;
        end
    end
    // 64bit Chiplet Set Task Descriptor with reserved bits
    typedef struct packed{
        logic [ReservedBitsForChipletSetTaskDesc-1:0]   reserved_bits;
        bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_3;
        bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_2;
        bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_1;
        bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_0;
        logic [2:0]                                     num_dep;
        logic                                           dep_set_all;
        bingo_hw_manager_assigned_chiplet_id_t          assigned_chiplet_id;
        bingo_hw_manager_task_id_t                      task_id;
        bingo_hw_manager_task_type_t                    task_type;
    } bingo_hw_manager_chiplet_dep_set_task_desc_full_t;

    // Dep Check Type
    typedef struct packed{
        bingo_hw_manager_assigned_chiplet_id_t       dep_check_sum;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
    } bingo_hw_manager_chiplet_dep_check_task_desc_t;    
    localparam int unsigned ChipletCheckTaskDescWidth = $bits(bingo_hw_manager_chiplet_dep_check_task_desc_t);
    localparam int unsigned ReservedBitsForChipletCheckTaskDesc = HostAxiLiteDataWidth - ChipletCheckTaskDescWidth;
    if (ChipletCheckTaskDescWidth>HostAxiLiteDataWidth) begin : gen_task_desc_width_check
        initial begin
        $error("Chiplet Check Task Descriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", ChipletCheckTaskDescWidth, HostAxiLiteDataWidth);
        $finish;
        end
    end
    //64bit Chiplet Check Task Descriptor with reserved bits
    typedef struct packed{
        logic [ReservedBitsForChipletCheckTaskDesc-1:0]   reserved_bits;
        bingo_hw_manager_assigned_chiplet_id_t       dep_check_sum;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
    } bingo_hw_manager_chiplet_dep_check_task_desc_full_t;        

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
  ) local_task_if [NUM_CHIPLET-1:0](.clk_i(clk_i));

  // AXI-Lite virtual interfaces for local done queue
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_done_if [NUM_CHIPLET-1:0](.clk_i(clk_i));


  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if [NUM_CHIPLET-1:0][READY_AGENT_NUM-1:0] (.clk_i(clk_i));

  // Local Task Queue interface
  host_req_t  [NUM_CHIPLET-1:0] local_task_queue_req;
  host_resp_t [NUM_CHIPLET-1:0] local_task_queue_resp;
  // Connect the wires to if
  for (genvar chip_idx=0; chip_idx<NUM_CHIPLET; chip_idx++) begin : gen_task_queue_if_connect
    `AXI_LITE_ASSIGN_TO_REQ  (local_task_queue_req[chip_idx] , local_task_if[chip_idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(local_task_if[chip_idx] , local_task_queue_resp[chip_idx]);
  end

  // Local Done Queue interface
  dev_req_t  [NUM_CHIPLET-1:0] local_done_queue_req;
  dev_resp_t [NUM_CHIPLET-1:0] local_done_queue_resp;
  // Connect the wires to if
  for (genvar chip_idx=0; chip_idx<NUM_CHIPLET; chip_idx++) begin : gen_done_queue_if_connect
    `AXI_LITE_ASSIGN_TO_REQ  (local_done_queue_req[chip_idx] , local_done_if[chip_idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(local_done_if[chip_idx] , local_done_queue_resp[chip_idx]);
  end

  // Local Ready Queue interface
  dev_req_t  [NUM_CHIPLET-1:0][READY_AGENT_NUM-1:0] local_ready_queue_req ;
  dev_resp_t [NUM_CHIPLET-1:0][READY_AGENT_NUM-1:0] local_ready_queue_resp;
  // Connect the wires to if
  for (genvar chip_idx=0; chip_idx<NUM_CHIPLET; chip_idx++) begin : gen_ready_queue_if_connect_chiplet
    for (genvar agent_idx=0; agent_idx<READY_AGENT_NUM; agent_idx++) begin : gen_ready_queue_if_connect_agent
      `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req[chip_idx][agent_idx] , local_ready_if[chip_idx][agent_idx]);
      `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if[chip_idx][agent_idx] , local_ready_queue_resp[chip_idx][agent_idx]);
    end
  end



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
  ) local_task_drv [NUM_CHIPLET-1:0];
  for (genvar chip_id = 0; chip_id < NUM_CHIPLET; chip_id++) begin : gen_local_task_drv
    initial begin 
      local_task_drv[chip_id] = new(local_task_if[chip_id]);
      local_task_drv[chip_id].reset_master();
    end
  end

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_done_drv [NUM_CHIPLET-1:0];
  for (genvar chip_id = 0; chip_id < NUM_CHIPLET; chip_id++) begin : gen_local_done_drv
    initial begin 
      local_done_drv[chip_id] = new(local_done_if[chip_id]);
      local_done_drv[chip_id].reset_master();
    end
  end

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) local_ready_drv [NUM_CHIPLET-1:0][READY_AGENT_NUM-1:0];
  for (genvar chip_id = 0; chip_id < NUM_CHIPLET; chip_id++) begin : gen_local_ready_drv_chiplet
    for (genvar agent_id = 0; agent_id < READY_AGENT_NUM; agent_id++) begin : gen_local_ready_drv_agent
      initial begin 
        local_ready_drv[chip_id][agent_id] = new(local_ready_if[chip_id][agent_id]);
        local_ready_drv[chip_id][agent_id].reset_master();
      end
    end
  end


  for (genvar chip_id = 0; chip_id < NUM_CHIPLET; chip_id++) begin: gen_dut
    // We do not need the address translation here since we directly inject the signals via the drivers
    // The H2H mailbox base address will be handled inside the DUT
    // Flatten ready-queue base addresses into 2-D packed array for DUT
    device_axi_lite_addr_t [READY_AGENT_NUM-1:0] ready_base_addr_bus;
    device_axi_lite_addr_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_base_addr_2d;
    for (int idx = 0; idx < READY_AGENT_NUM; idx++) begin
      ready_base_addr_bus[idx] = READY_QUEUE_BASE + device_axi_lite_addr_t'( idx * READY_QUEUE_STRIDE );
    end

    for (int idx = 0; idx < NUM_CORES_PER_CLUSTER; idx++) begin
      for (int jdx = 0; jdx < NUM_CLUSTERS_PER_CHIPLET; jdx++) begin
        ready_base_addr_2d[idx][jdx] = READY_QUEUE_BASE + device_axi_lite_addr_t'( (idx * NUM_CLUSTERS_PER_CHIPLET + jdx) * READY_QUEUE_STRIDE );
      end
    end
    bingo_hw_manager_top #(
      .NUM_CHIPLET              (NUM_CHIPLET              ),
      .NUM_CORES_PER_CLUSTER    (NUM_CORES_PER_CLUSTER    ),
      .NUM_CLUSTERS_PER_CHIPLET (NUM_CLUSTERS_PER_CHIPLET ),
      .HostAxiLiteAddrWidth     (HOST_AW                  ),
      .HostAxiLiteDataWidth     (HOST_DW                  ),
      .DeviceAxiLiteAddrWidth   (DEV_AW                   ),
      .DeviceAxiLiteDataWidth   (DEV_DW                   ),
      .task_queue_axi_lite_in_req_t     (host_req_t ),
      .task_queue_axi_lite_in_resp_t    (host_resp_t),
      .h2h_axi_lite_out_req_t           (host_req_t ),
      .h2h_axi_lite_out_resp_t          (host_resp_t),
      .h2h_axi_lite_in_req_t            (host_req_t ),
      .h2h_axi_lite_in_resp_t           (host_resp_t),
      .done_queue_axi_lite_in_req_t     (dev_req_t  ),
      .done_queue_axi_lite_in_resp_t    (dev_resp_t ),
      .ready_queue_axi_lite_in_req_t    (dev_req_t  ),
      .ready_queue_axi_lite_in_resp_t   (dev_resp_t )
    ) dut (
      .clk_i                          (clk_i               ),
      .rst_ni                         (rst_ni              ),
      .chip_id_i                      ('0                  ),
      .task_queue_base_addr_i         (TASK_QUEUE_BASE     ),
      .task_queue_axi_lite_req_i      (local_task_queue_req[chip_id]      ),
      .task_queue_axi_lite_resp_o     (local_task_queue_resp[chip_id]     ),
      .h2h_mailbox_base_addr_i        (H2H_DONE_QUEUE_BASE                ),
      .h2h_to_remote_axi_lite_req_o   (h2h_axi_lite_xbar_in_req[chip_id]  ),
      .h2h_to_remote_axi_lite_resp_i  (h2h_axi_lite_xbar_in_resp[chip_id] ),
      .h2h_from_remote_axi_lite_req_i (h2h_axi_lite_xbar_out_req[chip_id] ),
      .h2h_from_remote_axi_lite_resp_o(h2h_axi_lite_xbar_out_resp[chip_id]),
      .done_queue_base_addr_i         (DONE_QUEUE_BASE                    ),
      .done_queue_axi_lite_req_i      (local_done_queue_req[chip_id]      ),
      .done_queue_axi_lite_resp_o     (local_done_queue_resp[chip_id]     ),
      .ready_queue_base_addr_i        (ready_base_addr_2d                 ),
      .ready_queue_axi_lite_req_i     (local_ready_queue_req[chip_id]     ),
      .ready_queue_axi_lite_resp_o    (local_ready_queue_resp[chip_id]    )
    );    
  end

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
    input bingo_hw_manager_dep_code_t            dep_set_code,
    input bingo_hw_manager_assigned_cluster_id_t dep_set_cluster_id
  );
    assert(task_type==2'b00);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
    tmp.assigned_core_id                 = assigned_core_id;
    tmp.dep_check_info.dep_check_en      = dep_check_en;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.dep_set_info.dep_set_cluster_id  = dep_set_cluster_id;
    tmp.reserved_bits                    = '0;
    return tmp;
  endfunction


  function automatic bingo_hw_manager_task_desc_full_t pack_dummy_check_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input logic                                  dep_check_en,
    input bingo_hw_manager_dep_code_t            dep_check_code  
  );
    assert(task_type==2'b01 && dep_check_en==1'b1);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = '1;
    tmp.assigned_core_id                 = '1;
    tmp.dep_check_info.dep_check_en      = 1'b1;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_set_info                     = '0;
    tmp.reserved_bits                    = '0;
  endfunction

  function automatic bingo_hw_manager_task_desc_full_t pack_dummy_set_task(
    input bingo_hw_manager_task_type_t           task_type,
    input bingo_hw_manager_task_id_t             task_id,
    input bingo_hw_manager_assigned_chiplet_id_t assigned_chiplet_id,
    input logic                                  dep_set_en,
    input bingo_hw_manager_dep_code_t            dep_set_code,
    input bingo_hw_manager_assigned_cluster_id_t dep_set_cluster_id
  );
    assert(task_type==2'b01 && dep_set_en==1'b1);
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.dep_check_info                   = '0;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.dep_set_info.dep_set_cluster_id  = dep_set_cluster_id;
    tmp.reserved_bits                    = '0;
    return tmp;
  endfunction

  function automatic bingo_hw_manager_chiplet_dep_set_task_desc_full_t pack_chiplet_dep_set_task(
    input bingo_hw_manager_task_type_t                    task_type,
    input bingo_hw_manager_task_id_t                      task_id,
    input bingo_hw_manager_assigned_chiplet_id_t          assigned_chiplet_id,
    input logic                                           dep_set_all,
    input logic [2:0]                                     num_dep,
    input bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_3,
    input bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_2,
    input bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_1,
    input bingo_hw_manager_assigned_chiplet_id_t          dep_set_chiplet_id_0
  );
    assert(task_type==2'b10);
    bingo_hw_manager_chiplet_dep_set_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.dep_set_all                      = dep_set_all;
    tmp.num_dep                          = num_dep;
    tmp.dep_set_chiplet_id_0             = dep_set_chiplet_id_0;
    tmp.dep_set_chiplet_id_1             = dep_set_chiplet_id_1;
    tmp.dep_set_chiplet_id_2             = dep_set_chiplet_id_2;
    tmp.dep_set_chiplet_id_3             = dep_set_chiplet_id_3;
    tmp.reserved_bits                    = '0;
    return tmp;
  endfunction

  function automatic bingo_hw_manager_chiplet_dep_check_task_desc_full_t pack_chiplet_dep_check_task(
    input bingo_hw_manager_task_type_t                    task_type,
    input bingo_hw_manager_task_id_t                      task_id,
    input bingo_hw_manager_assigned_chiplet_id_t          assigned_chiplet_id,
    input bingo_hw_manager_assigned_chiplet_id_t          dep_check_sum
  );
    assert(task_type==2'b11);
    bingo_hw_manager_chiplet_dep_check_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.dep_check_sum                    = dep_check_sum;
    tmp.reserved_bits                    = '0;
    return tmp;
  endfunction

  // ---------------------------------------------------------------------------
  // Stimulus threads
  // ---------------------------------------------------------------------------

  // Host pushes three tasks after reset
  initial begin : host_sequence
    automatic bingo_hw_manager_task_desc_full_t task0;
    automatic bingo_hw_manager_task_desc_full_t task1;
    automatic bingo_hw_manager_task_desc_full_t task2;
    automatic axi_pkg::resp_t resp; // Declare all variables at the top

    host_drv.reset_master();
    wait (rst_ni);
    @(posedge clk_i);

    // Define tasks
    task0 = pack_task( 16'd1,      // task id
                       2'd0,      // core sel
                       1'b0,    // is dummy
                       1'b0,    // dep check en
                       3'b000,      // dep check code
                       1'd0,      // dep check cluster idx
                       1'b0,    // dep check chiplet_en
                       4'd0,    // dep check chiplet_code
                       1'b1,    // dep set en
                       3'b010, // dep set code (set core 1)
                       1'd0       // dep set cluster idx
                     );
    task1 = pack_task( 16'd2,      // task id
                       2'd1,      // core sel
                       1'b0,    // is dummy
                       1'b1,    // dep check en
                       3'b001, // dep check code (wait for core 0)
                       1'd0,      // dep check cluster idx (cluster 0)
                       1'b0,    // dep check chiplet_en
                       4'd0,    // dep check chiplet_code
                       1'b1,    // dep set en
                       3'b100,   // dep set code (set core 2)
                       1'd1       // dep set cluster idx (cluster 1)
                     );
    task2 = pack_task( 16'd3,   // task id
                       2'd2,    // core sel
                       1'b0,    // is dummy
                       1'b1,    // dep check en
                       3'b010,  // dep check code (wait for core 1)
                       '0,      // dep check cluster idx (cluster 0)
                       1'b0,    // dep check chiplet_en
                       4'd0,    // dep check chiplet_code
                       1'b0,    // dep set en
                       '0,      // dep set code
                       '0       // dep set cluster idx
                     );

    // Send tasks
    fork
      host_drv.send_aw(TASK_QUEUE_BASE, '0);
      host_drv.send_w(task0, {HOST_DW/8{1'b1}});
      host_drv.recv_b(resp);
    join_none

    #50;
    fork
    host_drv.send_aw(TASK_QUEUE_BASE, '0);
    host_drv.send_w(task1, {HOST_DW/8{1'b1}});
    host_drv.recv_b(resp);
    join_none
    #50;

    fork
    host_drv.send_aw(TASK_QUEUE_BASE, '0);
    host_drv.send_w(task2, {HOST_DW/8{1'b1}});
    host_drv.recv_b(resp);
    join_none
  end

  task automatic ready_queue_worker(input int idx,
                                    input int core,
                                    input int cluster);
    axi_pkg::resp_t                resp;
    device_axi_lite_data_t         data;
    device_axi_lite_addr_t         data_addr;
    device_axi_lite_data_t         status;
    device_axi_lite_addr_t         status_addr;
    bingo_hw_manager_done_info_full_t done_info;
    device_axi_lite_data_t         done_payload;

    data_addr   = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd4;
    status_addr = READY_QUEUE_BASE + device_axi_lite_addr_t'(idx * READY_QUEUE_STRIDE) + 32'd8;

    $display("%0t READY[%0d,%0d] worker started, idx %0d", $time, core, cluster, idx);

    forever begin
      $display("%0t READY[%0d,%0d] polling for new task...", $time, core, cluster);
      fork 
      ready_drv[idx].send_ar(status_addr, '0);
      ready_drv[idx].recv_r(status, resp);
      join_none
      $display("%0t READY[%0d,%0d] status: 0x%0h", $time, core, cluster, status);
      repeat (5) @(posedge clk_i);
      if (status[0]) begin
        $display("%0t READY[%0d,%0d] no task available, retrying...", $time, core, cluster);
        repeat (10) @(posedge clk_i);
        continue;
      end
      $display("%0t READY[%0d,%0d] task available, reading...", $time, core, cluster);
      fork
      ready_drv[idx].send_ar(data_addr, '0);
      ready_drv[idx].recv_r(data, resp);
      join_none
      repeat (5) @(posedge clk_i);
      $display("%0t READY[%0d,%0d] recvs task_id %0d",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      $display("%0t READY[%0d,%0d] doing some work....",
              $time, core, cluster);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t READY[%0d,%0d] done with task_id %0d, sending done info back",
              $time, core, cluster, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.cluster_id  = bingo_hw_manager_cluster_id_t'(cluster);
      done_info.core_id     = bingo_hw_manager_task_type_t'(core);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      fork
      done_drv.send_aw(DONE_QUEUE_BASE, '0);
      done_drv.send_w(done_payload, {DEV_DW/8{1'b1}});
      done_drv.recv_b(resp);
      join_none
    end
  endtask

  initial begin : ready_queue_pollers
    wait (rst_ni);
    for (int core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
      for (int cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
        automatic int core_i    = core_idx;
        automatic int cluster_i = cluster_idx;
        automatic int idx       = core_i * NUM_CLUSTERS_PER_CHIPLET + cluster_i;
        fork
          ready_queue_worker(idx, core_i, cluster_i);
        join_none
      end
    end
  end

  // Timeout
  initial begin
    #2000;
    $fatal(1, "Timeout");
  end

endmodule