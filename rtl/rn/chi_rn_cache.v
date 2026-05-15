`include "chi_defs.vh"

module chi_rn_cache #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter LINE_BYTES = 64,
    parameter LINES      = 64
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    line_update_valid,
    input      [ADDR_WIDTH-1:0] line_update_addr,
    input      [LINE_BYTES*8-1:0] line_update_data,
    input      [2:0]         line_update_state,

    input                    snoop_valid,
    input      [ADDR_WIDTH-1:0] snoop_addr,
    input      [5:0]         snoop_opcode,
    output                   snoop_hit,
    output                   snoop_dirty,
    output     [2:0]         snoop_state,
    output     [LINE_BYTES*8-1:0] snoop_data,
    output                   snoop_send_data,

    input                    snoop_commit
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
    localparam INDEX_W = (LINES <= 2) ? 1 : clog2(LINES);
    localparam TAG_W = (ADDR_WIDTH > (INDEX_W + 6)) ? (ADDR_WIDTH - INDEX_W - 6) : 1;

    wire [INDEX_W-1:0] update_index = line_update_addr[6 +: INDEX_W];
    wire [TAG_W-1:0]   update_tag = line_update_addr[ADDR_WIDTH-1 -: TAG_W];
    wire [INDEX_W-1:0] snoop_index = snoop_addr[6 +: INDEX_W];
    wire [TAG_W-1:0]   snoop_tag = snoop_addr[ADDR_WIDTH-1 -: TAG_W];

    reg                valid_mem [0:LINES-1];
    (* ram_style = "block" *) reg [TAG_W-1:0] tag_mem [0:LINES-1];
    (* ram_style = "block" *) reg [2:0] state_mem [0:LINES-1];
    (* ram_style = "block" *) reg [LINE_WIDTH-1:0] data_mem [0:LINES-1];

    wire hit_raw = valid_mem[snoop_index] &&
                   (tag_mem[snoop_index] == snoop_tag) &&
                   (state_mem[snoop_index] != `CHI_STATE_I);
    wire dirty_raw = (state_mem[snoop_index] == `CHI_STATE_SD) ||
                     (state_mem[snoop_index] == `CHI_STATE_UD);
    wire update_same_index = (update_index == snoop_index);
    wire update_same_line = update_same_index && (update_tag == snoop_tag);
    wire snoop_commit_applies = snoop_commit && hit_raw &&
                                !(line_update_valid &&
                                  update_same_index &&
                                  !update_same_line);

    integer reset_i;

    assign snoop_hit = snoop_valid && hit_raw;
    assign snoop_dirty = snoop_hit && dirty_raw;
    assign snoop_state = snoop_hit ? state_mem[snoop_index] : `CHI_STATE_I;
    assign snoop_data = data_mem[snoop_index];
    assign snoop_send_data = snoop_dirty &&
                             ((snoop_opcode == `CHI_SNP_SHARED) ||
                              (snoop_opcode == `CHI_SNP_UNIQUE) ||
                              (snoop_opcode == `CHI_SNP_INVALID));

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (reset_i = 0; reset_i < LINES; reset_i = reset_i + 1) begin
                valid_mem[reset_i] <= 1'b0;
            end
        end else if (clear) begin
            for (reset_i = 0; reset_i < LINES; reset_i = reset_i + 1) begin
                valid_mem[reset_i] <= 1'b0;
            end
        end else begin
            if (line_update_valid) begin
                valid_mem[update_index] <= (line_update_state != `CHI_STATE_I);
                tag_mem[update_index] <= update_tag;
                state_mem[update_index] <= line_update_state;
                data_mem[update_index] <= line_update_data;
            end

            if (snoop_commit_applies) begin
                case (snoop_opcode)
                    `CHI_SNP_SHARED: begin
                        if (state_mem[snoop_index] == `CHI_STATE_UD)
                            state_mem[snoop_index] <= `CHI_STATE_SD;
                        else if (state_mem[snoop_index] == `CHI_STATE_UC)
                            state_mem[snoop_index] <= `CHI_STATE_SC;
                    end

                    `CHI_SNP_UNIQUE,
                    `CHI_SNP_INVALID: begin
                        valid_mem[snoop_index] <= 1'b0;
                        state_mem[snoop_index] <= `CHI_STATE_I;
                    end

                    default: begin
                        state_mem[snoop_index] <= state_mem[snoop_index];
                    end
                endcase
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && line_update_valid && snoop_commit && update_same_line) begin
            $display("chi_rn_cache simultaneous fill and snoop commit on same line");
        end
    end
    // synthesis translate_on
endmodule
