`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_sn_axi_bridge
// Purpose: Bridges one SN-F CHI request/data port to a single AXI memory port.
// -----------------------------------------------------------------------------
module chi_sn_axi_bridge #(
    parameter NODE_ID    = 0,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W
)(
    input                    clk,
    input                    rstn,

    input                    req_valid,
    output                   req_ready,
    input      [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] req_flit,

    input                    wdat_valid,
    output                   wdat_ready,
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] wdat_flit,

    output                   rsp_valid,
    input                    rsp_ready,
    output reg [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rsp_flit,

    output                   rdat_valid,
    input                    rdat_ready,
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] rdat_flit,

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
    `include "../common/chi_clog2.vh"
localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB;
    localparam REQ_SIZE_LSB   = `CHI_REQ_SIZE_LSB(ADDR_WIDTH);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(ADDR_WIDTH);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(ADDR_WIDTH);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(ADDR_WIDTH,TXN_ID_W);
    localparam REQ_TGT_LSB    = `CHI_REQ_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam REQ_QOS_LSB    = `CHI_REQ_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);

    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB;
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB;
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB;
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(DBID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(DBID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(DBID_W,TXN_ID_W,NODE_ID_W);

    localparam BE_W = DATA_WIDTH / 8;
    localparam LINE_BYTES = 64;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam [7:0] AXI_BURST_LEN = BEATS - 1;
    localparam [2:0] AXI_SIZE = `CHI_CLOG2(BE_W);

    localparam DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB;
    localparam DAT_BE_LSB      = `CHI_DAT_BE_LSB;
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DATA_WIDTH);
    localparam DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DATA_WIDTH);
    localparam DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DATA_WIDTH);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DATA_WIDTH,DBID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DATA_WIDTH,DBID_W,TXN_ID_W);
    localparam DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);
    localparam DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);

    wire [ADDR_WIDTH-1:0] req_addr   = req_flit[REQ_ADDR_LSB +: ADDR_WIDTH];
    wire [5:0]            req_opcode = req_flit[REQ_OPCODE_LSB +: 6];
    wire [TXN_ID_W-1:0]   req_txn_id = req_flit[REQ_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0]  req_src_id = req_flit[REQ_SRC_LSB +: NODE_ID_W];
    wire [QOS_W-1:0]      req_qos    = req_flit[REQ_QOS_LSB +: QOS_W];

    wire is_read_req  = (req_opcode == `CHI_REQ_RD_NO_SNP);
    wire is_write_req = (req_opcode == `CHI_REQ_WR_NO_SNP);
    wire [3:0] wdat_data_id = wdat_flit[DAT_DATAID_LSB +: 4];
    wire wdat_last = (wdat_data_id == (BEATS - 1));

    reg                  read_active_q;
    reg [3:0]            read_beat_q;
    reg [TXN_ID_W-1:0]   read_txn_id_q;
    reg [NODE_ID_W-1:0]  read_src_id_q;

    reg                  write_active_q;
    reg                  write_aw_done_q;
    reg                  write_resp_pending_q;
    reg [ADDR_WIDTH-1:0] write_addr_q;
    reg [TXN_ID_W-1:0]   write_txn_id_q;
    reg [NODE_ID_W-1:0]  write_src_id_q;
    reg [QOS_W-1:0]      write_qos_q;

    wire read_start_fire = req_valid && is_read_req && !read_active_q && axi_arready;
    wire write_req_fire = req_valid && is_write_req && req_ready;
    wire write_aw_fire = axi_awvalid && axi_awready;
    wire write_beat_fire = axi_wvalid && axi_wready;
    wire read_beat_fire = read_active_q && axi_rvalid && rdat_ready;
    wire rsp_fire = rsp_valid && rsp_ready;

    assign axi_arvalid = req_valid && is_read_req && !read_active_q;
    assign axi_araddr  = req_addr;
    assign axi_arsize  = AXI_SIZE;
    assign axi_arlen   = AXI_BURST_LEN;
    assign axi_arburst = 2'b01;
    assign axi_rready  = read_active_q && rdat_ready;

    assign axi_awvalid = write_active_q && !write_aw_done_q;
    assign axi_awaddr  = write_addr_q;
    assign axi_awsize  = AXI_SIZE;
    assign axi_awlen   = AXI_BURST_LEN;
    assign axi_awburst = 2'b01;
    assign axi_wvalid  = write_active_q && write_aw_done_q && wdat_valid;
    assign axi_wdata   = wdat_flit[DAT_DATA_LSB +: DATA_WIDTH];
    assign axi_wstrb   = wdat_flit[DAT_BE_LSB +: BE_W];
    assign axi_wlast   = wdat_last;
    assign axi_bready  = write_resp_pending_q && rsp_ready;

    assign req_ready  = (is_read_req && !read_active_q && axi_arready) ||
                        (is_write_req && !write_active_q && !write_resp_pending_q);
    assign wdat_ready = write_active_q && write_aw_done_q && axi_wready;

    assign rdat_valid = read_active_q && axi_rvalid;
    assign rsp_valid  = write_resp_pending_q && axi_bvalid;

    always @(*) begin
        rdat_flit = {`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W){1'b0}};
        rdat_flit[DAT_RESPERR_LSB +: 2]       = axi_rresp;
        rdat_flit[DAT_BE_LSB +: BE_W]         = {BE_W{1'b1}};
        rdat_flit[DAT_DATA_LSB +: DATA_WIDTH] = axi_rdata;
        rdat_flit[DAT_DATAID_LSB +: 4]        = read_beat_q;
        rdat_flit[DAT_DBID_LSB +: DBID_W]     = {DBID_W{1'b0}};
        rdat_flit[DAT_TXN_LSB +: TXN_ID_W]    = read_txn_id_q;
        rdat_flit[DAT_SRC_LSB +: NODE_ID_W]   = NODE_ID;
        rdat_flit[DAT_TGT_LSB +: NODE_ID_W]   = read_src_id_q;
        rdat_flit[DAT_RESP_LSB +: 3]           = 3'd0;
    end

    always @(*) begin
        rsp_flit = {`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W){1'b0}};
        rsp_flit[RSP_RESP_LSB +: 3]       = 3'd0;
        rsp_flit[RSP_RESPERR_LSB +: 2]    = axi_bresp;
        rsp_flit[RSP_DBID_LSB +: DBID_W]  = {DBID_W{1'b0}};
        rsp_flit[RSP_OPCODE_LSB +: 4]     = `CHI_RSP_COMP;
        rsp_flit[RSP_TXN_LSB +: TXN_ID_W] = write_txn_id_q;
        rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = write_src_id_q;
        rsp_flit[RSP_QOS_LSB +: QOS_W]     = write_qos_q;
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (read_start_fire) begin
                read_txn_id_q <= req_txn_id;
                read_src_id_q <= req_src_id;
            end

            if (write_req_fire) begin
                write_addr_q   <= req_addr;
                write_txn_id_q <= req_txn_id;
                write_src_id_q <= req_src_id;
                write_qos_q    <= req_qos;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            read_active_q        <= 1'b0;
            read_beat_q          <= 4'd0;
            write_active_q       <= 1'b0;
            write_aw_done_q      <= 1'b0;
            write_resp_pending_q <= 1'b0;
        end else begin
            if (read_start_fire) begin
                read_active_q <= 1'b1;
                read_beat_q   <= 4'd0;
            end else if (read_beat_fire) begin
                if (read_beat_q == (BEATS - 1)) begin
                    read_active_q <= 1'b0;
                    read_beat_q   <= 4'd0;
                end else begin
                    read_beat_q <= read_beat_q + 1'b1;
                end
            end

            if (write_req_fire) begin
                write_active_q <= 1'b1;
                write_aw_done_q <= 1'b0;
            end else if (write_aw_fire) begin
                write_aw_done_q <= 1'b1;
            end

            if (write_beat_fire) begin
                if (wdat_last) begin
                    write_active_q       <= 1'b0;
                    write_aw_done_q      <= 1'b0;
                    write_resp_pending_q <= 1'b1;
                end
            end

            if (rsp_fire)
                write_resp_pending_q <= 1'b0;
        end
    end
endmodule
