`include "chi_defs.vh"

module chi_hn_f #(
    parameter NODE_ID    = 0,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter POS_DEPTH  = 16
)(
    input                    clk,
    input                    rstn,

    input                    rx_req_valid,
    input      [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] rx_req_flit,
    output                   rx_req_lcrdv,

    input                    rx_dat_valid,
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] rx_dat_flit,
    output                   rx_dat_lcrdv,

    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_lcrdv,

    output                   tx_rsp_valid,
    output     [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv,

    output                   tx_snp_valid,
    output     [`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] tx_snp_flit,
    input                    tx_snp_lcrdv,

    output                   tx_dat_valid,
    output     [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] tx_dat_flit,
    input                    tx_dat_lcrdv,

    output                   mem_req_valid,
    input                    mem_req_ready,
    output     [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] mem_req_flit,

    output                   mem_dat_valid,
    input                    mem_dat_ready,
    output     [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] mem_dat_flit
);
    localparam REQ_W = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam SNP_W = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(ADDR_WIDTH);
    localparam RSP_SRC_LSB    = `CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W);

    localparam HN_ST_IDLE     = 2'd0;
    localparam HN_ST_WAIT_SNP = 2'd1;
    localparam HN_ST_AFTER_SNP = 2'd2;

    wire                 pos_in_ready;
    wire                 pos_out_valid;
    wire                 pos_out_ready;
    wire [REQ_W-1:0]     pos_out_flit;
    wire [15:0]          pos_used_unused;

    wire                 parser_valid;
    wire [REQ_W-1:0]     parser_flit;
    wire                 parsed_valid;
    wire [ADDR_WIDTH-1:0] req_addr;
    wire [2:0]           req_size;
    wire [5:0]           req_opcode;
    wire [TXN_ID_W-1:0]  req_txn_id;
    wire [NODE_ID_W-1:0] req_src_id;
    wire [NODE_ID_W-1:0] req_tgt_id;
    wire [QOS_W-1:0]     req_qos;

    wire                 req_is_read;
    wire                 req_is_write;
    wire                 raw_need_snoop;
    wire                 need_snoop;
    wire                 snp_gen_start;
    wire                 need_mem;
    wire                 need_resp;
    wire                 direct_ready;
    wire                 after_ready;
    wire                 idle_fire;
    wire                 after_fire;
    wire                 mem_issue_valid;
    wire                 resp_issue_valid;
    wire                 snp_rsp_fire;
    wire [NODE_ID_W-1:0] snp_rsp_src_id;
    reg  [NUM_RN-1:0]    snp_rsp_onehot;
    wire [NUM_RN-1:0]    snp_wait_mask_next;
    wire [NUM_RN-1:0]    snp_send_mask_next;
    reg  [NUM_RN-1:0]    snp_send_onehot;
    wire                 snp_send_fire;
    wire                 snp_all_sent_next;
    wire                 snp_wait_done;
    wire                 dir_update_valid;

    wire                 filter_hit;
    wire [1:0]           filter_state;
    wire [NUM_RN-1:0]    filter_sharer_vec;
    wire [NUM_RN-1:0]    sharers_without_requestor;
    wire [NUM_RN-1:0]    snp_valid_vec;
    wire [NUM_RN*SNP_W-1:0] snp_flit_flat;
    reg  [NUM_RN-1:0]    requestor_onehot;
    integer              rn_idx;
    integer              snp_idx;

    wire                 resp_valid;
    wire                 resp_ready;
    wire                 resp_req_ready;
    wire [RSP_W-1:0]     resp_flit;
    wire [3:0]           tx_rsp_credit_unused;
    wire                 mem_issuer_ready;

    wire                 dat_sink_in_ready;
    wire                 dat_sink_valid;
    wire [DAT_W-1:0]     dat_sink_flit;
    wire [15:0]          dat_sink_used_unused;
    wire                 rsp_sink_in_ready;
    wire                 rsp_sink_valid;
    wire [RSP_W-1:0]     rsp_sink_flit;
    wire [15:0]          rsp_sink_used_unused;

    reg  [1:0]           state_q;
    reg  [REQ_W-1:0]     hold_req_flit_q;
    reg                  snp_selected_valid;
    reg [SNP_W-1:0]      snp_selected_flit;
    reg [NUM_RN-1:0]     snp_send_mask_q;
    reg [NUM_RN-1:0]     snp_wait_mask_q;
    reg [REQ_W-1:0]      mem_req_flit_pre;
    integer              snp_rsp_idx;

    assign rx_req_lcrdv = rx_req_valid && pos_in_ready;
    assign rx_dat_lcrdv = rx_dat_valid && dat_sink_in_ready;
    assign rx_rsp_lcrdv = rx_rsp_valid && rsp_sink_in_ready;

    assign parser_valid = (state_q == HN_ST_IDLE) ? pos_out_valid : 1'b1;
    assign parser_flit  = (state_q == HN_ST_IDLE) ? pos_out_flit : hold_req_flit_q;

    assign req_is_read = (req_opcode == `CHI_REQ_RD_SHARED) ||
                         (req_opcode == `CHI_REQ_RD_UNIQUE) ||
                         (req_opcode == `CHI_REQ_RD_ONCE) ||
                         (req_opcode == `CHI_REQ_RD_NO_SNP);
    assign req_is_write = (req_opcode == `CHI_REQ_WR_UNIQUE) ||
                          (req_opcode == `CHI_REQ_WR_NO_SNP) ||
                          (req_opcode == `CHI_REQ_WB_FULL) ||
                          (req_opcode == `CHI_REQ_WB_PTL);

    assign sharers_without_requestor = filter_sharer_vec & ~requestor_onehot;
    assign raw_need_snoop = (state_q == HN_ST_IDLE) &&
                            filter_hit &&
                            (|sharers_without_requestor);
    assign need_snoop = raw_need_snoop && (|snp_valid_vec);
    assign snp_gen_start = raw_need_snoop || (state_q == HN_ST_WAIT_SNP);
    assign need_mem = req_is_write ||
                      (req_is_read && (!need_snoop || (state_q == HN_ST_AFTER_SNP)));
    assign need_resp = req_is_write || (!req_is_read && !req_is_write);

    assign direct_ready = (!need_mem || mem_issuer_ready) &&
                          (!need_resp || resp_req_ready);
    assign after_ready = (!need_mem || mem_issuer_ready) &&
                         (!need_resp || resp_req_ready);
    assign idle_fire = (state_q == HN_ST_IDLE) &&
                       parsed_valid &&
                       (need_snoop ? 1'b1 : direct_ready);
    assign after_fire = (state_q == HN_ST_AFTER_SNP) &&
                        parsed_valid &&
                        after_ready;
    assign pos_out_ready = (state_q == HN_ST_IDLE) &&
                           parsed_valid &&
                           (need_snoop ? 1'b1 : direct_ready);

    assign mem_issue_valid = ((state_q == HN_ST_IDLE) && idle_fire &&
                              !need_snoop && need_mem) ||
                             ((state_q == HN_ST_AFTER_SNP) && after_fire &&
                              need_mem);
    assign resp_issue_valid = ((state_q == HN_ST_IDLE) && idle_fire &&
                               !need_snoop && need_resp) ||
                              ((state_q == HN_ST_AFTER_SNP) && after_fire &&
                               need_resp);
    assign snp_rsp_fire = (state_q == HN_ST_WAIT_SNP) && rsp_sink_valid;
    assign snp_rsp_src_id = rsp_sink_flit[RSP_SRC_LSB +: NODE_ID_W];
    assign snp_wait_mask_next = snp_wait_mask_q & ~snp_rsp_onehot;
    assign snp_send_fire = tx_snp_valid && tx_snp_lcrdv;
    assign snp_send_mask_next = snp_send_mask_q & ~snp_send_onehot;
    assign snp_all_sent_next = snp_send_fire ?
                               (snp_send_mask_next == {NUM_RN{1'b0}}) :
                               (snp_send_mask_q == {NUM_RN{1'b0}});
    assign snp_wait_done = ((snp_rsp_fire ? snp_wait_mask_next : snp_wait_mask_q) ==
                            {NUM_RN{1'b0}});
    assign dir_update_valid = ((state_q == HN_ST_IDLE) && idle_fire &&
                               !need_snoop) ||
                              ((state_q == HN_ST_AFTER_SNP) && after_fire);

    assign tx_snp_valid = (state_q == HN_ST_WAIT_SNP) &&
                          (snp_send_mask_q != {NUM_RN{1'b0}});
    assign tx_snp_flit  = snp_selected_flit;
    assign tx_dat_valid = 1'b0;
    assign tx_dat_flit  = {DAT_W{1'b0}};
    assign mem_dat_valid = dat_sink_valid;
    assign mem_dat_flit  = dat_sink_flit;

    always @(*) begin
        requestor_onehot = {NUM_RN{1'b0}};
        for (rn_idx = 0; rn_idx < NUM_RN; rn_idx = rn_idx + 1) begin
            if (req_src_id == rn_idx)
                requestor_onehot[rn_idx] = 1'b1;
        end
    end

    always @(*) begin
        snp_rsp_onehot = {NUM_RN{1'b0}};
        for (snp_rsp_idx = 0; snp_rsp_idx < NUM_RN; snp_rsp_idx = snp_rsp_idx + 1) begin
            if (snp_rsp_src_id == snp_rsp_idx)
                snp_rsp_onehot[snp_rsp_idx] = 1'b1;
        end
    end

    always @(*) begin
        snp_selected_valid = 1'b0;
        snp_selected_flit  = {SNP_W{1'b0}};
        snp_send_onehot = {NUM_RN{1'b0}};
        for (snp_idx = 0; snp_idx < NUM_RN; snp_idx = snp_idx + 1) begin
            if (!snp_selected_valid && snp_send_mask_q[snp_idx]) begin
                snp_selected_valid = 1'b1;
                snp_send_onehot[snp_idx] = 1'b1;
                snp_selected_flit = snp_flit_flat[snp_idx*SNP_W +: SNP_W];
            end
        end
    end

    always @(*) begin
        mem_req_flit_pre = parser_flit;
        if (req_is_write)
            mem_req_flit_pre[REQ_OPCODE_LSB +: 6] = `CHI_REQ_WR_NO_SNP;
        else
            mem_req_flit_pre[REQ_OPCODE_LSB +: 6] = `CHI_REQ_RD_NO_SNP;
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= HN_ST_IDLE;
            hold_req_flit_q <= {REQ_W{1'b0}};
            snp_send_mask_q <= {NUM_RN{1'b0}};
            snp_wait_mask_q <= {NUM_RN{1'b0}};
        end else begin
            if (snp_send_fire)
                snp_send_mask_q <= snp_send_mask_next;

            case (state_q)
                HN_ST_IDLE: begin
                    if (idle_fire && need_snoop) begin
                        hold_req_flit_q <= pos_out_flit;
                        snp_send_mask_q <= snp_valid_vec;
                        snp_wait_mask_q <= snp_valid_vec;
                        state_q         <= HN_ST_WAIT_SNP;
                    end
                end

                HN_ST_WAIT_SNP: begin
                    if (snp_rsp_fire)
                        snp_wait_mask_q <= snp_wait_mask_next;

                    if (snp_all_sent_next && snp_wait_done)
                        state_q <= HN_ST_AFTER_SNP;
                end

                HN_ST_AFTER_SNP: begin
                    if (after_fire) begin
                        snp_send_mask_q <= {NUM_RN{1'b0}};
                        snp_wait_mask_q <= {NUM_RN{1'b0}};
                        state_q <= HN_ST_IDLE;
                    end
                end

                default: begin
                    state_q <= HN_ST_IDLE;
                end
            endcase
        end
    end

    chi_hn_pos_buffer #(
        .FLIT_W(REQ_W),
        .DEPTH(POS_DEPTH)
    ) u_pos_buffer (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(rx_req_valid),
        .in_ready(pos_in_ready),
        .in_flit(rx_req_flit),
        .out_valid(pos_out_valid),
        .out_ready(pos_out_ready),
        .out_flit(pos_out_flit),
        .used_count(pos_used_unused)
    );

    chi_fifo #(
        .WIDTH(DAT_W),
        .DEPTH(8)
    ) u_dat_sink_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(rx_dat_valid),
        .in_ready(dat_sink_in_ready),
        .in_data(rx_dat_flit),
        .out_valid(dat_sink_valid),
        .out_ready(mem_dat_ready),
        .out_data(dat_sink_flit),
        .used_count(dat_sink_used_unused)
    );

    chi_fifo #(
        .WIDTH(RSP_W),
        .DEPTH(4)
    ) u_rsp_sink_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(rx_rsp_valid),
        .in_ready(rsp_sink_in_ready),
        .in_data(rx_rsp_flit),
        .out_valid(rsp_sink_valid),
        .out_ready(state_q == HN_ST_WAIT_SNP),
        .out_data(rsp_sink_flit),
        .used_count(rsp_sink_used_unused)
    );

    chi_hn_req_parser #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W)
    ) u_req_parser (
        .req_valid(parser_valid),
        .req_flit(parser_flit),
        .parsed_valid(parsed_valid),
        .addr(req_addr),
        .size(req_size),
        .opcode(req_opcode),
        .txn_id(req_txn_id),
        .src_id(req_src_id),
        .tgt_id(req_tgt_id),
        .qos(req_qos)
    );

    chi_hn_snoop_filter #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_RN(NUM_RN),
        .ENTRIES(1024)
    ) u_snoop_filter (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .lookup_valid(parsed_valid),
        .lookup_addr(req_addr),
        .lookup_hit(filter_hit),
        .lookup_state(filter_state),
        .lookup_sharer_vec(filter_sharer_vec),
        .update_valid(dir_update_valid),
        .update_addr(req_addr),
        .update_state(req_is_write ? 2'b10 : 2'b01),
        .update_sharer_vec(requestor_onehot),
        .update_invalidate(1'b0)
    );

    chi_hn_snoop_generator #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_RN(NUM_RN),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W)
    ) u_snoop_generator (
        .start_valid(snp_gen_start),
        .addr(req_addr),
        .txn_id(req_txn_id),
        .req_opcode(req_opcode),
        .hn_node_id(NODE_ID),
        .requestor_id(req_src_id),
        .qos(req_qos),
        .sharer_vec(filter_sharer_vec),
        .snp_valid_vec(snp_valid_vec),
        .snp_flit_flat(snp_flit_flat)
    );

    chi_hn_resp_engine #(
        .NODE_ID(NODE_ID),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W)
    ) u_resp_engine (
        .clk(clk),
        .rstn(rstn),
        .req_valid(resp_issue_valid),
        .req_ready(resp_req_ready),
        .req_opcode(req_opcode),
        .req_txn_id(req_txn_id),
        .req_src_id(req_src_id),
        .req_qos(req_qos),
        .resp_err(`CHI_RESPERR_OK),
        .rsp_valid(resp_valid),
        .rsp_ready(resp_ready),
        .rsp_flit(resp_flit)
    );

    chi_link_layer #(
        .FLIT_W(RSP_W),
        .INIT_CREDIT(INIT_CRD)
    ) u_tx_rsp_link (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .tx_in_valid(resp_valid),
        .tx_in_ready(resp_ready),
        .tx_in_flit(resp_flit),
        .tx_out_valid(tx_rsp_valid),
        .tx_out_flit(tx_rsp_flit),
        .tx_out_lcrdv(tx_rsp_lcrdv),
        .rx_in_valid(1'b0),
        .rx_in_flit({RSP_W{1'b0}}),
        .rx_in_lcrdv(),
        .rx_out_valid(),
        .rx_out_ready(1'b1),
        .rx_out_flit(),
        .credit_count(tx_rsp_credit_unused)
    );

    chi_hn_mem_issuer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W)
    ) u_mem_issuer (
        .clk(clk),
        .rstn(rstn),
        .req_valid(mem_issue_valid),
        .req_ready(mem_issuer_ready),
        .req_flit(mem_req_flit_pre),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_flit(mem_req_flit)
    );
endmodule
