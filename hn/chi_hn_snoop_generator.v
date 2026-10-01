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
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter ENABLE_DIRECT_FWD = `CHI_CAP_DIRECT_C2C_FWD
)(
    input                    start_valid,
    input      [ADDR_WIDTH-1:0] addr,
    input      [TXN_ID_W-1:0] txn_id,
    input      [`CHI_REQ_OPCODE_W-1:0] req_opcode,
    input      [2:0]         req_size,
    input      [NODE_ID_W-1:0] hn_node_id,
    input      [NODE_ID_W-1:0] requestor_id,
    input      [QOS_W-1:0]   qos,
    input      [NUM_RN-1:0]  sharer_vec,
    output reg [NUM_RN-1:0]  snp_valid_vec,
    output reg [NUM_RN*`CHI_SNP_W(NODE_ID_W)-1:0] snp_flit_flat
);
    localparam SNP_ADDR_LSB   = `CHI_SNP_ADDR_LSB(NODE_ID_W);
    localparam SNP_OPCODE_LSB = `CHI_SNP_OPCODE_LSB(NODE_ID_W);
    localparam SNP_TXN_LSB    = `CHI_SNP_TXN_LSB(NODE_ID_W);
    localparam SNP_SRC_LSB    = `CHI_SNP_SRC_LSB(NODE_ID_W);
    localparam SNP_QOS_LSB    = `CHI_SNP_QOS_LSB(NODE_ID_W);
    localparam SNP_FWD_NID_LSB =
        `CHI_SNP_FWD_NID_LSB(NODE_ID_W);
    localparam SNP_FWD_TXN_LSB =
        `CHI_SNP_FWD_TXN_LSB(NODE_ID_W);
    localparam SNP_DO_NOT_GO_TO_SD_LSB =
        `CHI_SNP_DO_NOT_GO_TO_SD_LSB(NODE_ID_W);
    localparam SNP_W          = `CHI_SNP_W(NODE_ID_W);

    integer i;
    integer j;
    reg [`CHI_SNP_OPCODE_W-1:0] snp_opcode;
    reg       use_forward_snoop;
    reg       snp_do_not_go_to_sd;
    // Number of RNs this request snoops (sharers other than the requester).
    reg [$clog2(NUM_RN+1)-1:0] target_count;

    always @(*) begin
        target_count = {($clog2(NUM_RN+1)){1'b0}};
        for (j = 0; j < NUM_RN; j = j + 1)
            if (sharer_vec[j] && (requestor_id != j))
                target_count = target_count + 1'b1;
        // A forwarding snoop goes to a single RN-F (B4.8.3.4 for
        // SnpUniqueFwd). With more sharers each gets the plain snoop and the
        // home supplies the data, so the requester never gets two copies.
        use_forward_snoop =
            (ENABLE_DIRECT_FWD != 0) &&
            (req_size == 3'd6) &&
            (target_count == 1) &&
            ((req_opcode == `CHI_REQ_RD_SHARED) ||
             (req_opcode == `CHI_REQ_RD_UNIQUE));

        case (req_opcode)
            `CHI_REQ_RD_SHARED:
                snp_opcode = use_forward_snoop ? `CHI_SNP_SHARED_FWD :
                                                  `CHI_SNP_SHARED;
            `CHI_REQ_RD_UNIQUE:
                snp_opcode = use_forward_snoop ? `CHI_SNP_UNIQUE_FWD :
                                                  `CHI_SNP_UNIQUE;
            // CleanUnique keeps the requester's copy but must collect a
            // dirty copy elsewhere, so it is not SnpMakeInvalid.
            `CHI_REQ_CLN_UNIQUE: snp_opcode = `CHI_SNP_UNIQUE;
            `CHI_REQ_MK_UNIQUE: snp_opcode = `CHI_SNP_INVALID;
            `CHI_REQ_WR_UNIQUE: snp_opcode = `CHI_SNP_INVALID;
            default:            snp_opcode = `CHI_SNP_INVALID;
        endcase
        // B13.10.36: DoNotGoToSD must be 1 in SnpUnique* and SnpMakeInvalid.
        snp_do_not_go_to_sd = (snp_opcode != `CHI_SNP_SHARED) &&
                              (snp_opcode != `CHI_SNP_SHARED_FWD);
    end

    always @(*) begin
        snp_valid_vec = {NUM_RN{1'b0}};
        snp_flit_flat = {NUM_RN*SNP_W{1'b0}};

        for (i = 0; i < NUM_RN; i = i + 1) begin
            if (start_valid && sharer_vec[i] && (requestor_id != i)) begin
                snp_valid_vec[i] = 1'b1;
                // SNP Addr is Addr[43:3].
                snp_flit_flat[i*SNP_W + SNP_ADDR_LSB +: ADDR_WIDTH-3] =
                    addr[ADDR_WIDTH-1:3];
                snp_flit_flat[i*SNP_W + SNP_OPCODE_LSB +: `CHI_SNP_OPCODE_W] = snp_opcode;
                snp_flit_flat[i*SNP_W + SNP_DO_NOT_GO_TO_SD_LSB] = snp_do_not_go_to_sd;
                snp_flit_flat[i*SNP_W + SNP_TXN_LSB +: TXN_ID_W]    = txn_id;
                snp_flit_flat[i*SNP_W + SNP_SRC_LSB +: NODE_ID_W]   = hn_node_id;
                snp_flit_flat[i*SNP_W + SNP_QOS_LSB +: QOS_W]       = qos;
                if (use_forward_snoop) begin
                    snp_flit_flat[i*SNP_W + SNP_FWD_NID_LSB +: NODE_ID_W] =
                        requestor_id;
                    snp_flit_flat[i*SNP_W + SNP_FWD_TXN_LSB +: TXN_ID_W] =
                        txn_id;
                end
            end
        end
    end
endmodule
