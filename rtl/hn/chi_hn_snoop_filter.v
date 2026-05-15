`include "chi_defs.vh"

module chi_hn_snoop_filter #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter ENTRIES    = 1024
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
    input                    update_invalidate
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

    localparam INDEX_W = (ENTRIES <= 2) ? 1 : clog2(ENTRIES);
    localparam TAG_W   = (ADDR_WIDTH > (INDEX_W + 6)) ? (ADDR_WIDTH - INDEX_W - 6) : 1;

    wire [INDEX_W-1:0] lookup_index = lookup_addr[6 +: INDEX_W];
    wire [INDEX_W-1:0] update_index = update_addr[6 +: INDEX_W];
    wire [TAG_W-1:0]   lookup_tag   = lookup_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [TAG_W-1:0]   update_tag   = update_addr[ADDR_WIDTH-1 -: TAG_W];

    reg                valid_mem [0:ENTRIES-1];
    reg [TAG_W-1:0]    tag_mem   [0:ENTRIES-1];
    reg [1:0]          state_mem [0:ENTRIES-1];
    reg [NUM_RN-1:0]   sharer_mem [0:ENTRIES-1];

    integer i;

    assign lookup_hit = lookup_valid && valid_mem[lookup_index] &&
                        (tag_mem[lookup_index] == lookup_tag);
    assign lookup_state = lookup_hit ? state_mem[lookup_index] : 2'b00;
    assign lookup_sharer_vec = lookup_hit ? sharer_mem[lookup_index] : {NUM_RN{1'b0}};

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid_mem[i]  <= 1'b0;
                tag_mem[i]    <= {TAG_W{1'b0}};
                state_mem[i]  <= 2'b00;
                sharer_mem[i] <= {NUM_RN{1'b0}};
            end
        end else if (clear) begin
            for (i = 0; i < ENTRIES; i = i + 1)
                valid_mem[i] <= 1'b0;
        end else if (update_valid) begin
            if (update_invalidate) begin
                valid_mem[update_index]  <= 1'b0;
                state_mem[update_index]  <= 2'b00;
                sharer_mem[update_index] <= {NUM_RN{1'b0}};
            end else begin
                valid_mem[update_index]  <= 1'b1;
                tag_mem[update_index]    <= update_tag;
                state_mem[update_index]  <= update_state;
                sharer_mem[update_index] <= update_sharer_vec;
            end
        end
    end
endmodule
