`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_mux_1hot
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_mux_1hot #(
    parameter WIDTH = 128,
    parameter N     = 2
)(
    input      [N*WIDTH-1:0] in_data,
    input      [N-1:0]       sel_onehot,
    output reg [WIDTH-1:0]   out_data,
    output                   sel_valid
);
    integer i;

    assign sel_valid = |sel_onehot;

    always @(*) begin
        out_data = {WIDTH{1'b0}};
        for (i = 0; i < N; i = i + 1) begin
            if (sel_onehot[i])
                out_data = in_data[i*WIDTH +: WIDTH];
        end
    end
endmodule
