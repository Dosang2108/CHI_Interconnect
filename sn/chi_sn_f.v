`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_sn_f
// Purpose: SN-F endpoint. Buffers incoming CHI REQ/WDAT traffic, bridges it to
//          AXI, and returns CHI RSP/DAT responses through link-layer credits.
// -----------------------------------------------------------------------------
module chi_sn_f #(
    parameter NODE_ID    = 3,
    // AXI data width.
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    // CHI DAT channel data width.
    parameter DAT_DATA_W = `CHI_DEFAULT_DAT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter SINK_FIFO_DEPTH = `CHI_DEFAULT_FIFO_DEPTH
)(
    input                    clk,
    input                    rstn,

    input                    rx_req_valid,
    input      [`CHI_REQ_W(NODE_ID_W)-1:0] rx_req_flit,
    output                   rx_req_ready,
    output                   rx_req_lcrdv,

    input                    rx_dat_valid,
    input      [`CHI_DAT_W(DAT_DATA_W,NODE_ID_W)-1:0] rx_dat_flit,
    output                   rx_dat_ready,
    output                   rx_dat_lcrdv,

    output                   tx_rsp_valid,
    output     [`CHI_RSP_W(NODE_ID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv,

    output                   tx_dat_valid,
    output     [`CHI_DAT_W(DAT_DATA_W,NODE_ID_W)-1:0] tx_dat_flit,
    input                    tx_dat_lcrdv,

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
    input      [1:0]         axi_bresp,
    // A buffered request/data flit, an AXI burst or a TX flit in flight.
    output                   busy
);
    localparam REQ_W = `CHI_REQ_W(NODE_ID_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W);
    localparam DAT_W = `CHI_DAT_W(DAT_DATA_W,NODE_ID_W);

    wire                 reqbuf_valid;
    wire                 reqbuf_in_ready;
    wire                 reqbuf_out_ready;
    wire [REQ_W-1:0]     reqbuf_flit;
    wire                 reqbuf_pop_unused;
    wire [15:0]          reqbuf_used_unused;
    wire                 wbuf_valid;
    wire                 wbuf_in_ready;
    wire [DAT_W-1:0]     wbuf_flit;
    wire                 bridge_req_ready;
    wire                 bridge_wdat_ready;
    wire                 bridge_busy;
    wire                 bridge_rsp_valid;
    wire                 bridge_rsp_ready;
    wire [RSP_W-1:0]     bridge_rsp_flit;
    wire                 bridge_rdat_valid;
    wire                 bridge_rdat_ready;
    wire [DAT_W-1:0]     bridge_rdat_flit;
    wire [3:0]           tx_rsp_credit_unused;
    wire [3:0]           tx_dat_credit_unused;
    wire                 tx_rsp_fire_unused;
    wire                 tx_rsp_return_unused;
    wire                 tx_rsp_stall_unused;
    wire                 tx_dat_fire_unused;
    wire                 tx_dat_return_unused;
    wire                 tx_dat_stall_unused;

    assign rx_req_ready = reqbuf_in_ready;
    assign rx_dat_ready = wbuf_in_ready;
    assign rx_req_lcrdv = rx_req_valid && reqbuf_in_ready;
    assign rx_dat_lcrdv = rx_dat_valid && wbuf_in_ready;
    assign reqbuf_out_ready = bridge_req_ready;

    chi_fifo #(
        .WIDTH(REQ_W),
        .DEPTH(SINK_FIFO_DEPTH)
    ) u_req_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(rx_req_valid),
        .in_ready(reqbuf_in_ready),
        .in_data(rx_req_flit),
        .out_valid(reqbuf_valid),
        .out_ready(reqbuf_out_ready),
        .out_data(reqbuf_flit),
        .pop_pulse(reqbuf_pop_unused),
        .used_count(reqbuf_used_unused)
    );

    chi_sn_wdata_buf #(
        .FLIT_W(DAT_W),
        .DEPTH(SINK_FIFO_DEPTH)
    ) u_wdata_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(rx_dat_valid),
        .in_ready(wbuf_in_ready),
        .in_flit(rx_dat_flit),
        .out_valid(wbuf_valid),
        .out_ready(bridge_wdat_ready),
        .out_flit(wbuf_flit)
    );

    chi_sn_axi_bridge #(
        .NODE_ID(NODE_ID),
        .DATA_WIDTH(DATA_WIDTH),
        .DAT_DATA_W(DAT_DATA_W),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W)
    ) u_axi_bridge (
        .clk(clk),
        .rstn(rstn),
        .busy(bridge_busy),
        .req_valid(reqbuf_valid),
        .req_ready(bridge_req_ready),
        .req_flit(reqbuf_flit),
        .wdat_valid(wbuf_valid),
        .wdat_ready(bridge_wdat_ready),
        .wdat_flit(wbuf_flit),
        .rsp_valid(bridge_rsp_valid),
        .rsp_ready(bridge_rsp_ready),
        .rsp_flit(bridge_rsp_flit),
        .rdat_valid(bridge_rdat_valid),
        .rdat_ready(bridge_rdat_ready),
        .rdat_flit(bridge_rdat_flit),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_araddr(axi_araddr),
        .axi_arsize(axi_arsize),
        .axi_arlen(axi_arlen),
        .axi_arburst(axi_arburst),
        .axi_rvalid(axi_rvalid),
        .axi_rready(axi_rready),
        .axi_rdata(axi_rdata),
        .axi_rresp(axi_rresp),
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_awaddr(axi_awaddr),
        .axi_awsize(axi_awsize),
        .axi_awlen(axi_awlen),
        .axi_awburst(axi_awburst),
        .axi_wvalid(axi_wvalid),
        .axi_wready(axi_wready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wlast(axi_wlast),
        .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_bresp(axi_bresp)
    );

    chi_link_layer #(
        .FLIT_W(RSP_W),
        .INIT_CREDIT(INIT_CRD)
    ) u_tx_rsp_link (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .tx_in_valid(bridge_rsp_valid),
        .tx_in_ready(bridge_rsp_ready),
        .tx_in_flit(bridge_rsp_flit),
        .tx_out_valid(tx_rsp_valid),
        .tx_out_flit(tx_rsp_flit),
        .tx_out_lcrdv(tx_rsp_lcrdv),
        .rx_in_valid(1'b0),
        .rx_in_flit({RSP_W{1'b0}}),
        .rx_in_lcrdv(),
        .rx_out_valid(),
        .rx_out_ready(1'b1),
        .rx_out_flit(),
        .credit_count(tx_rsp_credit_unused),
        .tx_fire_pulse(tx_rsp_fire_unused),
        .tx_credit_return_pulse(tx_rsp_return_unused),
        .tx_credit_stall(tx_rsp_stall_unused)
    );

    chi_link_layer #(
        .FLIT_W(DAT_W),
        .INIT_CREDIT(INIT_CRD)
    ) u_tx_dat_link (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .tx_in_valid(bridge_rdat_valid),
        .tx_in_ready(bridge_rdat_ready),
        .tx_in_flit(bridge_rdat_flit),
        .tx_out_valid(tx_dat_valid),
        .tx_out_flit(tx_dat_flit),
        .tx_out_lcrdv(tx_dat_lcrdv),
        .rx_in_valid(1'b0),
        .rx_in_flit({DAT_W{1'b0}}),
        .rx_in_lcrdv(),
        .rx_out_valid(),
        .rx_out_ready(1'b1),
        .rx_out_flit(),
        .credit_count(tx_dat_credit_unused),
        .tx_fire_pulse(tx_dat_fire_unused),
        .tx_credit_return_pulse(tx_dat_return_unused),
        .tx_credit_stall(tx_dat_stall_unused)
    );

    assign busy = reqbuf_valid || wbuf_valid || bridge_busy ||
                  tx_rsp_valid || tx_dat_valid;
endmodule
