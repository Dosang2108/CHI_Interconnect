`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_sn_axi_bridge
// Purpose: Bridges one SN-F CHI request/data port to a single AXI memory port.
//          The CHI DAT side is DAT_DATA_W wide and the AXI side DATA_WIDTH
//          wide; each DAT beat is DAT_DATA_W/DATA_WIDTH AXI beats.
// -----------------------------------------------------------------------------
module chi_sn_axi_bridge #(
    parameter NODE_ID    = 0,
    // AXI data width.
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    // CHI DAT channel data width, a multiple of DATA_WIDTH.
    parameter DAT_DATA_W = `CHI_DEFAULT_DAT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    // Writes held at once; each has its own DBID and line buffer.
    parameter WR_SLOTS   = `CHI_DEFAULT_SN_WR_SLOTS
)(
    input                    clk,
    input                    rstn,
    output                   busy,

    input                    req_valid,
    output                   req_ready,
    input      [`CHI_REQ_W(NODE_ID_W)-1:0] req_flit,

    input                    wdat_valid,
    output                   wdat_ready,
    input      [`CHI_DAT_W(DAT_DATA_W,NODE_ID_W)-1:0] wdat_flit,

    output                   rsp_valid,
    input                    rsp_ready,
    output reg [`CHI_RSP_W(NODE_ID_W)-1:0] rsp_flit,

    output                   rdat_valid,
    input                    rdat_ready,
    output reg [`CHI_DAT_W(DAT_DATA_W,NODE_ID_W)-1:0] rdat_flit,

    output                   axi_arvalid,
    input                    axi_arready,
    output     [ADDR_WIDTH-1:0] axi_araddr,
    output     [2:0]         axi_arsize,
    output     [7:0]         axi_arlen,
    output     [1:0]         axi_arburst,
    input                    axi_rvalid,
    output                   axi_rready,
    input      [DATA_WIDTH-1:0] axi_rdata,
    input      [1:0]         axi_rresp,

    output                   axi_awvalid,
    input                    axi_awready,
    output     [ADDR_WIDTH-1:0] axi_awaddr,
    output     [2:0]         axi_awsize,
    output     [7:0]         axi_awlen,
    output     [1:0]         axi_awburst,
    output                   axi_wvalid,
    input                    axi_wready,
    output     [DATA_WIDTH-1:0] axi_wdata,
    output     [DATA_WIDTH/8-1:0] axi_wstrb,
    output                   axi_wlast,
    input                    axi_bvalid,
    output                   axi_bready,
    input      [1:0]         axi_bresp
);
    `CHI_FLIT_PARAM_CHECK(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W,QOS_W,DAT_DATA_W)
    `include "../common/chi_clog2.vh"
localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB(NODE_ID_W);
    localparam REQ_SIZE_LSB   = `CHI_REQ_SIZE_LSB(NODE_ID_W);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(NODE_ID_W);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(NODE_ID_W);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(NODE_ID_W);
    localparam REQ_TGT_LSB    = `CHI_REQ_TGT_LSB(NODE_ID_W);
    localparam REQ_QOS_LSB    = `CHI_REQ_QOS_LSB(NODE_ID_W);

    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(NODE_ID_W);

    localparam LINE_BYTES = 64;
    // CHI DAT beats (BE_W bytes each) and AXI beats (AXI_BE_W bytes each).
    localparam BE_W = DAT_DATA_W / 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam DATAID_SHIFT = `CHI_DAT_DATAID_SHIFT(DAT_DATA_W);
    localparam [`CHI_DAT_DATAID_W-1:0] DATAID_ALIGN_MASK = (1 << DATAID_SHIFT) - 1;
    localparam AXI_BE_W = DATA_WIDTH / 8;
    localparam AXI_BEATS = LINE_BYTES / AXI_BE_W;
    localparam AXI_BEAT_W = (AXI_BEATS <= 2) ? 1 : `CHI_CLOG2(AXI_BEATS);
    // AXI beats per DAT beat.
    localparam RATIO = DAT_DATA_W / DATA_WIDTH;
    localparam LANE_W = (RATIO <= 2) ? 1 : `CHI_CLOG2(RATIO);
    localparam [7:0] AXI_BURST_LEN = AXI_BEATS - 1;
    localparam [2:0] AXI_SIZE = `CHI_CLOG2(AXI_BE_W);
    localparam SLOT_W = (WR_SLOTS <= 2) ? 1 : `CHI_CLOG2(WR_SLOTS);

    localparam DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_BE_LSB      = `CHI_DAT_BE_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_OPCODE_LSB  = `CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_QOS_LSB     = `CHI_DAT_QOS_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_HOME_NID_LSB = `CHI_DAT_HOME_NID_LSB(DAT_DATA_W,NODE_ID_W);

    wire [ADDR_WIDTH-1:0] req_addr   = req_flit[REQ_ADDR_LSB +: ADDR_WIDTH];
    wire [`CHI_REQ_OPCODE_W-1:0] req_opcode = req_flit[REQ_OPCODE_LSB +: `CHI_REQ_OPCODE_W];
    wire [TXN_ID_W-1:0]   req_txn_id = req_flit[REQ_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0]  req_src_id = req_flit[REQ_SRC_LSB +: NODE_ID_W];
    wire [QOS_W-1:0]      req_qos    = req_flit[REQ_QOS_LSB +: QOS_W];

    wire is_read_req  = (req_opcode == `CHI_REQ_RD_NO_SNP);
    wire is_write_req = (req_opcode == `CHI_REQ_WR_NO_SNP);
    wire [`CHI_DAT_DATAID_W-1:0] wdat_data_id =
        wdat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W];
    wire [3:0] wdat_beat_idx = wdat_data_id >> DATAID_SHIFT;
    wire wdat_data_id_valid =
        ((wdat_data_id & DATAID_ALIGN_MASK) == {`CHI_DAT_DATAID_W{1'b0}}) &&
        (wdat_beat_idx < BEATS);
    wire wdat_last = wdat_data_id_valid && (wdat_beat_idx == (BEATS - 1));

    // A read burst: AXI beats are gathered RATIO at a time into rd_acc_q,
    // which goes out as one CompData beat (read_beat_q is its DataID).
    reg                  read_active_q;
    reg [3:0]            read_beat_q;
    reg [LANE_W-1:0]     rd_lane_q;
    reg [DAT_DATA_W-1:0] rd_acc_q;
    reg                  rd_acc_valid_q;
    reg [1:0]            rd_resp_q;
    reg [TXN_ID_W-1:0]   read_txn_id_q;
    reg [NODE_ID_W-1:0]  read_src_id_q;
    reg [QOS_W-1:0]      read_qos_q;

    // ------------------------------------------------------------------
    // Write slots (P0-3 / 1.5). Each accepted WriteNoSnp gets a free slot;
    // the slot index is the DBID in its DBIDResp, so its WriteData comes
    // back with TxnID = slot (B2.3.2). Beats go into that slot's line
    // buffer by DataID, whatever order or interleaving they arrive in.
    // A slot whose DAT beats are all in joins the issue queue; the AXI
    // engine sends one slot at a time as AW + AXI_BEATS W beats (WLAST from
    // the engine's own beat counter) and returns Comp with the BRESP.
    // ------------------------------------------------------------------
    reg [WR_SLOTS-1:0]   slot_valid_q;
    reg [WR_SLOTS-1:0]   slot_dbid_pend_q;
    reg [BEATS-1:0]      slot_mask_q [0:WR_SLOTS-1];
    reg [ADDR_WIDTH-1:0] slot_addr_q [0:WR_SLOTS-1];
    reg [TXN_ID_W-1:0]   slot_txn_id_q [0:WR_SLOTS-1];
    reg [NODE_ID_W-1:0]  slot_src_id_q [0:WR_SLOTS-1];
    reg [QOS_W-1:0]      slot_qos_q [0:WR_SLOTS-1];
    // Line buffers, one write port (WriteData) and one read port (AXI W).
    reg [DAT_DATA_W-1:0] wbuf_data [0:WR_SLOTS*BEATS-1];
    reg [BE_W-1:0]       wbuf_be   [0:WR_SLOTS*BEATS-1];

    // Issue queue of full slots, in the order they filled.
    reg [SLOT_W-1:0]     iq_slot_q [0:WR_SLOTS-1];
    reg [SLOT_W-1:0]     iq_head_q;
    reg [SLOT_W-1:0]     iq_tail_q;
    reg [SLOT_W:0]       iq_count_q;

    localparam [1:0] WR_ST_IDLE = 2'd0;
    localparam [1:0] WR_ST_AW   = 2'd1;
    localparam [1:0] WR_ST_W    = 2'd2;
    localparam [1:0] WR_ST_B    = 2'd3;
    reg [1:0]            wr_state_q;
    reg [SLOT_W-1:0]     wr_slot_q;
    reg [AXI_BEAT_W-1:0] wr_beat_q;

    reg                  free_valid_r;
    reg [SLOT_W-1:0]     free_slot_r;
    reg                  dbid_sel_valid_r;
    reg [SLOT_W-1:0]     dbid_sel_r;
    integer              scan_i;

    always @(*) begin
        free_valid_r = 1'b0;
        free_slot_r = {SLOT_W{1'b0}};
        dbid_sel_valid_r = 1'b0;
        dbid_sel_r = {SLOT_W{1'b0}};
        for (scan_i = 0; scan_i < WR_SLOTS; scan_i = scan_i + 1) begin
            if (!slot_valid_q[scan_i] && !free_valid_r) begin
                free_valid_r = 1'b1;
                free_slot_r = scan_i[SLOT_W-1:0];
            end
            if (slot_dbid_pend_q[scan_i] && !dbid_sel_valid_r) begin
                dbid_sel_valid_r = 1'b1;
                dbid_sel_r = scan_i[SLOT_W-1:0];
            end
        end
    end

    // WriteData is steered by its TxnID, which must be a DBID this SN gave.
    wire [TXN_ID_W-1:0]  wdat_txn_id = wdat_flit[DAT_TXN_LSB +: TXN_ID_W];
    wire [SLOT_W-1:0]    wdat_slot = wdat_txn_id[SLOT_W-1:0];
    wire                 wdat_slot_ok =
        (wdat_txn_id < WR_SLOTS) && slot_valid_q[wdat_slot] &&
        wdat_data_id_valid && !slot_mask_q[wdat_slot][wdat_beat_idx];
    wire                 wdat_fire = wdat_valid && wdat_ready;
    wire                 wdat_store = wdat_fire && wdat_slot_ok;
    wire [BEATS-1:0]     wdat_beat_bit = {{(BEATS-1){1'b0}}, 1'b1} << wdat_beat_idx;
    wire                 wdat_slot_full =
        wdat_store &&
        ((slot_mask_q[wdat_slot] | wdat_beat_bit) == {BEATS{1'b1}});

    wire read_start_fire = req_valid && is_read_req && !read_active_q && axi_arready;
    wire write_req_fire = req_valid && is_write_req && req_ready;
    wire read_beat_fire = axi_rvalid && axi_rready;
    wire rdat_fire = rdat_valid && rdat_ready;
    wire rd_lane_last = (rd_lane_q == RATIO - 1);
    wire rsp_fire = rsp_valid && rsp_ready;
    wire dbid_rsp_fire = rsp_fire && dbid_sel_valid_r;
    wire iq_pop = (wr_state_q == WR_ST_IDLE) && (iq_count_q != {(SLOT_W+1){1'b0}});
    wire write_aw_fire = axi_awvalid && axi_awready;
    wire write_beat_fire = axi_wvalid && axi_wready;
    wire write_b_fire = axi_bvalid && axi_bready;
    wire [SLOT_W+AXI_BEAT_W:0] wbuf_wr_idx = wdat_slot * BEATS + wdat_beat_idx;
    // AXI beat wr_beat_q is lane (wr_beat_q % RATIO) of DAT beat
    // (wr_beat_q / RATIO).
    wire [SLOT_W+AXI_BEAT_W:0] wbuf_rd_idx = wr_slot_q * BEATS + wr_beat_q / RATIO;
    wire [AXI_BEAT_W-1:0] wr_lane = wr_beat_q % RATIO;
    wire [DAT_DATA_W-1:0] wbuf_rd_data = wbuf_data[wbuf_rd_idx];
    wire [BE_W-1:0]       wbuf_rd_be = wbuf_be[wbuf_rd_idx];
    wire [`CHI_DAT_QOS_W-1:0] read_qos_dat;
    wire [`CHI_DAT_DATAID_W-1:0] read_data_id = read_beat_q << DATAID_SHIFT;

    generate
        if (QOS_W >= `CHI_DAT_QOS_W) begin : gen_dat_qos_full
            assign read_qos_dat = read_qos_q[`CHI_DAT_QOS_W-1:0];
        end else begin : gen_dat_qos_pad
            assign read_qos_dat =
                {{(`CHI_DAT_QOS_W-QOS_W){1'b0}}, read_qos_q};
        end
    endgenerate

    assign axi_arvalid = req_valid && is_read_req && !read_active_q;
    assign axi_araddr  = req_addr;
    assign axi_arsize  = AXI_SIZE;
    assign axi_arlen   = AXI_BURST_LEN;
    assign axi_arburst = 2'b01;
    // A new beat may land while the gathered one leaves.
    assign axi_rready  = read_active_q && (!rd_acc_valid_q || rdat_ready);

    assign axi_awvalid = (wr_state_q == WR_ST_AW);
    assign axi_awaddr  = slot_addr_q[wr_slot_q];
    assign axi_awsize  = AXI_SIZE;
    assign axi_awlen   = AXI_BURST_LEN;
    assign axi_awburst = 2'b01;
    assign axi_wvalid  = (wr_state_q == WR_ST_W);
    assign axi_wdata   = wbuf_rd_data[wr_lane*DATA_WIDTH +: DATA_WIDTH];
    assign axi_wstrb   = wbuf_rd_be[wr_lane*AXI_BE_W +: AXI_BE_W];
    assign axi_wlast   = (wr_state_q == WR_ST_W) && (wr_beat_q == (AXI_BEATS - 1));
    // DBIDResp goes first so writers are never kept waiting behind a BRESP.
    assign axi_bready  = (wr_state_q == WR_ST_B) && rsp_ready &&
                         !dbid_sel_valid_r;

    assign req_ready  = (is_read_req && !read_active_q && axi_arready) ||
                        (is_write_req && free_valid_r);
    // Every beat has a line-buffer slot waiting for it.
    assign wdat_ready = 1'b1;

    assign rdat_valid = rd_acc_valid_q;
    assign rsp_valid  = dbid_sel_valid_r ||
                        ((wr_state_q == WR_ST_B) && axi_bvalid);

    always @(*) begin
        rdat_flit = {`CHI_DAT_W(DAT_DATA_W,NODE_ID_W){1'b0}};
        rdat_flit[DAT_RESPERR_LSB +: 2]       = rd_resp_q;
        rdat_flit[DAT_BE_LSB +: BE_W]         = {BE_W{1'b1}};
        rdat_flit[DAT_DATA_LSB +: DAT_DATA_W] = rd_acc_q;
        rdat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W] = read_data_id;
        rdat_flit[DAT_DBID_LSB +: DBID_W]     = {DBID_W{1'b0}};
        rdat_flit[DAT_TXN_LSB +: TXN_ID_W]    = read_txn_id_q;
        rdat_flit[DAT_SRC_LSB +: NODE_ID_W]   = NODE_ID;
        rdat_flit[DAT_TGT_LSB +: NODE_ID_W]   = read_src_id_q;
        rdat_flit[DAT_RESP_LSB +: 3]           = 3'd0;
        rdat_flit[DAT_OPCODE_LSB +: 4]         = `CHI_DAT_OPCODE_RD_DATA;
        rdat_flit[DAT_QOS_LSB +: `CHI_DAT_QOS_W] = read_qos_dat;
        rdat_flit[DAT_HOME_NID_LSB +: NODE_ID_W] = read_src_id_q;
    end

    wire [SLOT_W-1:0] rsp_slot = dbid_sel_valid_r ? dbid_sel_r : wr_slot_q;

    always @(*) begin
        rsp_flit = {`CHI_RSP_W(NODE_ID_W){1'b0}};
        rsp_flit[RSP_RESP_LSB +: 3]       = 3'd0;
        rsp_flit[RSP_RESPERR_LSB +: 2]    =
            dbid_sel_valid_r ? `CHI_RESPERR_OK : axi_bresp;
        rsp_flit[RSP_DBID_LSB +: DBID_W]  = rsp_slot;
        rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] =
            dbid_sel_valid_r ? `CHI_RSP_DBID : `CHI_RSP_COMP;
        rsp_flit[RSP_TXN_LSB +: TXN_ID_W] = slot_txn_id_q[rsp_slot];
        rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = slot_src_id_q[rsp_slot];
        rsp_flit[RSP_QOS_LSB +: QOS_W]     = slot_qos_q[rsp_slot];
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (read_start_fire) begin
                read_txn_id_q <= req_txn_id;
                read_src_id_q <= req_src_id;
                read_qos_q    <= req_qos;
            end

            if (write_req_fire) begin
                slot_addr_q[free_slot_r]   <= req_addr;
                slot_txn_id_q[free_slot_r] <= req_txn_id;
                slot_src_id_q[free_slot_r] <= req_src_id;
                slot_qos_q[free_slot_r]    <= req_qos;
            end

            if (read_beat_fire) begin
                rd_acc_q[rd_lane_q*DATA_WIDTH +: DATA_WIDTH] <= axi_rdata;
                // RespErr of the DAT beat: the worst RRESP among its lanes.
                if ((rd_lane_q == {LANE_W{1'b0}}) || (axi_rresp > rd_resp_q))
                    rd_resp_q <= axi_rresp;
            end

            if (wdat_store) begin
                wbuf_data[wbuf_wr_idx] <= wdat_flit[DAT_DATA_LSB +: DAT_DATA_W];
                wbuf_be[wbuf_wr_idx]   <= wdat_flit[DAT_BE_LSB +: BE_W];
            end

            if (wdat_slot_full)
                iq_slot_q[iq_tail_q] <= wdat_slot;
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && wdat_fire && !wdat_slot_ok)
            $display("[%0t] ERROR chi_sn_axi_bridge node %0d: WriteData TxnID %0h beat %0d matches no open write slot (valid=%b)",
                     $time, NODE_ID, wdat_txn_id, wdat_beat_idx, slot_valid_q);
    end
    // synthesis translate_on

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            read_active_q    <= 1'b0;
            read_beat_q      <= 4'd0;
            rd_lane_q        <= {LANE_W{1'b0}};
            rd_acc_valid_q   <= 1'b0;
            slot_valid_q     <= {WR_SLOTS{1'b0}};
            slot_dbid_pend_q <= {WR_SLOTS{1'b0}};
            for (scan_i = 0; scan_i < WR_SLOTS; scan_i = scan_i + 1)
                slot_mask_q[scan_i] <= {BEATS{1'b0}};
            iq_head_q        <= {SLOT_W{1'b0}};
            iq_tail_q        <= {SLOT_W{1'b0}};
            iq_count_q       <= {(SLOT_W+1){1'b0}};
            wr_state_q       <= WR_ST_IDLE;
            wr_slot_q        <= {SLOT_W{1'b0}};
            wr_beat_q        <= {AXI_BEAT_W{1'b0}};
        end else begin
            if (read_start_fire) begin
                read_active_q <= 1'b1;
                read_beat_q   <= 4'd0;
                rd_lane_q     <= {LANE_W{1'b0}};
            end else if (rdat_fire) begin
                if (read_beat_q == (BEATS - 1)) begin
                    read_active_q <= 1'b0;
                    read_beat_q   <= 4'd0;
                end else begin
                    read_beat_q <= read_beat_q + 1'b1;
                end
            end

            if (rdat_fire)
                rd_acc_valid_q <= 1'b0;
            if (read_beat_fire) begin
                if (rd_lane_last) begin
                    rd_lane_q      <= {LANE_W{1'b0}};
                    rd_acc_valid_q <= 1'b1;
                end else begin
                    rd_lane_q <= rd_lane_q + 1'b1;
                end
            end

            if (write_req_fire) begin
                slot_valid_q[free_slot_r]     <= 1'b1;
                slot_dbid_pend_q[free_slot_r] <= 1'b1;
                slot_mask_q[free_slot_r]      <= {BEATS{1'b0}};
            end
            if (dbid_rsp_fire)
                slot_dbid_pend_q[dbid_sel_r] <= 1'b0;
            if (wdat_store)
                slot_mask_q[wdat_slot] <= slot_mask_q[wdat_slot] | wdat_beat_bit;

            if (wdat_slot_full)
                iq_tail_q <= (iq_tail_q == WR_SLOTS - 1) ?
                             {SLOT_W{1'b0}} : iq_tail_q + 1'b1;
            if (iq_pop)
                iq_head_q <= (iq_head_q == WR_SLOTS - 1) ?
                             {SLOT_W{1'b0}} : iq_head_q + 1'b1;
            if (wdat_slot_full && !iq_pop)
                iq_count_q <= iq_count_q + 1'b1;
            else if (!wdat_slot_full && iq_pop)
                iq_count_q <= iq_count_q - 1'b1;

            case (wr_state_q)
                WR_ST_IDLE: begin
                    if (iq_pop) begin
                        wr_slot_q  <= iq_slot_q[iq_head_q];
                        wr_beat_q  <= {AXI_BEAT_W{1'b0}};
                        wr_state_q <= WR_ST_AW;
                    end
                end
                WR_ST_AW: begin
                    if (write_aw_fire)
                        wr_state_q <= WR_ST_W;
                end
                WR_ST_W: begin
                    if (write_beat_fire) begin
                        if (wr_beat_q == (AXI_BEATS - 1)) begin
                            wr_beat_q  <= {AXI_BEAT_W{1'b0}};
                            wr_state_q <= WR_ST_B;
                        end else begin
                            wr_beat_q <= wr_beat_q + 1'b1;
                        end
                    end
                end
                default: begin
                    if (write_b_fire) begin
                        // The write is done: Comp goes out with this BRESP.
                        slot_valid_q[wr_slot_q] <= 1'b0;
                        wr_state_q <= WR_ST_IDLE;
                    end
                end
            endcase
        end
    end

    // An AXI read burst, or a write slot from WriteNoSnp to Comp.
    assign busy = read_active_q || (|slot_valid_q);

    // synthesis translate_off
    initial begin
        if ((DAT_DATA_W < DATA_WIDTH) ||
            ((DAT_DATA_W % DATA_WIDTH) != 0)) begin
            $display("FATAL chi_sn_axi_bridge: DAT_DATA_W=%0d is not a multiple of the AXI width %0d",
                     DAT_DATA_W, DATA_WIDTH);
            $finish;
        end
        if ((WR_SLOTS < 1) || (WR_SLOTS > (1 << DBID_W)) ||
            (WR_SLOTS > (1 << TXN_ID_W))) begin
            $display("FATAL chi_sn_axi_bridge: WR_SLOTS=%0d does not fit DBID_W=%0d / TXN_ID_W=%0d",
                     WR_SLOTS, DBID_W, TXN_ID_W);
            $finish;
        end
    end
    // synthesis translate_on
endmodule
