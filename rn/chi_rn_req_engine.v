`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_rn_req_engine
// Purpose: RN-F CPU request encoder. Converts CPU-side operations into CHI REQ
//          flits with target HN/MN routing, attributes, and transaction ID.
// -----------------------------------------------------------------------------
module chi_rn_req_engine #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    // STREX is CleanUnique(Excl) (B6.3): the RN then writes its own copy.
    // Without a local cache (external L1) it stays a WriteUnique carrying
    // the data.
    parameter STREX_CLEAN_UNIQUE = 1
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
    output reg [`CHI_REQ_W(NODE_ID_W)-1:0] tx_req_flit,
    output reg [`CHI_REQ_OPCODE_W-1:0] tx_req_opcode
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

    wire cpu_req_exclusive = (cpu_req_op == `CHI_CPU_OP_LDREX) ||
                             (cpu_req_op == `CHI_CPU_OP_STREX);
    wire cpu_req_dvm = (cpu_req_op == `CHI_CPU_OP_DVM_OP) ||
                       (cpu_req_op == `CHI_CPU_OP_DVM_SYNC);
    reg  req_uses_coherent_attrs;
    reg  req_exp_comp_ack;
    reg  [2:0] req_size_enc;
    reg  [ADDR_WIDTH-1:0] req_addr_enc;

    assign cpu_req_ready   = tx_req_ready && txn_alloc_ready;
    assign tx_req_valid    = cpu_req_valid && txn_alloc_ready;
    assign txn_alloc_valid = cpu_req_valid && tx_req_ready && txn_alloc_ready;

    always @(*) begin
        case (cpu_req_op)
            `CHI_CPU_OP_RD_SHARED: tx_req_opcode = `CHI_REQ_RD_SHARED;
            `CHI_CPU_OP_RD_UNIQUE: tx_req_opcode = `CHI_REQ_RD_UNIQUE;
            `CHI_CPU_OP_EVICT:     tx_req_opcode = `CHI_REQ_EVICT;
            `CHI_CPU_OP_WB_FULL:   tx_req_opcode = `CHI_REQ_WB_FULL;
            `CHI_CPU_OP_WR_UNIQUE: tx_req_opcode = `CHI_REQ_WR_UNIQUE;
            `CHI_CPU_OP_MK_UNIQUE: tx_req_opcode = `CHI_REQ_MK_UNIQUE;
            // Excl is only legal on ReadShared/ReadClean/ReadNotSharedDirty,
            // CleanUnique and the NoSnp pair (B6.3).
            `CHI_CPU_OP_LDREX:     tx_req_opcode = `CHI_REQ_RD_SHARED;
            `CHI_CPU_OP_STREX:     tx_req_opcode = (STREX_CLEAN_UNIQUE != 0) ?
                                                   `CHI_REQ_CLN_UNIQUE :
                                                   `CHI_REQ_WR_UNIQUE;
            `CHI_CPU_OP_DVM_OP:    tx_req_opcode = `CHI_REQ_DVM_OP;
            `CHI_CPU_OP_DVM_SYNC:  tx_req_opcode = `CHI_REQ_DVM_OP;
            default: tx_req_opcode = `CHI_REQ_RD_ONCE;
        endcase

        // A DVMOp is an 8-byte write whose Addr carries the first half of the
        // payload; Addr[3] must be zero (Table B8.10). A Sync has no payload
        // besides DVMType.
        req_size_enc = cpu_req_dvm ? `CHI_DVM_REQ_SIZE : cpu_req_size;
        req_addr_enc = cpu_req_addr;
        if (cpu_req_op == `CHI_CPU_OP_DVM_SYNC) begin
            req_addr_enc = {ADDR_WIDTH{1'b0}};
            req_addr_enc[`CHI_DVM_TYPE_LSB +: 3] = `CHI_DVM_TYPE_SYNC;
        end else if (cpu_req_dvm) begin
            req_addr_enc[3:0] = 4'b0000;
        end

        req_uses_coherent_attrs =
            (tx_req_opcode == `CHI_REQ_RD_SHARED)  ||
            (tx_req_opcode == `CHI_REQ_RD_UNIQUE)  ||
            (tx_req_opcode == `CHI_REQ_CLN_UNIQUE) ||
            (tx_req_opcode == `CHI_REQ_MK_UNIQUE)  ||
            (tx_req_opcode == `CHI_REQ_EVICT)      ||
            (tx_req_opcode == `CHI_REQ_WB_FULL)    ||
            (tx_req_opcode == `CHI_REQ_WB_PTL)     ||
            (tx_req_opcode == `CHI_REQ_WR_UNIQUE);
        req_exp_comp_ack =
            (tx_req_opcode == `CHI_REQ_CLN_UNIQUE) ||
            (tx_req_opcode == `CHI_REQ_MK_UNIQUE);

        tx_req_flit = {`CHI_REQ_W(NODE_ID_W){1'b0}};
        tx_req_flit[REQ_ADDR_LSB +: ADDR_WIDTH] = req_addr_enc;
        tx_req_flit[REQ_SIZE_LSB +: 3]           = req_size_enc;
        tx_req_flit[REQ_OPCODE_LSB +: `CHI_REQ_OPCODE_W]         = tx_req_opcode;
        tx_req_flit[REQ_TXN_LSB +: TXN_ID_W]     = txn_alloc_id;
        tx_req_flit[REQ_SRC_LSB +: NODE_ID_W]    = node_id;
        tx_req_flit[REQ_TGT_LSB +: NODE_ID_W]    = target_id;
        tx_req_flit[REQ_QOS_LSB +: QOS_W]        = qos_value;
        tx_req_flit[REQ_EXCL_LSB]                = cpu_req_exclusive;
        tx_req_flit[REQ_ORDER_LSB +: 2]          = 2'b00;
        tx_req_flit[REQ_ALLOW_RETRY_LSB]         = 1'b1;
        tx_req_flit[REQ_PCRD_TYPE_LSB +: `CHI_REQ_PCRD_TYPE_W] =
            `CHI_REQ_PCRD_TYPE_NONE;
        tx_req_flit[REQ_EXP_COMP_ACK_LSB]        = req_exp_comp_ack;
        tx_req_flit[REQ_MEMATTR_LSB +: `CHI_REQ_MEMATTR_W] =
            req_uses_coherent_attrs ? `CHI_REQ_MEMATTR_NORMAL_CACHE :
                                      `CHI_REQ_MEMATTR_DEVICE;
        tx_req_flit[REQ_SNPATTR_LSB +: `CHI_REQ_SNPATTR_W] =
            req_uses_coherent_attrs ? `CHI_REQ_SNPATTR_COHERENT :
                                      `CHI_REQ_SNPATTR_NONE;
        tx_req_flit[REQ_PAS_LSB +: `CHI_REQ_PAS_W] = `CHI_REQ_PAS_DEFAULT;
        tx_req_flit[REQ_TRACE_TAG_LSB] = 1'b0;
    end
endmodule
