`include "chi_defs.vh"

module chi_skid_buffer #(
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
    reg             full_q;
    reg [WIDTH-1:0] data_q;

    wire take_in  = in_valid && in_ready;
    wire take_out = out_valid && out_ready;

    assign in_ready  = !full_q || out_ready;
    assign out_valid = full_q || in_valid;
    assign out_data  = full_q ? data_q : in_data;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            full_q <= 1'b0;
            data_q <= {WIDTH{1'b0}};
        end else begin
            case ({take_in, take_out})
                2'b10: begin
                    full_q <= 1'b1;
                    data_q <= in_data;
                end
                2'b01: begin
                    full_q <= 1'b0;
                end
                2'b11: begin
                    if (full_q) begin
                        full_q <= 1'b1;
                        data_q <= in_data;
                    end else begin
                        full_q <= 1'b0;
                    end
                end
                default: begin
                    full_q <= full_q;
                end
            endcase
        end
    end
endmodule
