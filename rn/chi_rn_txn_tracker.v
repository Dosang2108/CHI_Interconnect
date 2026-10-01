`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_rn_txn_tracker
// Purpose: RN-F transaction table. Allocates epoch/index TxnIDs, validates
//          DBID/data/complete matches, tracks timeouts, and exposes flat debug
//          state for B5 simulation/formal monitors.
// -----------------------------------------------------------------------------
module chi_rn_txn_tracker #(
    parameter TXN_ID_W     = `CHI_DEFAULT_TXN_ID_W,
    parameter TXN_TBL_SIZE = `CHI_DEFAULT_RN_TXN_TBL_SIZE,
    parameter TIMEOUT_CYCLES = 1024,
    // 0: timeout_valid is a one-cycle watchdog pulse when an entry first
    //    reaches TIMEOUT_CYCLES; the entry stays allocated.
    // 1: legacy functional timeout; timeout_valid stays high for the aged
    //    entry until the owner completes (reaps) it.
    parameter FUNCTIONAL_TIMEOUT = 0
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    alloc_valid,
    output                   alloc_ready,
    output     [TXN_ID_W-1:0] alloc_txn_id,

    input                    dbid_update_valid,
    input      [TXN_ID_W-1:0] dbid_update_txn_id,
    output                   dbid_match_valid,

    input                    complete_valid,
    input                    complete_clear,
    input      [TXN_ID_W-1:0] complete_txn_id,
    output                   complete_match_valid,

    input                    touch_valid,
    input      [TXN_ID_W-1:0] touch_txn_id,
    output                   touch_match_valid,

    input                    lookup_valid,
    input      [TXN_ID_W-1:0] lookup_txn_id,
    output                   lookup_match,

    output reg               timeout_valid,
    output reg [TXN_ID_W-1:0] timeout_txn_id,
    output reg [15:0]        outstanding_count,
    output                   table_full,

    output     [TXN_TBL_SIZE-1:0] debug_entry_valid,
    output     [TXN_TBL_SIZE*TXN_ID_W-1:0] debug_entry_txn_id_flat
);
    `include "../common/chi_clog2.vh"
    localparam IDX_W = (TXN_TBL_SIZE <= 2) ? 1 : `CHI_CLOG2(TXN_TBL_SIZE);
    localparam EPOCH_W = TXN_ID_W - IDX_W;
    localparam AGE_W = (TIMEOUT_CYCLES <= 2) ? 1 : `CHI_CLOG2(TIMEOUT_CYCLES + 1);
    localparam [AGE_W-1:0] TIMEOUT_VALUE = TIMEOUT_CYCLES;

    reg [TXN_TBL_SIZE-1:0] valid_q;
    reg [IDX_W-1:0]        alloc_ptr_q;
    reg [EPOCH_W-1:0]      epoch_q [0:TXN_TBL_SIZE-1];
    reg [AGE_W-1:0]        age_q   [0:TXN_TBL_SIZE-1];

    wire [IDX_W-1:0] complete_idx = complete_txn_id[IDX_W-1:0];
    wire [IDX_W-1:0] dbid_idx     = dbid_update_txn_id[IDX_W-1:0];
    wire [IDX_W-1:0] touch_idx    = touch_txn_id[IDX_W-1:0];
    wire [IDX_W-1:0] lookup_idx   = lookup_txn_id[IDX_W-1:0];
    wire [EPOCH_W-1:0] complete_epoch = complete_txn_id[TXN_ID_W-1:IDX_W];
    wire [EPOCH_W-1:0] dbid_epoch     = dbid_update_txn_id[TXN_ID_W-1:IDX_W];
    wire [EPOCH_W-1:0] touch_epoch    = touch_txn_id[TXN_ID_W-1:IDX_W];
    wire [EPOCH_W-1:0] lookup_epoch   = lookup_txn_id[TXN_ID_W-1:IDX_W];
    wire complete_match = valid_q[complete_idx] &&
                          (complete_epoch == epoch_q[complete_idx]);
    wire dbid_match = valid_q[dbid_idx] &&
                      (dbid_epoch == epoch_q[dbid_idx]);
    wire touch_match = valid_q[touch_idx] &&
                       (touch_epoch == epoch_q[touch_idx]);
    wire lookup_match_raw = valid_q[lookup_idx] &&
                            (lookup_epoch == epoch_q[lookup_idx]);
    wire alloc_fire = alloc_valid && alloc_ready;
    wire complete_fire = complete_valid && complete_clear && complete_match;
    wire touch_fire = touch_valid && touch_match;

    integer i;
    integer t;
    genvar dbg_g;

    assign alloc_ready  = !valid_q[alloc_ptr_q];
    assign alloc_txn_id = {epoch_q[alloc_ptr_q], alloc_ptr_q};
    assign table_full   = &valid_q;
    assign dbid_match_valid = dbid_update_valid && dbid_match;
    assign complete_match_valid = complete_valid && complete_match;
    assign touch_match_valid = touch_valid && touch_match;
    assign lookup_match = lookup_valid && lookup_match_raw;
    assign debug_entry_valid = valid_q;

    generate
        for (dbg_g = 0; dbg_g < TXN_TBL_SIZE; dbg_g = dbg_g + 1) begin : gen_debug_txn_id
            localparam [IDX_W-1:0] DBG_IDX = dbg_g;
            assign debug_entry_txn_id_flat[dbg_g*TXN_ID_W +: TXN_ID_W] =
                {epoch_q[dbg_g], DBG_IDX};
        end
    endgenerate

    always @(*) begin
        timeout_valid = 1'b0;
        timeout_txn_id = {TXN_ID_W{1'b0}};
        for (t = 0; t < TXN_TBL_SIZE; t = t + 1) begin
            if (!timeout_valid && valid_q[t] &&
                ((FUNCTIONAL_TIMEOUT != 0) ?
                 (age_q[t] >= TIMEOUT_VALUE) :
                 (age_q[t] == TIMEOUT_VALUE - 1'b1))) begin
                timeout_valid = 1'b1;
                timeout_txn_id = {epoch_q[t], t[IDX_W-1:0]};
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q     <= {TXN_TBL_SIZE{1'b0}};
            alloc_ptr_q <= {IDX_W{1'b0}};
            outstanding_count <= 16'd0;
            for (i = 0; i < TXN_TBL_SIZE; i = i + 1) begin
                epoch_q[i]      <= {EPOCH_W{1'b0}};
                age_q[i]        <= {AGE_W{1'b0}};
            end
        end else if (clear) begin
            valid_q     <= {TXN_TBL_SIZE{1'b0}};
            alloc_ptr_q <= {IDX_W{1'b0}};
            outstanding_count <= 16'd0;
            for (i = 0; i < TXN_TBL_SIZE; i = i + 1) begin
                age_q[i]        <= {AGE_W{1'b0}};
            end
        end else begin
            for (i = 0; i < TXN_TBL_SIZE; i = i + 1) begin
                if (valid_q[i] && (age_q[i] != TIMEOUT_VALUE))
                    age_q[i] <= age_q[i] + 1'b1;
            end

            case ({alloc_fire, complete_fire})
                2'b10: outstanding_count <= outstanding_count + 16'd1;
                2'b01: outstanding_count <= outstanding_count - 16'd1;
                default: outstanding_count <= outstanding_count;
            endcase

            if (alloc_fire) begin
                valid_q[alloc_ptr_q]      <= 1'b1;
                age_q[alloc_ptr_q]        <= {AGE_W{1'b0}};

                if (alloc_ptr_q == TXN_TBL_SIZE-1)
                    alloc_ptr_q <= {IDX_W{1'b0}};
                else
                    alloc_ptr_q <= alloc_ptr_q + 1'b1;
            end

            if (complete_fire) begin
                valid_q[complete_idx]      <= 1'b0;
                age_q[complete_idx]        <= {AGE_W{1'b0}};
                epoch_q[complete_idx]      <= epoch_q[complete_idx] + 1'b1;
            end

            if (touch_fire && !complete_fire) begin
                age_q[touch_idx] <= {AGE_W{1'b0}};
            end
        end
    end
endmodule
