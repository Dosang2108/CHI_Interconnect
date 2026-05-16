`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_csr_regs
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_csr_regs #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W
)(
    input                    clk,
    input                    rstn,

    input                    csr_valid,
    input                    csr_write,
    input      [7:0]         csr_addr,
    input      [63:0]        csr_wdata,
    output                   csr_ready,
    output reg [63:0]        csr_rdata,

    output reg               cfg_region_valid,
    output reg [ADDR_WIDTH-1:0] cfg_hnf_base,
    output reg [ADDR_WIDTH-1:0] cfg_hnf_end,
    output reg [ADDR_WIDTH-1:0] cfg_snf_base,
    output reg [ADDR_WIDTH-1:0] cfg_snf_end,
    output reg [ADDR_WIDTH-1:0] cfg_mn_base,
    output reg [ADDR_WIDTH-1:0] cfg_mn_end,
    output reg               cfg_dvm_enable,
    output reg               cfg_cg_enable,
    output reg               cfg_bist_init
);
    localparam CSR_CTRL      = 8'h00;
    localparam CSR_HNF_BASE  = 8'h10;
    localparam CSR_HNF_END   = 8'h18;
    localparam CSR_SNF_BASE  = 8'h20;
    localparam CSR_SNF_END   = 8'h28;
    localparam CSR_MN_BASE   = 8'h30;
    localparam CSR_MN_END    = 8'h38;
    localparam [ADDR_WIDTH-1:0] RESET_HNF_BASE = 44'h0000_0000;
    localparam [ADDR_WIDTH-1:0] RESET_HNF_END  = 44'h0000_7FFF_FFFF;
    localparam [ADDR_WIDTH-1:0] RESET_SNF_BASE = 44'h0000_8000_0000;
    localparam [ADDR_WIDTH-1:0] RESET_SNF_END  = 44'h0000_BFFF_FFFF;
    localparam [ADDR_WIDTH-1:0] RESET_MN_BASE  = 44'h0000_FFF0_0000;
    localparam [ADDR_WIDTH-1:0] RESET_MN_END   = 44'h0000_FFFF_FFFF;

    assign csr_ready = 1'b1;

    always @(*) begin
        csr_rdata = 64'd0;
        case (csr_addr)
            CSR_CTRL: begin
                csr_rdata[0] = cfg_region_valid;
                csr_rdata[1] = cfg_dvm_enable;
                csr_rdata[2] = cfg_cg_enable;
                csr_rdata[3] = cfg_bist_init;
            end
            CSR_HNF_BASE: csr_rdata[ADDR_WIDTH-1:0] = cfg_hnf_base;
            CSR_HNF_END:  csr_rdata[ADDR_WIDTH-1:0] = cfg_hnf_end;
            CSR_SNF_BASE: csr_rdata[ADDR_WIDTH-1:0] = cfg_snf_base;
            CSR_SNF_END:  csr_rdata[ADDR_WIDTH-1:0] = cfg_snf_end;
            CSR_MN_BASE:  csr_rdata[ADDR_WIDTH-1:0] = cfg_mn_base;
            CSR_MN_END:   csr_rdata[ADDR_WIDTH-1:0] = cfg_mn_end;
            default:      csr_rdata = 64'd0;
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            cfg_region_valid <= 1'b0;
            cfg_hnf_base     <= RESET_HNF_BASE;
            cfg_hnf_end      <= RESET_HNF_END;
            cfg_snf_base     <= RESET_SNF_BASE;
            cfg_snf_end      <= RESET_SNF_END;
            cfg_mn_base      <= RESET_MN_BASE;
            cfg_mn_end       <= RESET_MN_END;
            cfg_dvm_enable   <= 1'b1;
            cfg_cg_enable    <= 1'b0;
            cfg_bist_init    <= 1'b0;
        end else if (csr_valid && csr_write) begin
            case (csr_addr)
                CSR_CTRL: begin
                    cfg_region_valid <= csr_wdata[0];
                    cfg_dvm_enable   <= csr_wdata[1];
                    cfg_cg_enable    <= csr_wdata[2];
                    cfg_bist_init    <= csr_wdata[3];
                end
                CSR_HNF_BASE: cfg_hnf_base <= csr_wdata[ADDR_WIDTH-1:0];
                CSR_HNF_END:  cfg_hnf_end  <= csr_wdata[ADDR_WIDTH-1:0];
                CSR_SNF_BASE: cfg_snf_base <= csr_wdata[ADDR_WIDTH-1:0];
                CSR_SNF_END:  cfg_snf_end  <= csr_wdata[ADDR_WIDTH-1:0];
                CSR_MN_BASE:  cfg_mn_base  <= csr_wdata[ADDR_WIDTH-1:0];
                CSR_MN_END:   cfg_mn_end   <= csr_wdata[ADDR_WIDTH-1:0];
                default: begin
                    cfg_region_valid <= cfg_region_valid;
                end
            endcase
        end
    end
endmodule
