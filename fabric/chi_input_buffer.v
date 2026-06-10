`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_input_buffer
// Purpose: Fabric input FIFO that stores each flit together with its route
//          one-hot and QoS metadata until the crossbar grants it.
// -----------------------------------------------------------------------------
module chi_input_buffer #(
    parameter FLIT_W = 128,
    parameter DEPTH  = `CHI_DEFAULT_FIFO_DEPTH
)(
    input                  clk,
    input                  rstn,
    input                  clear,
    input                  in_valid,
    output                 in_ready,
    input      [FLIT_W-1:0] in_flit,
    output                 out_valid,
    input                  out_ready,
    output     [FLIT_W-1:0] out_flit,
    output                 pop_pulse,
    output     [15:0]      used_count
);
    chi_fifo #(
        .WIDTH(FLIT_W),
        .DEPTH(DEPTH),
        .BYPASS_READY(0)
    ) u_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data(in_flit),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data(out_flit),
        .pop_pulse(pop_pulse),
        .used_count(used_count)
    );
endmodule
