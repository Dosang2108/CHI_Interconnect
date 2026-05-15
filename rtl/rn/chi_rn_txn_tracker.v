`include "chi_defs.vh"

module chi_rn_txn_tracker #(
    parameter TXN_ID_W     = `CHI_DEFAULT_TXN_ID_W,
    parameter ADDR_WIDTH   = `CHI_DEFAULT_ADDR_W,
    parameter DBID_W       = `CHI_DEFAULT_DBID_W,
    parameter TXN_TBL_SIZE = 64,
    parameter TIMEOUT_CYCLES = 1024
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    alloc_valid,
    output                   alloc_ready,
    output     [TXN_ID_W-1:0] alloc_txn_id,
    input      [5:0]         alloc_opcode,
    input      [ADDR_WIDTH-1:0] alloc_addr,

    input                    dbid_update_valid,
    input      [TXN_ID_W-1:0] dbid_update_txn_id,
    input      [DBID_W-1:0]  dbid_update_value,
    output                   dbid_match_valid,

    input                    complete_valid,
    input      [TXN_ID_W-1:0] complete_txn_id,
    output                   complete_match_valid,

    input                    lookup_valid,
    input      [TXN_ID_W-1:0] lookup_txn_id,
    output                   lookup_match,

    output reg               timeout_valid,
    output reg [TXN_ID_W-1:0] timeout_txn_id,
    output reg [15:0]        outstanding_count,
    output                   table_full
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

    localparam IDX_W = (TXN_TBL_SIZE <= 2) ? 1 : clog2(TXN_TBL_SIZE);
    localparam EPOCH_W = TXN_ID_W - IDX_W;
    localparam AGE_W = (TIMEOUT_CYCLES <= 2) ? 1 : clog2(TIMEOUT_CYCLES + 1);
    localparam [AGE_W-1:0] TIMEOUT_VALUE = TIMEOUT_CYCLES;

    reg [TXN_TBL_SIZE-1:0] valid_q;
    reg [IDX_W-1:0]        alloc_ptr_q;
    reg [EPOCH_W-1:0]      epoch_q [0:TXN_TBL_SIZE-1];
    reg [AGE_W-1:0]        age_q   [0:TXN_TBL_SIZE-1];
    reg [5:0]              opcode_q [0:TXN_TBL_SIZE-1];
    reg [ADDR_WIDTH-1:0]   addr_q   [0:TXN_TBL_SIZE-1];
    reg [DBID_W-1:0]       dbid_q   [0:TXN_TBL_SIZE-1];
    reg                    dbid_valid_q [0:TXN_TBL_SIZE-1];

    wire [IDX_W-1:0] complete_idx = complete_txn_id[IDX_W-1:0];
    wire [IDX_W-1:0] dbid_idx     = dbid_update_txn_id[IDX_W-1:0];
    wire [IDX_W-1:0] lookup_idx   = lookup_txn_id[IDX_W-1:0];
    wire [EPOCH_W-1:0] complete_epoch = complete_txn_id[TXN_ID_W-1:IDX_W];
    wire [EPOCH_W-1:0] dbid_epoch     = dbid_update_txn_id[TXN_ID_W-1:IDX_W];
    wire [EPOCH_W-1:0] lookup_epoch   = lookup_txn_id[TXN_ID_W-1:IDX_W];
    wire complete_match = valid_q[complete_idx] &&
                          (complete_epoch == epoch_q[complete_idx]);
    wire dbid_match = valid_q[dbid_idx] &&
                      (dbid_epoch == epoch_q[dbid_idx]);
    wire lookup_match_raw = valid_q[lookup_idx] &&
                            (lookup_epoch == epoch_q[lookup_idx]);
    wire alloc_fire = alloc_valid && alloc_ready;
    wire complete_fire = complete_valid && complete_match;

    integer i;
    integer t;

    assign alloc_ready  = !valid_q[alloc_ptr_q];
    assign alloc_txn_id = {epoch_q[alloc_ptr_q], alloc_ptr_q};
    assign table_full   = &valid_q;
    assign dbid_match_valid = dbid_update_valid && dbid_match;
    assign complete_match_valid = complete_valid && complete_match;
    assign lookup_match = lookup_valid && lookup_match_raw;

    always @(*) begin
        timeout_valid = 1'b0;
        timeout_txn_id = {TXN_ID_W{1'b0}};
        for (t = 0; t < TXN_TBL_SIZE; t = t + 1) begin
            if (!timeout_valid && valid_q[t] && (age_q[t] >= TIMEOUT_VALUE)) begin
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
                opcode_q[i]     <= 6'd0;
                addr_q[i]       <= {ADDR_WIDTH{1'b0}};
                dbid_q[i]       <= {DBID_W{1'b0}};
                dbid_valid_q[i] <= 1'b0;
            end
        end else if (clear) begin
            valid_q     <= {TXN_TBL_SIZE{1'b0}};
            alloc_ptr_q <= {IDX_W{1'b0}};
            outstanding_count <= 16'd0;
            for (i = 0; i < TXN_TBL_SIZE; i = i + 1) begin
                age_q[i]        <= {AGE_W{1'b0}};
                dbid_valid_q[i] <= 1'b0;
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
                opcode_q[alloc_ptr_q]     <= alloc_opcode;
                addr_q[alloc_ptr_q]       <= alloc_addr;
                dbid_valid_q[alloc_ptr_q] <= 1'b0;

                if (alloc_ptr_q == TXN_TBL_SIZE-1)
                    alloc_ptr_q <= {IDX_W{1'b0}};
                else
                    alloc_ptr_q <= alloc_ptr_q + 1'b1;
            end

            if (dbid_update_valid && dbid_match) begin
                dbid_q[dbid_idx]       <= dbid_update_value;
                dbid_valid_q[dbid_idx] <= 1'b1;
            end

            if (complete_fire) begin
                valid_q[complete_idx]      <= 1'b0;
                age_q[complete_idx]        <= {AGE_W{1'b0}};
                dbid_valid_q[complete_idx] <= 1'b0;
                epoch_q[complete_idx]      <= epoch_q[complete_idx] + 1'b1;
            end
        end
    end
endmodule
