`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module set: chi_*_compact_to_boundary / chi_*_boundary_to_compact
// Purpose   : Adapters between the fabric flit and an external CHI port.
//
// Both sides use the IHI0050H B13.9 layout from chi_defs.vh. The fabric
// ("compact") flit has none of the optional interface properties; the
// external ("boundary") flit may add the ones below, at the positions
// Tables B13.6-B13.9 give them:
//   REQ: MPAM (MPAM_W = 0, 12 or 15) then RSVDC (RSVDC_W), above TraceTag.
//   SNP: MPAM (MPAM_W), above TraceTag.
//   DAT: RSVDC (RSVDC_W) below BE, Poison (DW/64 bits when POISON = 1)
//        above Data. DataCheck is not supported.
// compact_to_boundary drives the added fields as zero.
// boundary_to_compact raises unsupported_attr when an added field, or a
// base field this IP does not implement, is non-zero, and clears those
// fields in compact_flit. The integrator must reject a flit that raises
// unsupported_attr.
// -----------------------------------------------------------------------------

// Checks one optional-property width against the values B13.9 allows.
`define CHI_BOUNDARY_RSVDC_CHECK(W) \
    generate \
        if (((W) != 0) && ((W) != 4) && ((W) != 8) && ((W) != 12) && \
            ((W) != 16) && ((W) != 24) && ((W) != 32)) begin : g_bad_rsvdc_w \
            $fatal(1, "CHI boundary: RSVDC_W=%0d, Y is 0, 4, 8, 12, 16, 24 or 32", (W)); \
        end \
    endgenerate
`define CHI_BOUNDARY_MPAM_CHECK(W) \
    generate \
        if (((W) != 0) && ((W) != 12) && ((W) != 15)) begin : g_bad_mpam_w \
            $fatal(1, "CHI boundary: MPAM_W=%0d, M is 0, 12 or 15", (W)); \
        end \
    endgenerate

module chi_req_compact_to_boundary #(
    parameter integer NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter integer MPAM_W    = 0,
    parameter integer RSVDC_W   = 0
)(
    input      [`CHI_REQ_W(NODE_ID_W)-1:0]                  compact_flit,
    output reg [`CHI_REQ_W(NODE_ID_W)+MPAM_W+RSVDC_W-1:0]   boundary_flit
);
    localparam integer C_W = `CHI_REQ_W(NODE_ID_W);
    localparam integer B_W = C_W + MPAM_W + RSVDC_W;

    `CHI_FLIT_PARAM_CHECK(`CHI_DEFAULT_ADDR_W,NODE_ID_W,`CHI_FLIT_TXN_W,`CHI_FLIT_DBID_W,`CHI_FLIT_QOS_W,`CHI_DEFAULT_DAT_DATA_W)
    `CHI_BOUNDARY_MPAM_CHECK(MPAM_W)
    `CHI_BOUNDARY_RSVDC_CHECK(RSVDC_W)

    always @(*) begin
        boundary_flit = {B_W{1'b0}};
        boundary_flit[C_W-1:0] = compact_flit;
    end
endmodule

module chi_req_boundary_to_compact #(
    parameter integer NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter integer MPAM_W    = 0,
    parameter integer RSVDC_W   = 0
)(
    input      [`CHI_REQ_W(NODE_ID_W)+MPAM_W+RSVDC_W-1:0]   boundary_flit,
    output reg [`CHI_REQ_W(NODE_ID_W)-1:0]                  compact_flit,
    output                                                  unsupported_attr
);
    localparam integer C_W = `CHI_REQ_W(NODE_ID_W);
    localparam integer B_W = C_W + MPAM_W + RSVDC_W;
    localparam OPCODE_LSB   = `CHI_REQ_OPCODE_LSB(NODE_ID_W);
    localparam STASH_NV_LSB = `CHI_REQ_STASH_NID_VALID_LSB(NODE_ID_W);
    localparam MULTI_LSB    = `CHI_REQ_MULTI_REQ_LSB(NODE_ID_W);
    localparam NUM_REQ_LSB  = `CHI_REQ_NUM_REQ_LSB(NODE_ID_W);
    localparam PAS_LSB      = `CHI_REQ_PAS_LSB(NODE_ID_W);
    localparam PCRD_LSB     = `CHI_REQ_PCRD_TYPE_LSB(NODE_ID_W);
    localparam LPID_LSB     = `CHI_REQ_LPID_LSB(NODE_ID_W);
    localparam TAGOP_LSB    = `CHI_REQ_TAGOP_LSB(NODE_ID_W);
    localparam TRACE_LSB    = `CHI_REQ_TRACE_TAG_LSB(NODE_ID_W);

    `CHI_FLIT_PARAM_CHECK(`CHI_DEFAULT_ADDR_W,NODE_ID_W,`CHI_FLIT_TXN_W,`CHI_FLIT_DBID_W,`CHI_FLIT_QOS_W,`CHI_DEFAULT_DAT_DATA_W)
    `CHI_BOUNDARY_MPAM_CHECK(MPAM_W)
    `CHI_BOUNDARY_RSVDC_CHECK(RSVDC_W)

    wire [C_W-1:0] base = boundary_flit[C_W-1:0];
    wire [`CHI_REQ_OPCODE_W-1:0] opcode = base[OPCODE_LSB +: `CHI_REQ_OPCODE_W];
    wire pcrd_bad = (opcode != `CHI_REQ_PCRD_RETURN) &&
                    (|base[PCRD_LSB +: `CHI_REQ_PCRD_TYPE_W]);
    // Stash/Endian/Deep, multi-request, NumReq above Size, a non-default
    // PAS, LPID/PGroupID, memory tagging, trace, and every added property.
    wire base_bad =
        base[STASH_NV_LSB] || base[MULTI_LSB] ||
        (|base[NUM_REQ_LSB+3 +: 3]) ||
        (base[PAS_LSB +: `CHI_REQ_PAS_W] != `CHI_REQ_PAS_DEFAULT) ||
        (|base[LPID_LSB +: `CHI_REQ_LPID_W]) ||
        (|base[TAGOP_LSB +: 2]) || base[TRACE_LSB];
    wire [B_W-1:0] added = boundary_flit >> C_W;

    assign unsupported_attr = pcrd_bad || base_bad || (|added);

    always @(*) begin
        compact_flit = base;
        compact_flit[STASH_NV_LSB] = 1'b0;
        compact_flit[MULTI_LSB] = 1'b0;
        compact_flit[NUM_REQ_LSB+3 +: 3] = 3'b000;
        compact_flit[PAS_LSB +: `CHI_REQ_PAS_W] = `CHI_REQ_PAS_DEFAULT;
        compact_flit[LPID_LSB +: `CHI_REQ_LPID_W] = {`CHI_REQ_LPID_W{1'b0}};
        compact_flit[TAGOP_LSB +: 2] = 2'b00;
        compact_flit[TRACE_LSB] = 1'b0;
        if (pcrd_bad)
            compact_flit[PCRD_LSB +: `CHI_REQ_PCRD_TYPE_W] =
                {`CHI_REQ_PCRD_TYPE_W{1'b0}};
    end
endmodule

// RSP has no optional properties (Table B13.7), so the boundary flit is the
// fabric flit; the adapters only screen unsupported fields.
module chi_rsp_compact_to_boundary #(
    parameter integer NODE_ID_W = `CHI_DEFAULT_NODE_ID_W
)(
    input      [`CHI_RSP_W(NODE_ID_W)-1:0] compact_flit,
    output     [`CHI_RSP_W(NODE_ID_W)-1:0] boundary_flit
);
    `CHI_FLIT_PARAM_CHECK(`CHI_DEFAULT_ADDR_W,NODE_ID_W,`CHI_FLIT_TXN_W,`CHI_FLIT_DBID_W,`CHI_FLIT_QOS_W,`CHI_DEFAULT_DAT_DATA_W)

    assign boundary_flit = compact_flit;
endmodule

module chi_rsp_boundary_to_compact #(
    parameter integer NODE_ID_W = `CHI_DEFAULT_NODE_ID_W
)(
    input      [`CHI_RSP_W(NODE_ID_W)-1:0] boundary_flit,
    output reg [`CHI_RSP_W(NODE_ID_W)-1:0] compact_flit,
    output                                 unsupported_attr
);
    localparam OPCODE_LSB = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam PCRD_LSB   = `CHI_RSP_PCRD_TYPE_LSB(NODE_ID_W);
    localparam TAGOP_LSB  = `CHI_RSP_TAGOP_LSB(NODE_ID_W);
    localparam TRACE_LSB  = `CHI_RSP_TRACE_TAG_LSB(NODE_ID_W);
    localparam CLID_LSB   = `CHI_RSP_CACHE_LINE_ID_LSB(NODE_ID_W);

    `CHI_FLIT_PARAM_CHECK(`CHI_DEFAULT_ADDR_W,NODE_ID_W,`CHI_FLIT_TXN_W,`CHI_FLIT_DBID_W,`CHI_FLIT_QOS_W,`CHI_DEFAULT_DAT_DATA_W)

    wire [`CHI_RSP_OPCODE_W-1:0] opcode =
        boundary_flit[OPCODE_LSB +: `CHI_RSP_OPCODE_W];
    wire uses_pcrd = (opcode == `CHI_RSP_RETRY_ACK) ||
                     (opcode == `CHI_RSP_PCRD_GRANT);
    wire pcrd_bad = !uses_pcrd && (|boundary_flit[PCRD_LSB +: 4]);

    assign unsupported_attr =
        (opcode == `CHI_RSP_READ_RECEIPT) || pcrd_bad ||
        (|boundary_flit[TAGOP_LSB +: 2]) || boundary_flit[TRACE_LSB] ||
        (|boundary_flit[CLID_LSB +: 6]);

    always @(*) begin
        compact_flit = boundary_flit;
        compact_flit[TAGOP_LSB +: 2] = 2'b00;
        compact_flit[TRACE_LSB] = 1'b0;
        compact_flit[CLID_LSB +: 6] = 6'd0;
        if (pcrd_bad)
            compact_flit[PCRD_LSB +: 4] = 4'd0;
    end
endmodule

module chi_snp_compact_to_boundary #(
    parameter integer NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter integer MPAM_W    = 0
)(
    input      [`CHI_SNP_W(NODE_ID_W)-1:0]         compact_flit,
    output reg [`CHI_SNP_W(NODE_ID_W)+MPAM_W-1:0]  boundary_flit
);
    localparam integer C_W = `CHI_SNP_W(NODE_ID_W);
    localparam integer B_W = C_W + MPAM_W;

    `CHI_FLIT_PARAM_CHECK(`CHI_DEFAULT_ADDR_W,NODE_ID_W,`CHI_FLIT_TXN_W,`CHI_FLIT_DBID_W,`CHI_FLIT_QOS_W,`CHI_DEFAULT_DAT_DATA_W)
    `CHI_BOUNDARY_MPAM_CHECK(MPAM_W)

    always @(*) begin
        boundary_flit = {B_W{1'b0}};
        boundary_flit[C_W-1:0] = compact_flit;
    end
endmodule

module chi_snp_boundary_to_compact #(
    parameter integer NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter integer MPAM_W    = 0
)(
    input      [`CHI_SNP_W(NODE_ID_W)+MPAM_W-1:0]  boundary_flit,
    output reg [`CHI_SNP_W(NODE_ID_W)-1:0]         compact_flit,
    output                                         unsupported_attr
);
    localparam integer C_W = `CHI_SNP_W(NODE_ID_W);
    localparam integer B_W = C_W + MPAM_W;
    localparam OPCODE_LSB  = `CHI_SNP_OPCODE_LSB(NODE_ID_W);
    localparam FWD_NID_LSB = `CHI_SNP_FWD_NID_LSB(NODE_ID_W);
    localparam FWD_TXN_LSB = `CHI_SNP_FWD_TXN_LSB(NODE_ID_W);
    localparam PAS_LSB     = `CHI_SNP_PAS_LSB(NODE_ID_W);
    localparam TRACE_LSB   = `CHI_SNP_TRACE_TAG_LSB(NODE_ID_W);

    `CHI_FLIT_PARAM_CHECK(`CHI_DEFAULT_ADDR_W,NODE_ID_W,`CHI_FLIT_TXN_W,`CHI_FLIT_DBID_W,`CHI_FLIT_QOS_W,`CHI_DEFAULT_DAT_DATA_W)
    `CHI_BOUNDARY_MPAM_CHECK(MPAM_W)

    wire [C_W-1:0] base = boundary_flit[C_W-1:0];
    wire [`CHI_SNP_OPCODE_W-1:0] opcode = base[OPCODE_LSB +: `CHI_SNP_OPCODE_W];
    // FwdNID/FwdTxnID carry the forward target in Fwd snoops and DVM
    // payload (Num, Range, VMIDExt) in SnpDVMOp; elsewhere they are zero.
    wire uses_fwd = (opcode == `CHI_SNP_SHARED_FWD) ||
                    (opcode == `CHI_SNP_UNIQUE_FWD) ||
                    (opcode == `CHI_SNP_DVM_OP);
    wire fwd_bad = !uses_fwd &&
                   ((|base[FWD_NID_LSB +: NODE_ID_W]) ||
                    (|base[FWD_TXN_LSB +: `CHI_FLIT_TXN_W]));
    wire [B_W-1:0] added = boundary_flit >> C_W;

    assign unsupported_attr =
        fwd_bad || (|base[PAS_LSB +: 3]) || base[TRACE_LSB] || (|added);

    always @(*) begin
        compact_flit = base;
        compact_flit[PAS_LSB +: 3] = 3'b000;
        compact_flit[TRACE_LSB] = 1'b0;
        if (fwd_bad) begin
            compact_flit[FWD_NID_LSB +: NODE_ID_W] = {NODE_ID_W{1'b0}};
            compact_flit[FWD_TXN_LSB +: `CHI_FLIT_TXN_W] =
                {`CHI_FLIT_TXN_W{1'b0}};
        end
    end
endmodule

module chi_dat_compact_to_boundary #(
    parameter integer DATA_WIDTH = `CHI_DEFAULT_DAT_DATA_W,
    parameter integer NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter integer RSVDC_W    = 0,
    parameter integer POISON     = 0
)(
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] compact_flit,
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)+RSVDC_W+
                ((POISON != 0) ? DATA_WIDTH/64 : 0)-1:0] boundary_flit
);
    localparam integer POISON_W = (POISON != 0) ? DATA_WIDTH/64 : 0;
    localparam integer C_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W);
    localparam integer B_W = C_W + RSVDC_W + POISON_W;
    // RSVDC sits where BE starts in the fabric flit.
    localparam integer BE_LSB = `CHI_DAT_BE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer UPPER_W = C_W - BE_LSB;

    `CHI_FLIT_PARAM_CHECK(`CHI_DEFAULT_ADDR_W,NODE_ID_W,`CHI_FLIT_TXN_W,`CHI_FLIT_DBID_W,`CHI_FLIT_QOS_W,DATA_WIDTH)
    `CHI_BOUNDARY_RSVDC_CHECK(RSVDC_W)

    always @(*) begin
        boundary_flit = {B_W{1'b0}};
        boundary_flit[BE_LSB-1:0] = compact_flit[BE_LSB-1:0];
        boundary_flit[BE_LSB+RSVDC_W +: UPPER_W] = compact_flit[BE_LSB +: UPPER_W];
    end
endmodule

module chi_dat_boundary_to_compact #(
    parameter integer DATA_WIDTH = `CHI_DEFAULT_DAT_DATA_W,
    parameter integer NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter integer RSVDC_W    = 0,
    parameter integer POISON     = 0
)(
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)+RSVDC_W+
                ((POISON != 0) ? DATA_WIDTH/64 : 0)-1:0] boundary_flit,
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] compact_flit,
    output                                            unsupported_attr
);
    localparam integer POISON_W = (POISON != 0) ? DATA_WIDTH/64 : 0;
    localparam integer C_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W);
    localparam integer B_W = C_W + RSVDC_W + POISON_W;
    localparam integer BE_LSB = `CHI_DAT_BE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer UPPER_W = C_W - BE_LSB;
    localparam DATA_PULL_LSB = `CHI_DAT_DATA_PULL_LSB(DATA_WIDTH,NODE_ID_W);
    localparam TAGOP_LSB     = `CHI_DAT_TAGOP_LSB(DATA_WIDTH,NODE_ID_W);
    localparam TAG_LSB       = `CHI_DAT_TAG_LSB(DATA_WIDTH,NODE_ID_W);
    localparam TU_LSB        = `CHI_DAT_TU_LSB(DATA_WIDTH,NODE_ID_W);
    localparam TRACE_LSB     = `CHI_DAT_TRACE_TAG_LSB(DATA_WIDTH,NODE_ID_W);
    localparam NUM_DAT_LSB   = `CHI_DAT_NUM_DAT_LSB(DATA_WIDTH,NODE_ID_W);
    localparam REPLICATE_LSB = `CHI_DAT_REPLICATE_LSB(DATA_WIDTH,NODE_ID_W);
    // Bits of the boundary flit that are RSVDC or Poison.
    localparam [B_W-1:0] RSVDC_MASK =
        ({B_W{1'b1}} >> (B_W - RSVDC_W)) << BE_LSB;
    localparam [B_W-1:0] POISON_MASK =
        ({B_W{1'b1}} >> (B_W - POISON_W)) << (C_W + RSVDC_W);

    `CHI_FLIT_PARAM_CHECK(`CHI_DEFAULT_ADDR_W,NODE_ID_W,`CHI_FLIT_TXN_W,`CHI_FLIT_DBID_W,`CHI_FLIT_QOS_W,DATA_WIDTH)
    `CHI_BOUNDARY_RSVDC_CHECK(RSVDC_W)

    wire [C_W-1:0] base = {boundary_flit[BE_LSB+RSVDC_W +: UPPER_W],
                           boundary_flit[BE_LSB-1:0]};
    // DataPull (no Stash), memory tagging, trace, multi-request data, and
    // RSVDC or Poison.
    wire base_bad =
        base[DATA_PULL_LSB] || (|base[TAGOP_LSB +: 2]) ||
        (|base[TAG_LSB +: DATA_WIDTH/32]) || (|base[TU_LSB +: DATA_WIDTH/128]) ||
        base[TRACE_LSB] || (|base[NUM_DAT_LSB +: 2]) || base[REPLICATE_LSB];

    assign unsupported_attr = base_bad ||
                              (|(boundary_flit & RSVDC_MASK)) ||
                              (|(boundary_flit & POISON_MASK));

    always @(*) begin
        compact_flit = base;
        compact_flit[DATA_PULL_LSB] = 1'b0;
        compact_flit[TAGOP_LSB +: 2] = 2'b00;
        compact_flit[TAG_LSB +: DATA_WIDTH/32] = {(DATA_WIDTH/32){1'b0}};
        compact_flit[TU_LSB +: DATA_WIDTH/128] = {(DATA_WIDTH/128){1'b0}};
        compact_flit[TRACE_LSB] = 1'b0;
        compact_flit[NUM_DAT_LSB +: 2] = 2'b00;
        compact_flit[REPLICATE_LSB] = 1'b0;
    end
endmodule
