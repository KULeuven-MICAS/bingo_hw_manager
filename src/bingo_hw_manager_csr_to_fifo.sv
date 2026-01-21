// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// This module is the interface from the core CSR req/rsp to read/write the FIFO
// For the N inputs, it can only read its own FIFO
// so we only need demux for read and write for each input
module bingo_hw_manager_csr_to_fifo #(
    // Suppose there are N CSR req/rsp channels and N FIFOs
    parameter int unsigned TaskIdWidth = 12,
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
    parameter type bingo_hw_manager_done_info_full_t = logic
    // typedef struct packed{
    //     logic [ReservedBitsForDoneInfo-1:0]        reserved_bits;
    //     bingo_hw_manager_assigned_cluster_id_t     assigned_cluster_id;
    //     bingo_hw_manager_assigned_core_id_t        assigned_core_id;
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
    // FIFO Read interface
    input  data_t    [N-1:0]    fifo_data_i,
    input  logic     [N-1:0]    fifo_data_valid_i,
    output logic     [N-1:0]    fifo_data_ready_o,
    // FIFO Write interface
    output data_t    [N-1:0]    fifo_data_o,
    output logic     [N-1:0]    fifo_data_valid_o,
    input  logic     [N-1:0]    fifo_data_ready_i
);

    // Signals for csr_to_fifo_read
    logic [N-1:0] csr_req_valid_read;
    logic [N-1:0] csr_req_ready_read;
    logic [N-1:0] csr_rsp_valid_read;
    // Signals for csr_to_fifo_write
    logic [N-1:0] csr_req_valid_write;
    logic [N-1:0] csr_req_ready_write;
    logic [N-1:0] csr_rsp_valid_write;

    // Signals for Write Done Info
    bingo_hw_manager_done_info_full_t [N-1:0] done_info;
    data_t [N-1:0] done_info_tmp;
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
            .fifo_data_o(done_info_tmp[i]),
            .fifo_data_valid_o(fifo_data_valid_o[i]),
            .fifo_data_ready_i(fifo_data_ready_i[i])
        );
        // Compose the done info
        // i = core + cluster * NUM_CORES_PER_CLUSTER
        // Hence the cluster id = i / NUM_CORES_PER_CLUSTER % NUM_CLUSTERS_PER_CHIPLET
        // and the core id = i % NUM_CORES_PER_CLUSTER
        assign done_info[i].reserved_bits       = '0;
        assign done_info[i].assigned_cluster_id = i / NUM_CORES_PER_CLUSTER % NUM_CLUSTERS_PER_CHIPLET;
        assign done_info[i].assigned_core_id    = i % NUM_CORES_PER_CLUSTER;
        assign done_info[i].task_id             = done_info_tmp[i][TaskIdWidth-1:0];
        assign fifo_data_o[i] = data_t'(done_info[i]);
        assign csr_req_valid_write[i] = csr_req_valid_i[i] && csr_req_i[i].write;

        assign csr_req_ready_o[i] = csr_req_i[i].write ? csr_req_ready_write[i] : csr_req_ready_read[i];
        assign csr_rsp_valid_o[i] = csr_req_i[i].write ? '0 : csr_rsp_valid_read[i];

    end
endmodule