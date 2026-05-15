`include "chi_defs.vh"

module chi_output_reg #(
    parameter FLIT_W = 128
)(
    input                  clk,
    input                  rstn,
    input                  in_valid,
    output                 in_ready,
    input      [FLIT_W-1:0] in_flit,
    output                 out_valid,
    input                  out_ready,
    output     [FLIT_W-1:0] out_flit
);
    chi_flit_reg_slice #(
        .WIDTH(FLIT_W)
    ) u_reg_slice (
        .clk(clk),
        .rstn(rstn),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data(in_flit),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data(out_flit)
    );
endmodule
