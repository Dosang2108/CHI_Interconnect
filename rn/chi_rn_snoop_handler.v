`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_rn_snoop_handler
// Purpose: RN-F snoop responder. It performs synchronous cache snoop lookups,
//          returns SnpResp/SnpRespData, and updates or invalidates local cache
//          state as required by the snoop opcode. SnpDVMOp comes in two
//          parts (B8.2.3.2); a separate collector with DVM_SLOTS entries
//          takes them without blocking other snoops and answers one SnpResp
//          once both parts are in.
// -----------------------------------------------------------------------------
module chi_rn_snoop_handler #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter LINE_BYTES = 64,
    parameter DVM_ORDER_CYCLES = 2,
    // SnpDVMOp transactions accepted at once; at least 2 (B8.2.3.2).
    parameter DVM_SLOTS = 2,
    parameter USE_EXTERNAL_L1_SNOOP = 0
)(
    input                    clk,
    input                    rstn,
    output                   busy,
    input                    rx_snp_valid,
    input      [`CHI_SNP_W(NODE_ID_W)-1:0] rx_snp_flit,
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
    output     [`CHI_SNP_OPCODE_W-1:0] cache_snoop_opcode,
    output                   cache_snoop_commit,

    output                   l1_snoop_valid,
    input                    l1_snoop_ready,
    output                   l1_snoop_invalidate,
    output     [ADDR_WIDTH-1:0] l1_snoop_addr,
    input                    l1_snoop_result_valid,
    input                    l1_snoop_hit,
    input                    l1_snoop_dirty,
    input      [LINE_BYTES*8-1:0] l1_snoop_data,

    output                   tx_rsp_valid,
    input                    tx_rsp_ready,
    output reg [`CHI_RSP_W(NODE_ID_W)-1:0] tx_rsp_flit,

    output                   tx_dat_valid,
    input                    tx_dat_ready,
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] tx_dat_flit
);
    `include "../common/chi_clog2.vh"
    localparam SNP_ADDR_LSB   = `CHI_SNP_ADDR_LSB(NODE_ID_W);
    localparam SNP_OPCODE_LSB = `CHI_SNP_OPCODE_LSB(NODE_ID_W);
    localparam SNP_TXN_LSB    = `CHI_SNP_TXN_LSB(NODE_ID_W);
    localparam SNP_SRC_LSB    = `CHI_SNP_SRC_LSB(NODE_ID_W);
    localparam SNP_QOS_LSB    = `CHI_SNP_QOS_LSB(NODE_ID_W);
    localparam SNP_FWD_NID_LSB =
        `CHI_SNP_FWD_NID_LSB(NODE_ID_W);
    localparam SNP_FWD_TXN_LSB =
        `CHI_SNP_FWD_TXN_LSB(NODE_ID_W);

    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(NODE_ID_W);
    localparam RSP_FWD_STATE_LSB = `CHI_RSP_FWD_STATE_LSB(NODE_ID_W);

    localparam DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_BE_LSB      = `CHI_DAT_BE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_OPCODE_LSB  = `CHI_DAT_OPCODE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_QOS_LSB     = `CHI_DAT_QOS_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_HOME_NID_LSB = `CHI_DAT_HOME_NID_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_FWD_STATE_LSB = `CHI_DAT_FWD_STATE_LSB(DATA_WIDTH,NODE_ID_W);

    localparam BE_W = DATA_WIDTH / 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam DATAID_SHIFT = `CHI_DAT_DATAID_SHIFT(DATA_WIDTH);
    localparam DVM_ORDER_W = (DVM_ORDER_CYCLES <= 1) ? 1 :
                             `CHI_CLOG2(DVM_ORDER_CYCLES + 1);
    localparam [DVM_ORDER_W-1:0] DVM_ORDER_VALUE = DVM_ORDER_CYCLES;
    localparam ST_IDLE = 3'd0;
    localparam ST_LOOKUP = 3'd1;
    localparam ST_WAIT_CACHE = 3'd2;
    localparam ST_SEND_DAT = 3'd4;
    localparam ST_SEND_RSP = 3'd5;

    reg [2:0]           state_q;
    reg [`CHI_SNP_W(NODE_ID_W)-1:0] snp_flit_q;
    reg [LINE_WIDTH-1:0] data_q;
    reg                  hit_q;
    reg [3:0]            beat_q;
    reg                  l1_result_pending_q;
    reg                  l1_hit_q;
    reg                  l1_dirty_q;
    reg [LINE_WIDTH-1:0] l1_data_q;
    reg                  forward_data_q;
    // SnpRespDataFwded: after the CompData to the requester, the same line
    // goes to the home (forward_copy_q marks that second pass) and no
    // SnpRespFwded is sent.
    reg                  forward_home_q;
    reg                  forward_copy_q;

    // SNP Addr is Addr[43:3].
    wire [ADDR_WIDTH-1:0] snp_addr = {rx_snp_flit[SNP_ADDR_LSB +: ADDR_WIDTH-3], 3'b000};
    wire [`CHI_SNP_OPCODE_W-1:0] snp_opcode = rx_snp_flit[SNP_OPCODE_LSB +: `CHI_SNP_OPCODE_W];
    wire [ADDR_WIDTH-1:0] latched_addr = {snp_flit_q[SNP_ADDR_LSB +: ADDR_WIDTH-3], 3'b000};
    wire [`CHI_SNP_OPCODE_W-1:0] latched_opcode = snp_flit_q[SNP_OPCODE_LSB +: `CHI_SNP_OPCODE_W];
    wire [`CHI_SNP_OPCODE_W-1:0] latched_base_opcode =
        (latched_opcode == `CHI_SNP_SHARED_FWD) ? `CHI_SNP_SHARED :
        ((latched_opcode == `CHI_SNP_UNIQUE_FWD) ? `CHI_SNP_UNIQUE :
         latched_opcode);
    wire                 snp_is_dvm = (snp_opcode == `CHI_SNP_DVM_OP);
    wire                 latched_is_fwd =
        (latched_opcode == `CHI_SNP_SHARED_FWD) ||
        (latched_opcode == `CHI_SNP_UNIQUE_FWD);
    wire                 accept_snp = (state_q == ST_IDLE) && rx_snp_valid &&
                                      !snp_is_dvm;
    wire                 dat_fire = tx_dat_valid && tx_dat_ready;
    wire                 main_rsp_valid = (state_q == ST_SEND_RSP);
    // The main FSM owns the RSP port when it has a response.
    wire                 rsp_fire = main_rsp_valid && tx_rsp_ready;
    wire [3:0]           current_beat = beat_q;
    wire [TXN_ID_W-1:0]  latched_txn_id = snp_flit_q[SNP_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0] latched_src_id = snp_flit_q[SNP_SRC_LSB +: NODE_ID_W];
    wire [QOS_W-1:0]     latched_qos = snp_flit_q[SNP_QOS_LSB +: QOS_W];
    wire [NODE_ID_W-1:0] latched_fwd_nid =
        snp_flit_q[SNP_FWD_NID_LSB +: NODE_ID_W];
    wire [TXN_ID_W-1:0]  latched_fwd_txn_id =
        snp_flit_q[SNP_FWD_TXN_LSB +: TXN_ID_W];
    // Only a dirty line is forwarded. SnpUniqueFwd passes the dirty line to
    // the requester (Table B4.59: CompData_UD_PD, SnpResp_I_Fwded_UD_PD);
    // SnpSharedFwd forwards it clean (CompData_SC).
    wire [2:0]           fwd_state =
        (latched_opcode == `CHI_SNP_UNIQUE_FWD) ? `CHI_COMPDATA_RESP_UD_PD :
                                                  `CHI_COMPDATA_RESP_SC;
    // An external L1 cleans its line on SnpSharedFwd, so the dirty data must
    // also reach the home (SnpRespDataFwded instead of SnpRespFwded).
    wire                 fwd_to_home =
        (USE_EXTERNAL_L1_SNOOP != 0) && (latched_opcode == `CHI_SNP_SHARED_FWD);
    wire [`CHI_DAT_QOS_W-1:0] latched_qos_dat;
    wire [`CHI_DAT_DATAID_W-1:0] current_data_id = current_beat << DATAID_SHIFT;
    wire                 use_external_l1 = (USE_EXTERNAL_L1_SNOOP != 0);
    wire                 lookup_ready = !use_external_l1 || l1_snoop_ready;
    wire                 lookup_fire =
        (state_q == ST_LOOKUP) && lookup_ready;
    wire                 l1_result_available =
        l1_result_pending_q || l1_snoop_result_valid;
    wire                 combined_cache_result_valid =
        use_external_l1 ? l1_result_available : cache_result_valid;
    wire                 l1_result_hit =
        l1_result_pending_q ? l1_hit_q : l1_snoop_hit;
    wire                 l1_result_dirty =
        l1_result_pending_q ? l1_dirty_q : l1_snoop_dirty;
    wire [LINE_WIDTH-1:0] l1_result_data =
        l1_result_pending_q ? l1_data_q : l1_snoop_data;
    wire                 selected_cache_hit =
        use_external_l1 ? l1_result_hit : cache_hit;
    wire                 selected_cache_dirty =
        use_external_l1 ? l1_result_dirty : cache_dirty;
    wire [2:0]           selected_cache_state =
        use_external_l1 ?
        (l1_result_hit ? (l1_result_dirty ? `CHI_STATE_UD : `CHI_STATE_SC) :
         `CHI_STATE_I) :
        cache_state;
    wire                 selected_cache_send_data =
        use_external_l1 ? selected_cache_dirty : cache_send_data;

    generate
        if (QOS_W >= `CHI_DAT_QOS_W) begin : gen_dat_qos_full
            assign latched_qos_dat = latched_qos[`CHI_DAT_QOS_W-1:0];
        end else begin : gen_dat_qos_pad
            assign latched_qos_dat =
                {{(`CHI_DAT_QOS_W-QOS_W){1'b0}}, latched_qos};
        end
    endgenerate

    // -------------------------------------------------------------------
    // SnpDVMOp collector. Both parts carry the same SrcID and TxnID and
    // SNP.Addr[0] names the part; they may arrive in either order.
    // -------------------------------------------------------------------
    reg [DVM_SLOTS-1:0]           dvm_v_q;
    reg [DVM_SLOTS*2-1:0]         dvm_parts_q;
    reg [DVM_SLOTS*NODE_ID_W-1:0] dvm_src_q;
    reg [DVM_SLOTS*TXN_ID_W-1:0]  dvm_txn_q;
    reg [DVM_SLOTS*QOS_W-1:0]     dvm_qos_q;
    reg [DVM_ORDER_W-1:0]         dvm_order_cnt_q;
    reg                           dvm_match_r;
    reg                           dvm_free_r;
    reg [DVM_SLOTS-1:0]           dvm_sel_onehot_r;
    reg                           dvm_done_r;
    reg [DVM_SLOTS-1:0]           dvm_done_onehot_r;
    reg [NODE_ID_W-1:0]           dvm_done_src_r;
    reg [TXN_ID_W-1:0]            dvm_done_txn_r;
    reg [QOS_W-1:0]               dvm_done_qos_r;
    integer                       dvm_i;

    wire                 snp_part = rx_snp_flit[SNP_ADDR_LSB];
    wire [TXN_ID_W-1:0]  snp_txn_id = rx_snp_flit[SNP_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0] snp_src_id = rx_snp_flit[SNP_SRC_LSB +: NODE_ID_W];
    wire                 dvm_accept = rx_snp_valid && snp_is_dvm &&
                                      (dvm_match_r || dvm_free_r);
    // Each SnpDVMOp is answered once the RN's DVM work is done, modelled
    // as DVM_ORDER_CYCLES.
    wire                 dvm_rsp_valid =
        dvm_done_r && (dvm_order_cnt_q >= DVM_ORDER_VALUE);
    wire                 dvm_rsp_fire =
        dvm_rsp_valid && !main_rsp_valid && tx_rsp_ready;

    always @(*) begin
        // A part completes the slot of its transaction, else a free slot
        // takes it.
        dvm_match_r = 1'b0;
        dvm_free_r = 1'b0;
        dvm_sel_onehot_r = {DVM_SLOTS{1'b0}};
        for (dvm_i = 0; dvm_i < DVM_SLOTS; dvm_i = dvm_i + 1) begin
            if (!dvm_match_r && dvm_v_q[dvm_i] &&
                (dvm_src_q[dvm_i*NODE_ID_W +: NODE_ID_W] == snp_src_id) &&
                (dvm_txn_q[dvm_i*TXN_ID_W +: TXN_ID_W] == snp_txn_id) &&
                !dvm_parts_q[dvm_i*2 + snp_part]) begin
                dvm_match_r = 1'b1;
                dvm_sel_onehot_r[dvm_i] = 1'b1;
            end
        end
        for (dvm_i = 0; dvm_i < DVM_SLOTS; dvm_i = dvm_i + 1) begin
            if (!dvm_match_r && !dvm_free_r && !dvm_v_q[dvm_i]) begin
                dvm_free_r = 1'b1;
                dvm_sel_onehot_r[dvm_i] = 1'b1;
            end
        end

        dvm_done_r = 1'b0;
        dvm_done_onehot_r = {DVM_SLOTS{1'b0}};
        dvm_done_src_r = {NODE_ID_W{1'b0}};
        dvm_done_txn_r = {TXN_ID_W{1'b0}};
        dvm_done_qos_r = {QOS_W{1'b0}};
        for (dvm_i = 0; dvm_i < DVM_SLOTS; dvm_i = dvm_i + 1) begin
            if (!dvm_done_r && dvm_v_q[dvm_i] &&
                (dvm_parts_q[dvm_i*2 +: 2] == 2'b11)) begin
                dvm_done_r = 1'b1;
                dvm_done_onehot_r[dvm_i] = 1'b1;
                dvm_done_src_r = dvm_src_q[dvm_i*NODE_ID_W +: NODE_ID_W];
                dvm_done_txn_r = dvm_txn_q[dvm_i*TXN_ID_W +: TXN_ID_W];
                dvm_done_qos_r = dvm_qos_q[dvm_i*QOS_W +: QOS_W];
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dvm_v_q <= {DVM_SLOTS{1'b0}};
            dvm_parts_q <= {DVM_SLOTS*2{1'b0}};
            dvm_src_q <= {DVM_SLOTS*NODE_ID_W{1'b0}};
            dvm_txn_q <= {DVM_SLOTS*TXN_ID_W{1'b0}};
            dvm_qos_q <= {DVM_SLOTS*QOS_W{1'b0}};
            dvm_order_cnt_q <= {DVM_ORDER_W{1'b0}};
        end else begin
            if (dvm_rsp_fire)
                dvm_order_cnt_q <= {DVM_ORDER_W{1'b0}};
            else if (dvm_done_r && (dvm_order_cnt_q < DVM_ORDER_VALUE))
                dvm_order_cnt_q <= dvm_order_cnt_q + 1'b1;

            for (dvm_i = 0; dvm_i < DVM_SLOTS; dvm_i = dvm_i + 1) begin
                if (dvm_rsp_fire && dvm_done_onehot_r[dvm_i]) begin
                    dvm_v_q[dvm_i] <= 1'b0;
                    dvm_parts_q[dvm_i*2 +: 2] <= 2'b00;
                end else if (dvm_accept && dvm_sel_onehot_r[dvm_i]) begin
                    dvm_v_q[dvm_i] <= 1'b1;
                    dvm_parts_q[dvm_i*2 + snp_part] <= 1'b1;
                    dvm_src_q[dvm_i*NODE_ID_W +: NODE_ID_W] <= snp_src_id;
                    dvm_txn_q[dvm_i*TXN_ID_W +: TXN_ID_W] <= snp_txn_id;
                    dvm_qos_q[dvm_i*QOS_W +: QOS_W] <=
                        rx_snp_flit[SNP_QOS_LSB +: QOS_W];
                end
            end
        end
    end

    assign rx_snp_ready = snp_is_dvm ? (dvm_match_r || dvm_free_r) :
                                       (state_q == ST_IDLE);
    assign rx_snp_lcrdv = accept_snp || dvm_accept;
    assign cache_snoop_valid = lookup_fire && !use_external_l1;
    assign cache_snoop_addr = (state_q == ST_IDLE) ? snp_addr : latched_addr;
    assign cache_snoop_opcode = (state_q == ST_IDLE) ?
                                ((snp_opcode == `CHI_SNP_SHARED_FWD) ?
                                 `CHI_SNP_SHARED :
                                 ((snp_opcode == `CHI_SNP_UNIQUE_FWD) ?
                                  `CHI_SNP_UNIQUE : snp_opcode)) :
                                latched_base_opcode;
    // A snoop with data is answered by SnpRespData(Fwded) alone, so it
    // commits on the last beat to the home; any other snoop commits on its
    // SnpResp(Fwded).
    assign cache_snoop_commit =
        (rsp_fire ||
         (dat_fire && (beat_q == (BEATS - 1)) &&
          (!forward_data_q || forward_copy_q))) &&
        !use_external_l1;
    assign l1_snoop_valid = use_external_l1 &&
                            (state_q == ST_LOOKUP);
    assign l1_snoop_invalidate =
        (latched_base_opcode == `CHI_SNP_UNIQUE) ||
        (latched_opcode == `CHI_SNP_INVALID);
    assign l1_snoop_addr = latched_addr;
    assign tx_dat_valid = (state_q == ST_SEND_DAT);
    assign tx_rsp_valid = main_rsp_valid || dvm_rsp_valid;

    always @(*) begin
        tx_rsp_flit = {`CHI_RSP_W(NODE_ID_W){1'b0}};
        // SnpResp carries the snoopee's final state (I or SC here: a dirty
        // line is answered with SnpRespData). SnpRespFwded carries it too:
        // I after SnpUniqueFwd, SD after SnpSharedFwd (the cache keeps the
        // dirty line, Table B4.58 SnpResp_SD_Fwded_SC).
        tx_rsp_flit[RSP_RESP_LSB +: 3]        =
            forward_data_q ?
            ((latched_opcode == `CHI_SNP_UNIQUE_FWD) ?
             `CHI_COMPDATA_RESP_I : `CHI_SNPRESP_SD) :
            ((hit_q && (latched_base_opcode == `CHI_SNP_SHARED)) ?
             `CHI_COMPDATA_RESP_SC : `CHI_COMPDATA_RESP_I);
        tx_rsp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_OK;
        tx_rsp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        tx_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] =
            forward_data_q ? `CHI_RSP_SNP_RESP_FWD : `CHI_RSP_SNP_RESP;
        // SnpRespFwded names the state sent to the requester in FwdState.
        if (forward_data_q)
            tx_rsp_flit[RSP_FWD_STATE_LSB +: 3] = fwd_state;
        tx_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = latched_txn_id;
        tx_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = node_id;
        tx_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = latched_src_id;
        tx_rsp_flit[RSP_QOS_LSB +: QOS_W]     = latched_qos;
        if (!main_rsp_valid) begin
            // SnpResp_I to the MN for a SnpDVMOp (Table B8.2: Resp zero).
            tx_rsp_flit = {`CHI_RSP_W(NODE_ID_W){1'b0}};
            tx_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_SNP_RESP;
            tx_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = dvm_done_txn_r;
            tx_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = node_id;
            tx_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = dvm_done_src_r;
            tx_rsp_flit[RSP_QOS_LSB +: QOS_W]     = dvm_done_qos_r;
        end
    end

    always @(*) begin
        tx_dat_flit = {`CHI_DAT_W(DATA_WIDTH,NODE_ID_W){1'b0}};
        tx_dat_flit[DAT_RESPERR_LSB +: 2]       = `CHI_RESPERR_OK;
        tx_dat_flit[DAT_BE_LSB +: BE_W]         = {BE_W{1'b1}};
        tx_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] =
            data_q[current_beat*DATA_WIDTH +: DATA_WIDTH];
        tx_dat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W] = current_data_id;
        // Forwarded CompData names the snoop's TxnID as its DBID, so the
        // requester's CompAck (TxnID = DBID) reaches the home's snoop entry.
        tx_dat_flit[DAT_DBID_LSB +: DBID_W]     =
            (forward_data_q && !forward_copy_q) ?
            latched_txn_id : {DBID_W{1'b0}};
        tx_dat_flit[DAT_TXN_LSB +: TXN_ID_W]    =
            (forward_data_q && !forward_copy_q) ?
            latched_fwd_txn_id : latched_txn_id;
        tx_dat_flit[DAT_SRC_LSB +: NODE_ID_W]   = node_id;
        tx_dat_flit[DAT_TGT_LSB +: NODE_ID_W]   =
            (forward_data_q && !forward_copy_q) ?
            latched_fwd_nid : latched_src_id;
        // Forwarded CompData carries the requester's state (fwd_state).
        // SnpRespData carries the snoopee's final state and PassDirty: SD
        // after SnpShared (the RN keeps the dirty line), I_PD after
        // SnpUnique/SnpMakeInvalid. SnpRespDataFwded (external L1 only)
        // passes the dirty line to the home: SnpRespData_SC_PD_Fwded_SC.
        tx_dat_flit[DAT_RESP_LSB +: 3]          =
            (forward_data_q && !forward_copy_q) ? fwd_state :
            (forward_data_q ? `CHI_SNPRESP_SC_PD :
             ((latched_base_opcode == `CHI_SNP_SHARED) ?
              `CHI_SNPRESP_SD : `CHI_SNPRESP_I_PD));
        if (forward_data_q && forward_copy_q)
            tx_dat_flit[DAT_FWD_STATE_LSB +: 3] = fwd_state;
        tx_dat_flit[DAT_OPCODE_LSB +: 4]        =
            (forward_data_q && !forward_copy_q) ? `CHI_DAT_OPCODE_RD_DATA :
            (forward_data_q ? `CHI_DAT_OPCODE_SNP_DATA_FWD :
                              `CHI_DAT_OPCODE_SNP_DATA);
        tx_dat_flit[DAT_QOS_LSB +: `CHI_DAT_QOS_W] = latched_qos_dat;
        tx_dat_flit[DAT_HOME_NID_LSB +: NODE_ID_W] = latched_src_id;
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (accept_snp)
                snp_flit_q <= rx_snp_flit;

            if ((state_q == ST_WAIT_CACHE) && combined_cache_result_valid)
                data_q <= use_external_l1 ? l1_result_data : cache_data;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= ST_IDLE;
            hit_q <= 1'b0;
            beat_q <= 4'd0;
            l1_result_pending_q <= 1'b0;
            l1_hit_q <= 1'b0;
            l1_dirty_q <= 1'b0;
            l1_data_q <= {LINE_WIDTH{1'b0}};
            forward_data_q <= 1'b0;
            forward_home_q <= 1'b0;
            forward_copy_q <= 1'b0;
        end else begin
            if (use_external_l1 && l1_snoop_result_valid &&
                !combined_cache_result_valid) begin
                l1_result_pending_q <= 1'b1;
                l1_hit_q <= l1_snoop_hit;
                l1_dirty_q <= l1_snoop_dirty;
                l1_data_q <= l1_snoop_data;
            end

            case (state_q)
                ST_IDLE: begin
                    if (accept_snp) begin
                        beat_q <= 4'd0;
                        l1_result_pending_q <= 1'b0;
                        forward_data_q <= 1'b0;
                        forward_home_q <= 1'b0;
                        forward_copy_q <= 1'b0;
                        state_q <= ST_LOOKUP;
                    end
                end

                ST_LOOKUP: begin
                    if (lookup_ready)
                        state_q <= ST_WAIT_CACHE;
                end

                ST_WAIT_CACHE: begin
                    if (combined_cache_result_valid) begin
                        hit_q <= selected_cache_hit;
                        beat_q <= 4'd0;
                        l1_result_pending_q <= 1'b0;
                        forward_data_q <= latched_is_fwd &&
                                          selected_cache_send_data;
                        forward_home_q <= latched_is_fwd &&
                                          selected_cache_send_data &&
                                          fwd_to_home;
                        forward_copy_q <= 1'b0;
                        if (selected_cache_send_data) begin
                            if (latched_is_fwd && !fwd_to_home)
                                state_q <= ST_SEND_RSP;
                            else
                                state_q <= ST_SEND_DAT;
                        end else begin
                            state_q <= ST_SEND_RSP;
                        end
                    end
                end

                ST_SEND_DAT: begin
                    if (dat_fire) begin
                        if (beat_q == (BEATS - 1)) begin
                            beat_q <= 4'd0;
                            if (forward_data_q) begin
                                if (forward_home_q && !forward_copy_q) begin
                                    forward_copy_q <= 1'b1;
                                end else begin
                                    forward_data_q <= 1'b0;
                                    forward_home_q <= 1'b0;
                                    forward_copy_q <= 1'b0;
                                    state_q <= ST_IDLE;
                                end
                            end else begin
                                // SnpRespData is the whole response.
                                state_q <= ST_IDLE;
                            end
                        end else begin
                            beat_q <= beat_q + 1'b1;
                        end
                    end
                end

                ST_SEND_RSP: begin
                    if (rsp_fire) begin
                        if (forward_data_q)
                            state_q <= ST_SEND_DAT;
                        else
                            state_q <= ST_IDLE;
                    end
                end

                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end

    // A snoop is being looked up or answered.
    assign busy = (state_q != ST_IDLE) || (|dvm_v_q);
endmodule
