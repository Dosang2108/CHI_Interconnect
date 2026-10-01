`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_csr_regs
// Purpose: Runtime CSR block for region routing, control commands, sticky
//          error status, IRQ generation, and scalable HN/RN perf-counter reads.
// -----------------------------------------------------------------------------
module chi_csr_regs #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NUM_HN     = `CHI_DEFAULT_NUM_HN,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN
)(
    input                    clk,
    input                    rstn,

    input                    csr_valid,
    input                    csr_write,
    input      [7:0]         csr_addr,
    input      [63:0]        csr_wdata,
    output                   csr_ready,
    output reg [63:0]        csr_rdata,

    input      [NUM_HN*16*32-1:0] hn_perf_counts_flat,
    input      [NUM_RN*16*32-1:0] rn_perf_counts_flat,
    input                    ecc_single_event,
    input                    ecc_double_event,
    input                    rn_parity_error_event,
    input                    exclusive_fail_event,
    input                    watchdog_event,
    input                    bist_reject_event,
    output                   err_irq,

    output reg               cfg_region_valid,
    output reg [ADDR_WIDTH-1:0] cfg_hnf_base,
    output reg [ADDR_WIDTH-1:0] cfg_hnf_end,
    output reg [ADDR_WIDTH-1:0] cfg_snf_base,
    output reg [ADDR_WIDTH-1:0] cfg_snf_end,
    output reg [ADDR_WIDTH-1:0] cfg_mn_base,
    output reg [ADDR_WIDTH-1:0] cfg_mn_end,
    output reg               cfg_dvm_enable,
    output reg               cfg_cg_enable,
    output reg [15:0]        cfg_excl_timeout,
    output reg [15:0]        cfg_mn_drain_cycles,
    output reg [7:0]         cfg_qos_age_shift,
    output reg [7:0]         cfg_qos_age_max,
    output reg               cfg_bist_init
);
    localparam CSR_CTRL      = 8'h00;
    localparam CSR_HNF_BASE  = 8'h10;
    localparam CSR_HNF_END   = 8'h18;
    localparam CSR_SNF_BASE  = 8'h20;
    localparam CSR_SNF_END   = 8'h28;
    localparam CSR_MN_BASE   = 8'h30;
    localparam CSR_MN_END    = 8'h38;
    localparam CSR_ERR_STATUS   = 8'h40;
    localparam CSR_EXCL_TIMEOUT = 8'h68;
    localparam CSR_MN_DRAIN_CYCLES = 8'h70;
    localparam CSR_QOS_AGE_SHIFT = 8'h78;
    localparam CSR_QOS_AGE_MAX   = 8'h7C;
    localparam CSR_HN_PERF_BASE = 8'h80;
    localparam CSR_RN_PERF_BASE = 8'hC0;
    localparam [3:0] CSR_HN_PERF_NIBBLE = CSR_HN_PERF_BASE[7:4];
    localparam [3:0] CSR_RN_PERF_NIBBLE = CSR_RN_PERF_BASE[7:4];
    localparam [ADDR_WIDTH-1:0] RESET_HNF_BASE = 32'h0000_0000;
    localparam [ADDR_WIDTH-1:0] RESET_HNF_END  = 32'h7FFF_FFFF;
    localparam [ADDR_WIDTH-1:0] RESET_SNF_BASE = 32'h8000_0000;
    localparam [ADDR_WIDTH-1:0] RESET_SNF_END  = 32'hBFFF_FFFF;
    localparam [ADDR_WIDTH-1:0] RESET_MN_BASE  = 32'hFFF0_0000;
    localparam [ADDR_WIDTH-1:0] RESET_MN_END   = 32'hFFFF_FFFF;

    // ERR_STATUS: [0] ECC single, [1] ECC double, [2] RN parity,
    //             [3] exclusive fail, [4] node watchdog (transaction stuck
    //             longer than the node timeout), [5] BIST init refused
    //             because traffic was in flight. All W1C.
    reg [5:0] err_status_q;
    wire [5:0] err_event_vec;
    wire       csr_err_status_write;
    wire       csr_ctrl_write;
    integer   csr_hn_idx;
    integer   csr_rn_idx;

    assign csr_ready = 1'b1;
    assign err_irq = err_status_q[1] | err_status_q[2] | err_status_q[4];
    assign err_event_vec = {bist_reject_event,
                            watchdog_event,
                            exclusive_fail_event,
                            rn_parity_error_event,
                            ecc_double_event,
                            ecc_single_event};
    assign csr_err_status_write = csr_valid && csr_write &&
                                  (csr_addr == CSR_ERR_STATUS);
    assign csr_ctrl_write = csr_valid && csr_write &&
                            (csr_addr == CSR_CTRL);

    always @(*) begin
        csr_rdata = 64'd0;
        case (csr_addr)
            CSR_CTRL: begin
                csr_rdata[0] = cfg_region_valid;
                csr_rdata[1] = cfg_dvm_enable;
                csr_rdata[2] = cfg_cg_enable;
                csr_rdata[3] = 1'b0;
            end
            CSR_HNF_BASE: csr_rdata[ADDR_WIDTH-1:0] = cfg_hnf_base;
            CSR_HNF_END:  csr_rdata[ADDR_WIDTH-1:0] = cfg_hnf_end;
            CSR_SNF_BASE: csr_rdata[ADDR_WIDTH-1:0] = cfg_snf_base;
            CSR_SNF_END:  csr_rdata[ADDR_WIDTH-1:0] = cfg_snf_end;
            CSR_MN_BASE:  csr_rdata[ADDR_WIDTH-1:0] = cfg_mn_base;
            CSR_MN_END:   csr_rdata[ADDR_WIDTH-1:0] = cfg_mn_end;
            CSR_ERR_STATUS: csr_rdata[5:0] = err_status_q;
            CSR_EXCL_TIMEOUT: csr_rdata[15:0] = cfg_excl_timeout;
            CSR_MN_DRAIN_CYCLES: csr_rdata[15:0] = cfg_mn_drain_cycles;
            CSR_QOS_AGE_SHIFT: csr_rdata[7:0] = cfg_qos_age_shift;
            CSR_QOS_AGE_MAX:   csr_rdata[7:0] = cfg_qos_age_max;
            default:      csr_rdata = 64'd0;
        endcase

        for (csr_hn_idx = 0; csr_hn_idx < NUM_HN; csr_hn_idx = csr_hn_idx + 1) begin
            if (csr_addr[7:4] == (CSR_HN_PERF_NIBBLE + csr_hn_idx))
                csr_rdata[31:0] =
                    hn_perf_counts_flat[(csr_hn_idx*16 + csr_addr[3:0])*32 +: 32];
        end

        for (csr_rn_idx = 0; csr_rn_idx < NUM_RN; csr_rn_idx = csr_rn_idx + 1) begin
            if (csr_addr[7:4] == (CSR_RN_PERF_NIBBLE + csr_rn_idx))
                csr_rdata[31:0] =
                    rn_perf_counts_flat[(csr_rn_idx*16 + csr_addr[3:0])*32 +: 32];
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            err_status_q     <= 6'b000000;
            cfg_region_valid <= 1'b0;
            cfg_hnf_base     <= RESET_HNF_BASE;
            cfg_hnf_end      <= RESET_HNF_END;
            cfg_snf_base     <= RESET_SNF_BASE;
            cfg_snf_end      <= RESET_SNF_END;
            cfg_mn_base      <= RESET_MN_BASE;
            cfg_mn_end       <= RESET_MN_END;
            cfg_dvm_enable   <= 1'b1;
            cfg_cg_enable    <= 1'b0;
            cfg_excl_timeout <= 16'd4096;
            cfg_mn_drain_cycles <= 16'd4;
            cfg_qos_age_shift <= `CHI_DEFAULT_QOS_AGE_SHIFT;
            cfg_qos_age_max   <= `CHI_DEFAULT_QOS_AGE_MAX;
            cfg_bist_init    <= 1'b0;
        end else begin
            cfg_bist_init <= csr_ctrl_write && csr_wdata[3];

            err_status_q <= csr_err_status_write ?
                            ((err_status_q & ~csr_wdata[5:0]) | err_event_vec) :
                            (err_status_q | err_event_vec);

            if (csr_valid && csr_write) begin
                case (csr_addr)
                    CSR_CTRL: begin
                        cfg_region_valid <= csr_wdata[0];
                        cfg_dvm_enable   <= csr_wdata[1];
                        cfg_cg_enable    <= csr_wdata[2];
                    end
                    CSR_HNF_BASE: cfg_hnf_base <= csr_wdata[ADDR_WIDTH-1:0];
                    CSR_HNF_END:  cfg_hnf_end  <= csr_wdata[ADDR_WIDTH-1:0];
                    CSR_SNF_BASE: cfg_snf_base <= csr_wdata[ADDR_WIDTH-1:0];
                    CSR_SNF_END:  cfg_snf_end  <= csr_wdata[ADDR_WIDTH-1:0];
                    CSR_MN_BASE:  cfg_mn_base  <= csr_wdata[ADDR_WIDTH-1:0];
                    CSR_MN_END:   cfg_mn_end   <= csr_wdata[ADDR_WIDTH-1:0];
                    CSR_EXCL_TIMEOUT: cfg_excl_timeout <=
                        (csr_wdata[15:0] == 16'd0) ? 16'd1 :
                                                      csr_wdata[15:0];
                    CSR_MN_DRAIN_CYCLES: cfg_mn_drain_cycles <= csr_wdata[15:0];
                    CSR_QOS_AGE_SHIFT: cfg_qos_age_shift <= csr_wdata[7:0];
                    CSR_QOS_AGE_MAX:   cfg_qos_age_max   <= csr_wdata[7:0];
                    default: begin
                        cfg_region_valid <= cfg_region_valid;
                    end
                endcase
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && (NUM_HN > 4)) begin
            $display("chi_csr_regs only maps four HN perf banks in 8-bit CSR space");
            $stop;
        end
        if (rstn && (NUM_RN > 4)) begin
            $display("chi_csr_regs only maps four RN perf banks in 8-bit CSR space");
            $stop;
        end
    end
    // synthesis translate_on
endmodule
