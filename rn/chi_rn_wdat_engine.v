`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_rn_wdat_engine
// Purpose: RN-F write-data sender. It streams a cached 64B write line as CHI
//          DAT beats after a DBID is returned by the HN.
// -----------------------------------------------------------------------------
module chi_rn_wdat_engine #(
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter LINE_BYTES = 64
)(
    input                    clk,
    input                    rstn,

    input                    dbid_valid,
    output                   dbid_ready,
    input      [TXN_ID_W-1:0] dbid_txn_id,
    input      [DBID_W-1:0]  dbid_value,
    input      [NODE_ID_W-1:0] dbid_src_id,

    input                    wdata_valid,
    output                   wdata_ready,
    input      [LINE_BYTES*8-1:0] wdata,
    input      [LINE_BYTES-1:0] wstrb,
    input      [NODE_ID_W-1:0] node_id,

    output                   tx_dat_valid,
    input                    tx_dat_ready,
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] tx_dat_flit
);
    localparam BE_W = DATA_WIDTH / 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam LINE_WIDTH = LINE_BYTES * 8;

    localparam DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB;
    localparam DAT_BE_LSB      = `CHI_DAT_BE_LSB;
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DATA_WIDTH);
    localparam DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DATA_WIDTH);
    localparam DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DATA_WIDTH);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DATA_WIDTH,DBID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DATA_WIDTH,DBID_W,TXN_ID_W);
    localparam DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);
    localparam DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);

    reg                  busy_q;
    reg [3:0]            beat_cnt_q;
    reg [LINE_WIDTH-1:0] line_data_q;
    reg [LINE_BYTES-1:0] line_strb_q;
    reg [TXN_ID_W-1:0]   txn_id_q;
    reg [DBID_W-1:0]     dbid_q;
    reg [NODE_ID_W-1:0]  tgt_id_q;
    reg [NODE_ID_W-1:0]  src_id_q;

    wire active = busy_q || (dbid_valid && wdata_valid);
    wire tx_fire = tx_dat_valid && tx_dat_ready;
    wire [3:0] current_beat = busy_q ? beat_cnt_q : 4'd0;
    wire [LINE_WIDTH-1:0] current_line_data = busy_q ? line_data_q : wdata;
    wire [LINE_BYTES-1:0] current_line_strb = busy_q ? line_strb_q : wstrb;
    wire [TXN_ID_W-1:0] current_txn_id = busy_q ? txn_id_q : dbid_txn_id;
    wire [DBID_W-1:0] current_dbid = busy_q ? dbid_q : dbid_value;
    wire [NODE_ID_W-1:0] current_tgt_id = busy_q ? tgt_id_q : dbid_src_id;
    wire [NODE_ID_W-1:0] current_src_id = busy_q ? src_id_q : node_id;

    assign tx_dat_valid = active;
    assign dbid_ready   = !busy_q && tx_dat_ready && wdata_valid;
    assign wdata_ready  = !busy_q && tx_dat_ready && dbid_valid;

    always @(*) begin
        tx_dat_flit = {`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W){1'b0}};
        tx_dat_flit[DAT_RESPERR_LSB +: 2]       = `CHI_RESPERR_OK;
        tx_dat_flit[DAT_BE_LSB +: BE_W]         = current_line_strb[current_beat*BE_W +: BE_W];
        tx_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] = current_line_data[current_beat*DATA_WIDTH +: DATA_WIDTH];
        tx_dat_flit[DAT_DATAID_LSB +: 4]        = current_beat;
        tx_dat_flit[DAT_DBID_LSB +: DBID_W]     = current_dbid;
        tx_dat_flit[DAT_TXN_LSB +: TXN_ID_W]    = current_txn_id;
        tx_dat_flit[DAT_SRC_LSB +: NODE_ID_W]   = current_src_id;
        tx_dat_flit[DAT_TGT_LSB +: NODE_ID_W]   = current_tgt_id;
        tx_dat_flit[DAT_RESP_LSB +: 3]           = 3'd0;
    end

    always @(posedge clk) begin
        if (rstn && tx_fire && !busy_q && (BEATS > 1)) begin
            line_data_q <= wdata;
            line_strb_q <= wstrb;
            txn_id_q    <= dbid_txn_id;
            dbid_q      <= dbid_value;
            tgt_id_q    <= dbid_src_id;
            src_id_q    <= node_id;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_q      <= 1'b0;
            beat_cnt_q  <= 4'd0;
        end else if (tx_fire) begin
            if (!busy_q) begin
                if (BEATS > 1) begin
                    busy_q      <= 1'b1;
                    beat_cnt_q  <= 4'd1;
                end
            end else if (beat_cnt_q == (BEATS - 1)) begin
                busy_q     <= 1'b0;
                beat_cnt_q <= 4'd0;
            end else begin
                beat_cnt_q <= beat_cnt_q + 1'b1;
            end
        end
    end
endmodule
