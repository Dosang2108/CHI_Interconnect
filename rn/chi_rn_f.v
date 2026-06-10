`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_rn_f
// Purpose: Request Node - Fully coherent (RN-F). Bridges the simple CPU-side
//          request interface to CHI REQ/RSP/DAT/SNP channels, owns the RN
//          transaction table, private cache, WDAT path, and snoop handling.
// -----------------------------------------------------------------------------
module chi_rn_f #(
    parameter NODE_ID    = 0,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter TXN_TBL_SIZE = `CHI_DEFAULT_RN_TXN_TBL_SIZE,
    parameter RN_CACHE_LINES = `CHI_DEFAULT_RN_CACHE_LINES,
    parameter ENABLE_PERF = `CHI_DEFAULT_ENABLE_PERF
)(
    input                    clk,
    input                    rstn,

    input                    cpu_req_valid,
    output                   cpu_req_ready,
    input      [ADDR_WIDTH-1:0] cpu_req_addr,
    input      [3:0]         cpu_req_op,
    input      [2:0]         cpu_req_size,
    input      [DATA_WIDTH-1:0] cpu_wdata,
    output     [DATA_WIDTH-1:0] cpu_rdata,
    output                   cpu_resp_valid,

    output                   tx_req_valid,
    output     [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] tx_req_flit,
    input                    tx_req_lcrdv,

    output                   tx_rsp_valid,
    output     [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv,

    output                   tx_dat_valid,
    output     [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] tx_dat_flit,
    input                    tx_dat_lcrdv,

    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_ready,
    output                   rx_rsp_lcrdv,

    input                    rx_snp_valid,
    input      [`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] rx_snp_flit,
    output                   rx_snp_ready,
    output                   rx_snp_lcrdv,

    input                    rx_dat_valid,
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] rx_dat_flit,
    output                   rx_dat_ready,
    output                   rx_dat_lcrdv,

    output     [16*32-1:0]   perf_counts,
    output                   cache_parity_error_event
);
    `include "../common/chi_clog2.vh"
    localparam REQ_W = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);
    localparam LINE_BYTES = 64;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam BE_W = DATA_WIDTH / 8;
    localparam TXN_IDX_W = (TXN_TBL_SIZE <= 2) ? 1 : `CHI_CLOG2(TXN_TBL_SIZE);
    localparam SNP_OPCODE_LSB = `CHI_SNP_OPCODE_LSB(ADDR_WIDTH);
    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB;
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB;
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB;
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(DBID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(DBID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W);
    localparam RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(DBID_W,TXN_ID_W,NODE_ID_W);

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
    wire [5:0]           req_opcode;
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
    wire                 rsp_rx_ready;
    wire [TXN_ID_W-1:0]  rsp_txn_id;
    wire [DBID_W-1:0]    rsp_dbid;
    wire [NODE_ID_W-1:0] rsp_src_id;
    wire [1:0]           rsp_resp_err;

    wire                 dat_data_valid;
    wire [DATA_WIDTH-1:0] dat_data;
    wire [LINE_WIDTH-1:0] dat_line_data_unused;
    wire [TXN_ID_W-1:0]  dat_txn_id;
    wire [NODE_ID_W-1:0] dat_src_id;
    wire [1:0]           dat_resp_err;
    wire [2:0]           dat_resp_unused;
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
    wire [TXN_IDX_W-1:0] txn_alloc_idx;
    wire [TXN_IDX_W-1:0] rsp_txn_idx;
    wire [TXN_IDX_W-1:0] dat_txn_idx;
    wire [3:0]           tx_req_credit_unused;
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
    wire [TXN_ID_W-1:0]  timeout_txn_id;
    wire [15:0]          outstanding_count_unused;
    wire                 table_full_unused;
    wire [TXN_TBL_SIZE-1:0] txn_debug_entry_valid_unused;
    wire [TXN_TBL_SIZE*TXN_ID_W-1:0] txn_debug_entry_txn_id_flat_unused;

    reg [LINE_WIDTH-1:0] wdata_line_mem [0:TXN_TBL_SIZE-1];
    reg [LINE_BYTES-1:0] wstrb_line_mem [0:TXN_TBL_SIZE-1];
    reg [ADDR_WIDTH-1:0] txn_addr_mem [0:TXN_TBL_SIZE-1];
    reg [5:0]            txn_opcode_mem [0:TXN_TBL_SIZE-1];
    reg [TXN_TBL_SIZE-1:0] txn_ldrex_mem;
    reg [TXN_TBL_SIZE-1:0] txn_strex_mem;
    reg [TXN_TBL_SIZE-1:0] txn_cache_evict_mem;
    reg [TXN_TBL_SIZE-1:0] wdata_valid_mem;
    reg                  pending_wdat_valid_q;
    reg [TXN_ID_W-1:0]   pending_wdat_txn_q;
    reg [DBID_W-1:0]     pending_wdat_dbid_q;
    reg [NODE_ID_W-1:0]  pending_wdat_src_q;
    reg [LINE_WIDTH-1:0] pending_wdat_data_q;
    reg [LINE_BYTES-1:0] pending_wdat_strb_q;
    reg                  compack_valid_q;
    reg [TXN_ID_W-1:0]   compack_txn_q;
    reg [NODE_ID_W-1:0]  compack_tgt_q;
    reg [RSP_W-1:0]      compack_rsp_flit;

    wire                 cache_update_valid;
    wire [ADDR_WIDTH-1:0] cache_update_addr;
    wire [LINE_WIDTH-1:0] cache_update_data;
    wire [2:0]           cache_update_state;
    wire                 cache_snoop_valid;
    wire                 cache_snoop_result_valid;
    wire [ADDR_WIDTH-1:0] cache_snoop_addr;
    wire [5:0]           cache_snoop_opcode;
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
    wire                 cache_write_update;
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
    wire                 reservation_valid_unused;
    wire                 reservation_match_unused;
    wire [ADDR_WIDTH-1:0] reservation_addr_unused;
    wire                 ldrex_set_pulse_unused;
    wire                 reservation_clear_pulse_unused;
    wire [5:0]           rx_snp_opcode;
    wire                 normal_cpu_resp_valid;
    wire                 exclusive_resp_complete;
    wire                 exclusive_success_resp;
    wire                 selected_complete_cpu_visible;
    wire                 cpu_resp_valid_comb;
    wire [DATA_WIDTH-1:0] cpu_rdata_comb;
    reg                  strex_fail_resp_q;
    reg                  cpu_resp_valid_q;
    reg [DATA_WIDTH-1:0] cpu_rdata_q;
    wire [3:0]           cpu_line_beat_idx;
    wire [1:0]           cpu_byte_idx;
    wire [3:0]           dat_line_beat_idx;

    wire                 snoop_dat_valid;
    wire                 snoop_dat_ready;
    wire [DAT_W-1:0]     snoop_dat_flit;
    wire                 tx_dat_link_valid;
    wire                 tx_dat_link_ready;
    wire [DAT_W-1:0]     tx_dat_link_flit;

    assign node_id_wire = NODE_ID;
    assign qos_value    = {QOS_W{1'b0}};
    assign cpu_line_beat_idx = cpu_req_addr[5:2];
    assign cpu_byte_idx      = cpu_req_addr[1:0];
    assign dat_line_beat_idx = txn_addr_mem[dat_txn_idx][5:2];
    assign cpu_req_is_ldrex = (cpu_req_op == `CHI_CPU_OP_LDREX);
    assign cpu_req_is_strex = (cpu_req_op == `CHI_CPU_OP_STREX);
    assign strex_fail_fire = strex_fail;
    assign cpu_req_valid_to_engine = cpu_req_valid && !strex_fail;
    assign req_engine_input_valid = cache_evict_valid ? 1'b1 : cpu_req_valid_to_engine;
    assign req_engine_input_addr = cache_evict_valid ? cache_evict_addr : cpu_req_addr;
    assign req_engine_input_op = cache_evict_valid ? `CHI_CPU_OP_WB_FULL : cpu_req_op;
    assign req_engine_input_size = cache_evict_valid ? 3'd6 : cpu_req_size;
    assign req_engine_wdata_line = cache_evict_valid ? cache_evict_data : cpu_wdata_line;
    assign req_engine_wstrb_line = cache_evict_valid ? {LINE_BYTES{1'b1}} : cpu_wstrb_line;
    assign cache_evict_ready = cache_evict_valid && req_engine_cpu_ready;
    assign cpu_req_ready = cache_evict_valid ? 1'b0 :
                           (strex_fail ? 1'b1 : req_engine_cpu_ready);
    assign selected_complete_cpu_visible =
        selected_complete_match_valid &&
        !txn_cache_evict_mem[selected_complete_txn_id[TXN_IDX_W-1:0]];
    assign normal_cpu_resp_valid = ((rsp_comp_valid || timeout_valid) &&
                                    selected_complete_cpu_visible) ||
                                   (dat_line_valid_unused && dat_txn_match);
    assign exclusive_resp_complete = (rsp_comp_valid || timeout_valid) &&
                                     selected_complete_cpu_visible &&
                                     txn_strex_mem[selected_complete_txn_id[TXN_IDX_W-1:0]];
    assign exclusive_success_resp = exclusive_resp_complete &&
                                    (rsp_resp_err == `CHI_RESPERR_EXOKAY) &&
                                    !timeout_valid;
    assign cpu_rdata_comb = strex_fail_resp_q ? {DATA_WIDTH{1'b0}} :
                            (exclusive_resp_complete ?
                             {{(DATA_WIDTH-1){1'b0}}, exclusive_success_resp} :
                             (timeout_valid ? {DATA_WIDTH{1'b0}} :
                              (dat_line_valid_unused ? dat_line_cpu_data : dat_data)));
    assign cpu_resp_valid_comb = strex_fail_resp_q || normal_cpu_resp_valid;
    assign cpu_rdata = cpu_rdata_q;
    assign cpu_resp_valid = cpu_resp_valid_q;
    assign selected_complete_valid = rsp_comp_valid ||
                                     dat_line_valid_unused ||
                                     timeout_valid;
    assign selected_complete_txn_id = rsp_comp_valid ? rsp_txn_id :
                                      (dat_line_valid_unused ? dat_txn_id :
                                       timeout_txn_id);
    assign rsp_rx_ready = !pending_wdat_valid_q || wdat_accept;
    assign wdat_accept = pending_wdat_valid_q &&
                         dbid_ready_unused &&
                         wdata_ready_unused;
    assign txn_alloc_is_write = (req_opcode == `CHI_REQ_WR_UNIQUE) ||
                                (req_opcode == `CHI_REQ_WR_NO_SNP) ||
                                (req_opcode == `CHI_REQ_WB_FULL) ||
                                (req_opcode == `CHI_REQ_WB_PTL);
    assign txn_alloc_idx = txn_alloc_id[TXN_IDX_W-1:0];
    assign rsp_txn_idx = rsp_txn_id[TXN_IDX_W-1:0];
    assign dat_txn_idx = dat_txn_id[TXN_IDX_W-1:0];
    assign cache_write_update = txn_alloc_valid && txn_alloc_is_write &&
                                !cache_evict_valid &&
                                (req_engine_input_size == 3'd6);
    assign cache_read_fill_update = dat_line_valid_unused && dat_txn_match;
    assign cache_read_fill_uq = (txn_opcode_mem[dat_txn_idx] == `CHI_REQ_RD_UNIQUE);
    assign cache_update_valid = cache_write_update || cache_read_fill_update;
    assign cache_update_addr = cache_write_update ? req_engine_input_addr : txn_addr_mem[dat_txn_idx];
    assign cache_update_data = cache_write_update ? req_engine_wdata_line : dat_line_data_unused;
    assign cache_update_state = cache_write_update ? `CHI_STATE_UD :
                                (cache_read_fill_uq ? `CHI_STATE_UC :
                                 `CHI_STATE_SC);
    assign tx_dat_link_valid = snoop_dat_valid || wdat_valid;
    assign tx_dat_link_flit = snoop_dat_valid ? snoop_dat_flit : wdat_flit;
    assign snoop_dat_ready = tx_dat_link_ready;
    assign wdat_engine_ready = tx_dat_link_ready && !snoop_dat_valid;
    assign tx_rsp_link_valid = snoop_rsp_valid || compack_valid_q;
    assign tx_rsp_link_flit = snoop_rsp_valid ? snoop_rsp_flit : compack_rsp_flit;
    assign snoop_rsp_ready = tx_rsp_link_ready;
    assign compack_rsp_ready = tx_rsp_link_ready && !snoop_rsp_valid;
    assign rx_snp_opcode = rx_snp_flit[SNP_OPCODE_LSB +: 6];
    assign strex_commit = txn_alloc_valid && !cache_evict_valid &&
                          cpu_req_is_strex && strex_pass;
    assign ldrex_complete = dat_line_valid_unused &&
                            dat_txn_match &&
                            txn_ldrex_mem[dat_txn_idx] &&
                            (dat_resp_err == `CHI_RESPERR_OK);
    assign exclusive_snoop_clear = cache_snoop_commit &&
                                   ((cache_snoop_opcode == `CHI_SNP_UNIQUE) ||
                                    (cache_snoop_opcode == `CHI_SNP_INVALID));
    assign exclusive_local_write_clear = txn_alloc_valid &&
                                         !cache_evict_valid &&
                                         txn_alloc_is_write &&
                                         !cpu_req_is_strex;
    assign dvm_reservation_clear = rx_snp_lcrdv &&
                                   ((rx_snp_opcode == `CHI_SNP_DVM_OP) ||
                                    (rx_snp_opcode == `CHI_SNP_DVM_SYNC));
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
        compack_rsp_flit = {RSP_W{1'b0}};
        compack_rsp_flit[RSP_RESP_LSB +: 3]        = 3'd0;
        compack_rsp_flit[RSP_RESPERR_LSB +: 2]     = `CHI_RESPERR_OK;
        compack_rsp_flit[RSP_DBID_LSB +: DBID_W]   = {DBID_W{1'b0}};
        compack_rsp_flit[RSP_OPCODE_LSB +: 4]      = `CHI_RSP_COMP_ACK;
        compack_rsp_flit[RSP_TXN_LSB +: TXN_ID_W]  = compack_txn_q;
        compack_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = node_id_wire;
        compack_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = compack_tgt_q;
        compack_rsp_flit[RSP_QOS_LSB +: QOS_W]     = {QOS_W{1'b0}};
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

        if (DATA_WIDTH <= LINE_WIDTH) begin
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
        .TXN_TBL_SIZE(TXN_TBL_SIZE)
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
        .complete_txn_id(selected_complete_txn_id),
        .complete_match_valid(selected_complete_match_valid),
        .lookup_valid(dat_data_valid),
        .lookup_txn_id(dat_txn_id),
        .lookup_match(dat_txn_match),
        .timeout_valid(timeout_valid),
        .timeout_txn_id(timeout_txn_id),
        .outstanding_count(outstanding_count_unused),
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
        .QOS_W(QOS_W)
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
        .strex_check_valid(cpu_req_valid && cpu_req_is_strex),
        .strex_addr(cpu_req_addr),
        .strex_pass(strex_pass),
        .strex_fail(strex_fail),
        .strex_commit(strex_commit),
        .local_write_valid(exclusive_local_write_clear),
        .local_write_addr(req_engine_input_addr),
        .clear_addr_valid(exclusive_snoop_clear),
        .clear_addr(cache_snoop_addr),
        .clear_all(dvm_reservation_clear),
        .reservation_valid(reservation_valid_unused),
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
        .tx_in_valid(req_engine_valid),
        .tx_in_ready(req_engine_ready),
        .tx_in_flit(req_engine_flit),
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
        .rx_rsp_valid(rx_rsp_valid),
        .rx_rsp_flit(rx_rsp_flit),
        .rx_rsp_ready(rx_rsp_ready),
        .rx_rsp_lcrdv(rx_rsp_lcrdv),
        .rsp_ready(rsp_rx_ready),
        .comp_valid(rsp_comp_valid),
        .dbid_valid(rsp_dbid_valid),
        .rsp_txn_id(rsp_txn_id),
        .rsp_dbid(rsp_dbid),
        .rsp_src_id(rsp_src_id),
        .rsp_resp_err(rsp_resp_err)
    );

    chi_rn_dat_rx #(
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES)
    ) u_dat_rx (
        .clk(clk),
        .rstn(rstn),
        .rx_dat_valid(rx_dat_valid),
        .rx_dat_flit(rx_dat_flit),
        .rx_dat_ready(rx_dat_ready),
        .rx_dat_lcrdv(rx_dat_lcrdv),
        .data_valid(dat_data_valid),
        .data(dat_data),
        .txn_id(dat_txn_id),
        .src_id(dat_src_id),
        .resp_err(dat_resp_err),
        .resp(dat_resp_unused),
        .line_valid(dat_line_valid_unused),
        .line_data(dat_line_data_unused)
    );

    chi_rn_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .LINES(RN_CACHE_LINES),
        .WAYS(4)
    ) u_rn_cache (
        .clk(clk),
        .rstn(rstn),
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
        .snoop_commit(cache_snoop_commit)
    );

    chi_rn_snoop_handler #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES)
    ) u_snoop_handler (
        .clk(clk),
        .rstn(rstn),
        .rx_snp_valid(rx_snp_valid),
        .rx_snp_flit(rx_snp_flit),
        .rx_snp_ready(rx_snp_ready),
        .rx_snp_lcrdv(rx_snp_lcrdv),
        .node_id(node_id_wire),
        .cache_hit(cache_snoop_hit),
        .cache_dirty(cache_snoop_dirty),
        .cache_result_valid(cache_snoop_result_valid),
        .cache_state(cache_snoop_state),
        .cache_data(cache_snoop_data),
        .cache_send_data(cache_snoop_send_data),
        .cache_snoop_valid(cache_snoop_valid),
        .cache_snoop_addr(cache_snoop_addr),
        .cache_snoop_opcode(cache_snoop_opcode),
        .cache_snoop_commit(cache_snoop_commit),
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
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES)
    ) u_wdat_engine (
        .clk(clk),
        .rstn(rstn),
        .dbid_valid(pending_wdat_valid_q),
        .dbid_ready(dbid_ready_unused),
        .dbid_txn_id(pending_wdat_txn_q),
        .dbid_value(pending_wdat_dbid_q),
        .dbid_src_id(pending_wdat_src_q),
        .wdata_valid(pending_wdat_valid_q),
        .wdata_ready(wdata_ready_unused),
        .wdata(pending_wdat_data_q),
        .wstrb(pending_wdat_strb_q),
        .node_id(node_id_wire),
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
            txn_opcode_mem[txn_alloc_idx] <= req_opcode;

            if (txn_alloc_is_write) begin
                wdata_line_mem[txn_alloc_idx] <= req_engine_wdata_line;
                wstrb_line_mem[txn_alloc_idx] <= req_engine_wstrb_line;
            end
        end

        if (rstn && rsp_dbid_match_valid && wdata_valid_mem[rsp_txn_idx]) begin
            pending_wdat_txn_q  <= rsp_txn_id;
            pending_wdat_dbid_q <= rsp_dbid;
            pending_wdat_src_q  <= rsp_src_id;
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
            pending_wdat_valid_q <= 1'b0;
            compack_valid_q      <= 1'b0;
            compack_txn_q        <= {TXN_ID_W{1'b0}};
            compack_tgt_q        <= {NODE_ID_W{1'b0}};
            strex_fail_resp_q    <= 1'b0;
            cpu_resp_valid_q     <= 1'b0;
            cpu_rdata_q          <= {DATA_WIDTH{1'b0}};
        end else begin
            strex_fail_resp_q <= strex_fail_fire;
            cpu_resp_valid_q <= cpu_resp_valid_comb;
            if (cpu_resp_valid_comb)
                cpu_rdata_q <= cpu_rdata_comb;

            if (wdat_accept)
                pending_wdat_valid_q <= 1'b0;

            if (compack_valid_q && compack_rsp_ready)
                compack_valid_q <= 1'b0;

            if (dat_line_valid_unused && dat_txn_match) begin
                compack_valid_q <= 1'b1;
                compack_txn_q   <= dat_txn_id;
                compack_tgt_q   <= dat_src_id;
            end

            if (txn_alloc_valid) begin
                txn_ldrex_mem[txn_alloc_idx] <= !cache_evict_valid && cpu_req_is_ldrex;
                txn_strex_mem[txn_alloc_idx] <= !cache_evict_valid &&
                                                cpu_req_is_strex &&
                                                strex_pass;
                txn_cache_evict_mem[txn_alloc_idx] <= cache_evict_valid;

                if (txn_alloc_is_write) begin
                    wdata_valid_mem[txn_alloc_idx] <= 1'b1;
                end else begin
                    wdata_valid_mem[txn_alloc_idx] <= 1'b0;
                end
            end

            if (selected_complete_match_valid) begin
                wdata_valid_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                txn_ldrex_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                txn_strex_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                txn_cache_evict_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;
                if (pending_wdat_valid_q &&
                    (pending_wdat_txn_q == selected_complete_txn_id))
                    pending_wdat_valid_q <= 1'b0;
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
                $display("chi_rn_f transaction timeout txn %0h", timeout_txn_id);
            end

            if (dat_line_valid_unused && !dat_txn_match) begin
                $display("chi_rn_f received DAT line for unknown txn %0h", dat_txn_id);
                $stop;
            end

            if (rsp_comp_valid && !selected_complete_match_valid) begin
                $display("chi_rn_f received completion for unknown txn %0h", rsp_txn_id);
                $stop;
            end
        end
    end
    // synthesis translate_on
endmodule
