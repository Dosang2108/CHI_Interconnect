`include "chi_defs.vh"

module chi_top #(
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter NUM_HN     = `CHI_DEFAULT_NUM_HN,
    parameter NUM_SN     = `CHI_DEFAULT_NUM_SN,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter INIT_CRD   = `CHI_DEFAULT_INIT_CRD
)(
    input                         clk,
    input                         rstn,

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
    localparam NUM_TGT = NUM_HN + NUM_SN;
    localparam REQ_W   = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W   = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam SNP_W   = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam DAT_W   = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);

    localparam REQ_ADDR_LSB = `CHI_REQ_ADDR_LSB;
    localparam RSP_TGT_LSB  = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam SNP_TGT_LSB  = `CHI_SNP_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam DAT_TGT_LSB  = `CHI_DAT_TGT_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);

    wire [NUM_RN*QOS_W-1:0]  rn_qos_flat;
    wire [NUM_TGT*QOS_W-1:0] tgt_qos_flat;

    wire [NUM_RN-1:0]        rn_tx_req_valid;
    wire [NUM_RN-1:0]        rn_tx_req_lcrdv;
    wire [NUM_RN*REQ_W-1:0]  rn_tx_req_flit;
    wire [NUM_RN-1:0]        rn_tx_rsp_valid;
    wire [NUM_RN-1:0]        rn_tx_rsp_lcrdv;
    wire [NUM_RN*RSP_W-1:0]  rn_tx_rsp_flit;
    wire [NUM_RN-1:0]        rn_tx_dat_valid;
    wire [NUM_RN-1:0]        rn_tx_dat_lcrdv;
    wire [NUM_RN*DAT_W-1:0]  rn_tx_dat_flit;

    wire [NUM_RN-1:0]        req_in_ready;
    wire [NUM_RN-1:0]        req_in_pop_pulse;
    wire [NUM_RN-1:0]        rsp_rn_in_ready;
    wire [NUM_RN-1:0]        rsp_rn_in_pop_pulse;
    wire [NUM_RN-1:0]        dat_rn_in_ready;
    wire [NUM_RN-1:0]        dat_rn_in_pop_pulse;
    wire [NUM_RN*NUM_TGT-1:0] req_route_onehot;
    wire [NUM_RN*NUM_TGT-1:0] rsp_rn_route_onehot;
    wire [NUM_RN*NUM_TGT-1:0] dat_rn_route_onehot;

    wire [NUM_TGT-1:0]       req_out_valid;
    wire [NUM_TGT-1:0]       req_out_ready;
    wire [NUM_TGT*REQ_W-1:0] req_out_flit;
    wire [NUM_TGT-1:0]       dat_rn_out_valid;
    wire [NUM_TGT-1:0]       dat_rn_out_ready;
    wire [NUM_TGT*DAT_W-1:0] dat_rn_out_flit;
    wire [NUM_TGT-1:0]       rsp_rn_out_valid;
    wire [NUM_TGT-1:0]       rsp_rn_out_ready;
    wire [NUM_TGT*RSP_W-1:0] rsp_rn_out_flit;

    wire [NUM_TGT-1:0]       tgt_rsp_in_valid;
    wire [NUM_TGT-1:0]       tgt_rsp_in_ready;
    wire [NUM_TGT-1:0]       tgt_rsp_in_pop_pulse;
    wire [NUM_TGT*RSP_W-1:0] tgt_rsp_in_flit;
    wire [NUM_TGT*NUM_RN-1:0] tgt_rsp_route_onehot;
    wire [NUM_RN-1:0]        rsp_out_valid;
    wire [NUM_RN-1:0]        rsp_out_ready;
    wire [NUM_RN*RSP_W-1:0]  rsp_out_flit;

    wire [NUM_TGT-1:0]       tgt_snp_in_valid;
    wire [NUM_TGT-1:0]       tgt_snp_in_ready;
    wire [NUM_TGT-1:0]       tgt_snp_in_pop_pulse;
    wire [NUM_TGT*SNP_W-1:0] tgt_snp_in_flit;
    wire [NUM_TGT*NUM_RN-1:0] tgt_snp_route_onehot;
    wire [NUM_RN-1:0]        snp_out_valid;
    wire [NUM_RN-1:0]        snp_out_ready;
    wire [NUM_RN*SNP_W-1:0]  snp_out_flit;

    wire [NUM_TGT-1:0]       tgt_dat_in_valid;
    wire [NUM_TGT-1:0]       tgt_dat_in_ready;
    wire [NUM_TGT-1:0]       tgt_dat_in_pop_pulse;
    wire [NUM_TGT*DAT_W-1:0] tgt_dat_in_flit;
    wire [NUM_TGT*NUM_RN-1:0] tgt_dat_route_onehot;
    wire [NUM_RN-1:0]        dat_tgt_out_valid;
    wire [NUM_RN-1:0]        dat_tgt_out_ready;
    wire [NUM_RN*DAT_W-1:0]  dat_tgt_out_flit;

    wire [NUM_RN-1:0]        rn_rx_rsp_lcrdv_unused;
    wire [NUM_RN-1:0]        rn_rx_snp_lcrdv_unused;
    wire [NUM_RN-1:0]        rn_rx_dat_lcrdv_unused;

    wire [NUM_HN-1:0]        hn_rx_req_lcrdv_unused;
    wire [NUM_HN-1:0]        hn_rx_dat_lcrdv_unused;
    wire [NUM_HN-1:0]        hn_rx_rsp_lcrdv_unused;
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

    wire [NUM_SN-1:0]        sn_rx_req_lcrdv_unused;
    wire [NUM_SN-1:0]        sn_rx_dat_lcrdv_unused;
    wire [NUM_SN-1:0]        sn_tx_rsp_valid;
    wire [NUM_SN-1:0]        sn_tx_rsp_lcrdv;
    wire [NUM_SN*RSP_W-1:0]  sn_tx_rsp_flit;
    wire [NUM_SN-1:0]        sn_tx_dat_valid;
    wire [NUM_SN-1:0]        sn_tx_dat_lcrdv;
    wire [NUM_SN*DAT_W-1:0]  sn_tx_dat_flit;
    reg  [NUM_HN-1:0]        hn_mem_grant;
    reg  [REQ_W-1:0]         hn_mem_req_flit_mux;
    reg  [NUM_HN-1:0]        hn_mem_dat_grant;
    reg  [DAT_W-1:0]         hn_mem_dat_flit_mux;
    integer                  hn_mem_idx;
    integer                  hn_mem_dat_idx;

    assign rn_qos_flat      = {NUM_RN*QOS_W{1'b0}};
    assign tgt_qos_flat     = {NUM_TGT*QOS_W{1'b0}};
    assign hn_mem_req_ready = hn_mem_grant &
                              {NUM_HN{(!req_out_valid[NUM_HN]) &&
                                      sn_rx_req_lcrdv_unused[0]}};
    assign hn_mem_dat_ready = hn_mem_dat_grant &
                              {NUM_HN{(!dat_rn_out_valid[NUM_HN]) &&
                                      sn_rx_dat_lcrdv_unused[0]}};

    always @(*) begin
        hn_mem_grant = {NUM_HN{1'b0}};
        hn_mem_req_flit_mux = {REQ_W{1'b0}};
        for (hn_mem_idx = 0; hn_mem_idx < NUM_HN; hn_mem_idx = hn_mem_idx + 1) begin
            if ((hn_mem_grant == {NUM_HN{1'b0}}) && hn_mem_req_valid[hn_mem_idx]) begin
                hn_mem_grant[hn_mem_idx] = 1'b1;
                hn_mem_req_flit_mux = hn_mem_req_flit[hn_mem_idx*REQ_W +: REQ_W];
            end
        end
    end

    always @(*) begin
        hn_mem_dat_grant = {NUM_HN{1'b0}};
        hn_mem_dat_flit_mux = {DAT_W{1'b0}};
        for (hn_mem_dat_idx = 0; hn_mem_dat_idx < NUM_HN; hn_mem_dat_idx = hn_mem_dat_idx + 1) begin
            if ((hn_mem_dat_grant == {NUM_HN{1'b0}}) &&
                hn_mem_dat_valid[hn_mem_dat_idx]) begin
                hn_mem_dat_grant[hn_mem_dat_idx] = 1'b1;
                hn_mem_dat_flit_mux = hn_mem_dat_flit[hn_mem_dat_idx*DAT_W +: DAT_W];
            end
        end
    end
    genvar gr;
    genvar gh;
    genvar gs;
    genvar gt;

    generate
        for (gr = 0; gr < NUM_RN; gr = gr + 1) begin : gen_rn
            wire [ADDR_WIDTH-1:0] req_addr_for_route;
            wire [NODE_ID_W-1:0]  rsp_tgt_for_route;
            wire [NODE_ID_W-1:0]  dat_tgt_for_route;
            wire [3:0] route_id_unused_req;
            wire [3:0] route_id_unused_rsp;
            wire [3:0] route_id_unused_dat;
            wire route_error_unused_req;
            wire route_error_unused_rsp;
            wire route_error_unused_dat;

            assign rn_tx_req_lcrdv[gr] = req_in_pop_pulse[gr];
            assign rn_tx_rsp_lcrdv[gr] = rsp_rn_in_pop_pulse[gr];
            assign rn_tx_dat_lcrdv[gr] = dat_rn_in_pop_pulse[gr];
            assign rsp_out_ready[gr]   = rn_rx_rsp_lcrdv_unused[gr];
            assign snp_out_ready[gr]   = rn_rx_snp_lcrdv_unused[gr];
            assign dat_tgt_out_ready[gr] = rn_rx_dat_lcrdv_unused[gr];

            assign req_addr_for_route = rn_tx_req_flit[gr*REQ_W + REQ_ADDR_LSB +: ADDR_WIDTH];
            assign rsp_tgt_for_route  = rn_tx_rsp_flit[gr*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route  = rn_tx_dat_flit[gr*DAT_W + DAT_TGT_LSB +: NODE_ID_W];

            chi_rn_f #(
                .NODE_ID(gr),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .INIT_CRD(INIT_CRD)
            ) u_rn_f (
                .clk(clk),
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
                .rx_rsp_valid(rsp_out_valid[gr]),
                .rx_rsp_flit(rsp_out_flit[gr*RSP_W +: RSP_W]),
                .rx_rsp_lcrdv(rn_rx_rsp_lcrdv_unused[gr]),
                .rx_snp_valid(snp_out_valid[gr]),
                .rx_snp_flit(snp_out_flit[gr*SNP_W +: SNP_W]),
                .rx_snp_lcrdv(rn_rx_snp_lcrdv_unused[gr]),
                .rx_dat_valid(dat_tgt_out_valid[gr]),
                .rx_dat_flit(dat_tgt_out_flit[gr*DAT_W +: DAT_W]),
                .rx_dat_lcrdv(rn_rx_dat_lcrdv_unused[gr])
            );

            chi_route_decode #(
                .USE_ADDR(1),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_TGT),
                .ROUTE_ID_W(4)
            ) u_req_route (
                .valid(rn_tx_req_valid[gr]),
                .addr(req_addr_for_route),
                .tgt_id({NODE_ID_W{1'b0}}),
                .route_id(route_id_unused_req),
                .route_onehot(req_route_onehot[gr*NUM_TGT +: NUM_TGT]),
                .route_error(route_error_unused_req)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_TGT),
                .ROUTE_ID_W(4)
            ) u_rsp_route (
                .valid(rn_tx_rsp_valid[gr]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_rn_route_onehot[gr*NUM_TGT +: NUM_TGT]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_TGT),
                .ROUTE_ID_W(4)
            ) u_dat_route (
                .valid(rn_tx_dat_valid[gr]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(dat_tgt_for_route),
                .route_id(route_id_unused_dat),
                .route_onehot(dat_rn_route_onehot[gr*NUM_TGT +: NUM_TGT]),
                .route_error(route_error_unused_dat)
            );
        end

        for (gt = 0; gt < NUM_TGT; gt = gt + 1) begin : gen_target_routes
            wire [NODE_ID_W-1:0] rsp_tgt_id;
            wire [NODE_ID_W-1:0] snp_tgt_id;
            wire [NODE_ID_W-1:0] dat_tgt_id;
            wire [3:0] route_id_unused_rsp_tgt;
            wire [3:0] route_id_unused_snp_tgt;
            wire [3:0] route_id_unused_dat_tgt;
            wire route_error_unused_rsp_tgt;
            wire route_error_unused_snp_tgt;
            wire route_error_unused_dat_tgt;

            assign rsp_tgt_id = tgt_rsp_in_flit[gt*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign snp_tgt_id = tgt_snp_in_flit[gt*SNP_W + SNP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_id = tgt_dat_in_flit[gt*DAT_W + DAT_TGT_LSB +: NODE_ID_W];

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_RN),
                .ROUTE_ID_W(4)
            ) u_rsp_tgt_route (
                .valid(tgt_rsp_in_valid[gt]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_id),
                .route_id(route_id_unused_rsp_tgt),
                .route_onehot(tgt_rsp_route_onehot[gt*NUM_RN +: NUM_RN]),
                .route_error(route_error_unused_rsp_tgt)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_RN),
                .ROUTE_ID_W(4)
            ) u_snp_tgt_route (
                .valid(tgt_snp_in_valid[gt]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(snp_tgt_id),
                .route_id(route_id_unused_snp_tgt),
                .route_onehot(tgt_snp_route_onehot[gt*NUM_RN +: NUM_RN]),
                .route_error(route_error_unused_snp_tgt)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_RN),
                .ROUTE_ID_W(4)
            ) u_dat_tgt_route (
                .valid(tgt_dat_in_valid[gt]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(dat_tgt_id),
                .route_id(route_id_unused_dat_tgt),
                .route_onehot(tgt_dat_route_onehot[gt*NUM_RN +: NUM_RN]),
                .route_error(route_error_unused_dat_tgt)
            );
        end

        for (gh = 0; gh < NUM_HN; gh = gh + 1) begin : gen_hn
            assign tgt_rsp_in_valid[gh] = hn_tx_rsp_valid[gh];
            assign tgt_rsp_in_flit[gh*RSP_W +: RSP_W] = hn_tx_rsp_flit[gh*RSP_W +: RSP_W];
            assign hn_tx_rsp_lcrdv[gh] = tgt_rsp_in_pop_pulse[gh];

            assign tgt_snp_in_valid[gh] = hn_tx_snp_valid[gh];
            assign tgt_snp_in_flit[gh*SNP_W +: SNP_W] = hn_tx_snp_flit[gh*SNP_W +: SNP_W];
            assign hn_tx_snp_lcrdv[gh] = tgt_snp_in_pop_pulse[gh];

            assign tgt_dat_in_valid[gh] = hn_tx_dat_valid[gh];
            assign tgt_dat_in_flit[gh*DAT_W +: DAT_W] = hn_tx_dat_flit[gh*DAT_W +: DAT_W];
            assign hn_tx_dat_lcrdv[gh] = tgt_dat_in_pop_pulse[gh];
            assign req_out_ready[gh]   = hn_rx_req_lcrdv_unused[gh];
            assign dat_rn_out_ready[gh] = hn_rx_dat_lcrdv_unused[gh];
            assign rsp_rn_out_ready[gh] = hn_rx_rsp_lcrdv_unused[gh];

            chi_hn_f #(
                .NODE_ID(gh),
                .NUM_RN(NUM_RN),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .INIT_CRD(INIT_CRD)
            ) u_hn_f (
                .clk(clk),
                .rstn(rstn),
                .rx_req_valid(req_out_valid[gh]),
                .rx_req_flit(req_out_flit[gh*REQ_W +: REQ_W]),
                .rx_req_lcrdv(hn_rx_req_lcrdv_unused[gh]),
                .rx_dat_valid(dat_rn_out_valid[gh]),
                .rx_dat_flit(dat_rn_out_flit[gh*DAT_W +: DAT_W]),
                .rx_dat_lcrdv(hn_rx_dat_lcrdv_unused[gh]),
                .rx_rsp_valid(rsp_rn_out_valid[gh]),
                .rx_rsp_flit(rsp_rn_out_flit[gh*RSP_W +: RSP_W]),
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
                .mem_dat_flit(hn_mem_dat_flit[gh*DAT_W +: DAT_W])
            );
        end

        for (gs = 0; gs < NUM_SN; gs = gs + 1) begin : gen_sn
            localparam integer TGT_IDX = NUM_HN + gs;
            wire sn_req_valid_mux;
            wire [REQ_W-1:0] sn_req_flit_mux;
            wire sn_dat_valid_mux;
            wire [DAT_W-1:0] sn_dat_flit_mux;

            assign tgt_rsp_in_valid[TGT_IDX] = sn_tx_rsp_valid[gs];
            assign tgt_rsp_in_flit[TGT_IDX*RSP_W +: RSP_W] = sn_tx_rsp_flit[gs*RSP_W +: RSP_W];
            assign sn_tx_rsp_lcrdv[gs] = tgt_rsp_in_pop_pulse[TGT_IDX];

            assign tgt_snp_in_valid[TGT_IDX] = 1'b0;
            assign tgt_snp_in_flit[TGT_IDX*SNP_W +: SNP_W] = {SNP_W{1'b0}};

            assign tgt_dat_in_valid[TGT_IDX] = sn_tx_dat_valid[gs];
            assign tgt_dat_in_flit[TGT_IDX*DAT_W +: DAT_W] = sn_tx_dat_flit[gs*DAT_W +: DAT_W];
            assign sn_tx_dat_lcrdv[gs] = tgt_dat_in_pop_pulse[TGT_IDX];
            assign sn_req_valid_mux = (gs == 0) ?
                                      (req_out_valid[TGT_IDX] || (|hn_mem_req_valid)) :
                                      req_out_valid[TGT_IDX];
            assign sn_req_flit_mux = ((gs == 0) && !req_out_valid[TGT_IDX]) ?
                                     hn_mem_req_flit_mux :
                                     req_out_flit[TGT_IDX*REQ_W +: REQ_W];
            assign sn_dat_valid_mux = (gs == 0) ?
                                      (dat_rn_out_valid[TGT_IDX] || (|hn_mem_dat_valid)) :
                                      dat_rn_out_valid[TGT_IDX];
            assign sn_dat_flit_mux = ((gs == 0) && !dat_rn_out_valid[TGT_IDX]) ?
                                     hn_mem_dat_flit_mux :
                                     dat_rn_out_flit[TGT_IDX*DAT_W +: DAT_W];
            assign req_out_ready[TGT_IDX] = req_out_valid[TGT_IDX] ?
                                            sn_rx_req_lcrdv_unused[gs] :
                                            1'b0;
            assign dat_rn_out_ready[TGT_IDX] = sn_rx_dat_lcrdv_unused[gs];
            assign rsp_rn_out_ready[TGT_IDX] = 1'b0;

            chi_sn_f #(
                .NODE_ID(TGT_IDX),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .INIT_CRD(INIT_CRD)
            ) u_sn_f (
                .clk(clk),
                .rstn(rstn),
                .rx_req_valid(sn_req_valid_mux),
                .rx_req_flit(sn_req_flit_mux),
                .rx_req_lcrdv(sn_rx_req_lcrdv_unused[gs]),
                .rx_dat_valid(sn_dat_valid_mux),
                .rx_dat_flit(sn_dat_flit_mux),
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
        end
    endgenerate

    chi_fabric #(
        .NUM_RN(NUM_RN),
        .NUM_TGT(NUM_TGT),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W)
    ) u_fabric (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .rn_qos_flat(rn_qos_flat),
        .tgt_qos_flat(tgt_qos_flat),
        .req_in_valid(rn_tx_req_valid),
        .req_in_ready(req_in_ready),
        .req_in_flit(rn_tx_req_flit),
        .req_in_pop_pulse(req_in_pop_pulse),
        .req_route_onehot(req_route_onehot),
        .req_out_valid(req_out_valid),
        .req_out_ready(req_out_ready),
        .req_out_flit(req_out_flit),
        .rsp_in_valid(tgt_rsp_in_valid),
        .rsp_in_ready(tgt_rsp_in_ready),
        .rsp_in_flit(tgt_rsp_in_flit),
        .rsp_in_pop_pulse(tgt_rsp_in_pop_pulse),
        .rsp_route_onehot(tgt_rsp_route_onehot),
        .rsp_out_valid(rsp_out_valid),
        .rsp_out_ready(rsp_out_ready),
        .rsp_out_flit(rsp_out_flit),
        .rsp_rn_in_valid(rn_tx_rsp_valid),
        .rsp_rn_in_ready(rsp_rn_in_ready),
        .rsp_rn_in_flit(rn_tx_rsp_flit),
        .rsp_rn_in_pop_pulse(rsp_rn_in_pop_pulse),
        .rsp_rn_route_onehot(rsp_rn_route_onehot),
        .rsp_rn_out_valid(rsp_rn_out_valid),
        .rsp_rn_out_ready(rsp_rn_out_ready),
        .rsp_rn_out_flit(rsp_rn_out_flit),
        .snp_in_valid(tgt_snp_in_valid),
        .snp_in_ready(tgt_snp_in_ready),
        .snp_in_flit(tgt_snp_in_flit),
        .snp_in_pop_pulse(tgt_snp_in_pop_pulse),
        .snp_route_onehot(tgt_snp_route_onehot),
        .snp_out_valid(snp_out_valid),
        .snp_out_ready(snp_out_ready),
        .snp_out_flit(snp_out_flit),
        .dat_rn_in_valid(rn_tx_dat_valid),
        .dat_rn_in_ready(dat_rn_in_ready),
        .dat_rn_in_flit(rn_tx_dat_flit),
        .dat_rn_in_pop_pulse(dat_rn_in_pop_pulse),
        .dat_rn_route_onehot(dat_rn_route_onehot),
        .dat_rn_out_valid(dat_rn_out_valid),
        .dat_rn_out_ready(dat_rn_out_ready),
        .dat_rn_out_flit(dat_rn_out_flit),
        .dat_tgt_in_valid(tgt_dat_in_valid),
        .dat_tgt_in_ready(tgt_dat_in_ready),
        .dat_tgt_in_flit(tgt_dat_in_flit),
        .dat_tgt_in_pop_pulse(tgt_dat_in_pop_pulse),
        .dat_tgt_route_onehot(tgt_dat_route_onehot),
        .dat_tgt_out_valid(dat_tgt_out_valid),
        .dat_tgt_out_ready(dat_tgt_out_ready),
        .dat_tgt_out_flit(dat_tgt_out_flit)
    );
endmodule
