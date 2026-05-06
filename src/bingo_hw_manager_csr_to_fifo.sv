// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// This module is the interface from the core CSR req/rsp to read/write the FIFO
// For the N inputs, it can only read its own FIFO
// so we only need demux for read and write for each input
module bingo_hw_manager_csr_to_fifo #(
    // Suppose there are N CSR req/rsp channels and N FIFOs
    parameter int unsigned N = 6,
    parameter int unsigned NUM_CORES_PER_CLUSTER = 3,
    parameter int unsigned NUM_CLUSTERS_PER_CHIPLET = 2,
    parameter type csr_req_t = logic,
    parameter type csr_rsp_t = logic,
//   // CSR Req/Rsp interface
//   typedef struct packed {
//     addr_t   addr;
//     data_t   data;
//     logic    write;
//   } csr_req_t;
//   typedef struct packed {
//     data_t   data;
//   } csr_rsp_t;
    parameter type data_t = logic,
    // SW-visible AXI-Lite payload from device:
    //   typedef struct packed {
    //     logic [ReservedBitsForDoneInfoAxi-1:0] reserved_bits;
    //     bingo_hw_manager_return_value_t       return_value;
    //     bingo_hw_manager_task_id_t            task_id;
    //   } bingo_hw_manager_done_info_axi_t;
    parameter type bingo_hw_manager_done_info_axi_t  = logic,
    parameter type bingo_hw_manager_done_info_full_t = logic,
    parameter type bingo_hw_manager_slot_id_t = logic
    // typedef struct packed{
    //     logic [ReservedBitsForDoneInfo-1:0]        reserved_bits;
    //     bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
    //     bingo_hw_manager_assigned_core_id_t        assigned_core_id;
    //     bingo_hw_manager_slot_id_t                 slot_id;
    //     bingo_hw_manager_task_id_t                 task_id;
    // } bingo_hw_manager_done_info_full_t;
) (
    // CSR request input
    input  csr_req_t [N-1:0]    csr_req_i,
    input  logic     [N-1:0]    csr_req_valid_i,
    output logic     [N-1:0]    csr_req_ready_o,
    // CSR response output
    output csr_rsp_t [N-1:0]    csr_rsp_o,
    output logic     [N-1:0]    csr_rsp_valid_o,
    input  logic     [N-1:0]    csr_rsp_ready_i,
    // FIFO Read interface — ready-queue payload (AXI-width, padded).
    input  data_t                            [N-1:0]    fifo_data_i,
    input  logic                             [N-1:0]    fifo_data_valid_i,
    output logic                             [N-1:0]    fifo_data_ready_o,
    // FIFO Write interface — done-queue payload (natural-width stamped struct).
    // The downstream done arbiter / per-(core,cluster) FIFO carry the struct
    // verbatim, so this output is no longer AXI-shaped.
    output bingo_hw_manager_done_info_full_t [N-1:0]    fifo_data_o,
    output logic                             [N-1:0]    fifo_data_valid_o,
    input  logic                             [N-1:0]    fifo_data_ready_i,
    // Slot ID per channel — driven by the scoreboard's inverse (core -> slot)
    // view at the top level. Used to stamp done_info.slot_id so the dep-matrix
    // done-match can compare logical slot rather than physical core.
    input  bingo_hw_manager_slot_id_t [N-1:0]    slot_id_i
);

    // Signals for csr_to_fifo_read
    logic [N-1:0] csr_req_valid_read;
    logic [N-1:0] csr_req_ready_read;
    logic [N-1:0] csr_rsp_valid_read;
    // Signals for csr_to_fifo_write
    logic [N-1:0] csr_req_valid_write;
    logic [N-1:0] csr_req_ready_write;

    // Signals for Write Done Info
    bingo_hw_manager_done_info_full_t [N-1:0] done_info;
    // Raw AXI-Lite write from the device, parsed into the SW-visible payload
    // type. Field access by name replaces the prior manual bit-slicing.
    data_t                            [N-1:0] done_info_axi_raw;
    bingo_hw_manager_done_info_axi_t  [N-1:0] done_info_axi;
    for (genvar i = 0; i < N; i++) begin
        bingo_hw_manager_csr_to_fifo_read #(
            .data_t(data_t)
        ) csr_to_fifo_read (
            .csr_req_valid_i(csr_req_valid_read[i]),
            .csr_req_ready_o(csr_req_ready_read[i]),
            .csr_rsp_data_o(csr_rsp_o[i].data),
            .csr_rsp_valid_o(csr_rsp_valid_read[i]),
            .csr_rsp_ready_i(csr_rsp_ready_i[i]),
            .fifo_data_i(fifo_data_i[i]),
            .fifo_data_valid_i(fifo_data_valid_i[i]),
            .fifo_data_ready_o(fifo_data_ready_o[i])
        );
        assign csr_req_valid_read[i] = csr_req_valid_i[i] && ~csr_req_i[i].write;

        bingo_hw_manager_csr_to_fifo_write #(
            .data_t(data_t)
        ) csr_to_fifo_write_inst (
            .csr_req_data_i(csr_req_i[i].data),
            .csr_req_valid_i(csr_req_valid_write[i]),
            .csr_req_ready_o(csr_req_ready_write[i]),
            .fifo_data_o(done_info_axi_raw[i]),
            .fifo_data_valid_o(fifo_data_valid_o[i]),
            .fifo_data_ready_i(fifo_data_ready_i[i])
        );
        // Parse the raw AXI write into the SW-visible payload struct.
        // Layout: {reserved_bits, return_value[7:0], task_id[11:0]} packed into
        // the device AXI-Lite data lane. Kernels that call the legacy
        // single-arg helper produce return_value = 0 (backward compatible).
        assign done_info_axi[i] = bingo_hw_manager_done_info_axi_t'(done_info_axi_raw[i]);

        // Compose the done info
        // i = core + cluster * NUM_CORES_PER_CLUSTER
        // Hence the cluster id = i / NUM_CORES_PER_CLUSTER % NUM_CLUSTERS_PER_CHIPLET
        // and the core id = i % NUM_CORES_PER_CLUSTER
        assign done_info[i].assigned_cluster_id = i / NUM_CORES_PER_CLUSTER % NUM_CLUSTERS_PER_CHIPLET;
        assign done_info[i].assigned_core_id    = i % NUM_CORES_PER_CLUSTER;
        // slot_id is driven by the scoreboard's core->slot inverse view at the
        // top level. Under today's identity mapping this evaluates to
        // `i % NUM_CORES_PER_CLUSTER`, so behaviour is unchanged; when a future
        // dispatcher re-binds slots, this field tracks the current binding.
        assign done_info[i].slot_id             = slot_id_i[i];
        // SW-written fields, taken straight from the parsed AXI payload.
        assign done_info[i].task_id             = done_info_axi[i].task_id;
        assign done_info[i].return_value        = done_info_axi[i].return_value;
        // Emit the natural-width stamped struct — downstream is typed on the
        // same struct, no AXI cast needed.
        assign fifo_data_o[i] = done_info[i];
        assign csr_req_valid_write[i] = csr_req_valid_i[i] && csr_req_i[i].write;

        assign csr_req_ready_o[i] = csr_req_i[i].write ? csr_req_ready_write[i] : csr_req_ready_read[i];
        assign csr_rsp_valid_o[i] = csr_req_i[i].write ? '0 : csr_rsp_valid_read[i];

    end
endmodule