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
    input      [`CHI_REQ_W(NODE_ID_W)-1:0] req_flit,
    output                   parsed_valid,
    output     [ADDR_WIDTH-1:0] addr,
    output     [2:0]         size,
    output     [`CHI_REQ_OPCODE_W-1:0] opcode,
    output     [TXN_ID_W-1:0] txn_id,
    output     [NODE_ID_W-1:0] src_id,
    output     [NODE_ID_W-1:0] tgt_id,
    output     [QOS_W-1:0]   qos,
    output                   excl,
    output     [1:0]         order,
    output                   allow_retry,
    output     [`CHI_REQ_PCRD_TYPE_W-1:0] pcrd_type,
    output                   exp_comp_ack,
    output     [`CHI_REQ_MEMATTR_W-1:0] memattr,
    output                   snpattr,
    output     [`CHI_REQ_PAS_W-1:0] pas,
    output                   trace_tag
);
    localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB(NODE_ID_W);
    localparam REQ_SIZE_LSB   = `CHI_REQ_SIZE_LSB(NODE_ID_W);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(NODE_ID_W);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(NODE_ID_W);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(NODE_ID_W);
    localparam REQ_TGT_LSB    = `CHI_REQ_TGT_LSB(NODE_ID_W);
    localparam REQ_QOS_LSB    = `CHI_REQ_QOS_LSB(NODE_ID_W);
    localparam REQ_EXCL_LSB   = `CHI_REQ_EXCL_LSB(NODE_ID_W);
    localparam REQ_ORDER_LSB  = `CHI_REQ_ORDER_LSB(NODE_ID_W);
    localparam REQ_ALLOW_RETRY_LSB =
        `CHI_REQ_ALLOW_RETRY_LSB(NODE_ID_W);
    localparam REQ_PCRD_TYPE_LSB =
        `CHI_REQ_PCRD_TYPE_LSB(NODE_ID_W);
    localparam REQ_EXP_COMP_ACK_LSB =
        `CHI_REQ_EXP_COMP_ACK_LSB(NODE_ID_W);
    localparam REQ_MEMATTR_LSB =
        `CHI_REQ_MEMATTR_LSB(NODE_ID_W);
    localparam REQ_SNPATTR_LSB =
        `CHI_REQ_SNPATTR_LSB(NODE_ID_W);
    localparam REQ_PAS_LSB =
        `CHI_REQ_PAS_LSB(NODE_ID_W);
    localparam REQ_TRACE_TAG_LSB =
        `CHI_REQ_TRACE_TAG_LSB(NODE_ID_W);

    assign parsed_valid = req_valid;
    assign addr   = req_flit[REQ_ADDR_LSB +: ADDR_WIDTH];
    assign size   = req_flit[REQ_SIZE_LSB +: 3];
    assign opcode = req_flit[REQ_OPCODE_LSB +: `CHI_REQ_OPCODE_W];
    assign txn_id = req_flit[REQ_TXN_LSB +: TXN_ID_W];
    assign src_id = req_flit[REQ_SRC_LSB +: NODE_ID_W];
    assign tgt_id = req_flit[REQ_TGT_LSB +: NODE_ID_W];
    assign qos    = req_flit[REQ_QOS_LSB +: QOS_W];
    assign excl   = req_flit[REQ_EXCL_LSB];
    assign order  = req_flit[REQ_ORDER_LSB +: 2];
    assign allow_retry  = req_flit[REQ_ALLOW_RETRY_LSB];
    assign pcrd_type    = req_flit[REQ_PCRD_TYPE_LSB +: `CHI_REQ_PCRD_TYPE_W];
    assign exp_comp_ack = req_flit[REQ_EXP_COMP_ACK_LSB];
    assign memattr      = req_flit[REQ_MEMATTR_LSB +: `CHI_REQ_MEMATTR_W];
    assign snpattr      = req_flit[REQ_SNPATTR_LSB];
    assign pas          = req_flit[REQ_PAS_LSB +: `CHI_REQ_PAS_W];
    assign trace_tag    = req_flit[REQ_TRACE_TAG_LSB];

    // synthesis translate_off
    always @(*) begin
        if (req_valid) begin
            if (((opcode != `CHI_REQ_PCRD_RETURN) &&
                 (pcrd_type != `CHI_REQ_PCRD_TYPE_NONE)) ||
                (pas != `CHI_REQ_PAS_DEFAULT) ||
                trace_tag) begin
                $display("chi_hn_req_parser unsupported Issue-H REQ attrs opcode %0h txn %0h pcrd %0h pas %0h trace %0b",
                         opcode, txn_id, pcrd_type, pas, trace_tag);
                $stop;
            end
            if (((opcode == `CHI_REQ_CLN_UNIQUE) ||
                 (opcode == `CHI_REQ_MK_UNIQUE)) &&
                !exp_comp_ack) begin
                $display("chi_hn_req_parser dataless unique opcode %0h txn %0h missing ExpCompAck",
                         opcode, txn_id);
                $stop;
            end
        end
    end
    // synthesis translate_on
endmodule
