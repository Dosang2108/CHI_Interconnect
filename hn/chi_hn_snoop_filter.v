`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_hn_snoop_filter
// Purpose: Set-associative HN directory with synchronous way-banked lookup,
//          serialized update, PLRU replacement, and BackInv victim reporting.
// -----------------------------------------------------------------------------
module chi_hn_snoop_filter #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter ENTRIES    = `CHI_DEFAULT_SF_ENTRIES,
    parameter WAYS       = 4
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    lookup_valid,
    output                   lookup_ready,
    input      [ADDR_WIDTH-1:0] lookup_addr,
    output                   lookup_result_valid,
    output                   lookup_hit,
    output     [1:0]         lookup_state,
    output     [NUM_RN-1:0]  lookup_sharer_vec,

    input                    update_valid,
    output                   update_ready,
    input      [ADDR_WIDTH-1:0] update_addr,
    input      [1:0]         update_state,
    input      [NUM_RN-1:0]  update_sharer_vec,
    input                    update_invalidate,

    output                   backinv_valid,
    output     [ADDR_WIDTH-1:0] backinv_addr,
    output     [NUM_RN-1:0]  backinv_sharer_vec
);
    `include "../common/chi_clog2.vh"

    localparam SETS = ENTRIES / WAYS;
    localparam SET_W = (SETS <= 2) ? 1 : `CHI_CLOG2(SETS);
    localparam WAY_W = (WAYS <= 2) ? 1 : `CHI_CLOG2(WAYS);
    localparam TAG_W = (ADDR_WIDTH > (SET_W + 6)) ?
                       (ADDR_WIDTH - SET_W - 6) : 1;
    localparam META_W = TAG_W + 2 + NUM_RN;
    localparam META_SHARER_LSB = 0;
    localparam META_STATE_LSB  = NUM_RN;
    localparam META_TAG_LSB    = NUM_RN + 2;

    wire [SET_W-1:0] lookup_set = lookup_addr[6 +: SET_W];
    wire [SET_W-1:0] update_set = update_addr[6 +: SET_W];
    wire [TAG_W-1:0] lookup_tag = lookup_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [TAG_W-1:0] update_tag = update_addr[ADDR_WIDTH-1 -: TAG_W];

    reg                  op_valid_q;
    reg                  op_data_valid_q;
    reg                  op_is_update_q;
    reg [SET_W-1:0]      op_set_q;
    reg [TAG_W-1:0]      op_tag_q;
    reg [1:0]            op_update_state_q;
    reg [NUM_RN-1:0]     op_update_sharer_vec_q;
    reg                  op_update_invalidate_q;

    wire                 update_fire = update_valid && update_ready;
    wire                 lookup_fire = lookup_valid && lookup_ready;
    wire                 op_fire = update_fire || lookup_fire;
    wire                 op_busy = op_valid_q || op_data_valid_q;
    wire                 op_is_update_next = update_fire;
    wire [SET_W-1:0]     op_set_next = update_fire ? update_set : lookup_set;
    wire [TAG_W-1:0]     op_tag_next = update_fire ? update_tag : lookup_tag;

    wire [WAYS-1:0]      rd_valid_vec;
    wire [WAYS*TAG_W-1:0] rd_tag_flat;
    wire [WAYS*2-1:0]    rd_state_flat;
    wire [WAYS*NUM_RN-1:0] rd_sharer_flat;

    reg                  op_hit_r;
    reg [WAY_W-1:0]      op_hit_way_r;
    reg                  op_free_r;
    reg [WAY_W-1:0]      op_free_way_r;
    reg [WAY_W-1:0]      op_victim_way_r;
    reg [WAY_W-1:0]      op_update_way_r;
    reg [1:0]            op_hit_state_r;
    reg [NUM_RN-1:0]     op_hit_sharer_vec_r;
    reg [TAG_W-1:0]      op_victim_tag_r;
    reg [NUM_RN-1:0]     op_victim_sharer_vec_r;

    reg                  result_valid_q;
    reg                  result_hit_q;
    reg [1:0]            result_state_q;
    reg [NUM_RN-1:0]     result_sharer_vec_q;
    reg                  result_backinv_valid_q;
    reg [ADDR_WIDTH-1:0] result_backinv_addr_q;
    reg [NUM_RN-1:0]     result_backinv_sharer_vec_q;

    reg [2:0]            plru_q [0:SETS-1];

    integer scan_i;
    integer set_i;
    genvar  way_g;

    assign update_ready = !op_busy;
    assign lookup_ready = !op_busy && !update_valid;

    assign lookup_result_valid = result_valid_q;
    assign lookup_hit = result_valid_q && result_hit_q;
    assign lookup_state = lookup_hit ? result_state_q : 2'b00;
    assign lookup_sharer_vec = lookup_hit ? result_sharer_vec_q :
                                            {NUM_RN{1'b0}};
    assign backinv_valid = result_valid_q && result_backinv_valid_q;
    assign backinv_addr = result_backinv_addr_q;
    assign backinv_sharer_vec = result_backinv_sharer_vec_q;

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
            case (way[1:0])
                2'b00: plru_touch_4way = {1'b1, 1'b1, plru[0]};
                2'b01: plru_touch_4way = {1'b1, 1'b0, plru[0]};
                2'b10: plru_touch_4way = {1'b0, plru[1], 1'b1};
                2'b11: plru_touch_4way = {1'b0, plru[1], 1'b0};
            endcase
        end
    endfunction

    generate
        for (way_g = 0; way_g < WAYS; way_g = way_g + 1) begin : gen_way_ram
            localparam [WAY_W-1:0] WAY_ID = way_g;

            reg                  valid_mem [0:SETS-1];
            (* ram_style = "distributed" *) reg [META_W-1:0] meta_mem [0:SETS-1];

            reg                  rd_valid_q;
            reg [META_W-1:0]     rd_meta_q;

            integer              reset_i;

            assign rd_valid_vec[way_g] = rd_valid_q;
            assign rd_tag_flat[way_g*TAG_W +: TAG_W] =
                rd_meta_q[META_TAG_LSB +: TAG_W];
            assign rd_state_flat[way_g*2 +: 2] =
                rd_meta_q[META_STATE_LSB +: 2];
            assign rd_sharer_flat[way_g*NUM_RN +: NUM_RN] =
                rd_meta_q[META_SHARER_LSB +: NUM_RN];

            always @(posedge clk) begin
                if (!clear) begin
                    if (op_valid_q)
                        rd_meta_q <= meta_mem[op_set_q];

                    if (op_data_valid_q && op_is_update_q &&
                        (op_update_way_r == WAY_ID) &&
                        !op_update_invalidate_q) begin
                        meta_mem[op_set_q] <= {
                            op_tag_q,
                            op_update_state_q,
                            op_update_sharer_vec_q
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
                    if (op_valid_q)
                        rd_valid_q <= valid_mem[op_set_q];

                    if (op_data_valid_q && op_is_update_q &&
                        (op_update_way_r == WAY_ID)) begin
                        if (op_update_invalidate_q) begin
                            if (op_hit_r)
                                valid_mem[op_set_q] <= 1'b0;
                        end else begin
                            valid_mem[op_set_q] <=
                                (op_update_sharer_vec_q != {NUM_RN{1'b0}});
                        end
                    end
                end
            end
        end
    endgenerate

    always @(*) begin
        op_hit_r = 1'b0;
        op_hit_way_r = {WAY_W{1'b0}};
        op_free_r = 1'b0;
        op_free_way_r = {WAY_W{1'b0}};
        op_hit_state_r = 2'b00;
        op_hit_sharer_vec_r = {NUM_RN{1'b0}};

        for (scan_i = 0; scan_i < WAYS; scan_i = scan_i + 1) begin
            if (!op_hit_r &&
                rd_valid_vec[scan_i] &&
                (rd_tag_flat[scan_i*TAG_W +: TAG_W] == op_tag_q)) begin
                op_hit_r = 1'b1;
                op_hit_way_r = scan_i[WAY_W-1:0];
                op_hit_state_r = rd_state_flat[scan_i*2 +: 2];
                op_hit_sharer_vec_r =
                    rd_sharer_flat[scan_i*NUM_RN +: NUM_RN];
            end

            if (!op_free_r && !rd_valid_vec[scan_i]) begin
                op_free_r = 1'b1;
                op_free_way_r = scan_i[WAY_W-1:0];
            end
        end
    end

    always @(*) begin
        op_victim_way_r = plru_victim_4way(plru_q[op_set_q]);
        op_update_way_r = op_hit_r ? op_hit_way_r :
                          (op_free_r ? op_free_way_r : op_victim_way_r);
        op_victim_tag_r =
            rd_tag_flat[op_victim_way_r*TAG_W +: TAG_W];
        op_victim_sharer_vec_r =
            rd_sharer_flat[op_victim_way_r*NUM_RN +: NUM_RN];
    end

    always @(posedge clk) begin
        if (rstn && !clear) begin
            if (op_fire) begin
                op_is_update_q <= op_is_update_next;
                op_set_q <= op_set_next;
                op_tag_q <= op_tag_next;
                op_update_state_q <= update_state;
                op_update_sharer_vec_q <= update_sharer_vec;
                op_update_invalidate_q <= update_invalidate;
            end

            if (op_data_valid_q && !op_is_update_q) begin
                result_hit_q <= op_hit_r;
                result_state_q <= op_hit_state_r;
                result_sharer_vec_q <= op_hit_sharer_vec_r;
                result_backinv_valid_q <=
                    !op_hit_r &&
                    !op_free_r &&
                    (op_victim_sharer_vec_r != {NUM_RN{1'b0}});
                result_backinv_addr_q <=
                    {op_victim_tag_r, op_set_q, 6'b0};
                result_backinv_sharer_vec_q <= op_victim_sharer_vec_r;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            op_valid_q <= 1'b0;
            op_data_valid_q <= 1'b0;
            result_valid_q <= 1'b0;
            for (set_i = 0; set_i < SETS; set_i = set_i + 1)
                plru_q[set_i] <= 3'b000;
        end else if (clear) begin
            op_valid_q <= 1'b0;
            op_data_valid_q <= 1'b0;
            result_valid_q <= 1'b0;
            for (set_i = 0; set_i < SETS; set_i = set_i + 1)
                plru_q[set_i] <= 3'b000;
        end else begin
            op_valid_q <= op_fire;
            op_data_valid_q <= op_valid_q;

            if (lookup_fire)
                result_valid_q <= 1'b0;

            if (op_data_valid_q) begin
                if (op_is_update_q) begin
                    if (!op_update_invalidate_q &&
                        (op_update_sharer_vec_q != {NUM_RN{1'b0}}))
                        plru_q[op_set_q] <=
                            plru_touch_4way(plru_q[op_set_q],
                                            op_update_way_r);
                end else begin
                    result_valid_q <= 1'b1;
                    if (op_hit_r)
                        plru_q[op_set_q] <=
                            plru_touch_4way(plru_q[op_set_q], op_hit_way_r);
                end
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && ((WAYS != 4) || ((ENTRIES % WAYS) != 0))) begin
            $display("chi_hn_snoop_filter requires WAYS=4 and divisible ENTRIES");
            $stop;
        end

        if (rstn && op_data_valid_q && op_is_update_q &&
            !op_update_invalidate_q && !op_hit_r && !op_free_r &&
            (op_victim_sharer_vec_r != {NUM_RN{1'b0}})) begin
            $display("chi_hn_snoop_filter update requires back-invalidate first");
            $stop;
        end
    end
    // synthesis translate_on
endmodule
