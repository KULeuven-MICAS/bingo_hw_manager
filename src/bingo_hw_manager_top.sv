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
    /// The chiplet set interface to other chiplets
    // HW Manager -----> Other chiplets
    input  host_axi_lite_addr_t                 chiplet_mailbox_base_addr_i,
    output host_axi_lite_req_t                  to_remote_chiplet_axi_lite_req_o,
    input  host_axi_lite_resp_t                 to_remote_chiplet_axi_lite_resp_i,
    /// The chiplet done interface from other chiplets
    input  host_axi_lite_req_t                  from_remote_chiplet_axi_lite_req_i,
    output host_axi_lite_resp_t                 from_remote_chiplet_axi_lite_resp_o,
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
    // AXI Lite Master Interface
    output host_axi_lite_req_t                  pm_axi_lite_req_o,
    input  host_axi_lite_resp_t                 pm_axi_lite_resp_i,
    // CERF (Conditional Execution Register File) interface
    input  logic                                cerf_write_en_i,
    input  logic [31:0]                         cerf_write_data_i,
    output logic [31:0]                         cerf_state_o
);
    // --------Type definitions and signal declarations--------------------//
    // ---- Start of Type definitions -------------------------------------//
    // Task Type (2 bits)
    typedef logic [1:0]                                  bingo_hw_manager_task_type_t;
    localparam bingo_hw_manager_task_type_t TT_NORMAL = 2'b00; // executes on core
    localparam bingo_hw_manager_task_type_t TT_DUMMY  = 2'b01; // set/check sync only
    localparam bingo_hw_manager_task_type_t TT_GATING = 2'b10; // executes on core + writes CERF
    localparam bingo_hw_manager_task_type_t TT_JIT    = 2'b11; // RESERVE if is_bind=0, BIND if is_bind=1
    // Task ID
    typedef logic [TaskIdWidth-1:0                     ] bingo_hw_manager_task_id_t;
    // Assigned Chiplet ID
    typedef logic [ChipIdWidth-1:0                     ] bingo_hw_manager_assigned_chiplet_id_t;
    // Assigned Cluster ID
    typedef logic [cf_math_pkg::idx_width(NUM_CLUSTERS_PER_CHIPLET)-1:0] bingo_hw_manager_assigned_cluster_id_t;
    // Assigned Core ID
    typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0   ] bingo_hw_manager_assigned_core_id_t;
    // JIT-DFG: WAIT_FOR_BIND column index in dep_matrix.
    // dep_check_code is widened by 1 bit relative to dep_set_code so a
    // RESERVE descriptor can block on a column that is set only by bind_resolver.
    localparam int unsigned WAIT_FOR_BIND_COL = NUM_CORES_PER_CLUSTER;
    // Dependency code types — split between check (widened for WAIT_FOR_BIND) and set (unchanged).
    // Cross-chiplet dep_set forwarding still uses NUM_CORES_PER_CLUSTER-wide code; bind transactions
    // use a private bind_set_* port on dep_matrix and never appear in dep_set_code.
    typedef logic [NUM_CORES_PER_CLUSTER-1:0]            bingo_hw_manager_dep_set_code_t;
    typedef logic [NUM_CORES_PER_CLUSTER:0]              bingo_hw_manager_dep_check_code_t;
    // Legacy alias retained for backward compatibility (e.g., dep_matrix_set_meta_t).
    typedef bingo_hw_manager_dep_set_code_t              bingo_hw_manager_dep_code_t;
    typedef struct packed{
        bingo_hw_manager_dep_check_code_t            dep_check_code;
        logic                                        dep_check_en;
    } bingo_hw_manager_dep_check_info_t;
    // Dependency set info struct
    // dep_set_info: NORMAL/DUMMY/GATING tasks use these as the post-completion
    // dep-set fields. RVDB-armed RESERVES (task_type==TT_JIT && is_bind==0)
    // *repurpose* the bits as chain config — see the rvdb_config write block
    // for the exact bit-by-bit mapping. BIND descriptors always use the
    // original dep_set semantics.
    typedef struct packed{
        bingo_hw_manager_dep_set_code_t              dep_set_code;
        bingo_hw_manager_assigned_cluster_id_t       dep_set_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       dep_set_chiplet_id;
        logic                                        dep_set_all_chiplet;
        logic                                        dep_set_en;
    } bingo_hw_manager_dep_set_info_t;

    // Logical slot ID — decoupled from physical core_id for dependency tracking.
    // dep_check/dep_set codes reference slot_id; the dispatcher maps slot→core at runtime.
    typedef logic [cf_math_pkg::idx_width(NUM_CORES_PER_CLUSTER)-1:0] bingo_hw_manager_slot_id_t;

    // Task info struct (includes conditional execution + slot_id fields)
    typedef struct packed{
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        // JIT-DFG: when task_type==2'b11, distinguishes RESERVE (0) from BIND (1).
        // Ignored for all other task_type values.
        logic                                        is_bind;
        // Conditional Execution
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
        // Task-Slot Scoreboard (decoupled from physical core_id)
        bingo_hw_manager_slot_id_t                   slot_id;
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
        // JIT-DFG: RESERVE (0) vs BIND (1); only meaningful when task_type==2'b11.
        logic                                        is_bind;
        // Conditional Execution
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
        // Task-Slot Scoreboard
        bingo_hw_manager_slot_id_t                   slot_id;
    } bingo_hw_manager_task_desc_full_t;

    // 64bit host-facing task descriptor.
    //
    // Mirrors task_desc_full_t but drops `slot_id` — slot_id is HW-internal,
    // synthesized as assigned_core_id at the AXI decode point (see the
    // cur_task_desc.slot_id assignment in the host-decode block). The
    // scoreboard's reassign_valid_i path is the only legitimate way for
    // slot_id to diverge from assigned_core_id at runtime, and it stays
    // entirely inside HW. Reserved bits absorb the freed log2(NUM_CORES) bits.
    localparam int unsigned TaskDescHostWidth        = TaskDescWidth - $bits(bingo_hw_manager_slot_id_t);
    localparam int unsigned ReservedBitsForTaskDescHost = HostAxiLiteDataWidth - TaskDescHostWidth;
    if (TaskDescHostWidth>HostAxiLiteDataWidth) begin : gen_task_desc_host_width_check
        initial begin
        $error("Host Task Descriptor width (%0d) exceeds Host AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", TaskDescHostWidth, HostAxiLiteDataWidth);
        $finish;
        end
    end
    typedef struct packed{
        logic [ReservedBitsForTaskDescHost-1:0]      reserved_bits;
        bingo_hw_manager_dep_set_info_t              dep_set_info;
        bingo_hw_manager_dep_check_info_t            dep_check_info;
        bingo_hw_manager_assigned_core_id_t          assigned_core_id;
        bingo_hw_manager_assigned_cluster_id_t       assigned_cluster_id;
        bingo_hw_manager_assigned_chiplet_id_t       assigned_chiplet_id;
        bingo_hw_manager_task_id_t                   task_id;
        bingo_hw_manager_task_type_t                 task_type;
        // JIT-DFG: RESERVE (0) vs BIND (1); only meaningful when task_type==2'b11.
        logic                                        is_bind;
        // Conditional Execution
        logic                                        cond_exec_en;
        logic [4:0]                                  cond_exec_group_id;
        logic                                        cond_exec_invert;
        // No slot_id — synthesized internally as assigned_core_id at decode.
    } bingo_hw_manager_task_desc_host_t;

    // RVDB: 8-bit kernel return value carried back from device via CSR 0x5ff.
    // Device packs {return_value[7:0], task_id[11:0]} into the 32-bit CSR write.
    // Kernels that don't return a meaningful value just write 0 (backward compatible).
    typedef logic [7:0]                            bingo_hw_manager_return_value_t;

    // SW-visible CSR write payload (TYPE==1 mode): only {return_value, task_id}
    // are SW-visible. The routing fields in done_info_full_t (assigned_core_id,
    // assigned_cluster_id, slot_id) are HW-stamped in csr_to_fifo from the
    // per-core CSR channel index — they never traverse the CSR write data bus.
    // This check mirrors the host-side TaskDescHost width check.
    localparam int unsigned DoneInfoCsrWidth = $bits(bingo_hw_manager_return_value_t)
                                                + $bits(bingo_hw_manager_task_id_t);
    if (DoneInfoCsrWidth>DeviceAxiLiteDataWidth) begin : gen_done_info_csr_width_check
        initial begin
        $error("Device done-info CSR payload {return_value, task_id} width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", DoneInfoCsrWidth, DeviceAxiLiteDataWidth);
        $finish;
        end
    end

    // CSR write payload type (TYPE==1 mode). csr_to_fifo casts the raw device
    // CSR write to this type and reads the fields by name (instead of
    // bit-slicing), so the device→manager SW contract is captured in one place.
    localparam int unsigned ReservedBitsForDoneInfoCsr = DeviceAxiLiteDataWidth - DoneInfoCsrWidth;
    typedef struct packed{
        logic [ReservedBitsForDoneInfoCsr-1:0]     reserved_bits;
        bingo_hw_manager_return_value_t            return_value;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_csr_t;

    // Mailbox-visible AXI-Lite payload (TYPE==0 mode). The shared mailbox can't
    // tell who wrote, so the writer (a device-side aggregator that knows the
    // source identity) must include {assigned_core_id, assigned_cluster_id}.
    // slot_id is NOT included — it's a HW-internal mapping that may be re-bound
    // at runtime by the scoreboard, and SW/aggregator must not need to track
    // it. The manager looks slot_id up from the scoreboard inverse table at
    // mbox dequeue, mirroring how csr_to_fifo stamps slot_id from the per-core
    // channel index in CSR mode.
    localparam int unsigned DoneInfoMboxWidth = $bits(bingo_hw_manager_return_value_t)
                                              + $bits(bingo_hw_manager_assigned_cluster_id_t)
                                              + $bits(bingo_hw_manager_assigned_core_id_t)
                                              + $bits(bingo_hw_manager_task_id_t);
    if (DoneInfoMboxWidth>DeviceAxiLiteDataWidth) begin : gen_done_info_mbox_width_check
        initial begin
        $error("Done-info mailbox payload width (%0d) exceeds Device AXI Lite Data Width (%0d)! Please adjust the parameters accordingly.", DoneInfoMboxWidth, DeviceAxiLiteDataWidth);
        $finish;
        end
    end
    localparam int unsigned ReservedBitsForDoneInfoMbox = DeviceAxiLiteDataWidth - DoneInfoMboxWidth;
    typedef struct packed{
        logic [ReservedBitsForDoneInfoMbox-1:0]    reserved_bits;
        bingo_hw_manager_return_value_t            return_value;
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_task_id_t                 task_id;
    } bingo_hw_manager_done_info_mbox_t;

    // Full stamped done-info — the SW-visible payload (return_value + task_id)
    // augmented with HW-stamped routing/slot metadata. Carried verbatim through
    // the per-(core,cluster) done FIFOs and through the chiplet-level done
    // arbiter; no AXI-width padding because nothing on this path is AXI-shaped
    // anymore. The AXI-Lite mailbox path (TYPE==0) still extracts these fields
    // out of an AXI word at its boundary, see cur_done_queue_info_axi below.
    typedef struct packed{
        bingo_hw_manager_return_value_t            return_value;
        bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
        bingo_hw_manager_assigned_core_id_t        assigned_core_id;
        bingo_hw_manager_slot_id_t                 slot_id;
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
    bingo_hw_manager_task_desc_host_t  cur_task_desc_host;
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
    // JIT-DFG: per-core observation of dep_check_manager FSM state (2-bit).
    // Used by bind_resolver to detect a RESERVE descriptor parked at the
    // queue head waiting on WAIT_FOR_BIND.
    logic [NUM_CORES_PER_CLUSTER-1:0][1:0]                       dep_check_manager_state;

    ////////////////////////////////
    // JIT-DFG bind_resolver signals
    ////////////////////////////////
    // Per-core merged-view output of bind_resolver. Replaces direct use of
    // waiting_dep_check_task_desc[core] in all downstream consumers
    // (cond_exec_skip eval, dep_check pipeline, ready/checkout queues).
    bingo_hw_manager_task_desc_t  [NUM_CORES_PER_CLUSTER-1:0] live_task_desc;
    logic                         [NUM_CORES_PER_CLUSTER-1:0] live_task_desc_valid;
    // Bind side-channel input handshake (per core).
    logic                         [NUM_CORES_PER_CLUSTER-1:0] bind_in_valid;
    logic                         [NUM_CORES_PER_CLUSTER-1:0] bind_in_ready;
    // Bind set pulse to dep_matrix (per core).
    logic                         [NUM_CORES_PER_CLUSTER-1:0] per_core_bind_set_valid;
    bingo_hw_manager_slot_id_t    [NUM_CORES_PER_CLUSTER-1:0] per_core_bind_set_slot;
    // Per-core classification for the local task-queue path: is the descriptor
    // currently demuxed to this core a BIND? (Used by both the upstream demux
    // ready logic and the cross-chiplet RX demux below.)
    logic                         [NUM_CORES_PER_CLUSTER-1:0] is_bind_for_core;

    ///////////////////////////////////////////////////////////////////////
    // RVDB (Return-Value-Driven Binding) signals
    ///////////////////////////////////////////////////////////////////////
    // Bind table parameters
    // 64 entries × 64-bit (one packed task descriptor per entry) per cluster.
    localparam int unsigned BIND_TABLE_ENTRIES = 64;
    localparam int unsigned BIND_TABLE_ADDR_W  = $clog2(BIND_TABLE_ENTRIES);

    // RVDB chain config per (cluster, source_slot): when a slot completes its
    // task, HW looks up this entry. If valid, fetch bind_table[table_base +
    // return_value] and inject a synthetic BIND for target_slot.
    typedef struct packed {
        logic                                  valid;
        bingo_hw_manager_slot_id_t             target_slot;
        logic [BIND_TABLE_ADDR_W-1:0]          table_base;
    } rvdb_config_entry_t;

    rvdb_config_entry_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] rvdb_config_q;

    // Per-cluster rvdb_lookup outputs — synthetic bind into the bind_resolver
    // 3-way bind input mux (third source after local task-queue and remote H2H).
    // Packed inner dim (per-core), unpacked outer dim (per-cluster) so that
    // `rvdb_synthetic_bind_*_per_cluster[cl]` is itself a packed array
    // matching the rvdb_lookup port type.
    logic                        [NUM_CORES_PER_CLUSTER-1:0] rvdb_synthetic_bind_valid_per_cluster [NUM_CLUSTERS_PER_CHIPLET];
    bingo_hw_manager_task_desc_t [NUM_CORES_PER_CLUSTER-1:0] rvdb_synthetic_bind_desc_per_cluster  [NUM_CLUSTERS_PER_CHIPLET];

    // Aggregated per-core synthetic bind (after collapsing across clusters
    // — the rvdb_lookup of the cluster that hosts the source slot drives it).
    logic                        [NUM_CORES_PER_CLUSTER-1:0]                       rvdb_bind_in_valid;
    bingo_hw_manager_task_desc_t [NUM_CORES_PER_CLUSTER-1:0]                       rvdb_bind_in_desc;

    // Bind-table load port — driven externally for now (a future loader will add an
    // AXI-master loader; for sim/TB the harness drives this directly).
    logic                                bind_table_load_en_i_int;
    logic [BIND_TABLE_ADDR_W-1:0]        bind_table_load_addr_i_int;
    logic [63:0]                         bind_table_load_data_i_int;
    // For now, tie off (will be driven by TB or future loader).
    assign bind_table_load_en_i_int   = 1'b0;
    assign bind_table_load_addr_i_int = '0;
    assign bind_table_load_data_i_int = '0;
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
    // Stage 1: drop dummy-set tasks
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_dummy_set_inp_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_dummy_set_inp_ready;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_dummy_set_drop;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_dummy_set_oup_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_dummy_set_oup_ready;
    // Stage 2: drop CERF conditionally-skipped tasks
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_cond_exec_skip_drop;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_oup_valid;
    logic                                   [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] ready_queue_filter_oup_ready;

    //////////////////////
    // Dep matrix signals
    //////////////////////
    // dep_check_code is widened by 1 bit so RESERVE descriptors can carry a
    // WAIT_FOR_BIND check bit; dep_set_code stays at NUM_CORES (cross-chiplet
    // forwarding compatibility). The matrix has NUM_CORES_PER_CLUSTER + 1
    // columns; the extra column is bind-only and the public dep_set_valid /
    // dep_set_code slot at that index is tied to 0 below.
    localparam int unsigned DEP_MATRIX_COLS_TOTAL = NUM_CORES_PER_CLUSTER + 1;
    typedef logic [DEP_MATRIX_COLS_TOTAL-1:0] dep_check_code_t;
    typedef logic [NUM_CORES_PER_CLUSTER-1:0] dep_set_code_t;

    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_check_valid;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0]            dep_check_result;
    dep_check_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] dep_check_code;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][DEP_MATRIX_COLS_TOTAL-1:0]            dep_set_valid;
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0][DEP_MATRIX_COLS_TOTAL-1:0]            dep_set_ready;
    dep_set_code_t [NUM_CLUSTERS_PER_CHIPLET-1:0][DEP_MATRIX_COLS_TOTAL-1:0]   dep_set_code;

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
    // CERF state and per-core conditional skip signals
    logic [31:0] cerf_state;
    assign cerf_state_o = cerf_state;  // read-back for SW
    logic [NUM_CORES_PER_CLUSTER-1:0] cond_exec_skip;

    // CERF: per-core conditional skip evaluation.
    // Only valid when there IS a task being processed (queue not empty).
    // When cond_exec_en==0 (default), this is always 0 regardless of CERF state.
    //
    // read cond_exec_* from the bind_resolver's live view, NOT
    // the raw FIFO entry. A bound descriptor's cond_exec fields come from the
    // bind, not the reservation. See bind_resolver merge logic.
    for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin: gen_cerf_skip
        logic cerf_group_active_for_core;
        assign cerf_group_active_for_core = cerf_state[live_task_desc[c].cond_exec_group_id];
        assign cond_exec_skip[c] = !waiting_dep_check_queue_empty[c] &&
                                    live_task_desc[c].cond_exec_en &&
                                    (live_task_desc[c].cond_exec_invert ?
                                        cerf_group_active_for_core : !cerf_group_active_for_core);
    end

    // Task-Slot Scoreboard (slot->core forward, core->slot inverse)
    ///////////////////////////////////////
    // Per-cluster write port
    logic                              [NUM_CLUSTERS_PER_CHIPLET-1:0] scoreboard_we;
    bingo_hw_manager_slot_id_t         [NUM_CLUSTERS_PER_CHIPLET-1:0] scoreboard_write_slot;
    bingo_hw_manager_assigned_core_id_t[NUM_CLUSTERS_PER_CHIPLET-1:0] scoreboard_write_core;
    // Inverse-view read port (one per cluster, driven by physical core_id)
    bingo_hw_manager_assigned_core_id_t[NUM_CLUSTERS_PER_CHIPLET-1:0] scoreboard_inv_read_core;
    bingo_hw_manager_slot_id_t         [NUM_CLUSTERS_PER_CHIPLET-1:0] scoreboard_inv_read_slot;
    // Forward-view read port (currently unused, reserved for future fault-recovery)
    bingo_hw_manager_slot_id_t         [NUM_CLUSTERS_PER_CHIPLET-1:0] scoreboard_read_slot;
    bingo_hw_manager_assigned_core_id_t[NUM_CLUSTERS_PER_CHIPLET-1:0] scoreboard_read_core;
    logic                              [NUM_CLUSTERS_PER_CHIPLET-1:0] scoreboard_read_valid;
    // Full inverse-table (per cluster): scoreboard_inv_table[cluster][core] = slot_id
    bingo_hw_manager_slot_id_t         [NUM_CLUSTERS_PER_CHIPLET-1:0][NUM_CORES_PER_CLUSTER-1:0] scoreboard_inv_table;

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
    //////////////////////////////////////////////////////////////////////
    // Task queue → demux (direct connection, no mux needed)
    //////////////////////////////////////////////////////////////////////
    host_axi_lite_data_t muxed_task_data;
    logic                muxed_task_valid;

    assign muxed_task_data  = task_queue_mbox_data;
    assign muxed_task_valid = !task_queue_mbox_empty;
    assign task_queue_mbox_pop = stream_demux_core_type_inp_ready && !task_queue_mbox_empty;

    // Compose the current task descriptor from the muxed source.
    // Host writes task_desc_host_t (no slot_id); HW synthesizes slot_id =
    // assigned_core_id here. After decode, slot_id and assigned_core_id can
    // only diverge via the scoreboard's reassign_valid_i path.
    assign cur_task_desc_host = bingo_hw_manager_task_desc_host_t'(muxed_task_data);
    assign cur_task_desc.task_id = cur_task_desc_host.task_id;
    assign cur_task_desc.task_type = cur_task_desc_host.task_type;
    assign cur_task_desc.assigned_chiplet_id = cur_task_desc_host.assigned_chiplet_id;
    assign cur_task_desc.assigned_cluster_id = cur_task_desc_host.assigned_cluster_id;
    assign cur_task_desc.assigned_core_id = cur_task_desc_host.assigned_core_id;
    assign cur_task_desc.dep_check_info = cur_task_desc_host.dep_check_info;
    assign cur_task_desc.dep_set_info = cur_task_desc_host.dep_set_info;
    // CERF fields
    assign cur_task_desc.cond_exec_en = cur_task_desc_host.cond_exec_en;
    assign cur_task_desc.cond_exec_group_id = cur_task_desc_host.cond_exec_group_id;
    assign cur_task_desc.cond_exec_invert = cur_task_desc_host.cond_exec_invert;
    // JIT-DFG: propagate is_bind so RESERVE vs BIND survives the demux
    assign cur_task_desc.is_bind = cur_task_desc_host.is_bind;
    // slot_id is HW-internal — synthesize as assigned_core_id at decode.
    assign cur_task_desc.slot_id = cur_task_desc_host.assigned_core_id;


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
                // Propagate CERF + slot_id fields across chiplets — required for slot-indexed dep_matrix at the receiver
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].cond_exec_en = checkout_queue_data_out[core][cluster].cond_exec_en;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].cond_exec_group_id = checkout_queue_data_out[core][cluster].cond_exec_group_id;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].cond_exec_invert = checkout_queue_data_out[core][cluster].cond_exec_invert;
                stream_arbiter_chiplet_dep_set_inp_task_desc[core + cluster * NUM_CORES_PER_CLUSTER].slot_id = checkout_queue_data_out[core][cluster].slot_id;
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
        .req_i       (from_remote_chiplet_axi_lite_req_i        ),
        .resp_o      (from_remote_chiplet_axi_lite_resp_o       ),
        .irq_o       (/*not used*/                      ),
        .base_addr_i (chiplet_mailbox_base_addr_i       ),
        .mbox_data_o (chiplet_done_queue_mbox_data      ),
        .mbox_pop_i  (chiplet_done_queue_mbox_pop       ),
        .mbox_empty_o(chiplet_done_queue_mbox_empty     ),
        .mbox_flush_i('0                                )
    );
    assign cur_chiplet_done_queue_task_desc = bingo_hw_manager_task_desc_full_t'(chiplet_done_queue_mbox_data);

    // JIT-DFG cross-chiplet bind RX demux:
    //   When a remote chiplet forwards a BIND descriptor via H2H, route it
    //   into the LOCAL bind side-channel of the target core instead of the
    //   dep_matrix set arbiter. Non-bind H2H descriptors keep the existing
    //   dep_set forwarding path.
    logic chiplet_remote_is_bind;
    assign chiplet_remote_is_bind = !chiplet_done_queue_mbox_empty &&
                                    (cur_chiplet_done_queue_task_desc.task_type == TT_JIT) &&
                                    cur_chiplet_done_queue_task_desc.is_bind;
    // Per-core: is the H2H descriptor a bind targeting THIS core?
    logic [NUM_CORES_PER_CLUSTER-1:0] remote_bind_for_core;
    always_comb begin
        for (int unsigned co = 0; co < NUM_CORES_PER_CLUSTER; co++) begin
            remote_bind_for_core[co] = chiplet_remote_is_bind &&
                (cur_chiplet_done_queue_task_desc.assigned_core_id ==
                 bingo_hw_manager_assigned_core_id_t'(co));
        end
    end
    // Per-core bind acceptance: local task-queue bind takes priority; else remote.
    logic [NUM_CORES_PER_CLUSTER-1:0] remote_bind_accept;
    always_comb begin
        for (int unsigned co = 0; co < NUM_CORES_PER_CLUSTER; co++) begin
            remote_bind_accept[co] = remote_bind_for_core[co] &&
                                     !is_bind_for_core[co] &&
                                     bind_in_ready[co];
        end
    end
    // Drain the H2H mbox when either:
    //   (a) the dep_matrix set arbiter accepted the descriptor (non-bind path), OR
    //   (b) some core's remote-bind path accepted it.
    assign chiplet_done_queue_mbox_pop =
        (!chiplet_remote_is_bind &&
         stream_arbiter_dep_matrix_set_inp_ready[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET] &&
         !chiplet_done_queue_mbox_empty) ||
        (|remote_bind_accept);
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
    // JIT-DFG: per-core descriptor classification (combinational).
    // A BIND descriptor must NOT push into the wait queue — it goes straight to
    // bind_resolver via the bind side-channel handshake.
    // (Declaration of is_bind_for_core is at the JIT signals section above.)
    always_comb begin
        for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            is_bind_for_core[core] = stream_demux_core_type_oup_valid[core] &&
                                      (cur_task_desc.task_type == TT_JIT) &&
                                      cur_task_desc.is_bind;
        end
    end

    always_comb begin: compose_stream_demux_core_type_signals
        stream_demux_core_type_inp_valid = muxed_task_valid;
        stream_demux_core_type_oup_sel = cur_task_desc.assigned_core_id;
        for (int unsigned core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
            // Per-core combined ready: BIND consumes via bind_resolver, others
            // push into the wait queue.
            stream_demux_core_type_oup_ready[core] = is_bind_for_core[core]
                                                     ? bind_in_ready[core]
                                                     : !waiting_dep_check_queue_full[core];
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
        // JIT-DFG: BIND descriptors bypass the wait queue; only RESERVE / NORMAL /
        // DUMMY / GATING tasks push.
        assign waiting_dep_check_queue_push[core] =
            stream_demux_core_type_oup_valid[core] &&
            !is_bind_for_core[core] &&
            !waiting_dep_check_queue_full[core];
        assign waiting_dep_check_queue_pop[core] = dep_check_manager_inp_wait_dep_check_queue_ready[core] && !waiting_dep_check_queue_empty[core];

        // JIT-DFG: bind_resolver — sits between the FIFO and dep_check_manager.
        // The bind side-channel input is multiplexed between THREE sources:
        //   (a) local task-queue (cur_task_desc) when is_bind_for_core[core]
        //   (b) cross-chiplet H2H arrival when remote_bind_for_core[core]
        //   (c) RVDB synthetic bind from rvdb_lookup when rvdb_bind_in_valid[core]
        // Priority: local > rvdb > remote. live_task_desc[core] replaces direct
        // use of waiting_dep_check_task_desc[core] in all downstream consumers
        // (cond_exec_skip must read the live merged view).
        bingo_hw_manager_task_desc_t bind_in_mux_desc;
        logic                        bind_in_mux_valid;
        always_comb begin
            if (is_bind_for_core[core]) begin
                bind_in_mux_desc  = cur_task_desc;
                bind_in_mux_valid = 1'b1;
            end else if (rvdb_bind_in_valid[core]) begin
                // RVDB synthetic bind — already a fully-formed task descriptor;
                // no field-by-field cast needed.
                bind_in_mux_desc  = rvdb_bind_in_desc[core];
                bind_in_mux_valid = 1'b1;
            end else if (remote_bind_for_core[core]) begin
                // Cast the full descriptor (no reserved bits) into the slim type.
                bind_in_mux_desc.dep_set_info        = cur_chiplet_done_queue_task_desc.dep_set_info;
                bind_in_mux_desc.dep_check_info      = cur_chiplet_done_queue_task_desc.dep_check_info;
                bind_in_mux_desc.assigned_core_id    = cur_chiplet_done_queue_task_desc.assigned_core_id;
                bind_in_mux_desc.assigned_cluster_id = cur_chiplet_done_queue_task_desc.assigned_cluster_id;
                bind_in_mux_desc.assigned_chiplet_id = cur_chiplet_done_queue_task_desc.assigned_chiplet_id;
                bind_in_mux_desc.task_id             = cur_chiplet_done_queue_task_desc.task_id;
                bind_in_mux_desc.task_type           = cur_chiplet_done_queue_task_desc.task_type;
                bind_in_mux_desc.is_bind             = cur_chiplet_done_queue_task_desc.is_bind;
                bind_in_mux_desc.cond_exec_en        = cur_chiplet_done_queue_task_desc.cond_exec_en;
                bind_in_mux_desc.cond_exec_group_id  = cur_chiplet_done_queue_task_desc.cond_exec_group_id;
                bind_in_mux_desc.cond_exec_invert    = cur_chiplet_done_queue_task_desc.cond_exec_invert;
                bind_in_mux_desc.slot_id             = cur_chiplet_done_queue_task_desc.slot_id;
                bind_in_mux_valid = 1'b1;
            end else begin
                bind_in_mux_desc  = '0;
                bind_in_mux_valid = 1'b0;
            end
        end
        bingo_hw_manager_bind_resolver #(
            .task_desc_full_t ( bingo_hw_manager_task_desc_t ),
            .NUM_SLOTS        ( NUM_CORES_PER_CLUSTER        ),
            .PENDING_DEPTH    ( 2                            )
        ) i_bind_resolver (
            .clk_i                       ( clk_i                                       ),
            .rst_ni                      ( rst_ni                                      ),
            .flush_i                     ( 1'b0                                        ),
            .task_desc_at_queue_head_i   ( waiting_dep_check_task_desc[core]           ),
            .queue_head_valid_i          ( ~waiting_dep_check_queue_empty[core]        ),
            .dep_check_manager_state_i   ( dep_check_manager_state[core]               ),
            .bind_in_desc_i              ( bind_in_mux_desc                            ),
            .bind_in_valid_i             ( bind_in_mux_valid                           ),
            .bind_in_ready_o             ( bind_in_ready[core]                         ),
            .live_task_desc_o            ( live_task_desc[core]                        ),
            .live_task_desc_valid_o      ( live_task_desc_valid[core]                  ),
            .bind_set_valid_o            ( per_core_bind_set_valid[core]               ),
            .bind_set_slot_o             ( per_core_bind_set_slot[core]                )
        );
        assign bind_in_valid[core] = bind_in_mux_valid;

        bingo_hw_manager_dep_check_manager i_dep_check_manager(
            .clk_i                       ( clk_i                        ),
            .rst_ni                      ( rst_ni                       ),
            .wait_dep_check_queue_valid_i(dep_check_manager_inp_wait_dep_check_queue_valid[core]),
            .wait_dep_check_queue_ready_o(dep_check_manager_inp_wait_dep_check_queue_ready[core]),
            .dep_check_valid_o           (dep_check_manager_oup_dep_check_valid[core]),
            .dep_check_ready_i           (dep_check_manager_oup_dep_check_ready[core]),
            .ready_and_checkout_queue_valid_o(dep_check_manager_oup_ready_and_checkout_queue_valid[core]),
            .ready_and_checkout_queue_ready_i(dep_check_manager_oup_ready_and_checkout_queue_ready[core]),
            // JIT-DFG: expose FSM state for bind_resolver observation
            .state_o                     (dep_check_manager_state[core])
        );
        assign dep_check_manager_inp_wait_dep_check_queue_valid[core] = ~waiting_dep_check_queue_empty[core];
        // To Dep Matrix
        // JIT-DFG: read dep_check_en from the live (post-bind) view so a bound
        // descriptor's dep_check_en is honoured.
        stream_filter i_stream_filter_dep_check_en_to_dep_matrix (
            .valid_i ( dep_check_manager_oup_dep_check_valid[core]    ),
            .ready_o ( dep_check_manager_oup_dep_check_ready[core]    ),
            .drop_i  ( (!live_task_desc[core].dep_check_info.dep_check_en) ),
            .valid_o ( demux_dep_matrix_inp_valid[core]  ),
            .ready_i ( demux_dep_matrix_inp_ready[core]  )
        );
        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_from_waiting_dep_check_queue_to_dep_matrix (
            .inp_valid_i ( demux_dep_matrix_inp_valid[core]    ),
            .inp_ready_o ( demux_dep_matrix_inp_ready[core]    ),
            .oup_sel_i   ( live_task_desc[core].assigned_cluster_id ),
            .oup_valid_o ( demux_dep_matrix_oup_valid[core]    ),
            .oup_ready_i ( demux_dep_matrix_oup_ready[core]    )
        );
        // To Ready Queue and Checkout Queue
        // JIT-DFG: dummy_check filter reads live view; bound descriptors with
        // task_type=2'b00 are not dropped here.
        stream_filter i_stream_filter_dummy_check_task_to_ready_and_checkout_queue (
            .valid_i ( dep_check_manager_oup_ready_and_checkout_queue_valid[core]    ),
            .ready_o ( dep_check_manager_oup_ready_and_checkout_queue_ready[core]    ),
            .drop_i  ( (live_task_desc[core].task_type == TT_DUMMY) && (live_task_desc[core].dep_check_info.dep_check_en) ), // Drop if it is a dummy check task
            .valid_o ( demux_ready_and_checkout_queue_inp_valid[core]  ),
            .ready_i ( demux_ready_and_checkout_queue_inp_ready[core]  )
        );
        stream_demux #(
            .N_OUP ( NUM_CLUSTERS_PER_CHIPLET           )
        ) i_stream_demux_from_waiting_dep_check_queue_to_ready_and_checkout_queue (
            .inp_valid_i ( demux_ready_and_checkout_queue_inp_valid[core]    ),
            .inp_ready_o ( demux_ready_and_checkout_queue_inp_ready[core]    ),
            .oup_sel_i   ( live_task_desc[core].assigned_cluster_id          ),
            .oup_valid_o ( demux_ready_and_checkout_queue_oup_valid[core]    ),
            .oup_ready_i ( demux_ready_and_checkout_queue_oup_ready[core]    )
        );

        always_comb begin : connect_demux_ready_and_checkout_queue_ready_signals
            for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin 
                demux_ready_and_checkout_queue_oup_ready[core][cluster] = ready_queue_filter_dummy_set_inp_ready[core][cluster] && !checkout_queue_full[core][cluster];
            end
        end
    end


    ////////////////////////////////////////////////////////////////////////
    // Dep Matrix
    //////////////////////////////////////////////////////////////////////

    // JIT-DFG: per-cluster bind_set aggregation. A bind merge fires bind_set
    // on exactly one core's bind_resolver in a given cycle (ensured by the
    // upstream demux serialising new binds, plus pending-buffer drains being
    // gated on head match per core). We OR-reduce the valid and use a priority
    // selector for the slot index; the in-cluster SVA flags multi-fire.
    logic                            [NUM_CLUSTERS_PER_CHIPLET-1:0] cluster_bind_set_valid;
    bingo_hw_manager_slot_id_t       [NUM_CLUSTERS_PER_CHIPLET-1:0] cluster_bind_set_slot;
    always_comb begin : aggregate_bind_set_per_cluster
        for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
            cluster_bind_set_valid[cl] = 1'b0;
            cluster_bind_set_slot [cl] = '0;
            for (int unsigned co = 0; co < NUM_CORES_PER_CLUSTER; co++) begin
                if (per_core_bind_set_valid[co] &&
                    (live_task_desc[co].assigned_cluster_id ==
                     bingo_hw_manager_assigned_cluster_id_t'(cl))) begin
                    if (!cluster_bind_set_valid[cl]) begin
                        cluster_bind_set_valid[cl] = 1'b1;
                        cluster_bind_set_slot [cl] = per_core_bind_set_slot[co];
                    end
                end
            end
        end
    end

    for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_dep_matrix
        bingo_hw_manager_dep_matrix #(
            .DEP_MATRIX_ROWS(NUM_CORES_PER_CLUSTER),
            // +1 column for WAIT_FOR_BIND (JIT-DFG); the extra column is set only
            // via the private bind_set_* port driven by bind_resolver instances.
            .DEP_MATRIX_COLS(NUM_CORES_PER_CLUSTER + 1)
        ) i_dep_matrix (
            .clk_i             (clk_i                    ),
            .rst_ni            (rst_ni                   ),
            .dep_check_valid_i (dep_check_valid[cluster] ),
            .dep_check_code_i  (dep_check_code[cluster]  ),
            .dep_check_result_o(dep_check_result[cluster]),
            .dep_set_valid_i   (dep_set_valid[cluster]   ),
            .dep_set_ready_o   (dep_set_ready[cluster]   ),
            .dep_set_code_i    (dep_set_code[cluster]    ),
            // JIT-DFG bind set port — driven by the per-cluster aggregator above.
            .bind_set_valid_i  (cluster_bind_set_valid[cluster]),
            .bind_set_slot_i   (cluster_bind_set_slot [cluster])
        );
    end

    /////////////////////////////////////////////////////////////////////////
    // RVDB — bind_table + rvdb_lookup unit per cluster
    /////////////////////////////////////////////////////////////////////////
    // The bind_table holds 64 packed task descriptors per cluster. Loaded
    // once at init via the load_en port; runtime reads are combinational.
    // The rvdb_lookup unit observes per-(core,cluster) done-queue pops, looks
    // up the chain config + bind table, and synthesises a BIND descriptor
    // routed to the target core's bind side-channel.
    // For these signals the OUTER index is the cluster (one value per cluster),
    // so we use unpacked outer + packed inner. `foo[cl]` then returns the
    // per-cluster packed value, which the rvdb_lookup port expects.
    logic                                    [NUM_CLUSTERS_PER_CHIPLET-1:0] bt_loaded;
    logic [BIND_TABLE_ADDR_W-1:0]            bt_read_addr [NUM_CLUSTERS_PER_CHIPLET];
    bingo_hw_manager_task_desc_t                                            bt_read_data [NUM_CLUSTERS_PER_CHIPLET];
    // rvdb_config read view (per-cluster, indexed by source_slot)
    logic [NUM_CLUSTERS_PER_CHIPLET-1:0]                                    cfg_valid;
    bingo_hw_manager_slot_id_t           cfg_target_slot [NUM_CLUSTERS_PER_CHIPLET];
    logic [BIND_TABLE_ADDR_W-1:0]        cfg_table_base  [NUM_CLUSTERS_PER_CHIPLET];
    bingo_hw_manager_slot_id_t           cfg_read_addr   [NUM_CLUSTERS_PER_CHIPLET];

    for (genvar cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl = cl + 1) begin: gen_rvdb
        // Per-cluster bind_table SRAM. Entries are 64-bit packed task descriptors;
        // we pack/unpack via a width-matched cast since task_desc_t is the same width.
        logic [63:0] bt_data_packed;
        bingo_hw_manager_bind_table #(
            .NUM_ENTRIES(BIND_TABLE_ENTRIES),
            .ENTRY_WIDTH(64)
        ) i_bind_table (
            .clk_i      (clk_i                       ),
            .rst_ni     (rst_ni                      ),
            .load_en_i  (bind_table_load_en_i_int    ),
            .load_addr_i(bind_table_load_addr_i_int  ),
            .load_data_i(bind_table_load_data_i_int  ),
            .read_addr_i(bt_read_addr[cl]            ),
            .read_data_o(bt_data_packed              ),
            .loaded_o   (bt_loaded[cl]               )
        );
        // Cast packed 64-bit entry into a task descriptor view. The bind_table
        // entry layout intentionally matches `bingo_hw_manager_task_desc_t`'s
        // bit layout so this is a pure reinterpret.
        assign bt_read_data[cl] = bingo_hw_manager_task_desc_t'(bt_data_packed[$bits(bingo_hw_manager_task_desc_t)-1:0]);

        // rvdb_config[cl] read port — combinational by `source_slot` index.
        // Also drives `cfg_*` to the rvdb_lookup unit.
        assign cfg_valid       [cl] = rvdb_config_q[cl][cfg_read_addr[cl]].valid;
        assign cfg_target_slot [cl] = rvdb_config_q[cl][cfg_read_addr[cl]].target_slot;
        assign cfg_table_base  [cl] = rvdb_config_q[cl][cfg_read_addr[cl]].table_base;

        // Per-cluster done_pop and done_info fed into rvdb_lookup. We splat
        // the per-(core,cluster) done queues into a per-core slice for this
        // cluster.
        logic                             [NUM_CORES_PER_CLUSTER-1:0] done_pop_per_core;
        bingo_hw_manager_done_info_full_t [NUM_CORES_PER_CLUSTER-1:0] done_info_per_core;
        for (genvar co = 0; co < NUM_CORES_PER_CLUSTER; co = co + 1) begin: gen_rvdb_done_slice
            assign done_pop_per_core [co] = done_q_pop [co][cl];
            assign done_info_per_core[co] = done_q_info[co][cl];
        end

        bingo_hw_manager_rvdb_lookup #(
            .NUM_CORES_PER_CLUSTER(NUM_CORES_PER_CLUSTER),
            .task_desc_full_t     (bingo_hw_manager_task_desc_t),
            .done_info_full_t     (bingo_hw_manager_done_info_full_t),
            .BIND_TABLE_ENTRIES   (BIND_TABLE_ENTRIES)
        ) i_rvdb_lookup (
            .clk_i                 (clk_i                                  ),
            .rst_ni                (rst_ni                                 ),
            .done_pop_i            (done_pop_per_core                      ),
            .done_info_i           (done_info_per_core                     ),
            .cfg_read_addr_o       (cfg_read_addr[cl]                      ),
            .cfg_valid_i           (cfg_valid[cl]                          ),
            .cfg_target_slot_i     (cfg_target_slot[cl]                    ),
            .cfg_table_base_i      (cfg_table_base[cl]                     ),
            .bt_read_addr_o        (bt_read_addr[cl]                       ),
            .bt_read_data_i        (bt_read_data[cl]                       ),
            .bt_loaded_i           (bt_loaded[cl]                          ),
            .synthetic_bind_valid_o(rvdb_synthetic_bind_valid_per_cluster[cl]),
            .synthetic_bind_desc_o (rvdb_synthetic_bind_desc_per_cluster [cl])
        );
    end

    // Aggregate the per-cluster synthetic binds into a per-core view that the
    // bind_in_mux at each bind_resolver site consumes. The target cluster is
    // inferred from the bind descriptor's `assigned_cluster_id`; only one
    // cluster's rvdb_lookup will fire for any given core in any given cycle
    // (the cluster that hosts the chain's source slot).
    always_comb begin : aggregate_rvdb_bind_per_core
        for (int unsigned co = 0; co < NUM_CORES_PER_CLUSTER; co++) begin
            rvdb_bind_in_valid[co] = 1'b0;
            rvdb_bind_in_desc [co] = '0;
            for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                if (rvdb_synthetic_bind_valid_per_cluster[cl][co]) begin
                    rvdb_bind_in_valid[co] = 1'b1;
                    rvdb_bind_in_desc [co] = rvdb_synthetic_bind_desc_per_cluster[cl][co];
                end
            end
        end
    end

    //////////////////////////////////////////////////////////////////////
    // Task-Slot Scoreboard (one per cluster)
    //
    // Write trigger: any waiting_dep_check_queue_push[*] whose target cluster
    // matches this scoreboard. All per-core pushes in a cycle share the same
    // `cur_task_desc` (stream_demux_core_type selects exactly one core), so we
    // can pull write_slot / write_core straight from cur_task_desc.
    //
    // `reassign_*` is currently tied off; a future fault-recovery controller
    // will drive these ports from a host-visible CSR.
    //////////////////////////////////////////////////////////////////////
    for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_scoreboard
        assign scoreboard_we[cluster] =
            (|waiting_dep_check_queue_push) &&
            (cur_task_desc.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cluster));
        assign scoreboard_write_slot[cluster] = cur_task_desc.slot_id;
        assign scoreboard_write_core[cluster] = cur_task_desc.assigned_core_id;
        // Forward-view + scalar inverse read ports are currently unused — tie off.
        assign scoreboard_read_slot[cluster]     = '0;
        assign scoreboard_inv_read_core[cluster] = '0;

        bingo_hw_manager_scoreboard #(
            .NUM_SLOTS (NUM_CORES_PER_CLUSTER),
            .slot_id_t (bingo_hw_manager_slot_id_t),
            .core_id_t (bingo_hw_manager_assigned_core_id_t)
        ) i_scoreboard (
            .clk_i            (clk_i                            ),
            .rst_ni           (rst_ni                           ),
            .we_i             (scoreboard_we[cluster]           ),
            .write_slot_i     (scoreboard_write_slot[cluster]   ),
            .write_core_i     (scoreboard_write_core[cluster]   ),
            // Fault-recovery hook — tied off
            .reassign_valid_i (1'b0                             ),
            .reassign_slot_i  ('0                               ),
            .reassign_core_i  ('0                               ),
            // Forward read (currently unused)
            .read_slot_i      (scoreboard_read_slot[cluster]    ),
            .read_core_o      (scoreboard_read_core[cluster]    ),
            .read_valid_o     (scoreboard_read_valid[cluster]   ),
            // Inverse read (scalar — currently unused, full table drives done path)
            .inv_read_core_i  (scoreboard_inv_read_core[cluster]),
            .inv_read_slot_o  (scoreboard_inv_read_slot[cluster]),
            // Full-table debug + full inverse table for done-path stamping
            .table_core_o     (                                 ),
            .table_valid_o    (                                 ),
            .inv_table_o      (scoreboard_inv_table[cluster]    )
        );
    end

    /////////////////////////////////////////////////////////////////////////
    // RVDB chain config write
    //
    // When a RESERVE descriptor (`task_type=2'b11, is_bind=0`) lands and its
    // `rvdb_chain_en` bit is set (= the repurposed `dep_set_en` bit), HW writes
    // `rvdb_config[cluster][rvdb_source_slot]` with:
    //   {valid=1, target_slot=cur_task_desc.slot_id, table_base=rvdb_table_base}
    //
    // Repurposed bit layout (only meaningful when task_type=TT_JIT && is_bind=0):
    //   dep_set_info.dep_set_en                                      → rvdb_chain_en
    //   dep_set_info.dep_set_code[$bits(slot_id_t)-1:0]              → rvdb_source_slot
    //   dep_set_info.dep_set_chiplet_id[BIND_TABLE_ADDR_W-1:0]       → rvdb_table_base
    // (Width-safe across NUM_CORES_PER_CLUSTER variations: dep_set_chiplet_id
    //  is always 8 bits, comfortably wider than the 6-bit table_base.)
    /////////////////////////////////////////////////////////////////////////
    logic                                  cur_reserve_is_jit;
    logic                                  cur_reserve_rvdb_chain_en;
    bingo_hw_manager_slot_id_t             cur_reserve_rvdb_source_slot;
    logic [BIND_TABLE_ADDR_W-1:0]          cur_reserve_rvdb_table_base;

    assign cur_reserve_is_jit           = (cur_task_desc.task_type == TT_JIT) &&
                                          !cur_task_desc.is_bind;
    assign cur_reserve_rvdb_chain_en    = cur_reserve_is_jit && cur_task_desc.dep_set_info.dep_set_en;
    // Take the bottom log2(NUM_CORES) bits of dep_set_code as the source slot.
    // For NUM_CORES_PER_CLUSTER=4 this is [1:0]; the slot_id_t typedef enforces
    // the width via the assignment.
    assign cur_reserve_rvdb_source_slot = cur_task_desc.dep_set_info.dep_set_code[$bits(bingo_hw_manager_slot_id_t)-1:0];
    // Pack the table_base (6 bits) into the unused dep_set_chiplet_id field
    // (8 bits, always wide enough). Width-safe across all NUM_CORES_PER_CLUSTER
    // values; trivially extractable on both HW and host sides.
    assign cur_reserve_rvdb_table_base  = cur_task_desc.dep_set_info.dep_set_chiplet_id[BIND_TABLE_ADDR_W-1:0];

    always_ff @(posedge clk_i or negedge rst_ni) begin : rvdb_config_write
        if (!rst_ni) begin
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                for (int s = 0; s < NUM_CORES_PER_CLUSTER; s++) begin
                    rvdb_config_q[cl][s] <= '0;
                end
            end
        end else begin
            // Fire on the same condition as scoreboard_we, restricted to
            // reserves with rvdb_chain_en=1.
            for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                if ((|waiting_dep_check_queue_push) &&
                    (cur_task_desc.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cl)) &&
                    cur_reserve_rvdb_chain_en) begin
                    rvdb_config_q[cl][cur_reserve_rvdb_source_slot].valid       <= 1'b1;
                    rvdb_config_q[cl][cur_reserve_rvdb_source_slot].target_slot <= cur_task_desc.slot_id;
                    rvdb_config_q[cl][cur_reserve_rvdb_source_slot].table_base  <= cur_reserve_rvdb_table_base;
                end
            end
        end
    end

    // Dep-matrix is indexed by logical slot_id (not physical core_id).
    // For each requesting core c, the matrix row driven is task.slot_id;
    // the check result is sampled back at the same slot row.
    // Compiler invariant: at most one in-flight task per (cluster, slot) — to be guarded by SVA.
    //
    // Per-core helpers driven outside the connect block
    bingo_hw_manager_slot_id_t        [NUM_CORES_PER_CLUSTER-1:0] dep_check_row_idx;
    bingo_hw_manager_dep_check_code_t [NUM_CORES_PER_CLUSTER-1:0] dep_check_static_code;
    logic                             [NUM_CORES_PER_CLUSTER-1:0] dep_check_is_jit_slot;
    for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c = c + 1) begin : gen_dep_check_helpers
        // JIT-slot detection uses the raw FIFO entry: the merged view's task_type
        // post-bind is the bind's (typically 2'b00) and would mask the JIT origin.
        assign dep_check_row_idx[c]     = live_task_desc[c].slot_id;
        assign dep_check_static_code[c] = live_task_desc[c].dep_check_info.dep_check_code;
        assign dep_check_is_jit_slot[c] = ~waiting_dep_check_queue_empty[c] &&
                                          (waiting_dep_check_task_desc[c].task_type == TT_JIT) &&
                                          !waiting_dep_check_task_desc[c].is_bind;
    end

    always_comb begin : connect_dep_check_for_dep_matrix
        for ( int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin
            // Default: no request on any slot row
            for ( int row = 0; row < NUM_CORES_PER_CLUSTER; row = row + 1) begin
                dep_check_valid[cluster][row] = 1'b0;
                dep_check_code [cluster][row] = '0;
            end
            // Per-core ready default
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                demux_dep_matrix_oup_ready[core][cluster] = 1'b0;
            end
            // Drive row = slot_id for each requesting core, sample ready back from the same row.
            // JIT-DFG: read slot_id and dep_check_code from the bind_resolver's
            // live view so a bound descriptor uses its post-bind dep_check_code.
            // Any JIT slot gets the WAIT_FOR_BIND_COL bit OR'd into its check code:
            //   - pre-bind: WAIT_FOR_BIND counter is 0 → check fails → slot parks.
            //   - post-bind: bind_resolver pulsed bind_set, counter is 1 → check
            //     passes AND clears the counter to 0 (saturating decrement).
            for ( int core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin
                if (demux_dep_matrix_oup_valid[core][cluster]) begin
                    dep_check_valid[cluster][dep_check_row_idx[core]] = 1'b1;
                    dep_check_code [cluster][dep_check_row_idx[core]] = dep_check_static_code[core] |
                        (dep_check_is_jit_slot[core]
                            ? (bingo_hw_manager_dep_check_code_t'(1'b1) << WAIT_FOR_BIND_COL)
                            : '0);
                end
                demux_dep_matrix_oup_ready[core][cluster] = dep_check_result[cluster][dep_check_row_idx[core]];
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
                    // dep_matrix is slot-indexed: column = logical slot_id of the signaling task
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_matrix_col= checkout_queue_data_out[core][cluster].slot_id;
                    stream_arbiter_dep_matrix_set_inp_data[stream_arbiter_inp_idx].dep_set_code  = checkout_queue_data_out[core][cluster].dep_set_info.dep_set_code;
                    // Fire when the checkout entry is at the head AND either
                    //   - dummy_set (no execution → no done_q entry to wait for), OR
                    //   - the per-(core,cluster) done_q has the matching completion.
                    stream_arbiter_dep_matrix_set_inp_valid[stream_arbiter_inp_idx] =
                        stream_filter_checkout_queue_dep_set_enable_oup_valid[core][cluster] &&
                        ((checkout_queue_data_out[core][cluster].task_type == TT_DUMMY) ||
                         !done_q_empty[core][cluster]);
            end
        end
        // For Chiplet Set Queue
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_id  = cur_chiplet_done_queue_task_desc.dep_set_info.dep_set_cluster_id;
        // dep_matrix is slot-indexed: H2H remote dep_set column = logical slot_id carried in the cross-chiplet descriptor
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_matrix_col = cur_chiplet_done_queue_task_desc.slot_id;
        stream_arbiter_dep_matrix_set_inp_data[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET].dep_set_code   = cur_chiplet_done_queue_task_desc.dep_set_info.dep_set_code;
        // JIT-DFG: a remote BIND descriptor takes the bind path, NOT the dep_matrix arbiter.
        stream_arbiter_dep_matrix_set_inp_valid[NUM_CORES_PER_CLUSTER * NUM_CLUSTERS_PER_CHIPLET] =
            !chiplet_done_queue_mbox_empty && !chiplet_remote_is_bind;
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
        // Default: all columns idle, including the bind-only WAIT_FOR_BIND_COL
        // (index NUM_CORES_PER_CLUSTER) which is never set publicly.
        dep_set_valid = '0;
        dep_set_code  = '0;
        stream_demux_set_dep_matrix_core_id_oup_ready = '0;
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
    // Before each ready queue, two cascaded filters:
    //   1. drop dummy-set tasks (won't run on the core, only set deps downstream)
    //   2. drop CERF conditionally-skipped tasks (skip execution, propagate deps)
    for (genvar core = 0; core < NUM_CORES_PER_CLUSTER; core = core + 1) begin: gen_ready_queue_per_core
        for (genvar cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster = cluster + 1) begin: gen_ready_queue_per_core_per_cluster
            // Stage 1: drop dummy-set tasks (task_type==TT_DUMMY, dep_set_en==1)
            // JIT-DFG: read live (post-bind) view for the dummy_set drop test.
            stream_filter i_stream_filter_for_ready_queue_dummy_set (
                .valid_i (   ready_queue_filter_dummy_set_inp_valid[core][cluster]       ),
                .ready_o (   ready_queue_filter_dummy_set_inp_ready[core][cluster]       ),
                .drop_i  (   ready_queue_filter_dummy_set_drop[core][cluster]            ),
                .valid_o (   ready_queue_filter_dummy_set_oup_valid[core][cluster]       ),
                .ready_i (   ready_queue_filter_dummy_set_oup_ready[core][cluster]       )
            );
            assign ready_queue_filter_dummy_set_inp_valid[core][cluster] = demux_ready_and_checkout_queue_oup_valid[core][cluster];
            assign ready_queue_filter_dummy_set_drop[core][cluster] =
                (live_task_desc[core].task_type == TT_DUMMY) &&
                (live_task_desc[core].dep_set_info.dep_set_en == 1'b1);

            // Stage 2: drop CERF conditionally-skipped tasks
            stream_filter i_stream_filter_for_ready_queue_cond_exec_skip (
                .valid_i (   ready_queue_filter_dummy_set_oup_valid[core][cluster]       ),
                .ready_o (   ready_queue_filter_dummy_set_oup_ready[core][cluster]       ),
                .drop_i  (   ready_queue_filter_cond_exec_skip_drop[core][cluster]       ),
                .valid_o (   ready_queue_filter_oup_valid[core][cluster]                 ),
                .ready_i (   ready_queue_filter_oup_ready[core][cluster]                 )
            );
            assign ready_queue_filter_cond_exec_skip_drop[core][cluster] = cond_exec_skip[core];
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
            // JIT-DFG: ready queue carries the bound task_id, not the reservation's.
            assign ready_queue_data_in[core][cluster].task_id = live_task_desc[core].task_id;
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
            // CERF: if task is conditionally skipped, mark as dummy (2'b01)
            // so checkout logic fires dep_set without done_queue match.
            // JIT-DFG: source from the live (post-bind) view so the checkout
            // queue carries the bound dep_set_code etc.
            always_comb begin
                checkout_queue_data_in[core][cluster] = live_task_desc[core];
                if (cond_exec_skip[core]) begin
                    checkout_queue_data_in[core][cluster].task_type = TT_DUMMY;
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
        // Parse the mailbox AXI word as the writer-visible payload (no slot_id).
        // HW stamps slot_id from the scoreboard inverse table, indexed by the
        // routing identity the writer provided. This matches the CSR mode
        // contract — neither path requires SW/aggregator to know slot_id.
        bingo_hw_manager_done_info_mbox_t cur_done_queue_mbox_payload;
        assign cur_done_queue_mbox_payload = bingo_hw_manager_done_info_mbox_t'(done_queue_mbox_data);

        always_comb begin
            cur_done_queue_info_axi.return_value        = cur_done_queue_mbox_payload.return_value;
            cur_done_queue_info_axi.assigned_cluster_id = cur_done_queue_mbox_payload.assigned_cluster_id;
            cur_done_queue_info_axi.assigned_core_id    = cur_done_queue_mbox_payload.assigned_core_id;
            cur_done_queue_info_axi.task_id             = cur_done_queue_mbox_payload.task_id;
            cur_done_queue_info_axi.slot_id             = scoreboard_inv_table[
                cur_done_queue_mbox_payload.assigned_cluster_id][
                cur_done_queue_mbox_payload.assigned_core_id];
        end

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

    // Per-(core, cluster) done queue pop logic.
    always_comb begin
        for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
            for (int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin
                done_q_pop[core][cluster] = !done_q_empty[core][cluster] &&
                    (checkout_queue_data_out[core][cluster].task_type == TT_NORMAL ||
                     checkout_queue_data_out[core][cluster].task_type == TT_GATING) &&
                    // Scoreboard's logical match: physical routing alone isn't enough
                    // once the scoreboard rebinds slots (slot_id ≠ assigned_core_id).
                    (done_q_info[core][cluster].slot_id == checkout_queue_data_out[core][cluster].slot_id) &&
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
        // Internal done write path carries the natural-width stamped struct,
        // not an AXI word — csr_to_fifo emits done_info_full_t directly and the
        // arbiter / per-(core,cluster) FIFO route it without further casts.
        bingo_hw_manager_done_info_full_t [N_CORES_TOTAL-1:0] write_done_queue_data_1d;
        logic                             [N_CORES_TOTAL-1:0] write_done_queue_valid_1d;
        logic                             [N_CORES_TOTAL-1:0] write_done_queue_ready_1d;
        bingo_hw_manager_done_info_full_t write_done_queue_data;
        logic                             write_done_queue_valid;
        logic                             write_done_queue_ready;
        // 1D slot_id view (from the per-cluster scoreboard inverse table)
        bingo_hw_manager_slot_id_t [N_CORES_TOTAL-1:0] slot_id_1d;


        bingo_hw_manager_csr_to_fifo #(
            .N (N_CORES_TOTAL),
            .NUM_CORES_PER_CLUSTER (NUM_CORES_PER_CLUSTER),
            .NUM_CLUSTERS_PER_CHIPLET (NUM_CLUSTERS_PER_CHIPLET),
            .csr_req_t (csr_req_t),
            .csr_rsp_t (csr_rsp_t),
            .data_t    (device_axi_lite_data_t),
            .bingo_hw_manager_done_info_csr_t  (bingo_hw_manager_done_info_csr_t),
            .bingo_hw_manager_done_info_full_t (bingo_hw_manager_done_info_full_t),
            .bingo_hw_manager_slot_id_t (bingo_hw_manager_slot_id_t)
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
            .fifo_data_ready_i (write_done_queue_ready_1d),
            // Slot-id view driven by per-cluster scoreboard inverse table
            .slot_id_i         (slot_id_1d               )
        );

        // slot_id_1d[core + cluster*NUM_CORES_PER_CLUSTER] = scoreboard[cluster].inv_table[core]
        // Uses the full inverse-table output from each per-cluster scoreboard.
        always_comb begin : connect_scoreboard_inv_lookup
            for (int unsigned co = 0; co < NUM_CORES_PER_CLUSTER; co = co + 1) begin
                for (int unsigned cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl = cl + 1) begin
                    slot_id_1d[co + cl * NUM_CORES_PER_CLUSTER] = scoreboard_inv_table[cl][co];
                end
            end
        end
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
        // Arbiter payload is the stamped struct directly — no AXI-width packing.
        stream_arbiter #(
            .DATA_T(bingo_hw_manager_done_info_full_t),
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
        // Route the arbitrated stamped struct to per-(core, cluster) done FIFOs.
        always_comb begin
            for (int c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin
                for (int cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin
                    done_q_data_in[c][cl] = write_done_queue_data;
                    done_q_push[c][cl] = write_done_queue_valid &&
                        (write_done_queue_data.assigned_core_id == bingo_hw_manager_assigned_core_id_t'(c)) &&
                        (write_done_queue_data.assigned_cluster_id == bingo_hw_manager_assigned_cluster_id_t'(cl)) &&
                        !done_q_full[c][cl];
                end
            end
        end
        assign write_done_queue_ready = !done_q_full[write_done_queue_data.assigned_core_id][write_done_queue_data.assigned_cluster_id];


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
        // Interface to Host AXI Lite
        .pm_axi_lite_req_o     (pm_axi_lite_req_o                      ),
        .pm_axi_lite_resp_i    (pm_axi_lite_resp_i                     )
    );

    //////////////////////////////////////////////////////////////////////
    // Conditional Execution Register File (CERF)
    //////////////////////////////////////////////////////////////////////

    bingo_hw_manager_cond_exec_controller #(
        .NumGroups(32)
    ) i_cerf (
        .clk_i            ( clk_i                  ),
        .rst_ni           ( rst_ni                 ),
        .cerf_state_o     ( cerf_state             ),
        .cerf_write_data_i( cerf_write_data_i      ),
        .cerf_write_en_i  ( cerf_write_en_i        )
    );

    // ---- JIT-DFG top-level invariants (sim only) ------------------------
    // SVAs that span the per-cluster aggregation and per-core fanout.
    `ifndef SYNTHESIS
    // SVA 1: at most one core per cluster pulses bind_set in the same cycle.
    // The aggregator priority-mux uses first-match — a multi-fire would silently
    // drop the second bind's WAIT_FOR_BIND increment. Currently expected to be
    // mutex by construction (the upstream demux serialises new binds + the
    // pending buffer drain matches by head, which is per-core).
    for (genvar cl = 0; cl < NUM_CLUSTERS_PER_CHIPLET; cl++) begin: gen_sva_per_cluster
        // Count how many cores fired bind_set targeting THIS cluster.
        logic [$clog2(NUM_CORES_PER_CLUSTER+1)-1:0] cluster_bind_set_count;
        always_comb begin
            cluster_bind_set_count = '0;
            for (int co = 0; co < NUM_CORES_PER_CLUSTER; co++) begin
                if (per_core_bind_set_valid[co] &&
                    (live_task_desc[co].assigned_cluster_id ==
                     bingo_hw_manager_assigned_cluster_id_t'(cl))) begin
                    cluster_bind_set_count = cluster_bind_set_count + 1;
                end
            end
        end
        assert_at_most_one_bind_set_per_cluster_per_cycle: assert property (
            @(posedge clk_i) disable iff (!rst_ni)
            (cluster_bind_set_count <= 1)
        ) else $error("[JIT] cluster %0d saw %0d simultaneous bind_set pulses", cl, cluster_bind_set_count);
    end

    // pending_buffer_full and double_bind already assert inside bind_resolver
    // (one per core); duplicating at top level was redundant.

    // Livelock detector — if the head of any wait queue is a JIT
    // reservation that has been parked in WAIT_DEP_CHECK for more than
    // 10000 cycles without a merge, flag it. Catches missing-bind / wrong-slot
    // bugs without halting simulation. (Note: deliberately loose; a real
    // workload might legitimately pause longer in some scenarios.)
    localparam int unsigned BIND_LIVELOCK_THRESHOLD = 10000;
    for (genvar c = 0; c < NUM_CORES_PER_CLUSTER; c++) begin: gen_livelock
        logic [31:0] reserve_wait_cycles;
        logic        reserve_at_head;
        assign reserve_at_head = ~waiting_dep_check_queue_empty[c] &&
                                  (waiting_dep_check_task_desc[c].task_type == TT_JIT) &&
                                  !waiting_dep_check_task_desc[c].is_bind &&
                                  (dep_check_manager_state[c] == 2'b01); // WAIT_DEP_CHECK
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) reserve_wait_cycles <= '0;
            else if (!reserve_at_head) reserve_wait_cycles <= '0;
            else reserve_wait_cycles <= reserve_wait_cycles + 1;
        end
        assert_bind_lands_within_threshold: assert property (
            @(posedge clk_i) disable iff (!rst_ni)
            (reserve_wait_cycles < BIND_LIVELOCK_THRESHOLD)
        ) else $error("[JIT] core %0d: reservation parked >%0d cycles without bind (livelock?)",
                      c, BIND_LIVELOCK_THRESHOLD);
    end
    `endif

endmodule