`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_clock_gate_insert
// Purpose: Technology-neutral clock-gate placeholder. The RTL keeps this as a
//          synthesizable pass-through so ASIC/FPGA flows can replace it with a
//          library clock-gating cell or leave it ungated.
// -----------------------------------------------------------------------------
module chi_clock_gate_insert (
    input  clk_in,
    input  enable,
    input  scan_enable,
    output clk_out
);
    wire gate_open = enable || scan_enable;

`ifdef CHI_SIM_REAL_ICG
    // Simulation model of a latch-based ICG, used to prove that the enable
    // really covers all in-flight work: the enable is captured while clk_in
    // is low and the clock is suppressed for the whole next high phase.
    reg en_latch;
    always @(*) begin
        if (!clk_in)
            en_latch = gate_open;
    end
    assign clk_out = clk_in & en_latch;
`else
    assign clk_out = clk_in;
`endif

    // synthesis translate_off
    always @(*) begin
        if (!gate_open) begin
            // This wrapper is an insertion point. Vendor flows may replace the
            // assignment above with an integrated clock-gating cell.
        end
    end
    // synthesis translate_on
endmodule
