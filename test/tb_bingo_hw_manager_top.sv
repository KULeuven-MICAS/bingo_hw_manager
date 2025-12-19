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
    localparam time CyclTime = 10ns;
    localparam time ApplTime =  2ns;
    localparam time TestTime =  8ns;
    // ---------------------------------------------------------------------------
    // Local configuration
    // ---------------------------------------------------------------------------
    localparam int unsigned READY_AND_DONE_QUEUE_INTERFACE_TYPE = 0; // 1: AXI Lite 0: CSR Req/Resp
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

    // CSR TYPEs
    typedef struct packed {
      device_axi_lite_addr_t   addr;
      device_axi_lite_data_t   data;
      logic                    write;
    } csr_req_t;
    typedef struct packed {
      device_axi_lite_data_t   data;
    } csr_rsp_t;
    function automatic int flat_id(
      input int     chip_id,
      input int  cluster_id,
      input int     core_id
    );
      return chip_id * NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER +
             cluster_id * NUM_CORES_PER_CLUSTER +
             core_id;
  endfunction
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
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
    input bingo_hw_manager_assigned_core_id_t    assigned_core_id,
    input logic                                  dep_check_en,
    input bingo_hw_manager_dep_code_t            dep_check_code  
  );
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_type                        = task_type;
    tmp.task_id                          = task_id;
    tmp.assigned_chiplet_id              = assigned_chiplet_id;
    tmp.assigned_cluster_id              = assigned_cluster_id;
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
    input bingo_hw_manager_assigned_cluster_id_t assigned_cluster_id,
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
    tmp.assigned_cluster_id              = assigned_cluster_id;
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
  clk_rst_gen #(
      .ClkPeriod    ( CyclTime ),
      .RstClkCycles ( 5        )
  ) i_clk_gen (
      .clk_o (clk_i),
      .rst_no(rst_ni)
  );

  // ---------------------------------------------------------------------------
  // AXI-Lite type aliases (from axi/typedef.svh)
  // ---------------------------------------------------------------------------
  `AXI_LITE_TYPEDEF_ALL(host, host_axi_lite_addr_t, host_axi_lite_data_t, host_axi_lite_strb_t)
  `AXI_LITE_TYPEDEF_ALL(dev , device_axi_lite_addr_t, device_axi_lite_data_t, device_axi_lite_strb_t)

  // AXI-Lite virtual interfaces for local task queue
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW),
                .AXI_DATA_WIDTH(HOST_DW)
  ) local_task_if [NUM_CHIPLET-1:0](.clk_i(clk_i));

  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_done_if [NUM_CHIPLET-1:0](.clk_i(clk_i));

  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) local_ready_if [NUM_CHIPLET*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER-1:0](.clk_i(clk_i));


  // AXI-Lite virtual interfaces for local ready queue
  // Chip0
  // Local Task Queue interface
  host_req_t  [NUM_CHIPLET-1:0] local_task_queue_req;
  host_resp_t [NUM_CHIPLET-1:0] local_task_queue_resp;
  // Connect the wires to if
  for(genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    `AXI_LITE_ASSIGN_TO_REQ  (local_task_queue_req[chiplet_idx] , local_task_if[chiplet_idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(local_task_if[chiplet_idx] , local_task_queue_resp[chiplet_idx]); 
  end

  // Local Done Queue interface
  dev_req_t  [NUM_CHIPLET-1:0] local_done_queue_req;
  dev_resp_t [NUM_CHIPLET-1:0] local_done_queue_resp;
  // Connect the wires to if
  for(genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    `AXI_LITE_ASSIGN_TO_REQ  (local_done_queue_req[chiplet_idx] , local_done_if[chiplet_idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(local_done_if[chiplet_idx] , local_done_queue_resp[chiplet_idx]);
  end
  // Local Ready Queue interface
  dev_req_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_req [NUM_CHIPLET];
  dev_resp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] local_ready_queue_resp [NUM_CHIPLET];
  // Connect the wires to if

  for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin
    for(genvar cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
      for(genvar core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
        `AXI_LITE_ASSIGN_TO_REQ  (local_ready_queue_req[chiplet_idx][core_idx][cluster_idx] , local_ready_if[flat_id(chiplet_idx, cluster_idx, core_idx)] );
        `AXI_LITE_ASSIGN_FROM_RESP(local_ready_if[flat_id(chiplet_idx, cluster_idx, core_idx)] , local_ready_queue_resp[chiplet_idx][core_idx][cluster_idx]);
      end
    end
  end


  // CSR Interfaces
  csr_req_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req [NUM_CHIPLET];
  logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req_valid [NUM_CHIPLET];
  logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_req_ready [NUM_CHIPLET];
  csr_rsp_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp [NUM_CHIPLET];
  logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp_valid [NUM_CHIPLET];
  logic     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] csr_resp_ready [NUM_CHIPLET];
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

  typedef axi_test::axi_lite_rand_master #(
    // AXI interface parameters
    .AW ( HOST_AW       ),
    .DW ( HOST_DW       ),
    // Stimuli application and test time
    .TA ( ApplTime       ),
    .TT ( TestTime       ),
    .MIN_ADDR ( 48'h0 ),
    .MAX_ADDR ( {8'h3,40'h8000_0000} ),
    .MAX_READ_TXNS  ( 10 ),
    .MAX_WRITE_TXNS ( 10 )
  ) host_rand_lite_master_t;

  typedef axi_test::axi_lite_rand_master #(
    // AXI interface parameters
    .AW ( DEV_AW       ),
    .DW ( DEV_DW       ),
    // Stimuli application and test time
    .TA ( ApplTime       ),
    .TT ( TestTime       ),
    .MIN_ADDR ( 48'h0 ),
    .MAX_ADDR ( {8'h3,40'h8000_0000} ),
    .MAX_READ_TXNS  ( 10 ),
    .MAX_WRITE_TXNS ( 10 )
  ) dev_rand_lite_master_t;


  host_rand_lite_master_t task_queue_master [NUM_CHIPLET];
  for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin: gen_task_queue_master
    initial begin
      automatic string task_queue_name = $sformatf("task_queue_master_chiplet%0d", chiplet_idx);
      task_queue_master[chiplet_idx] = new(local_task_if[chiplet_idx], task_queue_name);
      task_queue_master[chiplet_idx].reset();
    end
  end


  dev_rand_lite_master_t done_queue_master [NUM_CHIPLET];
  for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin: gen_done_queue_master
    initial begin
      automatic string done_queue_name = $sformatf("done_queue_master_chiplet%0d", chiplet_idx);
      done_queue_master[chiplet_idx] = new(local_done_if[chiplet_idx], done_queue_name);
      done_queue_master[chiplet_idx].reset();
    end
  end

  dev_rand_lite_master_t ready_queue_master [NUM_CHIPLET*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER];

  for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_ready_queue_master
    for (genvar cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
      for (genvar core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
        initial begin
          automatic string ready_queue_name = $sformatf("ready_queue_master_chiplet%0d_cluster%0d_core%0d", chiplet_idx, cluster_idx, core_idx);
          ready_queue_master[chiplet_idx*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER + cluster_idx*NUM_CORES_PER_CLUSTER + core_idx] = new(local_ready_if[chiplet_idx*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER + cluster_idx*NUM_CORES_PER_CLUSTER + core_idx], ready_queue_name);
          ready_queue_master[chiplet_idx*NUM_CLUSTERS_PER_CHIPLET*NUM_CORES_PER_CLUSTER + cluster_idx*NUM_CORES_PER_CLUSTER + core_idx].reset();
        end
      end
    end
  end

  chip_id_t [NUM_CHIPLET-1:0] chip_id;
  assign chip_id[0] = 8'h0;
  assign chip_id[1] = 8'h1;
  assign chip_id[2] = 8'h2;
  assign chip_id[3] = 8'h3;

  for (genvar chiplet_idx = 0; chiplet_idx < NUM_CHIPLET; chiplet_idx++) begin : gen_dut
    bingo_hw_manager_top #(
      .READY_AND_DONE_QUEUE_INTERFACE_TYPE(READY_AND_DONE_QUEUE_INTERFACE_TYPE),
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
      .device_axi_lite_resp_t   (dev_resp_t               ),
      .csr_req_t                (csr_req_t                ),
      .csr_rsp_t                (csr_rsp_t                )
    ) i_dut (
      .clk_i                              (clk_i                                                     ),
      .rst_ni                             (rst_ni                                                    ),
      .chip_id_i                          (chip_id[chiplet_idx]                                                ),
      .task_queue_base_addr_i             ({chip_id[chiplet_idx],TASK_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
      .task_queue_axi_lite_req_i          (local_task_queue_req[chiplet_idx]                                   ),
      .task_queue_axi_lite_resp_o         (local_task_queue_resp[chiplet_idx]                                  ),
      .chiplet_mailbox_base_addr_i        ({chip_id[chiplet_idx],H2H_DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]} ),
      .to_remote_chiplet_axi_lite_req_o   (h2h_axi_lite_xbar_in_req[chiplet_idx]                               ),
      .to_remote_chiplet_axi_lite_resp_i  (h2h_axi_lite_xbar_in_resp[chiplet_idx]                              ),
      .from_remote_axi_lite_req_i         (h2h_axi_lite_xbar_out_req[chiplet_idx]                              ),
      .from_remote_axi_lite_resp_o        (h2h_axi_lite_xbar_out_resp[chiplet_idx]                             ),
      .done_queue_base_addr_i             ({chip_id[chiplet_idx],DONE_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}     ),
      .done_queue_axi_lite_req_i          (local_done_queue_req[chiplet_idx]                                   ),
      .done_queue_axi_lite_resp_o         (local_done_queue_resp[chiplet_idx]                                  ),
      .ready_queue_base_addr_i            ({chip_id[chiplet_idx],READY_QUEUE_BASE[HOST_AW-ChipIdWidth-1:0]}    ),
      .ready_queue_axi_lite_req_i         (local_ready_queue_req[chiplet_idx]                                  ),
      .ready_queue_axi_lite_resp_o        (local_ready_queue_resp[chiplet_idx]                                 ),
      .csr_req_i                          (csr_req[chiplet_idx]                                                ),
      .csr_req_valid_i                    (csr_req_valid[chiplet_idx]                                          ),
      .csr_req_ready_o                    (csr_req_ready[chiplet_idx]                                          ),
      .csr_rsp_o                          (csr_resp[chiplet_idx]                                               ),
      .csr_rsp_valid_o                    (csr_resp_valid[chiplet_idx]                                         ),
      .csr_rsp_ready_i                    (csr_resp_ready[chiplet_idx]                                         )
    );
  end
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
    bingo_hw_manager_dep_code_t'(8'b00000100) // dep_set_code
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

bingo_hw_manager_task_desc_full_t chip3_cluster0_core2_simd = pack_normal_task(
    1'b0, // task_type
    16'd15, // task_id
    3, // assigned_chiplet_id
    0, // assigned_cluster_id
    2, // assigned_core_id
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
    16'd16, // task_id
    3, // assigned_chiplet_id
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

bingo_hw_manager_task_desc_full_t dummy_set_chip0_cluster0_core2_simd_to_chip1_cluster0_core2_simd = pack_dummy_set_task(
    1'b1, // task_type
    16'd17,  // task_id
    0, // assigned_chiplet_id
    0, // assigned_cluster_id
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
    0, // assigned_cluster_id
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
    0, // assigned_cluster_id
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
    0, // assigned_cluster_id
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
    0, // assigned_cluster_id
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
    0, // assigned_cluster_id
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
    0, // assigned_cluster_id
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
    0, // assigned_cluster_id
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
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000010) // dep_check_code
);

bingo_hw_manager_task_desc_full_t dummy_check_chip3_cluster0_core0_gemm_1_0 = pack_dummy_check_task(
    1'b1, // task_type
    16'd26, // task_id
    3, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000001) // dep_check_code
);

bingo_hw_manager_task_desc_full_t dummy_check_chip3_cluster0_core0_gemm_2_1 = pack_dummy_check_task(
    1'b1, // task_type
    16'd27, // task_id
    3, // assigned_chiplet_id
    0, // assigned_cluster_id
    0, // assigned_core_id
    1'b1, // dep_check_en
    bingo_hw_manager_dep_code_t'(8'b00000110) // dep_check_code
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
    task_queue_master[0].reset();
    done_queue_master[0].reset();

      task_queue_master[0].write(task_queue_base[0], '0, chip0_cluster0_core0_gemm, '1, resp_chip0);
    #50;
      task_queue_master[0].write(task_queue_base[0], '0, chip0_cluster1_core1_dma, '1, resp_chip0);
    #50;
      task_queue_master[0].write(task_queue_base[0], '0, chip0_cluster0_core2_simd, '1, resp_chip0);
    #50;
      task_queue_master[0].write(task_queue_base[0], '0, dummy_set_chip0_cluster0_core2_simd_to_chip1_cluster0_core2_simd, '1, resp_chip0);
    #50;
      task_queue_master[0].write(task_queue_base[0], '0, dummy_set_chip0_cluster0_core2_simd_to_chip2_cluster0_core0_gemm, '1, resp_chip0);
    #50;
  end

  // Host pushes tasks for chiplet 1
  initial begin : chip1_push_sequence
    automatic axi_pkg::resp_t resp_chip1;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[1].reset();
    done_queue_master[1].reset();

      task_queue_master[1].write(task_queue_base[1], '0, chip1_cluster0_core2_simd, '1, resp_chip1);
    #50;
      task_queue_master[1].write(task_queue_base[1], '0, chip1_cluster1_core0_gemm, '1, resp_chip1);
    #50;
      task_queue_master[1].write(task_queue_base[1], '0, dummy_set_chip1_cluster0_core2_simd_0, '1, resp_chip1);
    #50;
      task_queue_master[1].write(task_queue_base[1], '0, chip1_cluster0_core1_dma, '1, resp_chip1);
    #50;
      task_queue_master[1].write(task_queue_base[1], '0, chip1_cluster0_core0_gemm, '1, resp_chip1);
    #50;
      task_queue_master[1].write(task_queue_base[1], '0, dummy_set_chip1_cluster0_core0_gemm_to_chip3_cluster0_core0_gemm_1, '1, resp_chip1);
    #50;
  end

  // Host pushes tasks for chiplet 2
  initial begin : chip2_push_sequence
    automatic axi_pkg::resp_t resp_chip2;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[2].reset();
    done_queue_master[2].reset();

      task_queue_master[2].write(task_queue_base[2], '0, chip2_cluster0_core0_gemm, '1, resp_chip2);
    #50;
      task_queue_master[2].write(task_queue_base[2], '0, chip2_cluster1_core1_dma, '1, resp_chip2);
    #50;
      task_queue_master[2].write(task_queue_base[2], '0, dummy_set_chip2_cluster0_core0_gemm_0, '1, resp_chip2);
    #50;
      task_queue_master[2].write(task_queue_base[2], '0, chip2_cluster0_core1_dma, '1, resp_chip2);
    #50;
      task_queue_master[2].write(task_queue_base[2], '0, dummy_check_chip2_cluster0_core0_gemm_2_1, '1, resp_chip2);
    #50;
      task_queue_master[2].write(task_queue_base[2], '0, chip2_cluster0_core0_gemm_2, '1, resp_chip2);
    #50;
      task_queue_master[2].write(task_queue_base[2], '0, dummy_set_chip2_cluster0_core0_gemm_2_to_chip3_cluster0_core0_gemm_1, '1, resp_chip2);
    #50;
  end

  // Host pushes tasks for chiplet 3
  initial begin : chip3_push_sequence
    automatic axi_pkg::resp_t resp_chip3;
    wait (rst_ni);
    @(posedge clk_i);
    task_queue_master[3].reset();
    done_queue_master[3].reset();

      task_queue_master[3].write(task_queue_base[3], '0, dummy_check_chip3_cluster0_core0_gemm_1_0, '1, resp_chip3);
    #50;
      task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster0_core0_gemm_1, '1, resp_chip3);
    #50;
      task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster0_core2_simd, '1, resp_chip3);
    #50;
      task_queue_master[3].write(task_queue_base[3], '0, dummy_set_chip3_cluster0_core0_gemm_1_0, '1, resp_chip3);
    #50;
      task_queue_master[3].write(task_queue_base[3], '0, dummy_set_chip3_cluster0_core0_gemm_1_1, '1, resp_chip3);
    #50;
      task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster0_core1_dma, '1, resp_chip3);
    #50;
      task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster1_core1_dma, '1, resp_chip3);
    #50;
      task_queue_master[3].write(task_queue_base[3], '0, dummy_check_chip3_cluster0_core0_gemm_2_1, '1, resp_chip3);
    #50;
      task_queue_master[3].write(task_queue_base[3], '0, chip3_cluster0_core0_gemm_2, '1, resp_chip3);
    #50;
  end

  task automatic reset_csr_interface();
    for (int chip_id = 0; chip_id < NUM_CHIPLET; chip_id++) begin
      for (int cluster_id = 0; cluster_id < NUM_CLUSTERS_PER_CHIPLET; cluster_id++) begin
        for (int core_id = 0; core_id < NUM_CORES_PER_CLUSTER; core_id++) begin
          csr_req[chip_id][core_id][cluster_id]        <= '0;
          csr_req_valid[chip_id][core_id][cluster_id]  <= 1'b0;
          csr_resp_ready[chip_id][core_id][cluster_id] <= 1'b0;
        end
      end
    end
    @(posedge clk_i);
  endtask

  task automatic csr_read(
    input int chip_id,
    input int cluster_id,
    input int core_id,
    input device_axi_lite_addr_t addr,
    output device_axi_lite_data_t data
  );
    // 1. Drive Request
    // Note: Indexing is [chip_id][core_id][cluster_id] based on declaration order
    csr_req[chip_id][core_id][cluster_id].addr  <= addr;
    csr_req[chip_id][core_id][cluster_id].write <= 1'b0;
    csr_req[chip_id][core_id][cluster_id].data  <= '0;
    csr_req_valid[chip_id][core_id][cluster_id] <= 1'b1;
    csr_resp_ready[chip_id][core_id][cluster_id] <= 1'b1;
    // 2. Wait for Grant (req_ready)
    while (csr_req_ready[chip_id][core_id][cluster_id] !== 1'b1) begin
      @(posedge clk_i);
    end

    $display("%0t Chip%0d Cluster%0d Core%0d CSR Read Request Granted",
             $time, chip_id, cluster_id, core_id);
    // Wait for Response (resp_valid)
    while (csr_resp_valid[chip_id][core_id][cluster_id] !== 1'b1) begin
      @(posedge clk_i);
    end
    $display("%0t Chip%0d Cluster%0d Core%0d CSR Read Response Valid",
             $time, chip_id, cluster_id, core_id);
    // Sample Data
    data = csr_resp[chip_id][core_id][cluster_id].data;

    // Deassert valid and ready
    csr_req_valid[chip_id][core_id][cluster_id] <= 1'b0;
    csr_resp_ready[chip_id][core_id][cluster_id] <= 1'b0;
  endtask

  task automatic csr_write(
    input int chip_id,
    input int cluster_id,
    input int core_id,
    input device_axi_lite_addr_t addr,
    input device_axi_lite_data_t data
  );
    // 1. Drive Request
    // Note: Indexing is [chip_id][core_id][cluster_id] based on declaration order
    csr_req[chip_id][core_id][cluster_id].addr  <= addr;
    csr_req[chip_id][core_id][cluster_id].write <= 1'b1;
    csr_req[chip_id][core_id][cluster_id].data  <= data;
    csr_req_valid[chip_id][core_id][cluster_id] <= 1'b1;
    csr_resp_ready[chip_id][core_id][cluster_id] <= 1'b0;

    // 2. Wait for Grant (req_ready)
    while (csr_req_ready[chip_id][core_id][cluster_id] !== 1'b1) begin
      @(posedge clk_i);
    end
    $display("%0t Chip%0d Cluster%0d Core%0d CSR Write Request Granted",
             $time, chip_id, cluster_id, core_id);

    // 3. Deassert Request
    csr_req_valid[chip_id][core_id][cluster_id] <= 1'b0;  
  endtask

  logic [NUM_CHIPLET-1:0] done_queue_lock;
  task automatic core_worker(
    input chip_id_t chip_id,
    input int cluster_id,
    input int core_id
  );
    automatic axi_pkg::resp_t                resp = '0;
    automatic device_axi_lite_data_t         data = '0;
    automatic device_axi_lite_addr_t         data_addr;
    automatic device_axi_lite_data_t         status = '1;
    automatic device_axi_lite_addr_t         status_addr;
    automatic device_axi_lite_addr_t         done_addr;
    automatic bingo_hw_manager_done_info_full_t done_info = '0;
    automatic device_axi_lite_data_t         done_payload = '0;    
    int idx = core_id + cluster_id * NUM_CORES_PER_CLUSTER + chip_id * NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER;
    
    done_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip_id;
    data_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip_id;
    status_addr[DEV_AW-1:DEV_AW-ChipIdWidth] = chip_id;
    done_addr[DEV_AW-ChipIdWidth-1:0]   = DONE_QUEUE_BASE;
    data_addr[DEV_AW-ChipIdWidth-1:0]   = READY_QUEUE_BASE + device_axi_lite_addr_t'((core_id + cluster_id * NUM_CORES_PER_CLUSTER) * READY_QUEUE_STRIDE) + 32'd4;
    status_addr[DEV_AW-ChipIdWidth-1:0] = READY_QUEUE_BASE + device_axi_lite_addr_t'((core_id + cluster_id * NUM_CORES_PER_CLUSTER) * READY_QUEUE_STRIDE) + 32'd8;
    $display("%0t Chip%0d READY[Core%0d, Cluster%0d] worker started, idx %0d", $time, chip_id, core_id, cluster_id, idx);
    forever begin
      if(READY_AND_DONE_QUEUE_INTERFACE_TYPE) begin
        // AXI Lite Read
        ready_queue_master[idx].read(status_addr, '0, status, resp);
        repeat (5) @(posedge clk_i);
        // Check the status
        // If no task is ready, retry after some time
        // status[0] == 1 means no task is ready
        if (status[0]) begin
          repeat (10) @(posedge clk_i);
          continue;
        end
        // Here the core sees a task is ready
        $display("%0t Chip%0d READY[Core%0d, Cluster%0d] Status Reg[0]: %d, Task is ready!", $time, chip_id, core_id, cluster_id, status[0]);
        // Read the task id
        ready_queue_master[idx].read(data_addr, '0, data, resp);
      end else begin
        // CSR Read
        // The csr address here is not used
        // We directly read from the fifo instead of reading the status first
        // If the fifo is empty, the ready signal will be deasserted and the read will continue to wait
        csr_read(chip_id, cluster_id, core_id, '0, data);
      end
      repeat (5) @(posedge clk_i);
      $display("%0t Chip%0d READY[Core%0d, Cluster%0d] recvs task_id %0d",
              $time, chip_id, core_id, cluster_id, data[TaskIdWidth-1:0]);
      $display("%0t Chip%0d READY[Core%0d, Cluster%0d] doing some work....",
              $time, chip_id, core_id, cluster_id);                
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      $display("%0t Chip%0d READY[Core%0d, Cluster%0d] done with task_id %0d, sending done info back",
              $time, chip_id, core_id, cluster_id, data[TaskIdWidth-1:0]);
      done_info.task_id     = data[TaskIdWidth-1:0];
      done_info.assigned_cluster_id  = bingo_hw_manager_assigned_cluster_id_t'(cluster_id);
      done_info.assigned_core_id     = bingo_hw_manager_assigned_core_id_t'(core_id);
      done_info.reserved_bits = '0;
      done_payload = device_axi_lite_data_t'(done_info);
      if(READY_AND_DONE_QUEUE_INTERFACE_TYPE) begin
      // Acquire the lock for the done queue
      wait (!done_queue_lock[chip_id]); // Wait until the lock is free
      done_queue_lock[chip_id] = 1'b1;  // Acquire the lock


      done_queue_master[chip_id].write(done_addr, '0, done_payload, {DEV_DW/8{1'b1}}, resp);
      repeat ($urandom_range(20, 50)) @(posedge clk_i);
      // Release the lock
      done_queue_lock[chip_id] = 1'b0;
      end else begin
        // CSR Write
        // The csr address here is not used
        // We directly write to the fifo
        csr_write(chip_id, cluster_id, core_id, '0, done_payload);
        repeat ($urandom_range(10, 20)) @(posedge clk_i);
      end
    end

  endtask


initial begin : ready_queue_pollers
    reset_csr_interface();
    wait (rst_ni);
    repeat (5) @(posedge clk_i);
    done_queue_lock = '0;
    for (int chip_idx = 0; chip_idx < NUM_CHIPLET; chip_idx++) begin
      for (int cluster_idx = 0; cluster_idx < NUM_CLUSTERS_PER_CHIPLET; cluster_idx++) begin
        for (int core_idx = 0; core_idx < NUM_CORES_PER_CLUSTER; core_idx++) begin
          fork
            automatic int c_id = chip_idx;      // Capture chip index
            automatic int cl_id = cluster_idx;  // Capture cluster index
            automatic int co_id = core_idx;     // Capture core index
            core_worker(c_id, cl_id, co_id);    // Spawn core_worker
          join_none
        end
      end
    end
    // fork
    //   core_worker(0, 0, 0);
    //   core_worker(0, 0, 1);
    //   core_worker(0, 0, 2);
    //   core_worker(0, 1, 0);
    //   core_worker(0, 1, 1);
    //   core_worker(0, 1, 2);
    //   core_worker(1, 0, 0);
    //   core_worker(1, 0, 1);
    //   core_worker(1, 0, 2);
    //   core_worker(1, 1, 0);
    //   core_worker(1, 1, 1);
    //   core_worker(1, 1, 2);
    //   core_worker(2, 0, 0);
    //   core_worker(2, 0, 1);
    //   core_worker(2, 0, 2);
    //   core_worker(2, 1, 0);
    //   core_worker(2, 1, 1);
    //   core_worker(2, 1, 2);
    //   core_worker(3, 0, 0);
    //   core_worker(3, 0, 1);
    //   core_worker(3, 0, 2);
    //   core_worker(3, 1, 0);
    //   core_worker(3, 1, 1);
    //   core_worker(3, 1, 2);
    // join_none
  end


  // Timeout
  initial begin
    #10000;
    $fatal(1, "Timeout");
  end

endmodule