`timescale 1ns/1ps

// Simulation-only bind layer. run_tb_chi_xsim.ps1 elaborates this module as a
// second top next to the testbench, so every chi_top instance in any
// testbench carries the protocol checker. The port connections are
// evaluated inside chi_top and tap the fabric outputs, where each flit is
// handed to the node that receives it. The fabric runs on the gated clock.
module chi_checker_binds;
    bind chi_top chi_protocol_checker #(
        .NUM_RN(NUM_RN),
        .NUM_HN(NUM_HN),
        .NUM_SN(NUM_SN),
        .NUM_MN(NUM_MN),
        .DATA_WIDTH(DAT_DATA_W),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W)
    ) u_chi_protocol_checker (
        .clk(clk_int),
        .rstn(rstn),
        .req_valid(req_tgt_valid),
        .req_ready(req_tgt_ready),
        .req_flit(req_tgt_flit),
        .rsp_valid(rsp_node_out_valid),
        .rsp_ready(rsp_node_out_ready),
        .rsp_flit(rsp_node_out_flit),
        .dat_valid(dat_node_out_valid),
        .dat_ready(dat_node_out_ready),
        .dat_flit(dat_node_out_flit),
        .snp_valid(snp_rn_out_valid),
        .snp_ready(snp_rn_out_ready),
        .snp_flit(snp_rn_out_flit)
    );
endmodule
