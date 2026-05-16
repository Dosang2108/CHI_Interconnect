`include "../common/chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_fabric
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_fabric #(
    parameter NUM_RN      = `CHI_DEFAULT_NUM_RN,
    parameter NUM_HN      = `CHI_DEFAULT_NUM_HN,
    parameter NUM_SN      = `CHI_DEFAULT_NUM_SN,
    parameter NUM_MN      = `CHI_DEFAULT_NUM_MN,
    parameter NUM_NODES   = NUM_RN + NUM_HN + NUM_SN + NUM_MN,
    parameter NUM_REQ_SRC = NUM_RN + NUM_HN,
    parameter NUM_REQ_TGT = NUM_HN + NUM_SN + NUM_MN,
    parameter NUM_SNP_SRC = NUM_HN + NUM_MN,
    parameter ADDR_WIDTH  = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH  = `CHI_DEFAULT_DATA_W,
    parameter NODE_ID_W   = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W    = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W       = `CHI_DEFAULT_QOS_W,
    parameter DBID_W      = `CHI_DEFAULT_DBID_W,
    parameter FIFO_DEPTH  = `CHI_DEFAULT_FIFO_DEPTH
)(
    input clk,
    input rstn,
    input clear,

    input      [NUM_REQ_SRC*QOS_W-1:0] req_qos_flat,
    input      [NUM_NODES*QOS_W-1:0]   node_qos_flat,
    input      [NUM_SNP_SRC*QOS_W-1:0] snp_qos_flat,

    input      [NUM_REQ_SRC-1:0] req_in_valid,
    output     [NUM_REQ_SRC-1:0] req_in_ready,
    input      [NUM_REQ_SRC*`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] req_in_flit,
    output     [NUM_REQ_SRC-1:0] req_in_pop_pulse,
    input      [NUM_REQ_SRC*NUM_REQ_TGT-1:0] req_route_onehot,
    output     [NUM_REQ_TGT-1:0] req_out_valid,
    input      [NUM_REQ_TGT-1:0] req_out_ready,
    output     [NUM_REQ_TGT*`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] req_out_flit,

    input      [NUM_NODES-1:0] rsp_in_valid,
    output     [NUM_NODES-1:0] rsp_in_ready,
    input      [NUM_NODES*`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rsp_in_flit,
    output     [NUM_NODES-1:0] rsp_in_pop_pulse,
    input      [NUM_NODES*NUM_NODES-1:0] rsp_route_onehot,
    output     [NUM_NODES-1:0] rsp_out_valid,
    input      [NUM_NODES-1:0] rsp_out_ready,
    output     [NUM_NODES*`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rsp_out_flit,

    input      [NUM_SNP_SRC-1:0] snp_in_valid,
    output     [NUM_SNP_SRC-1:0] snp_in_ready,
    input      [NUM_SNP_SRC*`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] snp_in_flit,
    output     [NUM_SNP_SRC-1:0] snp_in_pop_pulse,
    input      [NUM_SNP_SRC*NUM_RN-1:0] snp_route_onehot,
    output     [NUM_RN-1:0] snp_out_valid,
    input      [NUM_RN-1:0] snp_out_ready,
    output     [NUM_RN*`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] snp_out_flit,

    input      [NUM_NODES-1:0] dat_in_valid,
    output     [NUM_NODES-1:0] dat_in_ready,
    input      [NUM_NODES*`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] dat_in_flit,
    output     [NUM_NODES-1:0] dat_in_pop_pulse,
    input      [NUM_NODES*NUM_NODES-1:0] dat_route_onehot,
    output     [NUM_NODES-1:0] dat_out_valid,
    input      [NUM_NODES-1:0] dat_out_ready,
    output     [NUM_NODES*`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] dat_out_flit
);
    localparam REQ_W = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam SNP_W = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);

    chi_channel_slice #(
        .NUM_IN(NUM_REQ_SRC),
        .NUM_OUT(NUM_REQ_TGT),
        .FLIT_W(REQ_W),
        .QOS_W(QOS_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_req_slice (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(req_in_valid),
        .in_ready(req_in_ready),
        .in_flit(req_in_flit),
        .in_pop_pulse(req_in_pop_pulse),
        .route_onehot_flat(req_route_onehot),
        .qos_flat(req_qos_flat),
        .out_valid(req_out_valid),
        .out_ready(req_out_ready),
        .out_flit(req_out_flit)
    );

    chi_channel_slice #(
        .NUM_IN(NUM_NODES),
        .NUM_OUT(NUM_NODES),
        .FLIT_W(RSP_W),
        .QOS_W(QOS_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_rsp_slice (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(rsp_in_valid),
        .in_ready(rsp_in_ready),
        .in_flit(rsp_in_flit),
        .in_pop_pulse(rsp_in_pop_pulse),
        .route_onehot_flat(rsp_route_onehot),
        .qos_flat(node_qos_flat),
        .out_valid(rsp_out_valid),
        .out_ready(rsp_out_ready),
        .out_flit(rsp_out_flit)
    );

    chi_channel_slice #(
        .NUM_IN(NUM_SNP_SRC),
        .NUM_OUT(NUM_RN),
        .FLIT_W(SNP_W),
        .QOS_W(QOS_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_snp_slice (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(snp_in_valid),
        .in_ready(snp_in_ready),
        .in_flit(snp_in_flit),
        .in_pop_pulse(snp_in_pop_pulse),
        .route_onehot_flat(snp_route_onehot),
        .qos_flat(snp_qos_flat),
        .out_valid(snp_out_valid),
        .out_ready(snp_out_ready),
        .out_flit(snp_out_flit)
    );

    chi_channel_slice #(
        .NUM_IN(NUM_NODES),
        .NUM_OUT(NUM_NODES),
        .FLIT_W(DAT_W),
        .QOS_W(QOS_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_dat_slice (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(dat_in_valid),
        .in_ready(dat_in_ready),
        .in_flit(dat_in_flit),
        .in_pop_pulse(dat_in_pop_pulse),
        .route_onehot_flat(dat_route_onehot),
        .qos_flat(node_qos_flat),
        .out_valid(dat_out_valid),
        .out_ready(dat_out_ready),
        .out_flit(dat_out_flit)
    );
endmodule
