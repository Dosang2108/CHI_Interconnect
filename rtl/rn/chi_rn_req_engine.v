`include "chi_defs.vh"

module chi_rn_req_engine #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W
)(
    input                    cpu_req_valid,
    output                   cpu_req_ready,
    input      [ADDR_WIDTH-1:0] cpu_req_addr,
    input      [3:0]         cpu_req_op,
    input      [2:0]         cpu_req_size,
    input      [QOS_W-1:0]   qos_value,
    input      [NODE_ID_W-1:0] node_id,
    input      [NODE_ID_W-1:0] target_id,

    output                   txn_alloc_valid,
    input                    txn_alloc_ready,
    input      [TXN_ID_W-1:0] txn_alloc_id,

    output                   tx_req_valid,
    input                    tx_req_ready,
    output reg [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] tx_req_flit,
    output reg [5:0]         tx_req_opcode
);
    localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB;
    localparam REQ_SIZE_LSB   = `CHI_REQ_SIZE_LSB(ADDR_WIDTH);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(ADDR_WIDTH);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(ADDR_WIDTH);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(ADDR_WIDTH,TXN_ID_W);
    localparam REQ_TGT_LSB    = `CHI_REQ_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam REQ_QOS_LSB    = `CHI_REQ_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);

    assign cpu_req_ready   = tx_req_ready && txn_alloc_ready;
    assign tx_req_valid    = cpu_req_valid && txn_alloc_ready;
    assign txn_alloc_valid = cpu_req_valid && tx_req_ready && txn_alloc_ready;

    always @(*) begin
        case (cpu_req_op)
            4'd0: tx_req_opcode = `CHI_REQ_RD_SHARED;
            4'd1: tx_req_opcode = `CHI_REQ_RD_UNIQUE;
            4'd2: tx_req_opcode = `CHI_REQ_EVICT;
            4'd3: tx_req_opcode = `CHI_REQ_WB_FULL;
            4'd4: tx_req_opcode = `CHI_REQ_MK_UNIQUE;
            default: tx_req_opcode = `CHI_REQ_RD_ONCE;
        endcase

        tx_req_flit = {`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W){1'b0}};
        tx_req_flit[REQ_ADDR_LSB +: ADDR_WIDTH] = cpu_req_addr;
        tx_req_flit[REQ_SIZE_LSB +: 3]           = cpu_req_size;
        tx_req_flit[REQ_OPCODE_LSB +: 6]         = tx_req_opcode;
        tx_req_flit[REQ_TXN_LSB +: TXN_ID_W]     = txn_alloc_id;
        tx_req_flit[REQ_SRC_LSB +: NODE_ID_W]    = node_id;
        tx_req_flit[REQ_TGT_LSB +: NODE_ID_W]    = target_id;
        tx_req_flit[REQ_QOS_LSB +: QOS_W]        = qos_value;
    end
endmodule
