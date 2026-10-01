`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_rn_f
// Purpose: Request Node - Fully coherent (RN-F). Bridges the simple CPU-side
//          request interface to CHI REQ/RSP/DAT/SNP channels, owns the RN
//          transaction table, private cache, WDAT path, and snoop handling.
// -----------------------------------------------------------------------------
module chi_rn_f #(
    parameter NODE_ID    = 0,
    // CPU word width.
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    // CHI DAT channel data width.
    parameter DAT_DATA_W = `CHI_DEFAULT_DAT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter CPU_TAG_W  = 2,
    parameter INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter TXN_TBL_SIZE = `CHI_DEFAULT_RN_TXN_TBL_SIZE,
    parameter RN_CACHE_LINES = `CHI_DEFAULT_RN_CACHE_LINES,
    parameter USE_EXTERNAL_L1_SNOOP = 0,
    parameter TIMEOUT_CYCLES = 1024,
    // 0: an outstanding transaction older than TIMEOUT_CYCLES only raises
    //    watchdog_event; it keeps waiting for its real completion.
    // 1: legacy behaviour, the timeout completes it with zero data.
    parameter FUNCTIONAL_TIMEOUT = 0,
    parameter ENABLE_PERF = `CHI_DEFAULT_ENABLE_PERF
)(
    input                    clk,
    input                    rstn,

    input                    cpu_req_valid,
    output                   cpu_req_ready,
    input      [ADDR_WIDTH-1:0] cpu_req_addr,
    input      [3:0]         cpu_req_op,
    input      [2:0]         cpu_req_size,
    input      [QOS_W-1:0]   cpu_req_qos,
    input      [CPU_TAG_W-1:0] cpu_req_tag,
    input      [DATA_WIDTH-1:0] cpu_wdata,
    input      [64*8-1:0]    cpu_wdata_line_in,
    input      [64-1:0]      cpu_wstrb_line_in,
    output     [DATA_WIDTH-1:0] cpu_rdata,
    output                   cpu_resp_valid,
    output     [CPU_TAG_W-1:0] cpu_resp_tag,
    output                   cpu_resp_line_valid,
    output     [64*8-1:0]    cpu_resp_line_data,
    output     [CPU_TAG_W-1:0] cpu_resp_line_tag,

    output                   l1_snoop_valid,
    input                    l1_snoop_ready,
    output                   l1_snoop_invalidate,
    output     [ADDR_WIDTH-1:0] l1_snoop_addr,
    input                    l1_snoop_result_valid,
    input                    l1_snoop_hit,
    input                    l1_snoop_dirty,
    input      [64*8-1:0]    l1_snoop_data,

    output                   tx_req_valid,
    output     [`CHI_REQ_W(NODE_ID_W)-1:0] tx_req_flit,
    input                    tx_req_lcrdv,

    output                   tx_rsp_valid,
    output     [`CHI_RSP_W(NODE_ID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv,

    output                   tx_dat_valid,
    output     [`CHI_DAT_W(DAT_DATA_W,NODE_ID_W)-1:0] tx_dat_flit,
    input                    tx_dat_lcrdv,

    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_ready,
    output                   rx_rsp_lcrdv,

    input                    rx_snp_valid,
    input      [`CHI_SNP_W(NODE_ID_W)-1:0] rx_snp_flit,
    output                   rx_snp_ready,
    output                   rx_snp_lcrdv,

    input                    rx_dat_valid,
    input      [`CHI_DAT_W(DAT_DATA_W,NODE_ID_W)-1:0] rx_dat_flit,
    output                   rx_dat_ready,
    output                   rx_dat_lcrdv,

    output     [16*32-1:0]   perf_counts,
    output                   cache_parity_error_event,
    output                   watchdog_event,
    // Any transaction, snoop, queued flit or local reservation in flight.
    output                   busy
);
    `CHI_FLIT_PARAM_CHECK(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W,QOS_W,DAT_DATA_W)
    `include "../common/chi_clog2.vh"
    localparam REQ_W = `CHI_REQ_W(NODE_ID_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W);
    localparam DAT_W = `CHI_DAT_W(DAT_DATA_W,NODE_ID_W);
    localparam LINE_BYTES = 64;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam BE_W = DATA_WIDTH / 8;
    localparam TXN_IDX_W = (TXN_TBL_SIZE <= 2) ? 1 : `CHI_CLOG2(TXN_TBL_SIZE);
    localparam SNP_OPCODE_LSB = `CHI_SNP_OPCODE_LSB(NODE_ID_W);
    localparam REQ_ALLOW_RETRY_LSB =
        `CHI_REQ_ALLOW_RETRY_LSB(NODE_ID_W);
    localparam REQ_PCRD_TYPE_LSB =
        `CHI_REQ_PCRD_TYPE_LSB(NODE_ID_W);
    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(NODE_ID_W);

    wire [NODE_ID_W-1:0] node_id_wire;
    wire [NODE_ID_W-1:0] target_id;
    wire [3:0]           route_id_unused;
    wire [3:0]           route_onehot_unused;
    wire                 route_error_unused;
    wire [QOS_W-1:0]     qos_value;
    wire [15:0]          rn_perf_events;
    wire [16*32-1:0]     rn_perf_counts_unused;

    wire                 txn_alloc_valid;
    wire                 txn_alloc_ready;
    wire [TXN_ID_W-1:0]  txn_alloc_id;
    wire [`CHI_REQ_OPCODE_W-1:0] req_opcode;
    wire [REQ_W-1:0]     req_engine_flit;
    wire                 req_engine_valid;
    wire                 req_engine_ready;
    wire                 req_engine_cpu_ready;
    wire                 cpu_req_valid_to_engine;
    wire                 req_engine_input_valid;
    wire [ADDR_WIDTH-1:0] req_engine_input_addr;
    wire [3:0]           req_engine_input_op;
    wire [2:0]           req_engine_input_size;
    wire [LINE_WIDTH-1:0] req_engine_wdata_line;
    wire [LINE_BYTES-1:0] req_engine_wstrb_line;

    wire                 rsp_comp_valid;
    wire                 rsp_dbid_valid;
    wire                 rsp_dbid_match_valid;
    wire                 rsp_retry_ack_valid;
    wire                 rsp_pcrd_grant_valid;
    wire                 rsp_retry_touch_match_valid;
    wire                 rsp_rx_ready;
    wire [TXN_ID_W-1:0]  rsp_txn_id;
    wire [DBID_W-1:0]    rsp_dbid;
    wire [`CHI_REQ_PCRD_TYPE_W-1:0] rsp_pcrd_type;
    wire [NODE_ID_W-1:0] rsp_src_id;
    wire [1:0]           rsp_resp_err;

    wire                 dat_data_valid;
    wire [DAT_DATA_W-1:0] dat_data;
    wire [LINE_WIDTH-1:0] dat_line_data_unused;
    wire [TXN_ID_W-1:0]  dat_txn_id;
    wire [NODE_ID_W-1:0] dat_src_id;
    wire [NODE_ID_W-1:0] dat_home_nid;
    wire [1:0]           dat_resp_err;
    wire [2:0]           dat_resp_unused;
    wire [DBID_W-1:0]    dat_dbid;
    wire                 dat_line_valid_unused;
    wire [DATA_WIDTH-1:0] dat_line_cpu_data;
    wire                 dat_txn_match;
    wire                 selected_complete_valid;
    wire [TXN_ID_W-1:0]  selected_complete_txn_id;
    wire                 selected_complete_match_valid;

    wire                 snoop_rsp_valid;
    wire                 snoop_rsp_ready;
    wire [RSP_W-1:0]     snoop_rsp_flit;
    wire                 compack_rsp_ready;
    wire                 tx_rsp_link_valid;
    wire                 tx_rsp_link_ready;
    wire [RSP_W-1:0]     tx_rsp_link_flit;

    wire                 wdat_valid;
    wire                 wdat_engine_ready;
    wire                 wdata_ready_unused;
    wire [DAT_W-1:0]     wdat_flit;
    wire [LINE_WIDTH-1:0] cpu_wdata_line;
    wire [LINE_BYTES-1:0] cpu_wstrb_line;
    reg  [LINE_WIDTH-1:0] cpu_wdata_line_r;
    reg  [LINE_BYTES-1:0] cpu_wstrb_line_r;
    wire                 dbid_ready_unused;
    wire                 wdat_accept;
    wire                 txn_alloc_is_write;
    wire                 txn_alloc_is_dvm;
    wire [TXN_IDX_W-1:0] txn_alloc_idx;
    wire [TXN_IDX_W-1:0] rsp_txn_idx;
    wire [TXN_IDX_W-1:0] dat_txn_idx;
    wire [3:0]           tx_req_credit_unused;
    wire                 tx_req_link_in_valid;
    wire                 tx_req_link_in_ready;
    wire [REQ_W-1:0]     tx_req_link_in_flit;
    wire                 tx_req_link_accept_blocked;
    wire                 retry_reissue_fire;
    wire [3:0]           tx_rsp_credit_unused;
    wire [3:0]           tx_dat_credit_unused;
    wire                 tx_req_fire_unused;
    wire                 tx_req_return_unused;
    wire                 tx_req_stall_unused;
    wire                 tx_rsp_fire_unused;
    wire                 tx_rsp_return_unused;
    wire                 tx_rsp_stall_unused;
    wire                 tx_dat_fire_unused;
    wire                 tx_dat_return_unused;
    wire                 tx_dat_stall_unused;
    wire                 timeout_valid;
    wire                 rsp_rx_busy;
    wire                 dat_rx_busy;
    wire                 snoop_busy;
    wire                 wdat_busy;
    wire                 cache_busy;
    wire                 timeout_complete;
    wire [TXN_ID_W-1:0]  timeout_txn_id;
    wire [15:0]          outstanding_count;
    wire                 table_full_unused;
    wire [TXN_TBL_SIZE-1:0] txn_debug_entry_valid_unused;
    wire [TXN_TBL_SIZE*TXN_ID_W-1:0] txn_debug_entry_txn_id_flat_unused;

    reg [LINE_WIDTH-1:0] wdata_line_mem [0:TXN_TBL_SIZE-1];
    reg [LINE_BYTES-1:0] wstrb_line_mem [0:TXN_TBL_SIZE-1];
    reg [ADDR_WIDTH-1:0] txn_addr_mem [0:TXN_TBL_SIZE-1];
    reg [REQ_W-1:0]      txn_req_flit_mem [0:TXN_TBL_SIZE-1];
    reg [`CHI_REQ_OPCODE_W-1:0] txn_opcode_mem [0:TXN_TBL_SIZE-1];
    reg [QOS_W-1:0]      txn_qos_mem [0:TXN_TBL_SIZE-1];
    reg [CPU_TAG_W-1:0]  txn_cpu_tag_mem [0:TXN_TBL_SIZE-1];
    reg [TXN_TBL_SIZE-1:0] txn_ldrex_mem;
    reg [TXN_TBL_SIZE-1:0] txn_strex_mem;
    reg [TXN_TBL_SIZE-1:0] txn_cache_evict_mem;
    reg [TXN_TBL_SIZE-1:0] wdata_valid_mem;
    reg [TXN_TBL_SIZE-1:0] retry_ack_mem;
    reg [TXN_TBL_SIZE-1:0] retry_grant_mem;
    reg [`CHI_REQ_PCRD_TYPE_W-1:0] retry_pcrd_type_mem [0:TXN_TBL_SIZE-1];
    reg                  retry_reissue_valid_r;
    reg [TXN_IDX_W-1:0]  retry_reissue_idx_r;
    reg [REQ_W-1:0]      retry_reissue_flit;
    reg                  pending_wdat_valid_q;
    reg [TXN_ID_W-1:0]   pending_wdat_txn_q;
    reg [DBID_W-1:0]     pending_wdat_dbid_q;
    reg [NODE_ID_W-1:0]  pending_wdat_src_q;
    reg [QOS_W-1:0]      pending_wdat_qos_q;
    reg                  pending_wdat_dvm_q;
    reg [LINE_WIDTH-1:0] pending_wdat_data_q;
    reg [LINE_BYTES-1:0] pending_wdat_strb_q;
    reg                  compack_valid_q;
    reg [TXN_ID_W-1:0]   compack_txn_q;
    reg [NODE_ID_W-1:0]  compack_tgt_q;
    reg [RSP_W-1:0]      compack_rsp_flit;
    // CompAck of a MakeUnique (B2.7.2): sent once its Comp arrives, with the
    // DBID of that Comp as TxnID.
    reg                  mu_compack_valid_q;
    reg [TXN_ID_W-1:0]   mu_compack_txn_q;
    reg [NODE_ID_W-1:0]  mu_compack_tgt_q;
    reg [RSP_W-1:0]      mu_compack_flit;
    wire                 mu_compack_ready;
    wire                 mu_comp_fire;

    wire                 cache_update_valid;
    wire [ADDR_WIDTH-1:0] cache_update_addr;
    wire [LINE_WIDTH-1:0] cache_update_data;
    wire [2:0]           cache_update_state;
    wire                 cache_snoop_valid;
    wire                 cache_snoop_result_valid;
    wire [ADDR_WIDTH-1:0] cache_snoop_addr;
    wire [`CHI_SNP_OPCODE_W-1:0] cache_snoop_opcode;
    wire                 cache_snoop_hit;
    wire                 cache_snoop_dirty;
    wire [2:0]           cache_snoop_state;
    wire [LINE_WIDTH-1:0] cache_snoop_data;
    wire                 cache_snoop_send_data;
    wire                 cache_snoop_commit;
    wire                 cache_snoop_parity_error;
    wire                 cache_evict_valid;
    wire                 cache_evict_ready;
    wire [ADDR_WIDTH-1:0] cache_evict_addr;
    wire [LINE_WIDTH-1:0] cache_evict_data;
    wire [2:0]           cache_evict_state_unused;
    wire                 cache_read_fill_update;
    wire                 cache_read_fill_uq;
    wire                 cpu_req_is_ldrex;
    wire                 cpu_req_is_strex;
    wire                 strex_pass;
    wire                 strex_fail;
    wire                 strex_fail_fire;
    wire                 strex_commit;
    wire                 ldrex_complete;
    wire                 exclusive_snoop_clear;
    wire                 exclusive_local_write_clear;
    wire                 dvm_reservation_clear;
    wire                 reservation_valid;
    wire                 reservation_match_unused;
    wire [ADDR_WIDTH-1:0] reservation_addr_unused;
    wire                 ldrex_set_pulse_unused;
    wire                 reservation_clear_pulse_unused;
    wire [`CHI_SNP_OPCODE_W-1:0] rx_snp_opcode;
    wire                 normal_cpu_resp_valid;
    wire                 exclusive_resp_complete;
    wire                 exclusive_success_resp;
    wire                 selected_complete_cpu_visible;
    wire [TXN_IDX_W-1:0] selected_complete_txn_idx;
    wire                 selected_complete_is_read_data;
    wire                 selected_complete_clear;
    wire                 rsp_comp_complete_valid;
    wire                 rsp_comp_cpu_visible;
    wire                 cpu_resp_valid_comb;
    wire [DATA_WIDTH-1:0] cpu_rdata_comb;
    reg                  strex_fail_resp_q;
    reg                  cpu_resp_valid_q;
    reg [DATA_WIDTH-1:0] cpu_rdata_q;
    reg [CPU_TAG_W-1:0]  cpu_resp_tag_q;
    integer              retry_scan_i;
    integer              retry_reset_i;
    wire [3:0]           cpu_line_beat_idx;
    wire [1:0]           cpu_byte_idx;
    wire [3:0]           dat_line_beat_idx;

    // Request as seen by the transaction logic. With the external L1 it is
    // the CPU port itself; with the internal RN cache the front end (FE)
    // drives it after the local cache has been consulted.
    wire                 core_req_valid;
    wire                 core_req_ready;
    wire [ADDR_WIDTH-1:0] core_req_addr;
    wire [3:0]           core_req_op;
    wire [2:0]           core_req_size;
    wire [QOS_W-1:0]     core_req_qos;
    wire [CPU_TAG_W-1:0] core_req_tag;
    wire [LINE_WIDTH-1:0] core_wline;
    wire [LINE_BYTES-1:0] core_wstrb;
    reg  [CPU_TAG_W-1:0] strex_fail_tag_q;

    wire                 fe_resp_fire;
    wire                 fe_resp_line;
    wire [DATA_WIDTH-1:0] fe_resp_rdata;
    wire [CPU_TAG_W-1:0] fe_resp_tag;
    wire [LINE_WIDTH-1:0] fe_resp_line_data;
    wire                 fe_local_store;
    wire                 fe_busy;
    // 2.5: a STREX sent as CleanUnique(Excl) is finished by the front end:
    // it merges the store on EXOKAY, then sends the CompAck.
    wire                 selected_is_strex_cu;
    wire                 strex_cu_done;
    wire                 strex_cu_pass;
    wire                 fe_strex_clear;
    wire                 fe_compack_valid;
    wire                 fe_compack_ready;
    wire [TXN_ID_W-1:0]  fe_compack_txn;
    wire [NODE_ID_W-1:0] fe_compack_tgt;
    reg  [RSP_W-1:0]     fe_compack_flit;
    wire                 cache_cpu_excl_commit;
    wire                 cache_cpu_valid;
    wire                 cache_cpu_ready;
    wire [ADDR_WIDTH-1:0] cache_cpu_addr;
    wire [2:0]           cache_cpu_kind;
    wire [LINE_WIDTH-1:0] cache_cpu_wdata;
    wire [LINE_BYTES-1:0] cache_cpu_wstrb;
    wire                 cache_cpu_done;
    wire                 cache_cpu_hit;
    wire [2:0]           cache_cpu_state;
    wire [LINE_WIDTH-1:0] cache_cpu_line;
    wire                 cache_cpu_local;
    wire                 cache_cpu_flushed;
    wire [1:0]           cache_victim_valid;
    wire [2*ADDR_WIDTH-1:0] cache_victim_addr_flat;
    wire [2*LINE_WIDTH-1:0] cache_victim_data_flat;
    // Snoop result seen by the snoop handler: the cache, or else a dirty
    // line of this RN whose WriteBackFull is queued or waiting for DBIDResp.
    reg                  victim_hit_r;
    reg [LINE_WIDTH-1:0] victim_data_r;
    integer              victim_scan_i;
    wire                 snp_sel_hit;
    wire                 snp_sel_dirty;
    wire [2:0]           snp_sel_state;
    wire [LINE_WIDTH-1:0] snp_sel_data;
    wire                 snp_sel_send_data;

    wire                 snoop_dat_valid;
    wire                 snoop_dat_ready;
    wire [DAT_W-1:0]     snoop_dat_flit;
    wire                 tx_dat_link_valid;
    wire                 tx_dat_link_ready;
    wire [DAT_W-1:0]     tx_dat_link_flit;

    assign node_id_wire = NODE_ID;
    assign qos_value    = cache_evict_valid ? {QOS_W{1'b0}} : core_req_qos;
    assign cpu_line_beat_idx = cpu_req_addr[5:2];
    assign cpu_byte_idx      = cpu_req_addr[1:0];
    assign dat_line_beat_idx = txn_addr_mem[dat_txn_idx][5:2];
    assign cpu_req_is_ldrex = (core_req_op == `CHI_CPU_OP_LDREX);
    assign cpu_req_is_strex = (core_req_op == `CHI_CPU_OP_STREX);
    assign strex_fail_fire = strex_fail;
    assign cpu_req_valid_to_engine = core_req_valid && !strex_fail;
    assign req_engine_input_valid = cache_evict_valid ? 1'b1 : cpu_req_valid_to_engine;
    assign req_engine_input_addr = cache_evict_valid ? cache_evict_addr : core_req_addr;
    assign req_engine_input_op = cache_evict_valid ? `CHI_CPU_OP_WB_FULL : core_req_op;
    assign req_engine_input_size = cache_evict_valid ? 3'd6 : core_req_size;
    assign req_engine_wdata_line = cache_evict_valid ? cache_evict_data : core_wline;
    assign req_engine_wstrb_line = cache_evict_valid ? {LINE_BYTES{1'b1}} : core_wstrb;
    assign cache_evict_ready = cache_evict_valid && req_engine_cpu_ready;
    assign core_req_ready = cache_evict_valid ? 1'b0 :
                            (strex_fail ? 1'b1 : req_engine_cpu_ready);
    assign selected_complete_cpu_visible =
        selected_complete_match_valid &&
        !txn_cache_evict_mem[selected_complete_txn_idx] &&
        !selected_is_strex_cu;
    assign selected_is_strex_cu =
        txn_strex_mem[selected_complete_txn_idx] &&
        (txn_opcode_mem[selected_complete_txn_idx] == `CHI_REQ_CLN_UNIQUE);
    assign strex_cu_done = (rsp_comp_complete_valid || timeout_complete) &&
                           selected_complete_match_valid &&
                           selected_is_strex_cu;
    assign strex_cu_pass = rsp_comp_valid && !timeout_complete &&
                           (rsp_resp_err == `CHI_RESPERR_EXOKAY);
    assign selected_complete_txn_idx =
        selected_complete_txn_id[TXN_IDX_W-1:0];
    assign selected_complete_is_read_data =
        (txn_opcode_mem[selected_complete_txn_idx] == `CHI_REQ_RD_SHARED) ||
        (txn_opcode_mem[selected_complete_txn_idx] == `CHI_REQ_RD_UNIQUE) ||
        (txn_opcode_mem[selected_complete_txn_idx] == `CHI_REQ_RD_ONCE) ||
        (txn_opcode_mem[selected_complete_txn_idx] == `CHI_REQ_RD_NO_SNP);
    assign rsp_comp_complete_valid =
        rsp_comp_valid &&
        selected_complete_match_valid &&
        !selected_complete_is_read_data;
    assign rsp_comp_cpu_visible =
        rsp_comp_complete_valid &&
        selected_complete_cpu_visible;
    assign normal_cpu_resp_valid = rsp_comp_cpu_visible ||
                                   (timeout_complete &&
                                    selected_complete_cpu_visible) ||
                                   (dat_line_valid_unused && dat_txn_match);
    assign exclusive_resp_complete = (rsp_comp_complete_valid || timeout_complete) &&
                                     selected_complete_cpu_visible &&
                                     txn_strex_mem[selected_complete_txn_id[TXN_IDX_W-1:0]];
    assign exclusive_success_resp = exclusive_resp_complete &&
                                    (rsp_resp_err == `CHI_RESPERR_EXOKAY) &&
                                    !timeout_complete;
    assign cpu_rdata_comb = fe_resp_fire ? fe_resp_rdata :
                            strex_fail_resp_q ? {DATA_WIDTH{1'b0}} :
                            (exclusive_resp_complete ?
                             {{(DATA_WIDTH-1){1'b0}}, exclusive_success_resp} :
                             (timeout_complete ? {DATA_WIDTH{1'b0}} :
                              (dat_line_valid_unused ? dat_line_cpu_data :
                               dat_data[DATA_WIDTH-1:0])));
    assign cpu_resp_valid_comb = strex_fail_resp_q || normal_cpu_resp_valid ||
                                 fe_resp_fire;
    assign cpu_rdata = cpu_rdata_q;
    assign cpu_resp_valid = cpu_resp_valid_q;
    assign cpu_resp_tag = cpu_resp_tag_q;
    assign cpu_resp_line_valid = (dat_line_valid_unused && dat_txn_match) ||
                                 (fe_resp_fire && fe_resp_line);
    assign cpu_resp_line_data = fe_resp_fire ? fe_resp_line_data :
                                               dat_line_data_unused;
    assign cpu_resp_line_tag = fe_resp_fire ? fe_resp_tag :
                                              txn_cpu_tag_mem[dat_txn_idx];
    assign selected_complete_txn_id = rsp_comp_valid ? rsp_txn_id :
                                      (dat_line_valid_unused ? dat_txn_id :
                                       timeout_txn_id);
    assign selected_complete_valid = rsp_comp_valid ||
                                     dat_line_valid_unused ||
                                     timeout_complete;
    assign selected_complete_clear = dat_line_valid_unused ||
                                     timeout_complete ||
                                     (rsp_comp_valid &&
                                      !selected_complete_is_read_data);
    assign timeout_complete = (FUNCTIONAL_TIMEOUT != 0) && timeout_valid;
    assign watchdog_event = timeout_valid;

    // The transaction table has one completion port. A read line completing
    // on DAT takes it; an RSP Comp arriving in the same cycle would otherwise
    // win the selected_complete mux and leave the read entry allocated until
    // the watchdog reaps it. Hold the RSP flit in its FIFO for that cycle.
    // A pending MakeUnique CompAck also holds the next RSP, so a second
    // MakeUnique Comp cannot overwrite it.
    assign rsp_rx_ready = (!pending_wdat_valid_q || wdat_accept) &&
                          !dat_line_valid_unused && !mu_compack_valid_q;
    assign mu_comp_fire = rsp_comp_complete_valid &&
                          (txn_opcode_mem[selected_complete_txn_idx] ==
                           `CHI_REQ_MK_UNIQUE);
    assign wdat_accept = pending_wdat_valid_q &&
                         dbid_ready_unused &&
                         wdata_ready_unused;
    assign txn_alloc_is_write = (req_opcode == `CHI_REQ_WR_UNIQUE) ||
                                (req_opcode == `CHI_REQ_WR_NO_SNP) ||
                                (req_opcode == `CHI_REQ_WB_FULL) ||
                                (req_opcode == `CHI_REQ_WB_PTL);
    // A DVMOp also gets a DBIDResp and sends its payload as write data.
    assign txn_alloc_is_dvm = (req_opcode == `CHI_REQ_DVM_OP);
    assign txn_alloc_idx = txn_alloc_id[TXN_IDX_W-1:0];
    assign rsp_txn_idx = rsp_txn_id[TXN_IDX_W-1:0];
    assign dat_txn_idx = dat_txn_id[TXN_IDX_W-1:0];
    assign tx_req_link_accept_blocked = tx_req_fire_unused;
    assign tx_req_link_in_valid =
        !tx_req_link_accept_blocked &&
        (retry_reissue_valid_r || req_engine_valid);
    assign tx_req_link_in_flit = retry_reissue_valid_r ?
                                 retry_reissue_flit : req_engine_flit;
    assign req_engine_ready = tx_req_link_in_ready &&
                              !retry_reissue_valid_r &&
                              !tx_req_link_accept_blocked;
    assign retry_reissue_fire = retry_reissue_valid_r &&
                                tx_req_link_in_ready &&
                                !tx_req_link_accept_blocked;
    // Only read fills allocate. Writes that reach the fabric never leave a
    // copy behind (the front end has already invalidated or written back
    // the local line), and a store that hits an owned line is merged by the
    // cache itself.
    assign cache_read_fill_update = dat_line_valid_unused && dat_txn_match;
    // The fill state comes from the CompData Resp, not from the opcode.
    assign cache_read_fill_uq = (dat_resp_unused == `CHI_COMPDATA_RESP_UC);
    assign cache_update_valid = cache_read_fill_update;
    assign cache_update_addr = txn_addr_mem[dat_txn_idx];
    assign cache_update_data = dat_line_data_unused;
    assign cache_update_state =
        (dat_resp_unused == `CHI_COMPDATA_RESP_UC)    ? `CHI_STATE_UC :
        (dat_resp_unused == `CHI_COMPDATA_RESP_UD_PD) ? `CHI_STATE_UD :
        (dat_resp_unused == `CHI_COMPDATA_RESP_SD_PD) ? `CHI_STATE_SD :
                                                        `CHI_STATE_SC;
    assign tx_dat_link_valid = snoop_dat_valid || wdat_valid;
    assign tx_dat_link_flit = snoop_dat_valid ? snoop_dat_flit : wdat_flit;
    assign snoop_dat_ready = tx_dat_link_ready;
    assign wdat_engine_ready = tx_dat_link_ready && !snoop_dat_valid;
    assign tx_rsp_link_valid = snoop_rsp_valid || compack_valid_q ||
                               mu_compack_valid_q || fe_compack_valid;
    assign tx_rsp_link_flit = snoop_rsp_valid ? snoop_rsp_flit :
                              compack_valid_q ? compack_rsp_flit :
                              mu_compack_valid_q ? mu_compack_flit :
                                                   fe_compack_flit;
    assign snoop_rsp_ready = tx_rsp_link_ready;
    assign compack_rsp_ready = tx_rsp_link_ready && !snoop_rsp_valid;
    assign mu_compack_ready = tx_rsp_link_ready && !snoop_rsp_valid &&
                              !compack_valid_q;
    assign fe_compack_ready = tx_rsp_link_ready && !snoop_rsp_valid &&
                              !compack_valid_q && !mu_compack_valid_q;
    assign rx_snp_opcode = rx_snp_flit[SNP_OPCODE_LSB +: `CHI_SNP_OPCODE_W];
    assign strex_commit = txn_alloc_valid && !cache_evict_valid &&
                          cpu_req_is_strex && strex_pass;
    assign ldrex_complete = dat_line_valid_unused &&
                            dat_txn_match &&
                            txn_ldrex_mem[dat_txn_idx] &&
                            (dat_resp_err == `CHI_RESPERR_OK);
    assign exclusive_snoop_clear = cache_snoop_commit &&
                                   ((cache_snoop_opcode == `CHI_SNP_UNIQUE) ||
                                    (cache_snoop_opcode == `CHI_SNP_INVALID));
    assign exclusive_local_write_clear = (txn_alloc_valid &&
                                          !cache_evict_valid &&
                                          txn_alloc_is_write &&
                                          !cpu_req_is_strex) ||
                                         fe_local_store;
    // A DVM operation clears the reservations of every RN: the snooped ones
    // on SnpDVMOp, the requester when it issues the DVMOp (the MN does not
    // snoop it).
    assign dvm_reservation_clear = (rx_snp_lcrdv &&
                                    (rx_snp_opcode == `CHI_SNP_DVM_OP)) ||
                                   (txn_alloc_valid && txn_alloc_is_dvm);
    assign rn_perf_events[0]  = cpu_req_valid && cpu_req_ready;
    assign rn_perf_events[1]  = req_engine_valid && !req_engine_ready;
    assign rn_perf_events[2]  = tx_rsp_link_valid && !tx_rsp_link_ready;
    assign rn_perf_events[3]  = tx_dat_link_valid && !tx_dat_link_ready;
    assign rn_perf_events[4]  = timeout_valid;
    assign rn_perf_events[5]  = strex_fail_fire;
    assign rn_perf_events[6]  = strex_commit;
    assign rn_perf_events[7]  = ldrex_set_pulse_unused;
    assign rn_perf_events[8]  = reservation_clear_pulse_unused;
    assign rn_perf_events[9]  = cache_snoop_hit;
    assign rn_perf_events[10] = cache_snoop_dirty;
    assign rn_perf_events[11] = cache_snoop_parity_error;
    assign rn_perf_events[12] = cache_evict_valid && !cache_evict_ready;
    assign rn_perf_events[13] = rx_snp_valid && !rx_snp_lcrdv;
    assign rn_perf_events[14] = dat_line_valid_unused;
    assign rn_perf_events[15] = rsp_comp_valid;
    assign perf_counts = rn_perf_counts_unused;
    assign cache_parity_error_event = cache_snoop_parity_error;

    always @(*) begin
        retry_reissue_valid_r = 1'b0;
        retry_reissue_idx_r = {TXN_IDX_W{1'b0}};
        retry_reissue_flit = {REQ_W{1'b0}};
        for (retry_scan_i = 0; retry_scan_i < TXN_TBL_SIZE;
             retry_scan_i = retry_scan_i + 1) begin
            if (!retry_reissue_valid_r &&
                retry_ack_mem[retry_scan_i] &&
                retry_grant_mem[retry_scan_i]) begin
                retry_reissue_valid_r = 1'b1;
                retry_reissue_idx_r = retry_scan_i[TXN_IDX_W-1:0];
            end
        end
        if (retry_reissue_valid_r) begin
            retry_reissue_flit = txn_req_flit_mem[retry_reissue_idx_r];
            retry_reissue_flit[REQ_ALLOW_RETRY_LSB] = 1'b0;
            retry_reissue_flit[REQ_PCRD_TYPE_LSB +: `CHI_REQ_PCRD_TYPE_W] =
                retry_pcrd_type_mem[retry_reissue_idx_r];
        end
    end

    always @(*) begin
        compack_rsp_flit = {RSP_W{1'b0}};
        compack_rsp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        compack_rsp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_OK;
        compack_rsp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        compack_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_COMP_ACK;
        compack_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = compack_txn_q;
        compack_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = node_id_wire;
        compack_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = compack_tgt_q;
        compack_rsp_flit[RSP_QOS_LSB +: QOS_W]     = {QOS_W{1'b0}};

        mu_compack_flit = compack_rsp_flit;
        mu_compack_flit[RSP_TXN_LSB +: TXN_ID_W]  = mu_compack_txn_q;
        mu_compack_flit[RSP_TGT_LSB +: NODE_ID_W] = mu_compack_tgt_q;

        // CompAck of a CleanUnique: TxnID is the DBID of its Comp.
        fe_compack_flit = {RSP_W{1'b0}};
        fe_compack_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_OK;
        fe_compack_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_COMP_ACK;
        fe_compack_flit[RSP_TXN_LSB +: TXN_ID_W]  = fe_compack_txn;
        fe_compack_flit[RSP_SRC_LSB +: NODE_ID_W] = node_id_wire;
        fe_compack_flit[RSP_TGT_LSB +: NODE_ID_W] = fe_compack_tgt;
    end

    generate
        if (DATA_WIDTH <= LINE_WIDTH) begin : gen_rdata_select
            assign dat_line_cpu_data =
                dat_line_data_unused[dat_line_beat_idx*DATA_WIDTH +: DATA_WIDTH];
        end else begin : gen_rdata_extend
            assign dat_line_cpu_data = {{(DATA_WIDTH-LINE_WIDTH){1'b0}},
                                        dat_line_data_unused};
        end
    endgenerate

    assign cpu_wdata_line = cpu_wdata_line_r;
    assign cpu_wstrb_line = cpu_wstrb_line_r;

    always @(*) begin
        cpu_wdata_line_r = {LINE_WIDTH{1'b0}};
        cpu_wstrb_line_r = {LINE_BYTES{1'b0}};

        if ((cpu_req_op == `CHI_CPU_OP_DVM_OP) ||
            (cpu_req_op == `CHI_CPU_OP_DVM_SYNC)) begin
            // DVM payload Data[63:0]: the first 8 bytes of the write line,
            // or the CPU word. A Sync carries no payload (Table B8.21).
            if (cpu_req_op == `CHI_CPU_OP_DVM_SYNC)
                cpu_wdata_line_r[63:0] = 64'd0;
            else if ((cpu_req_size == 3'd6) && (|cpu_wstrb_line_in))
                cpu_wdata_line_r[63:0] = cpu_wdata_line_in[63:0];
            else if (DATA_WIDTH >= 64)
                cpu_wdata_line_r[63:0] = cpu_wdata[63:0];
            else
                cpu_wdata_line_r[DATA_WIDTH-1:0] = cpu_wdata;
            cpu_wstrb_line_r[7:0] = 8'hFF;
        end else if ((cpu_req_size == 3'd6) && (|cpu_wstrb_line_in)) begin
            cpu_wdata_line_r = cpu_wdata_line_in;
            cpu_wstrb_line_r = cpu_wstrb_line_in;
        end else if (DATA_WIDTH <= LINE_WIDTH) begin
            case (cpu_req_size)
                3'd0: begin
                    cpu_wdata_line_r[(cpu_line_beat_idx*DATA_WIDTH) +
                                     (cpu_byte_idx*8) +: 8] =
                        cpu_wdata[7:0];
                    cpu_wstrb_line_r[cpu_line_beat_idx*BE_W + cpu_byte_idx] =
                        1'b1;
                end
                3'd1: begin
                    cpu_wdata_line_r[(cpu_line_beat_idx*DATA_WIDTH) +
                                     ({cpu_byte_idx[1], 1'b0}*8) +: 16] =
                        cpu_wdata[15:0];
                    cpu_wstrb_line_r[cpu_line_beat_idx*BE_W + {cpu_byte_idx[1], 1'b0} +: 2] =
                        2'b11;
                end
                default: begin
                    cpu_wdata_line_r[cpu_line_beat_idx*DATA_WIDTH +: DATA_WIDTH] =
                        cpu_wdata;
                    cpu_wstrb_line_r[cpu_line_beat_idx*BE_W +: BE_W] =
                        {BE_W{1'b1}};
                end
            endcase
        end else begin
            cpu_wdata_line_r = cpu_wdata[LINE_WIDTH-1:0];
            cpu_wstrb_line_r = {LINE_BYTES{1'b1}};
        end
    end

    chi_addr_decoder #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_TGT(4),
        .TGT_ID_W(NODE_ID_W)
    ) u_addr_decoder (
        .valid(req_engine_input_valid),
        .addr(req_engine_input_addr),
        .cfg_region_valid(1'b0),
        .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
        .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
        .cfg_snf_base({ADDR_WIDTH{1'b0}}),
        .cfg_snf_end({ADDR_WIDTH{1'b0}}),
        .cfg_mn_base({ADDR_WIDTH{1'b0}}),
        .cfg_mn_end({ADDR_WIDTH{1'b0}}),
        .tgt_id(target_id),
        .tgt_onehot(route_onehot_unused),
        .decode_error(route_error_unused)
    );

    chi_rn_txn_tracker #(
        .TXN_ID_W(TXN_ID_W),
        .TXN_TBL_SIZE(TXN_TBL_SIZE),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .FUNCTIONAL_TIMEOUT(FUNCTIONAL_TIMEOUT)
    ) u_txn_tracker (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .alloc_valid(txn_alloc_valid),
        .alloc_ready(txn_alloc_ready),
        .alloc_txn_id(txn_alloc_id),
        .dbid_update_valid(rsp_dbid_valid),
        .dbid_update_txn_id(rsp_txn_id),
        .dbid_match_valid(rsp_dbid_match_valid),
        .complete_valid(selected_complete_valid),
        .complete_clear(selected_complete_clear),
        .complete_txn_id(selected_complete_txn_id),
        .complete_match_valid(selected_complete_match_valid),
        .touch_valid(rsp_retry_ack_valid || rsp_pcrd_grant_valid),
        .touch_txn_id(rsp_txn_id),
        .touch_match_valid(rsp_retry_touch_match_valid),
        .lookup_valid(dat_data_valid),
        .lookup_txn_id(dat_txn_id),
        .lookup_match(dat_txn_match),
        .timeout_valid(timeout_valid),
        .timeout_txn_id(timeout_txn_id),
        .outstanding_count(outstanding_count),
        .table_full(table_full_unused),
        .debug_entry_valid(txn_debug_entry_valid_unused),
        .debug_entry_txn_id_flat(txn_debug_entry_txn_id_flat_unused)
    );

    generate
        if (ENABLE_PERF != 0) begin : gen_rn_perf_on
            chi_perf_counter #(
                .NUM_EVENTS(16),
                .COUNTER_W(32)
            ) u_rn_perf_counter (
                .clk(clk),
                .rstn(rstn),
                .clear(1'b0),
                .enable(1'b1),
                .event_inc(rn_perf_events),
                .count_flat(rn_perf_counts_unused)
            );
        end else begin : gen_rn_perf_off
            assign rn_perf_counts_unused = {16*32{1'b0}};
        end
    endgenerate

    chi_rn_req_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .STREX_CLEAN_UNIQUE(USE_EXTERNAL_L1_SNOOP == 0)
    ) u_req_engine (
        .cpu_req_valid(req_engine_input_valid),
        .cpu_req_ready(req_engine_cpu_ready),
        .cpu_req_addr(req_engine_input_addr),
        .cpu_req_op(req_engine_input_op),
        .cpu_req_size(req_engine_input_size),
        .qos_value(qos_value),
        .node_id(node_id_wire),
        .target_id(target_id),
        .txn_alloc_valid(txn_alloc_valid),
        .txn_alloc_ready(txn_alloc_ready),
        .txn_alloc_id(txn_alloc_id),
        .tx_req_valid(req_engine_valid),
        .tx_req_ready(req_engine_ready),
        .tx_req_flit(req_engine_flit),
        .tx_req_opcode(req_opcode)
    );

    chi_exclusive_monitor #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_LSB(6)
    ) u_exclusive_monitor (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .ldrex_complete(ldrex_complete),
        .ldrex_addr(txn_addr_mem[dat_txn_idx]),
        .strex_check_valid(core_req_valid && cpu_req_is_strex),
        .strex_addr(core_req_addr),
        .strex_pass(strex_pass),
        .strex_fail(strex_fail),
        .strex_commit(strex_commit),
        .local_write_valid(exclusive_local_write_clear),
        .local_write_addr(fe_local_store ? core_req_addr :
                                           req_engine_input_addr),
        .clear_addr_valid(exclusive_snoop_clear),
        .clear_addr(cache_snoop_addr),
        .clear_all(dvm_reservation_clear || fe_strex_clear),
        .reservation_valid(reservation_valid),
        .reservation_match(reservation_match_unused),
        .reservation_addr(reservation_addr_unused),
        .ldrex_set_pulse(ldrex_set_pulse_unused),
        .reservation_clear_pulse(reservation_clear_pulse_unused)
    );

    chi_link_layer #(
        .FLIT_W(REQ_W),
        .INIT_CREDIT(INIT_CRD)
    ) u_tx_req_link (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .tx_in_valid(tx_req_link_in_valid),
        .tx_in_ready(tx_req_link_in_ready),
        .tx_in_flit(tx_req_link_in_flit),
        .tx_out_valid(tx_req_valid),
        .tx_out_flit(tx_req_flit),
        .tx_out_lcrdv(tx_req_lcrdv),
        .rx_in_valid(1'b0),
        .rx_in_flit({REQ_W{1'b0}}),
        .rx_in_lcrdv(),
        .rx_out_valid(),
        .rx_out_ready(1'b1),
        .rx_out_flit(),
        .credit_count(tx_req_credit_unused),
        .tx_fire_pulse(tx_req_fire_unused),
        .tx_credit_return_pulse(tx_req_return_unused),
        .tx_credit_stall(tx_req_stall_unused)
    );

    chi_rn_rsp_rx #(
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W)
    ) u_rsp_rx (
        .clk(clk),
        .rstn(rstn),
        .busy(rsp_rx_busy),
        .rx_rsp_valid(rx_rsp_valid),
        .rx_rsp_flit(rx_rsp_flit),
        .rx_rsp_ready(rx_rsp_ready),
        .rx_rsp_lcrdv(rx_rsp_lcrdv),
        .rsp_ready(rsp_rx_ready),
        .comp_valid(rsp_comp_valid),
        .dbid_valid(rsp_dbid_valid),
        .retry_ack_valid(rsp_retry_ack_valid),
        .pcrd_grant_valid(rsp_pcrd_grant_valid),
        .rsp_txn_id(rsp_txn_id),
        .rsp_dbid(rsp_dbid),
        .rsp_pcrd_type(rsp_pcrd_type),
        .rsp_src_id(rsp_src_id),
        .rsp_resp_err(rsp_resp_err)
    );

    chi_rn_dat_rx #(
        .DATA_WIDTH(DAT_DATA_W),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES)
    ) u_dat_rx (
        .clk(clk),
        .rstn(rstn),
        .busy(dat_rx_busy),
        .rx_dat_valid(rx_dat_valid),
        .rx_dat_flit(rx_dat_flit),
        .rx_dat_ready(rx_dat_ready),
        .rx_dat_lcrdv(rx_dat_lcrdv),
        .data_valid(dat_data_valid),
        .data(dat_data),
        .txn_id(dat_txn_id),
        .src_id(dat_src_id),
        .home_nid(dat_home_nid),
        .resp_err(dat_resp_err),
        .resp(dat_resp_unused),
        .dbid(dat_dbid),
        .line_valid(dat_line_valid_unused),
        .line_data(dat_line_data_unused)
    );

    generate
        if (USE_EXTERNAL_L1_SNOOP != 0) begin : gen_external_l1_no_rn_cache
            assign cache_evict_valid = 1'b0;
            assign cache_evict_addr = {ADDR_WIDTH{1'b0}};
            assign cache_evict_data = {LINE_WIDTH{1'b0}};
            assign cache_evict_state_unused = `CHI_STATE_I;
            assign cache_snoop_result_valid = 1'b0;
            assign cache_snoop_hit = 1'b0;
            assign cache_snoop_dirty = 1'b0;
            assign cache_snoop_state = `CHI_STATE_I;
            assign cache_snoop_data = {LINE_WIDTH{1'b0}};
            assign cache_snoop_send_data = 1'b0;
            assign cache_snoop_parity_error = 1'b0;
            assign cache_busy = 1'b0;

            // No local cache: the CPU port is the transaction port.
            assign core_req_valid = cpu_req_valid;
            assign core_req_addr = cpu_req_addr;
            assign core_req_op = cpu_req_op;
            assign core_req_size = cpu_req_size;
            assign core_req_qos = cpu_req_qos;
            assign core_req_tag = cpu_req_tag;
            assign core_wline = cpu_wdata_line;
            assign core_wstrb = cpu_wstrb_line;
            assign cpu_req_ready = core_req_ready;
            assign fe_resp_fire = 1'b0;
            assign fe_resp_line = 1'b0;
            assign fe_resp_rdata = {DATA_WIDTH{1'b0}};
            assign fe_resp_tag = {CPU_TAG_W{1'b0}};
            assign fe_resp_line_data = {LINE_WIDTH{1'b0}};
            assign fe_local_store = 1'b0;
            assign fe_busy = 1'b0;
            assign fe_strex_clear = 1'b0;
            assign fe_compack_valid = 1'b0;
            assign fe_compack_txn = {TXN_ID_W{1'b0}};
            assign fe_compack_tgt = {NODE_ID_W{1'b0}};
            assign cache_cpu_excl_commit = 1'b0;
            assign cache_cpu_valid = 1'b0;
            assign cache_cpu_addr = {ADDR_WIDTH{1'b0}};
            assign cache_cpu_kind = 3'd0;
            assign cache_cpu_wdata = {LINE_WIDTH{1'b0}};
            assign cache_cpu_wstrb = {LINE_BYTES{1'b0}};
            assign cache_cpu_ready = 1'b0;
            assign cache_cpu_done = 1'b0;
            assign cache_cpu_hit = 1'b0;
            assign cache_cpu_state = `CHI_STATE_I;
            assign cache_cpu_line = {LINE_WIDTH{1'b0}};
            assign cache_cpu_local = 1'b0;
            assign cache_cpu_flushed = 1'b0;
            assign cache_victim_valid = 2'b00;
            assign cache_victim_addr_flat = {2*ADDR_WIDTH{1'b0}};
            assign cache_victim_data_flat = {2*LINE_WIDTH{1'b0}};
        end else begin : gen_internal_rn_cache
            // Front end. One CPU request at a time:
            //   IDLE   accept the request.
            //   HAZARD wait until no transaction or queued victim touches
            //          the same line, so the cache and fabric agree on it.
            //   CACHE  one atomic cache access (see chi_rn_cache CPU_*):
            //          serve a hit locally, merge a store into an owned
            //          line, or invalidate / write back the local copy.
            //   WAIT_WB a written-back line must reach memory (its
            //          WriteBackFull completes) before the request goes on.
            //   ISSUE  hand the request to the transaction logic. A CPU
            //          WriteBackFull that was not merged locally is sent as
            //          WriteUnique: only the owner may copy a line back.
            //   RESP   return a locally served request to the CPU.
            localparam FE_IDLE      = 3'd0;
            localparam FE_HAZARD    = 3'd1;
            localparam FE_CACHE     = 3'd2;
            localparam FE_CACHE_WAIT = 3'd3;
            localparam FE_WAIT_WB   = 3'd4;
            localparam FE_ISSUE     = 3'd5;
            localparam FE_RESP      = 3'd6;
            // STREX sent as CleanUnique(Excl): wait for its Comp.
            localparam FE_WAIT_EXCL = 3'd7;

            reg [2:0]            fe_state_q;
            reg [ADDR_WIDTH-1:0] fe_addr_q;
            reg [3:0]            fe_op_q;
            reg [2:0]            fe_size_q;
            reg [QOS_W-1:0]      fe_qos_q;
            reg [CPU_TAG_W-1:0]  fe_tag_q;
            reg [LINE_WIDTH-1:0] fe_wline_q;
            reg [LINE_BYTES-1:0] fe_wstrb_q;
            reg                  fe_local_q;
            reg [LINE_WIDTH-1:0] fe_line_q;
            reg [2:0]            fe_kind_r;
            reg                  fe_strex_ok_q;
            reg                  fe_commit_q;
            reg                  fe_strex_clear_q;
            reg                  fe_compack_valid_q;
            reg [TXN_ID_W-1:0]   fe_compack_txn_q;
            reg [NODE_ID_W-1:0]  fe_compack_tgt_q;
            reg                  fe_line_busy_r;
            integer              fe_scan_i;

            wire fe_is_read = (fe_op_q == `CHI_CPU_OP_RD_SHARED) ||
                              (fe_op_q == `CHI_CPU_OP_RD_UNIQUE);
            wire fe_is_strex = (fe_op_q == `CHI_CPU_OP_STREX);
            wire fe_strex_mon_ok =
                reservation_valid &&
                (reservation_addr_unused[ADDR_WIDTH-1:6] ==
                 fe_addr_q[ADDR_WIDTH-1:6]);
            wire fe_evict_txn_busy =
                |(txn_debug_entry_valid_unused & txn_cache_evict_mem);
            wire fe_resp_slot_free =
                !(dat_line_valid_unused && dat_txn_match) &&
                !normal_cpu_resp_valid && !strex_fail_resp_q;

            always @(*) begin
                case (fe_op_q)
                    `CHI_CPU_OP_RD_SHARED: fe_kind_r = 3'd0; // READ
                    `CHI_CPU_OP_RD_UNIQUE: fe_kind_r = 3'd1; // READ_UQ
                    `CHI_CPU_OP_LDREX:     fe_kind_r = 3'd2; // FLUSH
                    `CHI_CPU_OP_STREX:     fe_kind_r = 3'd3; // STREX
                    `CHI_CPU_OP_WR_UNIQUE: fe_kind_r = 3'd4; // STORE
                    `CHI_CPU_OP_WB_FULL:   fe_kind_r = 3'd5; // STORE_WB
                    `CHI_CPU_OP_EVICT:     fe_kind_r = 3'd6; // EVICT
                    default:               fe_kind_r = 3'd7; // DROP
                endcase

                fe_line_busy_r = 1'b0;
                for (fe_scan_i = 0; fe_scan_i < TXN_TBL_SIZE;
                     fe_scan_i = fe_scan_i + 1) begin
                    if (txn_debug_entry_valid_unused[fe_scan_i] &&
                        (txn_addr_mem[fe_scan_i][ADDR_WIDTH-1:6] ==
                         fe_addr_q[ADDR_WIDTH-1:6]))
                        fe_line_busy_r = 1'b1;
                end
            end

            assign cpu_req_ready = (fe_state_q == FE_IDLE) &&
                                   !fe_compack_valid_q;

            assign core_req_valid = (fe_state_q == FE_ISSUE);
            assign core_req_addr = fe_addr_q;
            assign core_req_op = (fe_op_q == `CHI_CPU_OP_WB_FULL) ?
                                 `CHI_CPU_OP_WR_UNIQUE : fe_op_q;
            assign core_req_size = fe_size_q;
            assign core_req_qos = fe_qos_q;
            assign core_req_tag = fe_tag_q;
            assign core_wline = fe_wline_q;
            assign core_wstrb = fe_wstrb_q;

            assign cache_cpu_valid = (fe_state_q == FE_CACHE);
            assign cache_cpu_addr = fe_addr_q;
            assign cache_cpu_kind = fe_commit_q ? 3'd4 : fe_kind_r; // STORE
            assign cache_cpu_excl_commit = fe_commit_q;
            assign cache_cpu_wdata = fe_wline_q;
            assign cache_cpu_wstrb = fe_wstrb_q;

            assign fe_resp_fire = (fe_state_q == FE_RESP) && fe_resp_slot_free;
            assign fe_resp_line = fe_is_read;
            assign fe_resp_rdata = fe_is_read ?
                fe_line_q[fe_addr_q[5:2]*DATA_WIDTH +: DATA_WIDTH] :
                {{(DATA_WIDTH-1){1'b0}}, fe_is_strex && fe_strex_ok_q};
            assign fe_strex_clear = fe_strex_clear_q;
            assign fe_compack_valid = fe_compack_valid_q;
            assign fe_compack_txn = fe_compack_txn_q;
            assign fe_compack_tgt = fe_compack_tgt_q;
            assign fe_resp_tag = fe_tag_q;
            assign fe_resp_line_data = fe_line_q;
            // A store merged into the local line clears a reservation on it,
            // like a store that goes to the fabric.
            assign fe_local_store = cache_cpu_done && cache_cpu_local &&
                                    ((fe_op_q == `CHI_CPU_OP_WR_UNIQUE) ||
                                     (fe_op_q == `CHI_CPU_OP_WB_FULL));
            assign fe_busy = (fe_state_q != FE_IDLE) || fe_compack_valid_q;

            always @(posedge clk or negedge rstn) begin
                if (!rstn) begin
                    fe_state_q <= FE_IDLE;
                    fe_addr_q <= {ADDR_WIDTH{1'b0}};
                    fe_op_q <= 4'd0;
                    fe_size_q <= 3'd0;
                    fe_qos_q <= {QOS_W{1'b0}};
                    fe_tag_q <= {CPU_TAG_W{1'b0}};
                    fe_wline_q <= {LINE_WIDTH{1'b0}};
                    fe_wstrb_q <= {LINE_BYTES{1'b0}};
                    fe_local_q <= 1'b0;
                    fe_line_q <= {LINE_WIDTH{1'b0}};
                    fe_strex_ok_q <= 1'b0;
                    fe_commit_q <= 1'b0;
                    fe_strex_clear_q <= 1'b0;
                    fe_compack_valid_q <= 1'b0;
                    fe_compack_txn_q <= {TXN_ID_W{1'b0}};
                    fe_compack_tgt_q <= {NODE_ID_W{1'b0}};
                end else begin
                    fe_strex_clear_q <= 1'b0;
                    if (fe_compack_valid_q && fe_compack_ready)
                        fe_compack_valid_q <= 1'b0;
                    case (fe_state_q)
                        FE_IDLE: begin
                            if (cpu_req_valid) begin
                                fe_addr_q <= cpu_req_addr;
                                fe_op_q <= cpu_req_op;
                                fe_size_q <= cpu_req_size;
                                fe_qos_q <= cpu_req_qos;
                                fe_tag_q <= cpu_req_tag;
                                fe_wline_q <= cpu_wdata_line;
                                fe_wstrb_q <= cpu_wstrb_line;
                                fe_local_q <= 1'b0;
                                fe_state_q <=
                                    ((cpu_req_op == `CHI_CPU_OP_DVM_OP) ||
                                     (cpu_req_op == `CHI_CPU_OP_DVM_SYNC)) ?
                                    FE_ISSUE : FE_HAZARD;
                            end
                        end
                        FE_HAZARD: begin
                            if (!fe_line_busy_r && !cache_evict_valid) begin
                                // A STREX without a reservation on its line
                                // fails here, before touching the cache.
                                if (fe_is_strex && !fe_strex_mon_ok) begin
                                    fe_strex_ok_q <= 1'b0;
                                    fe_strex_clear_q <= 1'b1;
                                    fe_state_q <= FE_RESP;
                                end else begin
                                    fe_state_q <= FE_CACHE;
                                end
                            end
                        end
                        FE_CACHE: begin
                            if (cache_cpu_ready)
                                fe_state_q <= FE_CACHE_WAIT;
                        end
                        FE_CACHE_WAIT: begin
                            if (cache_cpu_done && fe_commit_q) begin
                                // CleanUnique(Excl) granted: the store is in
                                // if the line was still here.
                                fe_commit_q <= 1'b0;
                                fe_strex_ok_q <= cache_cpu_local;
                                fe_strex_clear_q <= 1'b1;
                                fe_compack_valid_q <= 1'b1;
                                fe_state_q <= FE_RESP;
                            end else if (cache_cpu_done && fe_is_strex) begin
                                if (cache_cpu_local || !cache_cpu_hit) begin
                                    // Owned: stored here. Gone: fails.
                                    fe_strex_ok_q <= cache_cpu_local;
                                    fe_strex_clear_q <= 1'b1;
                                    fe_state_q <= FE_RESP;
                                end else begin
                                    fe_state_q <= FE_ISSUE;
                                end
                            end else if (cache_cpu_done) begin
                                fe_local_q <= cache_cpu_local;
                                fe_line_q <= cache_cpu_line;
                                if (cache_cpu_flushed)
                                    fe_state_q <= FE_WAIT_WB;
                                else if (cache_cpu_local)
                                    fe_state_q <= FE_RESP;
                                else
                                    fe_state_q <= FE_ISSUE;
                            end
                        end
                        FE_WAIT_WB: begin
                            if (!cache_evict_valid && !fe_evict_txn_busy)
                                fe_state_q <= fe_local_q ? FE_RESP : FE_ISSUE;
                        end
                        FE_ISSUE: begin
                            // A STREX whose reservation was lost meanwhile
                            // is answered by strex_fail instead.
                            if (core_req_ready)
                                fe_state_q <= (fe_is_strex && !strex_fail) ?
                                              FE_WAIT_EXCL : FE_IDLE;
                        end
                        FE_WAIT_EXCL: begin
                            if (strex_cu_done) begin
                                fe_compack_txn_q <= rsp_dbid;
                                fe_compack_tgt_q <= rsp_src_id;
                                if (strex_cu_pass) begin
                                    fe_commit_q <= 1'b1;
                                    fe_state_q <= FE_CACHE;
                                end else begin
                                    fe_strex_ok_q <= 1'b0;
                                    fe_strex_clear_q <= 1'b1;
                                    fe_compack_valid_q <= !timeout_complete;
                                    fe_state_q <= FE_RESP;
                                end
                            end
                        end
                        FE_RESP: begin
                            if (fe_resp_slot_free)
                                fe_state_q <= FE_IDLE;
                        end
                        default: fe_state_q <= FE_IDLE;
                    endcase
                end
            end

            chi_rn_cache #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .LINE_BYTES(LINE_BYTES),
                .LINES(RN_CACHE_LINES),
                .WAYS(4)
            ) u_rn_cache (
                .clk(clk),
                .rstn(rstn),
                .busy(cache_busy),
                .clear(1'b0),
                .line_update_valid(cache_update_valid),
                .line_update_addr(cache_update_addr),
                .line_update_data(cache_update_data),
                .line_update_state(cache_update_state),
                .evict_valid(cache_evict_valid),
                .evict_ready(cache_evict_ready),
                .evict_addr(cache_evict_addr),
                .evict_data(cache_evict_data),
                .evict_state(cache_evict_state_unused),
                .snoop_valid(cache_snoop_valid),
                .snoop_addr(cache_snoop_addr),
                .snoop_opcode(cache_snoop_opcode),
                .snoop_result_valid(cache_snoop_result_valid),
                .snoop_hit(cache_snoop_hit),
                .snoop_dirty(cache_snoop_dirty),
                .snoop_state(cache_snoop_state),
                .snoop_data(cache_snoop_data),
                .snoop_send_data(cache_snoop_send_data),
                .snoop_parity_error(cache_snoop_parity_error),
                .snoop_commit(cache_snoop_commit),
                .cpu_valid(cache_cpu_valid),
                .cpu_ready(cache_cpu_ready),
                .cpu_addr(cache_cpu_addr),
                .cpu_kind(cache_cpu_kind),
                .cpu_wdata(cache_cpu_wdata),
                .cpu_wstrb(cache_cpu_wstrb),
                .cpu_excl_commit(cache_cpu_excl_commit),
                .cpu_done(cache_cpu_done),
                .cpu_hit(cache_cpu_hit),
                .cpu_state(cache_cpu_state),
                .cpu_line(cache_cpu_line),
                .cpu_local(cache_cpu_local),
                .cpu_flushed(cache_cpu_flushed),
                .victim_valid(cache_victim_valid),
                .victim_addr_flat(cache_victim_addr_flat),
                .victim_data_flat(cache_victim_data_flat)
            );
        end
    endgenerate

    // A victim is looked up only when the cache itself misses. After
    // DBIDResp the HN is already serving this WriteBack, so no snoop for the
    // line can still be outstanding; until then the data is in
    // wdata_line_mem. Before the request is issued it is in the cache's
    // victim queue.
    always @(*) begin
        victim_hit_r = 1'b0;
        victim_data_r = {LINE_WIDTH{1'b0}};
        if (cache_victim_valid[0] &&
            (cache_victim_addr_flat[0*ADDR_WIDTH + 6 +: ADDR_WIDTH-6] ==
             cache_snoop_addr[ADDR_WIDTH-1:6])) begin
            victim_hit_r = 1'b1;
            victim_data_r = cache_victim_data_flat[0*LINE_WIDTH +: LINE_WIDTH];
        end
        if (cache_victim_valid[1] &&
            (cache_victim_addr_flat[1*ADDR_WIDTH + 6 +: ADDR_WIDTH-6] ==
             cache_snoop_addr[ADDR_WIDTH-1:6])) begin
            victim_hit_r = 1'b1;
            victim_data_r = cache_victim_data_flat[1*LINE_WIDTH +: LINE_WIDTH];
        end
        for (victim_scan_i = 0; victim_scan_i < TXN_TBL_SIZE;
             victim_scan_i = victim_scan_i + 1) begin
            if (txn_debug_entry_valid_unused[victim_scan_i] &&
                txn_cache_evict_mem[victim_scan_i] &&
                wdata_valid_mem[victim_scan_i] &&
                (txn_addr_mem[victim_scan_i][ADDR_WIDTH-1:6] ==
                 cache_snoop_addr[ADDR_WIDTH-1:6])) begin
                victim_hit_r = 1'b1;
                victim_data_r = wdata_line_mem[victim_scan_i];
            end
        end
    end

    assign snp_sel_hit = cache_snoop_hit ||
                         (cache_snoop_result_valid && victim_hit_r);
    assign snp_sel_dirty = cache_snoop_hit ? cache_snoop_dirty : snp_sel_hit;
    assign snp_sel_state = cache_snoop_hit ? cache_snoop_state :
                           (snp_sel_hit ? `CHI_STATE_UD : `CHI_STATE_I);
    assign snp_sel_data = cache_snoop_hit ? cache_snoop_data : victim_data_r;
    assign snp_sel_send_data =
        cache_snoop_hit ? cache_snoop_send_data :
        (snp_sel_hit &&
         ((cache_snoop_opcode == `CHI_SNP_SHARED) ||
          (cache_snoop_opcode == `CHI_SNP_UNIQUE) ||
          (cache_snoop_opcode == `CHI_SNP_INVALID)));

    chi_rn_snoop_handler #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DAT_DATA_W),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES),
        .USE_EXTERNAL_L1_SNOOP(USE_EXTERNAL_L1_SNOOP)
    ) u_snoop_handler (
        .clk(clk),
        .rstn(rstn),
        .busy(snoop_busy),
        .rx_snp_valid(rx_snp_valid),
        .rx_snp_flit(rx_snp_flit),
        .rx_snp_ready(rx_snp_ready),
        .rx_snp_lcrdv(rx_snp_lcrdv),
        .node_id(node_id_wire),
        .cache_hit(snp_sel_hit),
        .cache_dirty(snp_sel_dirty),
        .cache_result_valid(cache_snoop_result_valid),
        .cache_state(snp_sel_state),
        .cache_data(snp_sel_data),
        .cache_send_data(snp_sel_send_data),
        .cache_snoop_valid(cache_snoop_valid),
        .cache_snoop_addr(cache_snoop_addr),
        .cache_snoop_opcode(cache_snoop_opcode),
        .cache_snoop_commit(cache_snoop_commit),
        .l1_snoop_valid(l1_snoop_valid),
        .l1_snoop_ready(l1_snoop_ready),
        .l1_snoop_invalidate(l1_snoop_invalidate),
        .l1_snoop_addr(l1_snoop_addr),
        .l1_snoop_result_valid(l1_snoop_result_valid),
        .l1_snoop_hit(l1_snoop_hit),
        .l1_snoop_dirty(l1_snoop_dirty),
        .l1_snoop_data(l1_snoop_data),
        .tx_rsp_valid(snoop_rsp_valid),
        .tx_rsp_ready(snoop_rsp_ready),
        .tx_rsp_flit(snoop_rsp_flit),
        .tx_dat_valid(snoop_dat_valid),
        .tx_dat_ready(snoop_dat_ready),
        .tx_dat_flit(snoop_dat_flit)
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

    chi_rn_wdat_engine #(
        .DATA_WIDTH(DAT_DATA_W),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES)
    ) u_wdat_engine (
        .clk(clk),
        .rstn(rstn),
        .busy(wdat_busy),
        .dbid_valid(pending_wdat_valid_q),
        .dbid_ready(dbid_ready_unused),
        // WriteData uses the DBID it was given as its TxnID.
        .dbid_txn_id(pending_wdat_dbid_q),
        .dbid_value(pending_wdat_dbid_q),
        .dbid_src_id(pending_wdat_src_q),
        .dbid_dvm(pending_wdat_dvm_q),
        .wdata_valid(pending_wdat_valid_q),
        .wdata_ready(wdata_ready_unused),
        .wdata(pending_wdat_data_q),
        .wstrb(pending_wdat_strb_q),
        .node_id(node_id_wire),
        .qos_value(pending_wdat_qos_q),
        .tx_dat_valid(wdat_valid),
        .tx_dat_ready(wdat_engine_ready),
        .tx_dat_flit(wdat_flit)
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

    always @(posedge clk) begin
        if (rstn && txn_alloc_valid) begin
            txn_addr_mem[txn_alloc_idx] <= req_engine_input_addr;
            txn_req_flit_mem[txn_alloc_idx] <= req_engine_flit;
            txn_opcode_mem[txn_alloc_idx] <= req_opcode;
            txn_qos_mem[txn_alloc_idx] <= qos_value;
            txn_cpu_tag_mem[txn_alloc_idx] <= core_req_tag;

            if (txn_alloc_is_write || txn_alloc_is_dvm) begin
                wdata_line_mem[txn_alloc_idx] <= req_engine_wdata_line;
                wstrb_line_mem[txn_alloc_idx] <= req_engine_wstrb_line;
            end
        end

        if (rstn && retry_reissue_fire) begin
            txn_req_flit_mem[retry_reissue_idx_r] <= retry_reissue_flit;
        end

        if (rstn && rsp_dbid_match_valid && wdata_valid_mem[rsp_txn_idx]) begin
            pending_wdat_txn_q  <= rsp_txn_id;
            pending_wdat_dbid_q <= rsp_dbid;
            pending_wdat_src_q  <= rsp_src_id;
            pending_wdat_qos_q  <= txn_qos_mem[rsp_txn_idx];
            pending_wdat_dvm_q  <= (txn_opcode_mem[rsp_txn_idx] == `CHI_REQ_DVM_OP);
            pending_wdat_data_q <= wdata_line_mem[rsp_txn_idx];
            pending_wdat_strb_q <= wstrb_line_mem[rsp_txn_idx];
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wdata_valid_mem      <= {TXN_TBL_SIZE{1'b0}};
            txn_ldrex_mem        <= {TXN_TBL_SIZE{1'b0}};
            txn_strex_mem        <= {TXN_TBL_SIZE{1'b0}};
            txn_cache_evict_mem  <= {TXN_TBL_SIZE{1'b0}};
            retry_ack_mem        <= {TXN_TBL_SIZE{1'b0}};
            retry_grant_mem      <= {TXN_TBL_SIZE{1'b0}};
            pending_wdat_valid_q <= 1'b0;
            compack_valid_q      <= 1'b0;
            compack_txn_q        <= {TXN_ID_W{1'b0}};
            compack_tgt_q        <= {NODE_ID_W{1'b0}};
            mu_compack_valid_q   <= 1'b0;
            mu_compack_txn_q     <= {TXN_ID_W{1'b0}};
            mu_compack_tgt_q     <= {NODE_ID_W{1'b0}};
            strex_fail_resp_q    <= 1'b0;
            strex_fail_tag_q     <= {CPU_TAG_W{1'b0}};
            cpu_resp_valid_q     <= 1'b0;
            cpu_rdata_q          <= {DATA_WIDTH{1'b0}};
            cpu_resp_tag_q       <= {CPU_TAG_W{1'b0}};
            for (retry_reset_i = 0; retry_reset_i < TXN_TBL_SIZE;
                 retry_reset_i = retry_reset_i + 1) begin
                retry_pcrd_type_mem[retry_reset_i] <= `CHI_REQ_PCRD_TYPE_GENERIC;
            end
        end else begin
            strex_fail_resp_q <= strex_fail_fire;
            if (strex_fail_fire)
                strex_fail_tag_q <= core_req_tag;
            cpu_resp_valid_q <= cpu_resp_valid_comb;
            if (cpu_resp_valid_comb) begin
                cpu_rdata_q <= cpu_rdata_comb;
                if (fe_resp_fire)
                    cpu_resp_tag_q <= fe_resp_tag;
                else if (dat_line_valid_unused && dat_txn_match)
                    cpu_resp_tag_q <= txn_cpu_tag_mem[dat_txn_idx];
                else if (selected_complete_match_valid)
                    cpu_resp_tag_q <= txn_cpu_tag_mem[selected_complete_txn_id[TXN_IDX_W-1:0]];
                else
                    cpu_resp_tag_q <= strex_fail_tag_q;
            end

            if (wdat_accept)
                pending_wdat_valid_q <= 1'b0;

            if (compack_valid_q && compack_rsp_ready)
                compack_valid_q <= 1'b0;

            if (mu_compack_valid_q && mu_compack_ready)
                mu_compack_valid_q <= 1'b0;
            if (mu_comp_fire) begin
                mu_compack_valid_q <= 1'b1;
                mu_compack_txn_q   <= rsp_dbid;
                mu_compack_tgt_q   <= rsp_src_id;
            end

            if (dat_line_valid_unused && dat_txn_match) begin
                compack_valid_q <= 1'b1;
                // CompAck carries the DBID of the CompData.
                compack_txn_q   <= dat_dbid;
                compack_tgt_q   <= dat_home_nid;
            end

            if (txn_alloc_valid) begin
                txn_ldrex_mem[txn_alloc_idx] <= !cache_evict_valid && cpu_req_is_ldrex;
                txn_strex_mem[txn_alloc_idx] <= !cache_evict_valid &&
                                                cpu_req_is_strex &&
                                                strex_pass;
                txn_cache_evict_mem[txn_alloc_idx] <= cache_evict_valid;
                retry_ack_mem[txn_alloc_idx] <= 1'b0;
                retry_grant_mem[txn_alloc_idx] <= 1'b0;
                retry_pcrd_type_mem[txn_alloc_idx] <= `CHI_REQ_PCRD_TYPE_GENERIC;

                if (txn_alloc_is_write || txn_alloc_is_dvm) begin
                    wdata_valid_mem[txn_alloc_idx] <= 1'b1;
                end else begin
                    wdata_valid_mem[txn_alloc_idx] <= 1'b0;
                end
            end

            if (selected_complete_match_valid && selected_complete_clear) begin
                wdata_valid_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                txn_ldrex_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                txn_strex_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                txn_cache_evict_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                retry_ack_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                retry_grant_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                if (pending_wdat_valid_q &&
                    (pending_wdat_txn_q == selected_complete_txn_id))
                    pending_wdat_valid_q <= 1'b0;
            end

            if (rsp_retry_ack_valid && rsp_retry_touch_match_valid) begin
                retry_ack_mem[rsp_txn_idx] <= 1'b1;
            end

            if (rsp_pcrd_grant_valid && rsp_retry_touch_match_valid) begin
                retry_grant_mem[rsp_txn_idx] <= 1'b1;
                retry_pcrd_type_mem[rsp_txn_idx] <= rsp_pcrd_type;
            end

            if (retry_reissue_fire) begin
                retry_ack_mem[retry_reissue_idx_r] <= 1'b0;
                retry_grant_mem[retry_reissue_idx_r] <= 1'b0;
            end

            if (rsp_dbid_match_valid && wdata_valid_mem[rsp_txn_idx]) begin
                pending_wdat_valid_q <= 1'b1;
                wdata_valid_mem[rsp_txn_idx] <= 1'b0;
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn) begin
            if (timeout_valid) begin
                $display("chi_rn_f %0s txn %0h node %0d opcode 0x%0h addr 0x%0h cache_evict %0b strex %0b",
                         (FUNCTIONAL_TIMEOUT != 0) ? "transaction timeout" :
                                                     "watchdog: transaction still outstanding",
                         timeout_txn_id, NODE_ID,
                         txn_opcode_mem[timeout_txn_id[TXN_IDX_W-1:0]],
                         txn_addr_mem[timeout_txn_id[TXN_IDX_W-1:0]],
                         txn_cache_evict_mem[timeout_txn_id[TXN_IDX_W-1:0]],
                         txn_strex_mem[timeout_txn_id[TXN_IDX_W-1:0]]);
            end

            if (rsp_comp_valid && dat_line_valid_unused) begin
                $display("ERROR: chi_rn_f completion collision: RSP Comp txn %0h and DAT line txn %0h in the same cycle",
                         rsp_txn_id, dat_txn_id);
            end

            if (dat_line_valid_unused && !dat_txn_match) begin
                $display("chi_rn_f received DAT line for unknown txn %0h", dat_txn_id);
                $stop;
            end

            if (rsp_comp_valid && !selected_complete_match_valid) begin
                $display("chi_rn_f dropping completion for inactive txn %0h", rsp_txn_id);
            end

            if ((rsp_retry_ack_valid || rsp_pcrd_grant_valid) &&
                !rsp_retry_touch_match_valid) begin
                $display("chi_rn_f received retry credit response for unknown txn %0h",
                         rsp_txn_id);
                $stop;
            end
        end
    end
    // synthesis translate_on

    // Clock-gate hold: an outstanding transaction or reservation, a flit in
    // a TX link or RX buffer, or local work (snoop, cache update, write
    // data, CompAck, CPU response) keeps the fabric clock running. The
    // reservation is included so exclusive-monitor aging keeps counting.
    assign busy = (outstanding_count != 16'd0) || reservation_valid ||
                  tx_req_valid || tx_rsp_valid || tx_dat_valid ||
                  rsp_rx_busy || dat_rx_busy || snoop_busy ||
                  wdat_busy || cache_busy ||
                  pending_wdat_valid_q || compack_valid_q ||
                  mu_compack_valid_q ||
                  cpu_resp_valid_q || strex_fail_resp_q || fe_busy;
endmodule
