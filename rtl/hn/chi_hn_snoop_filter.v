`include "../common/chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_hn_snoop_filter
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_hn_snoop_filter #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter ENTRIES    = 1024,
    parameter WAYS       = 4
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    lookup_valid,
    input      [ADDR_WIDTH-1:0] lookup_addr,
    output                   lookup_hit,
    output     [1:0]         lookup_state,
    output     [NUM_RN-1:0]  lookup_sharer_vec,

    input                    update_valid,
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
    localparam TAG_W = (ADDR_WIDTH > (SET_W + 6)) ? (ADDR_WIDTH - SET_W - 6) : 1;

    wire [SET_W-1:0] lookup_set = lookup_addr[6 +: SET_W];
    wire [SET_W-1:0] update_set = update_addr[6 +: SET_W];
    wire [TAG_W-1:0] lookup_tag = lookup_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [TAG_W-1:0] update_tag = update_addr[ADDR_WIDTH-1 -: TAG_W];

    reg                valid_mem [0:ENTRIES-1];
    (* ram_style = "block" *) reg [TAG_W-1:0] tag_mem [0:ENTRIES-1];
    (* ram_style = "block" *) reg [1:0] state_mem [0:ENTRIES-1];
    (* ram_style = "block" *) reg [NUM_RN-1:0] sharer_mem [0:ENTRIES-1];
    reg [WAY_W-1:0]    victim_way_q [0:SETS-1];

    reg                lookup_hit_r;
    reg [WAY_W-1:0]    lookup_way_r;
    reg [1:0]          lookup_state_r;
    reg [NUM_RN-1:0]   lookup_sharer_vec_r;
    reg                lookup_free_r;

    reg                update_hit_r;
    reg [WAY_W-1:0]    update_hit_way_r;
    reg                update_free_r;
    reg [WAY_W-1:0]    update_free_way_r;
    reg [WAY_W-1:0]    update_way_r;
    reg                backinv_valid_r;
    reg [ADDR_WIDTH-1:0] backinv_addr_r;
    reg [NUM_RN-1:0]   backinv_sharer_vec_r;

    integer set_i;
    integer way_i;
    integer lookup_scan_i;
    integer update_scan_i;
    integer lookup_scan_entry_i;
    integer update_scan_entry_i;
    integer victim_lookup_entry_i;
    integer victim_update_entry_i;
    integer victim_entry_i;

    assign lookup_hit = lookup_valid && lookup_hit_r;
    assign lookup_state = lookup_hit ? lookup_state_r : 2'b00;
    assign lookup_sharer_vec = lookup_hit ? lookup_sharer_vec_r : {NUM_RN{1'b0}};
    assign backinv_valid = backinv_valid_r;
    assign backinv_addr = backinv_addr_r;
    assign backinv_sharer_vec = backinv_sharer_vec_r;

    always @(*) begin
        lookup_hit_r = 1'b0;
        lookup_way_r = {WAY_W{1'b0}};
        lookup_state_r = 2'b00;
        lookup_sharer_vec_r = {NUM_RN{1'b0}};
        lookup_free_r = 1'b0;

        for (lookup_scan_i = 0; lookup_scan_i < WAYS; lookup_scan_i = lookup_scan_i + 1) begin
            lookup_scan_entry_i = (lookup_set * WAYS) + lookup_scan_i;
            if (!lookup_hit_r &&
                valid_mem[lookup_scan_entry_i] &&
                (tag_mem[lookup_scan_entry_i] == lookup_tag)) begin
                lookup_hit_r = 1'b1;
                lookup_way_r = lookup_scan_i;
                lookup_state_r = state_mem[lookup_scan_entry_i];
                lookup_sharer_vec_r = sharer_mem[lookup_scan_entry_i];
            end

            if (!lookup_free_r && !valid_mem[lookup_scan_entry_i])
                lookup_free_r = 1'b1;
        end
    end

    always @(*) begin
        update_hit_r = 1'b0;
        update_hit_way_r = {WAY_W{1'b0}};
        update_free_r = 1'b0;
        update_free_way_r = {WAY_W{1'b0}};

        for (update_scan_i = 0; update_scan_i < WAYS; update_scan_i = update_scan_i + 1) begin
            update_scan_entry_i = (update_set * WAYS) + update_scan_i;
            if (!update_hit_r &&
                valid_mem[update_scan_entry_i] &&
                (tag_mem[update_scan_entry_i] == update_tag)) begin
                update_hit_r = 1'b1;
                update_hit_way_r = update_scan_i;
            end

            if (!update_free_r && !valid_mem[update_scan_entry_i]) begin
                update_free_r = 1'b1;
                update_free_way_r = update_scan_i;
            end
        end
    end

    always @(*) begin
        update_way_r = update_hit_r ? update_hit_way_r :
                       (update_free_r ? update_free_way_r :
                        victim_way_q[update_set]);
        victim_lookup_entry_i = (lookup_set * WAYS) + victim_way_q[lookup_set];
        victim_update_entry_i = (update_set * WAYS) + victim_way_q[update_set];
        victim_entry_i = update_valid ? victim_update_entry_i : victim_lookup_entry_i;
        backinv_valid_r = update_valid ?
                          (!update_invalidate &&
                           !update_hit_r &&
                           !update_free_r &&
                           valid_mem[victim_update_entry_i] &&
                           (sharer_mem[victim_update_entry_i] != {NUM_RN{1'b0}})) :
                          (lookup_valid &&
                           !lookup_hit_r &&
                           !lookup_free_r &&
                           valid_mem[victim_lookup_entry_i] &&
                           (sharer_mem[victim_lookup_entry_i] != {NUM_RN{1'b0}}));
        backinv_addr_r = update_valid ?
                         {tag_mem[victim_entry_i],
                          update_set,
                          6'b0} :
                         {tag_mem[victim_entry_i],
                          lookup_set,
                          6'b0};
        backinv_sharer_vec_r = sharer_mem[victim_entry_i];
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (set_i = 0; set_i < SETS; set_i = set_i + 1) begin
                victim_way_q[set_i] <= {WAY_W{1'b0}};
                for (way_i = 0; way_i < WAYS; way_i = way_i + 1) begin
                    valid_mem[(set_i * WAYS) + way_i] <= 1'b0;
                end
            end
        end else if (clear) begin
            for (set_i = 0; set_i < SETS; set_i = set_i + 1) begin
                victim_way_q[set_i] <= {WAY_W{1'b0}};
                for (way_i = 0; way_i < WAYS; way_i = way_i + 1) begin
                    valid_mem[(set_i * WAYS) + way_i] <= 1'b0;
                end
            end
        end else if (update_valid) begin
            if (update_invalidate) begin
                if (update_hit_r) begin
                    valid_mem[(update_set * WAYS) + update_hit_way_r] <= 1'b0;
                end
            end else begin
                valid_mem[(update_set * WAYS) + update_way_r] <=
                    (update_sharer_vec != {NUM_RN{1'b0}});
                tag_mem[(update_set * WAYS) + update_way_r] <= update_tag;
                state_mem[(update_set * WAYS) + update_way_r] <= update_state;
                sharer_mem[(update_set * WAYS) + update_way_r] <= update_sharer_vec;

                if (update_way_r == WAYS-1)
                    victim_way_q[update_set] <= {WAY_W{1'b0}};
                else
                    victim_way_q[update_set] <= update_way_r + 1'b1;
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && update_valid && backinv_valid) begin
            $display("chi_hn_snoop_filter update requires back-invalidate first");
            $stop;
        end
    end
    // synthesis translate_on
endmodule
