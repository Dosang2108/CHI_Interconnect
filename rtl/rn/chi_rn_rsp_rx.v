`include "../common/chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_rn_rsp_rx
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_rn_rsp_rx #(
    parameter NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W  = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W     = `CHI_DEFAULT_QOS_W,
    parameter DBID_W    = `CHI_DEFAULT_DBID_W
)(
    input                    clk,
    input                    rstn,
    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_lcrdv,
    input                    rsp_ready,

    output                   comp_valid,
    output                   dbid_valid,
    output     [TXN_ID_W-1:0] rsp_txn_id,
    output     [DBID_W-1:0]  rsp_dbid,
    output     [NODE_ID_W-1:0] rsp_src_id,
    output     [1:0]         rsp_resp_err
);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB;
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB;
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB;
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(DBID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(DBID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W);

    wire                 rsp_in_ready;
    wire                 rsp_valid_buf;
    wire [RSP_W-1:0]     rsp_flit_buf;
    wire [15:0]          rsp_used_unused;
    wire [3:0]           rsp_opcode = rsp_flit_buf[RSP_OPCODE_LSB +: 4];

    assign rx_rsp_lcrdv = rx_rsp_valid && rsp_in_ready;
    assign rsp_txn_id   = rsp_flit_buf[RSP_TXN_LSB +: TXN_ID_W];
    assign rsp_dbid     = rsp_flit_buf[RSP_DBID_LSB +: DBID_W];
    assign rsp_src_id   = rsp_flit_buf[RSP_SRC_LSB +: NODE_ID_W];
    assign rsp_resp_err = rsp_flit_buf[RSP_RESPERR_LSB +: 2];
    assign comp_valid   = rsp_valid_buf && rsp_ready &&
                          ((rsp_opcode == `CHI_RSP_COMP) ||
                           (rsp_opcode == `CHI_RSP_COMP_DBID) ||
                           (rsp_opcode == `CHI_RSP_DVM_COMPLETE));
    assign dbid_valid   = rsp_valid_buf && rsp_ready &&
                          ((rsp_opcode == `CHI_RSP_DBID) ||
                           (rsp_opcode == `CHI_RSP_COMP_DBID));

    chi_fifo #(
        .WIDTH(RSP_W),
        .DEPTH(2)
    ) u_rsp_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(rx_rsp_valid),
        .in_ready(rsp_in_ready),
        .in_data(rx_rsp_flit),
        .out_valid(rsp_valid_buf),
        .out_ready(rsp_ready),
        .out_data(rsp_flit_buf),
        .used_count(rsp_used_unused)
    );
endmodule
