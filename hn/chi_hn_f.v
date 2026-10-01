`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_hn_f
// Purpose: Home Node - Fully coherent (HN-F).  Single point-of-serialization
//          per address, drives snoops, owns the directory/snoop-filter, LLC,
//          and detached read/write trackers, and emits read-completion or
//          write-Comp.
//
// FSM (state_q, see HN_ST_* localparams):
//   IDLE          - Pop oldest non-stalled POS slot, look up SF, issue LLC.
//   BACKINV       - Conflict victim needs invalidate before line can be filled.
//   AFTER_BACKINV - Replay original request once back-invalidate drained.
//   WAIT_SNP      - Snoop in flight; collect SnpResp / SnpRespData.
//   AFTER_SNP     - Snoop done; route to LLC / mem read / forward snp data.
//   WAIT_LLC      - Wait one cycle for registered LLC lookup hit/data.
//   WAIT_MEM      - Legacy scalar SN-F read wait; detached read miss uses the
//                   read tracker and returns the FSM to IDLE after issue.
//   SEND_DAT      - Multi-beat CompData to requestor from selected line source.
//   WAIT_ACK      - Wait for CompAck before releasing the slot.
//
// Resources (sub-modules):
//   chi_hn_pos_buffer       - 16-entry POS with address-lock stall reporting.
//   chi_hn_req_parser       - Combinational REQ-flit field decode.
//   chi_hn_snoop_filter     - Set-assoc directory/SF with PLRU + BackInv.
//   chi_hn_llc              - Parameterized LLC, SECDED-protected 64b chunks.
//   chi_hn_snoop_generator  - Per-RN SNP flit fan-out, size from req_size.
//   chi_hn_write_tracker    - CAM for DBID, WDAT, SN Comp, and write line lock.
//   chi_hn_read_tracker     - Detached read-miss DAT capture and CompData send.
//   chi_hn_resp_engine      - Build Comp / CompDBIDResp / write-error replies.
//   chi_hn_mem_issuer       - Forward read / write requests to SN-F.
//   chi_perf_counter        - Optional 16 stall/event counters.
// -----------------------------------------------------------------------------
module chi_hn_f #(
    parameter NODE_ID    = 0,
    parameter MEM_TGT_ID = 0,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter NUM_SN     = `CHI_DEFAULT_NUM_SN,
    parameter SN_BASE_ID = MEM_TGT_ID,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter POS_DEPTH  = `CHI_DEFAULT_POS_DEPTH,
    parameter SF_ENTRIES = `CHI_DEFAULT_SF_ENTRIES,
    parameter LLC_LINES  = `CHI_DEFAULT_LLC_LINES,
    parameter LLC_WAYS   = `CHI_DEFAULT_LLC_WAYS,
    parameter WRITE_TRACKER_DEPTH = `CHI_DEFAULT_HN_WRITE_TRACKER_DEPTH,
    parameter READ_TRACKER_DEPTH = `CHI_DEFAULT_HN_READ_TRACKER_DEPTH,
    parameter SNOOP_TRACKER_DEPTH = `CHI_DEFAULT_HN_SNOOP_TRACKER_DEPTH,
    parameter HN_NUM_SLOTS = 2,
    parameter SINK_FIFO_DEPTH = `CHI_DEFAULT_FIFO_DEPTH,
    parameter TIMEOUT_CYCLES = 1024,
    // 0: a request/tracker stuck longer than TIMEOUT_CYCLES only raises
    //    watchdog_event and keeps waiting. 1: legacy functional timeout
    //    (SLVERR/Err completion and slot release).
    parameter FUNCTIONAL_TIMEOUT = 0,
    parameter ENABLE_PERF = `CHI_DEFAULT_ENABLE_PERF,
    parameter ENABLE_LLC_ECC = `CHI_DEFAULT_ENABLE_LLC_ECC,
    parameter WRITE_THROUGH_NO_ALLOCATE = 0,
    parameter ENABLE_RETRY = `CHI_CAP_RETRY_SUPPORT
)(
    input                    clk,
    input                    rstn,

    input                    rx_req_valid,
    input      [`CHI_REQ_W(NODE_ID_W)-1:0] rx_req_flit,
    output                   rx_req_ready,
    output                   rx_req_lcrdv,

    input                    rx_dat_valid,
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] rx_dat_flit,
    output                   rx_dat_ready,
    output                   rx_dat_lcrdv,

    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_ready,
    output                   rx_rsp_lcrdv,

    output                   tx_rsp_valid,
    output     [`CHI_RSP_W(NODE_ID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv,

    output                   tx_snp_valid,
    output     [`CHI_SNP_W(NODE_ID_W)-1:0] tx_snp_flit,
    output     [NODE_ID_W-1:0] tx_snp_tgt_id,
    input                    tx_snp_lcrdv,

    output                   tx_dat_valid,
    output     [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] tx_dat_flit,
    input                    tx_dat_lcrdv,

    output                   mem_req_valid,
    input                    mem_req_ready,
    output     [`CHI_REQ_W(NODE_ID_W)-1:0] mem_req_flit,

    output                   mem_dat_valid,
    input                    mem_dat_ready,
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] mem_dat_flit,

    output     [16*32-1:0]   perf_counts,
    output                   ecc_single_event,
    output                   ecc_double_event,
    input      [15:0]        cfg_excl_timeout,
    output                   exclusive_fail_event,
    output                   watchdog_event,
    // Any request, tracker, queued flit, LLC/SF operation or exclusive
    // reservation in flight.
    output                   busy
);
    `CHI_FLIT_PARAM_CHECK(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W,QOS_W,DATA_WIDTH)
    `include "../common/chi_clog2.vh"
    localparam REQ_W = `CHI_REQ_W(NODE_ID_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W);
    localparam SNP_W = `CHI_SNP_W(NODE_ID_W);
    localparam DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W);
    localparam [NODE_ID_W-1:0] NODE_ID_SIZED = NODE_ID;
    localparam [NODE_ID_W-1:0] SN_BASE_ID_SIZED = SN_BASE_ID;

    localparam LINE_BYTES = 64;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam LINE_ADDR_W = ADDR_WIDTH - 6;
    localparam BE_W = DATA_WIDTH / 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam DATAID_SHIFT = `CHI_DAT_DATAID_SHIFT(DATA_WIDTH);
    localparam [`CHI_DAT_DATAID_W-1:0] DATAID_ALIGN_MASK = (1 << DATAID_SHIFT) - 1;
    localparam TIMEOUT_W = (TIMEOUT_CYCLES <= 2) ? 1 : `CHI_CLOG2(TIMEOUT_CYCLES + 1);
    localparam [TIMEOUT_W-1:0] TIMEOUT_VALUE = TIMEOUT_CYCLES;
    localparam EXCL_AGE_W = 16;
    localparam FRONT_SLOT_COUNT = (HN_NUM_SLOTS < 1) ? 1 :
                                  ((HN_NUM_SLOTS > 2) ? 2 : HN_NUM_SLOTS);
    localparam TRACKER_ACTIVE_SLOTS =
        WRITE_TRACKER_DEPTH + READ_TRACKER_DEPTH + (SNOOP_TRACKER_DEPTH * 2);
    localparam POS_ACTIVE_SLOTS = TRACKER_ACTIVE_SLOTS + 1;

    localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB(NODE_ID_W);
    localparam REQ_SIZE_LSB   = `CHI_REQ_SIZE_LSB(NODE_ID_W);
    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(NODE_ID_W);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(NODE_ID_W);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(NODE_ID_W);
    localparam REQ_TGT_LSB    = `CHI_REQ_TGT_LSB(NODE_ID_W);
    localparam REQ_QOS_LSB    = `CHI_REQ_QOS_LSB(NODE_ID_W);
    localparam REQ_ALLOW_RETRY_LSB =
        `CHI_REQ_ALLOW_RETRY_LSB(NODE_ID_W);
    localparam REQ_PCRD_TYPE_LSB =
        `CHI_REQ_PCRD_TYPE_LSB(NODE_ID_W);
    localparam RSP_RESP_LSB   = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam RSP_DBID_LSB   = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB    = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB    = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB    = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam RSP_QOS_LSB    = `CHI_RSP_QOS_LSB(NODE_ID_W);
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

    // N-01/PERF-01 cleanup, 2026-06-21: HN_ST_BACKINV, HN_ST_AFTER_BACKINV,
    // HN_ST_WAIT_SNP, HN_ST_AFTER_SNP, and HN_ST_WAIT_MEM were confirmed dead
    // (no `state_q <= ...` assignment anywhere in this file ever targets
    // them -- start_backinv/start_snoop already delegate 100% to
    // chi_hn_snoop_tracker and return state_q straight to HN_ST_IDLE; the
    // detached read-miss path already returns to HN_ST_IDLE without ever
    // visiting HN_ST_WAIT_MEM). Removed along with every register/wire whose
    // only read depended on these unreachable states (mem_line_q, snp_line_q,
    // mem_beat_mask_q, snp_beat_mask_q, active_mem_tgt_q, backinv_addr_q,
    // backinv_sharer_vec_q, snp_data_seen_q, snp_data_expected_q,
    // snp_data_src_mask_q, the RESP_LINE_SRC_*/resp_line_src_q mux which only
    // ever selected the LLC arm in practice, and the scalar_llc_update_*
    // shadow LLC-fill path that chi_hn_read_tracker/chi_hn_snoop_tracker have
    // already fully superseded). This shrinks the live per-transaction state
    // from 10 values to 5 (IDLE, WAIT_SF, WAIT_LLC, SEND_DAT, WAIT_ACK)
    // before any of it gets duplicated for N-way concurrent slots.
    localparam HN_ST_IDLE          = 4'd0;
    localparam HN_ST_SEND_DAT      = 4'd6;
    localparam HN_ST_WAIT_ACK      = 4'd7;
    localparam HN_ST_WAIT_LLC      = 4'd8;
    localparam HN_ST_WAIT_SF       = 4'd9;
    localparam EVICT_ST_IDLE       = 3'd0;
    localparam EVICT_ST_SEND_REQ   = 3'd1;
    localparam EVICT_ST_SEND_DAT   = 3'd2;
    localparam EVICT_ST_WAIT_COMP  = 3'd3;
    // Wait for the SN's DBIDResp before sending the write data.
    localparam EVICT_ST_WAIT_DBID  = 3'd4;
    localparam [TXN_ID_W-1:0] LLC_EVICT_TXN_ID = {TXN_ID_W{1'b1}};

    wire                 pos_in_ready;
    wire                 pos_in_valid;
    wire                 pos_out_valid;
    wire                 pos_out_ready;
    wire [REQ_W-1:0]     pos_out_flit;
    wire                 pos_pop_pulse;
    wire                 pos_out1_valid;
    wire                 pos_out1_ready;
    wire [REQ_W-1:0]     pos_out1_flit;
    wire                 pos_pop1_pulse;
    wire [15:0]          pos_used;
    wire                 pos_addr_lock_stall;
    wire                 pos_full_stall;
    wire [ADDR_WIDTH-1:0] pos_active_addr;
    wire                 parser_from_replay;
    wire                 parser_from_prefetch;
    wire                 replay_no_snoop_active;
    wire                 front_prefetch_enabled;
    wire                 front_prefetch_capture0_fire;
    wire                 front_prefetch_capture1_fire;
    wire                 front_prefetch_capture_fire;
    wire                 front_prefetch_launch_fire;
    wire [POS_ACTIVE_SLOTS-1:0] pos_active_valid_vec;
    wire [POS_ACTIVE_SLOTS*ADDR_WIDTH-1:0] pos_active_addr_flat;
    wire [15:0]          hn_perf_events;
    wire [16*32-1:0]     hn_perf_counts_unused;

    wire                 parser_valid;
    wire [REQ_W-1:0]     parser_flit;
    wire                 parsed_valid;
    wire [ADDR_WIDTH-1:0] req_addr;
    wire [2:0]           req_size;
    wire [`CHI_REQ_OPCODE_W-1:0] req_opcode;
    wire [TXN_ID_W-1:0]  req_txn_id;
    wire [NODE_ID_W-1:0] req_src_id;
    wire [NODE_ID_W-1:0] req_tgt_id;
    wire [QOS_W-1:0]     req_qos;
    wire [`CHI_DAT_QOS_W-1:0] req_qos_dat;
    wire                 req_excl;
    wire [1:0]           req_order_unused;
    wire                 req_allow_retry;
    wire [`CHI_REQ_PCRD_TYPE_W-1:0] req_pcrd_type;
    wire                 req_exp_comp_ack_unused;
    wire [`CHI_REQ_MEMATTR_W-1:0] req_memattr_unused;
    wire                 req_snpattr_unused;
    wire [`CHI_REQ_PAS_W-1:0] req_pas_unused;
    wire                 req_trace_tag_unused;

    generate
        if (QOS_W >= `CHI_DAT_QOS_W) begin : gen_dat_qos_full
            assign req_qos_dat = req_qos[`CHI_DAT_QOS_W-1:0];
        end else begin : gen_dat_qos_pad
            assign req_qos_dat =
                {{(`CHI_DAT_QOS_W-QOS_W){1'b0}}, req_qos};
        end
    endgenerate

    wire                 req_is_read;
    wire                 req_is_write;
    wire                 req_is_upgrade;
    wire                 req_is_pcrd_return;
    wire                 req_needs_sf;
    wire                 process_state;
    wire                 raw_need_snoop;
    wire                 need_snoop;
    wire                 need_backinv;
    wire                 accept_req;
    wire                 start_sf_stage;
    wire                 start_sf_lookup;
    wire                 start_backinv;
    wire                 start_snoop;
    wire                 start_llc_lookup;
    wire                 start_mem_read;
    wire                 start_llc_read;
    wire                 start_write;
    wire                 start_upgrade;
    wire                 start_other_resp;
    wire                 start_pcrd_return;
    wire                 retry_ingress_accept;
    wire                 retry_parser_fire;
    wire                 retry_capture_fire;
    wire                 retry_slot_free;
    wire                 rx_req_duplicate_active;
    wire                 retry_grant_resource_ready;
    wire                 retry_ack_ready;
    wire                 retry_grant_ready;
    wire                 retry_ack_fire;
    wire                 retry_grant_fire;
    wire [`CHI_REQ_OPCODE_W-1:0] retry_capture_opcode;
    wire [TXN_ID_W-1:0]  retry_capture_txn_id;
    wire [NODE_ID_W-1:0] retry_capture_src_id;
    wire [QOS_W-1:0]     retry_capture_qos;
    wire [`CHI_REQ_PCRD_TYPE_W-1:0] retry_capture_pcrd_type;
    wire [`CHI_REQ_OPCODE_W-1:0] rx_req_opcode;
    wire [TXN_ID_W-1:0]  rx_req_txn_id;
    wire [NODE_ID_W-1:0] rx_req_src_id;
    wire [QOS_W-1:0]     rx_req_qos;
    wire                 rx_req_allow_retry;
    wire [`CHI_REQ_PCRD_TYPE_W-1:0] rx_req_pcrd_type;
    wire                 req_src_is_rn;
    wire                 req_exclusive_write;
    wire                 req_exclusive_fail;
    wire                 req_is_clean_unique;
    wire                 start_excl_fail_resp;
    wire                 sf_lookup_valid;
    wire                 sf_lookup_ready;
    wire                 sf_result_valid;
    wire                 sf_decision_valid;
    wire                 sf_direct_state;

    // DBIDs this home hands out: {bank, class, index}. Writes use class 0
    // (slot 1..DEPTH, chi_hn_write_tracker); CompData of a read carries a
    // class-1 (read tracker), class-2 (snoop tracker) or class-3 (LLC hit
    // in the main FSM) DBID, which the CompAck returns as its TxnID.
    localparam integer DBID_CLASS_LSB = DBID_W - 6;
    localparam [DBID_W-1:0] DBID_BANK = (NODE_ID - NUM_RN) << (DBID_W - 4);
    localparam [DBID_W-1:0] DBID_RD_BASE = DBID_BANK | (1 << DBID_CLASS_LSB);
    localparam [DBID_W-1:0] DBID_SNP_BASE = DBID_BANK | (2 << DBID_CLASS_LSB);
    localparam [DBID_W-1:0] DBID_MAIN = DBID_BANK | (3 << DBID_CLASS_LSB);
    wire                 filter_hit;
    wire                 req_is_copyback;
    wire                 copyback_stale;
    wire [1:0]           filter_state;
    wire [NUM_RN-1:0]    filter_sharer_vec;
    wire                 backinv_valid;
    wire [ADDR_WIDTH-1:0] backinv_addr;
    wire [NUM_RN-1:0]    backinv_sharer_vec;
    wire                 filter_update_ready;
    wire [NUM_RN-1:0]    sharers_without_requestor;
    reg  [NUM_RN-1:0]    requestor_onehot;
    integer              rn_idx;
    integer              excl_seq_idx;

    wire                 llc_hit;
    wire [2:0]           llc_state_unused;
    wire [LINE_WIDTH-1:0] llc_data;
    wire                 llc_ecc_single_error;
    wire                 llc_ecc_double_error;
    wire                 llc_lookup_ready;
    wire                 llc_lookup_valid;
    wire                 llc_lookup_capture_fire;
    wire                 llc_lookup_to_core_fire;
    wire                 llc_core_lookup_ready;
    wire [ADDR_WIDTH-1:0] llc_core_lookup_addr;
    wire                 llc_lookup_result_valid;
    wire                 llc_result_available;
    wire                 llc_hit_sel;
    wire [LINE_WIDTH-1:0] llc_data_sel;
    wire                 llc_update_valid;
    wire [ADDR_WIDTH-1:0] llc_update_addr;
    wire [LINE_WIDTH-1:0] llc_update_data;
    wire [2:0]           llc_update_state;
    wire                 llc_line_update_ready;
    wire                 llc_update_capture_fire;
    wire                 llc_update_to_core_fire;
    wire                 llc_core_line_update_ready;
    wire                 llc_core_line_update_valid;
    wire [ADDR_WIDTH-1:0] llc_core_line_update_addr;
    wire [LINE_WIDTH-1:0] llc_core_line_update_data;
    wire [2:0]           llc_core_line_update_state;
    wire                 scalar_filter_update_busy;
    wire                 llc_invalidate_valid;
    wire                 llc_invalidate_ready;
    wire                 llc_evict_valid;
    wire                 llc_evict_ready;
    wire [ADDR_WIDTH-1:0] llc_evict_addr;
    wire [LINE_WIDTH-1:0] llc_evict_data;
    wire [2:0]           llc_evict_state_unused;
    wire                 llc_evict_capture_fire;
    wire                 llc_evict_req_valid;
    wire                 llc_evict_req_fire;
    wire                 llc_evict_dat_valid;
    wire                 llc_evict_dat_fire;
    wire                 llc_evict_idle;
    wire                 llc_evict_comp_match;
    wire                 llc_evict_comp_fire;
    reg  [2:0]           llc_evict_state_q;
    reg  [ADDR_WIDTH-1:0] llc_evict_addr_q;
    reg  [LINE_WIDTH-1:0] llc_evict_data_q;
    reg  [3:0]           llc_evict_beat_q;
    reg  [NODE_ID_W-1:0] llc_evict_mem_tgt_id_r;
    // DBID the SN gave the LLC victim / dirty snoop write (TxnID of its
    // WriteData to the SN).
    reg  [DBID_W-1:0]    llc_evict_sn_dbid_q;
    wire [DBID_W-1:0]    rsp_dbid;
    reg  [REQ_W-1:0]     llc_evict_req_flit;
    reg  [DAT_W-1:0]     llc_evict_dat_flit;
    integer              llc_evict_mem_tgt_bank_r;

    wire [ADDR_WIDTH-1:0] snp_addr_sel;
    wire [`CHI_REQ_OPCODE_W-1:0] snp_req_opcode_sel;
    wire [2:0]           snp_size_sel;
    wire [NODE_ID_W-1:0] snp_requestor_sel;
    wire [NUM_RN-1:0]    snp_sharer_sel;
    wire                 snp_gen_start;
    wire [NUM_RN-1:0]    snp_valid_vec;
    wire [NUM_RN*SNP_W-1:0] snp_flit_flat;
    wire                 scalar_tx_snp_valid;
    wire [SNP_W-1:0]     scalar_tx_snp_flit;
    wire [NODE_ID_W-1:0] scalar_tx_snp_tgt_id;
    wire                 scalar_snp_send_fire;
    reg  [NUM_RN-1:0]    snp_send_mask_q;
    reg  [NUM_RN-1:0]    snp_wait_mask_q;
    reg  [NUM_RN-1:0]    snp_send_onehot;
    reg                  snp_selected_valid;
    reg [SNP_W-1:0]      snp_selected_flit;
    reg [NODE_ID_W-1:0]  snp_selected_tgt_id;
    wire                 snp_send_fire;
    wire [NUM_RN-1:0]    snp_send_mask_next;
    wire                 snp_all_sent_next;
    wire                 snp_wait_done;
    integer              snp_idx;

    wire                 dat_sink_in_ready;
    wire                 dat_sink_out_ready;
    wire                 dat_sink_valid;
    wire [DAT_W-1:0]     dat_sink_flit;
    wire                 dat_sink_pop_unused;
    wire [15:0]          dat_sink_used_unused;
    wire [`CHI_DAT_DATAID_W-1:0] dat_data_id;
    wire [TXN_ID_W-1:0]  dat_txn_id;
    wire [NODE_ID_W-1:0] dat_src_id;
    wire [NODE_ID_W-1:0] dat_tgt_id;
    wire [NODE_ID_W-1:0] dat_home_nid;
    wire [DBID_W-1:0]    dat_dbid;
    wire [3:0]           dat_opcode;
    wire [3:0]           dat_beat_idx;
    wire                 dat_data_id_ok;
    wire                 dat_from_rn;
    wire                 dat_is_wdat;
    wire                 dat_forward_to_mem;

    wire                 rsp_sink_in_ready;
    wire                 rsp_sink_valid;
    wire [RSP_W-1:0]     rsp_sink_flit;
    wire                 rsp_sink_pop_unused;
    wire [15:0]          rsp_sink_used_unused;
    wire [`CHI_RSP_OPCODE_W-1:0] rsp_opcode;
    wire [TXN_ID_W-1:0]  rsp_txn_id;
    wire [NODE_ID_W-1:0] rsp_src_id;
    wire                 snp_rsp_fire;
    wire                 main_comp_ack_match;
    wire                 comp_ack_fire;
    wire                 mem_rsp_drop_fire;
    wire                 rsp_sink_pop;
    wire                 rsp_expected_stall;
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
    wire                 wr_tracker_alloc_valid;
    wire                 wr_tracker_alloc_ready;
    wire                 wr_tracker_comp_valid;
    wire                 sn_dbid_rsp;
    wire                 llc_evict_dbid_match;
    wire                 wr_tracker_sn_dbid_valid;
    wire                 wr_tracker_sn_dbid_match;
    wire                 wr_tracker_wdat_sn_ready;
    wire [DBID_W-1:0]    wr_tracker_wdat_sn_dbid;
    wire                 wr_tracker_wdat_discard;
    wire                 wr_tracker_dbid_rsp_valid;
    wire                 wr_tracker_dbid_rsp_ready;
    wire [TXN_ID_W-1:0]  wr_tracker_dbid_rsp_txn_id;
    wire [NODE_ID_W-1:0] wr_tracker_dbid_rsp_tgt_id;
    wire [QOS_W-1:0]     wr_tracker_dbid_rsp_qos;
    wire [DBID_W-1:0]    wr_tracker_dbid_rsp_dbid;
    wire [1:0]           wr_tracker_dbid_rsp_resp_err;
    wire                 wr_tracker_dbid_rsp_copyback;
    wire                 wr_tracker_comp_ready;
    wire                 wr_tracker_comp_match;
    wire [DBID_W-1:0]    wr_tracker_alloc_dbid;
    wire [TXN_ID_W-1:0]  wr_tracker_alloc_mem_txn_id;
    wire                 wr_tracker_wdat_match;
    wire [TXN_ID_W-1:0]  wr_tracker_wdat_mem_txn_id;
    wire [NODE_ID_W-1:0] wr_tracker_wdat_mem_tgt_id;
    wire                 wr_tracker_rsp_valid;
    wire                 wr_tracker_rsp_ready;
    wire [TXN_ID_W-1:0]  wr_tracker_rsp_txn_id;
    wire [NODE_ID_W-1:0] wr_tracker_rsp_tgt_id;
    wire [QOS_W-1:0]     wr_tracker_rsp_qos;
    wire [1:0]           wr_tracker_rsp_resp_err;
    wire [WRITE_TRACKER_DEPTH-1:0] wr_tracker_active_valid_vec;
    wire [WRITE_TRACKER_DEPTH*ADDR_WIDTH-1:0] wr_tracker_active_addr_flat;
    // A write to the request's line is still on its way to the SN.
    reg                  wr_line_hazard;
    integer              wr_haz_i;
    wire [15:0]          wr_tracker_used_unused;
    wire                 wr_trackers_idle;
    wire                 llc_busy;
    wire                 sf_busy;
    wire                 rd_tracker_alloc_valid;
    wire                 rd_tracker_alloc_ready;
    wire [TXN_ID_W-1:0]  rd_tracker_alloc_mem_txn_id;
    wire                 rd_tracker_dat_match;
    wire                 rd_tracker_dat_ready;
    wire                 rd_tracker_comp_ack_match;
    wire                 rd_tracker_comp_ack_ready;
    wire                 rd_tracker_ack_pending;
    wire                 rd_tracker_ack_valid;
    wire [ADDR_WIDTH-1:0] rd_tracker_ack_addr;
    wire [NODE_ID_W-1:0] rd_tracker_ack_src_id;
    wire                 rd_tracker_ack_excl;
    wire                 rd_tracker_ack_shared;
    wire                 rd_tracker_err_valid;
    wire                 rd_tracker_err_ready;
    wire [RSP_W-1:0]     rd_tracker_err_flit;
    reg  [NUM_RN-1:0]    rd_tracker_ack_sharer_vec;
    wire                 rd_tracker_tx_dat_valid;
    wire                 rd_tracker_tx_dat_ready;
    wire [DAT_W-1:0]     rd_tracker_tx_dat_flit;
    wire                 rd_tracker_llc_update_valid;
    wire                 rd_tracker_llc_update_ready;
    wire [ADDR_WIDTH-1:0] rd_tracker_llc_update_addr;
    wire [LINE_WIDTH-1:0] rd_tracker_llc_update_data;
    wire [2:0]           rd_tracker_llc_update_state;
    wire [READ_TRACKER_DEPTH-1:0] rd_tracker_active_valid_vec;
    wire [READ_TRACKER_DEPTH*ADDR_WIDTH-1:0] rd_tracker_active_addr_flat;
    wire [15:0]          rd_tracker_used_unused;
    wire                 snp_tracker_alloc_valid;
    wire                 snp_tracker_alloc_ready;
    wire                 snp_tracker_mode_backinv;
    wire                 snp_tracker_tx_snp_valid;
    wire                 snp_tracker_tx_snp_ready;
    wire [SNP_W-1:0]     snp_tracker_tx_snp_flit;
    wire [NODE_ID_W-1:0] snp_tracker_tx_snp_tgt_id;
    wire                 snp_tracker_rsp_match;
    wire                 snp_tracker_rsp_ready;
    wire                 snp_tracker_dat_match;
    wire                 snp_tracker_dat_ready;
    wire                 snp_tracker_comp_ack_match;
    wire                 snp_tracker_comp_ack_ready;
    wire                 snp_tracker_replay_valid;
    wire                 snp_tracker_replay_ready;
    wire [REQ_W-1:0]     snp_tracker_replay_flit;
    wire                 snp_tracker_replay_no_snoop;
    wire                 snp_tracker_tx_dat_valid;
    wire                 snp_tracker_tx_dat_ready;
    wire [DAT_W-1:0]     snp_tracker_tx_dat_flit;
    wire                 snp_tracker_llc_update_valid;
    wire                 snp_tracker_llc_update_ready;
    wire [ADDR_WIDTH-1:0] snp_tracker_llc_update_addr;
    wire [LINE_WIDTH-1:0] snp_tracker_llc_update_data;
    wire [2:0]           snp_tracker_llc_update_state;
    wire                 snp_tracker_wb_valid;
    wire                 snp_tracker_wb_ready;
    wire [ADDR_WIDTH-1:0] snp_tracker_wb_addr;
    wire [LINE_WIDTH-1:0] snp_tracker_wb_data;
    wire                 snp_wb_capture_fire;
    wire                 snp_tracker_filter_update_valid;
    wire                 snp_tracker_filter_update_ready;
    wire                 snp_tracker_filter_update_invalidate;
    wire [ADDR_WIDTH-1:0] snp_tracker_filter_update_addr;
    wire [1:0]           snp_tracker_filter_update_state;
    wire [NUM_RN-1:0]    snp_tracker_filter_update_sharer_vec;
    wire                 snp_tracker_ack_valid;
    wire [ADDR_WIDTH-1:0] snp_tracker_ack_addr;
    wire [NODE_ID_W-1:0] snp_tracker_ack_src_id;
    wire                 snp_tracker_ack_excl;
    wire                 snp_tracker_err_valid;
    wire                 snp_tracker_err_ready;
    wire [RSP_W-1:0]     snp_tracker_err_flit;
    wire [SNOOP_TRACKER_DEPTH*2-1:0] snp_tracker_active_valid_vec;
    wire [SNOOP_TRACKER_DEPTH*2*ADDR_WIDTH-1:0] snp_tracker_active_addr_flat;
    wire [15:0]          snp_tracker_used_unused;
    wire [WRITE_TRACKER_DEPTH+READ_TRACKER_DEPTH+(SNOOP_TRACKER_DEPTH*2)-1:0] tracker_active_valid_vec;
    wire [(WRITE_TRACKER_DEPTH+READ_TRACKER_DEPTH+(SNOOP_TRACKER_DEPTH*2))*ADDR_WIDTH-1:0] tracker_active_addr_flat;
    wire                 filter_trackers_idle;
    wire                 filter_trackers_sf_ready;
    integer              rd_ack_idx;
    wire [3:0]           tx_rsp_credit_unused;
    wire                 tx_rsp_fire_unused;
    wire                 tx_rsp_return_unused;
    wire                 tx_rsp_stall_unused;
    wire                 mem_issuer_ready;
    wire                 mem_issue_valid;
    wire                 resp_issue_valid;
    reg  [REQ_W-1:0]     mem_req_flit_pre;
    wire [NODE_ID_W-1:0] mem_tgt_id_sel;
    reg  [NODE_ID_W-1:0] mem_tgt_id_r;
    integer              mem_tgt_bank_r;

    wire                 resp_dat_valid;
    wire                 resp_dat_ready;
    reg  [DAT_W-1:0]     resp_dat_flit;
    wire                 tx_dat_link_valid;
    wire                 tx_dat_link_ready;
    wire [DAT_W-1:0]     tx_dat_link_flit;
    wire [3:0]           tx_dat_credit_unused;
    wire                 tx_dat_fire_unused;
    wire                 tx_dat_return_unused;
    wire                 tx_dat_stall_unused;
    wire                 resp_dat_fire;
    wire                 resp_dat_last;

    reg  [3:0]           state_q;
    reg  [REQ_W-1:0]     hold_req_flit_q;
    reg                  front_prefetch_valid_q;
    reg  [REQ_W-1:0]     front_prefetch_flit_q;
    reg                   sf_lookup_issued_q;
    reg  [ADDR_WIDTH-1:0] sf_lookup_addr_q;
    reg                   llc_result_valid_q;
    reg                   llc_hit_q;
    reg  [LINE_WIDTH-1:0] llc_data_q;
    reg                   llc_lookup_pending_q;
    reg  [ADDR_WIDTH-1:0] llc_lookup_addr_q;
    reg                   llc_update_pending_q;
    reg  [ADDR_WIDTH-1:0] llc_update_addr_q;
    reg  [LINE_WIDTH-1:0] llc_update_data_q;
    reg  [2:0]            llc_update_state_q;
    reg  [3:0]            resp_beat_q;
    wire [`CHI_DAT_DATAID_W-1:0] llc_evict_data_id;
    wire [`CHI_DAT_DATAID_W-1:0] resp_data_id;
    reg [RSP_W-1:0]       wr_comp_flit;
    reg [RSP_W-1:0]       wr_dbid_rsp_flit;
    reg [RSP_W-1:0]       excl_fail_rsp_flit;
    reg                   excl_fail_valid_q;
    reg [TXN_ID_W-1:0]    excl_fail_txn_q;
    reg [NODE_ID_W-1:0]   excl_fail_tgt_q;
    reg [QOS_W-1:0]       excl_fail_qos_q;
    reg                   err_rsp_valid_q;
    reg [TXN_ID_W-1:0]    err_txn_q;
    reg [NODE_ID_W-1:0]   err_tgt_q;
    reg [QOS_W-1:0]       err_qos_q;
    reg [RSP_W-1:0]       err_rsp_flit;
    reg                   retry_ack_valid_q;
    reg                   retry_grant_pending_q;
    reg                   retry_grant_valid_q;
    reg [TXN_ID_W-1:0]    retry_txn_q;
    reg [NODE_ID_W-1:0]   retry_tgt_q;
    reg [QOS_W-1:0]       retry_qos_q;
    reg [`CHI_REQ_OPCODE_W-1:0] retry_opcode_q;
    reg [`CHI_REQ_PCRD_TYPE_W-1:0] retry_pcrd_type_q;
    reg [RSP_W-1:0]       retry_rsp_flit;
    reg [TIMEOUT_W-1:0]   timeout_cnt_q;

    wire                  state_timeout_en;
    wire                  state_timeout_fire;
    wire                  state_watchdog;
    wire                  rd_tracker_watchdog;
    wire                  snp_tracker_watchdog;
    wire [ADDR_WIDTH-1:0] held_req_addr;
    wire [ADDR_WIDTH-1:0] filter_active_req_addr;
    wire [EXCL_AGE_W-1:0] excl_timeout_value;
    reg                   excl_lookup_match_r;
    reg [NUM_RN-1:0]      excl_valid_q;
    reg [LINE_ADDR_W-1:0] excl_line_q [0:NUM_RN-1];
    reg [EXCL_AGE_W-1:0]  excl_age_q [0:NUM_RN-1];
`ifndef SYNTHESIS
    wire [NUM_RN-1:0]     b5_excl_valid_flat;
    wire [NUM_RN*LINE_ADDR_W-1:0] b5_excl_line_flat;
    genvar                b5_excl_dbg_g;
    wire                  b5_excl_pass;
    wire [LINE_ADDR_W-1:0] b5_excl_pass_line;
`endif

    // synthesis translate_off
    localparam integer HN_SCALAR_MON_THRESHOLD =
        (TIMEOUT_CYCLES < 16) ? 16 : TIMEOUT_CYCLES;
    integer              hn_scalar_busy_mon_cnt;
    integer              hn_pos_blocked_mon_cnt;
    reg                  hn_scalar_busy_reported_q;
    reg                  hn_pos_blocked_reported_q;
    // synthesis translate_on

    reg                  filter_update_valid;
    reg                  filter_update_invalidate;
    reg                  filter_update_merge;
    reg [ADDR_WIDTH-1:0] filter_update_addr;
    reg [1:0]            filter_update_state;
    reg [NUM_RN-1:0]     filter_update_sharer_vec;

    assign rx_req_opcode = rx_req_flit[REQ_OPCODE_LSB +: `CHI_REQ_OPCODE_W];
    assign rx_req_txn_id = rx_req_flit[REQ_TXN_LSB +: TXN_ID_W];
    assign rx_req_src_id = rx_req_flit[REQ_SRC_LSB +: NODE_ID_W];
    assign rx_req_qos = rx_req_flit[REQ_QOS_LSB +: QOS_W];
    assign rx_req_allow_retry = rx_req_flit[REQ_ALLOW_RETRY_LSB];
    assign rx_req_pcrd_type =
        rx_req_flit[REQ_PCRD_TYPE_LSB +: `CHI_REQ_PCRD_TYPE_W];

    assign retry_slot_free = !retry_ack_valid_q &&
                             !retry_grant_pending_q &&
                             !retry_grant_valid_q;
    assign rx_req_duplicate_active =
        rx_req_valid &&
        (state_q != HN_ST_IDLE) &&
        (rx_req_txn_id == req_txn_id) &&
        (rx_req_src_id == req_src_id);
    assign retry_ingress_accept =
        (ENABLE_RETRY != 0) &&
        rx_req_valid &&
        !pos_in_ready &&
        !rx_req_duplicate_active &&
        rx_req_allow_retry &&
        (rx_req_opcode != `CHI_REQ_PCRD_RETURN) &&
        retry_slot_free;
    assign pos_in_valid =
        rx_req_valid && !retry_ingress_accept && !rx_req_duplicate_active;
    assign rx_req_ready =
        rx_req_duplicate_active || pos_in_ready || retry_ingress_accept;
    assign rx_dat_ready = dat_sink_in_ready;
    assign rx_rsp_ready = rsp_sink_in_ready;
    assign rx_req_lcrdv = rx_req_valid && rx_req_ready;
    assign rx_dat_lcrdv = rx_dat_valid && dat_sink_in_ready;
    assign rx_rsp_lcrdv = rx_rsp_valid && rsp_sink_in_ready;
    assign pos_active_addr = hold_req_flit_q[REQ_ADDR_LSB +: ADDR_WIDTH];
    assign front_prefetch_enabled = (FRONT_SLOT_COUNT > 1);

    assign parser_from_replay = (state_q == HN_ST_IDLE) &&
                                snp_tracker_replay_valid;
    assign parser_from_prefetch = (state_q == HN_ST_IDLE) &&
                                  !parser_from_replay &&
                                  front_prefetch_valid_q;
    assign replay_no_snoop_active = parser_from_replay &&
                                    snp_tracker_replay_no_snoop;
    assign parser_valid = parser_from_replay ? 1'b1 :
                          (parser_from_prefetch ? 1'b1 :
                           ((state_q == HN_ST_IDLE) ? pos_out_valid : 1'b1));
    assign parser_flit  = parser_from_replay ? snp_tracker_replay_flit :
                          (parser_from_prefetch ? front_prefetch_flit_q :
                           ((state_q == HN_ST_IDLE) ? pos_out_flit :
                                                      hold_req_flit_q));
    assign held_req_addr = hold_req_flit_q[REQ_ADDR_LSB +: ADDR_WIDTH];
    assign filter_active_req_addr =
        (state_q == HN_ST_IDLE) ? req_addr : held_req_addr;

    assign req_is_read = (req_opcode == `CHI_REQ_RD_SHARED) ||
                         (req_opcode == `CHI_REQ_RD_UNIQUE) ||
                         (req_opcode == `CHI_REQ_RD_ONCE) ||
                         (req_opcode == `CHI_REQ_RD_NO_SNP);
    assign req_is_write = (req_opcode == `CHI_REQ_WR_UNIQUE) ||
                          (req_opcode == `CHI_REQ_WR_NO_SNP) ||
                          (req_opcode == `CHI_REQ_WB_FULL) ||
                          (req_opcode == `CHI_REQ_WB_PTL);
    assign req_is_upgrade = (req_opcode == `CHI_REQ_MK_UNIQUE) ||
                            (req_opcode == `CHI_REQ_CLN_UNIQUE);
    assign req_is_pcrd_return = (req_opcode == `CHI_REQ_PCRD_RETURN);
    assign req_is_clean_unique = (req_opcode == `CHI_REQ_CLN_UNIQUE);
    assign req_needs_sf = req_is_read || req_is_write || req_is_upgrade;

    assign sharers_without_requestor = filter_sharer_vec & ~requestor_onehot;
    // A CopyBack from an RN the SF no longer lists: the RN lost the line to a
    // snoop while its WriteBack was queued (it answered that snoop with the
    // dirty data). Its data is stale (CopyBackWrData_I in IHI0050H), so the
    // HN takes the beats but writes nothing, and neither snoops nor updates
    // the SF.
    assign req_is_copyback = (req_opcode == `CHI_REQ_WB_FULL) ||
                             (req_opcode == `CHI_REQ_WB_PTL);
    assign copyback_stale = sf_decision_valid && req_is_copyback &&
                            !(filter_hit && |(filter_sharer_vec & requestor_onehot));
    assign raw_need_snoop = filter_hit && (|sharers_without_requestor);
    assign req_src_is_rn = (req_src_id < NUM_RN);
    assign req_exclusive_write = parsed_valid && req_excl &&
                                 (req_is_write ||
                                  (req_opcode == `CHI_REQ_CLN_UNIQUE));
    assign req_exclusive_fail = req_exclusive_write && !excl_lookup_match_r;
    assign mem_tgt_id_sel = mem_tgt_id_r;
    assign process_state = (state_q == HN_ST_IDLE);
    assign filter_trackers_idle =
        !(|rd_tracker_active_valid_vec) &&
        !(|snp_tracker_active_valid_vec) &&
        !rd_tracker_ack_valid &&
        !rd_tracker_llc_update_valid &&
        !snp_tracker_filter_update_valid;
    assign filter_trackers_sf_ready =
        filter_trackers_idle ||
        // A back-invalidate tracker replays the original request before it can
        // retire, so allow that single active replay to enter the SF stage.
        (parser_from_replay &&
         (snp_tracker_used_unused == 16'd1) &&
         !(|rd_tracker_active_valid_vec) &&
         !rd_tracker_ack_valid &&
         !rd_tracker_llc_update_valid &&
         !snp_tracker_filter_update_valid);
    assign wr_trackers_idle = !(|wr_tracker_active_valid_vec);
    assign sf_direct_state = replay_no_snoop_active;
    assign start_sf_stage = parsed_valid &&
                            (state_q == HN_ST_IDLE) &&
                            req_needs_sf &&
                            filter_trackers_sf_ready &&
                            !replay_no_snoop_active &&
                            !req_exclusive_fail;
    assign sf_lookup_valid = parsed_valid &&
                             (state_q == HN_ST_WAIT_SF) &&
                             !sf_lookup_issued_q &&
                             req_needs_sf;
    assign start_sf_lookup = sf_lookup_valid && sf_lookup_ready;
    assign sf_decision_valid = (state_q == HN_ST_WAIT_SF) &&
                               sf_lookup_issued_q &&
                               sf_result_valid;
    assign need_snoop = sf_decision_valid &&
                        !req_exclusive_fail &&
                        !copyback_stale &&
                        raw_need_snoop;
    assign need_backinv = sf_decision_valid &&
                          parsed_valid &&
                          req_needs_sf &&
                          !req_exclusive_fail &&
                          !copyback_stale &&
                          backinv_valid;

    assign start_excl_fail_resp = process_state &&
                                  req_exclusive_fail &&
                                  !excl_fail_valid_q;
    assign start_backinv = parsed_valid && sf_decision_valid &&
                           !start_excl_fail_resp &&
                           need_backinv && snp_tracker_alloc_ready;
    assign start_snoop = parsed_valid && sf_decision_valid &&
                         !start_excl_fail_resp &&
                         !need_backinv && need_snoop &&
                         snp_tracker_alloc_ready;
    assign start_llc_lookup = parsed_valid &&
                              !start_excl_fail_resp &&
                              req_is_read &&
                              llc_lookup_ready &&
                              (((sf_decision_valid &&
                                 !need_backinv && !need_snoop)) ||
                               (process_state && sf_direct_state));
    assign llc_result_available = (state_q == HN_ST_WAIT_LLC) &&
                                  (llc_lookup_result_valid ||
                                   llc_result_valid_q);
    assign llc_hit_sel = llc_lookup_result_valid ? llc_hit : llc_hit_q;
    assign llc_data_sel = llc_lookup_result_valid ? llc_data : llc_data_q;
    assign start_llc_read = parsed_valid &&
                            (state_q == HN_ST_WAIT_LLC) &&
                            req_is_read &&
                            llc_result_available &&
                            llc_hit_sel;
    // A memory read must not overtake a write to the same line that the HN
    // has already accepted: the SN (AXI) does not order a read after a
    // write in flight, so the read could return, and the LLC would keep,
    // the old data.
    always @(*) begin
        wr_line_hazard = 1'b0;
        for (wr_haz_i = 0; wr_haz_i < WRITE_TRACKER_DEPTH;
             wr_haz_i = wr_haz_i + 1) begin
            if (wr_tracker_active_valid_vec[wr_haz_i] &&
                (wr_tracker_active_addr_flat[wr_haz_i*ADDR_WIDTH + 6 +: ADDR_WIDTH-6] ==
                 req_addr[ADDR_WIDTH-1:6]))
                wr_line_hazard = 1'b1;
        end
    end

    assign start_mem_read = parsed_valid &&
                            (state_q == HN_ST_WAIT_LLC) &&
                            req_is_read &&
                            llc_result_available &&
                            !llc_hit_sel &&
                            !wr_line_hazard &&
                            llc_evict_idle &&
                            rd_tracker_alloc_ready && mem_issuer_ready;
    assign start_write = parsed_valid &&
                         (((sf_decision_valid &&
                            !need_backinv && !need_snoop)) ||
                          (process_state && sf_direct_state)) &&
                         !start_excl_fail_resp &&
                         !req_exclusive_fail &&
                         !rd_tracker_ack_pending &&
                         llc_evict_idle &&
                         req_is_write && wr_tracker_alloc_ready &&
                         !wr_line_hazard &&
                         mem_issuer_ready &&
                         filter_update_ready && llc_invalidate_ready;
    assign start_upgrade = parsed_valid &&
                           (((sf_decision_valid &&
                              !need_backinv && !need_snoop)) ||
                            (process_state && sf_direct_state)) &&
                           !start_excl_fail_resp &&
                           !req_exclusive_fail &&
                           !rd_tracker_ack_pending &&
                           llc_evict_idle &&
                           req_is_upgrade && resp_req_ready &&
                           filter_update_ready;
    assign start_other_resp = parsed_valid && !need_backinv && !need_snoop &&
                              !req_needs_sf && !req_is_pcrd_return &&
                              resp_req_ready;
    assign start_pcrd_return = parsed_valid &&
                               (state_q == HN_ST_IDLE) &&
                               req_is_pcrd_return;

    assign retry_parser_fire =
        (ENABLE_RETRY != 0) &&
        parsed_valid &&
        req_allow_retry &&
        retry_slot_free &&
        !parser_from_replay &&
        !req_is_pcrd_return &&
        !accept_req &&
        (((state_q == HN_ST_IDLE) && !start_sf_stage) ||
         ((state_q == HN_ST_WAIT_SF) && sf_decision_valid) ||
         ((state_q == HN_ST_WAIT_LLC) && llc_result_available &&
          !start_llc_read && !start_mem_read));
    assign retry_capture_fire = retry_ingress_accept || retry_parser_fire;
    assign retry_capture_opcode = retry_ingress_accept ? rx_req_opcode : req_opcode;
    assign retry_capture_txn_id = retry_ingress_accept ? rx_req_txn_id : req_txn_id;
    assign retry_capture_src_id = retry_ingress_accept ? rx_req_src_id : req_src_id;
    assign retry_capture_qos = retry_ingress_accept ? rx_req_qos : req_qos;
    assign retry_capture_pcrd_type = `CHI_REQ_PCRD_TYPE_GENERIC;

    assign accept_req = !err_rsp_valid_q &&
                        (start_excl_fail_resp ||
                         start_sf_stage || start_backinv ||
                         start_snoop ||
                         start_llc_lookup || start_write ||
                         start_upgrade ||
                         start_other_resp ||
                         start_pcrd_return);
    assign pos_out_ready =
        ((state_q == HN_ST_IDLE) && !parser_from_replay &&
         !parser_from_prefetch && (accept_req || retry_parser_fire)) ||
        (front_prefetch_enabled && (state_q != HN_ST_IDLE) &&
         !front_prefetch_valid_q && pos_out_valid);
    assign pos_out1_ready =
        front_prefetch_enabled &&
        !front_prefetch_valid_q &&
        (state_q == HN_ST_IDLE) &&
        !parser_from_replay &&
        !parser_from_prefetch &&
        (accept_req || retry_parser_fire);
    assign front_prefetch_capture0_fire =
        front_prefetch_enabled &&
        pos_out_valid && pos_out_ready &&
        !((state_q == HN_ST_IDLE) && !parser_from_replay &&
          !parser_from_prefetch && (accept_req || retry_parser_fire));
    assign front_prefetch_capture1_fire =
        front_prefetch_enabled &&
        pos_out1_valid && pos_out1_ready;
    assign front_prefetch_capture_fire =
        front_prefetch_capture0_fire || front_prefetch_capture1_fire;
    assign front_prefetch_launch_fire =
        parser_from_prefetch && (accept_req || retry_parser_fire);
    assign snp_tracker_replay_ready = parser_from_replay && accept_req;

    assign mem_issue_valid = start_mem_read || start_write ||
                             llc_evict_req_valid;
    // A write's DBIDResp comes from its write tracker once the SN has
    // given a DBID.
    assign resp_issue_valid = start_upgrade || start_other_resp;

    assign snp_gen_start = start_backinv || start_snoop;
    assign snp_addr_sel = start_backinv ? backinv_addr : req_addr;
    assign snp_req_opcode_sel = start_backinv ?
                                `CHI_REQ_MK_UNIQUE : req_opcode;
    assign snp_size_sel = start_backinv ? 3'd6 : req_size;
    assign snp_requestor_sel = start_backinv ?
                               {NODE_ID_W{1'b1}} : req_src_id;
    assign snp_sharer_sel = start_backinv ? backinv_sharer_vec :
                                            filter_sharer_vec;

    assign scalar_tx_snp_valid = snp_gen_start &&
                                 (snp_send_mask_q != {NUM_RN{1'b0}});
    assign scalar_tx_snp_flit = snp_selected_flit;
    assign scalar_tx_snp_tgt_id = snp_selected_tgt_id;
    assign tx_snp_valid = scalar_tx_snp_valid || snp_tracker_tx_snp_valid;
    assign tx_snp_flit = scalar_tx_snp_valid ? scalar_tx_snp_flit :
                                               snp_tracker_tx_snp_flit;
    assign tx_snp_tgt_id = scalar_tx_snp_valid ? scalar_tx_snp_tgt_id :
                                                  snp_tracker_tx_snp_tgt_id;
    assign scalar_snp_send_fire = scalar_tx_snp_valid && tx_snp_lcrdv;
    assign snp_tracker_tx_snp_ready = tx_snp_lcrdv && !scalar_tx_snp_valid;
    assign snp_send_fire = scalar_snp_send_fire;
    assign snp_send_mask_next = snp_send_mask_q & ~snp_send_onehot;
    assign snp_all_sent_next = snp_send_fire ?
                               (snp_send_mask_next == {NUM_RN{1'b0}}) :
                               (snp_send_mask_q == {NUM_RN{1'b0}});

    assign rsp_opcode = rsp_sink_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W];
    assign rsp_txn_id = rsp_sink_flit[RSP_TXN_LSB +: TXN_ID_W];
    assign rsp_src_id = rsp_sink_flit[RSP_SRC_LSB +: NODE_ID_W];
    assign rsp_dbid = rsp_sink_flit[RSP_DBID_LSB +: DBID_W];
    assign rd_tracker_ack_pending = rsp_sink_valid &&
                                    (rsp_opcode == `CHI_RSP_COMP_ACK) &&
                                    rd_tracker_comp_ack_match;
    assign snp_rsp_fire = rsp_sink_valid &&
                          ((rsp_opcode == `CHI_RSP_SNP_RESP) ||
                           (rsp_opcode == `CHI_RSP_SNP_RESP_FWD)) &&
                          (rsp_txn_id == req_txn_id) &&
                          (|(snp_wait_mask_q & snp_rsp_onehot));
    assign main_comp_ack_match = rsp_sink_valid &&
                                 (state_q == HN_ST_WAIT_ACK) &&
                                 (rsp_opcode == `CHI_RSP_COMP_ACK) &&
                                 (rsp_txn_id == DBID_MAIN) &&
                                 (rsp_src_id == req_src_id);
    // The CompAck waits while the snoop filter finishes another operation.
    assign comp_ack_fire = main_comp_ack_match && filter_update_ready;
    assign rd_tracker_comp_ack_ready =
        filter_update_ready &&
        !start_write &&
        !start_upgrade &&
        !comp_ack_fire;
    assign snp_tracker_rsp_ready = !snp_rsp_fire;
    assign snp_tracker_comp_ack_ready =
        !comp_ack_fire &&
        !(rd_tracker_ack_pending && rd_tracker_comp_ack_ready);
    assign wr_tracker_comp_valid = rsp_sink_valid &&
                                   ((rsp_opcode == `CHI_RSP_COMP) ||
                                    (rsp_opcode == `CHI_RSP_COMP_DBID));
    assign mem_rsp_drop_fire = wr_tracker_comp_valid && wr_tracker_comp_ready;
    // DBIDResp reaching the home comes from an SN for one of its writes:
    // the LLC victim / dirty snoop writer, or a write tracker entry.
    assign sn_dbid_rsp = rsp_sink_valid && (rsp_opcode == `CHI_RSP_DBID);
    assign llc_evict_dbid_match =
        sn_dbid_rsp && (llc_evict_state_q == EVICT_ST_WAIT_DBID) &&
        (rsp_txn_id == LLC_EVICT_TXN_ID) &&
        (rsp_src_id == llc_evict_mem_tgt_id_r);
    assign wr_tracker_sn_dbid_valid = sn_dbid_rsp && !llc_evict_dbid_match;
    assign rsp_sink_pop = snp_rsp_fire || comp_ack_fire ||
                          llc_evict_comp_fire || mem_rsp_drop_fire ||
                          llc_evict_dbid_match ||
                          (wr_tracker_sn_dbid_valid && wr_tracker_sn_dbid_match) ||
                          (rsp_sink_valid &&
                           (rsp_opcode == `CHI_RSP_COMP_ACK) &&
                           rd_tracker_comp_ack_match &&
                           rd_tracker_comp_ack_ready) ||
                          (rsp_sink_valid && snp_tracker_rsp_match &&
                           snp_tracker_rsp_ready) ||
                          (rsp_sink_valid &&
                           (rsp_opcode == `CHI_RSP_COMP_ACK) &&
                           snp_tracker_comp_ack_match &&
                           snp_tracker_comp_ack_ready);
    assign rsp_expected_stall =
        main_comp_ack_match ||
        (wr_tracker_comp_valid && wr_tracker_comp_match) ||
        llc_evict_comp_match ||
        llc_evict_dbid_match ||
        (wr_tracker_sn_dbid_valid && wr_tracker_sn_dbid_match) ||
        (rsp_sink_valid && (rsp_opcode == `CHI_RSP_COMP_ACK) &&
         rd_tracker_comp_ack_match) ||
        (rsp_sink_valid && snp_tracker_rsp_match) ||
        (rsp_sink_valid && (rsp_opcode == `CHI_RSP_COMP_ACK) &&
         snp_tracker_comp_ack_match);
    assign snp_wait_mask_next = snp_wait_mask_q & ~snp_rsp_onehot;
    assign snp_wait_done = ((snp_rsp_fire ? snp_wait_mask_next : snp_wait_mask_q) ==
                            {NUM_RN{1'b0}});

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && rsp_sink_valid &&
            ((rsp_opcode == `CHI_RSP_RETRY_ACK) ||
             (rsp_opcode == `CHI_RSP_PCRD_GRANT) ||
             (rsp_opcode == `CHI_RSP_READ_RECEIPT))) begin
            $display("chi_hn_f unsupported Issue-H RSP opcode %0h txn %0h",
                     rsp_opcode, rsp_txn_id);
            $stop;
        end
    end
    // synthesis translate_on

    assign dat_data_id = dat_sink_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W];
    assign dat_beat_idx = dat_data_id >> DATAID_SHIFT;
    assign dat_txn_id = dat_sink_flit[DAT_TXN_LSB +: TXN_ID_W];
    assign dat_src_id = dat_sink_flit[DAT_SRC_LSB +: NODE_ID_W];
    assign dat_tgt_id = dat_sink_flit[DAT_TGT_LSB +: NODE_ID_W];
    assign dat_home_nid = dat_sink_flit[DAT_HOME_NID_LSB +: NODE_ID_W];
    assign dat_dbid = dat_sink_flit[DAT_DBID_LSB +: DBID_W];
    assign dat_opcode = dat_sink_flit[DAT_OPCODE_LSB +: 4];
    assign dat_data_id_ok =
        ((dat_data_id & DATAID_ALIGN_MASK) == {`CHI_DAT_DATAID_W{1'b0}}) &&
        (dat_beat_idx < BEATS);
    assign dat_from_rn = (dat_src_id < NUM_RN);
    assign dat_is_wdat = dat_from_rn &&
                         (dat_tgt_id == NODE_ID_SIZED) &&
                         (dat_opcode == `CHI_DAT_OPCODE_WDAT);
    assign dat_forward_to_mem = dat_sink_valid &&
                                dat_is_wdat &&
                                wr_tracker_wdat_match &&
                                wr_tracker_wdat_sn_ready &&
                                !snp_tracker_dat_match &&
                                !rd_tracker_dat_match;

    assign resp_dat_valid = (state_q == HN_ST_SEND_DAT);
    assign tx_dat_link_valid = resp_dat_valid ||
                               snp_tracker_tx_dat_valid ||
                               rd_tracker_tx_dat_valid;
    assign tx_dat_link_flit = resp_dat_valid ? resp_dat_flit :
                              (snp_tracker_tx_dat_valid ?
                               snp_tracker_tx_dat_flit :
                               rd_tracker_tx_dat_flit);
    assign resp_dat_ready = tx_dat_link_ready;
    assign snp_tracker_tx_dat_ready = tx_dat_link_ready && !resp_dat_valid;
    assign rd_tracker_tx_dat_ready = tx_dat_link_ready && !resp_dat_valid &&
                                     !snp_tracker_tx_dat_valid;
    assign resp_dat_fire = resp_dat_valid && resp_dat_ready;
    assign resp_dat_last = resp_dat_fire && (resp_beat_q == (BEATS - 1));
    assign llc_evict_data_id = llc_evict_beat_q << DATAID_SHIFT;
    assign resp_data_id = resp_beat_q << DATAID_SHIFT;

    assign dat_sink_out_ready = snp_tracker_dat_match ? snp_tracker_dat_ready :
                                (rd_tracker_dat_match ? rd_tracker_dat_ready :
                                 (dat_forward_to_mem ?
                                  (mem_dat_ready && !llc_evict_dat_valid) :
                                  1'b0));

    assign mem_dat_valid = dat_forward_to_mem || llc_evict_dat_valid;

    assign tx_rsp_link_valid = resp_valid || wr_tracker_rsp_valid ||
                               wr_tracker_dbid_rsp_valid ||
                               excl_fail_valid_q || err_rsp_valid_q ||
                               rd_tracker_err_valid ||
                               snp_tracker_err_valid ||
                               retry_ack_valid_q ||
                               retry_grant_valid_q;
    assign tx_rsp_link_flit = resp_valid ? resp_flit :
                                (wr_tracker_rsp_valid ? wr_comp_flit :
                                 (wr_tracker_dbid_rsp_valid ? wr_dbid_rsp_flit :
                                 (excl_fail_valid_q ? excl_fail_rsp_flit :
                                  (err_rsp_valid_q ? err_rsp_flit :
                                   (rd_tracker_err_valid ? rd_tracker_err_flit :
                                    (snp_tracker_err_valid ? snp_tracker_err_flit :
                                     retry_rsp_flit))))));
    assign resp_ready = tx_rsp_link_ready;
    assign wr_comp_ready = tx_rsp_link_ready && !resp_valid;
    assign wr_tracker_rsp_ready = wr_comp_ready;
    assign wr_tracker_dbid_rsp_ready = tx_rsp_link_ready && !resp_valid &&
                                       !wr_tracker_rsp_valid;
    assign err_rsp_ready = tx_rsp_link_ready && !resp_valid &&
                           !wr_tracker_rsp_valid &&
                           !wr_tracker_dbid_rsp_valid && !excl_fail_valid_q;
    assign rd_tracker_err_ready = tx_rsp_link_ready && !resp_valid &&
                                  !wr_tracker_rsp_valid &&
                                  !wr_tracker_dbid_rsp_valid &&
                                  !excl_fail_valid_q && !err_rsp_valid_q;
    assign snp_tracker_err_ready = tx_rsp_link_ready && !resp_valid &&
                                   !wr_tracker_rsp_valid &&
                                   !wr_tracker_dbid_rsp_valid &&
                                   !excl_fail_valid_q && !err_rsp_valid_q &&
                                   !rd_tracker_err_valid;
    assign retry_ack_ready = tx_rsp_link_ready && !resp_valid &&
                             !wr_tracker_rsp_valid &&
                             !wr_tracker_dbid_rsp_valid &&
                             !excl_fail_valid_q && !err_rsp_valid_q &&
                             !rd_tracker_err_valid &&
                             !snp_tracker_err_valid;
    assign retry_grant_ready = retry_ack_ready && !retry_ack_valid_q;
    assign retry_ack_fire = retry_ack_valid_q && retry_ack_ready;
    assign retry_grant_fire = retry_grant_valid_q && retry_grant_ready;
    assign retry_grant_resource_ready =
        (state_q == HN_ST_IDLE) &&
        !front_prefetch_valid_q &&
        pos_in_ready &&
        llc_evict_idle &&
        filter_update_ready &&
        resp_req_ready &&
        wr_tracker_alloc_ready &&
        rd_tracker_alloc_ready &&
        snp_tracker_alloc_ready &&
        mem_issuer_ready &&
        llc_lookup_ready &&
        !err_rsp_valid_q;
    assign wr_tracker_alloc_valid = start_write;
    assign rd_tracker_alloc_valid = start_mem_read;
    assign llc_lookup_ready = !llc_lookup_pending_q ||
                              llc_lookup_to_core_fire;
    assign llc_lookup_capture_fire = start_llc_lookup;
    assign llc_lookup_valid = llc_lookup_pending_q &&
                              !llc_update_pending_q;
    assign llc_lookup_to_core_fire = llc_lookup_valid &&
                                     llc_core_lookup_ready;
    assign llc_core_lookup_addr = llc_lookup_addr_q;
    assign snp_tracker_alloc_valid = start_backinv || start_snoop;
    assign snp_tracker_mode_backinv = start_backinv;
    assign tracker_active_valid_vec = {wr_tracker_active_valid_vec,
                                       rd_tracker_active_valid_vec,
                                       snp_tracker_active_valid_vec};
    assign tracker_active_addr_flat = {wr_tracker_active_addr_flat,
                                      rd_tracker_active_addr_flat,
                                      snp_tracker_active_addr_flat};
    assign pos_active_valid_vec =
        {front_prefetch_valid_q, tracker_active_valid_vec};
    assign pos_active_addr_flat =
        {front_prefetch_flit_q[REQ_ADDR_LSB +: ADDR_WIDTH],
         tracker_active_addr_flat};
    assign perf_counts = hn_perf_counts_unused;
    assign ecc_single_event = llc_ecc_single_error;
    assign ecc_double_event = llc_ecc_double_error;
    assign exclusive_fail_event = start_excl_fail_resp;
    assign excl_timeout_value = (cfg_excl_timeout == 16'd0) ?
                                {{(EXCL_AGE_W-1){1'b0}}, 1'b1} :
                                cfg_excl_timeout[EXCL_AGE_W-1:0];
`ifndef SYNTHESIS
    assign b5_excl_valid_flat = excl_valid_q;
    // Exclusive stores only start (start_write / start_upgrade) when they
    // pass; a failing one takes the excl_fail path.
    assign b5_excl_pass = (start_write || start_upgrade) && req_excl &&
                          req_src_is_rn;
    assign b5_excl_pass_line = req_addr[ADDR_WIDTH-1:6];

    generate
        for (b5_excl_dbg_g = 0;
             b5_excl_dbg_g < NUM_RN;
             b5_excl_dbg_g = b5_excl_dbg_g + 1) begin : gen_b5_excl_line_flat
            assign b5_excl_line_flat[b5_excl_dbg_g*LINE_ADDR_W +: LINE_ADDR_W] =
                excl_line_q[b5_excl_dbg_g];
        end
    endgenerate
`endif

    assign state_timeout_en = (state_q == HN_ST_WAIT_SF) ||
                              (state_q == HN_ST_WAIT_LLC) ||
                              (state_q == HN_ST_SEND_DAT) ||
                              (state_q == HN_ST_WAIT_ACK);
    assign state_timeout_fire = (FUNCTIONAL_TIMEOUT != 0) &&
                                state_timeout_en &&
                                (timeout_cnt_q >= TIMEOUT_VALUE);
    // One pulse per stuck episode: the counter saturates at TIMEOUT_VALUE.
    assign state_watchdog = state_timeout_en &&
                            (timeout_cnt_q == TIMEOUT_VALUE - 1'b1);
    assign watchdog_event = state_watchdog || rd_tracker_watchdog ||
                            snp_tracker_watchdog;
    assign scalar_filter_update_busy =
        start_write || start_upgrade || comp_ack_fire ||
        rd_tracker_ack_valid;
    assign snp_tracker_filter_update_ready =
        filter_update_ready && !scalar_filter_update_busy;

    assign snp_tracker_llc_update_ready =
        llc_line_update_ready;
    assign rd_tracker_llc_update_ready =
        llc_line_update_ready && !snp_tracker_llc_update_valid;
    assign llc_update_valid = snp_tracker_llc_update_valid ||
                              rd_tracker_llc_update_valid;
    assign llc_update_addr = snp_tracker_llc_update_valid ?
                             snp_tracker_llc_update_addr :
                             rd_tracker_llc_update_addr;
    assign llc_update_data = snp_tracker_llc_update_valid ?
                             snp_tracker_llc_update_data :
                             rd_tracker_llc_update_data;
    assign llc_update_state = snp_tracker_llc_update_valid ?
                              snp_tracker_llc_update_state :
                              rd_tracker_llc_update_state;
    assign llc_line_update_ready = !llc_update_pending_q ||
                                   llc_update_to_core_fire;
    assign llc_update_capture_fire = llc_update_valid &&
                                     llc_line_update_ready;
    assign llc_core_line_update_valid = llc_update_pending_q;
    assign llc_update_to_core_fire = llc_core_line_update_valid &&
                                     llc_core_line_update_ready;
    assign llc_core_line_update_addr = llc_update_addr_q;
    assign llc_core_line_update_data = llc_update_data_q;
    assign llc_core_line_update_state = llc_update_state_q;
    assign llc_invalidate_valid = start_write;
    assign llc_evict_idle = (llc_evict_state_q == EVICT_ST_IDLE);
    // WriteData to the SN carries the DBID of its own write, so an LLC
    // victim burst may interleave with RN write bursts (1.5).
    assign llc_evict_ready = llc_evict_idle &&
                             !tx_dat_link_valid;

    // Clock-gate hold. Exclusive reservations are included so their aging
    // keeps counting while the rest of the node is idle.
    assign busy = (state_q != HN_ST_IDLE) || front_prefetch_valid_q ||
                  (pos_used != 16'd0) || pos_out_valid || pos_out1_valid ||
                  dat_sink_valid || rsp_sink_valid ||
                  (|wr_tracker_active_valid_vec) ||
                  (|rd_tracker_active_valid_vec) ||
                  (|snp_tracker_active_valid_vec) ||
                  !llc_evict_idle ||
                  llc_lookup_pending_q || llc_update_pending_q ||
                  llc_busy || sf_busy ||
                  excl_fail_valid_q || err_rsp_valid_q ||
                  retry_ack_valid_q || retry_grant_pending_q ||
                  retry_grant_valid_q || resp_valid ||
                  tx_rsp_valid || tx_snp_valid || tx_dat_valid ||
                  mem_req_valid || mem_dat_valid || (|excl_valid_q);

    assign llc_evict_capture_fire = llc_evict_valid && llc_evict_ready;
    // Dirty data returned by a snoop is written to memory through the same
    // HN->SN full-line writer as an LLC victim. The LLC keeps only a clean
    // copy, and a following write or read to the line waits for this write
    // to complete (start_write/start_mem_read need llc_evict_idle).
    assign snp_tracker_wb_ready = llc_evict_idle && !llc_evict_valid &&
                                  !tx_dat_link_valid;
    assign snp_wb_capture_fire = snp_tracker_wb_valid && snp_tracker_wb_ready;
    assign llc_evict_req_valid = (llc_evict_state_q == EVICT_ST_SEND_REQ);
    assign llc_evict_req_fire = llc_evict_req_valid && mem_issuer_ready;
    assign llc_evict_dat_valid = (llc_evict_state_q == EVICT_ST_SEND_DAT);
    assign llc_evict_dat_fire = llc_evict_dat_valid && mem_dat_ready;
    assign llc_evict_comp_match =
        (llc_evict_state_q == EVICT_ST_WAIT_COMP) &&
        rsp_sink_valid &&
        ((rsp_opcode == `CHI_RSP_COMP) ||
         (rsp_opcode == `CHI_RSP_COMP_DBID)) &&
        (rsp_txn_id == LLC_EVICT_TXN_ID) &&
        (rsp_src_id == llc_evict_mem_tgt_id_r);
    assign llc_evict_comp_fire = llc_evict_comp_match;

    // One-entry launch stages cut the long HN request/update path before the
    // LLC BRAM inputs. Pending updates are issued before lookups so a refill
    // or dirty-snoop update cannot be bypassed by a younger same-line read.
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            llc_lookup_pending_q <= 1'b0;
            llc_lookup_addr_q <= {ADDR_WIDTH{1'b0}};
            llc_update_pending_q <= 1'b0;
            llc_update_addr_q <= {ADDR_WIDTH{1'b0}};
            llc_update_data_q <= {LINE_WIDTH{1'b0}};
            llc_update_state_q <= `CHI_STATE_I;
        end else begin
            if (llc_lookup_to_core_fire)
                llc_lookup_pending_q <= 1'b0;
            if (llc_lookup_capture_fire) begin
                llc_lookup_pending_q <= 1'b1;
                llc_lookup_addr_q <= req_addr;
            end

            if (llc_update_to_core_fire)
                llc_update_pending_q <= 1'b0;
            if (llc_update_capture_fire) begin
                llc_update_pending_q <= 1'b1;
                llc_update_addr_q <= llc_update_addr;
                llc_update_data_q <= llc_update_data;
                llc_update_state_q <= llc_update_state;
            end
        end
    end

    assign hn_perf_events[0]  = accept_req || front_prefetch_capture_fire;
    assign hn_perf_events[1]  = start_backinv;
    assign hn_perf_events[2]  = start_snoop;
    assign hn_perf_events[3]  = start_llc_read;
    assign hn_perf_events[4]  = start_mem_read;
    assign hn_perf_events[5]  = start_write || start_upgrade;
    assign hn_perf_events[6]  = state_timeout_fire || rd_tracker_err_valid ||
                                snp_tracker_err_valid || watchdog_event;
    assign hn_perf_events[7]  = tx_snp_valid && !tx_snp_lcrdv;
    assign hn_perf_events[8]  = tx_rsp_link_valid && !tx_rsp_link_ready;
    assign hn_perf_events[9]  = tx_dat_link_valid && !tx_dat_link_ready;
    assign hn_perf_events[10] = llc_ecc_single_error;
    assign hn_perf_events[11] = llc_ecc_double_error;
    assign hn_perf_events[12] = pos_addr_lock_stall;
    assign hn_perf_events[13] = pos_full_stall;
    assign hn_perf_events[14] = front_prefetch_capture_fire;
    assign hn_perf_events[15] = comp_ack_fire;

    always @(*) begin
        mem_tgt_bank_r = 0;
        if (NUM_SN > 1)
            mem_tgt_bank_r = (req_addr >> 6) % NUM_SN;
        mem_tgt_id_r = SN_BASE_ID_SIZED + mem_tgt_bank_r;
    end

    always @(*) begin
        llc_evict_mem_tgt_bank_r = 0;
        if (NUM_SN > 1)
            llc_evict_mem_tgt_bank_r = (llc_evict_addr_q >> 6) % NUM_SN;
        llc_evict_mem_tgt_id_r =
            SN_BASE_ID_SIZED + llc_evict_mem_tgt_bank_r;
    end

    always @(*) begin
        requestor_onehot = {NUM_RN{1'b0}};
        for (rn_idx = 0; rn_idx < NUM_RN; rn_idx = rn_idx + 1) begin
            if (req_src_id == rn_idx)
                requestor_onehot[rn_idx] = 1'b1;
        end
    end

    always @(*) begin
        excl_lookup_match_r = 1'b0;
        if (req_src_is_rn)
            excl_lookup_match_r =
                excl_valid_q[req_src_id] &&
                (excl_line_q[req_src_id] == req_addr[ADDR_WIDTH-1:6]);
    end

    always @(*) begin
        snp_rsp_onehot = {NUM_RN{1'b0}};
        for (snp_rsp_idx = 0; snp_rsp_idx < NUM_RN; snp_rsp_idx = snp_rsp_idx + 1) begin
            if (rsp_src_id == snp_rsp_idx)
                snp_rsp_onehot[snp_rsp_idx] = 1'b1;
        end
    end

    always @(*) begin
        rd_tracker_ack_sharer_vec = {NUM_RN{1'b0}};
        for (rd_ack_idx = 0; rd_ack_idx < NUM_RN; rd_ack_idx = rd_ack_idx + 1) begin
            if (rd_tracker_ack_src_id == rd_ack_idx)
                rd_tracker_ack_sharer_vec[rd_ack_idx] = 1'b1;
        end
    end

    always @(*) begin
        snp_selected_valid = 1'b0;
        snp_selected_flit  = {SNP_W{1'b0}};
        snp_selected_tgt_id = {NODE_ID_W{1'b0}};
        snp_send_onehot = {NUM_RN{1'b0}};
        for (snp_idx = 0; snp_idx < NUM_RN; snp_idx = snp_idx + 1) begin
            if (!snp_selected_valid && snp_send_mask_q[snp_idx]) begin
                snp_selected_valid = 1'b1;
                snp_send_onehot[snp_idx] = 1'b1;
                snp_selected_flit = snp_flit_flat[snp_idx*SNP_W +: SNP_W];
                snp_selected_tgt_id = snp_idx;
            end
        end
    end

    always @(*) begin
        mem_req_flit_pre = llc_evict_req_valid ?
                           llc_evict_req_flit : parser_flit;
        if (!llc_evict_req_valid) begin
            mem_req_flit_pre[REQ_OPCODE_LSB +: `CHI_REQ_OPCODE_W] =
                req_is_write ? `CHI_REQ_WR_NO_SNP : `CHI_REQ_RD_NO_SNP;
            // HN always moves whole lines to and from the SN, and the SN
            // turns the address into an INCR burst start. A request for a
            // word inside the line (e.g. LDREX) must still fetch from the
            // start of the line, or an AXI slave returns the wrong beats.
            mem_req_flit_pre[REQ_ADDR_LSB +: ADDR_WIDTH] =
                {req_addr[ADDR_WIDTH-1:6], 6'b0};
            mem_req_flit_pre[REQ_SIZE_LSB +: 3] = 3'd6;
            mem_req_flit_pre[REQ_TXN_LSB +: TXN_ID_W] =
                req_is_write ? wr_tracker_alloc_mem_txn_id :
                               rd_tracker_alloc_mem_txn_id;
            mem_req_flit_pre[REQ_SRC_LSB +: NODE_ID_W] = NODE_ID;
            mem_req_flit_pre[REQ_TGT_LSB +: NODE_ID_W] = mem_tgt_id_sel;
        end
    end

    always @(*) begin
        mem_dat_flit = llc_evict_dat_flit;
        if (!llc_evict_dat_valid && dat_forward_to_mem) begin
            mem_dat_flit = dat_sink_flit;
            // WriteData to the SN carries the SN's DBID as its TxnID.
            mem_dat_flit[DAT_TXN_LSB +: TXN_ID_W] =
                wr_tracker_wdat_sn_dbid;
            mem_dat_flit[DAT_SRC_LSB +: NODE_ID_W] = NODE_ID;
            mem_dat_flit[DAT_TGT_LSB +: NODE_ID_W] =
                wr_tracker_wdat_mem_tgt_id;
            mem_dat_flit[DAT_HOME_NID_LSB +: NODE_ID_W] = NODE_ID;
            mem_dat_flit[DAT_DBID_LSB +: DBID_W] = wr_tracker_wdat_sn_dbid;
            if (wr_tracker_wdat_discard)
                mem_dat_flit[DAT_BE_LSB +: BE_W] = {BE_W{1'b0}};
        end
    end

    always @(*) begin
        llc_evict_req_flit = {REQ_W{1'b0}};
        llc_evict_req_flit[REQ_ADDR_LSB +: ADDR_WIDTH] = llc_evict_addr_q;
        llc_evict_req_flit[REQ_SIZE_LSB +: 3] = 3'd6;
        llc_evict_req_flit[REQ_OPCODE_LSB +: `CHI_REQ_OPCODE_W] = `CHI_REQ_WR_NO_SNP;
        llc_evict_req_flit[REQ_TXN_LSB +: TXN_ID_W] = LLC_EVICT_TXN_ID;
        llc_evict_req_flit[REQ_SRC_LSB +: NODE_ID_W] = NODE_ID;
        llc_evict_req_flit[REQ_TGT_LSB +: NODE_ID_W] =
            llc_evict_mem_tgt_id_r;
        llc_evict_req_flit[REQ_QOS_LSB +: QOS_W] = {QOS_W{1'b0}};
    end

    always @(*) begin
        llc_evict_dat_flit = {DAT_W{1'b0}};
        llc_evict_dat_flit[DAT_RESPERR_LSB +: 2] = `CHI_RESPERR_OK;
        llc_evict_dat_flit[DAT_BE_LSB +: BE_W] = {BE_W{1'b1}};
        llc_evict_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] =
            llc_evict_data_q[llc_evict_beat_q*DATA_WIDTH +: DATA_WIDTH];
        llc_evict_dat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W] = llc_evict_data_id;
        llc_evict_dat_flit[DAT_DBID_LSB +: DBID_W] = llc_evict_sn_dbid_q;
        llc_evict_dat_flit[DAT_TXN_LSB +: TXN_ID_W] = llc_evict_sn_dbid_q;
        llc_evict_dat_flit[DAT_SRC_LSB +: NODE_ID_W] = NODE_ID;
        llc_evict_dat_flit[DAT_TGT_LSB +: NODE_ID_W] =
            llc_evict_mem_tgt_id_r;
        llc_evict_dat_flit[DAT_RESP_LSB +: 3] = 3'd0;
        llc_evict_dat_flit[DAT_OPCODE_LSB +: 4] = `CHI_DAT_OPCODE_WB_DATA;
        llc_evict_dat_flit[DAT_QOS_LSB +: `CHI_DAT_QOS_W] =
            {`CHI_DAT_QOS_W{1'b0}};
        llc_evict_dat_flit[DAT_HOME_NID_LSB +: NODE_ID_W] = NODE_ID;
    end

    always @(*) begin
        resp_dat_flit = {DAT_W{1'b0}};
        resp_dat_flit[DAT_RESPERR_LSB +: 2]       = `CHI_RESPERR_OK;
        resp_dat_flit[DAT_BE_LSB +: BE_W]         = {BE_W{1'b1}};
        resp_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] =
            llc_data_q[resp_beat_q*DATA_WIDTH +: DATA_WIDTH];
        resp_dat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W] = resp_data_id;
        resp_dat_flit[DAT_DBID_LSB +: DBID_W]     = DBID_MAIN;
        resp_dat_flit[DAT_TXN_LSB +: TXN_ID_W]    = req_txn_id;
        resp_dat_flit[DAT_SRC_LSB +: NODE_ID_W]   = NODE_ID;
        resp_dat_flit[DAT_TGT_LSB +: NODE_ID_W]   = req_src_id;
        resp_dat_flit[DAT_RESP_LSB +: 3]          =
            `CHI_COMPDATA_RESP_FOR(req_opcode);
        resp_dat_flit[DAT_OPCODE_LSB +: 4]        = `CHI_DAT_OPCODE_RD_DATA;
        resp_dat_flit[DAT_QOS_LSB +: `CHI_DAT_QOS_W] = req_qos_dat;
        resp_dat_flit[DAT_HOME_NID_LSB +: NODE_ID_W] = NODE_ID;
    end

    always @(*) begin
        wr_comp_flit = {RSP_W{1'b0}};
        wr_comp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        wr_comp_flit[RSP_RESPERR_LSB +: 2]     = wr_tracker_rsp_resp_err;
        wr_comp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        wr_comp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_COMP;
        wr_comp_flit[RSP_TXN_LSB +: TXN_ID_W]  = wr_tracker_rsp_txn_id;
        wr_comp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        wr_comp_flit[RSP_TGT_LSB +: NODE_ID_W] = wr_tracker_rsp_tgt_id;
        wr_comp_flit[RSP_QOS_LSB +: QOS_W]     = wr_tracker_rsp_qos;
    end

    // DBIDResp to the requester (CompDBIDResp for a CopyBack, B2.3.2.3).
    always @(*) begin
        wr_dbid_rsp_flit = {RSP_W{1'b0}};
        wr_dbid_rsp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        wr_dbid_rsp_flit[RSP_RESPERR_LSB +: 2]     = wr_tracker_dbid_rsp_resp_err;
        wr_dbid_rsp_flit[RSP_DBID_LSB +: DBID_W]   = wr_tracker_dbid_rsp_dbid;
        wr_dbid_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] =
            wr_tracker_dbid_rsp_copyback ? `CHI_RSP_COMP_DBID : `CHI_RSP_DBID;
        wr_dbid_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = wr_tracker_dbid_rsp_txn_id;
        wr_dbid_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        wr_dbid_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = wr_tracker_dbid_rsp_tgt_id;
        wr_dbid_rsp_flit[RSP_QOS_LSB +: QOS_W]     = wr_tracker_dbid_rsp_qos;
    end

    always @(*) begin
        excl_fail_rsp_flit = {RSP_W{1'b0}};
        excl_fail_rsp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        excl_fail_rsp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_OK;
        excl_fail_rsp_flit[RSP_DBID_LSB +: DBID_W]   = DBID_MAIN;
        excl_fail_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_COMP;
        excl_fail_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = excl_fail_txn_q;
        excl_fail_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        excl_fail_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = excl_fail_tgt_q;
        excl_fail_rsp_flit[RSP_QOS_LSB +: QOS_W]     = excl_fail_qos_q;
    end

    always @(*) begin
        err_rsp_flit = {RSP_W{1'b0}};
        err_rsp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        err_rsp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_SLVERR;
        err_rsp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        err_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_COMP;
        err_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = err_txn_q;
        err_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        err_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = err_tgt_q;
        err_rsp_flit[RSP_QOS_LSB +: QOS_W]     = err_qos_q;
    end

    always @(*) begin
        retry_rsp_flit = {RSP_W{1'b0}};
        retry_rsp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        retry_rsp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_OK;
        retry_rsp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        retry_rsp_flit[`CHI_RSP_PCRD_TYPE_LSB(NODE_ID_W) +: `CHI_REQ_PCRD_TYPE_W] =
            retry_pcrd_type_q;
        retry_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] =
            retry_ack_valid_q ? `CHI_RSP_RETRY_ACK : `CHI_RSP_PCRD_GRANT;
        retry_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = retry_txn_q;
        retry_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID;
        retry_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = retry_tgt_q;
        retry_rsp_flit[RSP_QOS_LSB +: QOS_W]     = retry_qos_q;
    end

    always @(*) begin
        filter_update_valid = 1'b0;
        filter_update_invalidate = 1'b0;
        filter_update_merge = 1'b0;
        filter_update_addr = filter_active_req_addr;
        // No requester keeps a copy of a line it writes: a CopyBack gives the
        // line up, and a WriteUnique comes from an RN that does not hold it
        // (the internal RN cache and the external L1 both drop or write back
        // their copy first). Old sharers were snooped away, so the SF entry
        // is left with no sharers. WRITE_THROUGH_NO_ALLOCATE no longer
        // changes this.
        filter_update_state = (req_is_write || req_is_upgrade) ? 2'b10 : 2'b01;
        filter_update_sharer_vec =
            req_is_write ? {NUM_RN{1'b0}} : requestor_onehot;

        if ((start_write && !copyback_stale) || start_upgrade) begin
            filter_update_valid = 1'b1;
        end else if (comp_ack_fire && req_is_read) begin
            filter_update_valid = 1'b1;
            // Shared-read completions add the requester to the existing
            // sharers; only unique reads may replace the sharer vector.
            filter_update_merge = !req_is_write && !req_is_upgrade &&
                                  (req_opcode != `CHI_REQ_RD_UNIQUE);
        end else if (rd_tracker_ack_valid) begin
            filter_update_valid = 1'b1;
            filter_update_merge = rd_tracker_ack_shared;
            filter_update_addr = rd_tracker_ack_addr;
            filter_update_state = 2'b01;
            filter_update_sharer_vec = rd_tracker_ack_sharer_vec;
        end else if (snp_tracker_filter_update_valid) begin
            filter_update_valid = 1'b1;
            filter_update_invalidate = snp_tracker_filter_update_invalidate;
            filter_update_addr = snp_tracker_filter_update_addr;
            filter_update_state = snp_tracker_filter_update_state;
            filter_update_sharer_vec = snp_tracker_filter_update_sharer_vec;
        end
    end

    always @(posedge clk) begin
        if (rstn && llc_evict_dbid_match)
            llc_evict_sn_dbid_q <= rsp_dbid;
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (llc_evict_capture_fire)
                llc_evict_data_q <= llc_evict_data;
            else if (snp_wb_capture_fire)
                llc_evict_data_q <= snp_tracker_wb_data;
        end
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (llc_evict_capture_fire)
                llc_evict_addr_q <= llc_evict_addr;
            else if (snp_wb_capture_fire)
                llc_evict_addr_q <= snp_tracker_wb_addr;

            if (state_timeout_fire) begin
                if (state_q != HN_ST_WAIT_ACK) begin
                    err_txn_q <= req_txn_id;
                    err_tgt_q <= req_src_id;
                    err_qos_q <= req_qos;
                end
            end else begin
                case (state_q)
                    HN_ST_IDLE,
                    HN_ST_WAIT_SF: begin
                        if (accept_req) begin
                            if (state_q == HN_ST_IDLE)
                                hold_req_flit_q <= parser_flit;

                            if (start_excl_fail_resp) begin
                                excl_fail_txn_q <= req_txn_id;
                                excl_fail_tgt_q <= req_src_id;
                                excl_fail_qos_q <= req_qos;
                            end
                        end
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= HN_ST_IDLE;
            front_prefetch_valid_q <= 1'b0;
            front_prefetch_flit_q <= {REQ_W{1'b0}};
            snp_send_mask_q <= {NUM_RN{1'b0}};
            snp_wait_mask_q <= {NUM_RN{1'b0}};
            resp_beat_q <= 4'd0;
            sf_lookup_issued_q <= 1'b0;
            sf_lookup_addr_q <= {ADDR_WIDTH{1'b0}};
            llc_result_valid_q <= 1'b0;
            llc_hit_q <= 1'b0;
            excl_fail_valid_q <= 1'b0;
            excl_valid_q <= {NUM_RN{1'b0}};
            for (excl_seq_idx = 0;
                 excl_seq_idx < NUM_RN;
                 excl_seq_idx = excl_seq_idx + 1) begin
                excl_line_q[excl_seq_idx] <= {LINE_ADDR_W{1'b0}};
                excl_age_q[excl_seq_idx] <= {EXCL_AGE_W{1'b0}};
            end
            err_rsp_valid_q <= 1'b0;
            retry_ack_valid_q <= 1'b0;
            retry_grant_pending_q <= 1'b0;
            retry_grant_valid_q <= 1'b0;
            retry_txn_q <= {TXN_ID_W{1'b0}};
            retry_tgt_q <= {NODE_ID_W{1'b0}};
            retry_qos_q <= {QOS_W{1'b0}};
            retry_opcode_q <= {`CHI_REQ_OPCODE_W{1'b0}};
            retry_pcrd_type_q <= `CHI_REQ_PCRD_TYPE_GENERIC;
            timeout_cnt_q <= {TIMEOUT_W{1'b0}};
            llc_evict_state_q <= EVICT_ST_IDLE;
            llc_evict_beat_q <= 4'd0;
        end else begin
            if (front_prefetch_launch_fire)
                front_prefetch_valid_q <= 1'b0;

            if (front_prefetch_capture0_fire) begin
                front_prefetch_valid_q <= 1'b1;
                front_prefetch_flit_q <= pos_out_flit;
            end else if (front_prefetch_capture1_fire) begin
                front_prefetch_valid_q <= 1'b1;
                front_prefetch_flit_q <= pos_out1_flit;
            end

            if (excl_fail_valid_q && tx_rsp_link_ready &&
                !resp_valid && !wr_tracker_rsp_valid &&
                !wr_tracker_dbid_rsp_valid)
                excl_fail_valid_q <= 1'b0;

            if (err_rsp_valid_q && err_rsp_ready)
                err_rsp_valid_q <= 1'b0;

            if (retry_ack_fire)
                retry_ack_valid_q <= 1'b0;

            if (retry_grant_fire)
                retry_grant_valid_q <= 1'b0;

            if (retry_grant_pending_q &&
                !retry_grant_valid_q &&
                !retry_ack_valid_q &&
                retry_grant_resource_ready) begin
                retry_grant_pending_q <= 1'b0;
                retry_grant_valid_q <= 1'b1;
            end

            if (retry_capture_fire) begin
                retry_ack_valid_q <= 1'b1;
                retry_grant_pending_q <= 1'b1;
                retry_grant_valid_q <= 1'b0;
                retry_txn_q <= retry_capture_txn_id;
                retry_tgt_q <= retry_capture_src_id;
                retry_qos_q <= retry_capture_qos;
                retry_opcode_q <= retry_capture_opcode;
                retry_pcrd_type_q <= retry_capture_pcrd_type;
            end

            if (llc_evict_capture_fire || snp_wb_capture_fire) begin
                llc_evict_state_q <= EVICT_ST_SEND_REQ;
                llc_evict_beat_q <= 4'd0;
            end else if (llc_evict_req_fire) begin
                llc_evict_state_q <= EVICT_ST_WAIT_DBID;
                llc_evict_beat_q <= 4'd0;
            end else if (llc_evict_dbid_match) begin
                llc_evict_state_q <= EVICT_ST_SEND_DAT;
            end else if (llc_evict_dat_fire) begin
                if (llc_evict_beat_q == (BEATS - 1)) begin
                    llc_evict_state_q <= EVICT_ST_WAIT_COMP;
                    llc_evict_beat_q <= 4'd0;
                end else begin
                    llc_evict_beat_q <= llc_evict_beat_q + 1'b1;
                end
            end else if (llc_evict_comp_fire) begin
                llc_evict_state_q <= EVICT_ST_IDLE;
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

            if (start_sf_stage) begin
                sf_lookup_addr_q <= req_addr;
                sf_lookup_issued_q <= 1'b0;
            end else if (start_sf_lookup) begin
                sf_lookup_issued_q <= 1'b1;
            end

            for (excl_seq_idx = 0;
                 excl_seq_idx < NUM_RN;
                 excl_seq_idx = excl_seq_idx + 1) begin
                if (!excl_valid_q[excl_seq_idx]) begin
                    excl_age_q[excl_seq_idx] <= {EXCL_AGE_W{1'b0}};
                end else if (excl_age_q[excl_seq_idx] >= excl_timeout_value) begin
                    excl_valid_q[excl_seq_idx] <= 1'b0;
                    excl_age_q[excl_seq_idx] <= {EXCL_AGE_W{1'b0}};
                end else begin
                    excl_age_q[excl_seq_idx] <=
                        excl_age_q[excl_seq_idx] + 1'b1;
                end
            end

            if (start_backinv) begin
                for (excl_seq_idx = 0;
                     excl_seq_idx < NUM_RN;
                     excl_seq_idx = excl_seq_idx + 1) begin
                    if (excl_valid_q[excl_seq_idx] &&
                        (excl_line_q[excl_seq_idx] == backinv_addr[ADDR_WIDTH-1:6])) begin
                        excl_valid_q[excl_seq_idx] <= 1'b0;
                        excl_age_q[excl_seq_idx] <= {EXCL_AGE_W{1'b0}};
                    end
                end
            end

            if (start_write || start_upgrade) begin
                for (excl_seq_idx = 0;
                     excl_seq_idx < NUM_RN;
                     excl_seq_idx = excl_seq_idx + 1) begin
                    if (excl_valid_q[excl_seq_idx] &&
                        (excl_line_q[excl_seq_idx] == req_addr[ADDR_WIDTH-1:6])) begin
                        excl_valid_q[excl_seq_idx] <= 1'b0;
                        excl_age_q[excl_seq_idx] <= {EXCL_AGE_W{1'b0}};
                    end
                end
            end

            // (An exclusive that fails gains nothing and ends nothing.)
            if (accept_req && !start_excl_fail_resp && req_src_is_rn &&
                ((req_opcode == `CHI_REQ_RD_UNIQUE) || req_is_upgrade)) begin
                for (excl_seq_idx = 0;
                     excl_seq_idx < NUM_RN;
                     excl_seq_idx = excl_seq_idx + 1) begin
                    if ((excl_seq_idx != req_src_id) &&
                        excl_valid_q[excl_seq_idx] &&
                        (excl_line_q[excl_seq_idx] == req_addr[ADDR_WIDTH-1:6])) begin
                        excl_valid_q[excl_seq_idx] <= 1'b0;
                        excl_age_q[excl_seq_idx] <= {EXCL_AGE_W{1'b0}};
                    end
                end
            end

            if (start_excl_fail_resp && req_src_is_rn) begin
                excl_valid_q[req_src_id] <= 1'b0;
                excl_age_q[req_src_id] <= {EXCL_AGE_W{1'b0}};
            end

            if (comp_ack_fire && req_excl && req_is_read &&
                req_src_is_rn) begin
                excl_valid_q[req_src_id] <= 1'b1;
                excl_line_q[req_src_id] <= req_addr[ADDR_WIDTH-1:6];
                excl_age_q[req_src_id] <= {EXCL_AGE_W{1'b0}};
            end

            if (rd_tracker_ack_valid && rd_tracker_ack_excl &&
                (rd_tracker_ack_src_id < NUM_RN)) begin
                excl_valid_q[rd_tracker_ack_src_id] <= 1'b1;
                excl_line_q[rd_tracker_ack_src_id] <=
                    rd_tracker_ack_addr[ADDR_WIDTH-1:6];
                excl_age_q[rd_tracker_ack_src_id] <= {EXCL_AGE_W{1'b0}};
            end

            if (snp_tracker_ack_valid && snp_tracker_ack_excl &&
                (snp_tracker_ack_src_id < NUM_RN)) begin
                excl_valid_q[snp_tracker_ack_src_id] <= 1'b1;
                excl_line_q[snp_tracker_ack_src_id] <=
                    snp_tracker_ack_addr[ADDR_WIDTH-1:6];
                excl_age_q[snp_tracker_ack_src_id] <= {EXCL_AGE_W{1'b0}};
            end

            if (retry_parser_fire) begin
                state_q <= HN_ST_IDLE;
                snp_send_mask_q <= {NUM_RN{1'b0}};
                snp_wait_mask_q <= {NUM_RN{1'b0}};
                resp_beat_q <= 4'd0;
                sf_lookup_issued_q <= 1'b0;
                sf_lookup_addr_q <= {ADDR_WIDTH{1'b0}};
                llc_result_valid_q <= 1'b0;
                llc_hit_q <= 1'b0;
                timeout_cnt_q <= {TIMEOUT_W{1'b0}};
            end else if (state_timeout_fire) begin
                if (state_q != HN_ST_WAIT_ACK) begin
                    err_rsp_valid_q <= 1'b1;
                end
                state_q <= HN_ST_IDLE;
                snp_send_mask_q <= {NUM_RN{1'b0}};
                snp_wait_mask_q <= {NUM_RN{1'b0}};
                resp_beat_q <= 4'd0;
                sf_lookup_issued_q <= 1'b0;
                sf_lookup_addr_q <= {ADDR_WIDTH{1'b0}};
                llc_result_valid_q <= 1'b0;
                llc_hit_q <= 1'b0;
                timeout_cnt_q <= {TIMEOUT_W{1'b0}};
            end else begin
            if (start_llc_lookup) begin
                llc_result_valid_q <= 1'b0;
                llc_hit_q <= 1'b0;
            end else if ((state_q == HN_ST_WAIT_LLC) &&
                         llc_lookup_result_valid) begin
                llc_result_valid_q <= 1'b1;
                llc_hit_q <= llc_hit;
            end

            if (start_llc_read || start_mem_read) begin
                llc_result_valid_q <= 1'b0;
            end

            case (state_q)
                HN_ST_IDLE,
                HN_ST_WAIT_SF: begin
                    if (accept_req) begin
                        if (start_excl_fail_resp) begin
                            excl_fail_valid_q <= 1'b1;
                            state_q <= req_is_clean_unique ?
                                       HN_ST_WAIT_ACK : HN_ST_IDLE;
                        end else if (start_upgrade) begin
                            // CleanUnique and MakeUnique: the CompAck
                            // releases the line (B5.6.4).
                            state_q <= HN_ST_WAIT_ACK;
                        end else if (start_sf_stage) begin
                            state_q <= HN_ST_WAIT_SF;
                        end else if (start_backinv) begin
                            snp_send_mask_q <= {NUM_RN{1'b0}};
                            snp_wait_mask_q <= {NUM_RN{1'b0}};
                            state_q <= HN_ST_IDLE;
                        end else if (start_snoop) begin
                            snp_send_mask_q <= {NUM_RN{1'b0}};
                            snp_wait_mask_q <= {NUM_RN{1'b0}};
                            state_q <= HN_ST_IDLE;
                        end else if (start_llc_lookup) begin
                            state_q <= HN_ST_WAIT_LLC;
                        end else begin
                            state_q <= HN_ST_IDLE;
                        end
                    end
                end

                HN_ST_WAIT_LLC: begin
                    if (start_llc_read) begin
                        resp_beat_q <= 4'd0;
                        state_q <= HN_ST_SEND_DAT;
                    end else if (start_mem_read) begin
                        state_q <= HN_ST_IDLE;
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

    always @(posedge clk) begin
        if (rstn &&
            (state_q == HN_ST_WAIT_LLC) &&
            llc_lookup_result_valid) begin
            llc_data_q <= llc_data;
        end
    end

    chi_hn_pos_buffer #(
        .FLIT_W(REQ_W),
        .DEPTH(POS_DEPTH),
        .ACTIVE_SLOTS(POS_ACTIVE_SLOTS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .TXN_ID_W(TXN_ID_W),
        .NODE_ID_W(NODE_ID_W),
        .QOS_W(QOS_W)
    ) u_pos_buffer (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(pos_in_valid),
        .in_ready(pos_in_ready),
        .in_flit(rx_req_flit),
        .out_valid(pos_out_valid),
        .out_ready(pos_out_ready),
        .out_flit(pos_out_flit),
        .pop_pulse(pos_pop_pulse),
        .out1_valid(pos_out1_valid),
        .out1_ready(pos_out1_ready),
        .out1_flit(pos_out1_flit),
        .pop1_pulse(pos_pop1_pulse),
        .used_count(pos_used),
        .active_valid(state_q != HN_ST_IDLE),
        .active_addr(pos_active_addr),
        .active_valid_vec(pos_active_valid_vec),
        .active_addr_flat(pos_active_addr_flat),
        .addr_lock_stall(pos_addr_lock_stall),
        .full_stall(pos_full_stall)
    );

    chi_fifo #(
        .WIDTH(DAT_W),
        .DEPTH(SINK_FIFO_DEPTH),
        .BYPASS_READY(0)
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
        .pop_pulse(dat_sink_pop_unused),
        .used_count(dat_sink_used_unused)
    );

    chi_fifo #(
        .WIDTH(RSP_W),
        .DEPTH(SINK_FIFO_DEPTH),
        .BYPASS_READY(0)
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
        .pop_pulse(rsp_sink_pop_unused),
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
        .qos(req_qos),
        .excl(req_excl),
        .order(req_order_unused),
        .allow_retry(req_allow_retry),
        .pcrd_type(req_pcrd_type),
        .exp_comp_ack(req_exp_comp_ack_unused),
        .memattr(req_memattr_unused),
        .snpattr(req_snpattr_unused),
        .pas(req_pas_unused),
        .trace_tag(req_trace_tag_unused)
    );

    chi_hn_snoop_filter #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_RN(NUM_RN),
        .ENTRIES(SF_ENTRIES)
    ) u_snoop_filter (
        .clk(clk),
        .rstn(rstn),
        .busy(sf_busy),
        .clear(1'b0),
        .lookup_valid(sf_lookup_valid),
        .lookup_ready(sf_lookup_ready),
        .lookup_addr(sf_lookup_addr_q),
        .lookup_result_valid(sf_result_valid),
        .lookup_hit(filter_hit),
        .lookup_state(filter_state),
        .lookup_sharer_vec(filter_sharer_vec),
        .update_valid(filter_update_valid),
        .update_ready(filter_update_ready),
        .update_addr(filter_update_addr),
        .update_state(filter_update_state),
        .update_sharer_vec(filter_update_sharer_vec),
        .update_invalidate(filter_update_invalidate),
        .update_merge(filter_update_merge),
        .backinv_valid(backinv_valid),
        .backinv_addr(backinv_addr),
        .backinv_sharer_vec(backinv_sharer_vec)
    );

    chi_hn_llc #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .LINES(LLC_LINES),
        .WAYS(LLC_WAYS),
        .ENABLE_ECC(ENABLE_LLC_ECC)
    ) u_llc (
        .clk(clk),
        .rstn(rstn),
        .busy(llc_busy),
        .clear(1'b0),
        .lookup_valid(llc_lookup_valid),
        .lookup_ready(llc_core_lookup_ready),
        .lookup_addr(llc_core_lookup_addr),
        .lookup_result_valid(llc_lookup_result_valid),
        .lookup_hit(llc_hit),
        .lookup_state(llc_state_unused),
        .lookup_data(llc_data),
        .lookup_ecc_single_error(llc_ecc_single_error),
        .lookup_ecc_double_error(llc_ecc_double_error),
        .line_update_valid(llc_core_line_update_valid),
        .line_update_ready(llc_core_line_update_ready),
        .line_update_addr(llc_core_line_update_addr),
        .line_update_data(llc_core_line_update_data),
        .line_update_state(llc_core_line_update_state),
        .line_invalidate_valid(llc_invalidate_valid),
        .line_invalidate_ready(llc_invalidate_ready),
        .line_invalidate_addr(req_addr),
        .evict_valid(llc_evict_valid),
        .evict_ready(llc_evict_ready),
        .evict_addr(llc_evict_addr),
        .evict_data(llc_evict_data),
        .evict_state(llc_evict_state_unused)
    );

    generate
        if (ENABLE_PERF != 0) begin : gen_hn_perf_on
            chi_perf_counter #(
                .NUM_EVENTS(16),
                .COUNTER_W(32)
            ) u_hn_perf_counter (
                .clk(clk),
                .rstn(rstn),
                .clear(1'b0),
                .enable(1'b1),
                .event_inc(hn_perf_events),
                .count_flat(hn_perf_counts_unused)
            );
        end else begin : gen_hn_perf_off
            assign hn_perf_counts_unused = {16*32{1'b0}};
        end
    endgenerate

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
        .req_size(snp_size_sel),
        .hn_node_id(NODE_ID_SIZED),
        .requestor_id(snp_requestor_sel),
        .qos(req_qos),
        .sharer_vec(snp_sharer_sel),
        .snp_valid_vec(snp_valid_vec),
        .snp_flit_flat(snp_flit_flat)
    );

    chi_hn_write_tracker #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .DEPTH(WRITE_TRACKER_DEPTH),
        .HN_BANK_BITS(4),
        .HN_BANK_ID(NODE_ID - NUM_RN)
    ) u_write_tracker (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .alloc_valid(wr_tracker_alloc_valid),
        .alloc_ready(wr_tracker_alloc_ready),
        .alloc_txn_id(req_txn_id),
        .alloc_src_id(req_src_id),
        .alloc_qos(req_qos),
        .alloc_resp_err(req_excl ? `CHI_RESPERR_EXOKAY : `CHI_RESPERR_OK),
        .alloc_addr(req_addr),
        .alloc_mem_tgt_id(mem_tgt_id_sel),
        .alloc_copyback(req_is_copyback),
        .alloc_discard(copyback_stale),
        .alloc_dbid(wr_tracker_alloc_dbid),
        .alloc_mem_txn_id(wr_tracker_alloc_mem_txn_id),
        .comp_valid(wr_tracker_comp_valid),
        .comp_ready(wr_tracker_comp_ready),
        .comp_txn_id(rsp_txn_id),
        .comp_src_id(rsp_src_id),
        .comp_match(wr_tracker_comp_match),
        .sn_dbid_valid(wr_tracker_sn_dbid_valid),
        .sn_dbid(rsp_dbid),
        .sn_dbid_match(wr_tracker_sn_dbid_match),
        .wdat_dbid(dat_dbid),
        .wdat_src_id(dat_src_id),
        .wdat_txn_id(dat_txn_id),
        .wdat_match(wr_tracker_wdat_match),
        .wdat_mem_txn_id(wr_tracker_wdat_mem_txn_id),
        .wdat_mem_tgt_id(wr_tracker_wdat_mem_tgt_id),
        .wdat_sn_ready(wr_tracker_wdat_sn_ready),
        .wdat_sn_dbid(wr_tracker_wdat_sn_dbid),
        .wdat_discard(wr_tracker_wdat_discard),
        .dbid_rsp_valid(wr_tracker_dbid_rsp_valid),
        .dbid_rsp_ready(wr_tracker_dbid_rsp_ready),
        .dbid_rsp_txn_id(wr_tracker_dbid_rsp_txn_id),
        .dbid_rsp_tgt_id(wr_tracker_dbid_rsp_tgt_id),
        .dbid_rsp_qos(wr_tracker_dbid_rsp_qos),
        .dbid_rsp_dbid(wr_tracker_dbid_rsp_dbid),
        .dbid_rsp_resp_err(wr_tracker_dbid_rsp_resp_err),
        .dbid_rsp_copyback(wr_tracker_dbid_rsp_copyback),
        .rsp_valid(wr_tracker_rsp_valid),
        .rsp_ready(wr_tracker_rsp_ready),
        .rsp_txn_id(wr_tracker_rsp_txn_id),
        .rsp_tgt_id(wr_tracker_rsp_tgt_id),
        .rsp_qos(wr_tracker_rsp_qos),
        .rsp_resp_err(wr_tracker_rsp_resp_err),
        .active_valid_vec(wr_tracker_active_valid_vec),
        .active_addr_flat(wr_tracker_active_addr_flat),
        .used_count(wr_tracker_used_unused)
    );

    chi_hn_read_tracker #(
        .NODE_ID(NODE_ID),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .DEPTH(READ_TRACKER_DEPTH),
        .DBID_BASE(DBID_RD_BASE),
        .LINE_BYTES(LINE_BYTES),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .FUNCTIONAL_TIMEOUT(FUNCTIONAL_TIMEOUT),
        .RSP_W(RSP_W)
    ) u_read_tracker (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .alloc_valid(rd_tracker_alloc_valid),
        .alloc_ready(rd_tracker_alloc_ready),
        .alloc_txn_id(req_txn_id),
        .alloc_src_id(req_src_id),
        .alloc_qos(req_qos),
        .alloc_addr(req_addr),
        .alloc_opcode(req_opcode),
        .alloc_excl(req_excl),
        .alloc_mem_tgt_id(mem_tgt_id_sel),
        .alloc_mem_txn_id(rd_tracker_alloc_mem_txn_id),
        .dat_valid(dat_sink_valid),
        .dat_ready(rd_tracker_dat_ready),
        .dat_match(rd_tracker_dat_match),
        .dat_flit(dat_sink_flit),
        .comp_ack_valid(rsp_sink_valid &&
                        (rsp_opcode == `CHI_RSP_COMP_ACK)),
        .comp_ack_ready(rd_tracker_comp_ack_ready),
        .comp_ack_match(rd_tracker_comp_ack_match),
        .comp_ack_txn_id(rsp_txn_id),
        .comp_ack_src_id(rsp_src_id),
        .tx_dat_valid(rd_tracker_tx_dat_valid),
        .tx_dat_ready(rd_tracker_tx_dat_ready),
        .tx_dat_flit(rd_tracker_tx_dat_flit),
        .llc_update_valid(rd_tracker_llc_update_valid),
        .llc_update_ready(rd_tracker_llc_update_ready),
        .llc_update_addr(rd_tracker_llc_update_addr),
        .llc_update_data(rd_tracker_llc_update_data),
        .llc_update_state(rd_tracker_llc_update_state),
        .ack_valid(rd_tracker_ack_valid),
        .ack_addr(rd_tracker_ack_addr),
        .ack_src_id(rd_tracker_ack_src_id),
        .ack_excl(rd_tracker_ack_excl),
        .ack_shared(rd_tracker_ack_shared),
        .err_valid(rd_tracker_err_valid),
        .err_ready(rd_tracker_err_ready),
        .err_flit(rd_tracker_err_flit),
        .active_valid_vec(rd_tracker_active_valid_vec),
        .active_addr_flat(rd_tracker_active_addr_flat),
        .used_count(rd_tracker_used_unused),
        .watchdog(rd_tracker_watchdog)
    );

    chi_hn_snoop_tracker #(
        .NODE_ID(NODE_ID),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .NUM_RN(NUM_RN),
        .DEPTH(SNOOP_TRACKER_DEPTH),
        .DBID_BASE(DBID_SNP_BASE),
        .LINE_BYTES(LINE_BYTES),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .FUNCTIONAL_TIMEOUT(FUNCTIONAL_TIMEOUT),
        .REQ_W(REQ_W),
        .SNP_W(SNP_W),
        .DAT_W(DAT_W),
        .RSP_W(RSP_W)
    ) u_snoop_tracker (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .alloc_valid(snp_tracker_alloc_valid),
        .alloc_ready(snp_tracker_alloc_ready),
        .alloc_mode_backinv(snp_tracker_mode_backinv),
        .alloc_replay_flit(parser_flit),
        .alloc_active_addr(req_addr),
        .alloc_snp_addr(snp_addr_sel),
        .alloc_txn_id(req_txn_id),
        .alloc_src_id(req_src_id),
        .alloc_qos(req_qos),
        .alloc_opcode(req_opcode),
        .alloc_excl(req_excl),
        .alloc_req_is_read(req_is_read),
        .alloc_req_is_write(req_is_write || req_is_upgrade),
        .alloc_requestor_onehot(requestor_onehot),
        .alloc_snp_valid_vec(snp_valid_vec),
        .alloc_snp_flit_flat(snp_flit_flat),
        .tx_snp_valid(snp_tracker_tx_snp_valid),
        .tx_snp_ready(snp_tracker_tx_snp_ready),
        .tx_snp_flit(snp_tracker_tx_snp_flit),
        .tx_snp_tgt_id(snp_tracker_tx_snp_tgt_id),
        .rsp_valid(rsp_sink_valid &&
                   ((rsp_opcode == `CHI_RSP_SNP_RESP) ||
                    (rsp_opcode == `CHI_RSP_SNP_RESP_FWD))),
        .rsp_ready(snp_tracker_rsp_ready),
        .rsp_match(snp_tracker_rsp_match),
        .rsp_fwded(rsp_opcode == `CHI_RSP_SNP_RESP_FWD),
        .rsp_txn_id(rsp_txn_id),
        .rsp_src_id(rsp_src_id),
        .dat_valid(dat_sink_valid),
        .dat_ready(snp_tracker_dat_ready),
        .dat_match(snp_tracker_dat_match),
        .dat_flit(dat_sink_flit),
        .comp_ack_valid(rsp_sink_valid && (rsp_opcode == `CHI_RSP_COMP_ACK)),
        .comp_ack_ready(snp_tracker_comp_ack_ready),
        .comp_ack_match(snp_tracker_comp_ack_match),
        .comp_ack_txn_id(rsp_txn_id),
        .comp_ack_src_id(rsp_src_id),
        .replay_valid(snp_tracker_replay_valid),
        .replay_ready(snp_tracker_replay_ready),
        .replay_flit(snp_tracker_replay_flit),
        .replay_no_snoop(snp_tracker_replay_no_snoop),
        .tx_dat_valid(snp_tracker_tx_dat_valid),
        .tx_dat_ready(snp_tracker_tx_dat_ready),
        .tx_dat_flit(snp_tracker_tx_dat_flit),
        .llc_update_valid(snp_tracker_llc_update_valid),
        .llc_update_ready(snp_tracker_llc_update_ready),
        .llc_update_addr(snp_tracker_llc_update_addr),
        .llc_update_data(snp_tracker_llc_update_data),
        .llc_update_state(snp_tracker_llc_update_state),
        .wb_valid(snp_tracker_wb_valid),
        .wb_ready(snp_tracker_wb_ready),
        .wb_addr(snp_tracker_wb_addr),
        .wb_data(snp_tracker_wb_data),
        .filter_update_valid(snp_tracker_filter_update_valid),
        .filter_update_ready(snp_tracker_filter_update_ready),
        .filter_update_invalidate(snp_tracker_filter_update_invalidate),
        .filter_update_addr(snp_tracker_filter_update_addr),
        .filter_update_state(snp_tracker_filter_update_state),
        .filter_update_sharer_vec(snp_tracker_filter_update_sharer_vec),
        .ack_valid(snp_tracker_ack_valid),
        .ack_addr(snp_tracker_ack_addr),
        .ack_src_id(snp_tracker_ack_src_id),
        .ack_excl(snp_tracker_ack_excl),
        .err_valid(snp_tracker_err_valid),
        .err_ready(snp_tracker_err_ready),
        .err_flit(snp_tracker_err_flit),
        .active_valid_vec(snp_tracker_active_valid_vec),
        .active_addr_flat(snp_tracker_active_addr_flat),
        .used_count(snp_tracker_used_unused),
        .watchdog(snp_tracker_watchdog)
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
        // Comp of a CleanUnique or MakeUnique: its CompAck comes back with
        // this DBID.
        .req_dbid(DBID_MAIN),
        .resp_err(req_excl ? `CHI_RESPERR_EXOKAY : `CHI_RESPERR_OK),
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
        .credit_count(tx_rsp_credit_unused),
        .tx_fire_pulse(tx_rsp_fire_unused),
        .tx_credit_return_pulse(tx_rsp_return_unused),
        .tx_credit_stall(tx_rsp_stall_unused)
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
        .credit_count(tx_dat_credit_unused),
        .tx_fire_pulse(tx_dat_fire_unused),
        .tx_credit_return_pulse(tx_dat_return_unused),
        .tx_credit_stall(tx_dat_stall_unused)
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
        if (!rstn) begin
            hn_scalar_busy_mon_cnt <= 0;
            hn_pos_blocked_mon_cnt <= 0;
            hn_scalar_busy_reported_q <= 1'b0;
            hn_pos_blocked_reported_q <= 1'b0;
        end else begin
            if (state_q == HN_ST_IDLE) begin
                hn_scalar_busy_mon_cnt <= 0;
                hn_scalar_busy_reported_q <= 1'b0;
            end else begin
                if (hn_scalar_busy_mon_cnt < HN_SCALAR_MON_THRESHOLD)
                    hn_scalar_busy_mon_cnt <= hn_scalar_busy_mon_cnt + 1;

                if (!hn_scalar_busy_reported_q &&
                    (hn_scalar_busy_mon_cnt >= HN_SCALAR_MON_THRESHOLD)) begin
                    $display("chi_hn_f B1 monitor: scalar FSM busy >%0d cycles state %0d txn %0h addr 0x%0h pos_used %0d trackers 0x%0h",
                             HN_SCALAR_MON_THRESHOLD, state_q, req_txn_id,
                             held_req_addr, pos_used,
                             tracker_active_valid_vec);
                    hn_scalar_busy_reported_q <= 1'b1;
                end
            end

            if (pos_out_valid && !pos_out_ready &&
                (state_q != HN_ST_IDLE)) begin
                if (hn_pos_blocked_mon_cnt < HN_SCALAR_MON_THRESHOLD)
                    hn_pos_blocked_mon_cnt <= hn_pos_blocked_mon_cnt + 1;

                if (!hn_pos_blocked_reported_q &&
                    (hn_pos_blocked_mon_cnt >= HN_SCALAR_MON_THRESHOLD)) begin
                    $display("chi_hn_f B1 monitor: POS head blocked by scalar FSM >%0d cycles state %0d head_addr 0x%0h active_addr 0x%0h pos_used %0d",
                             HN_SCALAR_MON_THRESHOLD, state_q,
                             pos_out_flit[REQ_ADDR_LSB +: ADDR_WIDTH],
                             held_req_addr, pos_used);
                    hn_pos_blocked_reported_q <= 1'b1;
                end
            end else begin
                hn_pos_blocked_mon_cnt <= 0;
                hn_pos_blocked_reported_q <= 1'b0;
            end

            if (dat_sink_valid && !dat_data_id_ok &&
                (snp_tracker_dat_match ||
                 rd_tracker_dat_match)) begin
                $display("chi_hn_f invalid DAT DataID %0d", dat_data_id);
                $stop;
            end

            if (dat_sink_valid && snp_tracker_dat_match &&
                (dat_opcode != `CHI_DAT_OPCODE_SNP_DATA) &&
                (dat_opcode != `CHI_DAT_OPCODE_SNP_DATA_FWD)) begin
                $display("chi_hn_f DAT opcode legality error: snoop tracker matched opcode %0h src %0d tgt %0d txn %0h",
                         dat_opcode, dat_src_id, dat_tgt_id, dat_txn_id);
                $stop;
            end

            if (dat_sink_valid && rd_tracker_dat_match &&
                (dat_opcode != `CHI_DAT_OPCODE_RD_DATA)) begin
                $display("chi_hn_f DAT opcode legality error: read tracker matched opcode %0h src %0d tgt %0d txn %0h",
                         dat_opcode, dat_src_id, dat_tgt_id, dat_txn_id);
                $stop;
            end

            if (dat_sink_valid && dat_forward_to_mem &&
                (dat_opcode != `CHI_DAT_OPCODE_WDAT)) begin
                $display("chi_hn_f DAT opcode legality error: write path matched opcode %0h src %0d tgt %0d txn %0h",
                         dat_opcode, dat_src_id, dat_tgt_id, dat_txn_id);
                $stop;
            end

            if (dat_sink_valid &&
                (snp_tracker_dat_match ||
                 rd_tracker_dat_match ||
                 dat_forward_to_mem) &&
                (dat_home_nid != NODE_ID)) begin
                $display("chi_hn_f DAT HomeNID legality error: home %0d expected %0d opcode %0h src %0d tgt %0d txn %0h",
                         dat_home_nid, NODE_ID, dat_opcode, dat_src_id,
                         dat_tgt_id, dat_txn_id);
                $stop;
            end

            if (dat_sink_valid &&
                !snp_tracker_dat_match && !rd_tracker_dat_match &&
                !dat_forward_to_mem) begin
                $display("chi_hn_f unexpected DAT opcode %0h src %0d tgt %0d txn %0h state %0d",
                         dat_opcode, dat_src_id, dat_tgt_id, dat_txn_id,
                         state_q);
                $stop;
            end

            if (rsp_sink_valid && !rsp_sink_pop && !rsp_expected_stall) begin
                $display("chi_hn_f unexpected RSP opcode %0h txn %0h src %0d in state %0d (held req op %0h src %0d addr 0x%0h filt_rdy %0b)",
                         rsp_opcode, rsp_txn_id, rsp_src_id, state_q,
                         req_opcode, req_src_id, held_req_addr,
                         filter_update_ready);
                $stop;
            end

            if (state_watchdog) begin
                $display("chi_hn_f watchdog: request stuck state %0d txn %0h addr 0x%0h",
                         state_q, req_txn_id, held_req_addr);
            end
            if (rd_tracker_watchdog)
                $display("chi_hn_f watchdog: read tracker entry waiting for SN data");
            if (snp_tracker_watchdog)
                $display("chi_hn_f watchdog: snoop tracker entry stuck");

            if (state_timeout_fire) begin
                $display("chi_hn_f transaction timeout state %0d txn %0h addr 0x%0h pos_used %0d trackers 0x%0h evict_state %0d",
                         state_q, req_txn_id, held_req_addr,
                         pos_used, tracker_active_valid_vec,
                         llc_evict_state_q);
            end
        end
    end
    // synthesis translate_on
endmodule

// -----------------------------------------------------------------------------
// Module: chi_perf_counter
// Purpose: Small saturating performance counter bank for local RTL events.
//
// Kept here so projects that already include chi_hn_f.v can elaborate HN/RN
// performance-counter instances without adding a new common source file.
// -----------------------------------------------------------------------------
module chi_perf_counter #(
    parameter NUM_EVENTS = 8,
    parameter COUNTER_W  = 32
)(
    input                         clk,
    input                         rstn,
    input                         clear,
    input                         enable,
    input      [NUM_EVENTS-1:0]   event_inc,
    output     [NUM_EVENTS*COUNTER_W-1:0] count_flat
);
    reg [COUNTER_W-1:0] count_q [0:NUM_EVENTS-1];

    integer reset_i;
    integer event_i;
    genvar  gi;

    generate
        for (gi = 0; gi < NUM_EVENTS; gi = gi + 1) begin : gen_count_flat
            assign count_flat[gi*COUNTER_W +: COUNTER_W] = count_q[gi];
        end
    endgenerate

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (reset_i = 0; reset_i < NUM_EVENTS; reset_i = reset_i + 1)
                count_q[reset_i] <= {COUNTER_W{1'b0}};
        end else if (clear) begin
            for (reset_i = 0; reset_i < NUM_EVENTS; reset_i = reset_i + 1)
                count_q[reset_i] <= {COUNTER_W{1'b0}};
        end else if (enable) begin
            for (event_i = 0; event_i < NUM_EVENTS; event_i = event_i + 1) begin
                if (event_inc[event_i] &&
                    (count_q[event_i] != {COUNTER_W{1'b1}}))
                    count_q[event_i] <= count_q[event_i] + 1'b1;
            end
        end
    end
endmodule

// -----------------------------------------------------------------------------
// Module: chi_hn_snoop_tracker
// Purpose: Per-slot snoop/back-invalidate execution for HN-F. It owns snoop
//          send masks, wait masks, dirty-data capture, replay, response data,
//          filter/LLC update ordering, and per-slot timeout.
// -----------------------------------------------------------------------------
module chi_hn_snoop_tracker #(
    parameter NODE_ID    = 0,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter DEPTH      = `CHI_DEFAULT_HN_SNOOP_TRACKER_DEPTH,
    // The home assigns snoop TxnIDs (B2.5.1): entry i snooping RN r uses
    // DBID_BASE | (i << RN_W) | r, unique among its open snoops. The
    // CompData this entry sends names DBID_BASE | (i << RN_W); a forwarded
    // CompData (DCT) names the snoop TxnID. Either way the CompAck's TxnID
    // identifies the entry by its bits above RN_W.
    parameter [DBID_W-1:0] DBID_BASE = {DBID_W{1'b0}},
    parameter LINE_BYTES = 64,
    parameter TIMEOUT_CYCLES = 1024,
    parameter FUNCTIONAL_TIMEOUT = 0,
    parameter REQ_W      = `CHI_REQ_W(`CHI_DEFAULT_NODE_ID_W),
    parameter SNP_W      = `CHI_SNP_W(`CHI_DEFAULT_NODE_ID_W),
    parameter DAT_W      = `CHI_DAT_W(`CHI_DEFAULT_DATA_W,`CHI_DEFAULT_NODE_ID_W),
    parameter RSP_W      = `CHI_RSP_W(`CHI_DEFAULT_NODE_ID_W)
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    alloc_valid,
    output                   alloc_ready,
    input                    alloc_mode_backinv,
    input      [REQ_W-1:0]   alloc_replay_flit,
    input      [ADDR_WIDTH-1:0] alloc_active_addr,
    input      [ADDR_WIDTH-1:0] alloc_snp_addr,
    input      [TXN_ID_W-1:0] alloc_txn_id,
    input      [NODE_ID_W-1:0] alloc_src_id,
    input      [QOS_W-1:0]   alloc_qos,
    input      [`CHI_REQ_OPCODE_W-1:0] alloc_opcode,
    input                    alloc_excl,
    input                    alloc_req_is_read,
    input                    alloc_req_is_write,
    input      [NUM_RN-1:0]  alloc_requestor_onehot,
    input      [NUM_RN-1:0]  alloc_snp_valid_vec,
    input      [NUM_RN*SNP_W-1:0] alloc_snp_flit_flat,

    output                   tx_snp_valid,
    input                    tx_snp_ready,
    output reg [SNP_W-1:0]   tx_snp_flit,
    output reg [NODE_ID_W-1:0] tx_snp_tgt_id,

    input                    rsp_valid,
    input                    rsp_ready,
    output                   rsp_match,
    input                    rsp_fwded,
    input      [TXN_ID_W-1:0] rsp_txn_id,
    input      [NODE_ID_W-1:0] rsp_src_id,

    input                    dat_valid,
    output                   dat_ready,
    output                   dat_match,
    input      [DAT_W-1:0]   dat_flit,

    input                    comp_ack_valid,
    input                    comp_ack_ready,
    output                   comp_ack_match,
    input      [TXN_ID_W-1:0] comp_ack_txn_id,
    input      [NODE_ID_W-1:0] comp_ack_src_id,

    output                   replay_valid,
    input                    replay_ready,
    output     [REQ_W-1:0]   replay_flit,
    output                   replay_no_snoop,

    output                   tx_dat_valid,
    input                    tx_dat_ready,
    output reg [DAT_W-1:0]   tx_dat_flit,

    output                   llc_update_valid,
    input                    llc_update_ready,
    output     [ADDR_WIDTH-1:0] llc_update_addr,
    output     [LINE_BYTES*8-1:0] llc_update_data,
    output     [2:0]         llc_update_state,

    // Dirty snooped line to be written to memory before the LLC update.
    output                   wb_valid,
    input                    wb_ready,
    output     [ADDR_WIDTH-1:0] wb_addr,
    output     [LINE_BYTES*8-1:0] wb_data,

    output                   filter_update_valid,
    input                    filter_update_ready,
    output                   filter_update_invalidate,
    output     [ADDR_WIDTH-1:0] filter_update_addr,
    output     [1:0]         filter_update_state,
    output     [NUM_RN-1:0]  filter_update_sharer_vec,

    output                   ack_valid,
    output     [ADDR_WIDTH-1:0] ack_addr,
    output     [NODE_ID_W-1:0] ack_src_id,
    output                   ack_excl,

    output                   err_valid,
    input                    err_ready,
    output reg [RSP_W-1:0]   err_flit,

    output     [DEPTH*2-1:0] active_valid_vec,
    output     [DEPTH*2*ADDR_WIDTH-1:0] active_addr_flat,
    output     [15:0]        used_count,
    output                   watchdog
);
    `include "../common/chi_clog2.vh"
    localparam IDX_W = (DEPTH <= 2) ? 1 : `CHI_CLOG2(DEPTH);
    localparam RN_W = (NUM_RN <= 2) ? 1 : `CHI_CLOG2(NUM_RN);
    localparam SNP_TXN_LSB = `CHI_SNP_TXN_LSB(NODE_ID_W);
    localparam BE_W = DATA_WIDTH / 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam DATAID_SHIFT = `CHI_DAT_DATAID_SHIFT(DATA_WIDTH);
    localparam [`CHI_DAT_DATAID_W-1:0] DATAID_ALIGN_MASK = (1 << DATAID_SHIFT) - 1;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam TIMEOUT_W = (TIMEOUT_CYCLES <= 2) ? 1 : `CHI_CLOG2(TIMEOUT_CYCLES + 1);
    localparam [TIMEOUT_W-1:0] TIMEOUT_VALUE = TIMEOUT_CYCLES;
    localparam [NODE_ID_W-1:0] NODE_ID_SIZED = NODE_ID;

    localparam SNP_ST_EMPTY      = 4'd0;
    localparam SNP_ST_WAIT_RSP   = 4'd1;
    localparam SNP_ST_WAIT_DATA  = 4'd2;
    localparam SNP_ST_LLC_UPD    = 4'd3;
    localparam SNP_ST_FILTER_UPD = 4'd4;
    localparam SNP_ST_REPLAY     = 4'd5;
    localparam SNP_ST_SEND_DAT   = 4'd6;
    localparam SNP_ST_WAIT_ACK   = 4'd7;
    localparam SNP_ST_ACK_FILTER = 4'd8;
    localparam SNP_ST_ERR        = 4'd9;
    localparam SNP_ST_DRAIN      = 4'd10;
    localparam SNP_ST_FWD_WAIT_ACK = 4'd11;
    localparam DRAIN_WINDOW      = 8;
    localparam DRAIN_W           = 4;
    localparam [DRAIN_W-1:0] DRAIN_WINDOW_VALUE = DRAIN_WINDOW;

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

    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(NODE_ID_W);

    reg [3:0]            state_q [0:DEPTH-1];
    reg                  mode_backinv_q [0:DEPTH-1];
    reg                  req_is_read_q [0:DEPTH-1];
    reg                  req_is_write_q [0:DEPTH-1];
    // A snooped RN reported dirty data; it must reach memory.
    reg                  dirty_q [0:DEPTH-1];
    reg                  wb_done_q [0:DEPTH-1];
    reg                  excl_q [0:DEPTH-1];
    reg [REQ_W-1:0]      replay_flit_q [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] active_addr_q [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] snp_addr_q [0:DEPTH-1];
    reg [TXN_ID_W-1:0]   txn_id_q [0:DEPTH-1];
    reg [NODE_ID_W-1:0]  src_id_q [0:DEPTH-1];
    reg [QOS_W-1:0]      qos_q [0:DEPTH-1];
    reg [`CHI_REQ_OPCODE_W-1:0] opcode_q [0:DEPTH-1];
    reg [NUM_RN-1:0]     requestor_onehot_q [0:DEPTH-1];
    reg [NUM_RN-1:0]     send_mask_q [0:DEPTH-1];
    reg [NUM_RN-1:0]     wait_mask_q [0:DEPTH-1];
    reg [NUM_RN-1:0]     data_src_mask_q [0:DEPTH-1];
    reg [NUM_RN-1:0]     snoop_target_mask_q [0:DEPTH-1];
    reg [NUM_RN*SNP_W-1:0] snp_flit_q [0:DEPTH-1];
    (* ram_style = "registers" *) reg [LINE_WIDTH-1:0] line_q [0:DEPTH-1];
    reg [BEATS-1:0]      beat_mask_q [0:DEPTH-1];
    reg                  data_expected_q [0:DEPTH-1];
    reg                  data_seen_q [0:DEPTH-1];
    reg                  forwarded_q [0:DEPTH-1];
    reg                  forward_ack_seen_q [0:DEPTH-1];
    reg [3:0]            send_beat_q [0:DEPTH-1];
    reg [TIMEOUT_W-1:0]  timeout_cnt_q [0:DEPTH-1];
    reg [DRAIN_W-1:0]    drain_cnt_q [0:DEPTH-1];

    reg                  free_valid_r;
    reg [IDX_W-1:0]      free_idx_r;
    reg                  send_valid_r;
    reg [IDX_W-1:0]      send_idx_r;
    reg [NUM_RN-1:0]     send_onehot_r;
    reg                  rsp_match_r;
    reg [IDX_W-1:0]      rsp_idx_r;
    reg [NUM_RN-1:0]     rsp_src_onehot_r;
    // SnpRespData(Fwded) with no SnpResp: once all beats are in, it is
    // handled as that RN's response, one cycle later when no SnpResp is
    // taken. vrsp_fwded_q: it was SnpRespDataFwded.
    reg                  vrsp_valid_q;
    reg                  vrsp_fwded_q;
    reg [IDX_W-1:0]      vrsp_idx_q;
    reg [NUM_RN-1:0]     vrsp_onehot_q;
    reg [NUM_RN-1:0]     dat_src_onehot_r;
    reg                  dat_match_r;
    reg [IDX_W-1:0]      dat_idx_r;
    reg                  replay_valid_r;
    reg [IDX_W-1:0]      replay_idx_r;
    reg                  tx_dat_valid_r;
    reg [IDX_W-1:0]      tx_dat_idx_r;
    reg                  llc_update_valid_r;
    reg [IDX_W-1:0]      llc_update_idx_r;
    reg                  wb_valid_r;
    reg [IDX_W-1:0]      wb_idx_r;
    reg                  filter_update_valid_r;
    reg [IDX_W-1:0]      filter_update_idx_r;
    reg                  comp_ack_match_r;
    reg [IDX_W-1:0]      comp_ack_idx_r;
    reg                  err_valid_r;
    reg [IDX_W-1:0]      err_idx_r;
    reg                  timeout_valid_r;
    reg                  watchdog_r;
    reg [IDX_W-1:0]      timeout_idx_r;
    reg                  timeout_error_ok_r;
    reg [15:0]           used_count_r;
    integer              scan_i;
    integer              rn_i;
    integer              flit_rn_i;
    integer              reset_i;
    genvar               gi;

    wire alloc_fire = alloc_valid && alloc_ready;
    wire tx_snp_fire = tx_snp_valid && tx_snp_ready;
    wire real_rsp_fire = rsp_valid && rsp_ready && rsp_match;
    wire vrsp_go = vrsp_valid_q && !real_rsp_fire;
    wire rsp_fire = real_rsp_fire || vrsp_go;
    wire rsp_fwded_eff = vrsp_go ? vrsp_fwded_q : rsp_fwded;
    wire dat_fire = dat_valid && dat_ready && dat_match;
    wire replay_fire = replay_valid && replay_ready;
    wire tx_dat_fire = tx_dat_valid && tx_dat_ready;
    wire llc_update_fire = llc_update_valid && llc_update_ready;
    wire wb_fire = wb_valid && wb_ready;
    wire filter_update_fire = filter_update_valid && filter_update_ready;
    wire comp_ack_fire = comp_ack_valid && comp_ack_ready && comp_ack_match;
    wire err_fire = err_valid && err_ready;
    wire fwd_ack_complete =
        comp_ack_fire &&
        (state_q[comp_ack_idx_r] == SNP_ST_FWD_WAIT_ACK);
    wire fwd_filter_ack_seen =
        filter_update_valid_r &&
        (state_q[filter_update_idx_r] == SNP_ST_FILTER_UPD) &&
        forwarded_q[filter_update_idx_r] &&
        (forward_ack_seen_q[filter_update_idx_r] ||
         (comp_ack_fire && (comp_ack_idx_r == filter_update_idx_r)));
    wire fwd_filter_release = filter_update_fire && fwd_filter_ack_seen;

    // Only a response with data makes the home write the line back. A
    // SnpResp carries I or SC, and SnpRespFwded no data: after SnpSharedFwd
    // the snoopee keeps the dirty line (SD), after SnpUniqueFwd the
    // requester gets it (UD_PD).
    wire rsp_dirty = vrsp_go;
    wire [DBID_W-1:0] dat_dbid = dat_flit[DAT_DBID_LSB +: DBID_W];
    wire [TXN_ID_W-1:0] dat_txn_id = dat_flit[DAT_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0] dat_src_id = dat_flit[DAT_SRC_LSB +: NODE_ID_W];
    wire [NODE_ID_W-1:0] dat_tgt_id = dat_flit[DAT_TGT_LSB +: NODE_ID_W];
    wire [3:0] dat_opcode = dat_flit[DAT_OPCODE_LSB +: 4];
    wire [`CHI_DAT_QOS_W-1:0] tx_dat_qos;
    wire [`CHI_DAT_DATAID_W-1:0] dat_data_id =
        dat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W];
    wire [3:0] dat_beat_idx = dat_data_id >> DATAID_SHIFT;
    wire [`CHI_DAT_DATAID_W-1:0] tx_dat_data_id = send_beat_q[tx_dat_idx_r] << DATAID_SHIFT;
    wire dat_data_id_ok =
        ((dat_data_id & DATAID_ALIGN_MASK) == {`CHI_DAT_DATAID_W{1'b0}}) &&
        (dat_beat_idx < BEATS);
    wire [LINE_WIDTH-1:0] dat_line_next =
        line_q[dat_idx_r] |
        ({{(LINE_WIDTH-DATA_WIDTH){1'b0}},
          dat_flit[DAT_DATA_LSB +: DATA_WIDTH]} <<
         (dat_beat_idx * DATA_WIDTH));
    wire [BEATS-1:0] dat_beat_mask_next =
        beat_mask_q[dat_idx_r] |
        ({{(BEATS-1){1'b0}}, 1'b1} << dat_beat_idx);
    wire rsp_wait_done_next =
        ((wait_mask_q[rsp_idx_r] & ~rsp_src_onehot_r) ==
         {NUM_RN{1'b0}});
    wire dat_complete_for_rsp =
        dat_fire && dat_data_id_ok && (&dat_beat_mask_next) &&
        (dat_idx_r == rsp_idx_r);
    wire data_seen_for_rsp =
        data_seen_q[rsp_idx_r] || dat_complete_for_rsp;

    generate
        if (QOS_W >= `CHI_DAT_QOS_W) begin : gen_dat_qos_full
            assign tx_dat_qos =
                qos_q[tx_dat_idx_r][`CHI_DAT_QOS_W-1:0];
        end else begin : gen_dat_qos_pad
            assign tx_dat_qos =
                {{(`CHI_DAT_QOS_W-QOS_W){1'b0}}, qos_q[tx_dat_idx_r]};
        end
    endgenerate

    assign alloc_ready = free_valid_r;
    assign tx_snp_valid = send_valid_r;
    assign rsp_match = rsp_match_r;
    assign dat_ready = dat_match_r;
    assign dat_match = dat_match_r;
    assign comp_ack_match = comp_ack_match_r;
    assign replay_valid = replay_valid_r;
    assign replay_flit = replay_valid_r ? replay_flit_q[replay_idx_r] : {REQ_W{1'b0}};
    assign replay_no_snoop = replay_valid_r && !mode_backinv_q[replay_idx_r];
    assign tx_dat_valid = tx_dat_valid_r;
    assign wb_valid = wb_valid_r;
    assign wb_addr = mode_backinv_q[wb_idx_r] ?
                     {snp_addr_q[wb_idx_r][ADDR_WIDTH-1:6], 6'b0} :
                     {active_addr_q[wb_idx_r][ADDR_WIDTH-1:6], 6'b0};
    assign wb_data = line_q[wb_idx_r];
    assign llc_update_valid = llc_update_valid_r;
    assign llc_update_addr = llc_update_valid_r ?
                             (mode_backinv_q[llc_update_idx_r] ?
                              snp_addr_q[llc_update_idx_r] :
                              active_addr_q[llc_update_idx_r]) :
                             {ADDR_WIDTH{1'b0}};
    assign llc_update_data = llc_update_valid_r ?
                             line_q[llc_update_idx_r] : {LINE_WIDTH{1'b0}};
    assign llc_update_state = llc_update_valid_r ?
                              (mode_backinv_q[llc_update_idx_r] ?
                               `CHI_STATE_SC :
                               ((opcode_q[llc_update_idx_r] == `CHI_REQ_RD_UNIQUE) ?
                                `CHI_STATE_UC : `CHI_STATE_SC)) :
                              `CHI_STATE_SC;
    assign filter_update_valid = filter_update_valid_r;
    assign filter_update_invalidate = filter_update_valid_r &&
                                      mode_backinv_q[filter_update_idx_r];
    assign filter_update_addr = filter_update_valid_r ?
                                (mode_backinv_q[filter_update_idx_r] ?
                                 snp_addr_q[filter_update_idx_r] :
                                 active_addr_q[filter_update_idx_r]) :
                                {ADDR_WIDTH{1'b0}};
    assign filter_update_state = filter_update_valid_r ?
                                 (mode_backinv_q[filter_update_idx_r] ?
                                  2'b00 :
                                  ((req_is_write_q[filter_update_idx_r] ||
                                    (opcode_q[filter_update_idx_r] ==
                                     `CHI_REQ_RD_UNIQUE)) ?
                                   2'b10 : 2'b01)) :
                                 2'b00;
    assign filter_update_sharer_vec = filter_update_valid_r ?
                                      (mode_backinv_q[filter_update_idx_r] ?
                                       {NUM_RN{1'b0}} :
                                       ((opcode_q[filter_update_idx_r] ==
                                         `CHI_REQ_RD_SHARED) ?
                                        (requestor_onehot_q[filter_update_idx_r] |
                                         snoop_target_mask_q[filter_update_idx_r]) :
                                        requestor_onehot_q[filter_update_idx_r])) :
                                      {NUM_RN{1'b0}};
    assign err_valid = err_valid_r;
    assign ack_valid = (filter_update_fire &&
                        (state_q[filter_update_idx_r] == SNP_ST_ACK_FILTER)) ||
                       fwd_filter_release ||
                       fwd_ack_complete;
    assign ack_addr = fwd_ack_complete ?
                      active_addr_q[comp_ack_idx_r] :
                      ((filter_update_valid_r || fwd_filter_release) ?
                       active_addr_q[filter_update_idx_r] :
                       {ADDR_WIDTH{1'b0}});
    assign ack_src_id = fwd_ack_complete ?
                        src_id_q[comp_ack_idx_r] :
                        ((filter_update_valid_r || fwd_filter_release) ?
                         src_id_q[filter_update_idx_r] :
                         {NODE_ID_W{1'b0}});
    assign ack_excl = fwd_ack_complete ?
                      excl_q[comp_ack_idx_r] :
                      ((filter_update_valid_r || fwd_filter_release) &&
                       excl_q[filter_update_idx_r]);
    assign used_count = used_count_r;
    assign watchdog = watchdog_r;

    generate
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin : gen_active_line
            assign active_valid_vec[gi*2] =
                (state_q[gi] != SNP_ST_EMPTY);
            assign active_addr_flat[(gi*2)*ADDR_WIDTH +: ADDR_WIDTH] =
                active_addr_q[gi];
            assign active_valid_vec[(gi*2)+1] =
                (state_q[gi] != SNP_ST_EMPTY) && mode_backinv_q[gi];
            assign active_addr_flat[((gi*2)+1)*ADDR_WIDTH +: ADDR_WIDTH] =
                snp_addr_q[gi];
        end
    endgenerate

    always @(*) begin
        free_valid_r = 1'b0;
        free_idx_r = {IDX_W{1'b0}};
        send_valid_r = 1'b0;
        send_idx_r = {IDX_W{1'b0}};
        send_onehot_r = {NUM_RN{1'b0}};
        rsp_match_r = 1'b0;
        rsp_idx_r = {IDX_W{1'b0}};
        rsp_src_onehot_r = {NUM_RN{1'b0}};
        dat_match_r = 1'b0;
        dat_idx_r = {IDX_W{1'b0}};
        replay_valid_r = 1'b0;
        replay_idx_r = {IDX_W{1'b0}};
        tx_dat_valid_r = 1'b0;
        tx_dat_idx_r = {IDX_W{1'b0}};
        llc_update_valid_r = 1'b0;
        llc_update_idx_r = {IDX_W{1'b0}};
        wb_valid_r = 1'b0;
        wb_idx_r = {IDX_W{1'b0}};
        filter_update_valid_r = 1'b0;
        filter_update_idx_r = {IDX_W{1'b0}};
        comp_ack_match_r = 1'b0;
        comp_ack_idx_r = {IDX_W{1'b0}};
        err_valid_r = 1'b0;
        err_idx_r = {IDX_W{1'b0}};
        timeout_valid_r = 1'b0;
        timeout_idx_r = {IDX_W{1'b0}};
        timeout_error_ok_r = 1'b0;
        watchdog_r = 1'b0;
        used_count_r = 16'd0;

        for (scan_i = 0; scan_i < DEPTH; scan_i = scan_i + 1) begin
            if (state_q[scan_i] != SNP_ST_EMPTY) begin
                used_count_r = used_count_r + 1'b1;
                if ((state_q[scan_i] != SNP_ST_ERR) &&
                    (state_q[scan_i] != SNP_ST_DRAIN) &&
                    (timeout_cnt_q[scan_i] == TIMEOUT_VALUE - 1'b1))
                    watchdog_r = 1'b1;

                if ((state_q[scan_i] != SNP_ST_ERR) &&
                    (state_q[scan_i] != SNP_ST_DRAIN) &&
                    (FUNCTIONAL_TIMEOUT != 0) &&
                    (timeout_cnt_q[scan_i] >= TIMEOUT_VALUE)) begin
                    if (!timeout_valid_r) begin
                        timeout_valid_r = 1'b1;
                        timeout_idx_r = scan_i[IDX_W-1:0];
                        timeout_error_ok_r =
                            (state_q[scan_i] != SNP_ST_WAIT_ACK) &&
                            (state_q[scan_i] != SNP_ST_FWD_WAIT_ACK) &&
                            (state_q[scan_i] != SNP_ST_ACK_FILTER) &&
                            !((state_q[scan_i] == SNP_ST_SEND_DAT) &&
                              (send_beat_q[scan_i] != 4'd0));
                    end
                end else begin
                    if (!send_valid_r &&
                        (state_q[scan_i] == SNP_ST_WAIT_RSP) &&
                        (send_mask_q[scan_i] != {NUM_RN{1'b0}})) begin
                        send_valid_r = 1'b1;
                        send_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!rsp_match_r &&
                        (state_q[scan_i] == SNP_ST_WAIT_RSP)) begin
                        for (rn_i = 0; rn_i < NUM_RN; rn_i = rn_i + 1) begin
                            if ((rsp_src_id == rn_i) &&
                                (rsp_txn_id ==
                                 (DBID_BASE | (scan_i << RN_W) | rn_i)) &&
                                wait_mask_q[scan_i][rn_i]) begin
                                rsp_match_r = 1'b1;
                                rsp_idx_r = scan_i[IDX_W-1:0];
                                rsp_src_onehot_r[rn_i] = 1'b1;
                            end
                        end
                    end

                    if (!dat_match_r &&
                        ((state_q[scan_i] == SNP_ST_WAIT_RSP) ||
                         (state_q[scan_i] == SNP_ST_WAIT_DATA) ||
                         (state_q[scan_i] == SNP_ST_ERR) ||
                         (state_q[scan_i] == SNP_ST_DRAIN)) &&
                        ((dat_opcode == `CHI_DAT_OPCODE_SNP_DATA) ||
                         (dat_opcode == `CHI_DAT_OPCODE_SNP_DATA_FWD)) &&
                        (data_expected_q[scan_i] ||
                         (state_q[scan_i] == SNP_ST_WAIT_RSP)) &&
                        (dat_tgt_id == NODE_ID_SIZED) &&
                        (dat_dbid == {DBID_W{1'b0}})) begin
                        for (rn_i = 0; rn_i < NUM_RN; rn_i = rn_i + 1) begin
                            if ((dat_src_id == rn_i) &&
                                (dat_txn_id ==
                                 (DBID_BASE | (scan_i << RN_W) | rn_i)) &&
                                ((state_q[scan_i] == SNP_ST_DRAIN) ||
                                 (state_q[scan_i] == SNP_ST_ERR) ||
                                 data_src_mask_q[scan_i][rn_i] ||
                                 ((state_q[scan_i] == SNP_ST_WAIT_RSP) &&
                                  wait_mask_q[scan_i][rn_i]))) begin
                                dat_match_r = 1'b1;
                                dat_idx_r = scan_i[IDX_W-1:0];
                            end
                        end
                    end

                    if (!replay_valid_r &&
                        (state_q[scan_i] == SNP_ST_REPLAY)) begin
                        replay_valid_r = 1'b1;
                        replay_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!tx_dat_valid_r &&
                        (state_q[scan_i] == SNP_ST_SEND_DAT)) begin
                        tx_dat_valid_r = 1'b1;
                        tx_dat_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!llc_update_valid_r &&
                        (state_q[scan_i] == SNP_ST_LLC_UPD) &&
                        (!dirty_q[scan_i] || wb_done_q[scan_i])) begin
                        llc_update_valid_r = 1'b1;
                        llc_update_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!wb_valid_r &&
                        (state_q[scan_i] == SNP_ST_LLC_UPD) &&
                        dirty_q[scan_i] && !wb_done_q[scan_i]) begin
                        wb_valid_r = 1'b1;
                        wb_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!filter_update_valid_r &&
                        ((state_q[scan_i] == SNP_ST_FILTER_UPD) ||
                         (state_q[scan_i] == SNP_ST_ACK_FILTER))) begin
                        filter_update_valid_r = 1'b1;
                        filter_update_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!comp_ack_match_r &&
                        (((state_q[scan_i] == SNP_ST_WAIT_ACK) ||
                          (state_q[scan_i] == SNP_ST_FWD_WAIT_ACK)) ||
                         (((state_q[scan_i] == SNP_ST_WAIT_RSP) ||
                           (state_q[scan_i] == SNP_ST_WAIT_DATA) ||
                           (state_q[scan_i] == SNP_ST_LLC_UPD) ||
                           (state_q[scan_i] == SNP_ST_FILTER_UPD)) &&
                          req_is_read_q[scan_i] &&
                          !mode_backinv_q[scan_i])) &&
                        ((comp_ack_txn_id >> RN_W) ==
                         ((DBID_BASE | (scan_i << RN_W)) >> RN_W)) &&
                        (src_id_q[scan_i] == comp_ack_src_id)) begin
                        comp_ack_match_r = 1'b1;
                        comp_ack_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!err_valid_r &&
                        (state_q[scan_i] == SNP_ST_ERR)) begin
                        err_valid_r = 1'b1;
                        err_idx_r = scan_i[IDX_W-1:0];
                    end
                end
            end else if (!free_valid_r) begin
                free_valid_r = 1'b1;
                free_idx_r = scan_i[IDX_W-1:0];
            end
        end

        if (send_valid_r) begin
            for (rn_i = 0; rn_i < NUM_RN; rn_i = rn_i + 1) begin
                if ((send_onehot_r == {NUM_RN{1'b0}}) &&
                    send_mask_q[send_idx_r][rn_i])
                    send_onehot_r[rn_i] = 1'b1;
            end
        end

        dat_src_onehot_r = {NUM_RN{1'b0}};
        for (rn_i = 0; rn_i < NUM_RN; rn_i = rn_i + 1)
            if (dat_src_id == rn_i)
                dat_src_onehot_r[rn_i] = 1'b1;

        if (!(rsp_valid && rsp_ready && rsp_match_r) && vrsp_valid_q) begin
            rsp_idx_r = vrsp_idx_q;
            rsp_src_onehot_r = vrsp_onehot_q;
        end
    end

    always @(*) begin
        tx_snp_flit = {SNP_W{1'b0}};
        tx_snp_tgt_id = {NODE_ID_W{1'b0}};
        for (flit_rn_i = 0; flit_rn_i < NUM_RN; flit_rn_i = flit_rn_i + 1) begin
            if (send_valid_r && send_onehot_r[flit_rn_i]) begin
                tx_snp_flit =
                    snp_flit_q[send_idx_r][flit_rn_i*SNP_W +: SNP_W];
                tx_snp_flit[SNP_TXN_LSB +: TXN_ID_W] =
                    DBID_BASE | (send_idx_r << RN_W) | flit_rn_i;
                tx_snp_tgt_id = flit_rn_i;
            end
        end
    end

    always @(*) begin
        tx_dat_flit = {DAT_W{1'b0}};
        tx_dat_flit[DAT_RESPERR_LSB +: 2]       = `CHI_RESPERR_OK;
        tx_dat_flit[DAT_BE_LSB +: BE_W]         = {BE_W{1'b1}};
        tx_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] =
            line_q[tx_dat_idx_r][send_beat_q[tx_dat_idx_r]*DATA_WIDTH +: DATA_WIDTH];
        tx_dat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W] = tx_dat_data_id;
        tx_dat_flit[DAT_DBID_LSB +: DBID_W]     =
            DBID_BASE | (tx_dat_idx_r << RN_W);
        tx_dat_flit[DAT_TXN_LSB +: TXN_ID_W]    = txn_id_q[tx_dat_idx_r];
        tx_dat_flit[DAT_SRC_LSB +: NODE_ID_W]   = NODE_ID_SIZED;
        tx_dat_flit[DAT_TGT_LSB +: NODE_ID_W]   = src_id_q[tx_dat_idx_r];
        // Dirty snoop data has been written back, so the line is clean.
        tx_dat_flit[DAT_RESP_LSB +: 3]          =
            `CHI_COMPDATA_RESP_FOR(opcode_q[tx_dat_idx_r]);
        tx_dat_flit[DAT_OPCODE_LSB +: 4]        = `CHI_DAT_OPCODE_RD_DATA;
        tx_dat_flit[DAT_QOS_LSB +: `CHI_DAT_QOS_W] = tx_dat_qos;
        tx_dat_flit[DAT_HOME_NID_LSB +: NODE_ID_W] = NODE_ID_SIZED;
    end

    always @(*) begin
        err_flit = {RSP_W{1'b0}};
        err_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        err_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_SLVERR;
        err_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        err_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_COMP;
        err_flit[RSP_TXN_LSB +: TXN_ID_W]  = txn_id_q[err_idx_r];
        err_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID_SIZED;
        err_flit[RSP_TGT_LSB +: NODE_ID_W] = src_id_q[err_idx_r];
        err_flit[RSP_QOS_LSB +: QOS_W]     = qos_q[err_idx_r];
    end

    always @(posedge clk) begin
        if (rstn && !clear) begin
            if (dat_fire && dat_data_id_ok &&
                (state_q[dat_idx_r] != SNP_ST_DRAIN) &&
                (state_q[dat_idx_r] != SNP_ST_ERR)) begin
                line_q[dat_idx_r] <= dat_line_next;
            end

            if (alloc_fire) begin
                replay_flit_q[free_idx_r] <= alloc_replay_flit;
                active_addr_q[free_idx_r] <= alloc_active_addr;
                snp_addr_q[free_idx_r] <= alloc_snp_addr;
                snp_flit_q[free_idx_r] <= alloc_snp_flit_flat;
                line_q[free_idx_r] <= {LINE_WIDTH{1'b0}};
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            vrsp_valid_q <= 1'b0;
            vrsp_fwded_q <= 1'b0;
            vrsp_idx_q <= {IDX_W{1'b0}};
            vrsp_onehot_q <= {NUM_RN{1'b0}};
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1) begin
                state_q[reset_i] <= SNP_ST_EMPTY;
                mode_backinv_q[reset_i] <= 1'b0;
                req_is_read_q[reset_i] <= 1'b0;
                req_is_write_q[reset_i] <= 1'b0;
                dirty_q[reset_i] <= 1'b0;
                wb_done_q[reset_i] <= 1'b0;
                excl_q[reset_i] <= 1'b0;
                txn_id_q[reset_i] <= {TXN_ID_W{1'b0}};
                src_id_q[reset_i] <= {NODE_ID_W{1'b0}};
                qos_q[reset_i] <= {QOS_W{1'b0}};
                opcode_q[reset_i] <= {`CHI_REQ_OPCODE_W{1'b0}};
                requestor_onehot_q[reset_i] <= {NUM_RN{1'b0}};
                send_mask_q[reset_i] <= {NUM_RN{1'b0}};
                wait_mask_q[reset_i] <= {NUM_RN{1'b0}};
                data_src_mask_q[reset_i] <= {NUM_RN{1'b0}};
                beat_mask_q[reset_i] <= {BEATS{1'b0}};
                data_expected_q[reset_i] <= 1'b0;
                data_seen_q[reset_i] <= 1'b0;
                snoop_target_mask_q[reset_i] <= {NUM_RN{1'b0}};
                forwarded_q[reset_i] <= 1'b0;
                forward_ack_seen_q[reset_i] <= 1'b0;
                send_beat_q[reset_i] <= 4'd0;
                timeout_cnt_q[reset_i] <= {TIMEOUT_W{1'b0}};
                drain_cnt_q[reset_i] <= {DRAIN_W{1'b0}};
            end
        end else if (clear) begin
            vrsp_valid_q <= 1'b0;
            vrsp_fwded_q <= 1'b0;
            vrsp_idx_q <= {IDX_W{1'b0}};
            vrsp_onehot_q <= {NUM_RN{1'b0}};
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1) begin
                state_q[reset_i] <= SNP_ST_EMPTY;
                drain_cnt_q[reset_i] <= {DRAIN_W{1'b0}};
            end
        end else begin
            for (scan_i = 0; scan_i < DEPTH; scan_i = scan_i + 1) begin
                if ((state_q[scan_i] != SNP_ST_EMPTY) &&
                    (state_q[scan_i] != SNP_ST_ERR) &&
                    (state_q[scan_i] != SNP_ST_DRAIN)) begin
                    if (timeout_cnt_q[scan_i] != TIMEOUT_VALUE)
                        timeout_cnt_q[scan_i] <= timeout_cnt_q[scan_i] + 1'b1;
                end

                if (state_q[scan_i] == SNP_ST_DRAIN) begin
                    if (drain_cnt_q[scan_i] == {DRAIN_W{1'b0}}) begin
                        state_q[scan_i] <= SNP_ST_EMPTY;
                        data_expected_q[scan_i] <= 1'b0;
                        data_seen_q[scan_i] <= 1'b0;
                        data_src_mask_q[scan_i] <= {NUM_RN{1'b0}};
                        forwarded_q[scan_i] <= 1'b0;
                        forward_ack_seen_q[scan_i] <= 1'b0;
                    end else begin
                        drain_cnt_q[scan_i] <= drain_cnt_q[scan_i] - 1'b1;
                    end
                end
            end

            if (tx_snp_fire)
                send_mask_q[send_idx_r] <= send_mask_q[send_idx_r] &
                                           ~send_onehot_r;

            if (wb_fire)
                wb_done_q[wb_idx_r] <= 1'b1;

            if (vrsp_go)
                vrsp_valid_q <= 1'b0;
            if (dat_fire && dat_data_id_ok && (&dat_beat_mask_next) &&
                !forwarded_q[dat_idx_r] &&
                (state_q[dat_idx_r] == SNP_ST_WAIT_RSP) &&
                (|(wait_mask_q[dat_idx_r] & dat_src_onehot_r))) begin
                vrsp_valid_q <= 1'b1;
                vrsp_fwded_q <= (dat_opcode == `CHI_DAT_OPCODE_SNP_DATA_FWD);
                vrsp_idx_q <= dat_idx_r;
                vrsp_onehot_q <= dat_src_onehot_r;
            end

            if (rsp_fire) begin
                if (rsp_dirty)
                    dirty_q[rsp_idx_r] <= 1'b1;
                wait_mask_q[rsp_idx_r] <= wait_mask_q[rsp_idx_r] &
                                          ~rsp_src_onehot_r;
                if (rsp_fwded_eff) begin
                    // The snoopee sent the line to the requester. Its
                    // SnpRespDataFwded (data already seen) goes through the
                    // LLC; a SnpRespFwded brings no data, so unless another
                    // RN's data is owed only the filter is updated.
                    forwarded_q[rsp_idx_r] <= 1'b1;
                    if (rsp_wait_done_next) begin
                        if (data_seen_for_rsp)
                            state_q[rsp_idx_r] <= SNP_ST_LLC_UPD;
                        else if (data_expected_q[rsp_idx_r])
                            state_q[rsp_idx_r] <= SNP_ST_WAIT_DATA;
                        else
                            state_q[rsp_idx_r] <= SNP_ST_FILTER_UPD;
                    end
                end else if (rsp_dirty) begin
                    if (data_seen_for_rsp) begin
                        data_expected_q[rsp_idx_r] <= 1'b0;
                        data_src_mask_q[rsp_idx_r] <= {NUM_RN{1'b0}};
                    end else begin
                        data_expected_q[rsp_idx_r] <= 1'b1;
                        data_src_mask_q[rsp_idx_r] <=
                            data_src_mask_q[rsp_idx_r] | rsp_src_onehot_r;
                    end
                end

                if (!rsp_fwded_eff && rsp_wait_done_next && !rsp_dirty) begin
                    if (data_seen_for_rsp) begin
                        state_q[rsp_idx_r] <= SNP_ST_LLC_UPD;
                    end else if (data_expected_q[rsp_idx_r]) begin
                        state_q[rsp_idx_r] <= SNP_ST_WAIT_DATA;
                    end else if (mode_backinv_q[rsp_idx_r]) begin
                        state_q[rsp_idx_r] <= SNP_ST_FILTER_UPD;
                    end else begin
                        state_q[rsp_idx_r] <= SNP_ST_REPLAY;
                    end
                end else if (!rsp_fwded_eff && rsp_wait_done_next && rsp_dirty) begin
                    if (data_seen_for_rsp)
                        state_q[rsp_idx_r] <= SNP_ST_LLC_UPD;
                    else
                        state_q[rsp_idx_r] <= SNP_ST_WAIT_DATA;
                end
            end

            if (dat_fire && dat_data_id_ok &&
                (state_q[dat_idx_r] != SNP_ST_DRAIN) &&
                (state_q[dat_idx_r] != SNP_ST_ERR)) begin
                beat_mask_q[dat_idx_r] <= dat_beat_mask_next;
                if (&dat_beat_mask_next) begin
                    data_seen_q[dat_idx_r] <= 1'b1;
                    data_expected_q[dat_idx_r] <= 1'b0;
                    data_src_mask_q[dat_idx_r] <= {NUM_RN{1'b0}};
                    if (wait_mask_q[dat_idx_r] == {NUM_RN{1'b0}})
                        state_q[dat_idx_r] <= SNP_ST_LLC_UPD;
                end
            end

            if (llc_update_fire) begin
                if (mode_backinv_q[llc_update_idx_r]) begin
                    state_q[llc_update_idx_r] <= SNP_ST_FILTER_UPD;
                end else if (forwarded_q[llc_update_idx_r]) begin
                    state_q[llc_update_idx_r] <= SNP_ST_FILTER_UPD;
                end else if (req_is_read_q[llc_update_idx_r]) begin
                    state_q[llc_update_idx_r] <= SNP_ST_SEND_DAT;
                    send_beat_q[llc_update_idx_r] <= 4'd0;
                end else begin
                    state_q[llc_update_idx_r] <= SNP_ST_REPLAY;
                end
            end

            if (filter_update_fire) begin
                if (state_q[filter_update_idx_r] == SNP_ST_FILTER_UPD) begin
                    if (forwarded_q[filter_update_idx_r]) begin
                        if (fwd_filter_ack_seen) begin
                            state_q[filter_update_idx_r] <= SNP_ST_EMPTY;
                            forwarded_q[filter_update_idx_r] <= 1'b0;
                            forward_ack_seen_q[filter_update_idx_r] <= 1'b0;
                        end else begin
                            state_q[filter_update_idx_r] <= SNP_ST_FWD_WAIT_ACK;
                        end
                    end else begin
                        state_q[filter_update_idx_r] <= SNP_ST_REPLAY;
                    end
                end else begin
                    state_q[filter_update_idx_r] <= SNP_ST_EMPTY;
                end
            end

            if (replay_fire)
                state_q[replay_idx_r] <= SNP_ST_EMPTY;

            if (tx_dat_fire) begin
                if (send_beat_q[tx_dat_idx_r] == (BEATS - 1)) begin
                    send_beat_q[tx_dat_idx_r] <= 4'd0;
                    state_q[tx_dat_idx_r] <= SNP_ST_WAIT_ACK;
                end else begin
                    send_beat_q[tx_dat_idx_r] <=
                        send_beat_q[tx_dat_idx_r] + 1'b1;
                end
            end

            if (comp_ack_fire) begin
                if (state_q[comp_ack_idx_r] == SNP_ST_WAIT_ACK) begin
                    state_q[comp_ack_idx_r] <= SNP_ST_ACK_FILTER;
                end else if (state_q[comp_ack_idx_r] ==
                             SNP_ST_FWD_WAIT_ACK) begin
                    state_q[comp_ack_idx_r] <= SNP_ST_EMPTY;
                    forwarded_q[comp_ack_idx_r] <= 1'b0;
                    forward_ack_seen_q[comp_ack_idx_r] <= 1'b0;
                end else begin
                    forward_ack_seen_q[comp_ack_idx_r] <= 1'b1;
                end
            end

            if (err_fire) begin
                state_q[err_idx_r] <= SNP_ST_DRAIN;
                drain_cnt_q[err_idx_r] <= DRAIN_WINDOW_VALUE;
            end

            if (alloc_fire) begin
                state_q[free_idx_r] <= SNP_ST_WAIT_RSP;
                mode_backinv_q[free_idx_r] <= alloc_mode_backinv;
                req_is_read_q[free_idx_r] <= alloc_req_is_read;
                req_is_write_q[free_idx_r] <= alloc_req_is_write;
                dirty_q[free_idx_r] <= 1'b0;
                wb_done_q[free_idx_r] <= 1'b0;
                excl_q[free_idx_r] <= alloc_excl;
                txn_id_q[free_idx_r] <= alloc_txn_id;
                src_id_q[free_idx_r] <= alloc_src_id;
                qos_q[free_idx_r] <= alloc_qos;
                opcode_q[free_idx_r] <= alloc_opcode;
                requestor_onehot_q[free_idx_r] <= alloc_requestor_onehot;
                send_mask_q[free_idx_r] <= alloc_snp_valid_vec;
                wait_mask_q[free_idx_r] <= alloc_snp_valid_vec;
                data_src_mask_q[free_idx_r] <= {NUM_RN{1'b0}};
                snoop_target_mask_q[free_idx_r] <= alloc_snp_valid_vec;
                beat_mask_q[free_idx_r] <= {BEATS{1'b0}};
                data_expected_q[free_idx_r] <= 1'b0;
                data_seen_q[free_idx_r] <= 1'b0;
                forwarded_q[free_idx_r] <= 1'b0;
                forward_ack_seen_q[free_idx_r] <= 1'b0;
                send_beat_q[free_idx_r] <= 4'd0;
                timeout_cnt_q[free_idx_r] <= {TIMEOUT_W{1'b0}};
                drain_cnt_q[free_idx_r] <= {DRAIN_W{1'b0}};
                if (alloc_snp_valid_vec == {NUM_RN{1'b0}})
                    state_q[free_idx_r] <= alloc_mode_backinv ?
                                           SNP_ST_FILTER_UPD : SNP_ST_REPLAY;
            end

            if (timeout_valid_r) begin
                state_q[timeout_idx_r] <= timeout_error_ok_r ?
                                          SNP_ST_ERR : SNP_ST_DRAIN;
                send_mask_q[timeout_idx_r] <= {NUM_RN{1'b0}};
                wait_mask_q[timeout_idx_r] <= {NUM_RN{1'b0}};
                drain_cnt_q[timeout_idx_r] <= DRAIN_WINDOW_VALUE;
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && vrsp_valid_q && !vrsp_go &&
            dat_fire && dat_data_id_ok && (&dat_beat_mask_next) &&
            !forwarded_q[dat_idx_r] &&
            (state_q[dat_idx_r] == SNP_ST_WAIT_RSP) &&
            (|(wait_mask_q[dat_idx_r] & dat_src_onehot_r))) begin
            $display("ERROR: chi_hn_snoop_tracker SnpRespData response dropped");
            $stop;
        end
        if (rstn && ((DEPTH << RN_W) > (1 << (DBID_W - 6)))) begin
            $display("ERROR: chi_hn_snoop_tracker DEPTH*NUM_RN does not fit the snoop TxnID class");
            $stop;
        end
    end
    // synthesis translate_on
endmodule

// -----------------------------------------------------------------------------
// Module: chi_hn_read_tracker
// Purpose: Tracks detached HN-F read misses after MemReq issue. It captures
//          SN-F read DAT by HN-local memory TxnID/SN source, updates LLC,
//          returns CompData to the original RN, and releases the line on
//          CompAck.
// -----------------------------------------------------------------------------
module chi_hn_read_tracker #(
    parameter NODE_ID    = 0,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter DEPTH      = `CHI_DEFAULT_HN_READ_TRACKER_DEPTH,
    // DBID of entry i is DBID_BASE + i.
    parameter [DBID_W-1:0] DBID_BASE = {DBID_W{1'b0}},
    parameter LINE_BYTES = 64,
    parameter TIMEOUT_CYCLES = 1024,
    parameter FUNCTIONAL_TIMEOUT = 0,
    parameter RSP_W      = `CHI_RSP_W(`CHI_DEFAULT_NODE_ID_W)
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    alloc_valid,
    output                   alloc_ready,
    input      [TXN_ID_W-1:0] alloc_txn_id,
    input      [NODE_ID_W-1:0] alloc_src_id,
    input      [QOS_W-1:0]   alloc_qos,
    input      [ADDR_WIDTH-1:0] alloc_addr,
    input      [`CHI_REQ_OPCODE_W-1:0] alloc_opcode,
    input                    alloc_excl,
    input      [NODE_ID_W-1:0] alloc_mem_tgt_id,
    output     [TXN_ID_W-1:0] alloc_mem_txn_id,

    input                    dat_valid,
    output                   dat_ready,
    output                   dat_match,
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] dat_flit,

    input                    comp_ack_valid,
    input                    comp_ack_ready,
    output                   comp_ack_match,
    input      [TXN_ID_W-1:0] comp_ack_txn_id,
    input      [NODE_ID_W-1:0] comp_ack_src_id,

    output                   tx_dat_valid,
    input                    tx_dat_ready,
    output reg [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] tx_dat_flit,

    output                   llc_update_valid,
    input                    llc_update_ready,
    output     [ADDR_WIDTH-1:0] llc_update_addr,
    output     [LINE_BYTES*8-1:0] llc_update_data,
    output     [2:0]         llc_update_state,

    output                   ack_valid,
    output     [ADDR_WIDTH-1:0] ack_addr,
    output     [NODE_ID_W-1:0] ack_src_id,
    output                   ack_excl,
    output                   ack_shared,

    output                   err_valid,
    input                    err_ready,
    output reg [RSP_W-1:0]   err_flit,

    output     [DEPTH-1:0]   active_valid_vec,
    output     [DEPTH*ADDR_WIDTH-1:0] active_addr_flat,
    output     [15:0]        used_count,
    output                   watchdog
);
    `include "../common/chi_clog2.vh"
    localparam IDX_W = (DEPTH <= 2) ? 1 : `CHI_CLOG2(DEPTH);
    localparam BE_W = DATA_WIDTH / 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam DATAID_SHIFT = `CHI_DAT_DATAID_SHIFT(DATA_WIDTH);
    localparam [`CHI_DAT_DATAID_W-1:0] DATAID_ALIGN_MASK = (1 << DATAID_SHIFT) - 1;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam TIMEOUT_W = (TIMEOUT_CYCLES <= 2) ? 1 : `CHI_CLOG2(TIMEOUT_CYCLES + 1);
    localparam [TIMEOUT_W-1:0] TIMEOUT_VALUE = TIMEOUT_CYCLES;
    localparam [NODE_ID_W-1:0] NODE_ID_SIZED = NODE_ID;

    localparam RD_ST_EMPTY    = 3'd0;
    localparam RD_ST_WAIT_DAT = 3'd1;
    localparam RD_ST_LLC_UPD  = 3'd2;
    localparam RD_ST_SEND_DAT = 3'd3;
    localparam RD_ST_WAIT_ACK = 3'd4;
    localparam RD_ST_ERR      = 3'd5;
    localparam RD_ST_DRAIN    = 3'd6;
    localparam DRAIN_WINDOW   = 8;
    localparam DRAIN_W        = 4;
    localparam [DRAIN_W-1:0] DRAIN_WINDOW_VALUE = DRAIN_WINDOW;

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

    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(NODE_ID_W);

    reg [2:0]            state_q [0:DEPTH-1];
    reg [TXN_ID_W-1:0]   txn_id_q [0:DEPTH-1];
    reg [NODE_ID_W-1:0]  src_id_q [0:DEPTH-1];
    reg [QOS_W-1:0]      qos_q [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] addr_q [0:DEPTH-1];
    reg [NODE_ID_W-1:0]  mem_tgt_id_q [0:DEPTH-1];
    reg [TXN_ID_W-1:0]   mem_txn_id_q [0:DEPTH-1];
    (* ram_style = "registers" *) reg [LINE_WIDTH-1:0] line_q [0:DEPTH-1];
    reg [BEATS-1:0]      beat_mask_q [0:DEPTH-1];
    reg [3:0]            send_beat_q [0:DEPTH-1];
    reg [1:0]            resp_err_q [0:DEPTH-1];
    reg [2:0]            update_state_q [0:DEPTH-1];
    reg [2:0]            compdata_resp_q [0:DEPTH-1];
    reg                  excl_q [0:DEPTH-1];
    reg [TIMEOUT_W-1:0]  timeout_cnt_q [0:DEPTH-1];
    reg [DRAIN_W-1:0]    drain_cnt_q [0:DEPTH-1];

    reg                  free_valid_r;
    reg [IDX_W-1:0]      free_idx_r;
    reg                  dat_match_r;
    reg [IDX_W-1:0]      dat_idx_r;
    reg                  update_valid_r;
    reg [IDX_W-1:0]      update_idx_r;
    reg                  send_valid_r;
    reg [IDX_W-1:0]      send_idx_r;
    reg                  ack_match_r;
    reg [IDX_W-1:0]      ack_idx_r;
    reg                  err_valid_r;
    reg [IDX_W-1:0]      err_idx_r;
    reg                  timeout_valid_r;
    reg                  watchdog_r;
    reg [IDX_W-1:0]      timeout_idx_r;
    reg [15:0]           used_count_r;
    integer              scan_i;
    integer              reset_i;
    genvar               gi;

    wire [TXN_ID_W-1:0] free_idx_txn = free_idx_r;
    wire alloc_fire = alloc_valid && alloc_ready;
    wire dat_fire = dat_valid && dat_ready && dat_match;
    wire update_fire = llc_update_valid && llc_update_ready;
    wire tx_dat_fire = tx_dat_valid && tx_dat_ready;
    wire ack_fire = comp_ack_valid && comp_ack_ready && comp_ack_match;
    wire err_fire = err_valid && err_ready;

    wire [TXN_ID_W-1:0] dat_txn_id = dat_flit[DAT_TXN_LSB +: TXN_ID_W];
    wire [NODE_ID_W-1:0] dat_src_id = dat_flit[DAT_SRC_LSB +: NODE_ID_W];
    wire [NODE_ID_W-1:0] dat_tgt_id = dat_flit[DAT_TGT_LSB +: NODE_ID_W];
    wire [3:0] dat_opcode = dat_flit[DAT_OPCODE_LSB +: 4];
    wire [1:0] dat_resp_err = dat_flit[DAT_RESPERR_LSB +: 2];
    wire [`CHI_DAT_QOS_W-1:0] tx_dat_qos;
    wire [`CHI_DAT_DATAID_W-1:0] dat_data_id =
        dat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W];
    wire [3:0] dat_beat_idx = dat_data_id >> DATAID_SHIFT;
    wire [`CHI_DAT_DATAID_W-1:0] tx_dat_data_id = send_beat_q[send_idx_r] << DATAID_SHIFT;
    wire dat_data_id_ok =
        ((dat_data_id & DATAID_ALIGN_MASK) == {`CHI_DAT_DATAID_W{1'b0}}) &&
        (dat_beat_idx < BEATS);
    wire [LINE_WIDTH-1:0] dat_line_next =
        line_q[dat_idx_r] |
        ({{(LINE_WIDTH-DATA_WIDTH){1'b0}},
          dat_flit[DAT_DATA_LSB +: DATA_WIDTH]} <<
         (dat_beat_idx * DATA_WIDTH));
    wire [BEATS-1:0] dat_beat_mask_next =
        beat_mask_q[dat_idx_r] |
        ({{(BEATS-1){1'b0}}, 1'b1} << dat_beat_idx);

    generate
        if (QOS_W >= `CHI_DAT_QOS_W) begin : gen_dat_qos_full
            assign tx_dat_qos = qos_q[send_idx_r][`CHI_DAT_QOS_W-1:0];
        end else begin : gen_dat_qos_pad
            assign tx_dat_qos =
                {{(`CHI_DAT_QOS_W-QOS_W){1'b0}}, qos_q[send_idx_r]};
        end
    endgenerate

    assign alloc_ready = free_valid_r;
    // Class tag 2'b01 keeps read TxnIDs disjoint from the write tracker
    // (2'b10) and LLC evictions (all-ones) at the SN.
    assign alloc_mem_txn_id = {2'b01, free_idx_txn[TXN_ID_W-3:0]};
    assign dat_ready = dat_match_r;
    assign dat_match = dat_match_r;
    assign comp_ack_match = ack_match_r;
    assign tx_dat_valid = send_valid_r;
    assign llc_update_valid = update_valid_r;
    assign llc_update_addr = update_valid_r ?
                             addr_q[update_idx_r] : {ADDR_WIDTH{1'b0}};
    assign llc_update_data = update_valid_r ?
                             line_q[update_idx_r] : {LINE_WIDTH{1'b0}};
    assign llc_update_state = update_valid_r ?
                              update_state_q[update_idx_r] : `CHI_STATE_SC;
    assign ack_valid = ack_fire;
    assign ack_addr = ack_match_r ? addr_q[ack_idx_r] : {ADDR_WIDTH{1'b0}};
    assign ack_src_id = ack_match_r ? src_id_q[ack_idx_r] : {NODE_ID_W{1'b0}};
    assign ack_excl = ack_match_r ? excl_q[ack_idx_r] : 1'b0;
    assign ack_shared = ack_match_r &&
                        (update_state_q[ack_idx_r] != `CHI_STATE_UC);
    assign err_valid = err_valid_r;
    assign used_count = used_count_r;
    assign watchdog = watchdog_r;

    generate
        for (gi = 0; gi < DEPTH; gi = gi + 1) begin : gen_active_line
            assign active_valid_vec[gi] = (state_q[gi] != RD_ST_EMPTY);
            assign active_addr_flat[gi*ADDR_WIDTH +: ADDR_WIDTH] = addr_q[gi];
        end
    endgenerate

    always @(*) begin
        free_valid_r = 1'b0;
        free_idx_r = {IDX_W{1'b0}};
        dat_match_r = 1'b0;
        dat_idx_r = {IDX_W{1'b0}};
        update_valid_r = 1'b0;
        update_idx_r = {IDX_W{1'b0}};
        send_valid_r = 1'b0;
        send_idx_r = {IDX_W{1'b0}};
        ack_match_r = 1'b0;
        ack_idx_r = {IDX_W{1'b0}};
        err_valid_r = 1'b0;
        err_idx_r = {IDX_W{1'b0}};
        timeout_valid_r = 1'b0;
        timeout_idx_r = {IDX_W{1'b0}};
        watchdog_r = 1'b0;
        used_count_r = 16'd0;

        for (scan_i = 0; scan_i < DEPTH; scan_i = scan_i + 1) begin
            if (state_q[scan_i] != RD_ST_EMPTY) begin
                used_count_r = used_count_r + 1'b1;
                if ((state_q[scan_i] == RD_ST_WAIT_DAT) &&
                    (timeout_cnt_q[scan_i] == TIMEOUT_VALUE - 1'b1))
                    watchdog_r = 1'b1;

                if ((state_q[scan_i] == RD_ST_WAIT_DAT) &&
                    (FUNCTIONAL_TIMEOUT != 0) &&
                    (timeout_cnt_q[scan_i] >= TIMEOUT_VALUE)) begin
                    if (!timeout_valid_r) begin
                        timeout_valid_r = 1'b1;
                        timeout_idx_r = scan_i[IDX_W-1:0];
                    end
                end else begin
                    if (!dat_match_r &&
                        ((state_q[scan_i] == RD_ST_WAIT_DAT) ||
                         (state_q[scan_i] == RD_ST_ERR) ||
                         (state_q[scan_i] == RD_ST_DRAIN)) &&
                        (dat_opcode == `CHI_DAT_OPCODE_RD_DATA) &&
                        (mem_txn_id_q[scan_i] == dat_txn_id) &&
                        (mem_tgt_id_q[scan_i] == dat_src_id) &&
                        (dat_tgt_id == NODE_ID_SIZED)) begin
                        dat_match_r = 1'b1;
                        dat_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!update_valid_r &&
                        (state_q[scan_i] == RD_ST_LLC_UPD)) begin
                        update_valid_r = 1'b1;
                        update_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!send_valid_r &&
                        (state_q[scan_i] == RD_ST_SEND_DAT)) begin
                        send_valid_r = 1'b1;
                        send_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!ack_match_r &&
                        (state_q[scan_i] == RD_ST_WAIT_ACK) &&
                        (comp_ack_txn_id == (DBID_BASE + scan_i)) &&
                        (src_id_q[scan_i] == comp_ack_src_id)) begin
                        ack_match_r = 1'b1;
                        ack_idx_r = scan_i[IDX_W-1:0];
                    end

                    if (!err_valid_r &&
                        (state_q[scan_i] == RD_ST_ERR)) begin
                        err_valid_r = 1'b1;
                        err_idx_r = scan_i[IDX_W-1:0];
                    end
                end
            end else if (!free_valid_r) begin
                free_valid_r = 1'b1;
                free_idx_r = scan_i[IDX_W-1:0];
            end
        end
    end

    always @(*) begin
        tx_dat_flit = {`CHI_DAT_W(DATA_WIDTH,NODE_ID_W){1'b0}};
        tx_dat_flit[DAT_RESPERR_LSB +: 2]       = resp_err_q[send_idx_r];
        tx_dat_flit[DAT_BE_LSB +: BE_W]         = {BE_W{1'b1}};
        tx_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] =
            line_q[send_idx_r][send_beat_q[send_idx_r]*DATA_WIDTH +: DATA_WIDTH];
        tx_dat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W] = tx_dat_data_id;
        tx_dat_flit[DAT_DBID_LSB +: DBID_W]     = DBID_BASE + send_idx_r;
        tx_dat_flit[DAT_TXN_LSB +: TXN_ID_W]    = txn_id_q[send_idx_r];
        tx_dat_flit[DAT_SRC_LSB +: NODE_ID_W]   = NODE_ID_SIZED;
        tx_dat_flit[DAT_TGT_LSB +: NODE_ID_W]   = src_id_q[send_idx_r];
        tx_dat_flit[DAT_RESP_LSB +: 3]          = compdata_resp_q[send_idx_r];
        tx_dat_flit[DAT_OPCODE_LSB +: 4]        = `CHI_DAT_OPCODE_RD_DATA;
        tx_dat_flit[DAT_QOS_LSB +: `CHI_DAT_QOS_W] = tx_dat_qos;
        tx_dat_flit[DAT_HOME_NID_LSB +: NODE_ID_W] = NODE_ID_SIZED;
    end

    always @(*) begin
        err_flit = {RSP_W{1'b0}};
        err_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        err_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_SLVERR;
        err_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        err_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_COMP;
        err_flit[RSP_TXN_LSB +: TXN_ID_W]  = txn_id_q[err_idx_r];
        err_flit[RSP_SRC_LSB +: NODE_ID_W] = NODE_ID_SIZED;
        err_flit[RSP_TGT_LSB +: NODE_ID_W] = src_id_q[err_idx_r];
        err_flit[RSP_QOS_LSB +: QOS_W]     = qos_q[err_idx_r];
    end

    always @(posedge clk) begin
        if (rstn && !clear) begin
            if (dat_fire && dat_data_id_ok &&
                (state_q[dat_idx_r] == RD_ST_WAIT_DAT)) begin
                line_q[dat_idx_r] <= dat_line_next;
            end

            if (alloc_fire) begin
                addr_q[free_idx_r] <= alloc_addr;
                line_q[free_idx_r] <= {LINE_WIDTH{1'b0}};
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1) begin
                state_q[reset_i] <= RD_ST_EMPTY;
                txn_id_q[reset_i] <= {TXN_ID_W{1'b0}};
                src_id_q[reset_i] <= {NODE_ID_W{1'b0}};
                qos_q[reset_i] <= {QOS_W{1'b0}};
                mem_tgt_id_q[reset_i] <= {NODE_ID_W{1'b0}};
                mem_txn_id_q[reset_i] <= {TXN_ID_W{1'b0}};
                beat_mask_q[reset_i] <= {BEATS{1'b0}};
                send_beat_q[reset_i] <= 4'd0;
                resp_err_q[reset_i] <= `CHI_RESPERR_OK;
                update_state_q[reset_i] <= `CHI_STATE_SC;
                compdata_resp_q[reset_i] <= `CHI_COMPDATA_RESP_I;
                excl_q[reset_i] <= 1'b0;
                timeout_cnt_q[reset_i] <= {TIMEOUT_W{1'b0}};
                drain_cnt_q[reset_i] <= {DRAIN_W{1'b0}};
            end
        end else if (clear) begin
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1) begin
                state_q[reset_i] <= RD_ST_EMPTY;
                timeout_cnt_q[reset_i] <= {TIMEOUT_W{1'b0}};
                drain_cnt_q[reset_i] <= {DRAIN_W{1'b0}};
            end
        end else begin
            for (scan_i = 0; scan_i < DEPTH; scan_i = scan_i + 1) begin
                if (state_q[scan_i] == RD_ST_WAIT_DAT) begin
                    if (timeout_cnt_q[scan_i] != TIMEOUT_VALUE)
                        timeout_cnt_q[scan_i] <= timeout_cnt_q[scan_i] + 1'b1;
                end

                if (state_q[scan_i] == RD_ST_DRAIN) begin
                    if (drain_cnt_q[scan_i] == {DRAIN_W{1'b0}}) begin
                        state_q[scan_i] <= RD_ST_EMPTY;
                        beat_mask_q[scan_i] <= {BEATS{1'b0}};
                    end else begin
                        drain_cnt_q[scan_i] <= drain_cnt_q[scan_i] - 1'b1;
                    end
                end
            end

            if (dat_fire && dat_data_id_ok &&
                (state_q[dat_idx_r] == RD_ST_WAIT_DAT)) begin
                beat_mask_q[dat_idx_r] <= dat_beat_mask_next;
                if (dat_resp_err != `CHI_RESPERR_OK)
                    resp_err_q[dat_idx_r] <= dat_resp_err;
                if (&dat_beat_mask_next)
                    state_q[dat_idx_r] <= RD_ST_LLC_UPD;
            end

            if (update_fire) begin
                state_q[update_idx_r] <= RD_ST_SEND_DAT;
                send_beat_q[update_idx_r] <= 4'd0;
            end

            if (tx_dat_fire) begin
                if (send_beat_q[send_idx_r] == (BEATS - 1)) begin
                    send_beat_q[send_idx_r] <= 4'd0;
                    state_q[send_idx_r] <= RD_ST_WAIT_ACK;
                end else begin
                    send_beat_q[send_idx_r] <= send_beat_q[send_idx_r] + 1'b1;
                end
            end

            if (ack_fire)
                state_q[ack_idx_r] <= RD_ST_EMPTY;

            if (err_fire) begin
                state_q[err_idx_r] <= RD_ST_DRAIN;
                drain_cnt_q[err_idx_r] <= DRAIN_WINDOW_VALUE;
            end

            if (alloc_fire) begin
                state_q[free_idx_r] <= RD_ST_WAIT_DAT;
                txn_id_q[free_idx_r] <= alloc_txn_id;
                src_id_q[free_idx_r] <= alloc_src_id;
                qos_q[free_idx_r] <= alloc_qos;
                mem_tgt_id_q[free_idx_r] <= alloc_mem_tgt_id;
                mem_txn_id_q[free_idx_r] <= alloc_mem_txn_id;
                beat_mask_q[free_idx_r] <= {BEATS{1'b0}};
                send_beat_q[free_idx_r] <= 4'd0;
                resp_err_q[free_idx_r] <= `CHI_RESPERR_OK;
                excl_q[free_idx_r] <= alloc_excl;
                timeout_cnt_q[free_idx_r] <= {TIMEOUT_W{1'b0}};
                drain_cnt_q[free_idx_r] <= {DRAIN_W{1'b0}};
                update_state_q[free_idx_r] <=
                    (alloc_opcode == `CHI_REQ_RD_UNIQUE) ?
                    `CHI_STATE_UC : `CHI_STATE_SC;
                compdata_resp_q[free_idx_r] <=
                    `CHI_COMPDATA_RESP_FOR(alloc_opcode);
            end

            if (timeout_valid_r) begin
                state_q[timeout_idx_r] <= RD_ST_ERR;
                drain_cnt_q[timeout_idx_r] <= {DRAIN_W{1'b0}};
            end
        end
    end
endmodule
