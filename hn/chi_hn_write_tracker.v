// -----------------------------------------------------------------------------
// Module: chi_hn_write_tracker
// Purpose: Tracks outstanding HN-F writes. Allocates per-slot DBID and
//          HN-local memory TxnID, matches RN WDAT by DBID/RN/TxnID, matches
//          SN completion by memory TxnID/SN source, and restores the original
//          RN response context.
//
// This helper is kept in chi_hn_f.v so Vivado projects that already include
// chi_hn_f.v do not need an additional source-file update to elaborate HN-F.
// -----------------------------------------------------------------------------
module chi_hn_write_tracker #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W  = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W     = `CHI_DEFAULT_QOS_W,
    parameter DBID_W    = `CHI_DEFAULT_DBID_W,
    parameter DEPTH     = 8,
    parameter HN_BANK_BITS = 4,
    parameter HN_BANK_ID   = 0
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    alloc_valid,
    output                   alloc_ready,
    input      [TXN_ID_W-1:0] alloc_txn_id,
    input      [NODE_ID_W-1:0] alloc_src_id,
    input      [QOS_W-1:0]   alloc_qos,
    input      [1:0]         alloc_resp_err,
    input      [ADDR_WIDTH-1:0] alloc_addr,
    input      [NODE_ID_W-1:0] alloc_mem_tgt_id,
    output     [DBID_W-1:0]  alloc_dbid,
    output     [TXN_ID_W-1:0] alloc_mem_txn_id,

    input                    comp_valid,
    output                   comp_ready,
    input      [TXN_ID_W-1:0] comp_txn_id,
    input      [NODE_ID_W-1:0] comp_src_id,
    output                   comp_match,

    input      [DBID_W-1:0]  wdat_dbid,
    input      [NODE_ID_W-1:0] wdat_src_id,
    input      [TXN_ID_W-1:0] wdat_txn_id,
    output                   wdat_match,
    output     [TXN_ID_W-1:0] wdat_mem_txn_id,
    output     [NODE_ID_W-1:0] wdat_mem_tgt_id,

    output                   rsp_valid,
    input                    rsp_ready,
    output     [TXN_ID_W-1:0] rsp_txn_id,
    output     [NODE_ID_W-1:0] rsp_tgt_id,
    output     [QOS_W-1:0]   rsp_qos,
    output     [1:0]         rsp_resp_err,
    output     [DEPTH-1:0]   active_valid_vec,
    output     [DEPTH*ADDR_WIDTH-1:0] active_addr_flat,
    output     [15:0]        used_count
);
    localparam IDX_W = (DEPTH <= 2) ? 1 : `CHI_CLOG2(DEPTH);
    localparam SLOT_DBID_W = (DBID_W > HN_BANK_BITS) ?
                             (DBID_W - HN_BANK_BITS) : 1;
    localparam SLOT_REQ_W = (DEPTH <= 1) ? 1 : `CHI_CLOG2(DEPTH + 1);
    localparam [HN_BANK_BITS-1:0] HN_BANK_ID_SIZED = HN_BANK_ID;

    reg                 valid_q [0:DEPTH-1];
    reg [TXN_ID_W-1:0]  txn_id_q [0:DEPTH-1];
    reg [NODE_ID_W-1:0] src_id_q [0:DEPTH-1];
    reg [QOS_W-1:0]     qos_q [0:DEPTH-1];
    reg [1:0]           resp_err_q [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] addr_q [0:DEPTH-1];
    reg [DBID_W-1:0]    dbid_q [0:DEPTH-1];
    reg [TXN_ID_W-1:0]  mem_txn_id_q [0:DEPTH-1];
    reg [NODE_ID_W-1:0] mem_tgt_id_q [0:DEPTH-1];

    reg                 rsp_valid_q;
    reg [TXN_ID_W-1:0]  rsp_txn_id_q;
    reg [NODE_ID_W-1:0] rsp_tgt_id_q;
    reg [QOS_W-1:0]     rsp_qos_q;
    reg [1:0]           rsp_resp_err_q;
    reg [IDX_W-1:0]     rsp_idx_q;

    reg                 free_valid_r;
    reg [IDX_W-1:0]     free_idx_r;
    reg                 match_valid_r;
    reg [IDX_W-1:0]     match_idx_r;
    reg                 wdat_match_r;
    reg [IDX_W-1:0]     wdat_idx_r;
    reg [15:0]          used_count_r;
    integer             scan_i;
    integer             reset_i;
    integer             dup_i;
    integer             dup_j;
    genvar              gi;

    wire [SLOT_DBID_W-1:0] free_idx_dbid = free_idx_r;
    wire [SLOT_DBID_W-1:0] slot_dbid = free_idx_dbid + 1'b1;
    wire [TXN_ID_W-1:0] free_idx_txn = free_idx_r;

    wire alloc_fire = alloc_valid && alloc_ready;
    wire comp_fire = comp_valid && comp_ready;
    wire rsp_fire = rsp_valid && rsp_ready;

    assign alloc_ready = free_valid_r;
    assign alloc_dbid = {HN_BANK_ID_SIZED, slot_dbid};
    assign alloc_mem_txn_id = free_idx_txn + {{(TXN_ID_W-1){1'b0}}, 1'b1};
    assign comp_match = match_valid_r;
    assign comp_ready = match_valid_r && (!rsp_valid_q || rsp_ready);
    assign wdat_match = wdat_match_r;
    assign wdat_mem_txn_id = wdat_match_r ?
                             mem_txn_id_q[wdat_idx_r] : {TXN_ID_W{1'b0}};
    assign wdat_mem_tgt_id = wdat_match_r ?
                             mem_tgt_id_q[wdat_idx_r] : {NODE_ID_W{1'b0}};
    assign rsp_valid = rsp_valid_q;
    assign rsp_txn_id = rsp_txn_id_q;
    assign rsp_tgt_id = rsp_tgt_id_q;
    assign rsp_qos = rsp_qos_q;
    assign rsp_resp_err = rsp_resp_err_q;
    assign used_count = used_count_r;

    generate
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin : gen_active_line
            assign active_valid_vec[gi] = valid_q[gi];
            assign active_addr_flat[gi*ADDR_WIDTH +: ADDR_WIDTH] = addr_q[gi];
        end
    endgenerate

    always @(*) begin
        free_valid_r = 1'b0;
        free_idx_r = {IDX_W{1'b0}};
        match_valid_r = 1'b0;
        match_idx_r = {IDX_W{1'b0}};
        wdat_match_r = 1'b0;
        wdat_idx_r = {IDX_W{1'b0}};
        used_count_r = 16'd0;

        for (scan_i = 0; scan_i < DEPTH; scan_i = scan_i + 1) begin
            if (valid_q[scan_i]) begin
                used_count_r = used_count_r + 1'b1;
                if (!match_valid_r &&
                    (mem_txn_id_q[scan_i] == comp_txn_id) &&
                    (mem_tgt_id_q[scan_i] == comp_src_id)) begin
                    match_valid_r = 1'b1;
                    match_idx_r = scan_i[IDX_W-1:0];
                end

                if (!wdat_match_r &&
                    (dbid_q[scan_i] == wdat_dbid) &&
                    (src_id_q[scan_i] == wdat_src_id) &&
                    (txn_id_q[scan_i] == wdat_txn_id)) begin
                    wdat_match_r = 1'b1;
                    wdat_idx_r = scan_i[IDX_W-1:0];
                end
            end else if (!free_valid_r) begin
                free_valid_r = 1'b1;
                free_idx_r = scan_i[IDX_W-1:0];
            end
        end
    end

    always @(posedge clk) begin
        if (rstn && !clear && alloc_fire) begin
            txn_id_q[free_idx_r] <= alloc_txn_id;
            src_id_q[free_idx_r] <= alloc_src_id;
            qos_q[free_idx_r] <= alloc_qos;
            resp_err_q[free_idx_r] <= alloc_resp_err;
            addr_q[free_idx_r] <= alloc_addr;
            dbid_q[free_idx_r] <= alloc_dbid;
            mem_txn_id_q[free_idx_r] <= alloc_mem_txn_id;
            mem_tgt_id_q[free_idx_r] <= alloc_mem_tgt_id;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rsp_valid_q <= 1'b0;
            rsp_txn_id_q <= {TXN_ID_W{1'b0}};
            rsp_tgt_id_q <= {NODE_ID_W{1'b0}};
            rsp_qos_q <= {QOS_W{1'b0}};
            rsp_resp_err_q <= `CHI_RESPERR_OK;
            rsp_idx_q <= {IDX_W{1'b0}};
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1) begin
                valid_q[reset_i] <= 1'b0;
            end
        end else if (clear) begin
            rsp_valid_q <= 1'b0;
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1)
                valid_q[reset_i] <= 1'b0;
        end else begin
            if (rsp_fire) begin
                valid_q[rsp_idx_q] <= 1'b0;
                if (!comp_fire)
                    rsp_valid_q <= 1'b0;
            end

            if (comp_fire) begin
                rsp_valid_q <= 1'b1;
                rsp_idx_q <= match_idx_r;
                rsp_txn_id_q <= txn_id_q[match_idx_r];
                rsp_tgt_id_q <= src_id_q[match_idx_r];
                rsp_qos_q <= qos_q[match_idx_r];
                rsp_resp_err_q <= resp_err_q[match_idx_r];
            end

            if (alloc_fire) begin
                valid_q[free_idx_r] <= 1'b1;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (HN_BANK_BITS < 1) begin
            $display("[A2 FATAL] HN_BANK_BITS must be >= 1");
            $stop;
        end
        if (DBID_W < (HN_BANK_BITS + SLOT_REQ_W)) begin
            $display("[A2 FATAL] DBID_W=%0d too small for HN_BANK_BITS=%0d and DEPTH=%0d",
                     DBID_W, HN_BANK_BITS, DEPTH);
            $stop;
        end
    end

    always @(posedge clk) begin
        if (rstn) begin
            for (dup_i = 0; dup_i < DEPTH; dup_i = dup_i + 1) begin
                for (dup_j = dup_i + 1; dup_j < DEPTH; dup_j = dup_j + 1) begin
                    if (valid_q[dup_i] && valid_q[dup_j] &&
                        (dbid_q[dup_i] == dbid_q[dup_j])) begin
                        $display("[A2 FATAL] duplicate HN write DBID %0h",
                                 dbid_q[dup_i]);
                        $stop;
                    end
                end
            end
        end
    end
    // synthesis translate_on
endmodule
