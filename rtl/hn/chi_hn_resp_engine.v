`include "chi_defs.vh"

module chi_hn_resp_engine #(
    parameter NODE_ID   = 0,
    parameter NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W  = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W     = `CHI_DEFAULT_QOS_W,
    parameter DBID_W    = `CHI_DEFAULT_DBID_W
)(
    input                    clk,
    input                    rstn,
    input                    req_valid,
    output                   req_ready,
    input      [5:0]         req_opcode,
    input      [TXN_ID_W-1:0] req_txn_id,
    input      [NODE_ID_W-1:0] req_src_id,
    input      [QOS_W-1:0]   req_qos,
    input      [1:0]         resp_err,

    output                   rsp_valid,
    input                    rsp_ready,
    output reg [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rsp_flit
);
    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB;
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB;
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB;
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(DBID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(DBID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(DBID_W,TXN_ID_W,NODE_ID_W);

    wire req_fire = req_valid && req_ready;
    wire rsp_fire = rsp_valid && rsp_ready;

    reg                  rsp_valid_q;
    reg [5:0]            opcode_q;
    reg [TXN_ID_W-1:0]   txn_id_q;
    reg [NODE_ID_W-1:0]  src_id_q;
    reg [QOS_W-1:0]      qos_q;
    reg [1:0]            resp_err_q;

    assign req_ready = !rsp_valid_q || rsp_fire;
    assign rsp_valid = rsp_valid_q;

    always @(*) begin
        rsp_flit = {`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W){1'b0}};
        rsp_flit[RSP_RESP_LSB +: 3]       = 3'd0;
        rsp_flit[RSP_RESPERR_LSB +: 2]    = resp_err_q;
        rsp_flit[RSP_DBID_LSB +: DBID_W]  = {DBID_W{1'b0}};
        rsp_flit[RSP_DBID_LSB]            = 1'b1;
        rsp_flit[RSP_OPCODE_LSB +: 4]     = ((opcode_q == `CHI_REQ_WR_UNIQUE) ||
                                             (opcode_q == `CHI_REQ_WR_NO_SNP) ||
                                             (opcode_q == `CHI_REQ_WB_FULL) ||
                                             (opcode_q == `CHI_REQ_WB_PTL)) ?
                                             `CHI_RSP_DBID : `CHI_RSP_COMP;
        rsp_flit[RSP_TXN_LSB +: TXN_ID_W] = txn_id_q;
        rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = src_id_q;
        rsp_flit[RSP_QOS_LSB +: QOS_W]     = qos_q;
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rsp_valid_q <= 1'b0;
            opcode_q    <= 6'd0;
            txn_id_q    <= {TXN_ID_W{1'b0}};
            src_id_q    <= {NODE_ID_W{1'b0}};
            qos_q       <= {QOS_W{1'b0}};
            resp_err_q  <= `CHI_RESPERR_OK;
        end else begin
            if (req_fire) begin
                rsp_valid_q <= 1'b1;
                opcode_q    <= req_opcode;
                txn_id_q    <= req_txn_id;
                src_id_q    <= req_src_id;
                qos_q       <= req_qos;
                resp_err_q  <= resp_err;
            end else if (rsp_fire) begin
                rsp_valid_q <= 1'b0;
            end
        end
    end
endmodule
