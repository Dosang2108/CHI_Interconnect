`include "chi_defs.vh"

module chi_hn_f #(
    parameter NODE_ID    = 0,
    parameter MEM_TGT_ID = 0,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter POS_DEPTH  = 16,
    parameter TIMEOUT_CYCLES = 1024
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
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] mem_dat_flit
);
    function integer clog2;
        input integer value;
        integer i;
        begin
            value = value - 1;
            for (i = 0; value > 0; i = i + 1)
                value = value >> 1;
            clog2 = i;
        end
    endfunction

    localparam REQ_W = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam SNP_W = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);

    localparam LINE_BYTES = 64;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam BE_W = DATA_WIDTH / 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam TIMEOUT_W = (TIMEOUT_CYCLES <= 2) ? 1 : clog2(TIMEOUT_CYCLES + 1);
    localparam [TIMEOUT_W-1:0] TIMEOUT_VALUE = TIMEOUT_CYCLES;

    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(ADDR_WIDTH);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(ADDR_WIDTH,TXN_ID_W);
    localparam REQ_TGT_LSB    = `CHI_REQ_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam RSP_RESP_LSB   = `CHI_RSP_RESP_LSB;
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB;
    localparam RSP_DBID_LSB   = `CHI_RSP_DBID_LSB;
    localparam RSP_OPCODE_LSB = `CHI_RSP_OPCODE_LSB(DBID_W);
    localparam RSP_TXN_LSB    = `CHI_RSP_TXN_LSB(DBID_W);
    localparam RSP_SRC_LSB    = `CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W);
    localparam RSP_TGT_LSB    = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam RSP_QOS_LSB    = `CHI_RSP_QOS_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB;
    localparam DAT_BE_LSB      = `CHI_DAT_BE_LSB;
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DATA_WIDTH);
    localparam DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DATA_WIDTH);
    localparam DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DATA_WIDTH);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DATA_WIDTH,DBID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DATA_WIDTH,DBID_W,TXN_ID_W);
    localparam DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);
    localparam DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);

    localparam HN_ST_IDLE          = 4'd0;
    localparam HN_ST_BACKINV       = 4'd1;
    localparam HN_ST_AFTER_BACKINV = 4'd2;
    localparam HN_ST_WAIT_SNP      = 4'd3;
    localparam HN_ST_AFTER_SNP     = 4'd4;
    localparam HN_ST_WAIT_MEM      = 4'd5;
    localparam HN_ST_SEND_DAT      = 4'd6;
    localparam HN_ST_WAIT_ACK      = 4'd7;

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
    wire                 process_state;
    wire                 raw_need_snoop;
    wire                 need_snoop;
    wire                 need_backinv;
    wire                 accept_req;
    wire                 start_backinv;
    wire                 start_snoop;
    wire                 start_snoop_data_ack;
    wire                 start_mem_read;
    wire                 start_llc_read;
    wire                 start_write;
    wire                 start_other_resp;

    wire                 filter_hit;
    wire [1:0]           filter_state;
    wire [NUM_RN-1:0]    filter_sharer_vec;
    wire                 backinv_valid;
    wire [ADDR_WIDTH-1:0] backinv_addr;
    wire [NUM_RN-1:0]    backinv_sharer_vec;
    wire [NUM_RN-1:0]    sharers_without_requestor;
    reg  [NUM_RN-1:0]    requestor_onehot;
    integer              rn_idx;

    wire                 llc_hit;
    wire [2:0]           llc_state_unused;
    wire [LINE_WIDTH-1:0] llc_data;
    wire                 llc_update_valid;
    wire [ADDR_WIDTH-1:0] llc_update_addr;
    wire [LINE_WIDTH-1:0] llc_update_data;
    wire [2:0]           llc_update_state;
    wire                 llc_invalidate_valid;

    wire [ADDR_WIDTH-1:0] snp_addr_sel;
    wire [5:0]           snp_req_opcode_sel;
    wire [NODE_ID_W-1:0] snp_requestor_sel;
    wire [NUM_RN-1:0]    snp_sharer_sel;
    wire                 snp_gen_start;
    wire [NUM_RN-1:0]    snp_valid_vec;
    wire [NUM_RN*SNP_W-1:0] snp_flit_flat;
    reg  [NUM_RN-1:0]    snp_send_mask_q;
    reg  [NUM_RN-1:0]    snp_wait_mask_q;
    reg  [NUM_RN-1:0]    snp_send_onehot;
    reg                  snp_selected_valid;
    reg [SNP_W-1:0]      snp_selected_flit;
    wire                 snp_send_fire;
    wire [NUM_RN-1:0]    snp_send_mask_next;
    wire                 snp_all_sent_next;
    wire                 snp_wait_done;
    integer              snp_idx;

    wire                 dat_sink_in_ready;
    wire                 dat_sink_out_ready;
    wire                 dat_sink_valid;
    wire [DAT_W-1:0]     dat_sink_flit;
    wire [15:0]          dat_sink_used_unused;
    wire [3:0]           dat_data_id;
    wire                 dat_data_id_ok;
    wire [BEATS-1:0]     mem_beat_mask_next;
    wire [LINE_WIDTH-1:0] mem_line_next;
    wire                 mem_dat_beat_fire;
    wire                 backinv_dat_beat_fire;
    wire                 dat_line_beat_fire;
    wire                 mem_line_complete;

    wire                 rsp_sink_in_ready;
    wire                 rsp_sink_valid;
    wire [RSP_W-1:0]     rsp_sink_flit;
    wire [15:0]          rsp_sink_used_unused;
    wire [3:0]           rsp_opcode;
    wire [TXN_ID_W-1:0]  rsp_txn_id;
    wire [NODE_ID_W-1:0] rsp_src_id;
    wire                 snp_rsp_fire;
    wire                 comp_ack_fire;
    wire                 mem_rsp_drop_fire;
    wire                 rsp_sink_pop;
    reg  [NUM_RN-1:0]    snp_rsp_onehot;
    wire [NUM_RN-1:0]    snp_wait_mask_next;
    integer              snp_rsp_idx;

    wire                 resp_valid;
    wire                 resp_ready;
    wire                 resp_req_ready;
    wire [RSP_W-1:0]     resp_flit;
    wire                 tx_rsp_link_valid;
    wire                 tx_rsp_link_ready;
    wire [RSP_W-1:0]     tx_rsp_link_flit;
    wire                 wr_comp_ready;
    wire                 err_rsp_ready;
    wire [3:0]           tx_rsp_credit_unused;
    wire                 mem_issuer_ready;
    wire                 mem_issue_valid;
    wire                 resp_issue_valid;
    reg  [REQ_W-1:0]     mem_req_flit_pre;

    wire                 snp_dat_valid;
    wire                 snp_dat_ready;
    reg  [DAT_W-1:0]     snp_dat_flit;
    wire                 resp_dat_valid;
    wire                 resp_dat_ready;
    reg  [DAT_W-1:0]     resp_dat_flit;
    wire                 tx_dat_link_valid;
    wire                 tx_dat_link_ready;
    wire [DAT_W-1:0]     tx_dat_link_flit;
    wire [3:0]           tx_dat_credit_unused;
    wire                 resp_dat_fire;
    wire                 resp_dat_last;

    reg  [3:0]           state_q;
    reg  [REQ_W-1:0]     hold_req_flit_q;
    reg  [ADDR_WIDTH-1:0] backinv_addr_q;
    reg  [NUM_RN-1:0]    backinv_sharer_vec_q;
    reg  [LINE_WIDTH-1:0] mem_line_q;
    reg  [BEATS-1:0]      mem_beat_mask_q;
    reg  [LINE_WIDTH-1:0] resp_line_q;
    reg  [3:0]            resp_beat_q;
    reg                   snp_data_seen_q;
    reg                   wr_pending_q;
    reg                   wr_comp_valid_q;
    reg [TXN_ID_W-1:0]    wr_txn_q;
    reg [NODE_ID_W-1:0]   wr_src_q;
    reg [QOS_W-1:0]       wr_qos_q;
    reg [RSP_W-1:0]       wr_comp_flit;
    reg                   err_rsp_valid_q;
    reg [TXN_ID_W-1:0]    err_txn_q;
    reg [NODE_ID_W-1:0]   err_tgt_q;
    reg [QOS_W-1:0]       err_qos_q;
    reg [RSP_W-1:0]       err_rsp_flit;
    reg [TIMEOUT_W-1:0]   timeout_cnt_q;

    wire                  state_timeout_en;
    wire                  state_timeout_fire;

    reg                  filter_update_valid;
    reg                  filter_update_invalidate;
    reg [ADDR_WIDTH-1:0] filter_update_addr;
    reg [1:0]            filter_update_state;
    reg [NUM_RN-1:0]     filter_update_sharer_vec;

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
    assign raw_need_snoop = filter_hit && (|sharers_without_requestor);
    assign process_state = (state_q == HN_ST_IDLE) ||
                           (state_q == HN_ST_AFTER_BACKINV) ||
                           (state_q == HN_ST_AFTER_SNP);
    assign need_snoop = process_state &&
                        (state_q != HN_ST_AFTER_SNP) &&
                        raw_need_snoop;
    assign need_backinv = (state_q == HN_ST_IDLE) &&
                          parsed_valid &&
                          (req_is_read || req_is_write) &&
                          backinv_valid;

    assign start_backinv = parsed_valid && need_backinv;
    assign start_snoop = parsed_valid && !need_backinv && need_snoop;
    assign start_snoop_data_ack = parsed_valid &&
                                  (state_q == HN_ST_AFTER_SNP) &&
                                  req_is_read &&
                                  snp_data_seen_q;
    assign start_llc_read = parsed_valid && !need_backinv && !need_snoop &&
                            !start_snoop_data_ack && req_is_read && llc_hit;
    assign start_mem_read = parsed_valid && !need_backinv && !need_snoop &&
                            !start_snoop_data_ack && req_is_read &&
                            !llc_hit && mem_issuer_ready;
    assign start_write = parsed_valid && !need_backinv && !need_snoop &&
                         req_is_write && !wr_pending_q && !wr_comp_valid_q &&
                         mem_issuer_ready && resp_req_ready;
    assign start_other_resp = parsed_valid && !need_backinv && !need_snoop &&
                              !req_is_read && !req_is_write && resp_req_ready;

    assign accept_req = process_state &&
                        !err_rsp_valid_q &&
                        (start_backinv || start_snoop || start_snoop_data_ack ||
                         start_llc_read || start_mem_read || start_write ||
                         start_other_resp);
    assign pos_out_ready = (state_q == HN_ST_IDLE) && accept_req;

    assign mem_issue_valid = process_state && (start_mem_read || start_write);
    assign resp_issue_valid = process_state && (start_write || start_other_resp);

    assign snp_gen_start = start_backinv || start_snoop ||
                           (state_q == HN_ST_BACKINV) ||
                           (state_q == HN_ST_WAIT_SNP);
    assign snp_addr_sel = ((state_q == HN_ST_BACKINV) || start_backinv) ?
                          (start_backinv ? backinv_addr : backinv_addr_q) :
                          req_addr;
    assign snp_req_opcode_sel = ((state_q == HN_ST_BACKINV) || start_backinv) ?
                                `CHI_REQ_MK_UNIQUE : req_opcode;
    assign snp_requestor_sel = ((state_q == HN_ST_BACKINV) || start_backinv) ?
                               {NODE_ID_W{1'b1}} : req_src_id;
    assign snp_sharer_sel = (state_q == HN_ST_BACKINV) ?
                            backinv_sharer_vec_q :
                            (start_backinv ? backinv_sharer_vec :
                             filter_sharer_vec);

    assign tx_snp_valid = snp_gen_start &&
                          (snp_send_mask_q != {NUM_RN{1'b0}});
    assign tx_snp_flit = snp_selected_flit;
    assign snp_send_fire = tx_snp_valid && tx_snp_lcrdv;
    assign snp_send_mask_next = snp_send_mask_q & ~snp_send_onehot;
    assign snp_all_sent_next = snp_send_fire ?
                               (snp_send_mask_next == {NUM_RN{1'b0}}) :
                               (snp_send_mask_q == {NUM_RN{1'b0}});

    assign rsp_opcode = rsp_sink_flit[RSP_OPCODE_LSB +: 4];
    assign rsp_txn_id = rsp_sink_flit[RSP_TXN_LSB +: TXN_ID_W];
    assign rsp_src_id = rsp_sink_flit[RSP_SRC_LSB +: NODE_ID_W];
    assign snp_rsp_fire = rsp_sink_valid &&
                          ((state_q == HN_ST_BACKINV) ||
                           (state_q == HN_ST_WAIT_SNP)) &&
                          (rsp_opcode == `CHI_RSP_SNP_RESP);
    assign comp_ack_fire = rsp_sink_valid &&
                           (state_q == HN_ST_WAIT_ACK) &&
                           (rsp_opcode == `CHI_RSP_COMP_ACK) &&
                           (rsp_txn_id == req_txn_id);
    assign mem_rsp_drop_fire = rsp_sink_valid &&
                               ((rsp_opcode == `CHI_RSP_COMP) ||
                                (rsp_opcode == `CHI_RSP_COMP_DBID)) &&
                               !wr_comp_valid_q;
    assign rsp_sink_pop = snp_rsp_fire || comp_ack_fire || mem_rsp_drop_fire;
    assign snp_wait_mask_next = snp_wait_mask_q & ~snp_rsp_onehot;
    assign snp_wait_done = ((snp_rsp_fire ? snp_wait_mask_next : snp_wait_mask_q) ==
                            {NUM_RN{1'b0}});

    assign dat_data_id = dat_sink_flit[DAT_DATAID_LSB +: 4];
    assign dat_data_id_ok = (dat_data_id < BEATS);
    assign mem_dat_beat_fire = dat_sink_valid &&
                               (state_q == HN_ST_WAIT_MEM) &&
                               dat_sink_out_ready &&
                               dat_data_id_ok;
    assign backinv_dat_beat_fire = dat_sink_valid &&
                                   (state_q == HN_ST_BACKINV) &&
                                   dat_sink_out_ready &&
                                   dat_data_id_ok;
    assign dat_line_beat_fire = mem_dat_beat_fire || backinv_dat_beat_fire;
    assign mem_line_next = mem_line_q |
                           ({{(LINE_WIDTH-DATA_WIDTH){1'b0}},
                             dat_sink_flit[DAT_DATA_LSB +: DATA_WIDTH]} <<
                            (dat_data_id * DATA_WIDTH));
    assign mem_beat_mask_next = mem_beat_mask_q | ({{(BEATS-1){1'b0}}, 1'b1} << dat_data_id);
    assign mem_line_complete = dat_line_beat_fire && (&mem_beat_mask_next);

    assign snp_dat_valid = dat_sink_valid && (state_q == HN_ST_WAIT_SNP);
    assign resp_dat_valid = (state_q == HN_ST_SEND_DAT);
    assign tx_dat_link_valid = snp_dat_valid || resp_dat_valid;
    assign tx_dat_link_flit = snp_dat_valid ? snp_dat_flit : resp_dat_flit;
    assign snp_dat_ready = tx_dat_link_ready;
    assign resp_dat_ready = tx_dat_link_ready && !snp_dat_valid;
    assign resp_dat_fire = resp_dat_valid && resp_dat_ready;
    assign resp_dat_last = resp_dat_fire && (resp_beat_q == (BEATS - 1));

    assign dat_sink_out_ready = (state_q == HN_ST_WAIT_SNP) ? snp_dat_ready :
                                (state_q == HN_ST_WAIT_MEM) ? 1'b1 :
                                (state_q == HN_ST_BACKINV)  ? 1'b1 :
                                mem_dat_ready;

    assign mem_dat_valid = dat_sink_valid &&
                           (state_q != HN_ST_WAIT_SNP) &&
                           (state_q != HN_ST_WAIT_MEM) &&
                           (state_q != HN_ST_BACKINV);

    assign tx_rsp_link_valid = resp_valid || wr_comp_valid_q || err_rsp_valid_q;
    assign tx_rsp_link_flit = resp_valid ? resp_flit :
                              (wr_comp_valid_q ? wr_comp_flit :
                               err_rsp_flit);
    assign resp_ready = tx_rsp_link_ready;
    assign wr_comp_ready = tx_rsp_link_ready && !resp_valid;
    assign err_rsp_ready = tx_rsp_link_ready && !resp_valid && !wr_comp_valid_q;

    assign state_timeout_en = (state_q == HN_ST_BACKINV) ||
                              (state_q == HN_ST_WAIT_SNP) ||
                              (state_q == HN_ST_WAIT_MEM) ||
                              (state_q == HN_ST_SEND_DAT) ||
                              (state_q == HN_ST_WAIT_ACK);
    assign state_timeout_fire = state_timeout_en &&
                                (timeout_cnt_q >= TIMEOUT_VALUE);

    assign llc_update_valid = mem_line_complete;
    assign llc_update_addr = (state_q == HN_ST_BACKINV) ? backinv_addr_q : req_addr;
    assign llc_update_data = mem_line_next;
    assign llc_update_state = (state_q == HN_ST_BACKINV) ? `CHI_STATE_SC :
                              ((req_opcode == `CHI_REQ_RD_UNIQUE) ?
                               `CHI_STATE_UC : `CHI_STATE_SC);
    assign llc_invalidate_valid = 1'b0;

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
            if (rsp_src_id == snp_rsp_idx)
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
        mem_req_flit_pre[REQ_OPCODE_LSB +: 6] =
            req_is_write ? `CHI_REQ_WR_NO_SNP : `CHI_REQ_RD_NO_SNP;
        mem_req_flit_pre[REQ_SRC_LSB +: NODE_ID_W] = NODE_ID;
        mem_req_flit_pre[REQ_TGT_LSB +: NODE_ID_W] = MEM_TGT_ID;
    end

    always @(*) begin
        snp_dat_flit = dat_sink_flit;
        snp_dat_flit[DAT_SRC_LSB +: NODE_ID_W] = NODE_ID;
        snp_dat_flit[DAT_TGT_LSB +: NODE_ID_W] = req_src_id;
    end

    always @(*) begin
        mem_dat_flit = dat_sink_flit;
        mem_dat_flit[DAT_SRC_LSB +: NODE_ID_W] = NODE_ID;
        mem_dat_flit[DAT_TGT_LSB +: NODE_ID_W] = MEM_TGT_ID;
    end

    always @(*) begin
        resp_dat_flit = {DAT_W{1'b0}};
        resp_dat_flit[DAT_RESPERR_LSB +: 2]       = `CHI_RESPERR_OK;
        resp_dat_flit[DAT_BE_LSB +: BE_W]         = {BE_W{1'b1}};
        resp_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] =
            resp_line_q[resp_beat_q*DATA_WIDTH +: DATA_WIDTH];
        resp_dat_flit[DAT_DATAID_LSB +: 4]        = resp_beat_q;
        resp_dat_flit[DAT_DBID_LSB +: DBID_W]     = {DBID_W{1'b0}};
        resp_dat_flit[DAT_TXN_LSB +: TXN_ID_W]    = req_txn_id;
        resp_dat_flit[DAT_SRC_LSB +: NODE_ID_W]   = NODE_ID;
        resp_dat_flit[DAT_TGT_LSB +: NODE_ID_W]   = req_src_id;
        resp_dat_flit[DAT_RESP_LSB +: 3]          = 3'd0;
    end

    always @(*) begin
        wr_comp_flit = {RSP_W{1'b0}};
        wr_comp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        wr_comp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_OK;
        wr_comp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        wr_comp_flit[RSP_OPCODE_LSB +: 4]      = `CHI_RSP_COMP;
        wr_comp_flit[RSP_TXN_LSB +: TXN_ID_W]  = wr_txn_q;
        wr_comp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        wr_comp_flit[RSP_TGT_LSB +: NODE_ID_W] = wr_src_q;
        wr_comp_flit[RSP_QOS_LSB +: QOS_W]     = wr_qos_q;
    end

    always @(*) begin
        err_rsp_flit = {RSP_W{1'b0}};
        err_rsp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        err_rsp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_SLVERR;
        err_rsp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        err_rsp_flit[RSP_OPCODE_LSB +: 4]      = `CHI_RSP_COMP;
        err_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = err_txn_q;
        err_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        err_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = err_tgt_q;
        err_rsp_flit[RSP_QOS_LSB +: QOS_W]     = err_qos_q;
    end

    always @(*) begin
        filter_update_valid = 1'b0;
        filter_update_invalidate = 1'b0;
        filter_update_addr = req_addr;
        filter_update_state = req_is_write ? 2'b10 : 2'b01;
        filter_update_sharer_vec = requestor_onehot;

        if ((state_q == HN_ST_BACKINV) && snp_all_sent_next && snp_wait_done) begin
            filter_update_valid = 1'b1;
            filter_update_invalidate = 1'b1;
            filter_update_addr = backinv_addr_q;
            filter_update_state = 2'b00;
            filter_update_sharer_vec = {NUM_RN{1'b0}};
        end else if (start_write) begin
            filter_update_valid = 1'b1;
        end else if (comp_ack_fire) begin
            filter_update_valid = 1'b1;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= HN_ST_IDLE;
            hold_req_flit_q <= {REQ_W{1'b0}};
            backinv_addr_q <= {ADDR_WIDTH{1'b0}};
            backinv_sharer_vec_q <= {NUM_RN{1'b0}};
            snp_send_mask_q <= {NUM_RN{1'b0}};
            snp_wait_mask_q <= {NUM_RN{1'b0}};
            mem_line_q <= {LINE_WIDTH{1'b0}};
            mem_beat_mask_q <= {BEATS{1'b0}};
            resp_line_q <= {LINE_WIDTH{1'b0}};
            resp_beat_q <= 4'd0;
            snp_data_seen_q <= 1'b0;
            wr_pending_q <= 1'b0;
            wr_comp_valid_q <= 1'b0;
            wr_txn_q <= {TXN_ID_W{1'b0}};
            wr_src_q <= {NODE_ID_W{1'b0}};
            wr_qos_q <= {QOS_W{1'b0}};
            err_rsp_valid_q <= 1'b0;
            err_txn_q <= {TXN_ID_W{1'b0}};
            err_tgt_q <= {NODE_ID_W{1'b0}};
            err_qos_q <= {QOS_W{1'b0}};
            timeout_cnt_q <= {TIMEOUT_W{1'b0}};
        end else begin
            if (wr_comp_valid_q && wr_comp_ready)
                wr_comp_valid_q <= 1'b0;

            if (err_rsp_valid_q && err_rsp_ready)
                err_rsp_valid_q <= 1'b0;

            if (mem_rsp_drop_fire && wr_pending_q) begin
                wr_comp_valid_q <= 1'b1;
                wr_pending_q <= 1'b0;
            end

            if (state_timeout_en) begin
                if (timeout_cnt_q != TIMEOUT_VALUE)
                    timeout_cnt_q <= timeout_cnt_q + 1'b1;
            end else begin
                timeout_cnt_q <= {TIMEOUT_W{1'b0}};
            end

            if (snp_send_fire)
                snp_send_mask_q <= snp_send_mask_next;

            if (snp_rsp_fire)
                snp_wait_mask_q <= snp_wait_mask_next;

            if (dat_line_beat_fire) begin
                mem_line_q <= mem_line_next;
                mem_beat_mask_q <= mem_beat_mask_next;
            end

            if (snp_dat_valid && snp_dat_ready)
                snp_data_seen_q <= 1'b1;

            if (state_timeout_fire) begin
                if (state_q != HN_ST_WAIT_ACK) begin
                    err_rsp_valid_q <= 1'b1;
                    err_txn_q <= req_txn_id;
                    err_tgt_q <= req_src_id;
                    err_qos_q <= req_qos;
                end
                state_q <= HN_ST_IDLE;
                snp_send_mask_q <= {NUM_RN{1'b0}};
                snp_wait_mask_q <= {NUM_RN{1'b0}};
                mem_beat_mask_q <= {BEATS{1'b0}};
                resp_beat_q <= 4'd0;
                snp_data_seen_q <= 1'b0;
                timeout_cnt_q <= {TIMEOUT_W{1'b0}};
            end else begin
            case (state_q)
                HN_ST_IDLE,
                HN_ST_AFTER_BACKINV,
                HN_ST_AFTER_SNP: begin
                    if (accept_req) begin
                        if (state_q == HN_ST_IDLE)
                            hold_req_flit_q <= pos_out_flit;

                        if (start_backinv) begin
                            backinv_addr_q <= backinv_addr;
                            backinv_sharer_vec_q <= backinv_sharer_vec;
                            mem_line_q <= {LINE_WIDTH{1'b0}};
                            mem_beat_mask_q <= {BEATS{1'b0}};
                            snp_send_mask_q <= backinv_sharer_vec;
                            snp_wait_mask_q <= backinv_sharer_vec;
                            state_q <= HN_ST_BACKINV;
                        end else if (start_snoop) begin
                            snp_send_mask_q <= snp_valid_vec;
                            snp_wait_mask_q <= snp_valid_vec;
                            snp_data_seen_q <= 1'b0;
                            state_q <= HN_ST_WAIT_SNP;
                        end else if (start_snoop_data_ack) begin
                            state_q <= HN_ST_WAIT_ACK;
                        end else if (start_llc_read) begin
                            resp_line_q <= llc_data;
                            resp_beat_q <= 4'd0;
                            state_q <= HN_ST_SEND_DAT;
                        end else if (start_mem_read) begin
                            mem_line_q <= {LINE_WIDTH{1'b0}};
                            mem_beat_mask_q <= {BEATS{1'b0}};
                            state_q <= HN_ST_WAIT_MEM;
                        end else begin
                            if (start_write) begin
                                wr_pending_q <= 1'b1;
                                wr_txn_q <= req_txn_id;
                                wr_src_q <= req_src_id;
                                wr_qos_q <= req_qos;
                            end
                            state_q <= HN_ST_IDLE;
                        end
                    end
                end

                HN_ST_BACKINV: begin
                    if (snp_all_sent_next && snp_wait_done) begin
                        snp_send_mask_q <= {NUM_RN{1'b0}};
                        snp_wait_mask_q <= {NUM_RN{1'b0}};
                        state_q <= HN_ST_AFTER_BACKINV;
                    end
                end

                HN_ST_WAIT_SNP: begin
                    if (snp_all_sent_next && snp_wait_done) begin
                        snp_send_mask_q <= {NUM_RN{1'b0}};
                        snp_wait_mask_q <= {NUM_RN{1'b0}};
                        state_q <= HN_ST_AFTER_SNP;
                    end
                end

                HN_ST_WAIT_MEM: begin
                    if (mem_line_complete) begin
                        resp_line_q <= mem_line_next;
                        resp_beat_q <= 4'd0;
                        state_q <= HN_ST_SEND_DAT;
                    end
                end

                HN_ST_SEND_DAT: begin
                    if (resp_dat_fire) begin
                        if (resp_dat_last) begin
                            resp_beat_q <= 4'd0;
                            state_q <= HN_ST_WAIT_ACK;
                        end else begin
                            resp_beat_q <= resp_beat_q + 1'b1;
                        end
                    end
                end

                HN_ST_WAIT_ACK: begin
                    if (comp_ack_fire)
                        state_q <= HN_ST_IDLE;
                end

                default: state_q <= HN_ST_IDLE;
            endcase
            end
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
        .out_ready(dat_sink_out_ready),
        .out_data(dat_sink_flit),
        .used_count(dat_sink_used_unused)
    );

    chi_fifo #(
        .WIDTH(RSP_W),
        .DEPTH(8)
    ) u_rsp_sink_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(rx_rsp_valid),
        .in_ready(rsp_sink_in_ready),
        .in_data(rx_rsp_flit),
        .out_valid(rsp_sink_valid),
        .out_ready(rsp_sink_pop),
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
        .update_valid(filter_update_valid),
        .update_addr(filter_update_addr),
        .update_state(filter_update_state),
        .update_sharer_vec(filter_update_sharer_vec),
        .update_invalidate(filter_update_invalidate),
        .backinv_valid(backinv_valid),
        .backinv_addr(backinv_addr),
        .backinv_sharer_vec(backinv_sharer_vec)
    );

    chi_hn_llc #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .LINES(128)
    ) u_llc (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .lookup_valid(parsed_valid),
        .lookup_addr(req_addr),
        .lookup_hit(llc_hit),
        .lookup_state(llc_state_unused),
        .lookup_data(llc_data),
        .line_update_valid(llc_update_valid),
        .line_update_addr(llc_update_addr),
        .line_update_data(llc_update_data),
        .line_update_state(llc_update_state),
        .line_invalidate_valid(llc_invalidate_valid),
        .line_invalidate_addr(req_addr)
    );

    chi_hn_snoop_generator #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_RN(NUM_RN),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W)
    ) u_snoop_generator (
        .start_valid(snp_gen_start),
        .addr(snp_addr_sel),
        .txn_id(req_txn_id),
        .req_opcode(snp_req_opcode_sel),
        .hn_node_id(NODE_ID),
        .requestor_id(snp_requestor_sel),
        .qos(req_qos),
        .sharer_vec(snp_sharer_sel),
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
        .tx_in_valid(tx_rsp_link_valid),
        .tx_in_ready(tx_rsp_link_ready),
        .tx_in_flit(tx_rsp_link_flit),
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

    chi_link_layer #(
        .FLIT_W(DAT_W),
        .INIT_CREDIT(INIT_CRD)
    ) u_tx_dat_link (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .tx_in_valid(tx_dat_link_valid),
        .tx_in_ready(tx_dat_link_ready),
        .tx_in_flit(tx_dat_link_flit),
        .tx_out_valid(tx_dat_valid),
        .tx_out_flit(tx_dat_flit),
        .tx_out_lcrdv(tx_dat_lcrdv),
        .rx_in_valid(1'b0),
        .rx_in_flit({DAT_W{1'b0}}),
        .rx_in_lcrdv(),
        .rx_out_valid(),
        .rx_out_ready(1'b1),
        .rx_out_flit(),
        .credit_count(tx_dat_credit_unused)
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

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn) begin
            if (dat_sink_valid && !dat_data_id_ok &&
                ((state_q == HN_ST_WAIT_MEM) || (state_q == HN_ST_BACKINV))) begin
                $display("chi_hn_f invalid DAT DataID %0d", dat_data_id);
                $stop;
            end

            if (rsp_sink_valid && !rsp_sink_pop) begin
                $display("chi_hn_f unexpected RSP opcode %0h txn %0h in state %0d",
                         rsp_opcode, rsp_txn_id, state_q);
                $stop;
            end

            if (state_timeout_fire) begin
                $display("chi_hn_f transaction timeout state %0d txn %0h",
                         state_q, req_txn_id);
            end
        end
    end
    // synthesis translate_on
endmodule
