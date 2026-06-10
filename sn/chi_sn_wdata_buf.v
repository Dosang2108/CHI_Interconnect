`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_sn_wdata_buf
// Purpose: Small SN-F write-data staging buffer that captures incoming CHI DAT
//          WDAT beats before AXI write emission.
// -----------------------------------------------------------------------------
module chi_sn_wdata_buf #(
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
    output     [FLIT_W-1:0] out_flit
);
    wire pop_unused;
    wire [15:0] used_count_unused;

    chi_fifo #(
        .WIDTH(FLIT_W),
        .DEPTH(DEPTH)
    ) u_wdata_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data(in_flit),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data(out_flit),
        .pop_pulse(pop_unused),
        .used_count(used_count_unused)
    );
endmodule
