`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_rn_snoop_handler
// Purpose: RN-F snoop responder. It performs synchronous cache snoop lookups,
//          returns SnpResp/SnpRespData, and updates or invalidates local cache
//          state as required by the snoop opcode.
// -----------------------------------------------------------------------------
module chi_rn_snoop_handler #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter LINE_BYTES = 64,
    parameter DVM_ORDER_CYCLES = 2
)(
    input                    clk,
    input                    rstn,
    input                    rx_snp_valid,
    input      [`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] rx_snp_flit,
    output                   rx_snp_ready,
    output                   rx_snp_lcrdv,

    input      [NODE_ID_W-1:0] node_id,

    input                    cache_hit,
    input                    cache_dirty,
    input                    cache_result_valid,
    input      [2:0]         cache_state,
    input      [LINE_BYTES*8-1:0] cache_data,
    input                    cache_send_data,
    output                   cache_snoop_valid,
    output     [ADDR_WIDTH-1:0] cache_snoop_addr,
    output     [5:0]         cache_snoop_opcode,
    output                   cache_snoop_commit,

    output                   tx_rsp_valid,
    input                    tx_rsp_ready,
    output reg [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] tx_rsp_flit,

    output                   tx_dat_valid,
    input                    tx_dat_ready,
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] tx_dat_flit
);
    `include "../common/chi_clog2.vh"
    localparam SNP_ADDR_LSB   = `CHI_SNP_ADDR_LSB;
    localparam SNP_SIZE_LSB   = `CHI_SNP_SIZE_LSB(ADDR_WIDTH);
    localparam SNP_OPCODE_LSB = `CHI_SNP_OPCODE_LSB(ADDR_WIDTH);
    localparam SNP_TXN_LSB    = `CHI_SNP_TXN_LSB(ADDR_WIDTH);
    localparam SNP_SRC_LSB    = `CHI_SNP_SRC_LSB(ADDR_WIDTH,TXN_ID_W);
    localparam SNP_TGT_LSB    = `CHI_SNP_TGT_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);
    localparam SNP_QOS_LSB    = `CHI_SNP_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);

    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB;
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB;
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB;
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(DBID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(DBID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(DBID_W,TXN_ID_W,NODE_ID_W);

    localparam DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB;
    localparam DAT_BE_LSB      = `CHI_DAT_BE_LSB;
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DATA_WIDTH);
    localparam DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DATA_WIDTH);
    localparam DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DATA_WIDTH);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DATA_WIDTH,DBID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DATA_WIDTH,DBID_W,TXN_ID_W);
    localparam DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);
    localparam DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);

    localparam BE_W = DATA_WIDTH / 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam DVM_ORDER_W = (DVM_ORDER_CYCLES <= 1) ? 1 :
                             `CHI_CLOG2(DVM_ORDER_CYCLES + 1);
    localparam [DVM_ORDER_W-1:0] DVM_ORDER_VALUE = DVM_ORDER_CYCLES;
    localparam ST_IDLE = 3'd0;
    localparam ST_LOOKUP = 3'd1;
    localparam ST_WAIT_CACHE = 3'd2;
    localparam ST_DVM_ORDER = 3'd3;
    localparam ST_SEND_DAT = 3'd4;
    localparam ST_SEND_RSP = 3'd5;

    reg [2:0]           state_q;
    reg [`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] snp_flit_q;
    reg [LINE_WIDTH-1:0] data_q;
    reg                  hit_q;
    reg                  dirty_q;
    reg [2:0]            state_resp_q;
    reg [3:0]            beat_q;
    reg [DVM_ORDER_W-1:0] dvm_order_cnt_q;

    wire [ADDR_WIDTH-1:0] snp_addr = rx_snp_flit[SNP_ADDR_LSB +: ADDR_WIDTH];
    wire [5:0]           snp_opcode = rx_snp_flit[SNP_OPCODE_LSB +: 6];
    wire [ADDR_WIDTH-1:0] latched_addr = snp_flit_q[SNP_ADDR_LSB +: ADDR_WIDTH];
    wire [5:0]           latched_opcode = snp_flit_q[SNP_OPCODE_LSB +: 6];
    wire                 snp_is_dvm = (snp_opcode == `CHI_SNP_DVM_OP) ||
                                      (snp_opcode == `CHI_SNP_DVM_SYNC);
    wire                 latched_is_dvm = (latched_opcode == `CHI_SNP_DVM_OP) ||
                                          (latched_opcode == `CHI_SNP_DVM_SYNC);
    wire                 accept_snp = (state_q == ST_IDLE) && rx_snp_valid;
    wire                 dat_fire = tx_dat_valid && tx_dat_ready;
    wire                 rsp_fire = tx_rsp_valid && tx_rsp_ready;
    wire [3:0]           current_beat = beat_q;
    wire [TXN_ID_W-1:0]  latched_txn_id = snp_flit_q[SNP_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0] latched_src_id = snp_flit_q[SNP_SRC_LSB +: NODE_ID_W];
    wire [QOS_W-1:0]     latched_qos = snp_flit_q[SNP_QOS_LSB +: QOS_W];
    wire                 dvm_order_done = (dvm_order_cnt_q >= DVM_ORDER_VALUE);

    assign rx_snp_ready = (state_q == ST_IDLE);
    assign rx_snp_lcrdv = accept_snp;
    assign cache_snoop_valid = (state_q == ST_LOOKUP) && !latched_is_dvm;
    assign cache_snoop_addr = (state_q == ST_IDLE) ? snp_addr : latched_addr;
    assign cache_snoop_opcode = (state_q == ST_IDLE) ? snp_opcode : latched_opcode;
    assign cache_snoop_commit = rsp_fire && !latched_is_dvm;
    assign tx_dat_valid = (state_q == ST_SEND_DAT);
    assign tx_rsp_valid = (state_q == ST_SEND_RSP);

    always @(*) begin
        tx_rsp_flit = {`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W){1'b0}};
        tx_rsp_flit[RSP_RESP_LSB +: 3]        =
            latched_is_dvm ? `CHI_RESP_DVM_ACK : {1'b0, dirty_q, hit_q};
        tx_rsp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_OK;
        tx_rsp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        tx_rsp_flit[RSP_OPCODE_LSB +: 4]      = `CHI_RSP_SNP_RESP;
        tx_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = latched_txn_id;
        tx_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = node_id;
        tx_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = latched_src_id;
        tx_rsp_flit[RSP_QOS_LSB +: QOS_W]     = latched_qos;
    end

    always @(*) begin
        tx_dat_flit = {`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W){1'b0}};
        tx_dat_flit[DAT_RESPERR_LSB +: 2]       = `CHI_RESPERR_OK;
        tx_dat_flit[DAT_BE_LSB +: BE_W]         = {BE_W{1'b1}};
        tx_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] =
            data_q[current_beat*DATA_WIDTH +: DATA_WIDTH];
        tx_dat_flit[DAT_DATAID_LSB +: 4]        = current_beat;
        tx_dat_flit[DAT_DBID_LSB +: DBID_W]     = {DBID_W{1'b0}};
        tx_dat_flit[DAT_TXN_LSB +: TXN_ID_W]    = latched_txn_id;
        tx_dat_flit[DAT_SRC_LSB +: NODE_ID_W]   = node_id;
        tx_dat_flit[DAT_TGT_LSB +: NODE_ID_W]   = latched_src_id;
        tx_dat_flit[DAT_RESP_LSB +: 3]          = state_resp_q;
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (accept_snp)
                snp_flit_q <= rx_snp_flit;

            if ((state_q == ST_WAIT_CACHE) && cache_result_valid)
                data_q <= cache_data;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= ST_IDLE;
            hit_q <= 1'b0;
            dirty_q <= 1'b0;
            state_resp_q <= 3'd0;
            beat_q <= 4'd0;
            dvm_order_cnt_q <= {DVM_ORDER_W{1'b0}};
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (accept_snp) begin
                        beat_q <= 4'd0;
                        dvm_order_cnt_q <= {DVM_ORDER_W{1'b0}};
                        if (snp_is_dvm)
                            state_q <= ST_DVM_ORDER;
                        else
                            state_q <= ST_LOOKUP;
                    end
                end

                ST_LOOKUP: begin
                    state_q <= ST_WAIT_CACHE;
                end

                ST_WAIT_CACHE: begin
                    if (cache_result_valid) begin
                        hit_q <= cache_hit;
                        dirty_q <= cache_dirty;
                        state_resp_q <= cache_state;
                        beat_q <= 4'd0;
                        if (cache_send_data)
                            state_q <= ST_SEND_DAT;
                        else
                            state_q <= ST_SEND_RSP;
                    end
                end

                ST_DVM_ORDER: begin
                    hit_q <= 1'b0;
                    dirty_q <= 1'b0;
                    state_resp_q <= `CHI_RESP_DVM_ACK;
                    beat_q <= 4'd0;
                    if (dvm_order_done) begin
                        dvm_order_cnt_q <= {DVM_ORDER_W{1'b0}};
                        state_q <= ST_SEND_RSP;
                    end else begin
                        dvm_order_cnt_q <= dvm_order_cnt_q + 1'b1;
                    end
                end

                ST_SEND_DAT: begin
                    if (dat_fire) begin
                        if (beat_q == (BEATS - 1)) begin
                            beat_q <= 4'd0;
                            state_q <= ST_SEND_RSP;
                        end else begin
                            beat_q <= beat_q + 1'b1;
                        end
                    end
                end

                ST_SEND_RSP: begin
                    if (rsp_fire)
                        state_q <= ST_IDLE;
                end

                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
