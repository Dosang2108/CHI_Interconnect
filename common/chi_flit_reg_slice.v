`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_flit_reg_slice
// Purpose: One-entry ready/valid register slice for flit timing isolation.
//          This is a half-buffer: upstream ready depends only on local state,
//          never on downstream ready, to avoid fabric-level ready loops.
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

    assign in_ready  = !valid_q;
    assign out_valid = valid_q;
    assign out_data  = data_q;

    always @(posedge clk) begin
        if (rstn && !clear && in_ready && in_valid)
            data_q <= in_data;
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q <= 1'b0;
        end else if (clear) begin
            valid_q <= 1'b0;
        end else begin
            if (out_ready && valid_q)
                valid_q <= 1'b0;
            if (in_ready && in_valid)
                valid_q <= 1'b1;
        end
    end
endmodule
