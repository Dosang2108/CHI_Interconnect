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
    localparam NUM_NODES   = NUM_RN + NUM_HN + NUM_SN;
    localparam NUM_REQ_SRC = NUM_RN + NUM_HN;
    localparam NUM_REQ_TGT = NUM_HN + NUM_SN;
    localparam RN_BASE_ID  = 0;
    localparam HN_BASE_ID  = NUM_RN;
    localparam SN_BASE_ID  = NUM_RN + NUM_HN;

    localparam REQ_W   = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W   = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam SNP_W   = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam DAT_W   = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);

    localparam REQ_ADDR_LSB = `CHI_REQ_ADDR_LSB;
    localparam REQ_TGT_LSB  = `CHI_REQ_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam RSP_TGT_LSB  = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam SNP_TGT_LSB  = `CHI_SNP_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam DAT_TGT_LSB  = `CHI_DAT_TGT_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);

    wire [NUM_REQ_SRC*QOS_W-1:0] req_qos_flat;
    wire [NUM_NODES*QOS_W-1:0]   node_qos_flat;
    wire [NUM_HN*QOS_W-1:0]      hn_qos_flat;

    wire [NUM_RN-1:0]        rn_tx_req_valid;
    wire [NUM_RN-1:0]        rn_tx_req_lcrdv;
    wire [NUM_RN*REQ_W-1:0]  rn_tx_req_flit;
    wire [NUM_RN-1:0]        rn_tx_rsp_valid;
    wire [NUM_RN-1:0]        rn_tx_rsp_lcrdv;
    wire [NUM_RN*RSP_W-1:0]  rn_tx_rsp_flit;
    wire [NUM_RN-1:0]        rn_tx_dat_valid;
    wire [NUM_RN-1:0]        rn_tx_dat_lcrdv;
    wire [NUM_RN*DAT_W-1:0]  rn_tx_dat_flit;

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

    wire [NUM_HN-1:0]        snp_hn_in_ready;
    wire [NUM_HN-1:0]        snp_hn_in_pop_pulse;
    wire [NUM_HN*NUM_RN-1:0] snp_route_onehot;
    wire [NUM_RN-1:0]        snp_rn_out_valid;
    wire [NUM_RN-1:0]        snp_rn_out_ready;
    wire [NUM_RN*SNP_W-1:0]  snp_rn_out_flit;

    assign req_qos_flat  = {NUM_REQ_SRC*QOS_W{1'b0}};
    assign node_qos_flat = {NUM_NODES*QOS_W{1'b0}};
    assign hn_qos_flat   = {NUM_HN*QOS_W{1'b0}};

    genvar gr;
    genvar gh;
    genvar gs;

    generate
        for (gr = 0; gr < NUM_RN; gr = gr + 1) begin : gen_rn
            localparam integer RN_NODE_ID = RN_BASE_ID + gr;
            localparam integer REQ_SRC_IDX = gr;
            wire [ADDR_WIDTH-1:0] req_addr_for_route;
            wire [NODE_ID_W-1:0]  rsp_tgt_for_route;
            wire [NODE_ID_W-1:0]  dat_tgt_for_route;
            wire [NODE_ID_W-1:0]  route_id_unused_req;
            wire [NODE_ID_W-1:0]  route_id_unused_rsp;
            wire [NODE_ID_W-1:0]  route_id_unused_dat;
            wire route_error_unused_req;
            wire route_error_unused_rsp;
            wire route_error_unused_dat;
            reg  [REQ_W-1:0]      rn_req_flit_global_tgt;

            assign req_src_valid[REQ_SRC_IDX] = rn_tx_req_valid[gr];
            assign req_src_flit[REQ_SRC_IDX*REQ_W +: REQ_W] =
                   rn_req_flit_global_tgt;
            assign rn_tx_req_lcrdv[gr] = req_src_pop_pulse[REQ_SRC_IDX];

            assign rsp_node_in_valid[RN_NODE_ID] = rn_tx_rsp_valid[gr];
            assign rsp_node_in_flit[RN_NODE_ID*RSP_W +: RSP_W] =
                   rn_tx_rsp_flit[gr*RSP_W +: RSP_W];
            assign rn_tx_rsp_lcrdv[gr] = rsp_node_in_pop_pulse[RN_NODE_ID];

            assign dat_node_in_valid[RN_NODE_ID] = rn_tx_dat_valid[gr];
            assign dat_node_in_flit[RN_NODE_ID*DAT_W +: DAT_W] =
                   rn_tx_dat_flit[gr*DAT_W +: DAT_W];
            assign rn_tx_dat_lcrdv[gr] = dat_node_in_pop_pulse[RN_NODE_ID];

            assign rsp_node_out_ready[RN_NODE_ID] = rn_rx_rsp_lcrdv_unused[gr];
            assign snp_rn_out_ready[gr]           = rn_rx_snp_lcrdv_unused[gr];
            assign dat_node_out_ready[RN_NODE_ID] = rn_rx_dat_lcrdv_unused[gr];

            assign req_addr_for_route = rn_tx_req_flit[gr*REQ_W + REQ_ADDR_LSB +: ADDR_WIDTH];
            assign rsp_tgt_for_route  = rn_tx_rsp_flit[gr*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route  = rn_tx_dat_flit[gr*DAT_W + DAT_TGT_LSB +: NODE_ID_W];

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
                .rx_rsp_valid(rsp_node_out_valid[RN_NODE_ID]),
                .rx_rsp_flit(rsp_node_out_flit[RN_NODE_ID*RSP_W +: RSP_W]),
                .rx_rsp_lcrdv(rn_rx_rsp_lcrdv_unused[gr]),
                .rx_snp_valid(snp_rn_out_valid[gr]),
                .rx_snp_flit(snp_rn_out_flit[gr*SNP_W +: SNP_W]),
                .rx_snp_lcrdv(rn_rx_snp_lcrdv_unused[gr]),
                .rx_dat_valid(dat_node_out_valid[RN_NODE_ID]),
                .rx_dat_flit(dat_node_out_flit[RN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_lcrdv(rn_rx_dat_lcrdv_unused[gr])
            );

            chi_route_decode #(
                .USE_ADDR(1),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_REQ_TGT),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_req_route (
                .valid(rn_tx_req_valid[gr]),
                .addr(req_addr_for_route),
                .tgt_id({NODE_ID_W{1'b0}}),
                .route_id(route_id_unused_req),
                .route_onehot(req_route_onehot[REQ_SRC_IDX*NUM_REQ_TGT +: NUM_REQ_TGT]),
                .route_error(route_error_unused_req)
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
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[RN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk) begin
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
            wire [NODE_ID_W-1:0] route_id_unused_mem_req;
            wire [NODE_ID_W-1:0] route_id_unused_rsp;
            wire [NODE_ID_W-1:0] route_id_unused_snp;
            wire [NODE_ID_W-1:0] route_id_unused_dat;
            wire route_error_unused_mem_req;
            wire route_error_unused_rsp;
            wire route_error_unused_snp;
            wire route_error_unused_dat;

            assign req_tgt_ready[gh] = hn_rx_req_lcrdv_unused[gh];

            assign req_src_valid[REQ_SRC_IDX] = hn_mem_req_valid[gh];
            assign req_src_flit[REQ_SRC_IDX*REQ_W +: REQ_W] =
                   hn_mem_req_flit[gh*REQ_W +: REQ_W];
            assign hn_mem_req_ready[gh] = req_src_pop_pulse[REQ_SRC_IDX];

            assign rsp_node_in_valid[HN_NODE_ID] = hn_tx_rsp_valid[gh];
            assign rsp_node_in_flit[HN_NODE_ID*RSP_W +: RSP_W] =
                   hn_tx_rsp_flit[gh*RSP_W +: RSP_W];
            assign hn_tx_rsp_lcrdv[gh] = rsp_node_in_pop_pulse[HN_NODE_ID];

            assign hn_dat_src_valid = hn_tx_dat_valid[gh] || hn_mem_dat_valid[gh];
            assign hn_dat_src_flit  = hn_tx_dat_valid[gh] ?
                                      hn_tx_dat_flit[gh*DAT_W +: DAT_W] :
                                      hn_mem_dat_flit[gh*DAT_W +: DAT_W];
            assign dat_node_in_valid[HN_NODE_ID] = hn_dat_src_valid;
            assign dat_node_in_flit[HN_NODE_ID*DAT_W +: DAT_W] = hn_dat_src_flit;
            assign hn_tx_dat_lcrdv[gh] = dat_node_in_pop_pulse[HN_NODE_ID] &&
                                          hn_tx_dat_valid[gh];
            assign hn_mem_dat_ready[gh] = dat_node_in_pop_pulse[HN_NODE_ID] &&
                                           !hn_tx_dat_valid[gh];

            assign rsp_node_out_ready[HN_NODE_ID] = hn_rx_rsp_lcrdv_unused[gh];
            assign dat_node_out_ready[HN_NODE_ID] = hn_rx_dat_lcrdv_unused[gh];

            assign mem_req_tgt_for_route = hn_mem_req_flit[gh*REQ_W + REQ_TGT_LSB +: NODE_ID_W];
            assign rsp_tgt_for_route     = hn_tx_rsp_flit[gh*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route     = hn_dat_src_flit[DAT_TGT_LSB +: NODE_ID_W];

            chi_hn_f #(
                .NODE_ID(HN_NODE_ID),
                .MEM_TGT_ID(SN_BASE_ID),
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
                .rx_req_valid(req_tgt_valid[gh]),
                .rx_req_flit(req_tgt_flit[gh*REQ_W +: REQ_W]),
                .rx_req_lcrdv(hn_rx_req_lcrdv_unused[gh]),
                .rx_dat_valid(dat_node_out_valid[HN_NODE_ID]),
                .rx_dat_flit(dat_node_out_flit[HN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_lcrdv(hn_rx_dat_lcrdv_unused[gh]),
                .rx_rsp_valid(rsp_node_out_valid[HN_NODE_ID]),
                .rx_rsp_flit(rsp_node_out_flit[HN_NODE_ID*RSP_W +: RSP_W]),
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
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[HN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk) begin
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

            assign req_tgt_ready[REQ_TGT_IDX] = sn_rx_req_lcrdv_unused[gs];
            assign dat_node_out_ready[SN_NODE_ID] = sn_rx_dat_lcrdv_unused[gs];
            assign rsp_node_out_ready[SN_NODE_ID] = 1'b1;

            assign rsp_node_in_valid[SN_NODE_ID] = sn_tx_rsp_valid[gs];
            assign rsp_node_in_flit[SN_NODE_ID*RSP_W +: RSP_W] =
                   sn_tx_rsp_flit[gs*RSP_W +: RSP_W];
            assign sn_tx_rsp_lcrdv[gs] = rsp_node_in_pop_pulse[SN_NODE_ID];

            assign dat_node_in_valid[SN_NODE_ID] = sn_tx_dat_valid[gs];
            assign dat_node_in_flit[SN_NODE_ID*DAT_W +: DAT_W] =
                   sn_tx_dat_flit[gs*DAT_W +: DAT_W];
            assign sn_tx_dat_lcrdv[gs] = dat_node_in_pop_pulse[SN_NODE_ID];

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
                .clk(clk),
                .rstn(rstn),
                .rx_req_valid(req_tgt_valid[REQ_TGT_IDX]),
                .rx_req_flit(req_tgt_flit[REQ_TGT_IDX*REQ_W +: REQ_W]),
                .rx_req_lcrdv(sn_rx_req_lcrdv_unused[gs]),
                .rx_dat_valid(dat_node_out_valid[SN_NODE_ID]),
                .rx_dat_flit(dat_node_out_flit[SN_NODE_ID*DAT_W +: DAT_W]),
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
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[SN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk) begin
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

    endgenerate

    chi_fabric #(
        .NUM_RN(NUM_RN),
        .NUM_HN(NUM_HN),
        .NUM_SN(NUM_SN),
        .NUM_NODES(NUM_NODES),
        .NUM_REQ_SRC(NUM_REQ_SRC),
        .NUM_REQ_TGT(NUM_REQ_TGT),
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
        .req_qos_flat(req_qos_flat),
        .node_qos_flat(node_qos_flat),
        .hn_qos_flat(hn_qos_flat),
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
        .snp_in_valid(hn_tx_snp_valid),
        .snp_in_ready(snp_hn_in_ready),
        .snp_in_flit(hn_tx_snp_flit),
        .snp_in_pop_pulse(snp_hn_in_pop_pulse),
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

    assign hn_tx_snp_lcrdv = snp_hn_in_pop_pulse;
endmodule
