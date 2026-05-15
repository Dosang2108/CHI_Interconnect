`include "chi_defs.vh"

module chi_rn_snoop_handler #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W
)(
    input                    rx_snp_valid,
    input      [`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] rx_snp_flit,
    output                   rx_snp_lcrdv,

    input      [NODE_ID_W-1:0] node_id,
    output                   tx_rsp_valid,
    input                    tx_rsp_ready,
    output reg [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] tx_rsp_flit
);
    localparam SNP_ADDR_LSB   = `CHI_SNP_ADDR_LSB;
    localparam SNP_SIZE_LSB   = `CHI_SNP_SIZE_LSB(ADDR_WIDTH);
    localparam SNP_OPCODE_LSB = `CHI_SNP_OPCODE_LSB(ADDR_WIDTH);
    localparam SNP_TXN_LSB    = `CHI_SNP_TXN_LSB(ADDR_WIDTH);
    localparam SNP_SRC_LSB    = `CHI_SNP_SRC_LSB(ADDR_WIDTH,TXN_ID_W);
    localparam SNP_TGT_LSB    = `CHI_SNP_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam SNP_QOS_LSB    = `CHI_SNP_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);

    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB;
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB;
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB;
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(DBID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(DBID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(DBID_W,TXN_ID_W,NODE_ID_W);

    assign tx_rsp_valid = rx_snp_valid;
    assign rx_snp_lcrdv = rx_snp_valid && tx_rsp_ready;

    always @(*) begin
        tx_rsp_flit = {`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W){1'b0}};
        tx_rsp_flit[RSP_RESP_LSB +: 3]       = 3'd0;
        tx_rsp_flit[RSP_RESPERR_LSB +: 2]    = `CHI_RESPERR_OK;
        tx_rsp_flit[RSP_DBID_LSB +: DBID_W]  = {DBID_W{1'b0}};
        tx_rsp_flit[RSP_OPCODE_LSB +: 4]     = `CHI_RSP_SNP_RESP;
        tx_rsp_flit[RSP_TXN_LSB +: TXN_ID_W] = rx_snp_flit[SNP_TXN_LSB +: TXN_ID_W];
        tx_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = node_id;
        tx_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = rx_snp_flit[SNP_SRC_LSB +: NODE_ID_W];
        tx_rsp_flit[RSP_QOS_LSB +: QOS_W]     = rx_snp_flit[SNP_QOS_LSB +: QOS_W];
    end
endmodule
