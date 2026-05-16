`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_demux_1hot
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_demux_1hot #(
    parameter WIDTH = 128,
    parameter N     = 2
)(
    input                  in_valid,
    input      [WIDTH-1:0] in_data,
    input      [N-1:0]     sel_onehot,
    output reg [N-1:0]     out_valid,
    output reg [N*WIDTH-1:0] out_data
);
    integer i;

    always @(*) begin
        out_valid = {N{1'b0}};
        out_data  = {N*WIDTH{1'b0}};
        for (i = 0; i < N; i = i + 1) begin
            if (sel_onehot[i]) begin
                out_valid[i] = in_valid;
                out_data[i*WIDTH +: WIDTH] = in_data;
            end
        end
    end
endmodule
