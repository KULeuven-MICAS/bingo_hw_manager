// Copyright 2025 KU Leuven.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Authors:
// - Fanchen Kong <fanchen.kong@kuleuven.be>
// - Xiaoling Yi  <xiaoling.yi@kuleuven.be>
// - Yunhao Deng  <yunhao.deng@kuleuven.be>

// This is the power management module for the bingo hardware manager
// The implementation is tightly coupled with the on chip PMIC design
// Right now it only supports simple clock gating based on idle signal from the hw manager
// In the future it can be extended to support DVFS and power gating if needed

module bingo_hw_manager_pm #(
    parameter int unsigned NUM_CLUSTERS_PER_CHIPLET = 4,
    parameter int unsigned NUM_CORES_PER_CLUSTER = 8,
    parameter int unsigned CfgBusWidth = 32,
    parameter type     req_lite_t   = logic,
    parameter type     resp_lite_t  = logic,
    parameter type     addr_t       = logic,
    parameter type     data_t       = logic,
    // Derived type, do not override
    parameter type     cfg_t        = logic [CfgBusWidth-1:0]
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    // The configuration specifed by the host
    // Whether to enable idle power management
    input  cfg_t        enable_idle_pm_i,
    // The idle power level specified by the host
    input  cfg_t        idle_power_level_i,
    // The normal power level specified by the host
    input  cfg_t        normal_power_level_i,
    // The power management base address
    input  addr_t       pm_base_addr_i,  
    // The power domain information of each core
    input  cfg_t [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]    core_power_domain_i,
    // Idle signal from hw manager
    input  logic [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0]   core_status_waiting_task_i,
    // AXI Lite Master Interface to Configure PMIC
    output req_lite_t              pm_axi_lite_req_o,
    input  resp_lite_t             pm_axi_lite_resp_i
);

    // Constants
    // Notice here is tightly coupled with the PMIC design
    // So we do not make those as configurable parameters
    localparam int unsigned MAX_DOMAINS = 32;
    localparam int unsigned OFFSET_CLOCK_VALID = 32'h04;
    localparam int unsigned OFFSET_CLOCK_DIVISION_BASE = 32'h08;

    // Type definition for power level (using low 8 bits of cfg_t)
    typedef logic [7:0]                     power_level_t;
    typedef logic [$clog2(MAX_DOMAINS)-1:0] domain_id_t;
    // -------------------------------------------------------------------------
    // 1. Status Aggregation
    // -------------------------------------------------------------------------
    logic [MAX_DOMAINS-1:0] domain_all_idle;    // 1 if ALL cores in domain are idle
    logic [MAX_DOMAINS-1:0] domain_active_mask; // 1 if at least one core is mapped to this domain
    domain_id_t  [NUM_CORES_PER_CLUSTER-1:0][NUM_CLUSTERS_PER_CHIPLET-1:0] domain_id;

    // Example Scenario:
    // Setup:
    // - 2 Clusters, each with 2 Cores.
    // - Configuration:
    //   - C0_0 -> Domain 0
    //   - C0_1 -> Domain 0 (Shared)
    //   - C1_0 -> Domain 1
    //   - C1_1 -> Domain 2
    // - Status:
    //   - C0_0: Waiting (1)
    //   - C0_1: Active (0)
    //   - C1_0: Waiting (1)
    //   - C1_1: Waiting (1)
    //
    // Execution Trace:
    // 1. C0_0 (Domain 0): Idle. domain_all_idle[0] remains 1.
    // 2. C0_1 (Domain 0): Active. domain_all_idle[0] forced to 0. (Keeps Domain 0 awake).
    // 3. C1_0 (Domain 1): Idle. domain_all_idle[1] remains 1.
    // 4. C1_1 (Domain 2): Idle. domain_all_idle[2] remains 1.
    //
    // Result:
    // - domain_all_idle = ...11110 (Bit 0 is 0/Busy, Bits 1 & 2 are 1/Idle)
    // - Domain 0 -> Normal Power, Domains 1 & 2 -> Idle Power.
    always_comb begin
        domain_all_idle = '1; // Default to true, clear if any core busy
        domain_active_mask = '0;
        domain_id = '0;
        for (int core = 0; core < NUM_CORES_PER_CLUSTER; core++) begin
            for (int cluster = 0; cluster < NUM_CLUSTERS_PER_CHIPLET; cluster++) begin
                // We also support the case where some cores are not mapped to any power domain
                // Set to a magic number like 99 to indicate no power domain
                if (core_power_domain_i[core][cluster] < MAX_DOMAINS) begin
                    domain_id[core][cluster] = core_power_domain_i[core][cluster][4:0];
                    domain_active_mask[domain_id[core][cluster]] = 1'b1;
                    if (core_status_waiting_task_i[core][cluster] == 1'b0) begin
                        domain_all_idle[domain_id[core][cluster]] = 1'b0;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. Change Detection & Arbitration
    // -------------------------------------------------------------------------
    power_level_t [MAX_DOMAINS-1:0] current_power_level_q; // State tracking
    power_level_t [MAX_DOMAINS-1:0] target_power_level;
    logic [MAX_DOMAINS-1:0]         pending_update;       // Domains that need update
    logic                           update_req_valid;
    domain_id_t                     update_domain_id;
    power_level_t                   update_domain_target_level;

    // Calculate target level and pending updates
    always_comb begin
        for (int d = 0; d < MAX_DOMAINS; d++) begin
            if (enable_idle_pm_i[0] && domain_all_idle[d]) begin
                target_power_level[d] = idle_power_level_i[7:0];
            end else begin
                target_power_level[d] = normal_power_level_i[7:0];
            end

            // We update if the domain exists AND the target differs from current
            if (domain_active_mask[d] && (target_power_level[d] != current_power_level_q[d])) begin
                pending_update[d] = 1'b1;
            end else begin
                pending_update[d] = 1'b0;
            end
        end
    end

    // Simple Priority Arbiter (Least Significant Bit First)
    lzc #(
        .WIDTH(MAX_DOMAINS),
        .MODE (1'b0) // 0 for Trailing Zeros (LSB)
    ) i_lzc_arbiter (
        .in_i    ( pending_update   ),
        .cnt_o   ( update_domain_id ), // Returns the index of the first '1'
        .empty_o ( /* unused */     )
    );

    assign update_req_valid = |pending_update;
    assign update_domain_target_level = target_power_level[update_domain_id];

    // -------------------------------------------------------------------------
    // 3. AXI-Lite Protocol FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        WRITE_FREQ_AW,
        WRITE_FREQ_W,
        WRITE_VALID_AW,
        WRITE_VALID_W
    } pm_state_t;

    pm_state_t state_d, state_q;

    // Latch arbitration results when starting a transaction
    domain_id_t         active_domain_id_d, active_domain_id_q;
    power_level_t       active_target_level_d, active_target_level_q;

    // FSM Output signals
    logic bus_aw_valid, bus_w_valid;
    localparam int unsigned BUS_ADDR = $bits(addr_t);
    localparam int unsigned BUS_DATA = $bits(data_t);
    localparam int unsigned WstrbWidth = BUS_DATA / 8;
    addr_t   bus_addr;
    data_t   bus_wdata;
    logic [WstrbWidth-1:0] bus_wstrb;

    // 1. Sequential Logic: State and Datapath Registers
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q               <= IDLE;
            active_domain_id_q    <= '0;
            active_target_level_q <= '0;
            current_power_level_q <= '0; // Reset assumes power-on defaults (or specific val)
        end else begin
            state_q               <= state_d;
            active_domain_id_q    <= active_domain_id_d;
            active_target_level_q <= active_target_level_d;

            // Update the shadow register upon successful completion of the sequence
            // Assuming completion when last W-channel handshake is done
            if (state_q == WRITE_VALID_W && pm_axi_lite_resp_i.w_ready) begin
                current_power_level_q[active_domain_id_q] <= active_target_level_q;
            end
        end
    end

    // 2. Next State Logic
    always_comb begin
        state_d = state_q; // Default to hold state
        case (state_q)
            IDLE: begin
                if (update_req_valid && enable_idle_pm_i[0]) state_d = WRITE_FREQ_AW;
            end

            WRITE_FREQ_AW: begin
                if (pm_axi_lite_req_o.aw_valid && pm_axi_lite_resp_i.aw_ready) state_d = WRITE_FREQ_W;
            end

            WRITE_FREQ_W: begin
                if (pm_axi_lite_req_o.w_valid && pm_axi_lite_resp_i.w_ready) state_d = WRITE_VALID_AW;
            end

            WRITE_VALID_AW: begin
                if (pm_axi_lite_req_o.aw_valid && pm_axi_lite_resp_i.aw_ready) state_d = WRITE_VALID_W;
            end

            WRITE_VALID_W: begin
                if (pm_axi_lite_req_o.w_valid && pm_axi_lite_resp_i.w_ready) state_d = IDLE;
            end

            default: state_d = IDLE;
        endcase
    end

    // 3. Output and Datapath Logic
    always_comb begin
        // Default Datapath Next Values
        active_domain_id_d    = active_domain_id_q;
        active_target_level_d = active_target_level_q;

        // Default Bus Outputs
        bus_aw_valid = 1'b0;
        bus_w_valid  = 1'b0;
        bus_addr     = '0;
        bus_wdata    = '0;
        bus_wstrb    = '0;

        case (state_q)
            IDLE: begin
                if (update_req_valid) begin
                    active_domain_id_d    = update_domain_id;
                    active_target_level_d = update_domain_target_level;
                end
            end

            WRITE_FREQ_AW: begin
                // C Code Reference:
                // volatile uint32_t *hemaia_clk_rst_controller_clock_division_reg = 
                //     (base + DIVISION_OFFSET) + (domain / 4 * 4);
                //
                // Verilog Implementation:
                // - (active_domain_id_q >> 2) implements (domain / 4)
                // - ( ... << 2) implements (* 4) to align to 32-bit word boundary
                // 
                // Example: active_domain_id_q = 5 (00101b)
                // - 5 >> 2 = 1.
                // - 1 << 2 = 4.
                // - Offset added = 4 bytes. (Register for domains 4-7)
                bus_addr = pm_base_addr_i + OFFSET_CLOCK_DIVISION_BASE + ((active_domain_id_q >> 2) << 2);
                bus_aw_valid = 1'b1;
            end

            WRITE_FREQ_W: begin
                // Replicate 32-bit data to both halves of the 64-bit bus
                // logic [31:0] wdata_32 = 32'(active_target_level_q) << (active_domain_id_q[1:0] * 8);
                bus_wdata = {2{32'(active_target_level_q) << (active_domain_id_q[1:0] * 8)}};
                // The base addr of the frequency division registers is 0x08
                // Each domain requires 8bits within a 32-bit reg
                // 0x08 - 0x0c covers domains 0-3 
                // 0x0c - 0x10 covers domains 4-7
                // and so on...
                // Each time we need to issue a 64bit write to one of these registers
                // Actully we are issuing write to 0x08 - 0x10 at once but need to control the strobe
                // Hence we need to determine which 32bit half of the 64bit bus to use
                // Bit 2 of active_domain_id_q (value 4) determines if we are 
                // targeting the Upper or Lower word of the 64-bit data bus.
                // - If active_domain_id_q[2] == 0: Use Lower 32 bits (Strobe 0x0F)
                // - If active_domain_id_q[2] == 1: Use Upper 32 bits (Strobe 0xF0)
                if (active_domain_id_q[2]) begin
                    bus_wstrb = 8'hf0; // Upper 32 bits
                end else begin
                    bus_wstrb = 8'h0f; // Lower 32 bits
                end
                bus_w_valid  = 1'b1;
            end

            WRITE_VALID_AW: begin
                bus_addr = pm_base_addr_i + OFFSET_CLOCK_VALID;
                bus_aw_valid = 1'b1;
            end

            WRITE_VALID_W: begin
                // Replicate 32-bit data
                bus_wdata = {2{32'(1'b1) << active_domain_id_q}};
                // Valid register is at Offset 0x04 (Upper 32 bits)
                // We are actully writes to the 0x00 to 0x08 range with the 64bit bus
                // So the valid bits are always in the upper 32 bits
                bus_wstrb = 8'hf0; 
                bus_w_valid  = 1'b1;
            end

            default: begin
                // Should not occur
                active_domain_id_d    = '0;
                active_target_level_d = '0;
                bus_aw_valid          = 1'b0;
                bus_w_valid           = 1'b0;
                bus_addr              = 'hbaadf00d;
                bus_wdata             = '0;
                bus_wstrb             = '0;
            end
        endcase
    end

    // Map internal bus signals to output struct
    always_comb begin
        pm_axi_lite_req_o = '0;
        
        pm_axi_lite_req_o.aw.addr  = bus_addr;
        pm_axi_lite_req_o.aw.prot  = 3'b000;
        pm_axi_lite_req_o.aw_valid = bus_aw_valid;

        pm_axi_lite_req_o.w.data   = bus_wdata;
        pm_axi_lite_req_o.w.strb   = bus_wstrb;
        pm_axi_lite_req_o.w_valid  = bus_w_valid;

        pm_axi_lite_req_o.b_ready  = 1'b1;
        
        // Read channels unused
        pm_axi_lite_req_o.ar       = '0;
        pm_axi_lite_req_o.ar_valid = 1'b0;
        pm_axi_lite_req_o.r_ready  = 1'b0;
    end

endmodule