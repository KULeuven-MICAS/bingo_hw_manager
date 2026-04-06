// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// This module is the interface from the core CSR req/rsp to read the FIFO

module bingo_hw_manager_csr_to_fifo_read #(
    parameter type data_t = logic
) (
    input  logic            csr_req_valid_i,
    output logic            csr_req_ready_o,
    // CSR response output
    output data_t           csr_rsp_data_o,
    output logic            csr_rsp_valid_o,
    input  logic            csr_rsp_ready_i,
    // FIFO interface
    input  data_t           fifo_data_i,
    input  logic            fifo_data_valid_i,
    output logic            fifo_data_ready_o
);
    assign csr_req_ready_o = fifo_data_valid_i && csr_rsp_ready_i;
    assign csr_rsp_data_o = fifo_data_i;
    assign csr_rsp_valid_o = fifo_data_valid_i && csr_req_valid_i;
    assign fifo_data_ready_o = fifo_data_valid_i && csr_req_valid_i && csr_rsp_ready_i;
    
endmodule