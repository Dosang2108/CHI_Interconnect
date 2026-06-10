`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_hn_i_mn
// Purpose: Management-node wrapper. Forwards incoming DVM REQ/RSP traffic to
//          the MN DVM engine and exposes generated SNP/RSP traffic to fabric.
// -----------------------------------------------------------------------------
module chi_hn_i_mn #(
    parameter NODE_ID        = 0,
    parameter RN_BASE_ID     = 0,
    parameter NUM_RN         = `CHI_DEFAULT_NUM_RN,
    parameter ADDR_WIDTH     = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W      = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W       = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W          = `CHI_DEFAULT_QOS_W,
    parameter DBID_W         = `CHI_DEFAULT_DBID_W,
    parameter TIMEOUT_CYCLES = 1024
)(
    input                    clk,
    input                    rstn,
    input                    dvm_enable,
    input      [15:0]        cfg_drain_cycles,

    input                    rx_req_valid,
    input      [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] rx_req_flit,
    output                   rx_req_ready,
    output                   rx_req_lcrdv,

    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_ready,
    output                   rx_rsp_lcrdv,

    output                   tx_snp_valid,
    output     [`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] tx_snp_flit,
    input                    tx_snp_lcrdv,

    output                   tx_rsp_valid,
    output     [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv
);
    chi_mn_dvm #(
        .NODE_ID(NODE_ID),
        .RN_BASE_ID(RN_BASE_ID),
        .NUM_RN(NUM_RN),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_dvm (
        .clk(clk),
        .rstn(rstn),
        .dvm_enable(dvm_enable),
        .cfg_drain_cycles(cfg_drain_cycles),
        .rx_req_valid(rx_req_valid),
        .rx_req_flit(rx_req_flit),
        .rx_req_ready(rx_req_ready),
        .rx_req_lcrdv(rx_req_lcrdv),
        .rx_rsp_valid(rx_rsp_valid),
        .rx_rsp_flit(rx_rsp_flit),
        .rx_rsp_ready(rx_rsp_ready),
        .rx_rsp_lcrdv(rx_rsp_lcrdv),
        .tx_snp_valid(tx_snp_valid),
        .tx_snp_flit(tx_snp_flit),
        .tx_snp_lcrdv(tx_snp_lcrdv),
        .tx_rsp_valid(tx_rsp_valid),
        .tx_rsp_flit(tx_rsp_flit),
        .tx_rsp_lcrdv(tx_rsp_lcrdv)
    );
endmodule
