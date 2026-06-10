`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_mn_dvm
// Purpose: MN DVM transaction engine. It broadcasts DVM operations, waits for
//          RN acknowledgements, enforces programmable DVMSync drain, and sends
//          completion responses.
// -----------------------------------------------------------------------------
module chi_mn_dvm #(
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
    output reg [`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] tx_snp_flit,
    input                    tx_snp_lcrdv,

    output                   tx_rsp_valid,
    output     [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv
);
    `include "../common/chi_clog2.vh"
    localparam REQ_W = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam SNP_W = `CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB;
    localparam REQ_SIZE_LSB   = `CHI_REQ_SIZE_LSB(ADDR_WIDTH);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(ADDR_WIDTH);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(ADDR_WIDTH);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(ADDR_WIDTH,TXN_ID_W);
    localparam REQ_QOS_LSB    = `CHI_REQ_QOS_LSB(ADDR_WIDTH,TXN_ID_W,NODE_ID_W);

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

    localparam ST_IDLE        = 3'd0;
    localparam ST_ISSUE_DVM   = 3'd1;
    localparam ST_WAIT_DVM    = 3'd2;
    localparam ST_DRAIN_SYNC  = 3'd3;
    localparam ST_ISSUE_SYNC  = 3'd4;
    localparam ST_WAIT_SYNC   = 3'd5;
    localparam ST_SEND_COMP   = 3'd6;

    wire [5:0]            req_opcode = rx_req_flit[REQ_OPCODE_LSB +: 6];
    wire [TXN_ID_W-1:0]   req_txn_id = rx_req_flit[REQ_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0]  req_src_id = rx_req_flit[REQ_SRC_LSB +: NODE_ID_W];
    wire [QOS_W-1:0]      req_qos    = rx_req_flit[REQ_QOS_LSB +: QOS_W];
    wire                  req_is_dvm = (req_opcode == `CHI_REQ_DVM_OP) ||
                                       (req_opcode == `CHI_REQ_DVM_SYNC);

    wire [3:0]            rsp_opcode = rx_rsp_flit[RSP_OPCODE_LSB +: 4];
    wire [TXN_ID_W-1:0]   rsp_txn_id = rx_rsp_flit[RSP_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0]  rsp_src_id = rx_rsp_flit[RSP_SRC_LSB +: NODE_ID_W];

    wire tracker_alloc_ready;
    wire tracker_busy_unused;
    wire [TXN_ID_W-1:0]  active_txn_id;
    wire [NODE_ID_W-1:0] active_src_id;
    wire [QOS_W-1:0]     active_qos;
    wire [NUM_RN-1:0]    active_send_mask;
    wire [NUM_RN-1:0]    active_wait_mask;
    wire                 tracker_all_sent;
    wire                 tracker_all_acked;
    wire                 tracker_timeout_fire;

    reg [2:0]            state_q;
    reg [ADDR_WIDTH-1:0] req_addr_q;
    reg [2:0]            req_size_q;
    reg                  complete_error_q;
    reg                  unsupported_q;
    reg [TXN_ID_W-1:0]   unsupported_txn_q;
    reg [NODE_ID_W-1:0]  unsupported_src_q;
    reg [QOS_W-1:0]      unsupported_qos_q;
    reg [15:0]           drain_cnt_q;

    reg [NUM_RN-1:0]     selected_onehot;
    reg [NODE_ID_W-1:0]  selected_tgt_id;
    reg                  selected_valid;
    reg [NUM_RN-1:0]     rsp_ack_onehot;
    reg                  rsp_src_in_range;
    integer              scan_i;
    integer              rsp_i;

    wire [NUM_RN-1:0] all_rn_mask = {NUM_RN{1'b1}};
    wire req_accept = (state_q == ST_IDLE) &&
                      rx_req_valid &&
                      tracker_alloc_ready;
    wire tracker_alloc_valid = req_accept && req_is_dvm && dvm_enable;
    wire unsupported_accept = req_accept && (!req_is_dvm || !dvm_enable);

    wire issue_state = (state_q == ST_ISSUE_DVM) ||
                       (state_q == ST_ISSUE_SYNC);
    wire wait_state = (state_q == ST_WAIT_DVM) ||
                      (state_q == ST_WAIT_SYNC);
    wire snp_send_fire = tx_snp_valid && tx_snp_lcrdv;
    wire rsp_ack_fire = rx_rsp_valid &&
                        wait_state &&
                        (rsp_opcode == `CHI_RSP_SNP_RESP) &&
                        (rsp_txn_id == active_txn_id) &&
                        rsp_src_in_range &&
                        (|(active_wait_mask & rsp_ack_onehot));
    wire tx_rsp_fire = tx_rsp_valid && tx_rsp_lcrdv;
    wire [NUM_RN-1:0] send_mask_after =
        snp_send_fire ? (active_send_mask & ~selected_onehot) :
                        active_send_mask;
    wire [NUM_RN-1:0] wait_mask_after =
        rsp_ack_fire ? (active_wait_mask & ~rsp_ack_onehot) :
                       active_wait_mask;
    wire send_done_after = (send_mask_after == {NUM_RN{1'b0}});
    wire ack_done_after = (wait_mask_after == {NUM_RN{1'b0}});
    wire drain_done = (drain_cnt_q == 16'd0);
`ifndef SYNTHESIS
    wire b5_dvm_drain_active = (state_q == ST_DRAIN_SYNC);
    wire b5_dvm_sync_issue =
        (state_q == ST_ISSUE_SYNC) && tx_snp_valid && tx_snp_lcrdv;
    wire b5_dvm_drain_done = drain_done;
`endif
    wire start_sync_zero_drain =
        (state_q == ST_WAIT_DVM) &&
        (tracker_all_acked || ack_done_after) &&
        (cfg_drain_cycles == 16'd0);
    wire start_sync_phase =
        ((state_q == ST_DRAIN_SYNC) && (drain_cnt_q <= 16'd1)) ||
        start_sync_zero_drain;
    wire tracker_clear = tx_rsp_fire;
    wire [TXN_ID_W-1:0] complete_txn_id =
        unsupported_q ? unsupported_txn_q : active_txn_id;
    wire [NODE_ID_W-1:0] complete_tgt_id =
        unsupported_q ? unsupported_src_q : active_src_id;
    wire [QOS_W-1:0] complete_qos =
        unsupported_q ? unsupported_qos_q : active_qos;

    assign rx_req_ready = (state_q == ST_IDLE) && tracker_alloc_ready;
    assign rx_rsp_ready = wait_state || issue_state ||
                          (state_q == ST_IDLE) ||
                          (state_q == ST_SEND_COMP);
    assign rx_req_lcrdv = rx_req_valid && rx_req_ready;
    assign rx_rsp_lcrdv = rx_rsp_valid && rx_rsp_ready;
    assign tx_snp_valid = issue_state && selected_valid;

    always @(*) begin
        selected_valid = 1'b0;
        selected_onehot = {NUM_RN{1'b0}};
        selected_tgt_id = {NODE_ID_W{1'b0}};
        for (scan_i = 0; scan_i < NUM_RN; scan_i = scan_i + 1) begin
            if (!selected_valid && active_send_mask[scan_i]) begin
                selected_valid = 1'b1;
                selected_onehot[scan_i] = 1'b1;
                selected_tgt_id = RN_BASE_ID + scan_i;
            end
        end
    end

    always @(*) begin
        rsp_ack_onehot = {NUM_RN{1'b0}};
        rsp_src_in_range = 1'b0;
        for (rsp_i = 0; rsp_i < NUM_RN; rsp_i = rsp_i + 1) begin
            if (rsp_src_id == (RN_BASE_ID + rsp_i)) begin
                rsp_ack_onehot[rsp_i] = 1'b1;
                rsp_src_in_range = 1'b1;
            end
        end
    end

    always @(*) begin
        tx_snp_flit = {SNP_W{1'b0}};
        tx_snp_flit[SNP_ADDR_LSB +: ADDR_WIDTH] = req_addr_q;
        tx_snp_flit[SNP_SIZE_LSB +: 3] = req_size_q;
        tx_snp_flit[SNP_OPCODE_LSB +: 6] =
            (state_q == ST_ISSUE_SYNC) ? `CHI_SNP_DVM_SYNC : `CHI_SNP_DVM_OP;
        tx_snp_flit[SNP_TXN_LSB +: TXN_ID_W] = active_txn_id;
        tx_snp_flit[SNP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        tx_snp_flit[SNP_TGT_LSB +: NODE_ID_W] = selected_tgt_id;
        tx_snp_flit[SNP_QOS_LSB +: QOS_W] = active_qos;
    end

    assign tx_rsp_valid = (state_q == ST_SEND_COMP);
    assign tx_rsp_flit[RSP_RESP_LSB +: 3] =
        complete_error_q ? 3'd0 : `CHI_RESP_DVM_ACK;
    assign tx_rsp_flit[RSP_RESPERR_LSB +: 2] =
        complete_error_q ? `CHI_RESPERR_SLVERR : `CHI_RESPERR_OK;
    assign tx_rsp_flit[RSP_DBID_LSB +: DBID_W] = {DBID_W{1'b0}};
    assign tx_rsp_flit[RSP_OPCODE_LSB +: 4] = `CHI_RSP_DVM_COMPLETE;
    assign tx_rsp_flit[RSP_TXN_LSB +: TXN_ID_W] = complete_txn_id;
    assign tx_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
    assign tx_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = complete_tgt_id;
    assign tx_rsp_flit[RSP_QOS_LSB +: QOS_W] = complete_qos;

    always @(posedge clk) begin
        if (rstn && (state_q == ST_IDLE) && req_accept) begin
            req_addr_q <= rx_req_flit[REQ_ADDR_LSB +: ADDR_WIDTH];
            req_size_q <= rx_req_flit[REQ_SIZE_LSB +: 3];
            if (unsupported_accept) begin
                unsupported_txn_q <= req_txn_id;
                unsupported_src_q <= req_src_id;
                unsupported_qos_q <= req_qos;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= ST_IDLE;
            complete_error_q <= 1'b0;
            unsupported_q <= 1'b0;
            drain_cnt_q <= 16'd0;
        end else begin
            if (tracker_timeout_fire && (state_q != ST_SEND_COMP)) begin
                state_q <= ST_SEND_COMP;
                complete_error_q <= 1'b1;
                unsupported_q <= 1'b0;
                drain_cnt_q <= 16'd0;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        complete_error_q <= 1'b0;
                        unsupported_q <= 1'b0;
                        drain_cnt_q <= 16'd0;
                        if (req_accept) begin
                            if (unsupported_accept) begin
                                unsupported_q <= 1'b1;
                                complete_error_q <= 1'b1;
                                state_q <= ST_SEND_COMP;
                            end else if (req_opcode == `CHI_REQ_DVM_SYNC) begin
                                if (cfg_drain_cycles == 16'd0) begin
                                    state_q <= ST_ISSUE_SYNC;
                                end else begin
                                    drain_cnt_q <= cfg_drain_cycles;
                                    state_q <= ST_DRAIN_SYNC;
                                end
                            end else begin
                                state_q <= ST_ISSUE_DVM;
                            end
                        end
                    end

                    ST_ISSUE_DVM: begin
                        if (tracker_all_sent || (snp_send_fire && send_done_after))
                            state_q <= ST_WAIT_DVM;
                    end

                    ST_WAIT_DVM: begin
                        if (tracker_all_acked || ack_done_after) begin
                            if (cfg_drain_cycles == 16'd0) begin
                                drain_cnt_q <= 16'd0;
                                state_q <= ST_ISSUE_SYNC;
                            end else begin
                                drain_cnt_q <= cfg_drain_cycles;
                                state_q <= ST_DRAIN_SYNC;
                            end
                        end
                    end

                    ST_DRAIN_SYNC: begin
                        if (drain_done) begin
                            drain_cnt_q <= 16'd0;
                            state_q <= ST_ISSUE_SYNC;
                        end else if (drain_cnt_q == 16'd1) begin
                            drain_cnt_q <= 16'd0;
                            state_q <= ST_ISSUE_SYNC;
                        end else begin
                            drain_cnt_q <= drain_cnt_q - 1'b1;
                        end
                    end

                    ST_ISSUE_SYNC: begin
                        if (tracker_all_sent || (snp_send_fire && send_done_after))
                            state_q <= ST_WAIT_SYNC;
                    end

                    ST_WAIT_SYNC: begin
                        if (tracker_all_acked || ack_done_after)
                            state_q <= ST_SEND_COMP;
                    end

                    ST_SEND_COMP: begin
                        if (tx_rsp_fire)
                            state_q <= ST_IDLE;
                    end

                    default: begin
                        state_q <= ST_IDLE;
                    end
                endcase
            end
        end
    end

    chi_mn_dvm_tracker #(
        .NUM_RN(NUM_RN),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_dvm_tracker (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .alloc_valid(tracker_alloc_valid),
        .alloc_ready(tracker_alloc_ready),
        .alloc_txn_id(req_txn_id),
        .alloc_src_id(req_src_id),
        .alloc_qos(req_qos),
        .alloc_mask(all_rn_mask),
        .phase_start_valid(start_sync_phase),
        .phase_mask(all_rn_mask),
        .mark_sent_valid(snp_send_fire),
        .mark_sent_onehot(selected_onehot),
        .mark_ack_valid(rsp_ack_fire),
        .mark_ack_onehot(rsp_ack_onehot),
        .complete_clear(tracker_clear),
        .busy(tracker_busy_unused),
        .active_txn_id(active_txn_id),
        .active_src_id(active_src_id),
        .active_qos(active_qos),
        .active_send_mask(active_send_mask),
        .active_wait_mask(active_wait_mask),
        .all_sent(tracker_all_sent),
        .all_acked(tracker_all_acked),
        .timeout_fire(tracker_timeout_fire)
    );

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn) begin
            if (rx_rsp_valid && !rsp_ack_fire) begin
                $display("chi_mn_dvm unexpected DVM response src %0d txn %0h",
                         rsp_src_id, rsp_txn_id);
                $stop;
            end
            if (tracker_timeout_fire) begin
                $display("chi_mn_dvm timeout txn %0h", active_txn_id);
            end
        end
    end
    // synthesis translate_on
endmodule
