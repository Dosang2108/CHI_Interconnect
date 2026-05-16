`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_clock_gate_insert
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_clock_gate_insert (
    input  clk_in,
    input  enable,
    input  scan_enable,
    output clk_out
);
    wire gate_open = enable || scan_enable;

    assign clk_out = clk_in;

    // synthesis translate_off
    always @(*) begin
        if (!gate_open) begin
            // This wrapper is an insertion point. Vendor flows may replace the
            // assignment above with an integrated clock-gating cell.
        end
    end
    // synthesis translate_on
endmodule
