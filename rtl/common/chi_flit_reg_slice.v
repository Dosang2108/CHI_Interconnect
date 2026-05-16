`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_flit_reg_slice
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_flit_reg_slice #(
    parameter WIDTH = 128
)(
    input                  clk,
    input                  rstn,
    input                  in_valid,
    output                 in_ready,
    input      [WIDTH-1:0] in_data,
    output                 out_valid,
    input                  out_ready,
    output     [WIDTH-1:0] out_data
);
    reg             valid_q;
    reg [WIDTH-1:0] data_q;

    assign in_ready  = !valid_q || out_ready;
    assign out_valid = valid_q;
    assign out_data  = data_q;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q <= 1'b0;
            data_q  <= {WIDTH{1'b0}};
        end else if (in_ready) begin
            valid_q <= in_valid;
            data_q  <= in_data;
        end
    end
endmodule
