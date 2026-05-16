`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_credit_counter
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_credit_counter #(
    parameter CREDIT_W    = 4,
    parameter INIT_CREDIT = `CHI_DEFAULT_INIT_CRD,
    parameter MAX_CREDIT  = `CHI_DEFAULT_INIT_CRD
)(
    input                    clk,
    input                    rstn,
    input                    clear,
    input                    tx_fire,
    input                    lcrdv,
    output                   credit_ok,
    output                   credit_ok_bypass,
    output reg [CREDIT_W-1:0] credit_count,
    output                   underflow,
    output                   overflow
);
    localparam [CREDIT_W-1:0] INIT_CREDIT_VALUE = INIT_CREDIT;
    localparam [CREDIT_W-1:0] MAX_CREDIT_VALUE  = MAX_CREDIT;

    assign credit_ok = (credit_count != {CREDIT_W{1'b0}});
    assign credit_ok_bypass = credit_ok || lcrdv;
    assign underflow = tx_fire && !lcrdv && (credit_count == {CREDIT_W{1'b0}});
    assign overflow  = lcrdv && !tx_fire && (credit_count == MAX_CREDIT_VALUE);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            credit_count <= INIT_CREDIT_VALUE;
        end else if (clear) begin
            credit_count <= INIT_CREDIT_VALUE;
        end else begin
            case ({tx_fire, lcrdv})
                2'b10: begin
                    if (credit_count != {CREDIT_W{1'b0}})
                        credit_count <= credit_count - 1'b1;
                end
                2'b01: begin
                    if (credit_count != MAX_CREDIT_VALUE)
                        credit_count <= credit_count + 1'b1;
                end
                default: begin
                    credit_count <= credit_count;
                end
            endcase
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && !clear) begin
            if (underflow) begin
                $display("chi_credit_counter underflow");
                $stop;
            end

            if (overflow) begin
                $display("chi_credit_counter overflow");
                $stop;
            end
        end
    end
    // synthesis translate_on
endmodule
