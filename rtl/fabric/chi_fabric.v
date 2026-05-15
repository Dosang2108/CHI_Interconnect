`include "chi_defs.vh"

module chi_fabric #(
    parameter NUM_RN      = `CHI_DEFAULT_NUM_RN,
    parameter NUM_TGT     = `CHI_DEFAULT_NUM_TGT,
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

    input      [NUM_RN*QOS_W-1:0]  rn_qos_flat,
    input      [NUM_TGT*QOS_W-1:0] tgt_qos_flat,

    input      [NUM_RN-1:0] req_in_valid,
    output     [NUM_RN-1:0] req_in_ready,
    input      [NUM_RN*`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] req_in_flit,
    output     [NUM_RN-1:0] req_in_pop_pulse,
    input      [NUM_RN*NUM_TGT-1:0] req_route_onehot,
    output     [NUM_TGT-1:0] req_out_valid,
    input      [NUM_TGT-1:0] req_out_ready,
    output     [NUM_TGT*`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] req_out_flit,

    input      [NUM_TGT-1:0] rsp_in_valid,
    output     [NUM_TGT-1:0] rsp_in_ready,
    input      [NUM_TGT*`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rsp_in_flit,
    output     [NUM_TGT-1:0] rsp_in_pop_pulse,
    input      [NUM_TGT*NUM_RN-1:0] rsp_route_onehot,
    output     [NUM_RN-1:0] rsp_out_valid,
    input      [NUM_RN-1:0] rsp_out_ready,
    output     [NUM_RN*`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rsp_out_flit,

    input      [NUM_RN-1:0] rsp_rn_in_valid,
    output     [NUM_RN-1:0] rsp_rn_in_ready,
    input      [NUM_RN*`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rsp_rn_in_flit,
    output     [NUM_RN-1:0] rsp_rn_in_pop_pulse,
    input      [NUM_RN*NUM_TGT-1:0] rsp_rn_route_onehot,
    output     [NUM_TGT-1:0] rsp_rn_out_valid,
    input      [NUM_TGT-1:0] rsp_rn_out_ready,
    output     [NUM_TGT*`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rsp_rn_out_flit,

    input      [NUM_TGT-1:0] snp_in_valid,
    output     [NUM_TGT-1:0] snp_in_ready,
    input      [NUM_TGT*`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] snp_in_flit,
    output     [NUM_TGT-1:0] snp_in_pop_pulse,
    input      [NUM_TGT*NUM_RN-1:0] snp_route_onehot,
    output     [NUM_RN-1:0] snp_out_valid,
    input      [NUM_RN-1:0] snp_out_ready,
    output     [NUM_RN*`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] snp_out_flit,

    input      [NUM_RN-1:0] dat_rn_in_valid,
    output     [NUM_RN-1:0] dat_rn_in_ready,
    input      [NUM_RN*`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] dat_rn_in_flit,
    output     [NUM_RN-1:0] dat_rn_in_pop_pulse,
    input      [NUM_RN*NUM_TGT-1:0] dat_rn_route_onehot,
    output     [NUM_TGT-1:0] dat_rn_out_valid,
    input      [NUM_TGT-1:0] dat_rn_out_ready,
    output     [NUM_TGT*`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] dat_rn_out_flit,

    input      [NUM_TGT-1:0] dat_tgt_in_valid,
    output     [NUM_TGT-1:0] dat_tgt_in_ready,
    input      [NUM_TGT*`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] dat_tgt_in_flit,
    output     [NUM_TGT-1:0] dat_tgt_in_pop_pulse,
    input      [NUM_TGT*NUM_RN-1:0] dat_tgt_route_onehot,
    output     [NUM_RN-1:0] dat_tgt_out_valid,
    input      [NUM_RN-1:0] dat_tgt_out_ready,
    output     [NUM_RN*`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] dat_tgt_out_flit
);
    localparam REQ_W = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam SNP_W = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);

    chi_channel_slice #(
        .NUM_IN(NUM_RN),
        .NUM_OUT(NUM_TGT),
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
        .qos_flat(rn_qos_flat),
        .out_valid(req_out_valid),
        .out_ready(req_out_ready),
        .out_flit(req_out_flit)
    );

    chi_channel_slice #(
        .NUM_IN(NUM_TGT),
        .NUM_OUT(NUM_RN),
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
        .qos_flat(tgt_qos_flat),
        .out_valid(rsp_out_valid),
        .out_ready(rsp_out_ready),
        .out_flit(rsp_out_flit)
    );

    chi_channel_slice #(
        .NUM_IN(NUM_RN),
        .NUM_OUT(NUM_TGT),
        .FLIT_W(RSP_W),
        .QOS_W(QOS_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_rsp_rn_to_tgt_slice (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(rsp_rn_in_valid),
        .in_ready(rsp_rn_in_ready),
        .in_flit(rsp_rn_in_flit),
        .in_pop_pulse(rsp_rn_in_pop_pulse),
        .route_onehot_flat(rsp_rn_route_onehot),
        .qos_flat(rn_qos_flat),
        .out_valid(rsp_rn_out_valid),
        .out_ready(rsp_rn_out_ready),
        .out_flit(rsp_rn_out_flit)
    );

    chi_channel_slice #(
        .NUM_IN(NUM_TGT),
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
        .qos_flat(tgt_qos_flat),
        .out_valid(snp_out_valid),
        .out_ready(snp_out_ready),
        .out_flit(snp_out_flit)
    );

    chi_channel_slice #(
        .NUM_IN(NUM_RN),
        .NUM_OUT(NUM_TGT),
        .FLIT_W(DAT_W),
        .QOS_W(QOS_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_dat_rn_to_tgt_slice (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(dat_rn_in_valid),
        .in_ready(dat_rn_in_ready),
        .in_flit(dat_rn_in_flit),
        .in_pop_pulse(dat_rn_in_pop_pulse),
        .route_onehot_flat(dat_rn_route_onehot),
        .qos_flat(rn_qos_flat),
        .out_valid(dat_rn_out_valid),
        .out_ready(dat_rn_out_ready),
        .out_flit(dat_rn_out_flit)
    );

    chi_channel_slice #(
        .NUM_IN(NUM_TGT),
        .NUM_OUT(NUM_RN),
        .FLIT_W(DAT_W),
        .QOS_W(QOS_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_dat_tgt_to_rn_slice (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(dat_tgt_in_valid),
        .in_ready(dat_tgt_in_ready),
        .in_flit(dat_tgt_in_flit),
        .in_pop_pulse(dat_tgt_in_pop_pulse),
        .route_onehot_flat(dat_tgt_route_onehot),
        .qos_flat(tgt_qos_flat),
        .out_valid(dat_tgt_out_valid),
        .out_ready(dat_tgt_out_ready),
        .out_flit(dat_tgt_out_flit)
    );
endmodule
