`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_hn_llc
// Purpose: Set-associative HN LLC with synchronous way-banked RAM lookup,
//          per-64b SECDED generation/checking, and tree-PLRU replacement.
// -----------------------------------------------------------------------------
module chi_hn_llc #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter LINE_BYTES = 64,
    parameter LINES      = `CHI_DEFAULT_LLC_LINES,
    parameter WAYS       = `CHI_DEFAULT_LLC_WAYS,
    parameter ENABLE_ECC = `CHI_DEFAULT_ENABLE_LLC_ECC
)(
    input                    clk,
    input                    rstn,
    output                   busy,
    input                    clear,

    input                    lookup_valid,
    output                   lookup_ready,
    input      [ADDR_WIDTH-1:0] lookup_addr,
    output                   lookup_result_valid,
    output                   lookup_hit,
    output     [2:0]         lookup_state,
    output     [LINE_BYTES*8-1:0] lookup_data,
    output                   lookup_ecc_single_error,
    output                   lookup_ecc_double_error,

    input                    line_update_valid,
    output                   line_update_ready,
    input      [ADDR_WIDTH-1:0] line_update_addr,
    input      [LINE_BYTES*8-1:0] line_update_data,
    input      [2:0]         line_update_state,

    input                    line_invalidate_valid,
    output                   line_invalidate_ready,
    input      [ADDR_WIDTH-1:0] line_invalidate_addr,

    output                   evict_valid,
    input                    evict_ready,
    output     [ADDR_WIDTH-1:0] evict_addr,
    output     [LINE_BYTES*8-1:0] evict_data,
    output     [2:0]         evict_state
);
    `include "../common/chi_clog2.vh"
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam ECC_CHUNKS = LINE_WIDTH / 64;
    localparam ECC_W = ECC_CHUNKS * 8;
    localparam LINE_OFF_W = `CHI_CLOG2(LINE_BYTES);
    localparam SETS = LINES / WAYS;
    localparam SET_W = (SETS <= 2) ? 1 : `CHI_CLOG2(SETS);
    localparam WAY_W = (WAYS <= 2) ? 1 : `CHI_CLOG2(WAYS);
    localparam TAG_W = ADDR_WIDTH - LINE_OFF_W - SET_W;
    localparam PLRU_W = (WAYS <= 2) ? 1 : (WAYS - 1);
    localparam META_STATE_LSB = 0;
    localparam META_TAG_LSB = 3;
    localparam META_W = TAG_W + 3;

    wire [SET_W-1:0] lookup_set =
        lookup_addr[LINE_OFF_W +: SET_W];
    wire [TAG_W-1:0] lookup_tag =
        lookup_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [SET_W-1:0] update_set =
        line_update_addr[LINE_OFF_W +: SET_W];
    wire [TAG_W-1:0] update_tag =
        line_update_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [SET_W-1:0] inv_set =
        line_invalidate_addr[LINE_OFF_W +: SET_W];
    wire [TAG_W-1:0] inv_tag =
        line_invalidate_addr[ADDR_WIDTH-1 -: TAG_W];

    reg                  lookup_valid_q;
    reg [SET_W-1:0]      lookup_set_q;
    reg [TAG_W-1:0]      lookup_tag_q;
    reg                  update_valid_q;
    reg [SET_W-1:0]      update_set_q;
    reg [TAG_W-1:0]      update_tag_q;
    reg [2:0]            update_state_q;
    reg [LINE_WIDTH-1:0] update_data_q;
    reg [ECC_W-1:0]      update_ecc_q;
    reg                  update_pending_q;
    reg [PLRU_W-1:0]     plru_mem [0:SETS-1];

    reg                  inv_pending_q;
    reg [SET_W-1:0]      inv_pending_set_q;
    reg [TAG_W-1:0]      inv_pending_tag_q;
    reg                  inv_read_q;
    reg [SET_W-1:0]      inv_read_set_q;
    reg [TAG_W-1:0]      inv_read_tag_q;

    wire [WAYS-1:0]      lookup_valid_vec;
    wire [WAYS*TAG_W-1:0] lookup_tag_flat;
    wire [WAYS*3-1:0]    lookup_state_flat;
    wire [WAYS*LINE_WIDTH-1:0] lookup_data_flat;
    wire [WAYS*ECC_W-1:0] lookup_ecc_flat;
    wire [WAYS-1:0]      update_valid_vec;
    wire [WAYS*TAG_W-1:0] update_tag_flat;
    wire [WAYS*3-1:0]    update_state_flat;
    wire [WAYS-1:0]      inv_valid_vec;
    wire [WAYS*TAG_W-1:0] inv_tag_flat;

    reg                  lookup_hit_r;
    reg [WAY_W-1:0]      lookup_way_r;
    reg [2:0]            lookup_state_r;
    reg [LINE_WIDTH-1:0] lookup_data_r;
    reg [ECC_W-1:0]      lookup_ecc_r;

    reg                  update_hit_r;
    reg [WAY_W-1:0]      update_hit_way_r;
    reg                  update_free_r;
    reg [WAY_W-1:0]      update_free_way_r;
    reg [WAY_W-1:0]      update_way_r;
    reg [LINE_WIDTH-1:0] update_victim_data_r;

    reg                  inv_hit_r;
    reg [WAY_W-1:0]      inv_way_r;

    reg                  evict_valid_q;
    reg [ADDR_WIDTH-1:0] evict_addr_q;
    reg [LINE_WIDTH-1:0] evict_data_q;
    reg [2:0]            evict_state_q;

    integer              lookup_scan_i;
    integer              update_scan_i;
    integer              inv_scan_i;
    integer              set_i;
    genvar               way_g;
    genvar               ecc_i;

    wire [ECC_W-1:0]     update_ecc;
    wire [ECC_CHUNKS-1:0] ecc_single_vec;
    wire [ECC_CHUNKS-1:0] ecc_double_vec;
    wire                 lookup_update_bypass;
    wire [LINE_WIDTH-1:0] lookup_data_check;
    wire [ECC_W-1:0]     lookup_ecc_check;
    wire                 line_update_fire;
    wire                 update_commit_fire;
    wire                 evict_fire;
    wire                 lookup_fire;
    wire                 inv_input_read_fire;
    wire                 inv_pending_read_fire;
    wire                 inv_read_fire;
    wire                 inv_capture_pending;
    wire                 inv_pending_slot_available;
    wire                 inv_commit_fire;
    wire [SET_W-1:0]     inv_read_set;
    wire [TAG_W-1:0]     inv_read_tag;
    wire                 ram_read_valid;
    wire [SET_W-1:0]     ram_read_set;
    wire                 update_replaces_valid_dirty;
    wire [TAG_W-1:0]     update_victim_tag_selected;
    wire [2:0]           update_victim_state_selected;
    wire [ADDR_WIDTH-1:0] update_victim_addr;

    function [WAY_W-1:0] plru_victim;
        input [PLRU_W-1:0] plru;
        integer level_i;
        integer node_i;
        reg direction;
        begin
            plru_victim = {WAY_W{1'b0}};
            node_i = 0;
            for (level_i = 0; level_i < WAY_W; level_i = level_i + 1) begin
                direction = plru[node_i];
                plru_victim[WAY_W-1-level_i] = direction;
                node_i = direction ? ((node_i * 2) + 2) :
                                     ((node_i * 2) + 1);
            end
        end
    endfunction

    function [PLRU_W-1:0] plru_touch;
        input [PLRU_W-1:0] plru;
        input [WAY_W-1:0] way;
        integer level_i;
        integer node_i;
        reg direction;
        begin
            plru_touch = plru;
            node_i = 0;
            for (level_i = 0; level_i < WAY_W; level_i = level_i + 1) begin
                direction = way[WAY_W-1-level_i];
                plru_touch[node_i] = ~direction;
                node_i = direction ? ((node_i * 2) + 2) :
                                     ((node_i * 2) + 1);
            end
        end
    endfunction

    assign lookup_update_bypass =
        lookup_valid_q &&
        update_valid_q &&
        (update_state_q != `CHI_STATE_I) &&
        (update_set_q == lookup_set_q) &&
        (update_tag_q == lookup_tag_q);
    assign lookup_data_check = lookup_update_bypass ?
                               update_data_q : lookup_data_r;
    assign lookup_ecc_check = ((ENABLE_ECC != 0) && lookup_update_bypass) ?
                              update_ecc_q : lookup_ecc_r;
    assign lookup_result_valid = lookup_valid_q;
    assign lookup_hit = lookup_valid_q &&
                        (lookup_update_bypass || lookup_hit_r);
    assign lookup_state = lookup_hit ?
                          (lookup_update_bypass ?
                           update_state_q : lookup_state_r) :
                          `CHI_STATE_I;
    assign lookup_data = lookup_hit ? lookup_data_check : {LINE_WIDTH{1'b0}};
    assign lookup_ecc_single_error = lookup_hit && (|ecc_single_vec);
    assign lookup_ecc_double_error = lookup_hit && (|ecc_double_vec);
    assign lookup_ready = !update_pending_q && !inv_pending_q && !inv_read_q;
    assign lookup_fire = lookup_valid && lookup_ready;
    assign line_update_ready = !update_pending_q && !evict_valid_q &&
                               !lookup_valid &&
                               !inv_pending_q && !inv_read_q;
    assign line_update_fire = line_update_valid && line_update_ready;
    assign update_commit_fire = update_pending_q &&
                                (!update_replaces_valid_dirty ||
                                 !evict_valid_q);
    assign evict_fire = evict_valid_q && evict_ready;
    assign inv_input_read_fire =
        line_invalidate_valid && !inv_pending_q &&
        !lookup_valid && !line_update_fire &&
        !update_pending_q && !inv_read_q;
    assign inv_pending_read_fire =
        inv_pending_q && !lookup_valid && !line_update_fire &&
        !update_pending_q && !inv_read_q;
    assign inv_read_fire = inv_input_read_fire || inv_pending_read_fire;
    assign inv_pending_slot_available = !inv_pending_q ||
                                        inv_pending_read_fire;
    assign line_invalidate_ready = inv_pending_slot_available;
    assign inv_capture_pending = line_invalidate_valid &&
                                 !inv_input_read_fire &&
                                 inv_pending_slot_available;
    assign inv_read_set = inv_pending_read_fire ? inv_pending_set_q : inv_set;
    assign inv_read_tag = inv_pending_read_fire ? inv_pending_tag_q : inv_tag;
    assign inv_commit_fire = inv_read_q;
    assign ram_read_valid = lookup_fire || line_update_fire || inv_read_fire;
    assign ram_read_set = line_update_fire ? update_set :
                          (inv_read_fire ? inv_read_set : lookup_set);
    assign update_replaces_valid_dirty =
        !update_hit_r &&
        !update_free_r &&
        update_valid_vec[update_way_r] &&
        ((update_state_flat[update_way_r*3 +: 3] == `CHI_STATE_UD) ||
         (update_state_flat[update_way_r*3 +: 3] == `CHI_STATE_SD));
    assign update_victim_tag_selected =
        update_tag_flat[update_way_r*TAG_W +: TAG_W];
    assign update_victim_state_selected =
        update_state_flat[update_way_r*3 +: 3];
    assign update_victim_addr =
        {{update_victim_tag_selected, update_set_q},
         {LINE_OFF_W{1'b0}}};
    assign evict_valid = evict_valid_q;
    assign evict_addr = evict_addr_q;
    assign evict_data = evict_data_q;
    assign evict_state = evict_state_q;

    generate
        for (way_g = 0; way_g < WAYS; way_g = way_g + 1) begin : gen_way_ram
            localparam [WAY_W-1:0] WAY_ID = way_g;

            reg                  valid_mem [0:SETS-1];
            (* ram_style = "distributed" *) reg [META_W-1:0] meta_mem [0:SETS-1];
            (* ram_style = "block" *) reg [LINE_WIDTH-1:0] data_mem [0:SETS-1];

            reg                  rd_valid_q;
            reg [META_W-1:0]     rd_meta_q;
            reg [LINE_WIDTH-1:0] rd_data_q;
            wire [ECC_W-1:0]     rd_ecc_value;
            integer              reset_i;

            assign lookup_valid_vec[way_g] = rd_valid_q;
            assign lookup_tag_flat[way_g*TAG_W +: TAG_W] =
                rd_meta_q[META_TAG_LSB +: TAG_W];
            assign lookup_state_flat[way_g*3 +: 3] =
                rd_meta_q[META_STATE_LSB +: 3];
            assign lookup_data_flat[way_g*LINE_WIDTH +: LINE_WIDTH] =
                rd_data_q;
            assign lookup_ecc_flat[way_g*ECC_W +: ECC_W] = rd_ecc_value;

            assign update_valid_vec[way_g] = rd_valid_q;
            assign update_tag_flat[way_g*TAG_W +: TAG_W] =
                rd_meta_q[META_TAG_LSB +: TAG_W];
            assign update_state_flat[way_g*3 +: 3] =
                rd_meta_q[META_STATE_LSB +: 3];
            assign inv_valid_vec[way_g] = rd_valid_q;
            assign inv_tag_flat[way_g*TAG_W +: TAG_W] =
                rd_meta_q[META_TAG_LSB +: TAG_W];

            always @(posedge clk) begin
                if (ram_read_valid)
                    rd_meta_q <= meta_mem[ram_read_set];

                if (!clear) begin
                    if (update_commit_fire &&
                        (update_way_r == WAY_ID))
                        meta_mem[update_set_q] <= {
                            update_tag_q,
                            update_state_q
                        };
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

                    if (inv_commit_fire && inv_hit_r &&
                        (inv_way_r == WAY_ID))
                        valid_mem[inv_read_set_q] <= 1'b0;

                    if (update_commit_fire &&
                        (update_way_r == WAY_ID)) begin
                        valid_mem[update_set_q] <=
                            (update_state_q != `CHI_STATE_I);
                    end
                end
            end

            always @(posedge clk) begin
                if (ram_read_valid) begin
                    rd_data_q <= data_mem[ram_read_set];
                end

                if (update_commit_fire &&
                    (update_way_r == WAY_ID)) begin
                    data_mem[update_set_q] <= update_data_q;
                end
            end

            if (ENABLE_ECC != 0) begin : gen_way_ecc_ram
                (* ram_style = "block" *) reg [ECC_W-1:0] ecc_mem [0:SETS-1];
                reg [ECC_W-1:0] rd_ecc_q;

                assign rd_ecc_value = rd_ecc_q;

                always @(posedge clk) begin
                    if (ram_read_valid)
                        rd_ecc_q <= ecc_mem[ram_read_set];

                    if (update_commit_fire &&
                        (update_way_r == WAY_ID))
                        ecc_mem[update_set_q] <= update_ecc_q;
                end
            end else begin : gen_way_ecc_off
                assign rd_ecc_value = {ECC_W{1'b0}};
            end
        end
    endgenerate

    always @(*) begin
        lookup_hit_r = 1'b0;
        lookup_way_r = {WAY_W{1'b0}};
        lookup_state_r = `CHI_STATE_I;
        lookup_data_r = {LINE_WIDTH{1'b0}};
        lookup_ecc_r = {ECC_W{1'b0}};

        for (lookup_scan_i = 0;
             lookup_scan_i < WAYS;
             lookup_scan_i = lookup_scan_i + 1) begin
            if (!lookup_hit_r &&
                lookup_valid_vec[lookup_scan_i] &&
                (lookup_tag_flat[lookup_scan_i*TAG_W +: TAG_W] ==
                 lookup_tag_q)) begin
                lookup_hit_r = 1'b1;
                lookup_way_r = lookup_scan_i[WAY_W-1:0];
                lookup_state_r =
                    lookup_state_flat[lookup_scan_i*3 +: 3];
                lookup_data_r =
                    lookup_data_flat[lookup_scan_i*LINE_WIDTH +:
                                     LINE_WIDTH];
                lookup_ecc_r =
                    lookup_ecc_flat[lookup_scan_i*ECC_W +: ECC_W];
            end
        end
    end

    always @(*) begin
        update_hit_r = 1'b0;
        update_hit_way_r = {WAY_W{1'b0}};
        update_free_r = 1'b0;
        update_free_way_r = {WAY_W{1'b0}};

        for (update_scan_i = 0;
             update_scan_i < WAYS;
             update_scan_i = update_scan_i + 1) begin
            if (!update_hit_r &&
                update_valid_vec[update_scan_i] &&
                (update_tag_flat[update_scan_i*TAG_W +: TAG_W] ==
                 update_tag_q)) begin
                update_hit_r = 1'b1;
                update_hit_way_r = update_scan_i[WAY_W-1:0];
            end

            if (!update_free_r && !update_valid_vec[update_scan_i]) begin
                update_free_r = 1'b1;
                update_free_way_r = update_scan_i[WAY_W-1:0];
            end
        end

        update_way_r = update_hit_r ? update_hit_way_r :
                       (update_free_r ? update_free_way_r :
                        plru_victim(plru_mem[update_set_q]));
    end

    always @(*) begin
        update_victim_data_r = {LINE_WIDTH{1'b0}};
        for (update_scan_i = 0;
             update_scan_i < WAYS;
            update_scan_i = update_scan_i + 1) begin
            if (update_way_r == update_scan_i[WAY_W-1:0])
                update_victim_data_r =
                    lookup_data_flat[update_scan_i*LINE_WIDTH +:
                                     LINE_WIDTH];
        end
    end

    always @(*) begin
        inv_hit_r = 1'b0;
        inv_way_r = {WAY_W{1'b0}};

        for (inv_scan_i = 0;
             inv_scan_i < WAYS;
             inv_scan_i = inv_scan_i + 1) begin
            if (!inv_hit_r &&
                inv_valid_vec[inv_scan_i] &&
                (inv_tag_flat[inv_scan_i*TAG_W +: TAG_W] ==
                 inv_read_tag_q)) begin
                inv_hit_r = 1'b1;
                inv_way_r = inv_scan_i[WAY_W-1:0];
            end
        end
    end

    generate
        if (ENABLE_ECC != 0) begin : gen_llc_ecc_on
            for (ecc_i = 0; ecc_i < ECC_CHUNKS; ecc_i = ecc_i + 1) begin : gen_chunk
                wire [6:0] syndrome_unused;
                wire [6:0] update_syndrome_unused;
                wire       update_single_unused;
                wire       update_double_unused;

                chi_ecc_secded_64 u_update_ecc (
                    .enable(1'b0),
                    .data(line_update_data[ecc_i*64 +: 64]),
                    .ecc_in(8'h00),
                    .ecc_out(update_ecc[ecc_i*8 +: 8]),
                    .syndrome(update_syndrome_unused),
                    .single_error(update_single_unused),
                    .double_error(update_double_unused)
                );

                chi_ecc_secded_64 u_lookup_ecc (
                    .enable(lookup_hit),
                    .data(lookup_data_check[ecc_i*64 +: 64]),
                    .ecc_in(lookup_ecc_check[ecc_i*8 +: 8]),
                    .ecc_out(),
                    .syndrome(syndrome_unused),
                    .single_error(ecc_single_vec[ecc_i]),
                    .double_error(ecc_double_vec[ecc_i])
                );
            end
        end else begin : gen_llc_ecc_off
            assign update_ecc = {ECC_W{1'b0}};
            assign ecc_single_vec = {ECC_CHUNKS{1'b0}};
            assign ecc_double_vec = {ECC_CHUNKS{1'b0}};
        end
    endgenerate

    always @(posedge clk) begin
        if (rstn && !clear) begin
            if (lookup_fire) begin
                lookup_set_q <= lookup_set;
                lookup_tag_q <= lookup_tag;
            end

            if (line_update_fire) begin
                update_set_q <= update_set;
                update_tag_q <= update_tag;
                update_state_q <= line_update_state;
                update_data_q <= line_update_data;
                if (ENABLE_ECC != 0)
                    update_ecc_q <= update_ecc;
            end

            if (inv_read_fire) begin
                inv_read_set_q <= inv_read_set;
                inv_read_tag_q <= inv_read_tag;
            end

            if (inv_capture_pending) begin
                inv_pending_set_q <= inv_set;
                inv_pending_tag_q <= inv_tag;
            end

            if (update_commit_fire && update_replaces_valid_dirty) begin
                evict_addr_q <= update_victim_addr;
                evict_data_q <= update_victim_data_r;
                evict_state_q <= update_victim_state_selected;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            lookup_valid_q <= 1'b0;
            update_valid_q <= 1'b0;
            update_pending_q <= 1'b0;
            inv_pending_q <= 1'b0;
            inv_read_q <= 1'b0;
            evict_valid_q <= 1'b0;
            for (set_i = 0; set_i < SETS; set_i = set_i + 1)
                plru_mem[set_i] <= {PLRU_W{1'b0}};
        end else if (clear) begin
            lookup_valid_q <= 1'b0;
            update_valid_q <= 1'b0;
            update_pending_q <= 1'b0;
            inv_pending_q <= 1'b0;
            inv_read_q <= 1'b0;
            evict_valid_q <= 1'b0;
            for (set_i = 0; set_i < SETS; set_i = set_i + 1)
                plru_mem[set_i] <= {PLRU_W{1'b0}};
        end else begin
            lookup_valid_q <= lookup_fire;

            update_valid_q <= update_commit_fire;
            if (line_update_fire)
                update_pending_q <= 1'b1;

            if (inv_read_fire) begin
                inv_read_q <= 1'b1;
            end else begin
                inv_read_q <= 1'b0;
            end

            if (inv_capture_pending) begin
                inv_pending_q <= 1'b1;
            end else if (inv_pending_read_fire) begin
                inv_pending_q <= 1'b0;
            end

            if (evict_fire)
                evict_valid_q <= 1'b0;

            if (update_commit_fire) begin
                update_pending_q <= 1'b0;
                if (update_replaces_valid_dirty) begin
                    evict_valid_q <= 1'b1;
                end
            end

            if (update_commit_fire &&
                (update_state_q != `CHI_STATE_I)) begin
                plru_mem[update_set_q] <=
                    plru_touch(plru_mem[update_set_q], update_way_r);
            end else if (lookup_valid_q && lookup_hit_r) begin
                plru_mem[lookup_set_q] <=
                    plru_touch(plru_mem[lookup_set_q], lookup_way_r);
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && ((WAYS < 2) ||
            (((1 << WAY_W) != WAYS)) ||
            ((LINES % WAYS) != 0))) begin
            $display("chi_hn_llc invalid set-assoc config LINES=%0d WAYS=%0d",
                     LINES, WAYS);
            $stop;
        end
        if (rstn && lookup_hit && lookup_ecc_double_error) begin
            $display("chi_hn_llc uncorrectable ECC error addr %0h",
                     lookup_addr);
            $stop;
        end
    end
    // synthesis translate_on

    // A lookup, line update, invalidate or eviction is in progress.
    assign busy = lookup_valid_q || update_valid_q || update_pending_q ||
                  inv_pending_q || inv_read_q || evict_valid_q;
endmodule

// -----------------------------------------------------------------------------
// Module: chi_ecc_secded_64
// Purpose: 64-bit SECDED encode/check helper. The checker reports single-bit
//          and double-bit errors; data correction is left to wrapper policy.
// -----------------------------------------------------------------------------
module chi_ecc_secded_64 (
    input         enable,
    input  [63:0] data,
    input  [7:0]  ecc_in,
    output [7:0]  ecc_out,
    output [6:0]  syndrome,
    output        single_error,
    output        double_error
);
    function is_hamming_position;
        input integer pos;
        begin
            is_hamming_position = (pos == 1)  ||
                                  (pos == 2)  ||
                                  (pos == 4)  ||
                                  (pos == 8)  ||
                                  (pos == 16) ||
                                  (pos == 32) ||
                                  (pos == 64);
        end
    endfunction

    function [7:0] encode64;
        input [63:0] din;
        integer pos;
        integer data_i;
        integer parity_i;
        reg bit_value;
        reg [6:0] parity;
        reg overall;
        begin
            parity = 7'b0000000;
            overall = 1'b0;
            data_i = 0;

            for (pos = 1; pos <= 71; pos = pos + 1) begin
                if (!is_hamming_position(pos)) begin
                    bit_value = din[data_i];
                    overall = overall ^ bit_value;
                    for (parity_i = 0; parity_i < 7; parity_i = parity_i + 1) begin
                        if ((pos & (1 << parity_i)) != 0)
                            parity[parity_i] = parity[parity_i] ^ bit_value;
                    end
                    data_i = data_i + 1;
                end
            end

            for (parity_i = 0; parity_i < 7; parity_i = parity_i + 1)
                overall = overall ^ parity[parity_i];

            encode64 = {overall, parity};
        end
    endfunction

    wire [7:0] calc_ecc = encode64(data);
    wire       overall_mismatch = ecc_in[7] ^ calc_ecc[7];

    assign ecc_out = calc_ecc;
    assign syndrome = ecc_in[6:0] ^ calc_ecc[6:0];
    assign single_error = enable && overall_mismatch;
    assign double_error = enable && !overall_mismatch && (syndrome != 7'b0000000);
endmodule
