`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_addr_decoder
// Purpose: Address-to-target decoder for HN/SN/MN routing. It maps the
//          configured address regions first, then falls back to modulo banking
//          across the available target IDs.
// -----------------------------------------------------------------------------
module chi_addr_decoder #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NUM_TGT    = `CHI_DEFAULT_NUM_TGT,
    parameter TGT_ID_W   = 4,
    parameter NUM_HNF    = `CHI_DEFAULT_NUM_HN,
    parameter HNF_PORT   = 0,
    parameter SNF_PORT   = `CHI_DEFAULT_NUM_HN,
    parameter MN_PORT    = `CHI_DEFAULT_NUM_HN + `CHI_DEFAULT_NUM_SN,
    parameter HNF_BANK_LSB = 6,
    parameter [ADDR_WIDTH-1:0] HNF_BASE = 32'h0000_0000,
    parameter [ADDR_WIDTH-1:0] HNF_END  = 32'h7FFF_FFFF,
    parameter [ADDR_WIDTH-1:0] HNF_ALT_BASE = 32'hC000_0000,
    parameter [ADDR_WIDTH-1:0] HNF_ALT_END  = 32'hCFFF_FFFF,
    parameter [ADDR_WIDTH-1:0] SNF_BASE = 32'h8000_0000,
    parameter [ADDR_WIDTH-1:0] SNF_END  = 32'hBFFF_FFFF,
    parameter [ADDR_WIDTH-1:0] MN_BASE  = 32'hFFF0_0000,
    parameter [ADDR_WIDTH-1:0] MN_END   = 32'hFFFF_FFFF
)(
    input                    valid,
    input      [ADDR_WIDTH-1:0] addr,
    input                    cfg_region_valid,
    input      [ADDR_WIDTH-1:0] cfg_hnf_base,
    input      [ADDR_WIDTH-1:0] cfg_hnf_end,
    input      [ADDR_WIDTH-1:0] cfg_snf_base,
    input      [ADDR_WIDTH-1:0] cfg_snf_end,
    input      [ADDR_WIDTH-1:0] cfg_mn_base,
    input      [ADDR_WIDTH-1:0] cfg_mn_end,
    output reg [TGT_ID_W-1:0]   tgt_id,
    output reg [NUM_TGT-1:0]    tgt_onehot,
    output reg                  decode_error
);
    wire [ADDR_WIDTH-1:0] hnf_base_eff = cfg_region_valid ? cfg_hnf_base : HNF_BASE;
    wire [ADDR_WIDTH-1:0] hnf_end_eff  = cfg_region_valid ? cfg_hnf_end  : HNF_END;
    wire [ADDR_WIDTH-1:0] snf_base_eff = cfg_region_valid ? cfg_snf_base : SNF_BASE;
    wire [ADDR_WIDTH-1:0] snf_end_eff  = cfg_region_valid ? cfg_snf_end  : SNF_END;
    wire [ADDR_WIDTH-1:0] mn_base_eff  = cfg_region_valid ? cfg_mn_base  : MN_BASE;
    wire [ADDR_WIDTH-1:0] mn_end_eff   = cfg_region_valid ? cfg_mn_end   : MN_END;

    reg [TGT_ID_W-1:0] hnf_bank_id;
    integer bank_calc;

    task set_target;
        input integer port_id;
        begin
            tgt_id = port_id;
            if (port_id < NUM_TGT)
                tgt_onehot[port_id] = 1'b1;
            else
                decode_error = 1'b1;
        end
    endtask

    always @(*) begin
        tgt_id       = {TGT_ID_W{1'b0}};
        tgt_onehot   = {NUM_TGT{1'b0}};
        decode_error = 1'b0;
        hnf_bank_id  = {TGT_ID_W{1'b0}};
        bank_calc    = 0;

        if (valid) begin
            if (((addr >= hnf_base_eff) && (addr <= hnf_end_eff)) ||
                ((addr >= HNF_ALT_BASE) && (addr <= HNF_ALT_END))) begin
                if (NUM_HNF > 1) begin
                    bank_calc = (addr >> HNF_BANK_LSB) % NUM_HNF;
                    hnf_bank_id = bank_calc;
                end
                set_target(HNF_PORT + hnf_bank_id);
            end else if ((addr >= snf_base_eff) && (addr <= snf_end_eff)) begin
                set_target(SNF_PORT);
            end else if ((addr >= mn_base_eff) && (addr <= mn_end_eff)) begin
                set_target(MN_PORT);
            end else begin
                decode_error = 1'b1;
            end
        end
    end
endmodule
