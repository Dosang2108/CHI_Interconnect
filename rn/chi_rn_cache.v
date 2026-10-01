`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_rn_cache
// Purpose: Small RN-F private cache model with 4-way synchronous way banks,
//          serialized line fills/updates, snoop lookup, dirty victim
//          eviction reporting, and an atomic CPU access port (lookup plus
//          local read/store, invalidate or flush in one step, so a snoop
//          can never slip between the lookup and the state change).
// -----------------------------------------------------------------------------
module chi_rn_cache #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter LINE_BYTES = 64,
    parameter LINES      = `CHI_DEFAULT_RN_CACHE_LINES,
    parameter WAYS       = 4
)(
    input                    clk,
    input                    rstn,
    output                   busy,
    input                    clear,

    input                    line_update_valid,
    input      [ADDR_WIDTH-1:0] line_update_addr,
    input      [LINE_BYTES*8-1:0] line_update_data,
    input      [2:0]         line_update_state,

    output                   evict_valid,
    input                    evict_ready,
    output     [ADDR_WIDTH-1:0] evict_addr,
    output     [LINE_BYTES*8-1:0] evict_data,
    output     [2:0]         evict_state,

    input                    snoop_valid,
    input      [ADDR_WIDTH-1:0] snoop_addr,
    input      [`CHI_SNP_OPCODE_W-1:0] snoop_opcode,
    output                   snoop_result_valid,
    output                   snoop_hit,
    output                   snoop_dirty,
    output     [2:0]         snoop_state,
    output     [LINE_BYTES*8-1:0] snoop_data,
    output                   snoop_send_data,
    output                   snoop_parity_error,

    input                    snoop_commit,

    // CPU access. cpu_kind selects what a hit does (CPU_* below). The
    // result pulses on cpu_done one cycle after the access runs; cpu_line
    // is the line after any local store merge.
    input                    cpu_valid,
    output                   cpu_ready,
    input      [ADDR_WIDTH-1:0] cpu_addr,
    input      [2:0]         cpu_kind,
    input      [LINE_BYTES*8-1:0] cpu_wdata,
    input      [LINE_BYTES-1:0] cpu_wstrb,
    input                    cpu_excl_commit,
    output                   cpu_done,
    output                   cpu_hit,
    output     [2:0]         cpu_state,
    output     [LINE_BYTES*8-1:0] cpu_line,
    output                   cpu_local,
    output                   cpu_flushed,

    // Dirty victims waiting for their WriteBackFull to be issued. A snoop
    // must still see them (the RN-F checks these after a cache miss).
    output     [1:0]         victim_valid,
    output     [2*ADDR_WIDTH-1:0] victim_addr_flat,
    output     [2*LINE_BYTES*8-1:0] victim_data_flat
);
    `include "../common/chi_clog2.vh"

    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam SETS = LINES / WAYS;
    localparam INDEX_W = (SETS <= 2) ? 1 : `CHI_CLOG2(SETS);
    localparam WAY_W = (WAYS <= 2) ? 1 : `CHI_CLOG2(WAYS);
    localparam TAG_W = (ADDR_WIDTH > (INDEX_W + 6)) ?
                       (ADDR_WIDTH - INDEX_W - 6) : 1;
    localparam META_W = TAG_W + 3 + 1;
    localparam META_PARITY_LSB = 0;
    localparam META_STATE_LSB  = 1;
    localparam META_TAG_LSB    = 4;

    localparam ST_IDLE        = 2'd0;
    localparam ST_SNOOP_READ  = 2'd1;
    localparam ST_UPDATE_READ = 2'd2;
    localparam ST_CPU_READ    = 2'd3;

    // CPU access kinds. "Dirty" is UD/SD, "owned" is UC/UD.
    //   READ     any hit is served locally.
    //   READ_UQ  owned hit is local; SD is flushed first.
    //   FLUSH    dirty hit is flushed (written back); clean hit is kept.
    //   STREX    owned hit merges the bytes locally (-> UD, success); a
    //            shared hit is left as it is (the RN asks for CleanUnique
    //            first); a miss is reported as !cpu_hit (the STREX fails).
    //   cpu_excl_commit with STORE: the home granted CleanUnique(Excl), so
    //            any hit merges the bytes (-> UD); a miss is not local.
    //   STORE    owned hit merges the bytes locally (-> UD); SD is flushed;
    //            SC is invalidated.
    //   STORE_WB owned hit merges the bytes and flushes the merged line;
    //            SD is flushed; SC is invalidated.
    //   EVICT    dirty hit is flushed and counts as local; clean hit is
    //            invalidated.
    //   DROP     any hit is invalidated without a writeback.
    localparam CPU_READ     = 3'd0;
    localparam CPU_READ_UQ  = 3'd1;
    localparam CPU_FLUSH    = 3'd2;
    localparam CPU_STREX    = 3'd3;
    localparam CPU_STORE    = 3'd4;
    localparam CPU_STORE_WB = 3'd5;
    localparam CPU_EVICT    = 3'd6;
    localparam CPU_DROP     = 3'd7;

    function [1:0] plru_victim_4way;
        input [2:0] plru;
        begin
            casez (plru)
                3'b00?:  plru_victim_4way = 2'b00;
                3'b01?:  plru_victim_4way = 2'b01;
                3'b1?0:  plru_victim_4way = 2'b10;
                default: plru_victim_4way = 2'b11;
            endcase
        end
    endfunction

    function [2:0] plru_touch_4way;
        input [2:0] plru;
        input [1:0] way;
        begin
            plru_touch_4way = plru;
            case (way)
                2'b00: plru_touch_4way = {1'b1, 1'b1, plru[0]};
                2'b01: plru_touch_4way = {1'b1, 1'b0, plru[0]};
                2'b10: plru_touch_4way = {1'b0, plru[1], 1'b1};
                2'b11: plru_touch_4way = {1'b0, plru[1], 1'b0};
            endcase
        end
    endfunction

    function dirty_state;
        input [2:0] state;
        begin
            dirty_state = (state == `CHI_STATE_SD) ||
                          (state == `CHI_STATE_UD);
        end
    endfunction

    wire [INDEX_W-1:0] update_index = line_update_addr[6 +: INDEX_W];
    wire [TAG_W-1:0]   update_tag =
        line_update_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [INDEX_W-1:0] snoop_index = snoop_addr[6 +: INDEX_W];
    wire [TAG_W-1:0]   snoop_tag =
        snoop_addr[ADDR_WIDTH-1 -: TAG_W];

    wire [WAYS-1:0]              rd_valid_vec;
    wire [WAYS*META_W-1:0]       rd_meta_flat;
    wire [WAYS*LINE_WIDTH-1:0]   rd_data_flat;

    reg [1:0]          state_q;

    reg                snoop_pending_q;
    reg [ADDR_WIDTH-1:0] snoop_pending_addr_q;
    reg [`CHI_SNP_OPCODE_W-1:0] snoop_pending_opcode_q;
    reg                snoop_commit_wait_q;

    reg [INDEX_W-1:0]  active_snoop_index_q;
    reg [TAG_W-1:0]    active_snoop_tag_q;
    reg [`CHI_SNP_OPCODE_W-1:0] active_snoop_opcode_q;
    reg [INDEX_W-1:0]  active_update_index_q;
    reg [TAG_W-1:0]    active_update_tag_q;
    reg [2:0]          active_update_state_q;
    reg [LINE_WIDTH-1:0] active_update_data_q;

    reg                snoop_hit_r;
    reg [WAY_W-1:0]    snoop_way_r;
    reg [2:0]          snoop_state_r;
    reg                snoop_parity_r;
    reg [LINE_WIDTH-1:0] snoop_data_r;

    reg                update_hit_r;
    reg [WAY_W-1:0]    update_hit_way_r;
    reg                update_free_r;
    reg [WAY_W-1:0]    update_free_way_r;
    reg [WAY_W-1:0]    update_way_r;
    reg [TAG_W-1:0]    update_victim_tag_r;
    reg [2:0]          update_victim_state_r;
    reg                update_victim_parity_r;
    reg [LINE_WIDTH-1:0] update_victim_data_r;

    reg                snoop_result_valid_q;
    reg                snoop_hit_q;
    reg [WAY_W-1:0]    snoop_way_q;
    reg [INDEX_W-1:0]  snoop_index_q;
    reg [TAG_W-1:0]    snoop_tag_q;
    reg [2:0]          snoop_state_q;
    reg [`CHI_SNP_OPCODE_W-1:0] snoop_opcode_q;
    reg [LINE_WIDTH-1:0] snoop_data_q;
    reg                snoop_parity_q;
    reg                snoop_parity_error_q;

    reg [ADDR_WIDTH-1:0] evict_addr_q [0:1];
    reg [LINE_WIDTH-1:0] evict_data_q [0:1];
    reg [2:0]          evict_state_q [0:1];
    reg                evict_head_q;
    reg                evict_tail_q;
    reg [1:0]          evict_count_q;

    reg [ADDR_WIDTH-1:0] upd_addr_q [0:1];
    reg [LINE_WIDTH-1:0] upd_data_q [0:1];
    reg [2:0]          upd_state_q [0:1];
    reg                upd_head_q;
    reg                upd_tail_q;
    reg [1:0]          upd_count_q;

    reg [2:0]          plru_q [0:SETS-1];

    reg [INDEX_W-1:0]  cpu_index_q;
    reg [TAG_W-1:0]    cpu_tag_q;
    reg [2:0]          cpu_kind_q;
    reg                cpu_excl_commit_q;
    reg [LINE_WIDTH-1:0] cpu_wdata_q;
    reg [LINE_BYTES-1:0] cpu_wstrb_q;
    reg                cpu_hit_r;
    reg [WAY_W-1:0]    cpu_way_r;
    reg [2:0]          cpu_state_r;
    reg [LINE_WIDTH-1:0] cpu_data_r;
    reg [LINE_WIDTH-1:0] cpu_merged_r;
    reg                cpu_local_r;
    reg                cpu_merge_r;
    reg                cpu_flush_r;
    reg                cpu_inv_r;
    reg                cpu_done_q;
    reg                cpu_hit_q;
    reg [2:0]          cpu_state_q;
    reg [LINE_WIDTH-1:0] cpu_line_q;
    reg                cpu_local_q;
    reg                cpu_flushed_q;
    integer            cpu_byte_i;

    integer scan_i;
    integer set_i;
    genvar  way_g;

    wire                 evict_pop = evict_valid && evict_ready;
    wire                 evict_queue_full = (evict_count_q == 2'd2);
    wire                 update_victim_dirty =
        rd_valid_vec[update_way_r] && dirty_state(update_victim_state_r);
    wire                 update_needs_evict =
        !update_hit_r && !update_free_r && update_victim_dirty;
    wire                 update_wait_evict = update_needs_evict &&
                                             evict_queue_full &&
                                             !evict_pop;
    wire                 update_commit_fire =
        (state_q == ST_UPDATE_READ) && !update_wait_evict;
    wire                 update_fifo_full = (upd_count_q == 2'd2);
    wire                 update_fifo_push =
        line_update_valid && (!update_fifo_full || update_commit_fire);
    wire                 update_fifo_overflow =
        line_update_valid && update_fifo_full && !update_commit_fire;

    wire                 snoop_start_now =
        (state_q == ST_IDLE) &&
        !snoop_commit_wait_q &&
        (upd_count_q == 2'd0) &&
        !snoop_pending_q &&
        snoop_valid;
    wire                 snoop_pending_overflow =
        snoop_valid && !snoop_start_now && snoop_pending_q;
    wire                 start_update =
        (state_q == ST_IDLE) &&
        !snoop_commit_wait_q &&
        (upd_count_q != 2'd0);
    wire                 start_pending_snoop =
        (state_q == ST_IDLE) &&
        !snoop_commit_wait_q &&
        (upd_count_q == 2'd0) &&
        snoop_pending_q;
    wire                 start_direct_snoop = snoop_start_now;
    // Lowest priority; starts only with an empty victim queue so a flush
    // always has room.
    wire                 start_cpu =
        (state_q == ST_IDLE) &&
        !snoop_commit_wait_q &&
        (upd_count_q == 2'd0) &&
        !snoop_pending_q &&
        !snoop_valid &&
        (evict_count_q == 2'd0) &&
        cpu_valid;
    wire                 cpu_commit_fire = (state_q == ST_CPU_READ);
    wire                 ram_read_valid = start_update ||
                                          start_pending_snoop ||
                                          start_direct_snoop ||
                                          start_cpu;
    wire [INDEX_W-1:0]   ram_read_set =
        start_update ? upd_addr_q[upd_head_q][6 +: INDEX_W] :
        (start_pending_snoop ? snoop_pending_addr_q[6 +: INDEX_W] :
         (start_direct_snoop ? snoop_index :
          cpu_addr[6 +: INDEX_W]));

    wire [2:0] snoop_commit_state_next =
        ((snoop_opcode_q == `CHI_SNP_SHARED) &&
         (snoop_state_q == `CHI_STATE_UD)) ? `CHI_STATE_SD :
        ((snoop_opcode_q == `CHI_SNP_SHARED) &&
         (snoop_state_q == `CHI_STATE_UC)) ? `CHI_STATE_SC :
        (((snoop_opcode_q == `CHI_SNP_UNIQUE) ||
          (snoop_opcode_q == `CHI_SNP_INVALID)) ? `CHI_STATE_I :
         snoop_state_q);
    wire snoop_commit_valid_next =
        !((snoop_opcode_q == `CHI_SNP_UNIQUE) ||
          (snoop_opcode_q == `CHI_SNP_INVALID));
    wire snoop_commit_fire = snoop_commit && snoop_commit_wait_q &&
                             snoop_hit_q && !update_commit_fire;

    assign evict_valid = evict_count_q != 2'd0;
    assign evict_addr = evict_addr_q[evict_head_q];
    assign evict_data = evict_data_q[evict_head_q];
    assign evict_state = evict_state_q[evict_head_q];

    assign snoop_result_valid = snoop_result_valid_q;
    assign snoop_hit = snoop_result_valid_q && snoop_hit_q;
    assign snoop_dirty = snoop_hit && dirty_state(snoop_state_q);
    assign snoop_state = snoop_hit ? snoop_state_q : `CHI_STATE_I;
    assign snoop_data = snoop_data_q;
    assign snoop_parity_error = snoop_result_valid_q &&
                                snoop_parity_error_q;
    assign victim_valid[0] = (evict_count_q == 2'd2) ||
                             ((evict_count_q == 2'd1) && (evict_head_q == 1'b0));
    assign victim_valid[1] = (evict_count_q == 2'd2) ||
                             ((evict_count_q == 2'd1) && (evict_head_q == 1'b1));
    assign victim_addr_flat = {evict_addr_q[1], evict_addr_q[0]};
    assign victim_data_flat = {evict_data_q[1], evict_data_q[0]};

    assign cpu_ready = start_cpu;
    assign cpu_done = cpu_done_q;
    assign cpu_hit = cpu_hit_q;
    assign cpu_state = cpu_state_q;
    assign cpu_line = cpu_line_q;
    assign cpu_local = cpu_local_q;
    assign cpu_flushed = cpu_flushed_q;

    assign snoop_send_data = snoop_dirty &&
                             ((snoop_opcode_q == `CHI_SNP_SHARED) ||
                              (snoop_opcode_q == `CHI_SNP_UNIQUE) ||
                              (snoop_opcode_q == `CHI_SNP_INVALID));

    generate
        for (way_g = 0; way_g < WAYS; way_g = way_g + 1) begin : gen_way_ram
            localparam [WAY_W-1:0] WAY_ID = way_g;

            reg                  valid_mem [0:SETS-1];
            (* ram_style = "distributed" *) reg [META_W-1:0] meta_mem [0:SETS-1];
            (* ram_style = "block" *) reg [LINE_WIDTH-1:0] data_mem [0:SETS-1];

            reg                  rd_valid_q;
            reg [META_W-1:0]     rd_meta_q;
            reg [LINE_WIDTH-1:0] rd_data_q;
            integer              reset_i;

            assign rd_valid_vec[way_g] = rd_valid_q;
            assign rd_meta_flat[way_g*META_W +: META_W] = rd_meta_q;
            assign rd_data_flat[way_g*LINE_WIDTH +: LINE_WIDTH] = rd_data_q;

            always @(posedge clk) begin
                if (ram_read_valid) begin
                    rd_meta_q <= meta_mem[ram_read_set];
                    rd_data_q <= data_mem[ram_read_set];
                end

                if (!clear) begin
                    if (update_commit_fire && (update_way_r == WAY_ID)) begin
                        meta_mem[active_update_index_q] <= {
                            active_update_tag_q,
                            active_update_state_q,
                            ^active_update_data_q
                        };
                        data_mem[active_update_index_q] <= active_update_data_q;
                    end else if (cpu_commit_fire && cpu_merge_r &&
                                 !cpu_flush_r && (cpu_way_r == WAY_ID)) begin
                        meta_mem[cpu_index_q] <= {
                            cpu_tag_q,
                            `CHI_STATE_UD,
                            ^cpu_merged_r
                        };
                        data_mem[cpu_index_q] <= cpu_merged_r;
                    end else if (snoop_commit_fire &&
                                 (snoop_way_q == WAY_ID)) begin
                        meta_mem[snoop_index_q] <= {
                            snoop_tag_q,
                            snoop_commit_state_next,
                            snoop_parity_q
                        };
                    end
                end
            end

            always @(posedge clk or negedge rstn) begin
                if (!rstn) begin
                    rd_valid_q <= 1'b0;
                    for (reset_i = 0; reset_i < SETS; reset_i = reset_i + 1)
                        valid_mem[reset_i] <= 1'b0;
                end else if (clear) begin
                    rd_valid_q <= 1'b0;
                    for (reset_i = 0; reset_i < SETS; reset_i = reset_i + 1)
                        valid_mem[reset_i] <= 1'b0;
                end else begin
                    if (ram_read_valid)
                        rd_valid_q <= valid_mem[ram_read_set];

                    if (update_commit_fire && (update_way_r == WAY_ID)) begin
                        valid_mem[active_update_index_q] <=
                            (active_update_state_q != `CHI_STATE_I);
                    end else if (cpu_commit_fire &&
                                 (cpu_flush_r || cpu_inv_r) &&
                                 (cpu_way_r == WAY_ID)) begin
                        valid_mem[cpu_index_q] <= 1'b0;
                    end else if (snoop_commit_fire &&
                                 (snoop_way_q == WAY_ID)) begin
                        valid_mem[snoop_index_q] <= snoop_commit_valid_next;
                    end
                end
            end
        end
    endgenerate

    always @(*) begin
        snoop_hit_r = 1'b0;
        snoop_way_r = {WAY_W{1'b0}};
        snoop_state_r = `CHI_STATE_I;
        snoop_parity_r = 1'b0;
        snoop_data_r = {LINE_WIDTH{1'b0}};

        for (scan_i = 0; scan_i < WAYS; scan_i = scan_i + 1) begin
            if (!snoop_hit_r &&
                rd_valid_vec[scan_i] &&
                (rd_meta_flat[scan_i*META_W + META_TAG_LSB +: TAG_W] ==
                 active_snoop_tag_q) &&
                (rd_meta_flat[scan_i*META_W + META_STATE_LSB +: 3] !=
                 `CHI_STATE_I)) begin
                snoop_hit_r = 1'b1;
                snoop_way_r = scan_i[WAY_W-1:0];
                snoop_state_r =
                    rd_meta_flat[scan_i*META_W + META_STATE_LSB +: 3];
                snoop_parity_r =
                    rd_meta_flat[scan_i*META_W + META_PARITY_LSB];
                snoop_data_r =
                    rd_data_flat[scan_i*LINE_WIDTH +: LINE_WIDTH];
            end
        end
    end

    always @(*) begin
        cpu_hit_r = 1'b0;
        cpu_way_r = {WAY_W{1'b0}};
        cpu_state_r = `CHI_STATE_I;
        cpu_data_r = {LINE_WIDTH{1'b0}};

        for (scan_i = 0; scan_i < WAYS; scan_i = scan_i + 1) begin
            if (!cpu_hit_r &&
                rd_valid_vec[scan_i] &&
                (rd_meta_flat[scan_i*META_W + META_TAG_LSB +: TAG_W] ==
                 cpu_tag_q) &&
                (rd_meta_flat[scan_i*META_W + META_STATE_LSB +: 3] !=
                 `CHI_STATE_I)) begin
                cpu_hit_r = 1'b1;
                cpu_way_r = scan_i[WAY_W-1:0];
                cpu_state_r =
                    rd_meta_flat[scan_i*META_W + META_STATE_LSB +: 3];
                cpu_data_r = rd_data_flat[scan_i*LINE_WIDTH +: LINE_WIDTH];
            end
        end

        cpu_merged_r = cpu_data_r;
        for (cpu_byte_i = 0; cpu_byte_i < LINE_BYTES;
             cpu_byte_i = cpu_byte_i + 1) begin
            if (cpu_wstrb_q[cpu_byte_i])
                cpu_merged_r[cpu_byte_i*8 +: 8] =
                    cpu_wdata_q[cpu_byte_i*8 +: 8];
        end

        cpu_local_r = 1'b0;
        cpu_merge_r = 1'b0;
        cpu_flush_r = 1'b0;
        cpu_inv_r = 1'b0;
        if (cpu_hit_r) begin
            case (cpu_kind_q)
                CPU_READ: cpu_local_r = 1'b1;
                CPU_READ_UQ: begin
                    if ((cpu_state_r == `CHI_STATE_UC) ||
                        (cpu_state_r == `CHI_STATE_UD))
                        cpu_local_r = 1'b1;
                    else if (cpu_state_r == `CHI_STATE_SD)
                        cpu_flush_r = 1'b1;
                end
                CPU_FLUSH: cpu_flush_r = dirty_state(cpu_state_r);
                CPU_STREX: begin
                    if ((cpu_state_r == `CHI_STATE_UC) ||
                        (cpu_state_r == `CHI_STATE_UD)) begin
                        cpu_local_r = 1'b1;
                        cpu_merge_r = 1'b1;
                    end
                end
                CPU_STORE, CPU_STORE_WB: begin
                    if (cpu_excl_commit_q) begin
                        cpu_local_r = 1'b1;
                        cpu_merge_r = 1'b1;
                    end else if ((cpu_state_r == `CHI_STATE_UC) ||
                        (cpu_state_r == `CHI_STATE_UD)) begin
                        cpu_local_r = 1'b1;
                        cpu_merge_r = 1'b1;
                        cpu_flush_r = (cpu_kind_q == CPU_STORE_WB);
                    end else if (cpu_state_r == `CHI_STATE_SD) begin
                        cpu_flush_r = 1'b1;
                    end else begin
                        cpu_inv_r = 1'b1;
                    end
                end
                CPU_EVICT: begin
                    cpu_flush_r = dirty_state(cpu_state_r);
                    cpu_local_r = dirty_state(cpu_state_r);
                    cpu_inv_r = !dirty_state(cpu_state_r);
                end
                default: cpu_inv_r = 1'b1;
            endcase
        end
    end

    always @(*) begin
        update_hit_r = 1'b0;
        update_hit_way_r = {WAY_W{1'b0}};
        update_free_r = 1'b0;
        update_free_way_r = {WAY_W{1'b0}};

        for (scan_i = 0; scan_i < WAYS; scan_i = scan_i + 1) begin
            if (!update_hit_r &&
                rd_valid_vec[scan_i] &&
                (rd_meta_flat[scan_i*META_W + META_TAG_LSB +: TAG_W] ==
                 active_update_tag_q)) begin
                update_hit_r = 1'b1;
                update_hit_way_r = scan_i[WAY_W-1:0];
            end

            if (!update_free_r && !rd_valid_vec[scan_i]) begin
                update_free_r = 1'b1;
                update_free_way_r = scan_i[WAY_W-1:0];
            end
        end

        update_way_r = update_hit_r ? update_hit_way_r :
                       (update_free_r ? update_free_way_r :
                        plru_victim_4way(plru_q[active_update_index_q]));
        update_victim_tag_r =
            rd_meta_flat[update_way_r*META_W + META_TAG_LSB +: TAG_W];
        update_victim_state_r =
            rd_meta_flat[update_way_r*META_W + META_STATE_LSB +: 3];
        update_victim_parity_r =
            rd_meta_flat[update_way_r*META_W + META_PARITY_LSB];
        update_victim_data_r =
            rd_data_flat[update_way_r*LINE_WIDTH +: LINE_WIDTH];
    end

    always @(posedge clk) begin
        if (rstn && !clear) begin
            if (update_fifo_push) begin
                upd_addr_q[upd_tail_q] <= line_update_addr;
                upd_data_q[upd_tail_q] <= line_update_data;
                upd_state_q[upd_tail_q] <= line_update_state;
            end

            if (update_commit_fire && update_needs_evict) begin
                evict_addr_q[evict_tail_q] <= {
                    update_victim_tag_r,
                    active_update_index_q,
                    6'b0
                };
                evict_data_q[evict_tail_q] <= update_victim_data_r;
                evict_state_q[evict_tail_q] <= update_victim_state_r;
            end

            if (start_cpu) begin
                cpu_index_q <= cpu_addr[6 +: INDEX_W];
                cpu_tag_q <= cpu_addr[ADDR_WIDTH-1 -: TAG_W];
                cpu_kind_q <= cpu_kind;
                cpu_excl_commit_q <= cpu_excl_commit;
                cpu_wdata_q <= cpu_wdata;
                cpu_wstrb_q <= cpu_wstrb;
            end

            if (cpu_commit_fire) begin
                cpu_hit_q <= cpu_hit_r;
                cpu_state_q <= cpu_state_r;
                cpu_line_q <= cpu_merge_r ? cpu_merged_r : cpu_data_r;
                cpu_local_q <= cpu_local_r;
                cpu_flushed_q <= cpu_flush_r;
                if (cpu_flush_r) begin
                    evict_addr_q[evict_tail_q] <= {
                        cpu_tag_q,
                        cpu_index_q,
                        6'b0
                    };
                    evict_data_q[evict_tail_q] <=
                        cpu_merge_r ? cpu_merged_r : cpu_data_r;
                    evict_state_q[evict_tail_q] <=
                        cpu_merge_r ? `CHI_STATE_UD : cpu_state_r;
                end
            end

            if (snoop_valid && !snoop_start_now && !snoop_pending_q) begin
                snoop_pending_addr_q <= snoop_addr;
                snoop_pending_opcode_q <= snoop_opcode;
            end

            if (state_q == ST_IDLE) begin
                if (start_update) begin
                    active_update_index_q <=
                        upd_addr_q[upd_head_q][6 +: INDEX_W];
                    active_update_tag_q <=
                        upd_addr_q[upd_head_q][ADDR_WIDTH-1 -: TAG_W];
                    active_update_state_q <= upd_state_q[upd_head_q];
                    active_update_data_q <= upd_data_q[upd_head_q];
                end else if (start_pending_snoop) begin
                    active_snoop_index_q <=
                        snoop_pending_addr_q[6 +: INDEX_W];
                    active_snoop_tag_q <=
                        snoop_pending_addr_q[ADDR_WIDTH-1 -: TAG_W];
                    active_snoop_opcode_q <= snoop_pending_opcode_q;
                end else if (start_direct_snoop) begin
                    active_snoop_index_q <= snoop_index;
                    active_snoop_tag_q <= snoop_tag;
                    active_snoop_opcode_q <= snoop_opcode;
                end
            end

            if (state_q == ST_SNOOP_READ) begin
                snoop_hit_q <= snoop_hit_r;
                snoop_way_q <= snoop_way_r;
                snoop_index_q <= active_snoop_index_q;
                snoop_tag_q <= active_snoop_tag_q;
                snoop_state_q <= snoop_state_r;
                snoop_opcode_q <= active_snoop_opcode_q;
                snoop_data_q <= snoop_data_r;
                snoop_parity_q <= snoop_parity_r;
                snoop_parity_error_q <= snoop_hit_r &&
                                        (snoop_parity_r !=
                                         (^snoop_data_r));
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_q <= ST_IDLE;
            snoop_pending_q <= 1'b0;
            snoop_commit_wait_q <= 1'b0;
            snoop_result_valid_q <= 1'b0;
            evict_head_q <= 1'b0;
            evict_tail_q <= 1'b0;
            evict_count_q <= 2'd0;
            upd_head_q <= 1'b0;
            upd_tail_q <= 1'b0;
            upd_count_q <= 2'd0;
            cpu_done_q <= 1'b0;
            for (set_i = 0; set_i < SETS; set_i = set_i + 1)
                plru_q[set_i] <= 3'b000;
        end else if (clear) begin
            state_q <= ST_IDLE;
            snoop_pending_q <= 1'b0;
            snoop_commit_wait_q <= 1'b0;
            snoop_result_valid_q <= 1'b0;
            evict_head_q <= 1'b0;
            evict_tail_q <= 1'b0;
            evict_count_q <= 2'd0;
            upd_head_q <= 1'b0;
            upd_tail_q <= 1'b0;
            upd_count_q <= 2'd0;
            cpu_done_q <= 1'b0;
            for (set_i = 0; set_i < SETS; set_i = set_i + 1)
                plru_q[set_i] <= 3'b000;
        end else begin
            snoop_result_valid_q <= 1'b0;
            cpu_done_q <= cpu_commit_fire;

            if (update_fifo_push) begin
                upd_tail_q <= upd_tail_q + 1'b1;
            end

            if (update_commit_fire)
                upd_head_q <= upd_head_q + 1'b1;

            case ({update_fifo_push, update_commit_fire})
                2'b10: upd_count_q <= upd_count_q + 1'b1;
                2'b01: upd_count_q <= upd_count_q - 1'b1;
                default: upd_count_q <= upd_count_q;
            endcase

            if (snoop_valid && !snoop_start_now && !snoop_pending_q) begin
                snoop_pending_q <= 1'b1;
            end

            if (evict_pop) begin
                evict_head_q <= evict_head_q + 1'b1;
            end

            if ((update_commit_fire && update_needs_evict) ||
                (cpu_commit_fire && cpu_flush_r)) begin
                evict_tail_q <= evict_tail_q + 1'b1;
            end

            case ({((update_commit_fire && update_needs_evict) ||
                    (cpu_commit_fire && cpu_flush_r)), evict_pop})
                2'b10: evict_count_q <= evict_count_q + 1'b1;
                2'b01: evict_count_q <= evict_count_q - 1'b1;
                default: evict_count_q <= evict_count_q;
            endcase

            if (snoop_commit_fire)
                snoop_commit_wait_q <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (start_update) begin
                        state_q <= ST_UPDATE_READ;
                    end else if (start_pending_snoop) begin
                        snoop_pending_q <= 1'b0;
                        state_q <= ST_SNOOP_READ;
                    end else if (start_direct_snoop) begin
                        state_q <= ST_SNOOP_READ;
                    end else if (start_cpu) begin
                        state_q <= ST_CPU_READ;
                    end
                end

                ST_CPU_READ: begin
                    if (cpu_hit_r && !cpu_flush_r && !cpu_inv_r)
                        plru_q[cpu_index_q] <=
                            plru_touch_4way(plru_q[cpu_index_q], cpu_way_r);
                    state_q <= ST_IDLE;
                end

                ST_SNOOP_READ: begin
                    snoop_result_valid_q <= 1'b1;
                    snoop_commit_wait_q <= snoop_hit_r;
                    if (snoop_hit_r)
                        plru_q[active_snoop_index_q] <=
                            plru_touch_4way(plru_q[active_snoop_index_q],
                                            snoop_way_r);
                    state_q <= ST_IDLE;
                end

                ST_UPDATE_READ: begin
                    if (!update_wait_evict) begin
                        if (active_update_state_q != `CHI_STATE_I)
                            plru_q[active_update_index_q] <=
                                plru_touch_4way(plru_q[active_update_index_q],
                                                update_way_r);
                        state_q <= ST_IDLE;
                    end
                end

                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && ((WAYS != 4) || ((LINES % WAYS) != 0))) begin
            $display("chi_rn_cache requires WAYS=4 and divisible LINES");
            $stop;
        end

        if (rstn && update_fifo_overflow) begin
            $display("chi_rn_cache line update FIFO overflow");
            $stop;
        end

        if (rstn && snoop_pending_overflow) begin
            $display("chi_rn_cache snoop pending overflow");
            $stop;
        end

        if (rstn && snoop_parity_error) begin
            $display("chi_rn_cache data parity error addr %0h", snoop_addr);
            $stop;
        end

        if (rstn && update_wait_evict) begin
            $display("chi_rn_cache waiting for dirty victim queue space");
        end
    end
    // synthesis translate_on

    // A snoop, line update or eviction is still queued or in progress.
    assign busy = (state_q != ST_IDLE) || snoop_pending_q || snoop_commit_wait_q ||
                  cpu_done_q ||
                  snoop_result_valid_q || (upd_count_q != 2'd0) ||
                  (evict_count_q != 2'd0);
endmodule
