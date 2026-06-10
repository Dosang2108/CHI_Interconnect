`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_hn_snoop_generator
// Purpose: Builds one SNP flit per targeted RN from an HN snoop/back-invalidate
//          request and returns a flattened valid/flit vector.
// -----------------------------------------------------------------------------
module chi_hn_snoop_generator #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W
)(
    input                    start_valid,
    input      [ADDR_WIDTH-1:0] addr,
    input      [TXN_ID_W-1:0] txn_id,
    input      [5:0]         req_opcode,
    input      [2:0]         req_size,
    input      [NODE_ID_W-1:0] hn_node_id,
    input      [NODE_ID_W-1:0] requestor_id,
    input      [QOS_W-1:0]   qos,
    input      [NUM_RN-1:0]  sharer_vec,
    output reg [NUM_RN-1:0]  snp_valid_vec,
    output reg [NUM_RN*`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] snp_flit_flat
);
    localparam SNP_ADDR_LSB   = `CHI_SNP_ADDR_LSB;
    localparam SNP_SIZE_LSB   = `CHI_SNP_SIZE_LSB(ADDR_WIDTH);
    localparam SNP_OPCODE_LSB = `CHI_SNP_OPCODE_LSB(ADDR_WIDTH);
    localparam SNP_TXN_LSB    = `CHI_SNP_TXN_LSB(ADDR_WIDTH);
    localparam SNP_SRC_LSB    = `CHI_SNP_SRC_LSB(ADDR_WIDTH,TXN_ID_W);
    localparam SNP_TGT_LSB    = `CHI_SNP_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam SNP_QOS_LSB    = `CHI_SNP_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam SNP_W          = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);

    integer i;
    reg [5:0] snp_opcode;

    always @(*) begin
        case (req_opcode)
            `CHI_REQ_RD_SHARED: snp_opcode = `CHI_SNP_SHARED;
            `CHI_REQ_RD_UNIQUE: snp_opcode = `CHI_SNP_UNIQUE;
            `CHI_REQ_MK_UNIQUE: snp_opcode = `CHI_SNP_INVALID;
            `CHI_REQ_WR_UNIQUE: snp_opcode = `CHI_SNP_INVALID;
            default:            snp_opcode = `CHI_SNP_INVALID;
        endcase
    end

    always @(*) begin
        snp_valid_vec = {NUM_RN{1'b0}};
        snp_flit_flat = {NUM_RN*SNP_W{1'b0}};

        for (i = 0; i < NUM_RN; i = i + 1) begin
            if (start_valid && sharer_vec[i] && (requestor_id != i)) begin
                snp_valid_vec[i] = 1'b1;
                snp_flit_flat[i*SNP_W + SNP_ADDR_LSB +: ADDR_WIDTH] = addr;
                snp_flit_flat[i*SNP_W + SNP_SIZE_LSB +: 3]          = req_size;
                snp_flit_flat[i*SNP_W + SNP_OPCODE_LSB +: 6]        = snp_opcode;
                snp_flit_flat[i*SNP_W + SNP_TXN_LSB +: TXN_ID_W]    = txn_id;
                snp_flit_flat[i*SNP_W + SNP_SRC_LSB +: NODE_ID_W]   = hn_node_id;
                snp_flit_flat[i*SNP_W + SNP_TGT_LSB +: NODE_ID_W]   = i;
                snp_flit_flat[i*SNP_W + SNP_QOS_LSB +: QOS_W]       = qos;
            end
        end
    end
endmodule
