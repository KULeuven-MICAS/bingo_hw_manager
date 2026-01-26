// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// This mailbox module is mainly adopted from the axi_lite_mailbox.sv from 
// the PULP AXI IP repository.
// Different from the pulp version, this mailbox is not a dual-mailbox, but a single
// mailbox. 
// Besides, in our hw manager we need two types of mailboxes:
// 1. AXI Lite in, fifo out (for task queue from host and the done queue from device)
// 2. fifo in, AXI Lite out (for ready queue to device)
// This module implements the first type of mailbox.
`include "common_cells/registers.svh"
module bingo_hw_manager_write_mailbox #(
    parameter int unsigned MailboxDepth = 32'd0,
    parameter bit unsigned IrqEdgeTrig  = 1'b0,
    parameter bit unsigned IrqActHigh   = 1'b1,
    parameter int unsigned AxiAddrWidth = 32'd0,
    parameter int unsigned AxiDataWidth = 32'd0,
    parameter int unsigned ChipIdWidth  = 8,
    parameter type         req_lite_t   = logic,
    parameter type         resp_lite_t  = logic,
    // DEPENDENT PARAMETERS, DO NOT OVERRIDE!
    parameter type         addr_t       = logic [AxiAddrWidth-1:0],
    parameter type         data_t       = logic [AxiDataWidth-1:0],
    // usage type of the mailbox FIFO, also the type of the threshold comparison
    // is one bit wider, MSB is the fifo_full flag of the respective fifo
    parameter type         usage_t      = logic [$clog2(MailboxDepth):0]
) (
    input  logic                   clk_i,       // Clock
    input  logic                   rst_ni,      // Asynchronous reset active low
    input  logic                   test_i,      // Testmode enable
    input  logic [ChipIdWidth-1:0] chip_id_i,   // chip id input for multi-chip addressing
    // AXI Lite write ports
    input  req_lite_t              req_i,       // AXI-Lite request input
    output resp_lite_t             resp_o,      // AXI-Lite response output
    output logic                   irq_o,       // Interrupt output
    input  addr_t                  base_addr_i,  // base address for this peripheral
    // FIFO read ports
    output data_t                  mbox_data_o,   // data output to FIFO
    input  logic                   mbox_pop_i,    // pop signal from FIFO
    output logic                   mbox_empty_o,  // full signal from FIFO
    input  logic                   mbox_flush_i  // flush signal to FIFO
);
    // FIFO signals
    logic w_mbox_flush;
    logic mbox_push, mbox_pop;
    logic mbox_full, mbox_empty;
    logic [$clog2(MailboxDepth)-1:0] mbox_usage;
    data_t  mbox_w_data, mbox_r_data;
    usage_t mbox_usage_combined;
    // interrupt request from this slave port, level triggered, active high --> convert
    logic    slv_irq;
    logic    clear_irq;

    bingo_hw_manager_mailbox_adapter #(
        .MailboxDepth ( MailboxDepth ),
        .AxiAddrWidth ( AxiAddrWidth ),
        .AxiDataWidth ( AxiDataWidth ),
        .req_lite_t   ( req_lite_t   ),
        .resp_lite_t  ( resp_lite_t  ),
        .addr_t       ( addr_t       ),
        .data_t       ( data_t       ),
        .usage_t      ( usage_t      )  // fill pointer from MBOX FIFO
    ) i_bingo_hw_manager_mailbox_adapter (
        .clk_i,   // Clock
        .rst_ni,  // Asynchronous reset active low
        .chip_id_i      (chip_id_i     ), // chip id input for multi-chip addressing
        // slave port
        .slv_req_i      ( req_i        ),
        .slv_resp_o     ( resp_o       ),
        .base_addr_i    ( base_addr_i  ), // base address for the slave port
        // write FIFO port
        .mbox_w_data_o  ( mbox_w_data  ),
        .mbox_w_full_i  ( mbox_full    ),
        .mbox_w_push_o  ( mbox_push    ),
        .mbox_w_flush_o ( w_mbox_flush ),
        .mbox_w_usage_i ( mbox_usage_combined ),
        // read FIFO port
        .mbox_r_data_i  ( '0           ), // not used in this mailbox type
        .mbox_r_empty_i ( '0           ), // not used in this mailbox type
        .mbox_r_pop_o   ( /*not used*/ ),
        .mbox_r_flush_o ( /*not used*/ ),
        .mbox_r_usage_i ( '0           ),
        // interrupt output, level triggered, active high, conversion in top
        .irq_o          ( slv_irq      ),
        .clear_irq_o    ( clear_irq    )
    );
    fifo_v3 #(
        .FALL_THROUGH ( 1'b0         ),
        .DEPTH        ( MailboxDepth ),
        .dtype        ( data_t       )
    ) i_mbox (
        .clk_i       ( clk_i       ),
        .rst_ni      ( rst_ni      ),
        .testmode_i  ( test_i      ),
        .flush_i     ( w_mbox_flush | mbox_flush_i  ),
        .full_o      ( mbox_full   ),
        .empty_o     ( mbox_empty  ),
        .usage_o     ( mbox_usage  ),
        .data_i      ( mbox_w_data ),
        .push_i      ( mbox_push   ),
        .data_o      ( mbox_r_data ),
        .pop_i       ( mbox_pop    )
    );
    assign mbox_data_o    = mbox_r_data;
    assign mbox_empty_o   = mbox_empty;
    assign mbox_pop       = mbox_pop_i;
    // usage combined signal, MSB is the full flag
    assign mbox_usage_combined = {mbox_full, mbox_usage};
    // interrupt signal conversion
    if (IrqEdgeTrig) begin : gen_irq_edge
      logic irq_q, irq_d, update_irq;

      always_comb begin
        // default assignments
        irq_d      = irq_q;
        update_irq = 1'b0;
        // init the irq and pulse only on update
        irq_o   = ~IrqActHigh;
        if (clear_irq) begin
          irq_d      = 1'b0;
          update_irq = 1'b1;
        end else if (!irq_q && slv_irq) begin
          irq_d      = 1'b1;
          update_irq = 1'b1;
          irq_o   = IrqActHigh; // on update of the register pulse the irq signal
        end
      end

      `FFLARN(irq_q, irq_d, update_irq, '0, clk_i, rst_ni)
    end else begin : gen_irq_level
      assign irq_o = (IrqActHigh) ? slv_irq : ~slv_irq;
    end
endmodule