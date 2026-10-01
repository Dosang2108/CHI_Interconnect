`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_rn_rsp_rx
// Purpose: RN-F RSP receive decoder. It identifies Comp/DBID responses,
//          extracts response error and DBID fields, and flags write DBID
//          updates for the transaction table.
// -----------------------------------------------------------------------------
module chi_rn_rsp_rx #(
    parameter NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W  = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W     = `CHI_DEFAULT_QOS_W,
    parameter DBID_W    = `CHI_DEFAULT_DBID_W
)(
    input                    clk,
    input                    rstn,
    output                   busy,
    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_ready,
    output                   rx_rsp_lcrdv,
    input                    rsp_ready,

    output                   comp_valid,
    output                   dbid_valid,
    output                   retry_ack_valid,
    output                   pcrd_grant_valid,
    output     [TXN_ID_W-1:0] rsp_txn_id,
    output     [DBID_W-1:0]  rsp_dbid,
    output     [`CHI_REQ_PCRD_TYPE_W-1:0] rsp_pcrd_type,
    output     [NODE_ID_W-1:0] rsp_src_id,
    output     [1:0]         rsp_resp_err
);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W);
    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);

    wire                 rsp_in_ready;
    wire                 rsp_valid_buf;
    wire [RSP_W-1:0]     rsp_flit_buf;
    wire                 rsp_pop_unused;
    wire [15:0]          rsp_used_unused;
    wire [`CHI_RSP_OPCODE_W-1:0] rsp_opcode =
        rsp_flit_buf[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W];

    assign rx_rsp_ready = rsp_in_ready;
    assign rx_rsp_lcrdv = rx_rsp_valid && rsp_in_ready;
    assign rsp_txn_id   = rsp_flit_buf[RSP_TXN_LSB +: TXN_ID_W];
    assign rsp_dbid     = rsp_flit_buf[RSP_DBID_LSB +: DBID_W];
    assign rsp_pcrd_type =
        rsp_flit_buf[`CHI_RSP_PCRD_TYPE_LSB(NODE_ID_W) +: `CHI_REQ_PCRD_TYPE_W];
    assign rsp_src_id   = rsp_flit_buf[RSP_SRC_LSB +: NODE_ID_W];
    assign rsp_resp_err = rsp_flit_buf[RSP_RESPERR_LSB +: 2];
    assign comp_valid   = rsp_valid_buf && rsp_ready &&
                          ((rsp_opcode == `CHI_RSP_COMP) ||
                           (rsp_opcode == `CHI_RSP_COMP_DBID));
    assign dbid_valid   = rsp_valid_buf && rsp_ready &&
                          ((rsp_opcode == `CHI_RSP_DBID) ||
                           (rsp_opcode == `CHI_RSP_COMP_DBID));
    assign retry_ack_valid = rsp_valid_buf && rsp_ready &&
                             (rsp_opcode == `CHI_RSP_RETRY_ACK);
    assign pcrd_grant_valid = rsp_valid_buf && rsp_ready &&
                              (rsp_opcode == `CHI_RSP_PCRD_GRANT);

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && rsp_valid_buf && rsp_ready &&
            (rsp_opcode == `CHI_RSP_READ_RECEIPT)) begin
            $display("chi_rn_rsp_rx unsupported Issue-H RSP opcode %0h txn %0h",
                     rsp_opcode, rsp_txn_id);
            $stop;
        end
    end
    // synthesis translate_on

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
        .pop_pulse(rsp_pop_unused),
        .used_count(rsp_used_unused)
    );

    // A response is buffered and not yet consumed.
    assign busy = rsp_valid_buf;
endmodule
