`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_mn_dvm
// Purpose: MN DVM transaction engine (IHI0050H chapter B8), one DVMOp at a
//          time:
//            DVMOp -> DBIDResp -> NonCopyBackWriteData (payload Data[63:0])
//            -> SnpDVMOp Part 1 + Part 2 to every other RN -> SnpResp from
//            each -> Comp.
//          A Sync waits cfg_drain_cycles before its snoops. The MN does not
//          snoop the requester and never adds a Sync of its own.
// -----------------------------------------------------------------------------
module chi_mn_dvm #(
    parameter NODE_ID        = 0,
    parameter RN_BASE_ID     = 0,
    parameter NUM_RN         = `CHI_DEFAULT_NUM_RN,
    parameter ADDR_WIDTH     = `CHI_DEFAULT_ADDR_W,
    // CHI DAT channel data width.
    parameter DAT_DATA_W     = `CHI_DEFAULT_DAT_DATA_W,
    parameter NODE_ID_W      = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W       = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W          = `CHI_DEFAULT_QOS_W,
    parameter DBID_W         = `CHI_DEFAULT_DBID_W,
    parameter TIMEOUT_CYCLES = 1024,
    parameter FUNCTIONAL_TIMEOUT = 0
)(
    input                    clk,
    input                    rstn,
    input                    dvm_enable,
    input      [15:0]        cfg_drain_cycles,

    input                    rx_req_valid,
    input      [`CHI_REQ_W(NODE_ID_W)-1:0] rx_req_flit,
    output                   rx_req_ready,
    output                   rx_req_lcrdv,

    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_ready,
    output                   rx_rsp_lcrdv,

    input                    rx_dat_valid,
    input      [`CHI_DAT_W(DAT_DATA_W,NODE_ID_W)-1:0] rx_dat_flit,
    output                   rx_dat_ready,

    output                   tx_snp_valid,
    output reg [`CHI_SNP_W(NODE_ID_W)-1:0] tx_snp_flit,
    output     [NODE_ID_W-1:0] tx_snp_tgt_id,
    input                    tx_snp_lcrdv,

    output                   tx_rsp_valid,
    output reg [`CHI_RSP_W(NODE_ID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv,
    output                   watchdog_event,
    // A DVM transaction is in progress.
    output                   busy
);
    `CHI_FLIT_PARAM_CHECK(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W,QOS_W,DAT_DATA_W)
    `include "../common/chi_clog2.vh"
    localparam REQ_W = `CHI_REQ_W(NODE_ID_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W);
    localparam SNP_W = `CHI_SNP_W(NODE_ID_W);
    localparam REQ_AW = `CHI_REQ_ADDR_W;
    localparam SNP_AW = `CHI_SNP_ADDR_W;
    localparam PAYLOAD_W = 8 * `CHI_DVM_PAYLOAD_BYTES;
    localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB(NODE_ID_W);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(NODE_ID_W);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(NODE_ID_W);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(NODE_ID_W);
    localparam REQ_QOS_LSB    = `CHI_REQ_QOS_LSB(NODE_ID_W);

    localparam SNP_ADDR_LSB    = `CHI_SNP_ADDR_LSB(NODE_ID_W);
    localparam SNP_OPCODE_LSB  = `CHI_SNP_OPCODE_LSB(NODE_ID_W);
    localparam SNP_TXN_LSB     = `CHI_SNP_TXN_LSB(NODE_ID_W);
    localparam SNP_SRC_LSB     = `CHI_SNP_SRC_LSB(NODE_ID_W);
    localparam SNP_QOS_LSB     = `CHI_SNP_QOS_LSB(NODE_ID_W);
    localparam SNP_FWD_NID_LSB = `CHI_SNP_FWD_NID_LSB(NODE_ID_W);
    localparam SNP_FWD_TXN_LSB = `CHI_SNP_FWD_TXN_LSB(NODE_ID_W);

    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(NODE_ID_W);

    localparam DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_OPCODE_LSB  = `CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W);

    // One DVMOp at a time, so one DBID.
    localparam [DBID_W-1:0] MN_DBID = {DBID_W{1'b0}};

    localparam ST_IDLE       = 3'd0;
    localparam ST_SEND_DBID  = 3'd1;
    localparam ST_WAIT_DATA  = 3'd2;
    localparam ST_DRAIN_SYNC = 3'd3;
    localparam ST_ISSUE      = 3'd4;
    localparam ST_WAIT_ACK   = 3'd5;
    localparam ST_SEND_COMP  = 3'd6;

    wire [`CHI_REQ_OPCODE_W-1:0] req_opcode = rx_req_flit[REQ_OPCODE_LSB +: `CHI_REQ_OPCODE_W];
    wire [TXN_ID_W-1:0]   req_txn_id = rx_req_flit[REQ_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0]  req_src_id = rx_req_flit[REQ_SRC_LSB +: NODE_ID_W];
    wire [QOS_W-1:0]      req_qos    = rx_req_flit[REQ_QOS_LSB +: QOS_W];
    wire                  req_is_dvm = (req_opcode == `CHI_REQ_DVM_OP);

    wire [`CHI_RSP_OPCODE_W-1:0] rsp_opcode =
        rx_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W];
    wire [TXN_ID_W-1:0]   rsp_txn_id = rx_rsp_flit[RSP_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0]  rsp_src_id = rx_rsp_flit[RSP_SRC_LSB +: NODE_ID_W];

    wire [3:0]            dat_opcode = rx_dat_flit[DAT_OPCODE_LSB +: 4];
    wire [TXN_ID_W-1:0]   dat_txn_id = rx_dat_flit[DAT_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0]  dat_src_id = rx_dat_flit[DAT_SRC_LSB +: NODE_ID_W];
    wire [1:0]            dat_resp_err = rx_dat_flit[DAT_RESPERR_LSB +: 2];

    wire tracker_alloc_ready;
    wire tracker_busy;
    wire [TXN_ID_W-1:0]  active_txn_id;
    wire [NODE_ID_W-1:0] active_src_id;
    wire [QOS_W-1:0]     active_qos;
    wire [NUM_RN-1:0]    active_send_mask;
    wire [NUM_RN-1:0]    active_wait_mask;
    wire                 tracker_all_sent;
    wire                 tracker_all_acked;
    wire                 tracker_timeout_fire;

    reg [2:0]            state_q;
    reg [REQ_AW-1:0]     req_addr_q;
    reg [PAYLOAD_W-1:0]  payload_q;
    // The second SnpDVMOp part to the selected RN is next.
    reg                  part_q;
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
    reg [NUM_RN-1:0]     req_src_onehot;
    integer              scan_i;
    integer              rsp_i;
    integer              src_i;

    wire [NUM_RN-1:0] all_rn_mask = {NUM_RN{1'b1}};
    wire req_accept = (state_q == ST_IDLE) &&
                      rx_req_valid &&
                      tracker_alloc_ready;
    // A DVMOp always gets DBIDResp and sends its data; with DVM disabled it
    // then completes with an error and snoops nobody.
    wire tracker_alloc_valid = req_accept && req_is_dvm;
    wire unsupported_accept = req_accept && !req_is_dvm;

    wire is_sync = (req_addr_q[`CHI_DVM_TYPE_LSB +: 3] == `CHI_DVM_TYPE_SYNC);
    wire snp_send_fire = tx_snp_valid && tx_snp_lcrdv;
    // Both parts are out once Part 2 is sent.
    wire snp_part2_fire = snp_send_fire && part_q;
    wire rsp_ack_fire = rx_rsp_valid &&
                        ((state_q == ST_ISSUE) || (state_q == ST_WAIT_ACK)) &&
                        (rsp_opcode == `CHI_RSP_SNP_RESP) &&
                        // Snoop TxnID = index of the snooped RN (see below).
                        (rsp_txn_id == (rsp_src_id - RN_BASE_ID)) &&
                        rsp_src_in_range &&
                        (|(active_wait_mask & rsp_ack_onehot));
    wire dat_fire = rx_dat_valid && rx_dat_ready;
    wire dat_match = (dat_opcode == `CHI_DAT_OPCODE_WB_DATA) &&
                     (dat_txn_id == MN_DBID) &&
                     (dat_src_id == active_src_id);
    wire tx_rsp_fire = tx_rsp_valid && tx_rsp_lcrdv;
    wire [NUM_RN-1:0] send_mask_after =
        snp_part2_fire ? (active_send_mask & ~selected_onehot) :
                         active_send_mask;
    wire [NUM_RN-1:0] wait_mask_after =
        rsp_ack_fire ? (active_wait_mask & ~rsp_ack_onehot) :
                       active_wait_mask;
    wire send_done_after = (send_mask_after == {NUM_RN{1'b0}});
    wire ack_done_after = (wait_mask_after == {NUM_RN{1'b0}});
    wire drain_done = (drain_cnt_q == 16'd0);
`ifndef SYNTHESIS
    wire b5_dvm_drain_active = (state_q == ST_DRAIN_SYNC);
    wire b5_dvm_sync_issue = (state_q == ST_ISSUE) && is_sync && snp_send_fire;
    wire b5_dvm_drain_done = drain_done;
`endif
    wire tracker_clear = tx_rsp_fire && (state_q == ST_SEND_COMP);
    wire [TXN_ID_W-1:0] complete_txn_id =
        unsupported_q ? unsupported_txn_q : active_txn_id;
    wire [NODE_ID_W-1:0] complete_tgt_id =
        unsupported_q ? unsupported_src_q : active_src_id;
    wire [QOS_W-1:0] complete_qos =
        unsupported_q ? unsupported_qos_q : active_qos;

    assign rx_req_ready = (state_q == ST_IDLE) && tracker_alloc_ready;
    assign rx_rsp_ready = 1'b1;
    assign rx_dat_ready = (state_q == ST_WAIT_DATA);
    assign rx_req_lcrdv = rx_req_valid && rx_req_ready;
    assign rx_rsp_lcrdv = rx_rsp_valid && rx_rsp_ready;
    assign tx_snp_valid = (state_q == ST_ISSUE) && selected_valid;
    assign tx_snp_tgt_id = selected_tgt_id;

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
        req_src_onehot = {NUM_RN{1'b0}};
        for (rsp_i = 0; rsp_i < NUM_RN; rsp_i = rsp_i + 1) begin
            if (rsp_src_id == (RN_BASE_ID + rsp_i)) begin
                rsp_ack_onehot[rsp_i] = 1'b1;
                rsp_src_in_range = 1'b1;
            end
        end
        for (src_i = 0; src_i < NUM_RN; src_i = src_i + 1) begin
            if (req_src_id == (RN_BASE_ID + src_i))
                req_src_onehot[src_i] = 1'b1;
        end
    end

    // SnpDVMOp payload (Table B8.10, Req_Addr_Width 44). SNP.Addr[x] of
    // Part 1 is REQ.Addr[x+3] up to x = 37 (Leaf); Part 1 Addr[40:38] carry
    // VA[48:46] = Data[46:44]. SNP.Addr[x] of Part 2 is Data[x+3]. Range goes
    // in Part 1 FwdNID[0], Num[4:0] in Part 2 FwdNID[4:0], and VMID[15:8] in
    // Part 1 VMIDExt (Table B8.14, B13.8).
    always @(*) begin
        tx_snp_flit = {SNP_W{1'b0}};
        if (!part_q) begin
            tx_snp_flit[SNP_ADDR_LSB +: 38] = {req_addr_q[40:4], 1'b0};
            tx_snp_flit[SNP_ADDR_LSB + 38 +: 3] = payload_q[46:44];
            tx_snp_flit[SNP_FWD_NID_LSB] = req_addr_q[41];
            tx_snp_flit[SNP_FWD_TXN_LSB +: 8] = payload_q[63:56];
        end else begin
            tx_snp_flit[SNP_ADDR_LSB +: SNP_AW] =
                {payload_q[SNP_AW+2:4], 1'b1};
            tx_snp_flit[SNP_FWD_NID_LSB +: 5] =
                {req_addr_q[42], payload_q[3:0]};
        end
        tx_snp_flit[SNP_OPCODE_LSB +: `CHI_SNP_OPCODE_W] = `CHI_SNP_DVM_OP;
        // The MN runs one DVM at a time, so the snooped RN's index is a
        // TxnID unique among its open snoops (B2.5.1). Both parts share it.
        tx_snp_flit[SNP_TXN_LSB +: TXN_ID_W] = selected_tgt_id - RN_BASE_ID;
        tx_snp_flit[SNP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        tx_snp_flit[SNP_QOS_LSB +: QOS_W] = active_qos;
    end

    // DBIDResp, then Comp (Table B8.2: Resp zero; RespErr OK or SLVERR).
    assign tx_rsp_valid = (state_q == ST_SEND_DBID) ||
                          (state_q == ST_SEND_COMP);
    always @(*) begin
        tx_rsp_flit = {RSP_W{1'b0}};
        tx_rsp_flit[RSP_RESPERR_LSB +: 2] =
            ((state_q == ST_SEND_COMP) && complete_error_q) ?
            `CHI_RESPERR_SLVERR : `CHI_RESPERR_OK;
        tx_rsp_flit[RSP_DBID_LSB +: DBID_W] = MN_DBID;
        tx_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] =
            (state_q == ST_SEND_DBID) ? `CHI_RSP_DBID : `CHI_RSP_COMP;
        tx_rsp_flit[RSP_TXN_LSB +: TXN_ID_W] = complete_txn_id;
        tx_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        tx_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = complete_tgt_id;
        tx_rsp_flit[RSP_QOS_LSB +: QOS_W] = complete_qos;
    end

    always @(posedge clk) begin
        if (rstn && req_accept) begin
            req_addr_q <= rx_req_flit[REQ_ADDR_LSB +: REQ_AW];
            if (unsupported_accept) begin
                unsupported_txn_q <= req_txn_id;
                unsupported_src_q <= req_src_id;
                unsupported_qos_q <= req_qos;
            end
        end
        if (rstn && dat_fire && dat_match)
            payload_q <= rx_dat_flit[DAT_DATA_LSB +: PAYLOAD_W];
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= ST_IDLE;
            part_q <= 1'b0;
            complete_error_q <= 1'b0;
            unsupported_q <= 1'b0;
            drain_cnt_q <= 16'd0;
        end else begin
            if (tracker_timeout_fire && (state_q != ST_SEND_COMP)) begin
                state_q <= ST_SEND_COMP;
                part_q <= 1'b0;
                complete_error_q <= 1'b1;
                unsupported_q <= 1'b0;
                drain_cnt_q <= 16'd0;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        complete_error_q <= 1'b0;
                        unsupported_q <= 1'b0;
                        part_q <= 1'b0;
                        drain_cnt_q <= 16'd0;
                        if (req_accept) begin
                            if (unsupported_accept) begin
                                unsupported_q <= 1'b1;
                                complete_error_q <= 1'b1;
                                state_q <= ST_SEND_COMP;
                            end else begin
                                complete_error_q <= !dvm_enable;
                                state_q <= ST_SEND_DBID;
                            end
                        end
                    end

                    ST_SEND_DBID: begin
                        if (tx_rsp_fire)
                            state_q <= ST_WAIT_DATA;
                    end

                    ST_WAIT_DATA: begin
                        if (dat_fire && dat_match) begin
                            if (dat_resp_err != `CHI_RESPERR_OK)
                                complete_error_q <= 1'b1;
                            if (tracker_all_sent) begin
                                state_q <= ST_SEND_COMP;
                            end else if (is_sync &&
                                         (cfg_drain_cycles != 16'd0)) begin
                                drain_cnt_q <= cfg_drain_cycles;
                                state_q <= ST_DRAIN_SYNC;
                            end else begin
                                state_q <= ST_ISSUE;
                            end
                        end
                    end

                    ST_DRAIN_SYNC: begin
                        if (drain_cnt_q <= 16'd1) begin
                            drain_cnt_q <= 16'd0;
                            state_q <= ST_ISSUE;
                        end else begin
                            drain_cnt_q <= drain_cnt_q - 1'b1;
                        end
                    end

                    ST_ISSUE: begin
                        if (snp_send_fire)
                            part_q <= !part_q;
                        if (snp_part2_fire && send_done_after)
                            state_q <= ack_done_after ? ST_SEND_COMP :
                                                        ST_WAIT_ACK;
                    end

                    ST_WAIT_ACK: begin
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
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .FUNCTIONAL_TIMEOUT(FUNCTIONAL_TIMEOUT)
    ) u_dvm_tracker (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .alloc_valid(tracker_alloc_valid),
        .alloc_ready(tracker_alloc_ready),
        .alloc_txn_id(req_txn_id),
        .alloc_src_id(req_src_id),
        .alloc_qos(req_qos),
        // Every RN but the requester; nobody when DVM is disabled.
        .alloc_mask(dvm_enable ? (all_rn_mask & ~req_src_onehot) :
                                 {NUM_RN{1'b0}}),
        .phase_start_valid(1'b0),
        .phase_mask({NUM_RN{1'b0}}),
        .mark_sent_valid(snp_part2_fire),
        .mark_sent_onehot(selected_onehot),
        .mark_ack_valid(rsp_ack_fire),
        .mark_ack_onehot(rsp_ack_onehot),
        .complete_clear(tracker_clear),
        .busy(tracker_busy),
        .active_txn_id(active_txn_id),
        .active_src_id(active_src_id),
        .active_qos(active_qos),
        .active_send_mask(active_send_mask),
        .active_wait_mask(active_wait_mask),
        .all_sent(tracker_all_sent),
        .all_acked(tracker_all_acked),
        .timeout_fire(tracker_timeout_fire),
        .watchdog(watchdog_event)
    );

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn) begin
            if (rx_rsp_valid && !rsp_ack_fire) begin
                $display("chi_mn_dvm unexpected DVM response src %0d txn %0h",
                         rsp_src_id, rsp_txn_id);
                $stop;
            end
            if (dat_fire && !dat_match) begin
                $display("chi_mn_dvm unexpected DAT opcode %0h src %0d txn %0h",
                         dat_opcode, dat_src_id, dat_txn_id);
                $stop;
            end
            if (tracker_timeout_fire) begin
                $display("chi_mn_dvm timeout txn %0h", active_txn_id);
            end
            if (watchdog_event) begin
                $display("chi_mn_dvm watchdog: DVM txn %0h still outstanding", active_txn_id);
            end
        end
    end
    // synthesis translate_on

    assign busy = (state_q != ST_IDLE) || tracker_busy;
endmodule
