// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

module bingo_hw_manager_top #(
    // Top-level parameters can be defined here
    parameter int unsigned READY_AND_DONE_QUEUE_INTERFACE_TYPE = 1, // 1: CSR Req/Resp 0: Default AXi Lite Slave
    parameter int unsigned TASK_QUEUE_TYPE = 1,                     // 1: AXI Lite Master 0: Default AXI Lite Slave
    parameter int unsigned NUM_CORES_PER_CLUSTER = 4,
    parameter int unsigned NUM_CLUSTERS_PER_CHIPLET = 2,
    parameter int unsigned ChipIdWidth = 8,
    parameter int unsigned TaskIdWidth = 12,
    // AXI interface types
    // The task queue holds tasks to be scheduled to the devices
    // Host writes the task queue via 64bit AXI Lite
    parameter int unsigned HostAxiLiteAddrWidth = 48,
    parameter int unsigned HostAxiLiteDataWidth = 64,
    // Device writes the done queue via 32bit AXI Lite
    parameter int unsigned DeviceAxiLiteAddrWidth = 48,
    parameter int unsigned DeviceAxiLiteDataWidth = 32,
    // AXI Lite Interface types for host and device
    parameter type host_axi_lite_req_t = logic,
    parameter type host_axi_lite_resp_t = logic,
    parameter type device_axi_lite_req_t = logic,
    parameter type device_axi_lite_resp_t = logic,
    parameter type csr_req_t = logic,
    parameter type csr_rsp_t = logic,
    // FIFO Depths
    parameter int unsigned TaskQueueDepth = 32,
    parameter int unsigned ChipletDoneQueueDepth = 32,
    parameter int unsigned DoneQueueDepth = 32,
    parameter int unsigned CheckoutQueueDepth = 8,
    parameter int unsigned ReadyQueueDepth = 8,
    // Address Offsets
    parameter int unsigned ReadyQueueAddrOffset = 4096,
    // Dependent parameters, DO NOT OVERRIDE!
    parameter type chip_id_t = logic [ChipIdWidth-1:0],
    parameter type host_axi_lite_addr_t = logic [HostAxiLiteAddrWidth-1:0],
    parameter type host_axi_lite_data_t = logic [HostAxiLiteDataWidth-1:0],
    parameter type device_axi_lite_addr_t = logic [DeviceAxiLiteAddrWidth-1:0],
    parameter type device_axi_lite_data_t = logic [DeviceAxiLiteDataWidth-1:0]
) (
    /// Clock
    input logic clk_i,
    /// Asynchronous reset, active low
    input logic rst_ni,
    /// Chip ID for multi-chip addressing
    input chip_id_t chip_id_i,
    /// Interface to the system
    // For the task queue, we have two interfaces:
    // 1. Host writes to the task queue via 64bit AXI Lite interface
    // Host -----> Task Queue
    // Here this queue holds all the tasks to be scheduled to the devices
    // Hence this is a slave AXI Lite interface
    input  host_axi_lite_addr_t                 task_queue_base_addr_i,
    input  host_axi_lite_req_t                  task_queue_axi_lite_req_i,
    output host_axi_lite_resp_t                 task_queue_axi_lite_resp_o,
    // 2. The Hw Manager issues the read request to the address specified by the host via the following inputs
    // Hence this is a master AXI Lite interface
    input host_axi_lite_addr_t                  task_list_base_addr_i, // The task list base address specified by the host
    input device_axi_lite_data_t                num_task_i,            // The number of tasks specified by the host
    // Control signals to start the HW Manager
    // The start signals are from the reg gen modules
    input  device_axi_lite_data_t               bingo_hw_manager_start_i,
    output device_axi_lite_data_t               bingo_hw_manager_reset_start_o,
    output logic                                bingo_hw_manager_reset_start_en_o,
    output host_axi_lite_req_t                  task_queue_axi_lite_req_o,
    input  host_axi_lite_resp_t                 task_queue_axi_lite_resp_i,
    // The chiplet set interface to other chiplets
    // HW Manager -----> Other chiplets
    input  host_axi_lite_addr_t                 chiplet_mailbox_base_addr_i,
    output host_axi_lite_req_t                  to_remote_chiplet_axi_lite_req_o,
    input  host_axi_lite_resp_t                 to_remote_chiplet_axi_lite_resp_i,
    // The chiplet done interface from other chiplets
    input  host_axi_lite_req_t                  from_remote_axi_lite_req_i,
    output host_axi_lite_resp_t                 from_remote_axi_lite_resp_o,
    // The done queue interface to the devices
    // Devices -----> Done Queue
    // Here this queue holds all the completed tasks info from the devices
    // The device cores will write completed tasks into this queue via 32bit AXI Lite
    input  device_axi_lite_addr_t               done_queue_base_addr_i,
    input  device_axi_lite_req_t                done_queue_axi_lite_req_i,
    output device_axi_lite_resp_t               done_queue_axi_lite_resp_o,
    // The ready queue interface to the devices
    // HW scheduler -----> Ready Queue
    // Here the ready queue holds the tasks that are ready to be executed by the devices
    // The device cores will read tasks from this queue via 32bit AXI Lite
    // Each core has its own ready queue interface
    input  device_axi_lite_addr_t                ready_queue_base_addr_i,
    input  device_axi_lite_req_t             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_req_i,
    output device_axi_lite_resp_t            [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_resp_o,
    // CSR Req/Resp Interface for ready queue and the done queue
    // CSR Will Read from the ready queue and write to the done queue
    input  csr_req_t                         [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_i,
    input  logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_valid_i,
    output logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_ready_o,
    output csr_rsp_t                         [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_o,
    output logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_valid_o,
    input  logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_ready_i
);
    // --------Type definitions and signal declarations--------------------//
    // ---- Start of Type definitions -------------------------------------//
    // Task Type
    // 0: Normal Task
    // 1: Dummy Task
    typedef logic                                        bingo_hw_manager_task_type_t;
    // Task ID
    typedef logic [TaskIdWidth-1:0                     ] bingo_hw_manager_task_id_t;
    // Assigned Chiplet ID
    typedef logic [ChipIdWidth-1:0                     ] bingo_hw_manager_assigned_chiplet_id_t;
    // Assigned Cluster ID
    typedef logic [cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)-1:0] bingo_hw_manager_assigned_cluster_id_t;
    // Assigned Core ID
    typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0   ] bingo_hw_manager_assigned_core_id_t;
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

    // Done info struct
    typedef struct packed{
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_t;

    localparam int unsigned DoneInfoWidth = $bits(bingo_hw_manager_done_info_t);
    localparam int unsigned ReservedBitsForDoneInfo = DeviceAxiLiteDataWidth - DoneInfoWidth;
    if (DoneInfoWidth>DeviceAxiLiteDataWidth) begin : gen_done_info_width_check
        initial begin
        $error("Task Decriptor width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", DoneInfoWidth, DeviceAxiLiteDataWidth);
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
        bingo_hw_manager_assigned_core_id_t        dep_matrix_col;
        bingo_hw_manager_dep_code_t                dep_set_code;
    } bingo_hw_manager_dep_matrix_set_meta_t;

    typedef struct packed{
        bingo_hw_manager_task_id_t           task_id;
    } bingo_hw_manager_ready_task_desc_t;
    // Check the width
    localparam int unsigned ReadyTaskDescWidth = $bits(bingo_hw_manager_ready_task_desc_t);
    localparam int unsigned ReservedBitsForReadyTaskDesc = DeviceAxiLiteDataWidth - ReadyTaskDescWidth;
    if (ReadyTaskDescWidth>DeviceAxiLiteDataWidth) begin : gen_ready_task_desc_width_check
        initial begin
        $error("Ready Task Decriptor width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", ReadyTaskDescWidth, DeviceAxiLiteDataWidth);
        $finish;
        end
    end
    typedef struct packed{
        logic [ReservedBitsForReadyTaskDesc-1:0] reserved_bits;
        bingo_hw_manager_task_id_t           task_id;
    } bingo_hw_manager_ready_task_desc_full_t;
    //----- End of Type definitions ------------------------------------//

    //----- Start of Signal declarations -------------------------------//

    /////////////////////////////////////////////////////////
    // Task Queue Signals
    /////////////////////////////////////////////////////////
    // The task queue holds the tasks to be scheduled to the devices
    bingo_hw_manager_task_desc_full_t  cur_task_desc_full;
    bingo_hw_manager_task_desc_t       cur_task_desc;
    logic [HostAxiLiteDataWidth-1:0]   task_queue_mbox_data;
    logic                              task_queue_mbox_empty;
    logic                              task_queue_mbox_pop;


    /////////////////////////////////////////////////////////
    // Chiplet Dep Set Issue
    /////////////////////////////////////////////////////////
    // This module is to send the chiplet dep set signal to other chiplets
    // It will receive the chiplet dep set task from the wait dep check queues
    bingo_hw_manager_task_desc_full_t chiplet_dep_set_task_desc;
    logic                             chiplet_dep_set_task_desc_valid;
    logic                             chiplet_dep_set_task_desc_ready;

    //////////////////////////////////////////////////////////
    // Stream Arbiter Chiplet Dep Set Issue Signals
    //////////////////////////////////////////////////////////
    // The inputs are from the checkout queues of all cores in the chiplet
    bingo_hw_manager_task_desc_full_t [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] stream_arbiter_chiplet_dep_set_inp_task_desc;
    logic                             [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] stream_arbiter_chiplet_dep_set_inp_valid;
    logic                             [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] stream_arbiter_chiplet_dep_set_inp_ready;
    bingo_hw_manager_task_desc_full_t                                                      stream_arbiter_chiplet_dep_set_oup_task_desc;
    logic                                                                                  stream_arbiter_chiplet_dep_set_oup_valid;
    logic                                                                                  stream_arbiter_chiplet_dep_set_oup_ready;


    //////////////////////////////////////////////////////////
    // Chiplet Done Queue
    //////////////////////////////////////////////////////////
    logic [HostAxiLiteDataWidth-1:0]   chiplet_done_queue_mbox_data;
    logic                              chiplet_done_queue_mbox_empty;
    logic                              chiplet_done_queue_mbox_pop;
    bingo_hw_manager_task_desc_full_t  cur_chiplet_done_queue_task_desc;
    /////////////////////////////////////////////////////////
    // Stream demux core type
    /////////////////////////////////////////////////////////
    logic                                           stream_demux_core_type_inp_valid;
    logic                                           stream_demux_core_type_inp_ready;
    logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0]       stream_demux_core_type_oup_sel;
    logic [NUM_CORES_PER_CLUSTER-1:0]               stream_demux_core_type_oup_valid;
    logic [NUM_CORES_PER_CLUSTER-1:0]               stream_demux_core_type_oup_ready;

    ///////////////////////////////////
    // Waiting dep check queue signals
    ///////////////////////////////////
    bingo_hw_manager_task_desc_t      [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_task_desc;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_push;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_full;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_empty;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_pop;

    ////////////////////////////////
    // Dep Check Manager Signals
    ////////////////////////////////
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_inp_wait_dep_check_queue_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_inp_wait_dep_check_queue_ready;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_oup_dep_check_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_oup_dep_check_ready;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_oup_ready_and_checkout_queue_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_manager_oup_ready_and_checkout_queue_ready;
    ////////////////////////////////
    // Dep matrix demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] dep_matrix_demux_oup_t;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_inp_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_inp_ready;
    dep_matrix_demux_oup_t            [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_oup_valid;
    dep_matrix_demux_oup_t            [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_oup_ready;

    ////////////////////////////////
    // Ready and Checkout queue demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] ready_and_checkout_queue_demux_oup_t;
    logic                                          [NUM_CORES_PER_CLUSTER-1:0] demux_ready_and_checkout_queue_inp_valid;
    logic                                          [NUM_CORES_PER_CLUSTER-1:0] demux_ready_and_checkout_queue_inp_ready;
    ready_and_checkout_queue_demux_oup_t           [NUM_CORES_PER_CLUSTER-1:0] demux_ready_and_checkout_queue_oup_valid;
    ready_and_checkout_queue_demux_oup_t           [NUM_CORES_PER_CLUSTER-1:0] demux_ready_and_checkout_queue_oup_ready;

    ////////////////////////////////
    // Ready Queue Filter Signals
    ////////////////////////////////
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_inp_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_inp_ready;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_drop;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_oup_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_oup_ready;

    //////////////////////
    // Dep matrix signals
    //////////////////////
    typedef logic [NUM_CORES_PER_CLUSTER-1:0] dep_check_code_t;
    typedef logic [NUM_CORES_PER_CLUSTER-1:0] dep_set_code_t;

    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_check_valid;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_check_result;
    dep_check_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] dep_check_code;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_set_valid;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_set_ready;
    dep_set_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]   dep_set_code;

    ///////////////////////////////////////
    // Stream Arbiter Dep Matrix Set
    ///////////////////////////////////////
    // There are two types input streams to set the dep matrix
    // Type 1: From Checkout queues (NUM_CORE * NUM_Cluster) for normal and dummy set dep
    // Type 2: From Chiplet Dep Set Recv Queue for chiplet dep set queues
    // In total we have (NUM_CORE * NUM_Cluster) + 1 inputs for the dep matrix set
    localparam int unsigned STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP = NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET + 1;
    bingo_hw_manager_dep_matrix_set_meta_t    [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_data;
    logic                                     [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_valid;
    logic                                     [STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP-1:0] stream_arbiter_dep_matrix_set_inp_ready;
    bingo_hw_manager_dep_matrix_set_meta_t                                                stream_arbiter_dep_matrix_set_oup_data;
    logic                                                                                 stream_arbiter_dep_matrix_set_oup_valid;
    logic                                                                                 stream_arbiter_dep_matrix_set_oup_ready;
 
    ///////////////////////////////////////
    // Stream Demux Set Dep Matrix Cluster ID
    ///////////////////////////////////////
    // Possbile to move the demux before the arbiter to support more parallelism
    logic                                                          stream_demux_set_dep_matrix_cluster_id_inp_valid;
    logic                                                          stream_demux_set_dep_matrix_cluster_id_inp_ready;
    logic  [cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)-1:0]  stream_demux_set_dep_matrix_cluster_id_oup_sel;
    logic  [NUM_CLUSTERS_PER_CHIPLET-1:0]                          stream_demux_set_dep_matrix_cluster_id_oup_valid;
    logic  [NUM_CLUSTERS_PER_CHIPLET-1:0]                          stream_demux_set_dep_matrix_cluster_id_oup_ready;
    ///////////////////////////////////////
    // Stream Demux Set Dep Matrix Core ID
    ///////////////////////////////////////
    typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0]             stream_demux_set_dep_matrix_core_id_oup_sel_t;
    typedef logic [NUM_CORES_PER_CLUSTER-1:0]                                     stream_demux_set_dep_matrix_core_id_oup_t;
    logic                                          [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_inp_valid;
    logic                                          [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_inp_ready;
    stream_demux_set_dep_matrix_core_id_oup_sel_t  [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_oup_sel;
    stream_demux_set_dep_matrix_core_id_oup_t      [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_oup_valid;
    stream_demux_set_dep_matrix_core_id_oup_t      [NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_set_dep_matrix_core_id_oup_ready;


    //////////////////////
    // Ready queue signals
    //////////////////////
    // Ready task info
    device_axi_lite_addr_t                  [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_base_addr;
    bingo_hw_manager_ready_task_desc_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_data_in;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_push;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_full;
    // ready queue data_o/empty_o/pop_i signals are only for CSR interface
    logic                                    [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_pop;
    bingo_hw_manager_ready_task_desc_full_t  [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_data_out;
    logic                                    [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_empty;


    //////////////////////
    // Checkout queue signals
    //////////////////////
    bingo_hw_manager_task_desc_t   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_data_out;
    bingo_hw_manager_task_desc_t   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_data_in;
    logic                          [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_push;
    logic                          [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_pop;
    logic                          [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_full;
    logic                          [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_empty;

    ///////////////////////////////////////////
    // Stream Demux Checkout Queue Chiplet Set
    ///////////////////////////////////////////
    // After each checkout queue, we need to demux the chiplet dep set tasks
    // There are two types of outputs from the checkout queue
    // [0]: Local dep set
    // [1]: Chiplet dep set
    typedef logic [1:0] stream_demux_checkout_queue_chiplet_dep_set_oup_t;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_inp_valid;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_inp_ready;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_oup_sel;
    stream_demux_checkout_queue_chiplet_dep_set_oup_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_oup_valid;
    stream_demux_checkout_queue_chiplet_dep_set_oup_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_checkout_queue_chiplet_dep_set_oup_ready;

    ///////////////////////////////////////////
    // Stream Filter Checkout Queue Dep Set Enable
    ///////////////////////////////////////////    
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_inp_valid;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_inp_ready;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_drop;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_oup_valid;
    logic                                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] stream_filter_checkout_queue_dep_set_enable_oup_ready;
    ///////////////////////////////////////
    // Done Queue signals
    ///////////////////////////////////////
    bingo_hw_manager_done_info_full_t    cur_done_queue_info;
    device_axi_lite_data_t               done_queue_mbox_data;
    logic                                done_queue_mbox_pop;
    logic                                done_queue_mbox_empty;
    device_axi_lite_data_t               done_queue_mbox_data_in;
    logic                                done_queue_mbox_push;
    logic                                done_queue_mbox_full;
    // --------Finish Type definitions and signal declarations--------------------//

    // --------Module initializations---------------------------------------------//

    //////////////////////////////////////////////////////////////////////
    // Task Queue
    /////////////////////////////////////////////////////////////////////
    if (TASK_QUEUE_TYPE == 0 ) begin : gen_bingo_hw_manager_task_queue_default_slave
        // Default AXI Lite Slave Task Queue
        bingo_hw_manager_write_mailbox #(
            .MailboxDepth(TaskQueueDepth               ),
            .IrqEdgeTrig (1'b0                         ),
            .IrqActHigh  (1'b1                         ),
            .AxiAddrWidth(HostAxiLiteAddrWidth         ),
            .AxiDataWidth(HostAxiLiteDataWidth         ),
            .ChipIdWidth (ChipIdWidth                  ),
            .req_lite_t  (host_axi_lite_req_t          ),
            .resp_lite_t (host_axi_lite_resp_t         )
        ) i_bingo_hw_manager_task_queue_slave (
            .clk_i       (clk_i                     ),
            .rst_ni      (rst_ni                    ),
            .chip_id_i   (chip_id_i                 ),
            .test_i      (1'b0                      ),
            .req_i       (task_queue_axi_lite_req_i ),
            .resp_o      (task_queue_axi_lite_resp_o),
            .irq_o       (/*not used*/              ),
            .base_addr_i (task_queue_base_addr_i    ),
            .mbox_data_o (task_queue_mbox_data      ),
            .mbox_pop_i  (task_queue_mbox_pop       ),
            .mbox_empty_o(task_queue_mbox_empty     ),
            .mbox_flush_i('0                        )
        );
        // Tie off the unused master interface signals
        assign task_queue_axi_lite_req_o = '0;
        assign reset_start_o = 1'b0;
        assign reset_start_enable_o = 1'b0;
    end
    else begin : gen_bingo_hw_manager_task_queue_master
        // AXI Lite Master Task Queue
        // The Hw Manager issues the read request to the address specified by the host via the following inputs
        // Hence this is a master AXI Lite interface
        bingo_hw_manager_task_queue_master #(
            .TaskQueueDepth               (TaskQueueDepth               ),
            .TaskIdWidth                  (TaskIdWidth                  ),
            .req_lite_t                   (host_axi_lite_req_t          ),
            .resp_lite_t                  (host_axi_lite_resp_t         ),
            .addr_t                       (host_axi_lite_addr_t         ),
            .data_t                       (host_axi_lite_data_t         )
        ) i_bingo_hw_manager_task_queue_master (
            .clk_i                     (clk_i                                ),
            .rst_ni                    (rst_ni                               ),
            .task_list_base_addr_i     (task_list_base_addr_i                ),
            .num_task_i                (num_task_i                           ),
            .start_i                   (bingo_hw_manager_start_i             ),
            .reset_start_o             (bingo_hw_manager_reset_start_o       ),
            .reset_start_en_o          (bingo_hw_manager_reset_start_en_o    ),
            .task_queue_axi_lite_req_o (task_queue_axi_lite_req_o            ),
            .task_queue_axi_lite_resp_i(task_queue_axi_lite_resp_i           ),
            .task_queue_data_o         (task_queue_mbox_data                 ),
            .task_queue_pop_i          (task_queue_mbox_pop                  ),
            .task_queue_empty_o        (task_queue_mbox_empty                )
        );
        // Tie off the unused slave interface signals
        assign task_queue_axi_lite_resp_o = '0;
    end
    assign task_queue_mbox_pop = stream_demux_core_type_inp_ready && !task_queue_mbox_empty;
    // Compose the current task descriptor
    assign cur_task_desc_full = bingo_hw_manager_task_desc_full_t'(task_queue_mbox_data);
    assign cur_task_desc.task_id = cur_task_desc_full.task_id;
    assign cur_task_desc.task_type = cur_task_desc_full.task_type;
    assign cur_task_desc.assigned_chiplet_id = cur_task_desc_full.assigned_chiplet_id;
    assign cur_task_desc.assigned_cluster_id = cur_task_desc_full.assigned_cluster_id;
    assign cur_task_desc.assigned_core_id = cur_task_desc_full.assigned_core_id;
    assign cur_task_desc.dep_check_info = cur_task_desc_full.dep_check_info;
    assign cur_task_desc.dep_set_info = cur_task_desc_full.dep_set_info;


    /////////////////////////////////////////////////////////
    // H2H Dep Set Interface
    /////////////////////////////////////////////////////////       
    bingo_hw_manager_chiplet_dep_set #(
        .ChipIdWidth                                  (ChipIdWidth            ),
        .HostAxiLiteAddrWidth                         (HostAxiLiteAddrWidth   ),
        .HostAxiLiteDataWidth                         (HostAxiLiteDataWidth   ),
        .host_axi_lite_req_t                          (host_axi_lite_req_t    ),
        .host_axi_lite_resp_t                         (host_axi_lite_resp_t   ),
        .bingo_hw_manager_task_desc_full_t            (bingo_hw_manager_task_desc_full_t)
    ) i_bingo_hw_manager_chiplet_dep_set (
        .clk_i                             (clk_i                              ),
        .rst_ni                            (rst_ni                             ),
        .chiplet_mailbox_base_addr_i       (chiplet_mailbox_base_addr_i        ),
        .to_remote_chiplet_axi_lite_req_o  (to_remote_chiplet_axi_lite_req_o   ),
        .to_remote_chiplet_axi_lite_resp_i (to_remote_chiplet_axi_lite_resp_i  ),
        .chiplet_dep_set_task_desc_i       (chiplet_dep_set_task_desc          ),
        .chiplet_dep_set_task_desc_valid_i (chiplet_dep_set_task_desc_valid    ),
        .chiplet_dep_set_task_desc_ready_o (chiplet_dep_set_task_desc_ready    )
    );
    assign chiplet_dep_set_task_desc = stream_arbiter_chiplet_dep_set_oup_task_desc;
    assign chiplet_dep_set_task_desc_valid = stream_arbiter_chiplet_dep_set_oup_valid;

    /////////////////////////////////////////////////////////
    // Stream Arbiter for Chiplet Dep Set
    /////////////////////////////////////////////////////////     
    stream_arbiter #(
        .DATA_T (bingo_hw_manager_task_desc_full_t                             ),
        .N_INP  (NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET              )
    ) i_stream_arbiter_chiplet_dep_set (
        .clk_i      ( clk_i                                        ),
        .rst_ni     ( rst_ni                                       ),
        .inp_data_i ( stream_arbiter_chiplet_dep_set_inp_task_desc ),
        .inp_valid_i( stream_arbiter_chiplet_dep_set_inp_valid     ),
        .inp_ready_o( stream_arbiter_chiplet_dep_set_inp_ready     ),
        .oup_data_o ( stream_arbiter_chiplet_dep_set_oup_task_desc ),
        .oup_valid_o( stream_arbiter_chiplet_dep_set_oup_valid     ),
        .oup_ready_i( stream_arbiter_chiplet_dep_set_oup_ready     )
    );
    assign stream_arbiter_chiplet_dep_set_oup_ready = chiplet_dep_set_task_desc_ready;
    always_comb begin : compose_stream_arbiter_chiplet_dep_set_signals
        for (int unsigned cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].reserved_bits = '0;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].dep_set_info = checkout_queue_data_out[core][cluster].dep_set_info;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].dep_check_info = checkout_queue_data_out[core][cluster].dep_check_info;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].assigned_core_id = checkout_queue_data_out[core][cluster].assigned_core_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].assigned_cluster_id = checkout_queue_data_out[core][cluster].assigned_cluster_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].assigned_chiplet_id = checkout_queue_data_out[core][cluster].assigned_chiplet_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].task_id = checkout_queue_data_out[core][cluster].task_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].task_type = checkout_queue_data_out[core][cluster].task_type;
                stream_arbiter_chiplet_dep_set_inp_valid[core + cluster * NUM_CORES_PER_CLUSTER] = stream_demux_checkout_queue_chiplet_dep_set_oup_valid[core][cluster][1];
            end           
        end
    end


    //////////////////////////////////////////////////////////////////////
    // Chiplet from remote Done Queue
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_write_mailbox #(
        .MailboxDepth(ChipletDoneQueueDepth                    ),
        .IrqEdgeTrig (1'b0                                     ),
        .IrqActHigh  (1'b1                                     ),
        .AxiAddrWidth(HostAxiLiteAddrWidth                     ),
        .AxiDataWidth(HostAxiLiteDataWidth                     ),
        .ChipIdWidth (ChipIdWidth                              ),
        .req_lite_t  (host_axi_lite_req_t                      ),
        .resp_lite_t (host_axi_lite_resp_t                     )
    ) i_bingo_hw_manager_chiplet_done_queue (
        .clk_i       (clk_i                             ),
        .rst_ni      (rst_ni                            ),
        .chip_id_i   (chip_id_i                         ),
        .test_i      (1'b0                              ),
        .req_i       (from_remote_axi_lite_req_i        ),
        .resp_o      (from_remote_axi_lite_resp_o       ),
        .irq_o       (/*not used*/                      ),
        .base_addr_i (chiplet_mailbox_base_addr_i       ),
        .mbox_data_o (chiplet_done_queue_mbox_data      ),
        .mbox_pop_i  (chiplet_done_queue_mbox_pop       ),
        .mbox_empty_o(chiplet_done_queue_mbox_empty     ),
        .mbox_flush_i('0                                )
    );
    assign cur_chiplet_done_queue_task_desc = bingo_hw_manager_task_desc_full_t'(chiplet_done_queue_mbox_data);
    assign chiplet_done_queue_mbox_pop =  stream_arbiter_dep_matrix_set_inp_ready[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET] && !chiplet_done_queue_mbox_empty;
    //////////////////////////////////////////////////////////////////////
    // Stream demux core type
    //////////////////////////////////////////////////////////////////////
    stream_demux #(
        .N_OUP ( NUM_CORES_PER_CLUSTER           )
    ) i_stream_demux_core_type (
        .inp_valid_i ( stream_demux_core_type_inp_valid ),
        .inp_ready_o ( stream_demux_core_type_inp_ready ),
        .oup_sel_i   ( stream_demux_core_type_oup_sel   ),
        .oup_valid_o ( stream_demux_core_type_oup_valid ),
        .oup_ready_i ( stream_demux_core_type_oup_ready )
    );
    always_comb begin: compose_stream_demux_core_type_signals
        stream_demux_core_type_inp_valid = !task_queue_mbox_empty;
        stream_demux_core_type_oup_sel = cur_task_desc.assigned_core_id;
        for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            stream_demux_core_type_oup_ready[core] = !waiting_dep_check_queue_full[core];
        end
    end


    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_waiting_dep_check_queue
        fifo_v3 #(
            .FALL_THROUGH ( 1'b0                               ),
            .DEPTH        ( 8                                  ),
            .dtype        ( bingo_hw_manager_task_desc_t       )
        ) i_waiting_dep_check_queue (
            .clk_i       ( clk_i                               ),
            .rst_ni      ( rst_ni                              ),
            .testmode_i  ( 1'b0                                ),
            .flush_i     ( 1'b0                                ),
            .full_o      ( waiting_dep_check_queue_full[core]  ),
            .empty_o     ( waiting_dep_check_queue_empty[core] ),
            .usage_o     ( /*not used*/                        ),
            .data_i      ( cur_task_desc                       ),
            .push_i      ( waiting_dep_check_queue_push[core]  ),
            .data_o      ( waiting_dep_check_task_desc[core]   ),
            .pop_i       ( waiting_dep_check_queue_pop[core]   )
        );
        assign waiting_dep_check_queue_push[core] = stream_demux_core_type_oup_valid[core] && !waiting_dep_check_queue_full[core];
        assign waiting_dep_check_queue_pop[core] = dep_check_manager_inp_wait_dep_check_queue_ready[core] && !waiting_dep_check_queue_empty[core];

        bingo_hw_manager_dep_check_manager i_dep_check_manager(
            .clk_i                       ( clk_i                        ),
            .rst_ni                      ( rst_ni                       ),
            .wait_dep_check_queue_valid_i(dep_check_manager_inp_wait_dep_check_queue_valid[core]),
            .wait_dep_check_queue_ready_o(dep_check_manager_inp_wait_dep_check_queue_ready[core]),
            .dep_check_valid_o           (dep_check_manager_oup_dep_check_valid[core]),
            .dep_check_ready_i           (dep_check_manager_oup_dep_check_ready[core]),
            .ready_and_checkout_queue_valid_o(dep_check_manager_oup_ready_and_checkout_queue_valid[core]),
            .ready_and_checkout_queue_ready_i(dep_check_manager_oup_ready_and_checkout_queue_ready[core])
        );
        assign dep_check_manager_inp_wait_dep_check_queue_valid[core] = ~waiting_dep_check_queue_empty[core];
        // To Dep Matrix
        // For the dep matrix, if the dep check is disable, we do not need to send the task to dep matrix
        stream_filter i_stream_filter_dep_check_en_to_dep_matrix (
            .valid_i ( dep_check_manager_oup_dep_check_valid[core]    ),
            .ready_o ( dep_check_manager_oup_dep_check_ready[core]    ),
            .drop_i  ( (!waiting_dep_check_task_desc[core].dep_check_info.dep_check_en) ),
            .valid_o ( demux_dep_matrix_inp_valid[core]  ),
            .ready_i ( demux_dep_matrix_inp_ready[core]  )
        );
        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_from_waiting_dep_check_queue_to_dep_matrix (
            .inp_valid_i ( demux_dep_matrix_inp_valid[core]    ),
            .inp_ready_o ( demux_dep_matrix_inp_ready[core]    ),
            .oup_sel_i   ( waiting_dep_check_task_desc[core].assigned_cluster_id ),
            .oup_valid_o ( demux_dep_matrix_oup_valid[core]    ),
            .oup_ready_i ( demux_dep_matrix_oup_ready[core]    )
        );
        // To Ready Queue and Checkout Queue
        // We need a filter to drop the dummy check tasks
        // The dummy check does not need to go to the ready and checkout queue
        stream_filter i_stream_filter_dummy_check_task_to_ready_and_checkout_queue (
            .valid_i ( dep_check_manager_oup_ready_and_checkout_queue_valid[core]    ),
            .ready_o ( dep_check_manager_oup_ready_and_checkout_queue_ready[core]    ),
            .drop_i  ( (waiting_dep_check_task_desc[core].task_type) && (waiting_dep_check_task_desc[core].dep_check_info.dep_check_en) ), // Drop if it is a dummy check task
            .valid_o ( demux_ready_and_checkout_queue_inp_valid[core]  ),
            .ready_i ( demux_ready_and_checkout_queue_inp_ready[core]  )
        );
        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_from_waiting_dep_check_queue_to_ready_and_checkout_queue (
            .inp_valid_i ( demux_ready_and_checkout_queue_inp_valid[core]    ),
            .inp_ready_o ( demux_ready_and_checkout_queue_inp_ready[core]    ),
            .oup_sel_i   ( waiting_dep_check_task_desc[core].assigned_cluster_id ),
            .oup_valid_o ( demux_ready_and_checkout_queue_oup_valid[core]    ),
            .oup_ready_i ( demux_ready_and_checkout_queue_oup_ready[core]    )
        );

        always_comb begin : connect_demux_ready_and_checkout_queue_ready_signals
            for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin 
                demux_ready_and_checkout_queue_oup_ready[core][cluster] = ready_queue_filter_inp_ready[core][cluster] && !checkout_queue_full[core][cluster];
            end
        end
    end


    ////////////////////////////////////////////////////////////////////////
    // Dep Matrix
    //////////////////////////////////////////////////////////////////////

    for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_dep_matrix
        bingo_hw_manager_dep_matrix #(
            .DEP_MATRIX_ROWS(NUM_CORES_PER_CLUSTER),
            .DEP_MATRIX_COLS(NUM_CORES_PER_CLUSTER)
        ) i_dep_matrix (
            .clk_i             (clk_i                    ),
            .rst_ni            (rst_ni                   ),
            .dep_check_valid_i (dep_check_valid[cluster] ),
            .dep_check_code_i  (dep_check_code[cluster]  ),
            .dep_check_result_o(dep_check_result[cluster]),
            .dep_set_valid_i   (dep_set_valid[cluster]   ),
            .dep_set_ready_o   (dep_set_ready[cluster]   ),
            .dep_set_code_i    (dep_set_code[cluster]    )
        );
    end

    always_comb begin : connect_dep_check_for_dep_matrix
        for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                dep_check_valid[cluster][core] = demux_dep_matrix_oup_valid[core][cluster];
                demux_dep_matrix_oup_ready[core][cluster] = dep_check_result[cluster][core];
                dep_check_code[cluster][core] = waiting_dep_check_task_desc[core].dep_check_info.dep_check_code;
            end
        end
    end

    //////////////////////////////////////////////////////////////////////
    // Stream Arbiter Dep Matrix Set
    //////////////////////////////////////////////////////////////////////
    stream_arbiter #(
        .DATA_T(bingo_hw_manager_dep_matrix_set_meta_t),
        .N_INP (STREAM_ARBITER_DEP_MATRIX_SET_NUM_INP)
    ) i_stream_arbiter_dep_matrix_set(
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .inp_data_i (stream_arbiter_dep_matrix_set_inp_data ),
        .inp_valid_i(stream_arbiter_dep_matrix_set_inp_valid),
        .inp_ready_o(stream_arbiter_dep_matrix_set_inp_ready),
        .oup_data_o (stream_arbiter_dep_matrix_set_oup_data ),
        .oup_valid_o(stream_arbiter_dep_matrix_set_oup_valid),
        .oup_ready_i(stream_arbiter_dep_matrix_set_oup_ready)
    );
    always_comb begin : compose_stream_arbiter_dep_matrix_set_inputs
        // For Checkout Queue
        int stream_arbiter_inp_idx;
        for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                    stream_arbiter_inp_idx = core + cluster * NUM_CORES_PER_CLUSTER;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_id = checkout_queue_data_out[core][cluster].dep_set_info.dep_set_cluster_id;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_col= core;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_set_code  = checkout_queue_data_out[core][cluster].dep_set_info.dep_set_code;
                    // Handshake from the checkout demux and the done queue
                    // If the task is dummy set, it does not need to check the done queue
                    // If it is a normal dep set, it needs to check the done queue
                    stream_arbiter_dep_matrix_set_inp_valid[stream_arbiter_inp_idx] = (checkout_queue_data_out[core][cluster].task_type) ? 
                                                                                      stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster] :
                                                                                      ((stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster]) &&
                                                                                       (!done_queue_mbox_empty) &&
                                                                                       (cur_done_queue_info.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cluster)) &&
                                                                                       (cur_done_queue_info.assigned_core_id == bingo_hw_manager_assigned_core_id_t'(core)));
            end
        end
        // For Chiplet Set Queue
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_id  = cur_chiplet_done_queue_task_desc.dep_set_info.dep_set_cluster_id;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_col = cur_chiplet_done_queue_task_desc.assigned_core_id;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_set_code   = cur_chiplet_done_queue_task_desc.dep_set_info.dep_set_code;
        stream_arbiter_dep_matrix_set_inp_valid[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET] = !chiplet_done_queue_mbox_empty;
        stream_arbiter_dep_matrix_set_oup_ready = stream_demux_set_dep_matrix_cluster_id_inp_ready;
    end 
    //////////////////////////////////////////////////////////////////////
    // Stream Demux Set Dep Matrix Cluster ID
    //////////////////////////////////////////////////////////////////////
    stream_demux #(
        .N_OUP(NUM_CLUSTERS_PER_CHIPLET)
    ) i_stream_demux_set_dep_matrix_cluster_id (
        .inp_valid_i(stream_demux_set_dep_matrix_cluster_id_inp_valid),
        .inp_ready_o(stream_demux_set_dep_matrix_cluster_id_inp_ready),
        .oup_sel_i  (stream_demux_set_dep_matrix_cluster_id_oup_sel),
        .oup_valid_o(stream_demux_set_dep_matrix_cluster_id_oup_valid),
        .oup_ready_i(stream_demux_set_dep_matrix_cluster_id_oup_ready)
    );
    assign stream_demux_set_dep_matrix_cluster_id_inp_valid = stream_arbiter_dep_matrix_set_oup_valid;
    assign stream_demux_set_dep_matrix_cluster_id_oup_sel = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_id;

    //////////////////////////////////////////////////////////////////////
    // Stream Demux Set Dep Matrix Core ID
    //////////////////////////////////////////////////////////////////////
    for (genvar cluster= 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_set_dep_matrix_core_id
        stream_demux #(
            .N_OUP(NUM_CORES_PER_CLUSTER)
        ) i_stream_demux_set_dep_matrix_core_id (
            .inp_valid_i(stream_demux_set_dep_matrix_core_id_inp_valid[cluster]),
            .inp_ready_o(stream_demux_set_dep_matrix_core_id_inp_ready[cluster]),
            .oup_sel_i  (stream_demux_set_dep_matrix_core_id_oup_sel[cluster]  ),
            .oup_valid_o(stream_demux_set_dep_matrix_core_id_oup_valid[cluster]),
            .oup_ready_i(stream_demux_set_dep_matrix_core_id_oup_ready[cluster])
        );
        assign stream_demux_set_dep_matrix_cluster_id_oup_ready[cluster] = stream_demux_set_dep_matrix_core_id_inp_ready[cluster];
        assign stream_demux_set_dep_matrix_core_id_inp_valid[cluster] = stream_demux_set_dep_matrix_cluster_id_oup_valid[cluster];
        assign stream_demux_set_dep_matrix_core_id_oup_sel[cluster] = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_col;
    end

    always_comb begin : connect_dep_set_for_dep_matrix
        for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                dep_set_valid[cluster][core] = stream_demux_set_dep_matrix_core_id_oup_valid[cluster][core];
                stream_demux_set_dep_matrix_core_id_oup_ready[cluster][core] = dep_set_ready[cluster][core];
                dep_set_code[cluster][core] = stream_arbiter_dep_matrix_set_oup_data.dep_set_code;
            end
        end        
    end

    //////////////////////////////////////////////////////////////////////
    // Ready Queue
    //////////////////////////////////////////////////////////////////////
    // This is the ready queue interface
    // Device will read ready tasks info from this queue via 32bit AXI Lite
    // The information contains only task ID
    // Before each ready queue, there is a filter to filter out the dummy set tasks since it will not be run on the core
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_ready_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_ready_queue_per_core_per_cluster
            stream_filter i_stream_filter_for_ready_queue_dummy_set (
                .valid_i (   ready_queue_filter_inp_valid[core][cluster]       ),
                .ready_o (   ready_queue_filter_inp_ready[core][cluster]       ),
                .drop_i  (   ready_queue_filter_drop[core][cluster]            ),
                .valid_o (   ready_queue_filter_oup_valid[core][cluster]       ),
                .ready_i (   ready_queue_filter_oup_ready[core][cluster]       )
            );
            assign ready_queue_filter_inp_valid[core][cluster] = demux_ready_and_checkout_queue_oup_valid[core][cluster];
            // Drop the dummy set tasks
            assign ready_queue_filter_drop[core][cluster] = (waiting_dep_check_task_desc[core].task_type) && 
                                                                        (waiting_dep_check_task_desc[core].dep_set_info.dep_set_en == 1'b1);
            assign ready_queue_filter_oup_ready[core][cluster] = ~ready_queue_full[core][cluster];
            if (READY_AND_DONE_QUEUE_INTERFACE_TYPE==0) begin: gen_ready_queue_axi_lite_mailbox                               
                bingo_hw_manager_read_mailbox #(
                    .MailboxDepth(ReadyQueueDepth                ),
                    .IrqEdgeTrig (1'b0                           ),
                    .IrqActHigh  (1'b1                           ),
                    .AxiAddrWidth(DeviceAxiLiteAddrWidth         ),
                    .AxiDataWidth(DeviceAxiLiteDataWidth         ),
                    .ChipIdWidth (ChipIdWidth                    ),
                    .req_lite_t  (device_axi_lite_req_t          ),
                    .resp_lite_t (device_axi_lite_resp_t         )
                ) i_bingo_hw_manager_ready_queue (
                    .clk_i       (clk_i                                                        ),
                    .rst_ni      (rst_ni                                                       ),
                    .chip_id_i   (chip_id_i                                                    ),
                    .test_i      (1'b0                                                         ),
                    .req_i       (ready_queue_axi_lite_req_i[core][cluster]                    ),
                    .resp_o      (ready_queue_axi_lite_resp_o[core][cluster]                   ),
                    .irq_o       (/*not used*/                                                 ),
                    .base_addr_i (ready_queue_base_addr[core][cluster]                         ),
                    .mbox_data_i (ready_queue_data_in[core][cluster]                           ),
                    .mbox_push_i (ready_queue_push[core][cluster]                              ),
                    .mbox_full_o (ready_queue_full[core][cluster]                              ),
                    .mbox_flush_i(1'b0                                                         )
                );
                // Tie off the generic fifo read signals
                assign ready_queue_pop[core][cluster] = 1'b0;
                assign ready_queue_empty[core][cluster] = 1'b0;
                assign ready_queue_data_out[core][cluster] = '0;
            end else begin: gen_ready_queue_generic_fifo
                fifo_v3 #(
                    .FALL_THROUGH ( 1'b0                                      ),
                    .DEPTH        ( ReadyQueueDepth                           ),
                    .dtype        ( bingo_hw_manager_ready_task_desc_full_t   )
                ) i_ready_queue (
                    .clk_i       ( clk_i                                  ),
                    .rst_ni      ( rst_ni                                 ),
                    .testmode_i  ( 1'b0                                   ),
                    .flush_i     ( 1'b0                                   ),
                    .full_o      ( ready_queue_full[core][cluster]        ),
                    .empty_o     ( ready_queue_empty[core][cluster]       ),
                    .usage_o     ( /*not used*/                           ),
                    .data_i      ( ready_queue_data_in[core][cluster]     ),
                    .push_i      ( ready_queue_push[core][cluster]        ),
                    .data_o      ( ready_queue_data_out[core][cluster]    ),
                    .pop_i       ( ready_queue_pop[core][cluster]         )
                );
                // Since we do not have the axi lite interface, we tie off the ready queue axi lite resp signals
                assign ready_queue_axi_lite_resp_o[core][cluster] = '0;
            end
            assign ready_queue_base_addr[core][cluster] = ready_queue_base_addr_i +
                                                        (core + cluster * NUM_CORES_PER_CLUSTER) * ReadyQueueAddrOffset;
            assign ready_queue_data_in[core][cluster].task_id = waiting_dep_check_task_desc[core].task_id;
            assign ready_queue_data_in[core][cluster].reserved_bits = '0;
            assign ready_queue_push[core][cluster] = ready_queue_filter_oup_valid[core][cluster] & ~ready_queue_full[core][cluster];
        end
    end


    //////////////////////////////////////////////////////////////////////
    // Checkout Queue
    //////////////////////////////////////////////////////////////////////
    // Check out queues are internal fifos
    // input is from the waiting dep check queue
    // after it has been checked by the dep matrix, it will be pushed to the checkout queue
    // and then wait the done queue to pop it
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_checkout_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_checkout_queue_per_core_per_cluster
            fifo_v3 #(
                .FALL_THROUGH ( 1'b0                                  ),
                .DEPTH        ( CheckoutQueueDepth                    ),
                .dtype        ( bingo_hw_manager_task_desc_t          )
            ) i_checkout_queue (
                .clk_i       ( clk_i                                  ),
                .rst_ni      ( rst_ni                                 ),
                .testmode_i  ( 1'b0                                   ),
                .flush_i     ( 1'b0                                   ),
                .full_o      ( checkout_queue_full[core][cluster]     ),
                .empty_o     ( checkout_queue_empty[core][cluster]    ),
                .usage_o     ( /*not used*/                           ),
                .data_i      ( checkout_queue_data_in[core][cluster]  ),
                .push_i      ( checkout_queue_push[core][cluster]     ),
                .data_o      ( checkout_queue_data_out[core][cluster] ),
                .pop_i       ( checkout_queue_pop[core][cluster]      )
            );
            assign checkout_queue_data_in[core][cluster] = waiting_dep_check_task_desc[core];
            assign checkout_queue_push[core][cluster] = demux_ready_and_checkout_queue_oup_valid[core][cluster] && !checkout_queue_full[core][cluster];
            assign checkout_queue_pop[core][cluster] = stream_demux_checkout_queue_chiplet_dep_set_inp_ready[core][cluster] && !checkout_queue_empty[core][cluster];

            stream_demux #(
                .N_OUP ( 2 )
            ) i_stream_demux_checkout_queue_chiplet_dep_set (
                .inp_valid_i ( stream_demux_checkout_queue_chiplet_dep_set_inp_valid[core][cluster]    ),
                .inp_ready_o ( stream_demux_checkout_queue_chiplet_dep_set_inp_ready[core][cluster]    ),
                .oup_sel_i   ( stream_demux_checkout_queue_chiplet_dep_set_oup_sel[core][cluster]      ),
                .oup_valid_o ( stream_demux_checkout_queue_chiplet_dep_set_oup_valid[core][cluster]    ),
                .oup_ready_i ( stream_demux_checkout_queue_chiplet_dep_set_oup_ready[core][cluster]    )
            );

            assign stream_demux_checkout_queue_chiplet_dep_set_inp_valid[core][cluster] = !checkout_queue_empty[core][cluster];
            assign stream_demux_checkout_queue_chiplet_dep_set_oup_sel[core][cluster] = 
                (checkout_queue_data_out[core][cluster].dep_set_info.dep_set_chiplet_id != chip_id_i);
            // To Chiplet Dep Set
            assign stream_demux_checkout_queue_chiplet_dep_set_oup_ready[core][cluster][1] = stream_arbiter_chiplet_dep_set_inp_ready[core + cluster * NUM_CORES_PER_CLUSTER];
            // To Local Dep Set
            assign stream_demux_checkout_queue_chiplet_dep_set_oup_ready[core][cluster][0] = stream_filter_checkout_queue_dep_set_enable_inp_ready[core][cluster];

            stream_filter i_stream_filter_checkout_queue_dep_set_enable (
                .valid_i ( stream_filter_checkout_queue_dep_set_enable_inp_valid[core][cluster]    ),
                .ready_o ( stream_filter_checkout_queue_dep_set_enable_inp_ready[core][cluster]    ),
                .drop_i  ( stream_filter_checkout_queue_dep_set_enable_drop[core][cluster]         ),
                .valid_o ( stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster]    ),
                .ready_i ( stream_filter_checkout_queue_dep_set_enable_oup_ready[core][cluster]    )
            );
            assign stream_filter_checkout_queue_dep_set_enable_inp_valid[core][cluster] = stream_demux_checkout_queue_chiplet_dep_set_oup_valid[core][cluster][0];
            // Only drop the signal when dep set is disabled and the done queue matches this core and cluster
            assign stream_filter_checkout_queue_dep_set_enable_drop[core][cluster] = 
                (checkout_queue_data_out[core][cluster].dep_set_info.dep_set_en == 1'b0) &&
                (!done_queue_mbox_empty) &&
                (cur_done_queue_info.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cluster)) &&
                (cur_done_queue_info.assigned_core_id == bingo_hw_manager_assigned_core_id_t'(core));
            assign stream_filter_checkout_queue_dep_set_enable_oup_ready[core][cluster] = stream_arbiter_dep_matrix_set_inp_ready[core + cluster * NUM_CORES_PER_CLUSTER];

        end
    end

    //////////////////////////////////////////////////////////////////////
    // Local Done Queue
    //////////////////////////////////////////////////////////////////////
    // This is the done queue interface
    // Device will writes completed tasks info to this queue via 32bit AXI Lite
    // The information contains task ID, cluster id and core id
    if (READY_AND_DONE_QUEUE_INTERFACE_TYPE==0) begin: gen_done_queue_axi_lite_mailbox
        bingo_hw_manager_write_mailbox #(
            .MailboxDepth(DoneQueueDepth               ),
            .IrqEdgeTrig (1'b0                         ),
            .IrqActHigh  (1'b1                         ),
            .AxiAddrWidth(DeviceAxiLiteAddrWidth       ),
            .AxiDataWidth(DeviceAxiLiteDataWidth       ),
            .ChipIdWidth (ChipIdWidth                  ),
            .req_lite_t  (device_axi_lite_req_t        ),
            .resp_lite_t (device_axi_lite_resp_t       )
        ) i_bingo_hw_manager_done_queue (
            .clk_i       (clk_i                     ),
            .rst_ni      (rst_ni                    ),
            .chip_id_i   (chip_id_i                 ),
            .test_i      (1'b0                      ),
            .req_i       (done_queue_axi_lite_req_i ),
            .resp_o      (done_queue_axi_lite_resp_o),
            .irq_o       (),
            .base_addr_i (done_queue_base_addr_i    ),
            .mbox_data_o (done_queue_mbox_data      ),
            .mbox_pop_i  (done_queue_mbox_pop       ),
            .mbox_empty_o(done_queue_mbox_empty     ),
            .mbox_flush_i(1'b0)
        );
        // Tie off the generic fifo write signals
        assign done_queue_mbox_push = 1'b0;
        assign done_queue_mbox_data_in = '0;
        assign done_queue_mbox_full = 1'b0;
    end else begin: gen_done_queue_generic_fifo
        fifo_v3 #(
            .FALL_THROUGH ( 1'b0                               ),
            .DEPTH        ( DoneQueueDepth                     ),
            .dtype        ( bingo_hw_manager_done_info_full_t  )
        ) i_done_queue (
            .clk_i       ( clk_i                               ),
            .rst_ni      ( rst_ni                              ),
            .testmode_i  ( 1'b0                                ),
            .flush_i     ( 1'b0                                ),
            .full_o      ( done_queue_mbox_full                ),
            .empty_o     ( done_queue_mbox_empty               ),
            .usage_o     ( /*not used*/                        ),
            .data_i      ( done_queue_mbox_data_in             ),
            .push_i      ( done_queue_mbox_push                ),
            .data_o      ( done_queue_mbox_data                ),
            .pop_i       ( done_queue_mbox_pop                 )
        );
        // Since we do not have the axi lite interface, we tie off the done queue axi lite resp signals
        assign done_queue_axi_lite_resp_o = '0;
    end
    assign cur_done_queue_info = bingo_hw_manager_done_info_full_t'(done_queue_mbox_data);
    // Pop the done queue when
    // there is a normal task at the head of the checkout queue
    // and the dep set is done
    assign done_queue_mbox_pop = !done_queue_mbox_empty &&
                                 (checkout_queue_data_out[cur_done_queue_info.assigned_core_id][cur_done_queue_info.assigned_cluster_id].task_type==1'b0) &&
                                 (stream_arbiter_dep_matrix_set_inp_ready[cur_done_queue_info.assigned_core_id + cur_done_queue_info.assigned_cluster_id * NUM_CORES_PER_CLUSTER]);

    // For generic FIFO done queue, we need to connect the CSR interface signals
    if (READY_AND_DONE_QUEUE_INTERFACE_TYPE==1) begin: gen_csr_to_fifo_intf
        localparam N_CORES_TOTAL = NUM_CLUSTERS_PER_CHIPLET * NUM_CORES_PER_CLUSTER;
        // 1D CSR Requests
        csr_req_t [N_CORES_TOTAL-1:0] csr_req_1d;
        logic     [N_CORES_TOTAL-1:0] csr_req_valid_1d;
        logic     [N_CORES_TOTAL-1:0] csr_req_ready_1d;
        csr_rsp_t [N_CORES_TOTAL-1:0] csr_rsp_1d;
        logic     [N_CORES_TOTAL-1:0] csr_rsp_valid_1d;
        logic     [N_CORES_TOTAL-1:0] csr_rsp_ready_1d;
        // 1D Ready Queue FIFO Interface
        device_axi_lite_data_t [N_CORES_TOTAL-1:0] read_ready_queue_data_1d;
        logic                  [N_CORES_TOTAL-1:0] read_ready_queue_valid_1d;
        logic                  [N_CORES_TOTAL-1:0] read_ready_queue_ready_1d;
        // 1D Done QUeue FIFO Interface
        device_axi_lite_data_t [N_CORES_TOTAL-1:0] write_done_queue_data_1d;
        logic                  [N_CORES_TOTAL-1:0] write_done_queue_valid_1d;
        logic                  [N_CORES_TOTAL-1:0] write_done_queue_ready_1d;
        device_axi_lite_data_t write_done_queue_data;
        logic                  write_done_queue_valid;
        logic                  write_done_queue_ready;


        bingo_hw_manager_csr_to_fifo #(
            .TaskIdWidth (TaskIdWidth),
            .N (N_CORES_TOTAL),
            .NUM_CORES_PER_CLUSTER (NUM_CORES_PER_CLUSTER),
            .NUM_CLUSTERS_PER_CHIPLET (NUM_CLUSTERS_PER_CHIPLET),
            .csr_req_t (csr_req_t),
            .csr_rsp_t (csr_rsp_t),
            .data_t    (device_axi_lite_data_t),
            .bingo_hw_manager_done_info_full_t (bingo_hw_manager_done_info_full_t)
        ) i_bingo_hw_manager_csr_to_fifo (
            .csr_req_i         (csr_req_1d               ),
            .csr_req_valid_i   (csr_req_valid_1d         ),
            .csr_req_ready_o   (csr_req_ready_1d         ),
            .csr_rsp_o         (csr_rsp_1d               ),
            .csr_rsp_valid_o   (csr_rsp_valid_1d         ),
            .csr_rsp_ready_i   (csr_rsp_ready_1d         ),
            // FIFO Read Interface
            .fifo_data_i       (read_ready_queue_data_1d ),
            .fifo_data_valid_i (read_ready_queue_valid_1d),
            .fifo_data_ready_o (read_ready_queue_ready_1d),
            // FIFO Write Interface
            .fifo_data_o       (write_done_queue_data_1d ),
            .fifo_data_valid_o (write_done_queue_valid_1d),
            .fifo_data_ready_i (write_done_queue_ready_1d)
        );
        always_comb begin : connect_ready_queue_1d_to_2d
            for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                for (int unsigned cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                    csr_req_1d[core + cluster * NUM_CORES_PER_CLUSTER] = csr_req_i[core][cluster];
                    csr_req_valid_1d[core + cluster * NUM_CORES_PER_CLUSTER] = csr_req_valid_i[core][cluster];
                    csr_req_ready_o[core][cluster] = csr_req_ready_1d[core + cluster * NUM_CORES_PER_CLUSTER];
                    csr_rsp_o[core][cluster] = csr_rsp_1d[core + cluster * NUM_CORES_PER_CLUSTER];
                    csr_rsp_valid_o[core][cluster] = csr_rsp_valid_1d[core + cluster * NUM_CORES_PER_CLUSTER];
                    csr_rsp_ready_1d[core + cluster * NUM_CORES_PER_CLUSTER] = csr_rsp_ready_i[core][cluster];
                    read_ready_queue_data_1d[core + cluster * NUM_CORES_PER_CLUSTER] = device_axi_lite_data_t'(ready_queue_data_out[core][cluster]);
                    read_ready_queue_valid_1d[core + cluster * NUM_CORES_PER_CLUSTER] = !ready_queue_empty[core][cluster];
                    ready_queue_pop[core][cluster] = read_ready_queue_ready_1d[core + cluster * NUM_CORES_PER_CLUSTER] && !ready_queue_empty[core][cluster];
                end
            end
        end

        // For the Done Queue, we need a arbiter to arbitrate the write requests from all cores to one done queue
        stream_arbiter #(
            .DATA_T(device_axi_lite_data_t),
            .N_INP (N_CORES_TOTAL)
        ) i_stream_arbiter_done_queue_write (
            .clk_i      (clk_i),
            .rst_ni     (rst_ni),
            .inp_data_i (write_done_queue_data_1d),
            .inp_valid_i(write_done_queue_valid_1d),
            .inp_ready_o(write_done_queue_ready_1d),
            .oup_data_o (write_done_queue_data),
            .oup_valid_o(write_done_queue_valid),
            .oup_ready_i(write_done_queue_ready)
        );
        assign done_queue_mbox_data_in = write_done_queue_data;
        assign done_queue_mbox_push = write_done_queue_valid && !done_queue_mbox_full;
        assign write_done_queue_ready = !done_queue_mbox_full;


    end else begin: gen_no_csr_to_fifo_intf
        // If it is AXI Lite Mailbox interface, the ready queue and done queue interface are already connected
        // So we do not need to do anything here
        // Tie the csr signals to zero
        assign csr_req_ready_o = '0;
        assign csr_rsp_o = '0;
        assign csr_rsp_valid_o = '0;
    end



endmodule