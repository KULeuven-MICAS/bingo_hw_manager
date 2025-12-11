// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>
module bingo_hw_manager_top #(
    // Top-level parameters can be defined here
    parameter int unsigned NUM_CHIPLET = 4,
    parameter int unsigned NUM_CORES_PER_CLUSTER = 4,
    parameter int unsigned NUM_CLUSTERS_PER_CHIPLET = 2,
    parameter int unsigned ChipIdWidth = 8,
    // AXI interface types
    // The task queue holds tasks to be scheduled to the devices
    // Host writes the task queue via 64bit AXI Lite
    parameter int unsigned HostAxiLiteAddrWidth = 48,
    parameter int unsigned HostAxiLiteDataWidth = 64,
    parameter int unsigned TaskQueueDepth = 32,
    parameter type task_queue_axi_lite_in_req_t = logic,
    parameter type task_queue_axi_lite_in_resp_t = logic,
    // The H2H chiplet done queue holds the completed tasks info from other chiplets
    parameter int unsigned H2HDoneQueueDepth = 32,
    parameter type h2h_axi_lite_in_req_t = logic,
    parameter type h2h_axi_lite_in_resp_t = logic,
    // The chiplet done issue interface to other chiplets
    parameter type h2h_axi_lite_out_req_t = logic,
    parameter type h2h_axi_lite_out_resp_t = logic,
    // The done queue holds the completed tasks info from the devices
    // Device writes the done queue via 32bit AXI Lite
    parameter int unsigned DeviceAxiLiteAddrWidth = 48,
    parameter int unsigned DeviceAxiLiteDataWidth = 32,
    parameter int unsigned DoneQueueDepth = 32,
    parameter type done_queue_axi_lite_in_req_t = logic,
    parameter type done_queue_axi_lite_in_resp_t = logic,
    parameter int unsigned ReadyQueueDepth = 8,
    parameter type ready_queue_axi_lite_in_req_t = logic,
    parameter type ready_queue_axi_lite_in_resp_t = logic,
    // Dependent parameters, DO NOT OVERRIDE!
    parameter type chip_id_t = logic [ChipIdWidth-1:0],
    parameter type host_axi_lite_addr_t = logic [HostAxiLiteAddrWidth-1:0],
    parameter type device_axi_lite_addr_t = logic [DeviceAxiLiteAddrWidth-1:0]
) (
    /// Clock
    input logic clk_i,
    /// Asynchronous reset, active low
    input logic rst_ni,
    /// Chip ID for multi-chip addressing
    input chip_id_t chip_id_i,

    /// Interface to the system
    // Host -----> Task Queue
    // The task queue interface from the host
    // Here this queue holds all the tasks to be scheduled to the devices
    // The host core will write tasks into this queue via 64bit AXI Lite
    input  host_axi_lite_addr_t                 task_queue_base_addr_i,
    input  task_queue_axi_lite_in_req_t         task_queue_axi_lite_req_i,
    output task_queue_axi_lite_in_resp_t        task_queue_axi_lite_resp_o,
    // The chiplet set interface to other chiplets
    // HW Manager -----> Other chiplets
    input  host_axi_lite_addr_t                 h2h_mailbox_base_addr_i,
    output h2h_axi_lite_out_req_t               h2h_to_remote_axi_lite_req_o,
    input  h2h_axi_lite_out_resp_t              h2h_to_remote_axi_lite_resp_i,
    // The chiplet done interface from other chiplets
    input  h2h_axi_lite_in_req_t                h2h_from_remote_axi_lite_req_i,
    output h2h_axi_lite_in_resp_t               h2h_from_remote_axi_lite_resp_o,

    // The done queue interface to the devices
    // Devices -----> Done Queue
    // Here this queue holds all the completed tasks info from the devices
    // The device cores will write completed tasks into this queue via 32bit AXI Lite
    input  device_axi_lite_addr_t               done_queue_base_addr_i,
    input  done_queue_axi_lite_in_req_t         done_queue_axi_lite_req_i,
    output done_queue_axi_lite_in_resp_t        done_queue_axi_lite_resp_o,

    // The ready queue interface to the devices
    // HW scheduler -----> Ready Queue
    // Here the ready queue holds the tasks that are ready to be executed by the devices
    // The device cores will read tasks from this queue via 32bit AXI Lite
    // Each core has its own ready queue interface
    input  device_axi_lite_addr_t            [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_base_addr_i,
    input  ready_queue_axi_lite_in_req_t     [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_req_i,
    output ready_queue_axi_lite_in_resp_t    [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_resp_o

);
    // --------Type definitions and signal declarations--------------------//
    // ---- Start of Type definitions -------------------------------------//
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
        logic [2:0]                                  num_dep_set;
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
        logic [2:0]                                     num_dep_set;
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

    //----- End of Type definitions ------------------------------------//

    //----- Start of Signal declarations -------------------------------//
    /////////////////////////////////////////////////////////
    // Task Queue Signals
    /////////////////////////////////////////////////////////
    // The task queue holds the tasks to be scheduled to the devices
    bingo_hw_manager_task_desc_full_t  cur_task_desc;
    logic [HostAxiLiteDataWidth-1:0]   task_queue_mbox_data;
    logic                              task_queue_mbox_empty;
    logic                              task_queue_mbox_pop;

    /////////////////////////////////////////////////////////
    // Stream demux chiplet set task
    /////////////////////////////////////////////////////////
    // This demux is right behind the task queue
    // It will check the taks_type==2'b11 to decide whether it is a chiplet dep set task
    // It will block the task queue until the chiplet dep set task is finished
    // This blocking design is to ensure the ordering of the chiplet dep set tasks
    // [0]: Normal, Dummy, H2H Dep Check
    // [1]: task_type == 2'b11 path (H2H Dep Set)
    logic       stream_demux_is_chiplet_dep_set_task_inp_valid;
    logic       stream_demux_is_chiplet_dep_set_task_inp_ready;
    logic       stream_demux_is_chiplet_dep_set_task_oup_sel;
    logic [1:0] stream_demux_is_chiplet_dep_set_task_oup_valid;
    logic [1:0] stream_demux_is_chiplet_dep_set_task_oup_ready;

    /////////////////////////////////////////////////////////
    // H2H Dep Set
    /////////////////////////////////////////////////////////
    // This module is to send the h2h chiplet done signal to other chiplets
    // It will receive the chiplet dep set task from the task queue demux
    // and then write the h2h mailbox with the current task's taskid to other chiplets
    bingo_hw_manager_task_desc_full_t h2h_dep_set_task_desc;
    logic                             h2h_dep_set_task_desc_valid;
    logic                             h2h_dep_set_task_desc_ready;

    /////////////////////////////////////////////////////////
    // Stream demux chiplet dep check
    /////////////////////////////////////////////////////////
    // This demux is to check the chiplet dep matrix
    // After checking, the dummy task will be poped so the later task can proceed
    // [0]: Normal, Dummy
    // [1]: task_type == 2'b10 path (H2H Dep Check)
    logic       stream_demux_is_chiplet_dep_check_task_inp_valid;
    logic       stream_demux_is_chiplet_dep_check_task_inp_ready;
    logic       stream_demux_is_chiplet_dep_check_task_oup_sel;
    logic [1:0] stream_demux_is_chiplet_dep_check_task_oup_valid;
    logic [1:0] stream_demux_is_chiplet_dep_check_task_oup_ready;

    //////////////////////////////////////////////////////////
    // H2H Done Queue signals
    //////////////////////////////////////////////////////////
    logic [HostAxiLiteDataWidth-1:0]   h2h_chiplet_done_queue_mbox_data;
    logic                              h2h_chiplet_done_queue_mbox_empty;
    logic                              h2h_chiplet_done_queue_mbox_pop;

    //////////////////////////////////////////////////////////
    // H2H Dep Check sum signals
    //////////////////////////////////////////////////////////
    logic                   dep_check_sum_valid;
    logic                   dep_check_sum_ready;
    logic [ChipIdWidth-1:0] dep_check_sum;
    logic                   dep_set_sum_valid;
    logic                   dep_set_sum_ready;


    /////////////////////////////////////////////////////////
    // Stream demux core type
    /////////////////////////////////////////////////////////
    logic                                           stream_demux_core_type_inp_valid;
    logic                                           stream_demux_core_type_inp_ready;
    logic [$clog2(NUM_CORES_PER_CLUSTER)-1:0]       stream_demux_core_type_oup_sel;
    logic [NUM_CORES_PER_CLUSTER-1:0]               stream_demux_core_type_oup_valid;
    logic [NUM_CORES_PER_CLUSTER-1:0]               stream_demux_core_type_oup_ready;

    ///////////////////////////////////
    // Waiting dep check queue signals
    ///////////////////////////////////
    bingo_hw_manager_task_desc_full_t [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_task_desc;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_push;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_full;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_empty;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] waiting_dep_check_queue_pop;


    //////////////////////////////////
    // is_dummy_set task demux signals
    //////////////////////////////////
    // Here we need to demux the is_dummy_set signal to two outputs
    // Each core type has its own demux

    typedef logic [1:0]                               is_dummy_set_task_demux_oup_t;
    typedef logic [$clog2(NUM_CORES_PER_CLUSTER)-1:0] is_dummy_set_task_demux_oup_sel_t;
    logic                                [NUM_CORES_PER_CLUSTER-1:0]         is_dummy_set_task_demux_inp_valid;
    logic                                [NUM_CORES_PER_CLUSTER-1:0]         is_dummy_set_task_demux_inp_ready;
    is_dummy_set_task_demux_oup_sel_t    [NUM_CORES_PER_CLUSTER-1:0]         is_dummy_set_task_demux_oup_sel;
    is_dummy_set_task_demux_oup_t        [NUM_CORES_PER_CLUSTER-1:0]         is_dummy_set_task_demux_oup_valid;
    is_dummy_set_task_demux_oup_t        [NUM_CORES_PER_CLUSTER-1:0]         is_dummy_set_task_demux_oup_ready;

    /////////////////////////////////
    // dummy_set_cluster_id demux signals
    //////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0]         dummy_set_cluster_id_demux_oup_t;
    typedef logic [$clog2(NUM_CLUSTERS_PER_CHIPLET)-1:0] dummy_set_cluster_id_demux_oup_sel_t;
    logic                                 [NUM_CORES_PER_CLUSTER-1:0] dummy_set_task_demux_inp_valid;
    logic                                 [NUM_CORES_PER_CLUSTER-1:0] dummy_set_task_demux_inp_ready;
    dummy_set_cluster_id_demux_oup_sel_t  [NUM_CORES_PER_CLUSTER-1:0] dummy_set_task_demux_oup_sel;
    dummy_set_cluster_id_demux_oup_t      [NUM_CORES_PER_CLUSTER-1:0] dummy_set_task_demux_oup_valid;
    dummy_set_cluster_id_demux_oup_t      [NUM_CORES_PER_CLUSTER-1:0] dummy_set_task_demux_oup_ready;

    ////////////////////////////////
    // Stream fork signals
    ////////////////////////////////
    typedef logic [2:0] stream_fork_oup_t;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] stream_fork_inp_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] stream_fork_inp_ready;
    stream_fork_oup_t                 [NUM_CORES_PER_CLUSTER-1:0] stream_fork_oup_valid;
    stream_fork_oup_t                 [NUM_CORES_PER_CLUSTER-1:0] stream_fork_oup_ready;


    ////////////////////////////////
    // Stream demux dep check cluster id
    ////////////////////////////////
    // We only need the sel signal here
    typedef logic [$clog2(NUM_CLUSTERS_PER_CHIPLET)-1:0] dep_check_cluster_id_demux_oup_sel_t;
    dep_check_cluster_id_demux_oup_sel_t [NUM_CORES_PER_CLUSTER-1:0] dep_check_cluster_id_demux_oup_sel;
    ////////////////////////////////
    // dep matrix demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] dep_matrix_demux_oup_t;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_inp_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_inp_ready;
    dep_matrix_demux_oup_t            [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_oup_valid;
    dep_matrix_demux_oup_t            [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_oup_ready;

    ////////////////////////////////
    // ready queue demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_demux_oup_t;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_ready_queue_inp_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_ready_queue_inp_ready;
    ready_queue_demux_oup_t           [NUM_CORES_PER_CLUSTER-1:0] demux_ready_queue_oup_valid;
    ready_queue_demux_oup_t           [NUM_CORES_PER_CLUSTER-1:0] demux_ready_queue_oup_ready;

    ////////////////////////////////
    // checkout queue demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_demux_oup_t;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_checkout_queue_inp_valid;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] demux_checkout_queue_inp_ready;
    checkout_queue_demux_oup_t        [NUM_CORES_PER_CLUSTER-1:0] demux_checkout_queue_oup_valid;
    checkout_queue_demux_oup_t        [NUM_CORES_PER_CLUSTER-1:0] demux_checkout_queue_oup_ready;


    //////////////////////
    // Dep matrix signals
    //////////////////////
    typedef logic [NUM_CORES_PER_CLUSTER-1:0] dep_check_code_t;
    typedef logic [NUM_CORES_PER_CLUSTER-1:0] dep_set_code_t;

    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_check_valid;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_check_result;
    dep_check_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] dep_check_code;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_set_valid;
    dep_set_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]   dep_set_code;

    //////////////////////
    // Ready queue signals
    //////////////////////
    // Ready task info
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

    bingo_hw_manager_ready_task_desc_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_task_desc;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_push;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_full;

    //////////////////////
    // Checkout queue signals
    //////////////////////

    typedef struct packed{
        bingo_hw_manager_task_id_t           task_id;
        bingo_hw_manager_dep_set_info_t      dep_set_info;
    } bingo_hw_manager_checkout_task_desc_t;

    bingo_hw_manager_checkout_task_desc_t   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_data_out;
    bingo_hw_manager_checkout_task_desc_t   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_data_in;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_push;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_full;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_queue_empty;

    /////////////////////////
    // Checkout filter signals
    /////////////////////////
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_filter_inp_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_filter_inp_ready;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_filter_oup_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] checkout_filter_oup_ready;


    /////////////////////////
    // Dep Set Mux signals
    /////////////////////////
    bingo_hw_manager_dep_code_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_set_code_mux_oup_data;
    logic                       [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_set_code_mux_oup_valid;
    logic                       [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_set_code_mux_oup_ready;


    //////////////////////
    // Done queue signals
    //////////////////////

    // Done info struct

    typedef struct packed{

        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_t           assigned_core_id;
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
        bingo_hw_manager_assigned_core_t           assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_full_t;

    // Done Queue signals
    bingo_hw_manager_done_info_full_t    cur_done_queue_info;
    logic [DeviceAxiLiteDataWidth-1:0]   done_queue_mbox_data;
    logic                                done_queue_mbox_pop;
    logic                                done_queue_mbox_empty;

    // Done queue first demux signal
    typedef logic [NUM_CORES_PER_CLUSTER-1:0] done_queue_coreid_demux_oup_t;
    logic                               stream_demux_from_done_queue_to_checkout_queue_coreid_inp_valid;
    logic                               stream_demux_from_done_queue_to_checkout_queue_coreid_inp_ready;
    done_queue_coreid_demux_oup_t       stream_demux_from_done_queue_to_checkout_queue_coreid_oup_valid;
    done_queue_coreid_demux_oup_t       stream_demux_from_done_queue_to_checkout_queue_coreid_oup_ready;


    // Done queue second stage demux signal
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] done_queue_clusterid_demux_oup_t;
    logic                            [NUM_CORES_PER_CLUSTER-1:0] stream_demux_from_done_queue_to_checkout_queue_clusterid_inp_valid;
    logic                            [NUM_CORES_PER_CLUSTER-1:0] stream_demux_from_done_queue_to_checkout_queue_clusterid_inp_ready;
    done_queue_clusterid_demux_oup_t [NUM_CORES_PER_CLUSTER-1:0] stream_demux_from_done_queue_to_checkout_queue_clusterid_oup_valid;
    // --------Finish Type definitions and signal declarations--------------------//

    // --------Module initializations---------------------------------------------//

    //////////////////////////////////////////////////////////////////////
    // Task Queue
    /////////////////////////////////////////////////////////////////////
    bingo_hw_manager_write_mailbox #(
        .MailboxDepth(TaskQueueDepth               ),
        .IrqEdgeTrig (1'b0                         ),
        .IrqActHigh  (1'b1                         ),
        .AxiAddrWidth(HostAxiLiteAddrWidth         ),
        .AxiDataWidth(HostAxiLiteDataWidth         ),
        .ChipIdWidth (ChipIdWidth                  ),
        .req_lite_t  (task_queue_axi_lite_in_req_t ),
        .resp_lite_t (task_queue_axi_lite_in_resp_t)
    ) i_bingo_hw_manager_task_queue (
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
    always_comb begin : compose_task_queue_signals
        cur_task_desc = bingo_hw_manager_task_desc_full_t'(task_queue_mbox_data);
        task_queue_mbox_pop = stream_demux_is_chiplet_dep_set_task_inp_ready && !task_queue_mbox_empty;
    end

    /////////////////////////////////////////////////////////
    // Stream demux is chiplet set task
    /////////////////////////////////////////////////////////    
    stream_demux #(
        .N_OUP ( 2           )
    ) i_stream_demux_is_chiplet_dep_set_task (
        .inp_valid_i ( stream_demux_is_chiplet_dep_set_task_inp_valid ),
        .inp_ready_o ( stream_demux_is_chiplet_dep_set_task_inp_ready ),
        .oup_sel_i   ( stream_demux_is_chiplet_dep_set_task_oup_sel   ),
        .oup_valid_o ( stream_demux_is_chiplet_dep_set_task_oup_valid ),
        .oup_ready_i ( stream_demux_is_chiplet_dep_set_task_oup_ready )
    );
    always_comb begin: compose_stream_chiplet_dep_set_task_signals
        stream_demux_is_chiplet_dep_set_task_inp_valid = !task_queue_mbox_empty;
        stream_demux_is_chiplet_dep_set_task_oup_sel = (cur_task_desc.task_type == 2'b11);
        stream_demux_is_chiplet_dep_set_task_oup_ready[0] = stream_demux_is_chiplet_dep_check_task_inp_ready;
        stream_demux_is_chiplet_dep_set_task_oup_ready[1] = h2h_dep_set_task_desc_ready;
    end

    /////////////////////////////////////////////////////////
    // H2H Dep Set Interface
    /////////////////////////////////////////////////////////       
    bingo_hw_manager_h2h_dep_set #(
        .ChipIdWidth                                  (ChipIdWidth            ),
        .HostAxiLiteAddrWidth                         (HostAxiLiteAddrWidth   ),
        .HostAxiLiteDataWidth                         (HostAxiLiteDataWidth   ),
        .h2h_axi_lite_out_req_t                       (h2h_axi_lite_out_req_t ),
        .h2h_axi_lite_out_resp_t                      (h2h_axi_lite_out_resp_t),
        .bingo_hw_manager_chiplet_dep_set_task_desc_full_t(bingo_hw_manager_chiplet_dep_set_task_desc_full_t)
    ) i_bingo_hw_manager_h2h_dep_set (
        .clk_i                         (clk_i                          ),
        .rst_ni                        (rst_ni                         ),
        .h2h_mailbox_base_addr_i       (h2h_mailbox_base_addr_i        ),
        .h2h_to_remote_axi_lite_req_o  (h2h_to_remote_axi_lite_req_o   ),
        .h2h_to_remote_axi_lite_resp_i (h2h_to_remote_axi_lite_resp_i  ),
        .h2h_dep_set_task_desc_i       (h2h_dep_set_task_desc          ),
        .h2h_dep_set_task_desc_valid_i (h2h_dep_set_task_desc_valid    ),
        .h2h_dep_set_task_desc_ready_o (h2h_dep_set_task_desc_ready    )
    );
    always_comb begin : compose_h2h_dep_set_signals
        h2h_dep_set_task_desc = bingo_hw_manager_chiplet_dep_set_task_desc_full_t'(task_queue_mbox_data);
        h2h_dep_set_task_desc_valid = stream_demux_is_chiplet_dep_set_task_oup_valid[1];
    end

    //////////////////////////////////////////////////////////////////////
    // H2H Chiplet from remote Done Queue
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_write_mailbox #(
        .MailboxDepth(H2HDoneQueueDepth                        ),
        .IrqEdgeTrig (1'b0                                     ),
        .IrqActHigh  (1'b1                                     ),
        .AxiAddrWidth(HostAxiLiteAddrWidth                     ),
        .AxiDataWidth(HostAxiLiteDataWidth                     ),
        .ChipIdWidth (ChipIdWidth                              ),
        .req_lite_t  (h2h_axi_lite_in_req_t                    ),
        .resp_lite_t (h2h_axi_lite_in_resp_t                   )
    ) i_bingo_hw_manager_chiplet_done_queue (
        .clk_i       (clk_i                     ),
        .rst_ni      (rst_ni                    ),
        .chip_id_i   (chip_id_i                 ),
        .test_i      (1'b0                      ),
        .req_i       (h2h_from_remote_axi_lite_req_i        ),
        .resp_o      (h2h_from_remote_axi_lite_resp_o       ),
        .irq_o       (/*not used*/                          ),
        .base_addr_i (h2h_mailbox_base_addr_i               ),
        .mbox_data_o (h2h_chiplet_done_queue_mbox_data      ),
        .mbox_pop_i  (h2h_chiplet_done_queue_mbox_pop       ),
        .mbox_empty_o(h2h_chiplet_done_queue_mbox_empty     ),
        .mbox_flush_i('0                                    )
    );
    always_comb begin : compose_h2h_chiplet_done_queue_signal
        h2h_chiplet_done_queue_mbox_pop = dep_set_sum_ready && !h2h_chiplet_done_queue_mbox_empty;
    end

    /////////////////////////////////////////////////////////
    // Stream demux is chiplet check task
    /////////////////////////////////////////////////////////    
    stream_demux #(
        .N_OUP ( 2           )
    ) i_stream_demux_is_chiplet_dep_check_task (
        .inp_valid_i ( stream_demux_is_chiplet_dep_check_task_inp_valid ),
        .inp_ready_o ( stream_demux_is_chiplet_dep_check_task_inp_ready ),
        .oup_sel_i   ( stream_demux_is_chiplet_dep_check_task_oup_sel   ),
        .oup_valid_o ( stream_demux_is_chiplet_dep_check_task_oup_valid ),
        .oup_ready_i ( stream_demux_is_chiplet_dep_check_task_oup_ready )
    );
    always_comb begin: compose_stream_chiplet_check_task_signals
        stream_demux_is_chiplet_dep_check_task_inp_valid = stream_demux_is_chiplet_dep_set_task_oup_valid[0];
        stream_demux_is_chiplet_dep_check_task_oup_sel = (cur_task_desc.task_type == 2'b10);
        stream_demux_is_chiplet_dep_check_task_oup_ready[0] = stream_demux_core_type_inp_ready;
        stream_demux_is_chiplet_dep_check_task_oup_ready[1] = dep_check_sum_ready;
    end

    /////////////////////////////////////////////////////////
    // H2H Dep Check Sum
    ///////////////////////////////////////////////////////// 
    bingo_hw_manager_dep_check_sum #(
        .CHECKSUM_WIDTH(ChipIdWidth)
    ) i_bingo_hw_manager_h2h_dep_check_sum(
        .clk_i                   (clk_i                  ),
        .rst_ni                  (rst_ni                 ),
        .dep_check_sum_valid_i   (dep_check_sum_valid    ),
        .dep_check_sum_ready_o   (dep_check_sum_ready    ),
        .dep_check_sum_i         (dep_check_sum          ),
        .dep_set_sum_valid_i     (dep_set_sum_valid      ),
        .dep_set_sum_ready_o     (dep_set_sum_ready      )
    );
    always_comb begin : compose_h2h_dep_check_sum_signals
        dep_check_sum_valid = stream_demux_is_chiplet_dep_check_task_oup_valid[1];
        dep_set_sum_valid = !h2h_chiplet_done_queue_mbox_empty;
        dep_check_sum = bingo_hw_manager_chiplet_dep_check_task_desc_full_t'(task_queue_mbox_data).dep_check_sum;
    end


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
        stream_demux_core_type_inp_valid = stream_demux_is_chiplet_dep_check_task_oup_valid[0];
        stream_demux_core_type_oup_sel = '0;
        stream_demux_core_type_oup_sel[cur_task_desc.assigned_core_id] = 1'b1;
        for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            stream_demux_core_type_oup_ready[core] = ~waiting_dep_check_queue_full[core];
        end
    end


    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_waiting_dep_check_queue
        fifo_v3 #(
            .FALL_THROUGH ( 1'b0                               ),
            .DEPTH        ( 8                                  ),
            .dtype        ( bingo_hw_manager_task_desc_full_t  )
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
        always_comb begin: compose_waiting_dep_check_queue_signals
            waiting_dep_check_queue_push[core] = stream_demux_core_type_oup_valid[core] && ~waiting_dep_check_queue_full[core];
            waiting_dep_check_queue_pop[core] = is_dummy_set_task_demux_inp_ready[core] && ~waiting_dep_check_queue_empty[core];
        end
        // After the waiting dep check queue, we need a demux to create a fast set path for the dummy set tasks
        // [0]: Normal path
        // [1]: Dummy Set path: is_dummy==1 && dep_set_en==1
        stream_demux #(
            .N_OUP ( 2           )
        ) i_stream_demux_is_dummy_set (
            .inp_valid_i ( is_dummy_set_task_demux_inp_valid[core] ),
            .inp_ready_o ( is_dummy_set_task_demux_inp_ready[core] ),
            .oup_sel_i   ( is_dummy_set_task_demux_oup_sel[core]   ),
            .oup_valid_o ( is_dummy_set_task_demux_oup_valid[core] ),
            .oup_ready_i ( is_dummy_set_task_demux_oup_ready[core] )
        );
        always_comb begin: compose_is_dummy_set_task_demux_signals
            is_dummy_set_task_demux_inp_valid[core] = !waiting_dep_check_queue_empty[core];
            is_dummy_set_task_demux_oup_sel[core] = (waiting_dep_check_task_desc[core].task_type == 2'b10) && (waiting_dep_check_task_desc[core].dep_set_info.dep_set_en);
            is_dummy_set_task_demux_oup_ready[core][0] = stream_fork_inp_ready[core];
            is_dummy_set_task_demux_oup_ready[core][1] = dummy_set_task_demux_inp_ready[core];
        end


        // Then we need another stream demux to route to the dummy set task to the correct cluster based on cluster id
        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_dummy_set_cluster_id (
            .inp_valid_i ( dummy_set_task_demux_inp_valid[core]   ),
            .inp_ready_o ( dummy_set_task_demux_inp_ready[core]   ),
            .oup_sel_i   ( dummy_set_task_demux_oup_sel[core]     ),
            .oup_valid_o ( dummy_set_task_demux_oup_valid[core]   ),
            .oup_ready_i ( dummy_set_task_demux_oup_ready[core]   )
        );
        always_comb begin: compose_dummy_set_cluster_id_demux_signals
            dummy_set_task_demux_inp_valid[core] = is_dummy_set_task_demux_oup_valid[core][1];
            dummy_set_task_demux_oup_sel[core] = waiting_dep_check_task_desc[core].assigned_cluster_id;
        end

        // There are three outputs from the stream fork:
        // [0]: to dep matrix
        // [1]: to ready queue
        // [2]: to checkout queue
        stream_fork #(
            .N_OUP ( 3 )
        ) i_stream_fork_dep_check_queue (
            .clk_i      ( clk_i                        ),
            .rst_ni     ( rst_ni                       ),
            .valid_i    ( stream_fork_inp_valid[core]  ),
            .ready_o    ( stream_fork_inp_ready[core]  ),
            .valid_o    ( stream_fork_oup_valid[core]  ),
            .ready_i    ( stream_fork_oup_ready[core]  )
        );
        always_comb begin: compose_stream_fork_dep_check_queue_signals
            stream_fork_inp_valid[core] = is_dummy_set_task_demux_oup_valid[core][0];
        end

        // For the dep matrix, if the dep check is disable, we do not need to send the task to dep matrix
        stream_filter i_stream_filter_to_dep_matrix (
            .valid_i ( stream_fork_oup_valid[core][0]    ),
            .ready_o ( stream_fork_oup_ready[core][0]    ),
            .drop_i  ( ~waiting_dep_check_task_desc[core].dep_check_info.dep_check_en ),
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

        // For the dummy tasks, we need the stream_filter to drop the task from ready queue and checkout queue
        // Drop the dummy tasks for ready queue
        stream_filter i_stream_filter_for_dummy_tasks_to_ready_queue (
            .valid_i ( stream_fork_oup_valid[core][1] && stream_fork_oup_ready[core][0]  ), // make sure the dep matrix check is done
            .ready_o ( stream_fork_oup_ready[core][1]    ),
            .drop_i  ( (waiting_dep_check_task_desc[core].task_type==2'b01) && (~waiting_dep_check_task_desc[core].dep_set_info.dep_set_en)),
            .valid_o ( demux_ready_queue_inp_valid[core] ),
            .ready_i ( demux_ready_queue_inp_ready[core] )
        );

        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_from_waiting_dep_check_queue_to_ready_queue (
            .inp_valid_i ( demux_ready_queue_inp_valid[core]    ),
            .inp_ready_o ( demux_ready_queue_inp_ready[core]    ),
            .oup_sel_i   ( waiting_dep_check_task_desc[core].assigned_cluster_id ),
            .oup_valid_o ( demux_ready_queue_oup_valid[core]    ),
            .oup_ready_i ( demux_ready_queue_oup_ready[core]    )
        );

        // Drop the dummy tasks for checkout queue
        stream_filter i_stream_filter_for_dummy_tasks_to_checkout_queue (
            .valid_i ( stream_fork_oup_valid[core][2] && stream_fork_oup_ready[core][0]   ), // make sure the dep matrix check is done
            .ready_o ( stream_fork_oup_ready[core][2]       ),
            .drop_i  ( (waiting_dep_check_task_desc[core].task_type==2'b01) && (~waiting_dep_check_task_desc[core].dep_set_info.dep_set_en)),
            .valid_o ( demux_checkout_queue_inp_valid[core] ),
            .ready_i ( demux_checkout_queue_inp_ready[core] )
        );

        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_from_waiting_dep_check_queue_to_checkout_queue (
            .inp_valid_i ( demux_checkout_queue_inp_valid[core]    ),
            .inp_ready_o ( demux_checkout_queue_inp_ready[core]    ),
            .oup_sel_i   ( waiting_dep_check_task_desc[core].assigned_cluster_id ),
            .oup_valid_o ( demux_checkout_queue_oup_valid[core]    ),
            .oup_ready_i ( demux_checkout_queue_oup_ready[core]    )
        );
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
            .dep_set_code_i    (dep_set_code[cluster]    )
        );

    end

    always_comb begin : connect_waiting_dep_check_queue_demux_to_dep_matrix
        for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                dep_check_valid[cluster][core] = demux_dep_matrix_oup_valid[core][cluster];
                demux_dep_matrix_oup_ready[core][cluster] = dep_check_result[cluster][core];
                dep_check_code[cluster][core] = waiting_dep_check_task_desc[core].dep_check_info.dep_check_code;
            end
        end
    end

    always_comb begin : connect_dep_set_mux_to_dep_matrix
        for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                dep_set_valid[cluster][core] = dep_set_code_mux_oup_valid[core][cluster];
                dep_set_code[cluster][core] =  dep_set_code_mux_oup_data[core][cluster];
                dep_set_code_mux_oup_ready[core][cluster] = dep_set_valid[cluster][core];
            end
        end
    end


    //////////////////////////////////////////////////////////////////////
    // Ready Queue
    //////////////////////////////////////////////////////////////////////
    // This is the ready queue interface
    // Device will read ready tasks info from this queue via 32bit AXI Lite
    // The information contains only task ID
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_ready_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_ready_queue_per_core_per_cluster
            bingo_hw_manager_read_mailbox #(
                .MailboxDepth(ReadyQueueDepth                ),
                .IrqEdgeTrig (1'b0                           ),
                .IrqActHigh  (1'b1                           ),
                .AxiAddrWidth(DeviceAxiLiteAddrWidth         ),
                .AxiDataWidth(DeviceAxiLiteDataWidth         ),
                .ChipIdWidth (ChipIdWidth                    ),
                .req_lite_t  (ready_queue_axi_lite_in_req_t  ),
                .resp_lite_t (ready_queue_axi_lite_in_resp_t )
            ) i_bingo_hw_manager_ready_queue (
                .clk_i       (clk_i                                      ),
                .rst_ni      (rst_ni                                     ),
                .chip_id_i   (chip_id_i                                  ),
                .test_i      (1'b0                                       ),
                .req_i       (ready_queue_axi_lite_req_i[core][cluster]  ),
                .resp_o      (ready_queue_axi_lite_resp_o[core][cluster] ),
                .irq_o       (/*not used*/                               ),
                .base_addr_i (ready_queue_base_addr_i[core][cluster]     ),
                .mbox_data_i (ready_queue_task_desc[core][cluster]       ),
                .mbox_push_i (ready_queue_push[core][cluster]            ),
                .mbox_full_o (ready_queue_full[core][cluster]            ),
                .mbox_flush_i(1'b0                                       )
            );
        end
    end

    always_comb begin : compose_ready_queue_task_desc
        for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                ready_queue_task_desc[core][cluster].task_id = waiting_dep_check_task_desc[core].task_id;
                ready_queue_task_desc[core][cluster].reserved_bits = '0;
                ready_queue_push[core][cluster] = demux_ready_queue_oup_valid[core][cluster] & ~ready_queue_full[core][cluster];
                demux_ready_queue_oup_ready[core][cluster] = ready_queue_push[core][cluster];
            end
        end
    end

    //////////////////////////////////////////////////////////////////////
    // Checkout Queue
    //////////////////////////////////////////////////////////////////////
    // Check out queues are internal fifos
    // input is from the waiting dep check queue
    // after it has been checked by the dep matrix, it will be pushed to the checkout queue
    // and then wait the done queue to pop it

    // Here the data type only holds the task id and dependency set info

    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_checkout_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_checkout_queue_per_core_per_cluster
            fifo_v3 #(
                .FALL_THROUGH ( 1'b0                                  ),
                .DEPTH        ( 4                                     ),
                .dtype        ( bingo_hw_manager_checkout_task_desc_t )
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
                .pop_i       ( checkout_filter_inp_ready[core][cluster] && ~checkout_queue_empty[core][cluster] )
            );

            // Each checkout queue will also filter the tasks based on the dep_set_info
            stream_filter i_stream_filter_for_checkout_queue_dep_set (
                .valid_i (   checkout_filter_inp_valid[core][cluster]                      ),
                .ready_o (   checkout_filter_inp_ready[core][cluster]                      ),
                .drop_i  (   (checkout_queue_data_out[core][cluster].dep_set_info.dep_set_en==1'b0) && (checkout_queue_empty[core][cluster]!=1'b1) ),
                .valid_o (   checkout_filter_oup_valid[core][cluster]                      ),
                .ready_i (   checkout_filter_oup_ready[core][cluster]                      )
            );
        end
    end
    
    always_comb begin : compose_checkout_filter_inp_valid
        for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                checkout_filter_inp_valid[core][cluster] = ~checkout_queue_empty[core][cluster] && stream_demux_from_done_queue_to_checkout_queue_clusterid_oup_valid[core][cluster] &&
                checkout_queue_data_out[core][cluster].task_id == cur_done_queue_info.task_id;
            end
        end
    end

    always_comb begin : compose_checkout_queue_input
        for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                checkout_queue_data_in[core][cluster].task_id = waiting_dep_check_task_desc[core].task_id;
                checkout_queue_data_in[core][cluster].dep_set_info = waiting_dep_check_task_desc[core].dep_set_info;
                checkout_queue_push[core][cluster] = demux_checkout_queue_oup_valid[core][cluster] & ~checkout_queue_full[core][cluster];
                demux_checkout_queue_oup_ready[core][cluster] = ~checkout_queue_full[core][cluster];
            end
        end
    end

    /////////////////////////////////////////////////////////
    // Dep Set Mux
    /////////////////////////////////////////////////////////
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_dep_set_mux
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            // There are two sources for dep set info:
            // [0]: From checkout queue
            // [1]: From fast dummy set path
            stream_mux #(
                .DATA_T ( bingo_hw_manager_dep_code_t ),
                .N_INP ( 2 )
            ) i_dep_set_code_mux (
                .inp_data_i  ({waiting_dep_check_task_desc[core].dep_set_info.dep_set_code, checkout_queue_data_out[core][cluster].dep_set_info.dep_set_code} ),
                .inp_valid_i ({dummy_set_task_demux_oup_valid[core][cluster], checkout_filter_oup_valid[core][cluster]}      ),
                .inp_ready_o ({dummy_set_task_demux_oup_ready[core][cluster], checkout_filter_oup_ready[core][cluster]}      ),
                .inp_sel_i   (dummy_set_task_demux_oup_valid[core][cluster]                                                  ),
                .oup_data_o  (dep_set_code_mux_oup_data[core][cluster]                                                       ),
                .oup_valid_o (dep_set_code_mux_oup_valid[core][cluster]                                                      ),
                .oup_ready_i (dep_set_code_mux_oup_ready[core][cluster]                                                      )
            );
        end
    end

    //////////////////////////////////////////////////////////////////////
    // Local Done Queue
    //////////////////////////////////////////////////////////////////////
    // This is the done queue interface
    // Device will writes completed tasks info to this queue via 32bit AXI Lite
    // The information contains task ID, cluster id and core id
    bingo_hw_manager_write_mailbox #(
        .MailboxDepth(DoneQueueDepth               ),
        .IrqEdgeTrig (1'b0                         ),
        .IrqActHigh  (1'b1                         ),
        .AxiAddrWidth(DeviceAxiLiteAddrWidth       ),
        .AxiDataWidth(DeviceAxiLiteDataWidth       ),
        .ChipIdWidth (ChipIdWidth                  ),
        .req_lite_t  (done_queue_axi_lite_in_req_t ),
        .resp_lite_t (done_queue_axi_lite_in_resp_t)
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
    always_comb begin : compose_done_queue_info
        cur_done_queue_info = bingo_hw_manager_done_info_full_t'(done_queue_mbox_data);
    end
    ////////////////////////////////////////////////
    // Done queue demux
    ///////////////////////////////////////////////
    // First stage demux is selected by the core id
    stream_demux #(
        .N_OUP ( NUM_CORES_PER_CLUSTER           )
    ) i_stream_demux_from_done_queue_to_checkout_queue_coreid (
        .inp_valid_i ( stream_demux_from_done_queue_to_checkout_queue_coreid_inp_valid ),
        .inp_ready_o ( stream_demux_from_done_queue_to_checkout_queue_coreid_inp_ready ),
        .oup_sel_i   ( cur_done_queue_info.assigned_core_id ),
        .oup_valid_o ( stream_demux_from_done_queue_to_checkout_queue_coreid_oup_valid ),
        .oup_ready_i ( stream_demux_from_done_queue_to_checkout_queue_coreid_oup_ready )
    );
    // Second stage demux is selected by the cluster id
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_done_queue_demux_clusterid
        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET )
        ) i_stream_demux_from_done_queue_to_checkout_queue_clusterid (
            .inp_valid_i ( stream_demux_from_done_queue_to_checkout_queue_clusterid_inp_valid[core] ),
            .inp_ready_o ( stream_demux_from_done_queue_to_checkout_queue_clusterid_inp_ready[core] ),
            .oup_sel_i   ( cur_done_queue_info.assigned_cluster_id ),
            .oup_valid_o ( stream_demux_from_done_queue_to_checkout_queue_clusterid_oup_valid[core] ),
            .oup_ready_i ( checkout_filter_oup_ready[core] )
        );
    end
    //////////////////////////////////////////////////////////////////////
    // Connect the done queue mailbox to the first stage demux
    //////////////////////////////////////////////////////////////////////
    always_comb begin : connect_done_queue_to_first_stage_demux
        stream_demux_from_done_queue_to_checkout_queue_coreid_inp_valid = ~done_queue_mbox_empty;
        done_queue_mbox_pop = stream_demux_from_done_queue_to_checkout_queue_coreid_inp_ready & ~done_queue_mbox_empty;
    end
    //////////////////////////////////////////////////////////////////////
    // Connect the first stage demux to the second stage demux
    //////////////////////////////////////////////////////////////////////
    always_comb begin : connect_first_stage_demux_to_second_stage_demux
        for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            stream_demux_from_done_queue_to_checkout_queue_clusterid_inp_valid[core] = stream_demux_from_done_queue_to_checkout_queue_coreid_oup_valid[core];
            stream_demux_from_done_queue_to_checkout_queue_coreid_oup_ready[core] = stream_demux_from_done_queue_to_checkout_queue_clusterid_inp_ready[core];
        end
    end

        
endmodule