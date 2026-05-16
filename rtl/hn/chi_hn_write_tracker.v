`include "../common/chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_hn_write_tracker
// Purpose: Tracks outstanding HN-F write requests until SN-F completion returns.
// -----------------------------------------------------------------------------
module chi_hn_write_tracker #(
    parameter NODE_ID_W = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W  = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W     = `CHI_DEFAULT_QOS_W,
    parameter DEPTH     = 8
)(
    input                   clk,
    input                   rstn,
    input                   clear,

    input                   alloc_valid,
    output                  alloc_ready,
    input      [TXN_ID_W-1:0] alloc_txn_id,
    input      [NODE_ID_W-1:0] alloc_src_id,
    input      [QOS_W-1:0]  alloc_qos,

    input                   comp_valid,
    output                  comp_ready,
    input      [TXN_ID_W-1:0] comp_txn_id,
    output                  comp_match,

    output                  rsp_valid,
    input                   rsp_ready,
    output     [TXN_ID_W-1:0] rsp_txn_id,
    output     [NODE_ID_W-1:0] rsp_tgt_id,
    output     [QOS_W-1:0]  rsp_qos,
    output     [15:0]       used_count
);
    `include "../common/chi_clog2.vh"

    localparam IDX_W = (DEPTH <= 2) ? 1 : `CHI_CLOG2(DEPTH);

    reg                  valid_q [0:DEPTH-1];
    reg [TXN_ID_W-1:0]   txn_id_q [0:DEPTH-1];
    reg [NODE_ID_W-1:0]  src_id_q [0:DEPTH-1];
    reg [QOS_W-1:0]      qos_q [0:DEPTH-1];

    reg                  rsp_valid_q;
    reg [TXN_ID_W-1:0]   rsp_txn_id_q;
    reg [NODE_ID_W-1:0]  rsp_tgt_id_q;
    reg [QOS_W-1:0]      rsp_qos_q;

    reg                  free_valid_r;
    reg [IDX_W-1:0]      free_idx_r;
    reg                  match_valid_r;
    reg [IDX_W-1:0]      match_idx_r;
    reg [15:0]           used_count_r;
    integer              scan_i;
    integer              reset_i;

    wire alloc_fire = alloc_valid && alloc_ready;
    wire comp_fire = comp_valid && comp_ready;
    wire rsp_fire = rsp_valid && rsp_ready;

    assign alloc_ready = free_valid_r;
    assign comp_match = match_valid_r;
    assign comp_ready = match_valid_r && (!rsp_valid_q || rsp_ready);
    assign rsp_valid = rsp_valid_q;
    assign rsp_txn_id = rsp_txn_id_q;
    assign rsp_tgt_id = rsp_tgt_id_q;
    assign rsp_qos = rsp_qos_q;
    assign used_count = used_count_r;

    always @(*) begin
        free_valid_r = 1'b0;
        free_idx_r = {IDX_W{1'b0}};
        match_valid_r = 1'b0;
        match_idx_r = {IDX_W{1'b0}};
        used_count_r = 16'd0;

        for (scan_i = 0; scan_i < DEPTH; scan_i = scan_i + 1) begin
            if (valid_q[scan_i]) begin
                used_count_r = used_count_r + 1'b1;
                if (!match_valid_r && (txn_id_q[scan_i] == comp_txn_id)) begin
                    match_valid_r = 1'b1;
                    match_idx_r = scan_i;
                end
            end else if (!free_valid_r) begin
                free_valid_r = 1'b1;
                free_idx_r = scan_i;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rsp_valid_q <= 1'b0;
            rsp_txn_id_q <= {TXN_ID_W{1'b0}};
            rsp_tgt_id_q <= {NODE_ID_W{1'b0}};
            rsp_qos_q <= {QOS_W{1'b0}};
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1) begin
                valid_q[reset_i] <= 1'b0;
                txn_id_q[reset_i] <= {TXN_ID_W{1'b0}};
                src_id_q[reset_i] <= {NODE_ID_W{1'b0}};
                qos_q[reset_i] <= {QOS_W{1'b0}};
            end
        end else if (clear) begin
            rsp_valid_q <= 1'b0;
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1) begin
                valid_q[reset_i] <= 1'b0;
            end
        end else begin
            if (rsp_fire && !comp_fire)
                rsp_valid_q <= 1'b0;

            if (comp_fire) begin
                valid_q[match_idx_r] <= 1'b0;
                rsp_valid_q <= 1'b1;
                rsp_txn_id_q <= txn_id_q[match_idx_r];
                rsp_tgt_id_q <= src_id_q[match_idx_r];
                rsp_qos_q <= qos_q[match_idx_r];
            end

            if (alloc_fire) begin
                valid_q[free_idx_r] <= 1'b1;
                txn_id_q[free_idx_r] <= alloc_txn_id;
                src_id_q[free_idx_r] <= alloc_src_id;
                qos_q[free_idx_r] <= alloc_qos;
            end
        end
    end
endmodule
