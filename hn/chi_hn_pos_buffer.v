`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_hn_pos_buffer
// Purpose: Multi-slot HN-F POS queue with per-line metadata and address-lock
//          visibility. It preserves oldest-ready issue while exposing stalls
//          caused by full slots or an active same-line transaction. Upstream
//          ready depends only on currently-free slots, not the same-cycle pop,
//          to keep HN-F request acceptance out of combinational timing loops.
// -----------------------------------------------------------------------------
module chi_hn_pos_buffer #(
    parameter FLIT_W     = 128,
    parameter DEPTH      = 16,
    parameter ACTIVE_SLOTS = 1,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter LINE_LSB   = 6
)(
    input                  clk,
    input                  rstn,
    input                  clear,
    input                  in_valid,
    output                 in_ready,
    input      [FLIT_W-1:0] in_flit,
    output                 out_valid,
    input                  out_ready,
    output     [FLIT_W-1:0] out_flit,
    output                 pop_pulse,
    output     [15:0]      used_count,
    input                  active_valid,
    input      [ADDR_WIDTH-1:0] active_addr,
    input      [ACTIVE_SLOTS-1:0] active_valid_vec,
    input      [ACTIVE_SLOTS*ADDR_WIDTH-1:0] active_addr_flat,
    output                 addr_lock_stall,
    output                 full_stall
);
    `include "../common/chi_clog2.vh"
    localparam IDX_W = (DEPTH <= 2) ? 1 : `CHI_CLOG2(DEPTH);
    localparam LINE_W = ADDR_WIDTH - LINE_LSB;
    localparam AGE_W = 16;

    reg                  valid_q [0:DEPTH-1];
    reg [FLIT_W-1:0]     flit_q [0:DEPTH-1];
    reg [AGE_W-1:0]      age_q [0:DEPTH-1];
    reg [AGE_W-1:0]      alloc_age_q;
    reg                  out_valid_q;
    reg [FLIT_W-1:0]     out_flit_q;
    reg [IDX_W-1:0]      out_idx_q;
    reg                  sel_valid_q;
    reg [IDX_W-1:0]      sel_idx_q;
    reg [ACTIVE_SLOTS-1:0] active_valid_vec_q;
    reg [ACTIVE_SLOTS*LINE_W-1:0] active_line_flat_q;

    reg                  free_valid_r;
    reg [IDX_W-1:0]      free_idx_r;
    reg                  select_valid_r;
    reg [IDX_W-1:0]      select_idx_r;
    reg [AGE_W-1:0]      select_age_r;
    reg [15:0]           used_count_r;
    reg                  addr_lock_stall_r;
    reg                  slot_blocked_r;
    reg                  older_same_line_r;
    reg [LINE_W-1:0]     scan_line_r;
    reg [LINE_W-1:0]     other_line_r;
    reg                  active_vec_blocked_r;
    integer              scan_i;
    integer              other_i;
    integer              active_i;
    integer              active_cap_i;
    integer              reset_i;

    wire push = in_valid && in_ready;
    wire pop = out_valid_q && out_ready;
    wire [IDX_W-1:0] alloc_idx = free_idx_r;
    wire [LINE_W-1:0] active_line = active_addr[ADDR_WIDTH-1:LINE_LSB];

    function age_before;
        input [AGE_W-1:0] lhs;
        input [AGE_W-1:0] rhs;
        begin
            age_before = (lhs < rhs);
        end
    endfunction

    assign in_ready = free_valid_r;
    assign out_valid = out_valid_q;
    assign out_flit = out_flit_q;
    assign pop_pulse = pop;
    assign used_count = used_count_r;
    assign addr_lock_stall = addr_lock_stall_r;
    assign full_stall = in_valid && !in_ready;

    always @(*) begin
        free_valid_r = 1'b0;
        free_idx_r = {IDX_W{1'b0}};
        select_valid_r = 1'b0;
        select_idx_r = {IDX_W{1'b0}};
        select_age_r = {AGE_W{1'b1}};
        used_count_r = 16'd0;
        addr_lock_stall_r = 1'b0;

        for (scan_i = 0; scan_i < DEPTH; scan_i = scan_i + 1) begin
            if (valid_q[scan_i]) begin
                used_count_r = used_count_r + 1'b1;
                scan_line_r = flit_q[scan_i][ADDR_WIDTH-1:LINE_LSB];
                older_same_line_r = 1'b0;

                for (other_i = 0; other_i < DEPTH; other_i = other_i + 1) begin
                    other_line_r = flit_q[other_i][ADDR_WIDTH-1:LINE_LSB];
                    if (valid_q[other_i] &&
                        (other_line_r == scan_line_r) &&
                        age_before(age_q[other_i], age_q[scan_i]))
                        older_same_line_r = 1'b1;
                end

                active_vec_blocked_r = 1'b0;
                for (active_i = 0; active_i < ACTIVE_SLOTS; active_i = active_i + 1) begin
                    if (active_valid_vec_q[active_i] &&
                        (scan_line_r ==
                         active_line_flat_q[active_i*LINE_W +: LINE_W]))
                        active_vec_blocked_r = 1'b1;
                end

                slot_blocked_r = older_same_line_r ||
                                 (active_valid && (scan_line_r == active_line)) ||
                                 active_vec_blocked_r;
                if (slot_blocked_r)
                    addr_lock_stall_r = 1'b1;

                if (!slot_blocked_r &&
                    (!select_valid_r || age_before(age_q[scan_i], select_age_r))) begin
                    select_valid_r = 1'b1;
                    select_idx_r = scan_i[IDX_W-1:0];
                    select_age_r = age_q[scan_i];
                end
            end else if (!free_valid_r) begin
                free_valid_r = 1'b1;
                free_idx_r = scan_i[IDX_W-1:0];
            end
        end
    end

    always @(posedge clk) begin
        if (rstn && !clear && push) begin
            flit_q[alloc_idx] <= in_flit;
            age_q[alloc_idx] <= alloc_age_q;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            active_valid_vec_q <= {ACTIVE_SLOTS{1'b0}};
            active_line_flat_q <= {(ACTIVE_SLOTS*LINE_W){1'b0}};
        end else if (clear) begin
            active_valid_vec_q <= {ACTIVE_SLOTS{1'b0}};
            active_line_flat_q <= {(ACTIVE_SLOTS*LINE_W){1'b0}};
        end else begin
            active_valid_vec_q <= active_valid_vec;
            for (active_cap_i = 0; active_cap_i < ACTIVE_SLOTS; active_cap_i = active_cap_i + 1) begin
                active_line_flat_q[active_cap_i*LINE_W +: LINE_W] <=
                    active_addr_flat[active_cap_i*ADDR_WIDTH + LINE_LSB +: LINE_W];
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            alloc_age_q <= {AGE_W{1'b0}};
            out_valid_q <= 1'b0;
            out_flit_q <= {FLIT_W{1'b0}};
            out_idx_q <= {IDX_W{1'b0}};
            sel_valid_q <= 1'b0;
            sel_idx_q <= {IDX_W{1'b0}};
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1) begin
                valid_q[reset_i] <= 1'b0;
            end
        end else if (clear) begin
            alloc_age_q <= {AGE_W{1'b0}};
            out_valid_q <= 1'b0;
            out_flit_q <= {FLIT_W{1'b0}};
            out_idx_q <= {IDX_W{1'b0}};
            sel_valid_q <= 1'b0;
            sel_idx_q <= {IDX_W{1'b0}};
            for (reset_i = 0; reset_i < DEPTH; reset_i = reset_i + 1)
                valid_q[reset_i] <= 1'b0;
        end else begin
            if (pop)
                valid_q[out_idx_q] <= 1'b0;

            if (out_valid_q) begin
                if (pop)
                    out_valid_q <= 1'b0;
            end else if (sel_valid_q) begin
                out_valid_q <= 1'b1;
                out_flit_q <= flit_q[sel_idx_q];
                out_idx_q <= sel_idx_q;
                sel_valid_q <= 1'b0;
            end else if (select_valid_r) begin
                sel_valid_q <= 1'b1;
                sel_idx_q <= select_idx_r;
            end

            if (push) begin
                valid_q[alloc_idx] <= 1'b1;
                alloc_age_q <= alloc_age_q + 1'b1;
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && full_stall) begin
            $display("chi_hn_pos_buffer full stall");
        end
    end
    // synthesis translate_on
endmodule
