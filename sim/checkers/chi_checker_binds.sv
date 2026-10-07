`timescale 1ns/1ps

// Simulation-only bind layer. run_tb_chi_xsim.ps1 elaborates this module as a
// second top next to the testbench, so every chi_top instance in any
// testbench carries the protocol checker and the link credit checkers. The port connections are
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
        .snp_flit(snp_rn_out_flit),
        .rn_in_domain(rn_syscoreq)
    );

    // Link-layer L-Credit checker (3.0), one per channel and direction at the
    // node<->fabric link boundary. Every link starts with no credit.
    // Node->fabric (3.1a): the fabric input FIFO grants FABRIC_FIFO_DEPTH.
    // Fabric->node (3.1b): the node receive buffer grants INIT_CRD.
    // FLITV includes the LCrdReturn flits (3.3), which the protocol checker
    // above never sees. Each port is checked against the LINKACTIVEREQ/ACK
    // pair of its node's transmit link (node_tx_*) or receive link
    // (node_rx_*).
    bind chi_top chi_link_credit_checker #(
        .N(NUM_REQ_SRC), .INIT_CREDIT(0), .MAX_CREDIT(FABRIC_FIFO_DEPTH), .IN_SPEC_ALL(1), .LINK("REQ node->fabric")
    ) u_link_chk_req_in (.clk(clk_int), .rstn(rstn), .flitv(req_src_flitv), .flitpend(req_src_flitpend), .lcrdv(req_src_lcrdv),
                         .linkactivereq(node_tx_lareq[NUM_RN+NUM_HN-1:0]), .linkactiveack(node_tx_laack[NUM_RN+NUM_HN-1:0]));
    bind chi_top chi_link_credit_checker #(
        .N(NUM_RN+NUM_HN+NUM_SN+NUM_MN), .INIT_CREDIT(0), .MAX_CREDIT(FABRIC_FIFO_DEPTH), .IN_SPEC_ALL(1), .LINK("RSP node->fabric")
    ) u_link_chk_rsp_in (.clk(clk_int), .rstn(rstn), .flitv(rsp_node_in_flitv), .flitpend(rsp_node_in_flitpend), .lcrdv(rsp_node_in_lcrdv),
                         .linkactivereq(node_tx_lareq), .linkactiveack(node_tx_laack));
    bind chi_top chi_link_credit_checker #(
        .N(NUM_RN+NUM_HN+NUM_SN+NUM_MN), .INIT_CREDIT(0), .MAX_CREDIT(FABRIC_FIFO_DEPTH), .IN_SPEC_ALL(1), .LINK("DAT node->fabric")
    ) u_link_chk_dat_in (.clk(clk_int), .rstn(rstn), .flitv(dat_node_in_flitv), .flitpend(dat_node_in_flitpend), .lcrdv(dat_node_in_lcrdv),
                         .linkactivereq(node_tx_lareq), .linkactiveack(node_tx_laack));
    bind chi_top chi_link_credit_checker #(
        .N(NUM_HN+NUM_MN), .INIT_CREDIT(0), .MAX_CREDIT(FABRIC_FIFO_DEPTH), .IN_SPEC_ALL(1), .LINK("SNP node->fabric")
    ) u_link_chk_snp_in (.clk(clk_int), .rstn(rstn), .flitv(snp_src_flitv), .flitpend(snp_src_flitpend), .lcrdv(snp_src_lcrdv),
                         .linkactivereq(snp_src_lareq), .linkactiveack(snp_src_laack));
    bind chi_top chi_link_credit_checker #(
        .N(NUM_HN+NUM_SN+NUM_MN), .INIT_CREDIT(0), .MAX_CREDIT(INIT_CRD), .IN_SPEC_ALL(1), .LINK("REQ fabric->node")
    ) u_link_chk_req_out (.clk(clk_int), .rstn(rstn), .flitv(req_tgt_flitv), .flitpend(req_tgt_flitpend), .lcrdv(req_tgt_lcrdv),
                          .linkactivereq(node_rx_lareq[NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:NUM_RN]),
                          .linkactiveack(node_rx_laack[NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:NUM_RN]));
    bind chi_top chi_link_credit_checker #(
        .N(NUM_RN+NUM_HN+NUM_SN+NUM_MN), .INIT_CREDIT(0), .MAX_CREDIT(INIT_CRD), .IN_SPEC_ALL(1), .LINK("RSP fabric->node")
    ) u_link_chk_rsp_out (.clk(clk_int), .rstn(rstn), .flitv(rsp_node_out_flitv), .flitpend(rsp_node_out_flitpend), .lcrdv(rsp_node_out_lcrdv),
                          .linkactivereq(node_rx_lareq), .linkactiveack(node_rx_laack));
    bind chi_top chi_link_credit_checker #(
        .N(NUM_RN+NUM_HN+NUM_SN+NUM_MN), .INIT_CREDIT(0), .MAX_CREDIT(INIT_CRD), .IN_SPEC_ALL(1), .LINK("DAT fabric->node")
    ) u_link_chk_dat_out (.clk(clk_int), .rstn(rstn), .flitv(dat_node_out_flitv), .flitpend(dat_node_out_flitpend), .lcrdv(dat_node_out_lcrdv),
                          .linkactivereq(node_rx_lareq), .linkactiveack(node_rx_laack));
    bind chi_top chi_link_credit_checker #(
        .N(NUM_RN), .INIT_CREDIT(0), .MAX_CREDIT(INIT_CRD), .IN_SPEC_ALL(1), .LINK("SNP fabric->node")
    ) u_link_chk_snp_out (.clk(clk_int), .rstn(rstn), .flitv(snp_rn_out_flitv), .flitpend(snp_rn_out_flitpend), .lcrdv(snp_rn_out_lcrdv),
                          .linkactivereq(node_rx_lareq[NUM_RN-1:0]), .linkactiveack(node_rx_laack[NUM_RN-1:0]));

    // Protocol activity and system coherency (3.4): TX/RXSACTIVE of every
    // node and the SYSCOREQ/SYSCOACK pair of every RN. The flit taps are
    // protocol flits only: the *_valid of a node output and the fabric
    // handoff to a node, neither of which carries LCrdReturn flits.
    bind chi_top chi_sysco_checker #(
        .NUM_RN(NUM_RN), .NUM_HN(NUM_HN), .NUM_SN(NUM_SN), .NUM_MN(NUM_MN)
    ) u_sysco_chk (
        .clk(clk_int), .rstn(rstn),
        .syscoreq(rn_syscoreq), .syscoack(rn_syscoack),
        .txsactive(node_txsactive), .rxsactive(node_rxsactive),
        .req_tx(req_src_valid), .rsp_tx(rsp_node_in_valid),
        .dat_tx(dat_node_in_valid), .snp_tx(snp_src_valid),
        .req_rx(req_tgt_valid & req_tgt_ready),
        .rsp_rx(rsp_node_out_valid & rsp_node_out_ready),
        .dat_rx(dat_node_out_valid & dat_node_out_ready),
        .snp_rx(snp_rn_out_valid & snp_rn_out_ready)
    );
endmodule
