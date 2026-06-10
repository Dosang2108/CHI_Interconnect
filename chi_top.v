`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_top
// Purpose: Top-level CHI MxN fabric wrapper. Instantiates RN/HN/SN/MN nodes,
//          address-based routing, CSR control, error IRQ, and channel fabrics.
// -----------------------------------------------------------------------------
module chi_top #(
    parameter integer NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter integer NUM_HN     = `CHI_DEFAULT_NUM_HN,
    parameter integer NUM_SN     = `CHI_DEFAULT_NUM_SN,
    parameter integer NUM_MN     = `CHI_DEFAULT_NUM_MN,
    parameter integer DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter integer ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter integer NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter integer TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter integer QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter integer DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter integer INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter integer HN_POS_DEPTH = `CHI_DEFAULT_POS_DEPTH,
    parameter integer HN_SF_ENTRIES = `CHI_DEFAULT_SF_ENTRIES,
    parameter integer HN_LLC_LINES = `CHI_DEFAULT_LLC_LINES,
    parameter integer HN_LLC_WAYS = `CHI_DEFAULT_LLC_WAYS,
    parameter integer HN_WRITE_TRACKER_DEPTH = `CHI_DEFAULT_HN_WRITE_TRACKER_DEPTH,
    parameter integer HN_READ_TRACKER_DEPTH = `CHI_DEFAULT_HN_READ_TRACKER_DEPTH,
    parameter integer HN_SNOOP_TRACKER_DEPTH = `CHI_DEFAULT_HN_SNOOP_TRACKER_DEPTH,
    parameter integer RN_CACHE_LINES = `CHI_DEFAULT_RN_CACHE_LINES,
    parameter integer RN_TXN_TBL_SIZE = `CHI_DEFAULT_RN_TXN_TBL_SIZE,
    parameter integer FABRIC_FIFO_DEPTH = `CHI_DEFAULT_FIFO_DEPTH,
    parameter integer ENABLE_PERF = `CHI_DEFAULT_ENABLE_PERF,
    parameter integer HN_ENABLE_LLC_ECC = `CHI_DEFAULT_ENABLE_LLC_ECC,
    parameter integer FABRIC_OUTPUT_FIFO_DEPTH = `CHI_DEFAULT_OUTPUT_FIFO_DEPTH,
    parameter integer ENABLE_QOS_AGING = `CHI_DEFAULT_ENABLE_QOS_AGING
)(
    input                         clk,
    input                         rstn,

    input                         csr_valid,
    input                         csr_write,
    input      [7:0]              csr_addr,
    input      [63:0]             csr_wdata,
    output                        csr_ready,
    output     [63:0]             csr_rdata,
    output                        chi_irq,

    input      [NUM_RN-1:0]       cpu_req_valid,
    output     [NUM_RN-1:0]       cpu_req_ready,
    input      [NUM_RN*ADDR_WIDTH-1:0] cpu_req_addr,
    input      [NUM_RN*4-1:0]     cpu_req_op,
    input      [NUM_RN*3-1:0]     cpu_req_size,
    input      [NUM_RN*DATA_WIDTH-1:0] cpu_wdata,
    output     [NUM_RN*DATA_WIDTH-1:0] cpu_rdata,
    output     [NUM_RN-1:0]       cpu_resp_valid,

    output     [NUM_SN-1:0]       axi_arvalid,
    input      [NUM_SN-1:0]       axi_arready,
    output     [NUM_SN*ADDR_WIDTH-1:0] axi_araddr,
    output     [NUM_SN*3-1:0]     axi_arsize,
    output     [NUM_SN*8-1:0]     axi_arlen,
    output     [NUM_SN*2-1:0]     axi_arburst,
    input      [NUM_SN-1:0]       axi_rvalid,
    output     [NUM_SN-1:0]       axi_rready,
    input      [NUM_SN*DATA_WIDTH-1:0] axi_rdata,
    input      [NUM_SN*2-1:0]     axi_rresp,

    output     [NUM_SN-1:0]       axi_awvalid,
    input      [NUM_SN-1:0]       axi_awready,
    output     [NUM_SN*ADDR_WIDTH-1:0] axi_awaddr,
    output     [NUM_SN*3-1:0]     axi_awsize,
    output     [NUM_SN*8-1:0]     axi_awlen,
    output     [NUM_SN*2-1:0]     axi_awburst,
    output     [NUM_SN-1:0]       axi_wvalid,
    input      [NUM_SN-1:0]       axi_wready,
    output     [NUM_SN*DATA_WIDTH-1:0] axi_wdata,
    output     [NUM_SN*(DATA_WIDTH/8)-1:0] axi_wstrb,
    output     [NUM_SN-1:0]       axi_wlast,
    input      [NUM_SN-1:0]       axi_bvalid,
    output     [NUM_SN-1:0]       axi_bready,
    input      [NUM_SN*2-1:0]     axi_bresp
);
    localparam NUM_NODES   = NUM_RN + NUM_HN + NUM_SN + NUM_MN;
    localparam NUM_REQ_SRC = NUM_RN + NUM_HN;
    localparam NUM_REQ_TGT = NUM_HN + NUM_SN + NUM_MN;
    localparam NUM_SNP_SRC = NUM_HN + NUM_MN;
    localparam integer RN_BASE_ID = 0;
    localparam integer HN_BASE_ID = NUM_RN;
    localparam integer SN_BASE_ID = NUM_RN + NUM_HN;
    localparam integer MN_BASE_ID = NUM_RN + NUM_HN + NUM_SN;

    localparam REQ_W   = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W   = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam SNP_W   = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam DAT_W   = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);

    localparam REQ_ADDR_LSB = `CHI_REQ_ADDR_LSB;
    localparam REQ_TGT_LSB  = `CHI_REQ_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam REQ_QOS_LSB  = `CHI_REQ_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam RSP_TGT_LSB  = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam SNP_TGT_LSB  = `CHI_SNP_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam SNP_QOS_LSB  = `CHI_SNP_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam DAT_TGT_LSB  = `CHI_DAT_TGT_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);

    wire [NUM_REQ_SRC*QOS_W-1:0] req_qos_flat;
    wire [NUM_NODES*QOS_W-1:0]   node_qos_flat;
    wire [NUM_SNP_SRC*QOS_W-1:0] snp_qos_flat;
    wire                         cfg_region_valid;
    wire [ADDR_WIDTH-1:0]        cfg_hnf_base;
    wire [ADDR_WIDTH-1:0]        cfg_hnf_end;
    wire [ADDR_WIDTH-1:0]        cfg_snf_base;
    wire [ADDR_WIDTH-1:0]        cfg_snf_end;
    wire [ADDR_WIDTH-1:0]        cfg_mn_base;
    wire [ADDR_WIDTH-1:0]        cfg_mn_end;
    wire                         cfg_dvm_enable;
    wire                         cfg_cg_enable;
    wire [15:0]                  cfg_excl_timeout;
    wire [15:0]                  cfg_mn_drain_cycles;
    wire [7:0]                   cfg_qos_age_shift;
    wire [7:0]                   cfg_qos_age_max;
    wire                         csr_bist_init_pulse;
    wire                         chi_cg_en;
    wire                         clk_int;
    wire                         fabric_clear;

    wire [NUM_RN-1:0]        rn_tx_req_valid;
    wire [NUM_RN-1:0]        rn_tx_req_lcrdv;
    wire [NUM_RN*REQ_W-1:0]  rn_tx_req_flit;
    wire [NUM_RN-1:0]        rn_tx_rsp_valid;
    wire [NUM_RN-1:0]        rn_tx_rsp_lcrdv;
    wire [NUM_RN*RSP_W-1:0]  rn_tx_rsp_flit;
    wire [NUM_RN-1:0]        rn_tx_dat_valid;
    wire [NUM_RN-1:0]        rn_tx_dat_lcrdv;
    wire [NUM_RN*DAT_W-1:0]  rn_tx_dat_flit;
    wire [NUM_RN*16*32-1:0]  rn_perf_counts_flat;
    wire [NUM_RN-1:0]        rn_cache_parity_error_event;

    wire [NUM_RN-1:0]        rn_rx_rsp_lcrdv_unused;
    wire [NUM_RN-1:0]        rn_rx_snp_lcrdv_unused;
    wire [NUM_RN-1:0]        rn_rx_dat_lcrdv_unused;
    wire [NUM_RN-1:0]        rn_rx_rsp_ready;
    wire [NUM_RN-1:0]        rn_rx_snp_ready;
    wire [NUM_RN-1:0]        rn_rx_dat_ready;

    wire [NUM_HN-1:0]        hn_rx_req_lcrdv_unused;
    wire [NUM_HN-1:0]        hn_rx_dat_lcrdv_unused;
    wire [NUM_HN-1:0]        hn_rx_rsp_lcrdv_unused;
    wire [NUM_HN-1:0]        hn_rx_req_ready;
    wire [NUM_HN-1:0]        hn_rx_dat_ready;
    wire [NUM_HN-1:0]        hn_rx_rsp_ready;
    wire [NUM_HN-1:0]        hn_tx_rsp_valid;
    wire [NUM_HN-1:0]        hn_tx_rsp_lcrdv;
    wire [NUM_HN*RSP_W-1:0]  hn_tx_rsp_flit;
    wire [NUM_HN-1:0]        hn_tx_snp_valid;
    wire [NUM_HN-1:0]        hn_tx_snp_lcrdv;
    wire [NUM_HN*SNP_W-1:0]  hn_tx_snp_flit;
    wire [NUM_HN-1:0]        hn_tx_dat_valid;
    wire [NUM_HN-1:0]        hn_tx_dat_lcrdv;
    wire [NUM_HN*DAT_W-1:0]  hn_tx_dat_flit;
    wire [NUM_HN-1:0]        hn_mem_req_valid;
    wire [NUM_HN-1:0]        hn_mem_req_ready;
    wire [NUM_HN*REQ_W-1:0]  hn_mem_req_flit;
    wire [NUM_HN-1:0]        hn_mem_dat_valid;
    wire [NUM_HN-1:0]        hn_mem_dat_ready;
    wire [NUM_HN*DAT_W-1:0]  hn_mem_dat_flit;
    wire [NUM_HN*16*32-1:0]  hn_perf_counts_flat;
    wire [NUM_HN-1:0]        hn_ecc_single_event;
    wire [NUM_HN-1:0]        hn_ecc_double_event;
    wire [NUM_HN-1:0]        hn_exclusive_fail_event;

    wire [NUM_SN-1:0]        sn_rx_req_lcrdv_unused;
    wire [NUM_SN-1:0]        sn_rx_dat_lcrdv_unused;
    wire [NUM_SN-1:0]        sn_rx_req_ready;
    wire [NUM_SN-1:0]        sn_rx_dat_ready;
    wire [NUM_SN-1:0]        sn_tx_rsp_valid;
    wire [NUM_SN-1:0]        sn_tx_rsp_lcrdv;
    wire [NUM_SN*RSP_W-1:0]  sn_tx_rsp_flit;
    wire [NUM_SN-1:0]        sn_tx_dat_valid;
    wire [NUM_SN-1:0]        sn_tx_dat_lcrdv;
    wire [NUM_SN*DAT_W-1:0]  sn_tx_dat_flit;

    wire [NUM_MN-1:0]        mn_rx_req_lcrdv_unused;
    wire [NUM_MN-1:0]        mn_rx_rsp_lcrdv_unused;
    wire [NUM_MN-1:0]        mn_rx_req_ready;
    wire [NUM_MN-1:0]        mn_rx_rsp_ready;
    wire [NUM_MN-1:0]        mn_tx_rsp_valid;
    wire [NUM_MN-1:0]        mn_tx_rsp_lcrdv;
    wire [NUM_MN*RSP_W-1:0]  mn_tx_rsp_flit;
    wire [NUM_MN-1:0]        mn_tx_snp_valid;
    wire [NUM_MN-1:0]        mn_tx_snp_lcrdv;
    wire [NUM_MN*SNP_W-1:0]  mn_tx_snp_flit;

    wire [NUM_REQ_SRC-1:0]        req_src_valid;
    wire [NUM_REQ_SRC-1:0]        req_src_ready;
    wire [NUM_REQ_SRC-1:0]        req_src_pop_pulse;
    wire [NUM_REQ_SRC*REQ_W-1:0]  req_src_flit;
    wire [NUM_REQ_SRC*NUM_REQ_TGT-1:0] req_route_onehot;
    wire [NUM_REQ_TGT-1:0]        req_tgt_valid;
    wire [NUM_REQ_TGT-1:0]        req_tgt_ready;
    wire [NUM_REQ_TGT*REQ_W-1:0]  req_tgt_flit;

    wire [NUM_NODES-1:0]        rsp_node_in_valid;
    wire [NUM_NODES-1:0]        rsp_node_in_ready;
    wire [NUM_NODES-1:0]        rsp_node_in_pop_pulse;
    wire [NUM_NODES*RSP_W-1:0]  rsp_node_in_flit;
    wire [NUM_NODES*NUM_NODES-1:0] rsp_route_onehot;
    wire [NUM_NODES-1:0]        rsp_node_out_valid;
    wire [NUM_NODES-1:0]        rsp_node_out_ready;
    wire [NUM_NODES*RSP_W-1:0]  rsp_node_out_flit;

    wire [NUM_NODES-1:0]        dat_node_in_valid;
    wire [NUM_NODES-1:0]        dat_node_in_ready;
    wire [NUM_NODES-1:0]        dat_node_in_pop_pulse;
    wire [NUM_NODES*DAT_W-1:0]  dat_node_in_flit;
    wire [NUM_NODES*NUM_NODES-1:0] dat_route_onehot;
    wire [NUM_NODES-1:0]        dat_node_out_valid;
    wire [NUM_NODES-1:0]        dat_node_out_ready;
    wire [NUM_NODES*DAT_W-1:0]  dat_node_out_flit;

    wire [NUM_SNP_SRC-1:0]   snp_src_valid;
    wire [NUM_SNP_SRC-1:0]   snp_src_ready;
    wire [NUM_SNP_SRC-1:0]   snp_src_pop_pulse;
    wire [NUM_SNP_SRC*SNP_W-1:0] snp_src_flit;
    wire [NUM_SNP_SRC*NUM_RN-1:0] snp_route_onehot;
    wire [NUM_RN-1:0]        snp_rn_out_valid;
    wire [NUM_RN-1:0]        snp_rn_out_ready;
    wire [NUM_RN*SNP_W-1:0]  snp_rn_out_flit;

    assign node_qos_flat = {NUM_NODES*QOS_W{1'b0}};
    assign chi_cg_en     = !cfg_cg_enable ||
                            (|cpu_req_valid) ||
                            (|axi_rvalid) ||
                            (|axi_bvalid);
    assign fabric_clear = csr_bist_init_pulse;

    chi_clock_gate_insert u_top_clock_gate (
        .clk_in(clk),
        .enable(chi_cg_en),
        .scan_enable(1'b0),
        .clk_out(clk_int)
    );

    chi_csr_regs #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_HN(NUM_HN),
        .NUM_RN(NUM_RN)
    ) u_csr_regs (
        .clk(clk),
        .rstn(rstn),
        .csr_valid(csr_valid),
        .csr_write(csr_write),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_ready(csr_ready),
        .csr_rdata(csr_rdata),
        .hn_perf_counts_flat(hn_perf_counts_flat),
        .rn_perf_counts_flat(rn_perf_counts_flat),
        .ecc_single_event(|hn_ecc_single_event),
        .ecc_double_event(|hn_ecc_double_event),
        .rn_parity_error_event(|rn_cache_parity_error_event),
        .exclusive_fail_event(|hn_exclusive_fail_event),
        .err_irq(chi_irq),
        .cfg_region_valid(cfg_region_valid),
        .cfg_hnf_base(cfg_hnf_base),
        .cfg_hnf_end(cfg_hnf_end),
        .cfg_snf_base(cfg_snf_base),
        .cfg_snf_end(cfg_snf_end),
        .cfg_mn_base(cfg_mn_base),
        .cfg_mn_end(cfg_mn_end),
        .cfg_dvm_enable(cfg_dvm_enable),
        .cfg_cg_enable(cfg_cg_enable),
        .cfg_excl_timeout(cfg_excl_timeout),
        .cfg_mn_drain_cycles(cfg_mn_drain_cycles),
        .cfg_qos_age_shift(cfg_qos_age_shift),
        .cfg_qos_age_max(cfg_qos_age_max),
        .cfg_bist_init(csr_bist_init_pulse)
    );

    genvar gr;
    genvar gh;
    genvar gs;
    genvar gm;

    generate
        for (gr = 0; gr < NUM_RN; gr = gr + 1) begin : gen_rn
            localparam integer RN_NODE_ID = RN_BASE_ID + gr;
            localparam integer REQ_SRC_IDX = gr;
            localparam integer DVM_REQ_TGT_IDX = (NUM_MN == 0) ? 0 : (NUM_HN + NUM_SN);
            wire [ADDR_WIDTH-1:0] req_addr_for_route;
            wire [5:0]           req_opcode_for_route;
            wire [NODE_ID_W-1:0]  rsp_tgt_for_route;
            wire [NODE_ID_W-1:0]  dat_tgt_for_route;
            wire [NODE_ID_W-1:0]  route_id_unused_req;
            wire [NODE_ID_W-1:0]  route_id_addr_req;
            wire [NODE_ID_W-1:0]  route_id_unused_rsp;
            wire [NODE_ID_W-1:0]  route_id_unused_dat;
            wire route_error_unused_req;
            wire route_error_addr_req;
            wire route_error_unused_rsp;
            wire route_error_unused_dat;
            wire req_is_dvm_for_route;
            wire req_is_no_snp_for_route;
            wire req_force_hn_for_route;
            wire [NODE_ID_W-1:0] hnf_route_id_for_route;
            wire [NUM_REQ_TGT-1:0] req_route_onehot_addr;
            reg  [NUM_REQ_TGT-1:0] req_route_onehot_sel;
            reg  [REQ_W-1:0]      rn_req_flit_global_tgt;

            assign req_src_valid[REQ_SRC_IDX] = rn_tx_req_valid[gr];
            assign req_src_flit[REQ_SRC_IDX*REQ_W +: REQ_W] =
                   rn_req_flit_global_tgt;
            assign req_qos_flat[REQ_SRC_IDX*QOS_W +: QOS_W] =
                   rn_req_flit_global_tgt[REQ_QOS_LSB +: QOS_W];
            assign rn_tx_req_lcrdv[gr] = req_src_valid[REQ_SRC_IDX] &&
                                          req_src_ready[REQ_SRC_IDX];

            assign rsp_node_in_valid[RN_NODE_ID] = rn_tx_rsp_valid[gr];
            assign rsp_node_in_flit[RN_NODE_ID*RSP_W +: RSP_W] =
                   rn_tx_rsp_flit[gr*RSP_W +: RSP_W];
            assign rn_tx_rsp_lcrdv[gr] = rsp_node_in_valid[RN_NODE_ID] &&
                                          rsp_node_in_ready[RN_NODE_ID];

            assign dat_node_in_valid[RN_NODE_ID] = rn_tx_dat_valid[gr];
            assign dat_node_in_flit[RN_NODE_ID*DAT_W +: DAT_W] =
                   rn_tx_dat_flit[gr*DAT_W +: DAT_W];
            assign rn_tx_dat_lcrdv[gr] = dat_node_in_valid[RN_NODE_ID] &&
                                          dat_node_in_ready[RN_NODE_ID];

            assign rsp_node_out_ready[RN_NODE_ID] = rn_rx_rsp_ready[gr];
            assign snp_rn_out_ready[gr]           = rn_rx_snp_ready[gr];
            assign dat_node_out_ready[RN_NODE_ID] = rn_rx_dat_ready[gr];

            assign req_addr_for_route = rn_tx_req_flit[gr*REQ_W + REQ_ADDR_LSB +: ADDR_WIDTH];
            assign req_opcode_for_route = rn_tx_req_flit[gr*REQ_W + `CHI_REQ_OPCODE_LSB(ADDR_WIDTH) +: 6];
            assign rsp_tgt_for_route  = rn_tx_rsp_flit[gr*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route  = rn_tx_dat_flit[gr*DAT_W + DAT_TGT_LSB +: NODE_ID_W];
            assign req_is_dvm_for_route =
                (req_opcode_for_route == `CHI_REQ_DVM_OP) ||
                (req_opcode_for_route == `CHI_REQ_DVM_SYNC);
            assign req_is_no_snp_for_route =
                (req_opcode_for_route == `CHI_REQ_RD_NO_SNP) ||
                (req_opcode_for_route == `CHI_REQ_WR_NO_SNP);
            assign req_force_hn_for_route =
                !req_is_dvm_for_route && !req_is_no_snp_for_route;
            assign hnf_route_id_for_route =
                (NUM_HN > 1) ?
                ((req_addr_for_route >> 6) % NUM_HN) :
                {NODE_ID_W{1'b0}};
            assign route_id_unused_req = req_is_dvm_for_route ?
                                         DVM_REQ_TGT_IDX :
                                         (req_force_hn_for_route ?
                                          hnf_route_id_for_route :
                                          route_id_addr_req);
            assign route_error_unused_req = req_is_dvm_for_route ?
                                            (NUM_MN == 0) :
                                            (req_force_hn_for_route ?
                                             1'b0 :
                                             route_error_addr_req);
            assign req_route_onehot[REQ_SRC_IDX*NUM_REQ_TGT +: NUM_REQ_TGT] =
                   req_route_onehot_sel;

            always @(*) begin
                req_route_onehot_sel = req_route_onehot_addr;
                if (req_is_dvm_for_route) begin
                    req_route_onehot_sel = {NUM_REQ_TGT{1'b0}};
                    if (NUM_MN != 0)
                        req_route_onehot_sel[DVM_REQ_TGT_IDX] = 1'b1;
                end else if (req_force_hn_for_route) begin
                    req_route_onehot_sel = {NUM_REQ_TGT{1'b0}};
                    req_route_onehot_sel[hnf_route_id_for_route] = 1'b1;
                end
            end

            always @(*) begin
                rn_req_flit_global_tgt = rn_tx_req_flit[gr*REQ_W +: REQ_W];
                rn_req_flit_global_tgt[REQ_TGT_LSB +: NODE_ID_W] =
                    HN_BASE_ID + route_id_unused_req;
            end

            chi_rn_f #(
                .NODE_ID(RN_NODE_ID),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .INIT_CRD(INIT_CRD),
                .TXN_TBL_SIZE(RN_TXN_TBL_SIZE),
                .RN_CACHE_LINES(RN_CACHE_LINES),
                .ENABLE_PERF(ENABLE_PERF)
            ) u_rn_f (
                .clk(clk_int),
                .rstn(rstn),
                .cpu_req_valid(cpu_req_valid[gr]),
                .cpu_req_ready(cpu_req_ready[gr]),
                .cpu_req_addr(cpu_req_addr[gr*ADDR_WIDTH +: ADDR_WIDTH]),
                .cpu_req_op(cpu_req_op[gr*4 +: 4]),
                .cpu_req_size(cpu_req_size[gr*3 +: 3]),
                .cpu_wdata(cpu_wdata[gr*DATA_WIDTH +: DATA_WIDTH]),
                .cpu_rdata(cpu_rdata[gr*DATA_WIDTH +: DATA_WIDTH]),
                .cpu_resp_valid(cpu_resp_valid[gr]),
                .tx_req_valid(rn_tx_req_valid[gr]),
                .tx_req_flit(rn_tx_req_flit[gr*REQ_W +: REQ_W]),
                .tx_req_lcrdv(rn_tx_req_lcrdv[gr]),
                .tx_rsp_valid(rn_tx_rsp_valid[gr]),
                .tx_rsp_flit(rn_tx_rsp_flit[gr*RSP_W +: RSP_W]),
                .tx_rsp_lcrdv(rn_tx_rsp_lcrdv[gr]),
                .tx_dat_valid(rn_tx_dat_valid[gr]),
                .tx_dat_flit(rn_tx_dat_flit[gr*DAT_W +: DAT_W]),
                .tx_dat_lcrdv(rn_tx_dat_lcrdv[gr]),
                .rx_rsp_valid(rsp_node_out_valid[RN_NODE_ID]),
                .rx_rsp_flit(rsp_node_out_flit[RN_NODE_ID*RSP_W +: RSP_W]),
                .rx_rsp_ready(rn_rx_rsp_ready[gr]),
                .rx_rsp_lcrdv(rn_rx_rsp_lcrdv_unused[gr]),
                .rx_snp_valid(snp_rn_out_valid[gr]),
                .rx_snp_flit(snp_rn_out_flit[gr*SNP_W +: SNP_W]),
                .rx_snp_ready(rn_rx_snp_ready[gr]),
                .rx_snp_lcrdv(rn_rx_snp_lcrdv_unused[gr]),
                .rx_dat_valid(dat_node_out_valid[RN_NODE_ID]),
                .rx_dat_flit(dat_node_out_flit[RN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_ready(rn_rx_dat_ready[gr]),
                .rx_dat_lcrdv(rn_rx_dat_lcrdv_unused[gr]),
                .perf_counts(rn_perf_counts_flat[gr*16*32 +: 16*32]),
                .cache_parity_error_event(rn_cache_parity_error_event[gr])
            );

            chi_route_decode #(
                .USE_ADDR(1),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_REQ_TGT),
                .ROUTE_ID_W(NODE_ID_W),
                .NUM_HNF(NUM_HN),
                .HNF_PORT(0),
                .SNF_PORT(NUM_HN),
                .MN_PORT(NUM_HN + NUM_SN)
            ) u_req_route (
                .valid(rn_tx_req_valid[gr]),
                .addr(req_addr_for_route),
                .tgt_id({NODE_ID_W{1'b0}}),
                .cfg_region_valid(cfg_region_valid),
                .cfg_hnf_base(cfg_hnf_base),
                .cfg_hnf_end(cfg_hnf_end),
                .cfg_snf_base(cfg_snf_base),
                .cfg_snf_end(cfg_snf_end),
                .cfg_mn_base(cfg_mn_base),
                .cfg_mn_end(cfg_mn_end),
                .route_id(route_id_addr_req),
                .route_onehot(req_route_onehot_addr),
                .route_error(route_error_addr_req)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_rsp_route (
                .valid(rn_tx_rsp_valid[gr]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_route_onehot[RN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_dat_route (
                .valid(rn_tx_dat_valid[gr]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(dat_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[RN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk_int) begin
                if (rstn) begin
                    if (route_error_unused_req) begin
                        $display("chi_top RN node %0d REQ route error",
                                 RN_NODE_ID);
                        $stop;
                    end
                    if (route_error_unused_rsp) begin
                        $display("chi_top RN%0d RSP route error target %0d",
                                 RN_NODE_ID, rsp_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_dat) begin
                        $display("chi_top RN%0d DAT route error target %0d",
                                 RN_NODE_ID, dat_tgt_for_route);
                        $stop;
                    end
                end
            end
            // synthesis translate_on
        end

        for (gh = 0; gh < NUM_HN; gh = gh + 1) begin : gen_hn
            localparam integer HN_NODE_ID = HN_BASE_ID + gh;
            localparam integer REQ_SRC_IDX = NUM_RN + gh;
            wire [NODE_ID_W-1:0] mem_req_tgt_for_route;
            wire [NODE_ID_W-1:0] rsp_tgt_for_route;
            wire [NODE_ID_W-1:0] dat_tgt_for_route;
            wire [DAT_W-1:0]     hn_dat_src_flit;
            wire                 hn_dat_src_valid;
            wire                 dat_both_valid;
            wire                 mem_dat_wins;
            wire                 tx_dat_wins;
            wire [NODE_ID_W-1:0] route_id_unused_mem_req;
            wire [NODE_ID_W-1:0] route_id_unused_rsp;
            wire [NODE_ID_W-1:0] route_id_unused_snp;
            wire [NODE_ID_W-1:0] route_id_unused_dat;
            wire route_error_unused_mem_req;
            wire route_error_unused_rsp;
            wire route_error_unused_snp;
            wire route_error_unused_dat;
            reg  dat_arb_priority_q;
            // synthesis translate_off
            reg [15:0] dat_starve_cnt_tx_q;
            reg [15:0] dat_starve_cnt_mem_q;
            // synthesis translate_on

            assign req_tgt_ready[gh] = hn_rx_req_ready[gh];
            assign snp_src_valid[gh] = hn_tx_snp_valid[gh];
            assign snp_src_flit[gh*SNP_W +: SNP_W] =
                   hn_tx_snp_flit[gh*SNP_W +: SNP_W];
            assign snp_qos_flat[gh*QOS_W +: QOS_W] =
                   hn_tx_snp_flit[gh*SNP_W + SNP_QOS_LSB +: QOS_W];
            assign hn_tx_snp_lcrdv[gh] = snp_src_valid[gh] &&
                                          snp_src_ready[gh];

            assign req_src_valid[REQ_SRC_IDX] = hn_mem_req_valid[gh];
            assign req_src_flit[REQ_SRC_IDX*REQ_W +: REQ_W] =
                   hn_mem_req_flit[gh*REQ_W +: REQ_W];
            assign req_qos_flat[REQ_SRC_IDX*QOS_W +: QOS_W] =
                   hn_mem_req_flit[gh*REQ_W + REQ_QOS_LSB +: QOS_W];
            assign hn_mem_req_ready[gh] = req_src_ready[REQ_SRC_IDX];

            assign rsp_node_in_valid[HN_NODE_ID] = hn_tx_rsp_valid[gh];
            assign rsp_node_in_flit[HN_NODE_ID*RSP_W +: RSP_W] =
                   hn_tx_rsp_flit[gh*RSP_W +: RSP_W];
            assign hn_tx_rsp_lcrdv[gh] = rsp_node_in_valid[HN_NODE_ID] &&
                                          rsp_node_in_ready[HN_NODE_ID];

            assign dat_both_valid = hn_tx_dat_valid[gh] &&
                                    hn_mem_dat_valid[gh];
            assign mem_dat_wins = hn_mem_dat_valid[gh] &&
                                  (!hn_tx_dat_valid[gh] ||
                                   (dat_both_valid && dat_arb_priority_q));
            assign tx_dat_wins = hn_tx_dat_valid[gh] && !mem_dat_wins;
            assign hn_dat_src_valid = tx_dat_wins || mem_dat_wins;
            assign hn_dat_src_flit  = tx_dat_wins ?
                                      hn_tx_dat_flit[gh*DAT_W +: DAT_W] :
                                      hn_mem_dat_flit[gh*DAT_W +: DAT_W];
            assign dat_node_in_valid[HN_NODE_ID] = hn_dat_src_valid;
            assign dat_node_in_flit[HN_NODE_ID*DAT_W +: DAT_W] = hn_dat_src_flit;
            assign hn_tx_dat_lcrdv[gh] = dat_node_in_ready[HN_NODE_ID] &&
                                          tx_dat_wins;
            assign hn_mem_dat_ready[gh] = dat_node_in_ready[HN_NODE_ID] &&
                                           mem_dat_wins;

            always @(posedge clk_int or negedge rstn) begin
                if (!rstn) begin
                    dat_arb_priority_q <= 1'b0;
                end else if (dat_node_in_pop_pulse[HN_NODE_ID]) begin
                    dat_arb_priority_q <= ~dat_arb_priority_q;
                end
            end

            // synthesis translate_off
            always @(posedge clk_int or negedge rstn) begin
                if (!rstn) begin
                    dat_starve_cnt_tx_q <= 16'd0;
                    dat_starve_cnt_mem_q <= 16'd0;
                end else begin
                    if (hn_tx_dat_valid[gh] && !tx_dat_wins)
                        dat_starve_cnt_tx_q <= dat_starve_cnt_tx_q + 1'b1;
                    else
                        dat_starve_cnt_tx_q <= 16'd0;

                    if (hn_mem_dat_valid[gh] && !mem_dat_wins)
                        dat_starve_cnt_mem_q <= dat_starve_cnt_mem_q + 1'b1;
                    else
                        dat_starve_cnt_mem_q <= 16'd0;

                    if ((dat_starve_cnt_tx_q == 16'd512) ||
                        (dat_starve_cnt_mem_q == 16'd512)) begin
                        $display("[A1 WARN] HN%0d DAT arb starvation: tx=%0d mem=%0d",
                                 HN_NODE_ID,
                                 dat_starve_cnt_tx_q,
                                 dat_starve_cnt_mem_q);
                    end
                end
            end
            // synthesis translate_on

            assign rsp_node_out_ready[HN_NODE_ID] = hn_rx_rsp_ready[gh];
            assign dat_node_out_ready[HN_NODE_ID] = hn_rx_dat_ready[gh];

            assign mem_req_tgt_for_route = hn_mem_req_flit[gh*REQ_W + REQ_TGT_LSB +: NODE_ID_W];
            assign rsp_tgt_for_route     = hn_tx_rsp_flit[gh*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route     = hn_dat_src_flit[DAT_TGT_LSB +: NODE_ID_W];

            chi_hn_f #(
                .NODE_ID(HN_NODE_ID),
                .MEM_TGT_ID(SN_BASE_ID),
                .NUM_RN(NUM_RN),
                .NUM_SN(NUM_SN),
                .SN_BASE_ID(SN_BASE_ID),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .INIT_CRD(INIT_CRD),
                .POS_DEPTH(HN_POS_DEPTH),
                .SF_ENTRIES(HN_SF_ENTRIES),
                .LLC_LINES(HN_LLC_LINES),
                .LLC_WAYS(HN_LLC_WAYS),
                .WRITE_TRACKER_DEPTH(HN_WRITE_TRACKER_DEPTH),
                .READ_TRACKER_DEPTH(HN_READ_TRACKER_DEPTH),
                .SNOOP_TRACKER_DEPTH(HN_SNOOP_TRACKER_DEPTH),
                .ENABLE_PERF(ENABLE_PERF),
                .ENABLE_LLC_ECC(HN_ENABLE_LLC_ECC)
            ) u_hn_f (
                .clk(clk_int),
                .rstn(rstn),
                .rx_req_valid(req_tgt_valid[gh]),
                .rx_req_flit(req_tgt_flit[gh*REQ_W +: REQ_W]),
                .rx_req_ready(hn_rx_req_ready[gh]),
                .rx_req_lcrdv(hn_rx_req_lcrdv_unused[gh]),
                .rx_dat_valid(dat_node_out_valid[HN_NODE_ID]),
                .rx_dat_flit(dat_node_out_flit[HN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_ready(hn_rx_dat_ready[gh]),
                .rx_dat_lcrdv(hn_rx_dat_lcrdv_unused[gh]),
                .rx_rsp_valid(rsp_node_out_valid[HN_NODE_ID]),
                .rx_rsp_flit(rsp_node_out_flit[HN_NODE_ID*RSP_W +: RSP_W]),
                .rx_rsp_ready(hn_rx_rsp_ready[gh]),
                .rx_rsp_lcrdv(hn_rx_rsp_lcrdv_unused[gh]),
                .tx_rsp_valid(hn_tx_rsp_valid[gh]),
                .tx_rsp_flit(hn_tx_rsp_flit[gh*RSP_W +: RSP_W]),
                .tx_rsp_lcrdv(hn_tx_rsp_lcrdv[gh]),
                .tx_snp_valid(hn_tx_snp_valid[gh]),
                .tx_snp_flit(hn_tx_snp_flit[gh*SNP_W +: SNP_W]),
                .tx_snp_lcrdv(hn_tx_snp_lcrdv[gh]),
                .tx_dat_valid(hn_tx_dat_valid[gh]),
                .tx_dat_flit(hn_tx_dat_flit[gh*DAT_W +: DAT_W]),
                .tx_dat_lcrdv(hn_tx_dat_lcrdv[gh]),
                .mem_req_valid(hn_mem_req_valid[gh]),
                .mem_req_ready(hn_mem_req_ready[gh]),
                .mem_req_flit(hn_mem_req_flit[gh*REQ_W +: REQ_W]),
                .mem_dat_valid(hn_mem_dat_valid[gh]),
                .mem_dat_ready(hn_mem_dat_ready[gh]),
                .mem_dat_flit(hn_mem_dat_flit[gh*DAT_W +: DAT_W]),
                .perf_counts(hn_perf_counts_flat[gh*16*32 +: 16*32]),
                .ecc_single_event(hn_ecc_single_event[gh]),
                .ecc_double_event(hn_ecc_double_event[gh]),
                .cfg_excl_timeout(cfg_excl_timeout),
                .exclusive_fail_event(hn_exclusive_fail_event[gh])
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_REQ_TGT),
                .BASE_ID(HN_BASE_ID),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_mem_req_route (
                .valid(hn_mem_req_valid[gh]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(mem_req_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_mem_req),
                .route_onehot(req_route_onehot[REQ_SRC_IDX*NUM_REQ_TGT +: NUM_REQ_TGT]),
                .route_error(route_error_unused_mem_req)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_rsp_route (
                .valid(hn_tx_rsp_valid[gh]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_route_onehot[HN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_RN),
                .BASE_ID(RN_BASE_ID),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_snp_route (
                .valid(hn_tx_snp_valid[gh]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(hn_tx_snp_flit[gh*SNP_W + SNP_TGT_LSB +: NODE_ID_W]),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_snp),
                .route_onehot(snp_route_onehot[gh*NUM_RN +: NUM_RN]),
                .route_error(route_error_unused_snp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_dat_route (
                .valid(hn_dat_src_valid),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(dat_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[HN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk_int) begin
                if (rstn) begin
                    if (route_error_unused_mem_req) begin
                        $display("chi_top HN%0d MEM REQ route error target %0d",
                                 HN_NODE_ID, mem_req_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_rsp) begin
                        $display("chi_top HN%0d RSP route error target %0d",
                                 HN_NODE_ID, rsp_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_snp) begin
                        $display("chi_top HN node %0d SNP route error",
                                 HN_NODE_ID);
                        $stop;
                    end
                    if (route_error_unused_dat) begin
                        $display("chi_top HN%0d DAT route error target %0d",
                                 HN_NODE_ID, dat_tgt_for_route);
                        $stop;
                    end
                end
            end
            // synthesis translate_on
        end

        for (gs = 0; gs < NUM_SN; gs = gs + 1) begin : gen_sn
            localparam integer SN_NODE_ID = SN_BASE_ID + gs;
            localparam integer REQ_TGT_IDX = NUM_HN + gs;
            wire [NODE_ID_W-1:0] rsp_tgt_for_route;
            wire [NODE_ID_W-1:0] dat_tgt_for_route;
            wire [NODE_ID_W-1:0] route_id_unused_rsp;
            wire [NODE_ID_W-1:0] route_id_unused_dat;
            wire route_error_unused_rsp;
            wire route_error_unused_dat;

            assign req_tgt_ready[REQ_TGT_IDX] = sn_rx_req_ready[gs];
            assign dat_node_out_ready[SN_NODE_ID] = sn_rx_dat_ready[gs];
            assign rsp_node_out_ready[SN_NODE_ID] = 1'b1;

            assign rsp_node_in_valid[SN_NODE_ID] = sn_tx_rsp_valid[gs];
            assign rsp_node_in_flit[SN_NODE_ID*RSP_W +: RSP_W] =
                   sn_tx_rsp_flit[gs*RSP_W +: RSP_W];
            assign sn_tx_rsp_lcrdv[gs] = rsp_node_in_valid[SN_NODE_ID] &&
                                          rsp_node_in_ready[SN_NODE_ID];

            assign dat_node_in_valid[SN_NODE_ID] = sn_tx_dat_valid[gs];
            assign dat_node_in_flit[SN_NODE_ID*DAT_W +: DAT_W] =
                   sn_tx_dat_flit[gs*DAT_W +: DAT_W];
            assign sn_tx_dat_lcrdv[gs] = dat_node_in_valid[SN_NODE_ID] &&
                                          dat_node_in_ready[SN_NODE_ID];

            assign rsp_tgt_for_route = sn_tx_rsp_flit[gs*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route = sn_tx_dat_flit[gs*DAT_W + DAT_TGT_LSB +: NODE_ID_W];

            chi_sn_f #(
                .NODE_ID(SN_NODE_ID),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .INIT_CRD(INIT_CRD)
            ) u_sn_f (
                .clk(clk_int),
                .rstn(rstn),
                .rx_req_valid(req_tgt_valid[REQ_TGT_IDX]),
                .rx_req_flit(req_tgt_flit[REQ_TGT_IDX*REQ_W +: REQ_W]),
                .rx_req_ready(sn_rx_req_ready[gs]),
                .rx_req_lcrdv(sn_rx_req_lcrdv_unused[gs]),
                .rx_dat_valid(dat_node_out_valid[SN_NODE_ID]),
                .rx_dat_flit(dat_node_out_flit[SN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_ready(sn_rx_dat_ready[gs]),
                .rx_dat_lcrdv(sn_rx_dat_lcrdv_unused[gs]),
                .tx_rsp_valid(sn_tx_rsp_valid[gs]),
                .tx_rsp_flit(sn_tx_rsp_flit[gs*RSP_W +: RSP_W]),
                .tx_rsp_lcrdv(sn_tx_rsp_lcrdv[gs]),
                .tx_dat_valid(sn_tx_dat_valid[gs]),
                .tx_dat_flit(sn_tx_dat_flit[gs*DAT_W +: DAT_W]),
                .tx_dat_lcrdv(sn_tx_dat_lcrdv[gs]),
                .axi_arvalid(axi_arvalid[gs]),
                .axi_arready(axi_arready[gs]),
                .axi_araddr(axi_araddr[gs*ADDR_WIDTH +: ADDR_WIDTH]),
                .axi_arsize(axi_arsize[gs*3 +: 3]),
                .axi_arlen(axi_arlen[gs*8 +: 8]),
                .axi_arburst(axi_arburst[gs*2 +: 2]),
                .axi_rvalid(axi_rvalid[gs]),
                .axi_rready(axi_rready[gs]),
                .axi_rdata(axi_rdata[gs*DATA_WIDTH +: DATA_WIDTH]),
                .axi_rresp(axi_rresp[gs*2 +: 2]),
                .axi_awvalid(axi_awvalid[gs]),
                .axi_awready(axi_awready[gs]),
                .axi_awaddr(axi_awaddr[gs*ADDR_WIDTH +: ADDR_WIDTH]),
                .axi_awsize(axi_awsize[gs*3 +: 3]),
                .axi_awlen(axi_awlen[gs*8 +: 8]),
                .axi_awburst(axi_awburst[gs*2 +: 2]),
                .axi_wvalid(axi_wvalid[gs]),
                .axi_wready(axi_wready[gs]),
                .axi_wdata(axi_wdata[gs*DATA_WIDTH +: DATA_WIDTH]),
                .axi_wstrb(axi_wstrb[gs*(DATA_WIDTH/8) +: (DATA_WIDTH/8)]),
                .axi_wlast(axi_wlast[gs]),
                .axi_bvalid(axi_bvalid[gs]),
                .axi_bready(axi_bready[gs]),
                .axi_bresp(axi_bresp[gs*2 +: 2])
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_rsp_route (
                .valid(sn_tx_rsp_valid[gs]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_route_onehot[SN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_dat_route (
                .valid(sn_tx_dat_valid[gs]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(dat_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[SN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk_int) begin
                if (rstn) begin
                    if (route_error_unused_rsp) begin
                        $display("chi_top SN%0d RSP route error target %0d",
                                 SN_NODE_ID, rsp_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_dat) begin
                        $display("chi_top SN%0d DAT route error target %0d",
                                 SN_NODE_ID, dat_tgt_for_route);
                        $stop;
                    end
                end
            end
            // synthesis translate_on
        end

        for (gm = 0; gm < NUM_MN; gm = gm + 1) begin : gen_mn
            localparam integer MN_NODE_ID = MN_BASE_ID + gm;
            localparam integer REQ_TGT_IDX = NUM_HN + NUM_SN + gm;
            localparam integer SNP_SRC_IDX = NUM_HN + gm;
            wire [NODE_ID_W-1:0] rsp_tgt_for_route;
            wire [NODE_ID_W-1:0] snp_tgt_for_route;
            wire [NODE_ID_W-1:0] route_id_unused_rsp;
            wire [NODE_ID_W-1:0] route_id_unused_snp;
            wire route_error_unused_rsp;
            wire route_error_unused_snp;

            assign req_tgt_ready[REQ_TGT_IDX] = mn_rx_req_ready[gm];
            assign rsp_node_out_ready[MN_NODE_ID] = mn_rx_rsp_ready[gm];
            assign dat_node_out_ready[MN_NODE_ID] = 1'b1;

            assign rsp_node_in_valid[MN_NODE_ID] = mn_tx_rsp_valid[gm];
            assign rsp_node_in_flit[MN_NODE_ID*RSP_W +: RSP_W] =
                   mn_tx_rsp_flit[gm*RSP_W +: RSP_W];
            assign mn_tx_rsp_lcrdv[gm] = rsp_node_in_valid[MN_NODE_ID] &&
                                          rsp_node_in_ready[MN_NODE_ID];

            assign dat_node_in_valid[MN_NODE_ID] = 1'b0;
            assign dat_node_in_flit[MN_NODE_ID*DAT_W +: DAT_W] = {DAT_W{1'b0}};

            assign snp_src_valid[SNP_SRC_IDX] = mn_tx_snp_valid[gm];
            assign snp_src_flit[SNP_SRC_IDX*SNP_W +: SNP_W] =
                   mn_tx_snp_flit[gm*SNP_W +: SNP_W];
            assign snp_qos_flat[SNP_SRC_IDX*QOS_W +: QOS_W] =
                   mn_tx_snp_flit[gm*SNP_W + SNP_QOS_LSB +: QOS_W];
            assign mn_tx_snp_lcrdv[gm] = snp_src_valid[SNP_SRC_IDX] &&
                                          snp_src_ready[SNP_SRC_IDX];

            assign rsp_tgt_for_route = mn_tx_rsp_flit[gm*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign snp_tgt_for_route = mn_tx_snp_flit[gm*SNP_W + SNP_TGT_LSB +: NODE_ID_W];

            chi_hn_i_mn #(
                .NODE_ID(MN_NODE_ID),
                .RN_BASE_ID(RN_BASE_ID),
                .NUM_RN(NUM_RN),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W)
            ) u_hn_i_mn (
                .clk(clk_int),
                .rstn(rstn),
                .dvm_enable(cfg_dvm_enable),
                .cfg_drain_cycles(cfg_mn_drain_cycles),
                .rx_req_valid(req_tgt_valid[REQ_TGT_IDX]),
                .rx_req_flit(req_tgt_flit[REQ_TGT_IDX*REQ_W +: REQ_W]),
                .rx_req_ready(mn_rx_req_ready[gm]),
                .rx_req_lcrdv(mn_rx_req_lcrdv_unused[gm]),
                .rx_rsp_valid(rsp_node_out_valid[MN_NODE_ID]),
                .rx_rsp_flit(rsp_node_out_flit[MN_NODE_ID*RSP_W +: RSP_W]),
                .rx_rsp_ready(mn_rx_rsp_ready[gm]),
                .rx_rsp_lcrdv(mn_rx_rsp_lcrdv_unused[gm]),
                .tx_snp_valid(mn_tx_snp_valid[gm]),
                .tx_snp_flit(mn_tx_snp_flit[gm*SNP_W +: SNP_W]),
                .tx_snp_lcrdv(mn_tx_snp_lcrdv[gm]),
                .tx_rsp_valid(mn_tx_rsp_valid[gm]),
                .tx_rsp_flit(mn_tx_rsp_flit[gm*RSP_W +: RSP_W]),
                .tx_rsp_lcrdv(mn_tx_rsp_lcrdv[gm])
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_rsp_route (
                .valid(mn_tx_rsp_valid[gm]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_route_onehot[MN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_RN),
                .BASE_ID(RN_BASE_ID),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_snp_route (
                .valid(mn_tx_snp_valid[gm]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(snp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_snp),
                .route_onehot(snp_route_onehot[SNP_SRC_IDX*NUM_RN +: NUM_RN]),
                .route_error(route_error_unused_snp)
            );

            // synthesis translate_off
            always @(posedge clk_int) begin
                if (rstn) begin
                    if (route_error_unused_rsp) begin
                        $display("chi_top MN%0d RSP route error target %0d",
                                 MN_NODE_ID, rsp_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_snp) begin
                        $display("chi_top MN%0d SNP route error target %0d",
                                 MN_NODE_ID, snp_tgt_for_route);
                        $stop;
                    end
                end
            end
            // synthesis translate_on
        end

    endgenerate

    chi_fabric #(
        .NUM_RN(NUM_RN),
        .NUM_HN(NUM_HN),
        .NUM_SN(NUM_SN),
        .NUM_MN(NUM_MN),
        .NUM_NODES(NUM_NODES),
        .NUM_REQ_SRC(NUM_REQ_SRC),
        .NUM_REQ_TGT(NUM_REQ_TGT),
        .NUM_SNP_SRC(NUM_SNP_SRC),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .FIFO_DEPTH(FABRIC_FIFO_DEPTH),
        .OUTPUT_FIFO_DEPTH(FABRIC_OUTPUT_FIFO_DEPTH),
        .ENABLE_QOS_AGING(ENABLE_QOS_AGING)
    ) u_fabric (
        .clk(clk_int),
        .rstn(rstn),
        .clear(fabric_clear),
        .req_qos_flat(req_qos_flat),
        .node_qos_flat(node_qos_flat),
        .snp_qos_flat(snp_qos_flat),
        .cfg_qos_age_shift(cfg_qos_age_shift),
        .cfg_qos_age_max(cfg_qos_age_max),
        .req_in_valid(req_src_valid),
        .req_in_ready(req_src_ready),
        .req_in_flit(req_src_flit),
        .req_in_pop_pulse(req_src_pop_pulse),
        .req_route_onehot(req_route_onehot),
        .req_out_valid(req_tgt_valid),
        .req_out_ready(req_tgt_ready),
        .req_out_flit(req_tgt_flit),
        .rsp_in_valid(rsp_node_in_valid),
        .rsp_in_ready(rsp_node_in_ready),
        .rsp_in_flit(rsp_node_in_flit),
        .rsp_in_pop_pulse(rsp_node_in_pop_pulse),
        .rsp_route_onehot(rsp_route_onehot),
        .rsp_out_valid(rsp_node_out_valid),
        .rsp_out_ready(rsp_node_out_ready),
        .rsp_out_flit(rsp_node_out_flit),
        .snp_in_valid(snp_src_valid),
        .snp_in_ready(snp_src_ready),
        .snp_in_flit(snp_src_flit),
        .snp_in_pop_pulse(snp_src_pop_pulse),
        .snp_route_onehot(snp_route_onehot),
        .snp_out_valid(snp_rn_out_valid),
        .snp_out_ready(snp_rn_out_ready),
        .snp_out_flit(snp_rn_out_flit),
        .dat_in_valid(dat_node_in_valid),
        .dat_in_ready(dat_node_in_ready),
        .dat_in_flit(dat_node_in_flit),
        .dat_in_pop_pulse(dat_node_in_pop_pulse),
        .dat_route_onehot(dat_route_onehot),
        .dat_out_valid(dat_node_out_valid),
        .dat_out_ready(dat_node_out_ready),
        .dat_out_flit(dat_node_out_flit)
    );
endmodule
