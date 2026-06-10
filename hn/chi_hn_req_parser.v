`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_hn_req_parser
// Purpose: Combinational HN-F REQ flit parser. It extracts address, opcode,
//          source/target IDs, QoS, exclusives, and ordering attributes.
// -----------------------------------------------------------------------------
module chi_hn_req_parser #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W
)(
    input                    req_valid,
    input      [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] req_flit,
    output                   parsed_valid,
    output     [ADDR_WIDTH-1:0] addr,
    output     [2:0]         size,
    output     [5:0]         opcode,
    output     [TXN_ID_W-1:0] txn_id,
    output     [NODE_ID_W-1:0] src_id,
    output     [NODE_ID_W-1:0] tgt_id,
    output     [QOS_W-1:0]   qos,
    output                   excl,
    output     [1:0]         order
);
    localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB;
    localparam REQ_SIZE_LSB   = `CHI_REQ_SIZE_LSB(ADDR_WIDTH);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(ADDR_WIDTH);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(ADDR_WIDTH);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(ADDR_WIDTH,TXN_ID_W);
    localparam REQ_TGT_LSB    = `CHI_REQ_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam REQ_QOS_LSB    = `CHI_REQ_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam REQ_EXCL_LSB   = `CHI_REQ_EXCL_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W,QOS_W);
    localparam REQ_ORDER_LSB  = `CHI_REQ_ORDER_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W,QOS_W);

    assign parsed_valid = req_valid;
    assign addr   = req_flit[REQ_ADDR_LSB +: ADDR_WIDTH];
    assign size   = req_flit[REQ_SIZE_LSB +: 3];
    assign opcode = req_flit[REQ_OPCODE_LSB +: 6];
    assign txn_id = req_flit[REQ_TXN_LSB +: TXN_ID_W];
    assign src_id = req_flit[REQ_SRC_LSB +: NODE_ID_W];
    assign tgt_id = req_flit[REQ_TGT_LSB +: NODE_ID_W];
    assign qos    = req_flit[REQ_QOS_LSB +: QOS_W];
    assign excl   = req_flit[REQ_EXCL_LSB];
    assign order  = req_flit[REQ_ORDER_LSB +: 2];
endmodule
