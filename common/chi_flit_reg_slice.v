`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_flit_reg_slice
// Purpose: Two-entry ready/valid register slice for flit timing isolation.
//          The output register feeds downstream; the skid register takes the
//          one flit that arrives while the output register is held. Upstream
//          ready depends only on local state, never on downstream ready, so
//          the slice cannot close a fabric-level ready loop, and a steady
//          stream moves one flit every cycle (a one-entry half-buffer manages
//          one every two cycles).
// -----------------------------------------------------------------------------
module chi_flit_reg_slice #(
    parameter WIDTH = 128
)(
    input                  clk,
    input                  rstn,
    input                  clear,
    input                  in_valid,
    output                 in_ready,
    input      [WIDTH-1:0] in_data,
    output                 out_valid,
    input                  out_ready,
    output     [WIDTH-1:0] out_data
);
    reg             valid_q;
    reg [WIDTH-1:0] data_q;
    reg             skid_valid_q;
    reg [WIDTH-1:0] skid_q;

    wire push = in_valid && in_ready;
    // The output register is free, or is being emptied this cycle.
    wire out_load = !valid_q || out_ready;

    assign in_ready  = !skid_valid_q;
    assign out_valid = valid_q;
    assign out_data  = data_q;

    always @(posedge clk) begin
        if (rstn && !clear) begin
            if (out_load) begin
                if (skid_valid_q)
                    data_q <= skid_q;
                else if (push)
                    data_q <= in_data;
            end else if (push) begin
                skid_q <= in_data;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q      <= 1'b0;
            skid_valid_q <= 1'b0;
        end else if (clear) begin
            valid_q      <= 1'b0;
            skid_valid_q <= 1'b0;
        end else if (out_load) begin
            // A flit waiting in the skid register goes first; in_ready was
            // low for it, so nothing else arrives in the same cycle.
            valid_q      <= skid_valid_q || push;
            skid_valid_q <= 1'b0;
        end else if (push) begin
            skid_valid_q <= 1'b1;
        end
    end
endmodule
