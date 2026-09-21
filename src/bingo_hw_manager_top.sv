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
    // Dedicated host DVFS doorbell bit inside the shared CLINT MSIP word. Injected from
    // the HeMAiA level (occamygen hw_manager_ipi_idx) and forwarded to the PM so it is
    // never hardcoded; must match HW_MANAGER_DVFS_MSIP_BIT / occamy_soc.sv ipi_i.
    parameter int unsigned HOST_DVFS_MSIP_BIT = 3,
    parameter int unsigned ChipIdWidth = 8,
    parameter int unsigned TaskIdWidth = 12,
    // Identity-aware dependency tracking (per-edge tags). The mini-compiler's
    // per-edge tags are plumbed to the tagged dep-matrix scoreboard so a
    // consumer drains only ITS producer's increment (no counter-sharing hazard).
    parameter int unsigned DepTagWidth = 4,
    /// CROSS-DIE CERF WINDOW: the low GlobalCerfGroups CERF entries ride inside
    /// cross-chiplet dep-set messages, so a gating task on one die can gate work
    /// on another. Must be >= 1; a design with no cross-die conditionals simply
    /// never allocates groups in the window.
    ///
    /// Locally CERF is race-free structurally -- a gated task depends on its
    /// gating task, so the dependency edge orders the CERF write against the
    /// read. A predicate sent as its OWN message loses that ordering and the
    /// remote task can see its dependency satisfied with a stale bit, silently
    /// skipping selected work. Carrying it on the edge restores the ordering by
    /// construction. See model/tests/test_multi_chiplet_cerf.py.
    parameter int unsigned GlobalCerfGroups = 8,
    /// Width of the task-descriptor CONTAINER, in bits.
    ///
    /// This used to be implicit: the descriptor was whatever fitted in one HostAxiLiteDataWidth
    /// beat, so "how wide is a descriptor" and "how wide is the host bus" were the same number and
    /// the design could not tell them apart. They are different questions. The host narrow fabric
    /// is fixed at 64 bit by the SoC; the descriptor has to grow with the core and cluster counts
    /// (each extra core costs 2 bits, because dep_check_code and dep_set_code are both per-core
    /// masks). At 4 clusters x 4 cores + host the descriptor is already 65 bits.
    ///
    /// MUST be an integer multiple of HostAxiLiteDataWidth: the task list is fetched as that many
    /// AXI-Lite beats per descriptor (see bingo_hw_manager_task_queue_master, which makes the
    /// multi-beat fetch atomic). Software MUST use the same value -- it is published to the C and
    /// Python sides as BINGO_TASK_DESC_WIDTH so the emitted task list has the same stride.
    parameter int unsigned TaskDescBusWidth = 128,
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
    /// AXI-Lite reads the master-mode task queue may keep in flight
    /// (TASK_QUEUE_TYPE == 1 only; see bingo_hw_manager_task_queue_master).
    /// 1 is the strictly-serial behaviour and the default, so raising it is
    /// opt-in. Must be >= 1 and <= TaskQueueDepth.
    parameter int unsigned TaskQueueMaxOutstanding = 1,
    // Per-core waiting-dep-check queue. It was the one queue in this module fixed at a
    // literal while its siblings were parameters, and it is the one the stream demux
    // backpressures on: `stream_demux_core_type_oup_ready[core] = !waiting_..._full[core]`
    // stalls the WHOLE in-order descriptor stream when a single core's queue fills, so it
    // is worth being able to sweep. The Python model in model/ already treats it as a
    // parameter (QueueDepths.waiting), so this makes the RTL and the model agree.
    //
    // Parameterised so it can be swept, not because the default is a bottleneck.
    parameter int unsigned WaitingDepCheckQueueDepth = 8,
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
    /// The chiplet set interface to other chiplets
    // HW Manager -----> Other chiplets
    input  host_axi_lite_addr_t                 chiplet_mailbox_base_addr_i,
    output host_axi_lite_req_t                  to_remote_chiplet_axi_lite_req_o,
    input  host_axi_lite_resp_t                 to_remote_chiplet_axi_lite_resp_i,
    /// The chiplet done interface from other chiplets
    input  host_axi_lite_req_t                  from_remote_axi_lite_req_i,
    output host_axi_lite_resp_t                 from_remote_axi_lite_resp_o,
    /// The done queue interface to the devices
    // Devices -----> Done Queue
    // Here this queue holds all the completed tasks info from the devices
    // The device cores will write completed tasks into this queue via 32bit AXI Lite
    input  device_axi_lite_addr_t               done_queue_base_addr_i,
    input  device_axi_lite_req_t                done_queue_axi_lite_req_i,
    output device_axi_lite_resp_t               done_queue_axi_lite_resp_o,
    /// The ready queue interface to the devices
    // HW scheduler -----> Ready Queue
    // Here the ready queue holds the tasks that are ready to be executed by the devices
    // The device cores will read tasks from this queue via 32bit AXI Lite
    // Each core has its own ready queue interface
    input  device_axi_lite_addr_t               ready_queue_base_addr_i,
    input  device_axi_lite_req_t                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_req_i,
    output device_axi_lite_resp_t               [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    ready_queue_axi_lite_resp_o,
    /// CSR Req/Resp Interface for ready queue and the done queue
    // CSR Will Read from the ready queue and write to the done queue
    input  csr_req_t                            [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_i,
    input  logic                                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_valid_i,
    output logic                                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_req_ready_o,
    output csr_rsp_t                            [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_o,
    output logic                                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_valid_o,
    input  logic                                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    csr_rsp_ready_i,
    /// The interface to the Power Management Module
    // Host configuration interface
    input device_axi_lite_data_t                bingo_hw_manager_enable_idle_pm_i,
    input device_axi_lite_data_t                bingo_hw_manager_idle_power_level_i,
    input device_axi_lite_data_t                bingo_hw_manager_normal_power_level_i,
    input device_axi_lite_addr_t                bingo_hw_manager_pm_base_addr_i,
    input device_axi_lite_data_t                [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    bingo_hw_manager_core_power_domain_i,
    // DVFS: mode select, CLINT doorbell address, host ack, and published request
    input  device_axi_lite_data_t               bingo_hw_manager_pm_mode_i,
    input  device_axi_lite_addr_t               bingo_hw_manager_dvfs_clint_msip_addr_i,
    input  device_axi_lite_data_t               bingo_hw_manager_dvfs_ack_i,
    output device_axi_lite_data_t               bingo_hw_manager_dvfs_request_o,
    // AXI Lite Master Interface
    output host_axi_lite_req_t                  pm_axi_lite_req_o,
    input  host_axi_lite_resp_t                 pm_axi_lite_resp_i,
    // DARTS: CERF (Conditional Execution Register File) interface
    input  logic                                cerf_write_en_i,
    input  logic [31:0]                         cerf_write_data_i,
    output logic [31:0]                         cerf_state_o,
    // DARTS: Load Monitor output (CSR readable)
    output logic [10:0]                         load_total_pending_o
);
    // --------Type definitions and signal declarations--------------------//
    // ---- Start of Type definitions -------------------------------------//
    // Task Type (DARTS: expanded to 2 bits for gating support)
    // 2'b00: Normal Task
    // 2'b01: Dummy Task (set/check synchronization)
    // 2'b10: Gating Task (executes on core, writes CERF on completion)
    // 2'b11: Reserved
    typedef logic [1:0]                                  bingo_hw_manager_task_type_t;
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
    // Per-edge identity tag. Carried alongside the dep code so
    // it flows through every existing dep_check_info / dep_set_info copy unchanged.
    typedef logic [DepTagWidth-1:0]                      bingo_hw_manager_dep_tag_t;
    typedef struct packed{
        bingo_hw_manager_dep_tag_t                   dep_check_tag;
        bingo_hw_manager_dep_code_t                  dep_check_code;
        logic                                        dep_check_en;
    } bingo_hw_manager_dep_check_info_t;
    // Dependency set info struct
    typedef struct packed{
        bingo_hw_manager_dep_tag_t                   dep_set_tag;
        bingo_hw_manager_dep_code_t                  dep_set_code;
        bingo_hw_manager_assigned_cluster_id_t       dep_set_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id;
        logic                                        dep_set_all_chiplet;
        logic                                        dep_set_en;
    } bingo_hw_manager_dep_set_info_t;

    // Task info struct (DARTS: includes conditional execution fields)
    typedef struct packed{
        /// CARRIES THE CROSS-DIE CERF WINDOW. Set by the compiler on whichever
        /// task actually SENDS the cross-chiplet message for a gating region.
        /// That is NOT the gating task: the dummy-set pass always proxies a
        /// remote successor through a dummy on the gating task's own core, so
        /// inferring this from task_type == GATING would never fire on a real
        /// compiled graph. The compiler states it instead of the hardware
        /// guessing.
        logic                                        cerf_carry;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        // DARTS Tier 1: Conditional Execution
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
    } bingo_hw_manager_task_desc_t;

    localparam int unsigned TaskDescWidth = $bits(bingo_hw_manager_task_desc_t);
    localparam int unsigned ReservedBitsForTaskDesc = TaskDescBusWidth - TaskDescWidth;
    /// How many host AXI-Lite beats one descriptor occupies. 1 reproduces the historical
    /// single-beat behaviour exactly.
    localparam int unsigned TaskDescBeats = TaskDescBusWidth / HostAxiLiteDataWidth;
    if (TaskDescWidth>TaskDescBusWidth) begin : gen_task_desc_width_check
        initial begin
        $error("Task Descriptor width (%0d) exceeds TaskDescBusWidth (%0d)! Raise TaskDescBusWidth (and BINGO_TASK_DESC_WIDTH on the SW side) or shrink a field.", TaskDescWidth, TaskDescBusWidth);
        $finish;
        end
    end
    if (TaskDescBusWidth % HostAxiLiteDataWidth != 0) begin : gen_task_desc_beat_check
        initial begin
        $error("TaskDescBusWidth (%0d) must be an integer multiple of HostAxiLiteDataWidth (%0d).", TaskDescBusWidth, HostAxiLiteDataWidth);
        $finish;
        end
    end
    // TASK_QUEUE_TYPE==0 is the AXI-Lite SLAVE task queue: the host pushes descriptors into a
    // write mailbox that commits one entry per W beat. It has no reassembly, so it can only carry
    // a single-beat descriptor. Only the MASTER path (TYPE==1, what HeMAiA uses) implements the
    // multi-beat atomic fetch. Fail loudly here rather than silently zero-extending a truncated
    // descriptor, which is what the unguarded width assignment would otherwise do.
    if ((TASK_QUEUE_TYPE == 0) && (TaskDescBusWidth != HostAxiLiteDataWidth)) begin : gen_task_desc_slave_width_check
        initial begin
        $error("TASK_QUEUE_TYPE==0 (AXI-Lite slave task queue) supports only a single-beat descriptor, but TaskDescBusWidth=%0d and HostAxiLiteDataWidth=%0d. Use TASK_QUEUE_TYPE==1 for a multi-beat descriptor.", TaskDescBusWidth, HostAxiLiteDataWidth);
        $finish;
        end
    end
    // Task Descriptor padded out to the container width
    typedef struct packed{
        logic [ReservedBitsForTaskDesc-1:0]          reserved_bits;
        logic                                        cerf_carry;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        // DARTS Tier 1: Conditional Execution
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
    } bingo_hw_manager_task_desc_full_t;

    /// CROSS-CHIPLET DEP-SET MESSAGE.
    ///
    /// This is deliberately NOT the task descriptor. The sender used to put the whole descriptor
    /// on the wire simply because it happened to fit in one AXI-Lite beat, which made the
    /// atomicity of a cross-chiplet dep-set an accident of its width rather than a property of
    /// the protocol. Many chiplets write one destination mailbox concurrently and the receiving
    /// adapter pushes one FIFO entry per W beat with no reassembly, so the moment a message needs
    /// two beats two senders can interleave and the receiver commits a torn message -- silently,
    /// because every bit pattern is a legal descriptor.
    ///
    /// So the message carries only what the RECEIVER actually consumes (see the dep-matrix set
    /// composition below): the four fields it reads, plus the originating task id for tracing.
    /// It is checked at elaboration to fit in a single beat, which is what keeps it atomic no
    /// matter how wide the descriptor grows.
    typedef struct packed{
        /// Carried predicate: set only by a GATING task's message. Carries that
        /// die's global CERF window so the receiver applies the routing decision
        /// together with the dep-set that releases the gated task.
        logic                                      cerf_valid;
        logic [GlobalCerfGroups-1:0]               cerf_global;
        bingo_hw_manager_task_id_t                 task_id;             // trace only, not consumed
        bingo_hw_manager_dep_tag_t                 dep_set_tag;
        bingo_hw_manager_dep_code_t                dep_set_code;
        bingo_hw_manager_assigned_core_id_t        src_core_id;         // dep_matrix column
        bingo_hw_manager_assigned_cluster_id_t     dep_set_cluster_id;  // dep_matrix id
    } bingo_hw_manager_chiplet_msg_t;

    localparam int unsigned ChipletMsgWidth = $bits(bingo_hw_manager_chiplet_msg_t);
    localparam int unsigned ReservedBitsForChipletMsg = HostAxiLiteDataWidth - ChipletMsgWidth;
    if (ChipletMsgWidth > HostAxiLiteDataWidth) begin : gen_chiplet_msg_width_check
        initial begin
        $error("Cross-chiplet dep-set message (%0d b) exceeds one AXI-Lite beat (%0d b). It MUST fit in one beat or it is no longer atomic against concurrent senders.", ChipletMsgWidth, HostAxiLiteDataWidth);
        $finish;
        end
    end
    typedef struct packed{
        logic [ReservedBitsForChipletMsg-1:0]      reserved_bits;
        logic                                      cerf_valid;
        logic [GlobalCerfGroups-1:0]               cerf_global;
        bingo_hw_manager_task_id_t                 task_id;
        bingo_hw_manager_dep_tag_t                 dep_set_tag;
        bingo_hw_manager_dep_code_t                dep_set_code;
        bingo_hw_manager_assigned_core_id_t        src_core_id;
        bingo_hw_manager_assigned_cluster_id_t     dep_set_cluster_id;
    } bingo_hw_manager_chiplet_msg_full_t;

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
        bingo_hw_manager_dep_tag_t                 dep_matrix_set_tag;
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
    // Descriptor-wide, NOT bus-wide. These two were the same number until the descriptor
    // outgrew one AXI-Lite beat; declaring a descriptor carrier with the bus width is exactly
    // the kind of silent coupling that made the old design impossible to widen.
    logic [TaskDescBusWidth-1:0]       task_queue_mbox_data;
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
    bingo_hw_manager_chiplet_msg_full_t cur_chiplet_done_queue_msg;
    /////////////////////////////////////////////////////////
    // Stream demux core type
    /////////////////////////////////////////////////////////
    logic                                           stream_demux_core_type_inp_valid;
    logic                                           stream_demux_core_type_inp_ready;
    logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET)-1:0] stream_demux_core_type_oup_sel;
    logic [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_core_type_oup_valid;
    logic [NUM_CORES_PER_CLUSTER*NUM_CLUSTERS_PER_CHIPLET-1:0] stream_demux_core_type_oup_ready;

    ///////////////////////////////////
    // Waiting dep check queue signals
    ///////////////////////////////////
    bingo_hw_manager_task_desc_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] waiting_dep_check_task_desc;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] waiting_dep_check_queue_push;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] waiting_dep_check_queue_full;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] waiting_dep_check_queue_empty;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] waiting_dep_check_queue_pop;

    ////////////////////////////////
    // Dep Check Manager Signals
    ////////////////////////////////
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_check_manager_inp_wait_dep_check_queue_valid;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_check_manager_inp_wait_dep_check_queue_ready;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_check_manager_oup_dep_check_valid;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_check_manager_oup_dep_check_ready;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_check_manager_oup_ready_and_checkout_queue_valid;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] dep_check_manager_oup_ready_and_checkout_queue_ready;
    ////////////////////////////////
    // Dep matrix demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] dep_matrix_demux_oup_t;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] demux_dep_matrix_inp_valid;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] demux_dep_matrix_inp_ready;
    dep_matrix_demux_oup_t            [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_oup_valid;
    dep_matrix_demux_oup_t            [NUM_CORES_PER_CLUSTER-1:0] demux_dep_matrix_oup_ready;

    ////////////////////////////////
    // Ready and Checkout queue demux signals
    ////////////////////////////////
    typedef logic [NUM_CLUSTERS_PER_CHIPLET-1:0] ready_and_checkout_queue_demux_oup_t;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] demux_ready_and_checkout_queue_inp_valid;
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] demux_ready_and_checkout_queue_inp_ready;
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
    bingo_hw_manager_dep_tag_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] dep_check_tag;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_set_valid;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_set_ready;
    dep_set_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]   dep_set_code;
    bingo_hw_manager_dep_tag_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] dep_set_tag;

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
    // Per (Core, Cluster) Done Queue signals
    // Each (core, cluster) pair has its own done queue FIFO.
    // This fully eliminates HOL blocking: completions for different
    // cores AND different clusters drain independently.
    ///////////////////////////////////////
    bingo_hw_manager_done_info_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_info;
    logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_pop;
    logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_empty;
    bingo_hw_manager_done_info_full_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_data_in;
    logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_push;
    logic                             [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] done_q_full;
    // Legacy single-queue signals for AXI-Lite mailbox mode (TYPE==0)
    // In AXI-Lite mode, we still use a single mailbox + internal demux
    device_axi_lite_data_t               done_queue_mbox_data;
    logic                                done_queue_mbox_pop;
    logic                                done_queue_mbox_empty;
    bingo_hw_manager_done_info_full_t    cur_done_queue_info_axi;
    ///////////////////////////////////////
    // DARTS Tier 1: CERF state and per-core conditional skip signals
    logic [31:0] cerf_state;
    assign cerf_state_o = cerf_state;  // read-back for SW
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] cond_exec_skip;

    // DARTS CERF: per-core conditional skip evaluation.
    // Only valid when there IS a task being processed (queue not empty).
    // When cond_exec_en==0 (default), this is always 0 regardless of CERF state.
    for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin: gen_cerf_skip
      for (genvar cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin: gen_cerf_skip_cluster
        logic cerf_group_active_for_core;
        assign cerf_group_active_for_core = cerf_state[waiting_dep_check_task_desc[c][cl].cond_exec_group_id];
        assign cond_exec_skip[c][cl] = !waiting_dep_check_queue_empty[c][cl] &&
                                    waiting_dep_check_task_desc[c][cl].cond_exec_en &&
                                    (waiting_dep_check_task_desc[c][cl].cond_exec_invert ?
                                        cerf_group_active_for_core : !cerf_group_active_for_core);
      end
    end

    // PM signals
    ///////////////////////////////////////
    logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] core_status_waiting_task;
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
            .MaxOutstanding               (TaskQueueMaxOutstanding      ),
            .TaskIdWidth                  (TaskIdWidth                  ),
            .req_lite_t                   (host_axi_lite_req_t          ),
            .resp_lite_t                  (host_axi_lite_resp_t         ),
            .addr_t                       (host_axi_lite_addr_t         ),
            // data_t = one AXI-Lite beat; desc_t = one whole descriptor. The master fetches
            // TaskDescBeats beats and commits them to its FIFO as a single atomic push.
            .data_t                       (host_axi_lite_data_t         ),
            .desc_t                       (logic [TaskDescBusWidth-1:0] )
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
    //////////////////////////////////////////////////////////////////////
    // Task queue → demux (direct connection, no mux needed)
    //////////////////////////////////////////////////////////////////////
    logic [TaskDescBusWidth-1:0] muxed_task_data;
    logic                        muxed_task_valid;

    assign muxed_task_data  = task_queue_mbox_data;
    assign muxed_task_valid = !task_queue_mbox_empty;
    assign task_queue_mbox_pop = stream_demux_core_type_inp_ready && !task_queue_mbox_empty;

    // Compose the current task descriptor from the muxed source
    assign cur_task_desc_full = bingo_hw_manager_task_desc_full_t'(muxed_task_data);
    assign cur_task_desc.task_id = cur_task_desc_full.task_id;
    assign cur_task_desc.task_type = cur_task_desc_full.task_type;
    assign cur_task_desc.assigned_chiplet_id = cur_task_desc_full.assigned_chiplet_id;
    assign cur_task_desc.assigned_cluster_id = cur_task_desc_full.assigned_cluster_id;
    assign cur_task_desc.assigned_core_id = cur_task_desc_full.assigned_core_id;
    assign cur_task_desc.dep_check_info = cur_task_desc_full.dep_check_info;
    assign cur_task_desc.dep_set_info = cur_task_desc_full.dep_set_info;
    assign cur_task_desc.cerf_carry = cur_task_desc_full.cerf_carry;
    // DARTS Tier 1: CERF fields
    assign cur_task_desc.cond_exec_en = cur_task_desc_full.cond_exec_en;
    assign cur_task_desc.cond_exec_group_id = cur_task_desc_full.cond_exec_group_id;
    assign cur_task_desc.cond_exec_invert = cur_task_desc_full.cond_exec_invert;


    /////////////////////////////////////////////////////////
    // H2H Dep Set Interface
    /////////////////////////////////////////////////////////       
    bingo_hw_manager_chiplet_dep_set #(
        .bingo_hw_manager_chiplet_msg_t   (bingo_hw_manager_chiplet_msg_full_t),
        .GlobalCerfGroups                             (GlobalCerfGroups       ),
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
        .cerf_global_state_i               (cerf_state[GlobalCerfGroups-1:0]   ),
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
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].cerf_carry = checkout_queue_data_out[core][cluster].cerf_carry;
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
    assign cur_chiplet_done_queue_msg = bingo_hw_manager_chiplet_msg_full_t'(chiplet_done_queue_mbox_data);
    assign chiplet_done_queue_mbox_pop =  stream_arbiter_dep_matrix_set_inp_ready[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET] && !chiplet_done_queue_mbox_empty;

    /// Carried predicate, receive side: the window is written in the SAME cycle
    /// the message's dep-set is granted, so both land on one clock edge and a
    /// consumer released by that set already sees the new predicate.
    logic [GlobalCerfGroups-1:0] cerf_global_write_data;
    logic                        cerf_global_write_en;
    assign cerf_global_write_en   = chiplet_done_queue_mbox_pop
                                 && cur_chiplet_done_queue_msg.cerf_valid;
    assign cerf_global_write_data = cur_chiplet_done_queue_msg.cerf_global;
    //////////////////////////////////////////////////////////////////////
    // Stream demux core type
    //////////////////////////////////////////////////////////////////////
    // DEMUX ON (core, cluster), NOT ON core ALONE.
    //
    // The waiting queue and its dep-check manager used to be indexed by core only, while the
    // ready queue downstream was already [core][cluster]. So all clusters' tasks for a given
    // core shared ONE in-order dep-check stream: cluster 3's GEMM task could not be checked
    // before cluster 0's, even when cluster 3's dependency was met first and cluster 0's was
    // not. With one cluster that costs nothing -- in-order is what a single core wants. With
    // four it serialises every cluster behind the other three, which dominates grant latency
    // on a multi-shard graph.
    //
    // Splitting the lane per (core, cluster) gives each cluster's stream the independence the
    // ready queues already had. The per-cluster demuxes that used to sit AFTER the dep check
    // are gone with it: the lane already knows its cluster.
    localparam int unsigned NUM_LANES = NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET;
    stream_demux #(
        .N_OUP ( NUM_LANES                       )
    ) i_stream_demux_core_type (
        .inp_valid_i ( stream_demux_core_type_inp_valid ),
        .inp_ready_o ( stream_demux_core_type_inp_ready ),
        .oup_sel_i   ( stream_demux_core_type_oup_sel   ),
        .oup_valid_o ( stream_demux_core_type_oup_valid ),
        .oup_ready_i ( stream_demux_core_type_oup_ready )
    );
    always_comb begin: compose_stream_demux_core_type_signals
        stream_demux_core_type_inp_valid = muxed_task_valid;
        stream_demux_core_type_oup_sel = cur_task_desc.assigned_core_id * NUM_CLUSTERS_PER_CHIPLET
                                       + cur_task_desc.assigned_cluster_id;
        for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl = cl + 1) begin
                stream_demux_core_type_oup_ready[core*NUM_CLUSTERS_PER_CHIPLET + cl] =
                    !waiting_dep_check_queue_full[core][cl];
            end
        end
    end


    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_waiting_dep_check_queue
      for (genvar cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl = cl + 1) begin: gen_wq_cluster
        fifo_v3 #(
            .FALL_THROUGH ( 1'b0                               ),
            .DEPTH        ( WaitingDepCheckQueueDepth          ),
            .dtype        ( bingo_hw_manager_task_desc_t       )
        ) i_waiting_dep_check_queue (
            .clk_i       ( clk_i                                    ),
            .rst_ni      ( rst_ni                                   ),
            .testmode_i  ( 1'b0                                     ),
            .flush_i     ( 1'b0                                     ),
            .full_o      ( waiting_dep_check_queue_full[core][cl]   ),
            .empty_o     ( waiting_dep_check_queue_empty[core][cl]  ),
            .usage_o     ( /*not used*/                             ),
            .data_i      ( cur_task_desc                            ),
            .push_i      ( waiting_dep_check_queue_push[core][cl]   ),
            .data_o      ( waiting_dep_check_task_desc[core][cl]    ),
            .pop_i       ( waiting_dep_check_queue_pop[core][cl]    )
        );
        assign waiting_dep_check_queue_push[core][cl] =
            stream_demux_core_type_oup_valid[core*NUM_CLUSTERS_PER_CHIPLET + cl]
            && !waiting_dep_check_queue_full[core][cl];
        assign waiting_dep_check_queue_pop[core][cl] =
            dep_check_manager_inp_wait_dep_check_queue_ready[core][cl]
            && !waiting_dep_check_queue_empty[core][cl];

        bingo_hw_manager_dep_check_manager i_dep_check_manager(
            .clk_i                       ( clk_i                        ),
            .rst_ni                      ( rst_ni                       ),
            .wait_dep_check_queue_valid_i(dep_check_manager_inp_wait_dep_check_queue_valid[core][cl]),
            .wait_dep_check_queue_ready_o(dep_check_manager_inp_wait_dep_check_queue_ready[core][cl]),
            .dep_check_valid_o           (dep_check_manager_oup_dep_check_valid[core][cl]),
            .dep_check_ready_i           (dep_check_manager_oup_dep_check_ready[core][cl]),
            .ready_and_checkout_queue_valid_o(dep_check_manager_oup_ready_and_checkout_queue_valid[core][cl]),
            .ready_and_checkout_queue_ready_i(dep_check_manager_oup_ready_and_checkout_queue_ready[core][cl])
        );
        assign dep_check_manager_inp_wait_dep_check_queue_valid[core][cl] =
            ~waiting_dep_check_queue_empty[core][cl];

        // To Dep Matrix. The lane already knows its cluster, so the filter drives the matrix
        // port directly -- the per-cluster demux that used to sit here is gone.
        stream_filter i_stream_filter_dep_check_en_to_dep_matrix (
            .valid_i ( dep_check_manager_oup_dep_check_valid[core][cl] ),
            .ready_o ( dep_check_manager_oup_dep_check_ready[core][cl] ),
            .drop_i  ( (!waiting_dep_check_task_desc[core][cl].dep_check_info.dep_check_en) ),
            .valid_o ( demux_dep_matrix_inp_valid[core][cl]  ),
            .ready_i ( demux_dep_matrix_inp_ready[core][cl]  )
        );
        assign demux_dep_matrix_oup_valid[core][cl] = demux_dep_matrix_inp_valid[core][cl];
        assign demux_dep_matrix_inp_ready[core][cl] = demux_dep_matrix_oup_ready[core][cl];

        // To Ready Queue and Checkout Queue. Dummy CHECK tasks are consumed here and never
        // reach a core, which is why they cost manager time but no dispatch.
        stream_filter i_stream_filter_dummy_check_task_to_ready_and_checkout_queue (
            .valid_i ( dep_check_manager_oup_ready_and_checkout_queue_valid[core][cl] ),
            .ready_o ( dep_check_manager_oup_ready_and_checkout_queue_ready[core][cl] ),
            .drop_i  ( (waiting_dep_check_task_desc[core][cl].task_type == 2'b01) &&
                       (waiting_dep_check_task_desc[core][cl].dep_check_info.dep_check_en) ),
            .valid_o ( demux_ready_and_checkout_queue_inp_valid[core][cl]  ),
            .ready_i ( demux_ready_and_checkout_queue_inp_ready[core][cl]  )
        );
        assign demux_ready_and_checkout_queue_oup_valid[core][cl] =
            demux_ready_and_checkout_queue_inp_valid[core][cl];
        assign demux_ready_and_checkout_queue_inp_ready[core][cl] =
            ready_queue_filter_inp_ready[core][cl] && !checkout_queue_full[core][cl];
        assign demux_ready_and_checkout_queue_oup_ready[core][cl] =
            ready_queue_filter_inp_ready[core][cl] && !checkout_queue_full[core][cl];
      end
    end


    ////////////////////////////////////////////////////////////////////////
    // Dep Matrix
    //////////////////////////////////////////////////////////////////////

    for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_dep_matrix
        bingo_hw_manager_dep_matrix #(
            .DEP_MATRIX_ROWS(NUM_CORES_PER_CLUSTER),
            .DEP_MATRIX_COLS(NUM_CORES_PER_CLUSTER),
            .TagWidth(DepTagWidth)
        ) i_dep_matrix (
            .clk_i             (clk_i                    ),
            .rst_ni            (rst_ni                   ),
            .dep_check_valid_i (dep_check_valid[cluster] ),
            .dep_check_code_i  (dep_check_code[cluster]  ),
            .dep_check_tag_i   (dep_check_tag[cluster]   ),
            .dep_check_result_o(dep_check_result[cluster]),
            .dep_set_valid_i   (dep_set_valid[cluster]   ),
            .dep_set_ready_o   (dep_set_ready[cluster]   ),
            .dep_set_code_i    (dep_set_code[cluster]    ),
            .dep_set_tag_i     (dep_set_tag[cluster]     )
        );
    end

    always_comb begin : connect_dep_check_for_dep_matrix
        for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                dep_check_valid[cluster][core] = demux_dep_matrix_oup_valid[core][cluster];
                demux_dep_matrix_oup_ready[core][cluster] = dep_check_result[cluster][core];
                dep_check_code[cluster][core] = waiting_dep_check_task_desc[core][cluster].dep_check_info.dep_check_code;
                dep_check_tag[cluster][core] = waiting_dep_check_task_desc[core][cluster].dep_check_info.dep_check_tag;
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
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_set_tag = checkout_queue_data_out[core][cluster].dep_set_info.dep_set_tag;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_set_code  = checkout_queue_data_out[core][cluster].dep_set_info.dep_set_code;
                    // Handshake from the checkout demux and the per-(core,cluster) done queue
                    // Dummy set: no done queue check needed
                    // Normal: per-(core,cluster) done queue must be non-empty
                    stream_arbiter_dep_matrix_set_inp_valid[stream_arbiter_inp_idx] = (checkout_queue_data_out[core][cluster].task_type == 2'b01) ?
                                                                                      stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster] :
                                                                                      ((stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster]) &&
                                                                                       (!done_q_empty[core][cluster]));
            end
        end
        // For Chiplet Set Queue
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_id  = cur_chiplet_done_queue_msg.dep_set_cluster_id;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_col = cur_chiplet_done_queue_msg.src_core_id;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_set_tag = cur_chiplet_done_queue_msg.dep_set_tag;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_set_code   = cur_chiplet_done_queue_msg.dep_set_code;
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
                dep_set_tag[cluster][core] = stream_arbiter_dep_matrix_set_oup_data.dep_matrix_set_tag;
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
            // Drop from ready queue if:
            // 1. Dummy set task (task_type==01, dep_set_en==1) — existing behavior
            // 2. DARTS CERF: conditionally skipped task — skip execution but propagate deps
            assign ready_queue_filter_drop[core][cluster] =
                ((waiting_dep_check_task_desc[core][cluster].task_type == 2'b01) &&
                 (waiting_dep_check_task_desc[core][cluster].dep_set_info.dep_set_en == 1'b1)) ||
                cond_exec_skip[core][cluster];
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
                // Connect to the core_status_waiting_task
                // This signal indicates whether the core is waiting for a task to be read from the ready queue
                // If ar_valid is high and r_ready is low, it means the core is waiting for a task
                assign core_status_waiting_task[core][cluster] = ready_queue_axi_lite_req_i[core][cluster].ar_valid && 
                                                                !ready_queue_axi_lite_req_i[core][cluster].r_ready;
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
                // Connect to the core_status_waiting_task
                // Since we do not have the axi lite interface, we tie off the ready queue axi lite resp signals
                assign ready_queue_axi_lite_resp_o[core][cluster] = '0;
            end
            assign ready_queue_base_addr[core][cluster] = ready_queue_base_addr_i +
                                                        (core + cluster * NUM_CORES_PER_CLUSTER) * ReadyQueueAddrOffset;
            assign ready_queue_data_in[core][cluster].task_id = waiting_dep_check_task_desc[core][cluster].task_id;
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
            // DARTS CERF: if task is conditionally skipped, mark as dummy (2'b01)
            // so checkout logic fires dep_set without done_queue match
            always_comb begin
                checkout_queue_data_in[core][cluster] = waiting_dep_check_task_desc[core][cluster];
                if (cond_exec_skip[core][cluster]) begin
                    checkout_queue_data_in[core][cluster].task_type = 2'b01;
                end
            end
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
            // Only drop the signal when dep set is disabled and the per-(core,cluster) done queue is non-empty
            assign stream_filter_checkout_queue_dep_set_enable_drop[core][cluster] =
                (checkout_queue_data_out[core][cluster].dep_set_info.dep_set_en == 1'b0) &&
                (!done_q_empty[core][cluster]);
            assign stream_filter_checkout_queue_dep_set_enable_oup_ready[core][cluster] = stream_arbiter_dep_matrix_set_inp_ready[core + cluster * NUM_CORES_PER_CLUSTER];

        end
    end

    //////////////////////////////////////////////////////////////////////
    // Local Per-Core Done Queues
    //////////////////////////////////////////////////////////////////////
    // Each core has its own done queue FIFO. This eliminates HOL blocking
    // where one core's completion stalls behind another core's entry in a
    // shared FIFO. Completions for different cores drain independently.

    if (READY_AND_DONE_QUEUE_INTERFACE_TYPE==0) begin: gen_done_queue_axi_lite_mailbox
        // AXI-Lite mailbox mode: single mailbox writes into a shared FIFO,
        // then we demux to per-(core,cluster) FIFOs based on done_info fields.
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
        assign cur_done_queue_info_axi = bingo_hw_manager_done_info_full_t'(done_queue_mbox_data);
        // Pop the mailbox when the target per-(core,cluster) FIFO accepts it
        assign done_queue_mbox_pop = !done_queue_mbox_empty &&
                                     !done_q_full[cur_done_queue_info_axi.assigned_core_id][cur_done_queue_info_axi.assigned_cluster_id];
        // Route mailbox data to per-(core,cluster) FIFOs
        always_comb begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    done_q_data_in[c][cl] = cur_done_queue_info_axi;
                    done_q_push[c][cl] = done_queue_mbox_pop &&
                        (cur_done_queue_info_axi.assigned_core_id == bingo_hw_manager_assigned_core_id_t'(c)) &&
                        (cur_done_queue_info_axi.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cl));
                end
            end
        end
    end else begin: gen_done_queue_generic_fifo
        // Generic FIFO mode: CSR writes go through arbiter, then demux to per-(core,cluster) FIFOs.
        assign done_queue_axi_lite_resp_o = '0;
        assign done_queue_mbox_empty = 1'b1;
        assign done_queue_mbox_data = '0;
        assign done_queue_mbox_pop = 1'b0;
    end

    // Per-(core, cluster) done queue FIFO instantiation
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin: gen_done_q_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin: gen_done_q_cluster
            fifo_v3 #(
                .FALL_THROUGH ( 1'b0                               ),
                .DEPTH        ( DoneQueueDepth                     ),
                .dtype        ( bingo_hw_manager_done_info_full_t  )
            ) i_done_q (
                .clk_i       ( clk_i                            ),
                .rst_ni      ( rst_ni                           ),
                .testmode_i  ( 1'b0                             ),
                .flush_i     ( 1'b0                             ),
                .full_o      ( done_q_full[core][cluster]       ),
                .empty_o     ( done_q_empty[core][cluster]      ),
                .usage_o     ( /*not used*/                     ),
                .data_i      ( done_q_data_in[core][cluster]    ),
                .push_i      ( done_q_push[core][cluster]       ),
                .data_o      ( done_q_info[core][cluster]       ),
                .pop_i       ( done_q_pop[core][cluster]        )
            );
        end
    end

    // Per-(core, cluster) done queue pop logic:
    // Pop when the checkout queue head for this (core, cluster) is a normal task
    // AND the arbiter accepted the dep_set. No cross-core or cross-cluster blocking.
    always_comb begin
        for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
            for (int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin
                // Normal (2'b00) and gating (2'b10) tasks need done_queue match
                done_q_pop[core][cluster] = !done_q_empty[core][cluster] &&
                    (checkout_queue_data_out[core][cluster].task_type == 2'b00 ||
                     checkout_queue_data_out[core][cluster].task_type == 2'b10) &&
                    stream_arbiter_dep_matrix_set_inp_ready[core + cluster * NUM_CORES_PER_CLUSTER];
            end
        end
    end

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
        // Connect to the core_status_waiting_task
        // This signal indicates whether the core is waiting for a task to be read from the ready queue
        // If csr_req_i.write==0 and csr_req_valid_i is high and csr_req_ready_o is low, it means the core is waiting for a task
        always_comb begin : connect_core_status_waiting_task_signals
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
                    core_status_waiting_task[core][cluster] = (csr_req_i[core][cluster].write == 1'b0) &&
                                                              csr_req_valid_i[core][cluster] &&
                                                              !csr_req_ready_o[core][cluster];
                end
            end
        end

        // For the Done Queue, we arbitrate all cores' write requests, then demux
        // the result to per-core FIFOs based on assigned_core_id in the data.
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
        // Extract core_id + cluster_id from the arbitrated done_info to route to per-(core,cluster) FIFO
        bingo_hw_manager_done_info_full_t write_done_info;
        assign write_done_info = bingo_hw_manager_done_info_full_t'(write_done_queue_data);
        // Route to per-(core, cluster) done queue FIFOs
        always_comb begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    done_q_data_in[c][cl] = write_done_info;
                    done_q_push[c][cl] = write_done_queue_valid &&
                        (write_done_info.assigned_core_id == bingo_hw_manager_assigned_core_id_t'(c)) &&
                        (write_done_info.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cl)) &&
                        !done_q_full[c][cl];
                end
            end
        end
        assign write_done_queue_ready = !done_q_full[write_done_info.assigned_core_id][write_done_info.assigned_cluster_id];


    end else begin: gen_no_csr_to_fifo_intf
        // If it is AXI Lite Mailbox interface, the ready queue and done queue interface are already connected
        // So we do not need to do anything here
        // Tie the csr signals to zero
        assign csr_req_ready_o = '0;
        assign csr_rsp_o = '0;
        assign csr_rsp_valid_o = '0;
    end

    //////////////////////////////////////////////////////////////////////
    // Power Manager
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_pm #(
        .NUM_CLUSTERS_PER_CHIPLET ( NUM_CLUSTERS_PER_CHIPLET          ),
        .NUM_CORES_PER_CLUSTER    ( NUM_CORES_PER_CLUSTER             ),
        .CfgBusWidth              ( DeviceAxiLiteDataWidth            ),
        .HOST_DVFS_MSIP_BIT       ( HOST_DVFS_MSIP_BIT                ),
        .req_lite_t               ( host_axi_lite_req_t               ),
        .resp_lite_t              ( host_axi_lite_resp_t              ),
        .addr_t                   ( host_axi_lite_addr_t              ),
        .data_t                   ( host_axi_lite_data_t              )
    ) i_bingo_hw_manager_pm (
        .clk_i                 ( clk_i                                 ),
        .rst_ni                ( rst_ni                                ),
        // Configuration from the host
        .enable_idle_pm_i      ( bingo_hw_manager_enable_idle_pm_i      ),
        .idle_power_level_i    ( bingo_hw_manager_idle_power_level_i    ),
        .normal_power_level_i  ( bingo_hw_manager_normal_power_level_i  ),
        .pm_base_addr_i        ( bingo_hw_manager_pm_base_addr_i        ),
        .core_power_domain_i   ( bingo_hw_manager_core_power_domain_i   ),
        // Internal Core status
        .core_status_waiting_task_i ( core_status_waiting_task         ),
        // DVFS mode: monitor + notify host
        .pm_mode_i             ( bingo_hw_manager_pm_mode_i             ),
        .dvfs_clint_msip_addr_i( bingo_hw_manager_dvfs_clint_msip_addr_i),
        .dvfs_ack_i            ( bingo_hw_manager_dvfs_ack_i            ),
        .dvfs_request_o        ( bingo_hw_manager_dvfs_request_o        ),
        // Interface to Host AXI Lite
        .pm_axi_lite_req_o     (pm_axi_lite_req_o                      ),
        .pm_axi_lite_resp_i    (pm_axi_lite_resp_i                     )
    );

    //////////////////////////////////////////////////////////////////////
    // DARTS Tier 3: Load Monitor
    //////////////////////////////////////////////////////////////////////
    bingo_hw_manager_load_monitor #(
        .NumCores   (NUM_CORES_PER_CLUSTER),
        .NumClusters(NUM_CLUSTERS_PER_CHIPLET),
        .CounterWidth(8)
    ) i_load_monitor (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .task_dispatched_i  (ready_queue_pop),
        .task_done_i        (done_q_push),
        .pending_per_core_o (/* unconnected: no CSR path exists yet; total_pending_o is the one that is read */),
        .total_pending_o    (load_total_pending_o)
    );

    //////////////////////////////////////////////////////////////////////
    // DARTS Tier 1: Conditional Execution Register File (CERF)
    //////////////////////////////////////////////////////////////////////

    bingo_hw_manager_cond_exec_controller #(
        .NumGroups(32)
    ) i_cerf (
        .clk_i            ( clk_i                  ),
        .rst_ni           ( rst_ni                 ),
        .cerf_state_o     ( cerf_state             ),
        .cerf_write_data_i( cerf_write_data_i      ),
        .cerf_write_en_i  ( cerf_write_en_i        ),
        .cerf_global_write_data_i( cerf_global_write_data ),
        .cerf_global_write_en_i  ( cerf_global_write_en   )
    );

endmodule