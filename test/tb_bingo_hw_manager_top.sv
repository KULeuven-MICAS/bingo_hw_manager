`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"
`include "axi/port.svh"

import axi_pkg::*;
import axi_test::*;

module tb_bingo_hw_manager_top;

    // ---------------------------------------------------------------------------
    // Local configuration
    // ---------------------------------------------------------------------------
    localparam int unsigned NUM_CHIPLET = 4;
    localparam int unsigned NUM_CORES_PER_CLUSTER    = 3;
    localparam int unsigned NUM_CLUSTERS_PER_CHIPLET = 2;
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
    typedef logic [NUM_CHIPLET-1:0                     ] bingo_hw_manager_chiplet_check_code_t;
    typedef logic [$clog2(NUM_CORES_PER_CLUSTER)-1:0   ] bingo_hw_manager_task_type_t;
    typedef logic [0:0                                 ] bingo_hw_manager_dummy_t;
    typedef logic [TaskIdWidth-1:0                     ] bingo_hw_manager_task_id_t;
    typedef logic [NUM_CORES_PER_CLUSTER-1:0           ] bingo_hw_manager_dep_code_t;
    typedef logic [$clog2(NUM_CLUSTERS_PER_CHIPLET)-1:0] bingo_hw_manager_cluster_id_t;

    // Dependency check info struct
    typedef struct packed{
        logic                                        dep_check_en;
        bingo_hw_manager_dep_code_t                  dep_check_code;
        bingo_hw_manager_cluster_id_t                dep_check_cluster_idx;
        logic                                        dep_check_chiplet_en;
        bingo_hw_manager_chiplet_check_code_t        dep_check_chiplet_code;
    } bingo_hw_manager_dep_check_info_t;

    // Dependency set info struct
    typedef struct packed{
        logic                                        dep_set_en;
        bingo_hw_manager_dep_code_t                  dep_set_code;
        bingo_hw_manager_cluster_id_t                dep_set_cluster_idx;
    } bingo_hw_manager_dep_set_info_t;

    // Task info struct
    typedef struct packed{
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        bingo_hw_manager_dummy_t                     is_dummy;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
    } bingo_hw_manager_task_desc_t;

    localparam int unsigned TaskDescWidth = $bits(bingo_hw_manager_task_desc_t);
    localparam int unsigned ReservedBitsForTaskDesc = HOST_DW - TaskDescWidth;
    if (TaskDescWidth>HOST_DW) begin : gen_task_desc_width_check
        initial begin
        $error("Task Decriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", TaskDescWidth, HOST_DW);
        $finish;
        end
    end
    // Task info struct
    typedef struct packed{
        logic [ReservedBitsForTaskDesc-1:0]          reserved_bits;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        bingo_hw_manager_dummy_t                     is_dummy;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
    } bingo_hw_manager_task_desc_full_t;

    typedef struct packed{
        bingo_hw_manager_task_id_t                 task_id;
        bingo_hw_manager_cluster_id_t              cluster_id;
        bingo_hw_manager_task_type_t               core_id;
    } bingo_hw_manager_done_info_t;

    localparam int unsigned DoneInfoWidth = $bits(bingo_hw_manager_done_info_t);
    localparam int unsigned ReservedBitsForDoneInfo = DEV_DW - DoneInfoWidth;

    typedef struct packed{
        logic [ReservedBitsForDoneInfo-1:0]        reserved_bits;
        bingo_hw_manager_task_id_t                 task_id;
        bingo_hw_manager_cluster_id_t              cluster_id;
        bingo_hw_manager_task_type_t               core_id;
    } bingo_hw_manager_done_info_full_t;

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

  // AXI-Lite virtual interfaces
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW),
                .AXI_DATA_WIDTH(HOST_DW)
  ) host_if (.clk_i(clk_i));

  // AXI-Lite virtual interfaces
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(HOST_AW),
                .AXI_DATA_WIDTH(HOST_DW)
  ) h2h_done_if (.clk_i(clk_i));

  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) done_if (.clk_i(clk_i));
  AXI_LITE_DV #(.AXI_ADDR_WIDTH(DEV_AW ),
                .AXI_DATA_WIDTH(DEV_DW )
  ) ready_if [READY_AGENT_NUM-1:0] (.clk_i(clk_i));


  // Struct wires that connect to the DUT
  host_req_t task_queue_req;
  host_resp_t task_queue_resp;

  host_req_t h2h_done_queue_req;
  host_resp_t h2h_done_queue_resp;

  dev_req_t done_queue_req;
  dev_resp_t done_queue_resp;

  dev_req_t  [READY_AGENT_NUM-1:0] ready_queue_req ;
  dev_resp_t [READY_AGENT_NUM-1:0] ready_queue_resp;

  // Interface<->struct hookups
  `AXI_LITE_ASSIGN_TO_REQ  (task_queue_req , host_if);
  `AXI_LITE_ASSIGN_FROM_RESP(host_if      , task_queue_resp);

  `AXI_LITE_ASSIGN_TO_REQ  (h2h_done_queue_req , h2h_done_if);
  `AXI_LITE_ASSIGN_FROM_RESP(h2h_done_if      , h2h_done_queue_resp);

  `AXI_LITE_ASSIGN_TO_REQ  (done_queue_req , done_if);
  `AXI_LITE_ASSIGN_FROM_RESP(done_if      , done_queue_resp);
  // hook each generated ready_if_inst to the request/response structs
  for (genvar idx = 0; idx < READY_AGENT_NUM; idx++) begin : gen_ready_assign
    `AXI_LITE_ASSIGN_TO_REQ  (ready_queue_req[idx], ready_if[idx]);
    `AXI_LITE_ASSIGN_FROM_RESP(ready_if[idx], ready_queue_resp[idx]);
  end

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  // Flatten ready-queue base addresses into 2-D packed array for DUT
  device_axi_lite_addr_t [READY_AGENT_NUM-1:0] ready_base_addr_bus;
  device_axi_lite_addr_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_base_addr_2d;
  initial begin
    for (int idx = 0; idx < READY_AGENT_NUM; idx++) begin
      ready_base_addr_bus[idx] = READY_QUEUE_BASE + device_axi_lite_addr_t'( idx * READY_QUEUE_STRIDE );
    end
  end
  initial begin
    for (int idx = 0; idx < NUM_CORES_PER_CLUSTER; idx++) begin
      for (int jdx = 0; jdx < NUM_CLUSTERS_PER_CHIPLET; jdx++) begin
        ready_base_addr_2d[idx][jdx] = READY_QUEUE_BASE + device_axi_lite_addr_t'( (idx * NUM_CLUSTERS_PER_CHIPLET + jdx) * READY_QUEUE_STRIDE );
      end
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
    .h2h_done_queue_axi_lite_in_req_t (host_req_t ),
    .h2h_done_queue_axi_lite_in_resp_t(host_resp_t),
    .done_queue_axi_lite_in_req_t     (dev_req_t  ),
    .done_queue_axi_lite_in_resp_t    (dev_resp_t ),
    .ready_queue_axi_lite_in_req_t    (dev_req_t  ),
    .ready_queue_axi_lite_in_resp_t   (dev_resp_t )
  ) dut (
    .clk_i                         (clk_i               ),
    .rst_ni                        (rst_ni              ),
    .chip_id_i                     ('0                  ),
    .task_queue_base_addr_i        (TASK_QUEUE_BASE     ),
    .task_queue_axi_lite_req_i     (task_queue_req      ),
    .task_queue_axi_lite_resp_o    (task_queue_resp     ),
    .h2h_done_queue_base_addr_i    (H2H_DONE_QUEUE_BASE ),
    .h2h_done_queue_axi_lite_req_i (h2h_done_queue_req  ),
    .h2h_done_queue_axi_lite_resp_o(h2h_done_queue_resp ),
    .done_queue_base_addr_i        (DONE_QUEUE_BASE     ),
    .done_queue_axi_lite_req_i     (done_queue_req      ),
    .done_queue_axi_lite_resp_o    (done_queue_resp     ),
    .ready_queue_base_addr_i       (ready_base_addr_2d  ),
    .ready_queue_axi_lite_req_i    (ready_queue_req     ),
    .ready_queue_axi_lite_resp_o   (ready_queue_resp    )
  );


  axi_lite_driver #(
    .AW(HOST_AW),
    .DW(HOST_DW)
  ) host_drv = new(host_if);

  axi_lite_driver #(
    .AW(HOST_AW),
    .DW(HOST_DW)
  ) h2h_done_drv = new(h2h_done_if);

  initial h2h_done_drv.reset_master();

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) done_drv = new(done_if);

  initial done_drv.reset_master();

  axi_lite_driver #(
    .AW(DEV_AW),
    .DW(DEV_DW)
  ) ready_drv [READY_AGENT_NUM-1:0];

  for (genvar idx = 0; idx < READY_AGENT_NUM; idx++) begin : gen_ready_drv_init
    initial begin 
      ready_drv[idx] = new(ready_if[idx]);
      ready_drv[idx].reset_master();
    end
  end


  // ---------------------------------------------------------------------------
  // Task descriptor packing helper
  // ---------------------------------------------------------------------------

  function automatic bingo_hw_manager_task_desc_full_t pack_task(
    input bingo_hw_manager_task_id_t    task_id,
    input bingo_hw_manager_task_type_t  core_sel,
    input logic                         is_dummy,
    input logic                         dep_check_en,
    input bingo_hw_manager_dep_code_t   dep_check_code,
    input bingo_hw_manager_cluster_id_t dep_check_cluster_idx,
    input logic                         dep_check_chiplet_en,
    input bingo_hw_manager_chiplet_check_code_t dep_check_chiplet_code,
    input logic                         dep_set_en,
    input bingo_hw_manager_dep_code_t   dep_set_code,
    input bingo_hw_manager_cluster_id_t dep_set_cluster_idx
  );
    bingo_hw_manager_task_desc_full_t tmp;
    tmp.task_id                          = task_id;
    tmp.task_type                        = core_sel;
    tmp.is_dummy                         = is_dummy;
    tmp.dep_check_info.dep_check_en      = dep_check_en;
    tmp.dep_check_info.dep_check_code    = dep_check_code;
    tmp.dep_check_info.dep_check_cluster_idx = dep_check_cluster_idx;
    tmp.dep_check_info.dep_check_chiplet_en = dep_check_chiplet_en;
    tmp.dep_check_info.dep_check_chiplet_code = dep_check_chiplet_code;
    tmp.dep_set_info.dep_set_en          = dep_set_en;
    tmp.dep_set_info.dep_set_code        = dep_set_code;
    tmp.dep_set_info.dep_set_cluster_idx = dep_set_cluster_idx;
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
    // Task 0: ID 0, Core 0, Cluster 0, no dep check, dep set: set core 1, cluster 0
    // Task 1: ID 1, Core 1, Cluster 0, dep check: check cluster0, core0 dep set: set cluster1, core2
    // Task 2: ID 2, Core 2, Cluster 1, dep check: wait for cluster0, core1, no dep set
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