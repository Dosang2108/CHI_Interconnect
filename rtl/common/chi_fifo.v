`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_fifo
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_fifo #(
    parameter WIDTH = 128,
    parameter DEPTH = `CHI_DEFAULT_FIFO_DEPTH
)(
    input                  clk,
    input                  rstn,
    input                  clear,
    input                  in_valid,
    output                 in_ready,
    input      [WIDTH-1:0] in_data,
    output                 out_valid,
    input                  out_ready,
    output     [WIDTH-1:0] out_data,
    output     [15:0]      used_count
);
    `include "chi_clog2.vh"
    localparam PTR_W   = (DEPTH <= 2) ? 1 : `CHI_CLOG2(DEPTH);
    localparam COUNT_W = (DEPTH <= 1) ? 1 : `CHI_CLOG2(DEPTH + 1);
    localparam [COUNT_W-1:0] DEPTH_COUNT = DEPTH;

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W-1:0] rd_ptr;
    reg [COUNT_W-1:0] count;

    wire push = in_valid && in_ready;
    wire pop  = out_valid && out_ready;

    assign in_ready  = (count < DEPTH_COUNT) || pop;
    assign out_valid = (count != {COUNT_W{1'b0}});
    assign out_data  = mem[rd_ptr];
    assign used_count = {{(16-COUNT_W){1'b0}}, count};

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            count  <= {COUNT_W{1'b0}};
        end else if (clear) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            count  <= {COUNT_W{1'b0}};
        end else begin
            if (push) begin
                mem[wr_ptr] <= in_data;
                if (wr_ptr == DEPTH-1)
                    wr_ptr <= {PTR_W{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end

            if (pop) begin
                if (rd_ptr == DEPTH-1)
                    rd_ptr <= {PTR_W{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
