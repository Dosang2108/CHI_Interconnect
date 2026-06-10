`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_output_reg
// Purpose: Per-output fabric elastic stage. Depth 1 uses a half-buffer register
//          slice; depth >1 uses a fabric-safe FIFO for burst absorption.
// -----------------------------------------------------------------------------
module chi_output_reg #(
    parameter FLIT_W = 128,
    parameter FIFO_DEPTH = `CHI_DEFAULT_OUTPUT_FIFO_DEPTH
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
    generate
        if (FIFO_DEPTH <= 1) begin : gen_reg_slice
            chi_flit_reg_slice #(
                .WIDTH(FLIT_W)
            ) u_reg_slice (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
                .in_valid(in_valid),
                .in_ready(in_ready),
                .in_data(in_flit),
                .out_valid(out_valid),
                .out_ready(out_ready),
                .out_data(out_flit)
            );
        end else begin : gen_output_fifo
            wire unused_pop_pulse;
            wire [15:0] unused_count;

            chi_fifo #(
                .WIDTH(FLIT_W),
                .DEPTH(FIFO_DEPTH),
                .BYPASS_READY(0)
            ) u_output_fifo (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
                .in_valid(in_valid),
                .in_ready(in_ready),
                .in_data(in_flit),
                .out_valid(out_valid),
                .out_ready(out_ready),
                .out_data(out_flit),
                .pop_pulse(unused_pop_pulse),
                .used_count(unused_count)
            );
        end
    endgenerate
endmodule
