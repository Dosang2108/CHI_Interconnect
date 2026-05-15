`include "chi_defs.vh"

module chi_hn_llc #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter LINE_BYTES = 64,
    parameter LINES      = 128
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    lookup_valid,
    input      [ADDR_WIDTH-1:0] lookup_addr,
    output                   lookup_hit,
    output     [2:0]         lookup_state,
    output     [LINE_BYTES*8-1:0] lookup_data,

    input                    line_update_valid,
    input      [ADDR_WIDTH-1:0] line_update_addr,
    input      [LINE_BYTES*8-1:0] line_update_data,
    input      [2:0]         line_update_state,

    input                    line_invalidate_valid,
    input      [ADDR_WIDTH-1:0] line_invalidate_addr
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

    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam LINE_OFF_W = clog2(LINE_BYTES);
    localparam INDEX_W = (LINES <= 2) ? 1 : clog2(LINES);
    localparam TAG_W = ADDR_WIDTH - LINE_OFF_W - INDEX_W;

    wire [INDEX_W-1:0] lookup_index =
        lookup_addr[LINE_OFF_W +: INDEX_W];
    wire [TAG_W-1:0] lookup_tag =
        lookup_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [INDEX_W-1:0] update_index =
        line_update_addr[LINE_OFF_W +: INDEX_W];
    wire [TAG_W-1:0] update_tag =
        line_update_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [INDEX_W-1:0] inv_index =
        line_invalidate_addr[LINE_OFF_W +: INDEX_W];
    wire [TAG_W-1:0] inv_tag =
        line_invalidate_addr[ADDR_WIDTH-1 -: TAG_W];

    reg                valid_mem [0:LINES-1];
    (* ram_style = "block" *) reg [TAG_W-1:0] tag_mem [0:LINES-1];
    (* ram_style = "block" *) reg [2:0] state_mem [0:LINES-1];
    (* ram_style = "block" *) reg [LINE_WIDTH-1:0] data_mem [0:LINES-1];

    integer i;

    assign lookup_hit = lookup_valid &&
                        valid_mem[lookup_index] &&
                        (tag_mem[lookup_index] == lookup_tag);
    assign lookup_state = lookup_hit ? state_mem[lookup_index] : `CHI_STATE_I;
    assign lookup_data = lookup_hit ? data_mem[lookup_index] : {LINE_WIDTH{1'b0}};

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (i = 0; i < LINES; i = i + 1) begin
                valid_mem[i] <= 1'b0;
            end
        end else if (clear) begin
            for (i = 0; i < LINES; i = i + 1) begin
                valid_mem[i] <= 1'b0;
            end
        end else begin
            if (line_invalidate_valid &&
                valid_mem[inv_index] &&
                (tag_mem[inv_index] == inv_tag)) begin
                valid_mem[inv_index] <= 1'b0;
                state_mem[inv_index] <= `CHI_STATE_I;
            end

            if (line_update_valid) begin
                valid_mem[update_index] <= (line_update_state != `CHI_STATE_I);
                tag_mem[update_index]   <= update_tag;
                state_mem[update_index] <= line_update_state;
                data_mem[update_index]  <= line_update_data;
            end
        end
    end
endmodule
