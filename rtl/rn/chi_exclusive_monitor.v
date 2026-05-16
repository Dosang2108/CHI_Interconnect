`include "../common/chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_exclusive_monitor
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_exclusive_monitor #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter LINE_LSB   = 6
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    ldrex_complete,
    input      [ADDR_WIDTH-1:0] ldrex_addr,

    input                    strex_check_valid,
    input      [ADDR_WIDTH-1:0] strex_addr,
    output                   strex_pass,

    input                    strex_commit,
    input                    clear_addr_valid,
    input      [ADDR_WIDTH-1:0] clear_addr,
    input                    clear_all,

    output                   reservation_valid
);
    reg                  valid_q;
    reg [ADDR_WIDTH-1:0] addr_q;

    wire [ADDR_WIDTH-LINE_LSB-1:0] ldrex_line =
        ldrex_addr[ADDR_WIDTH-1:LINE_LSB];
    wire [ADDR_WIDTH-LINE_LSB-1:0] strex_line =
        strex_addr[ADDR_WIDTH-1:LINE_LSB];
    wire [ADDR_WIDTH-LINE_LSB-1:0] clear_line =
        clear_addr[ADDR_WIDTH-1:LINE_LSB];
    wire [ADDR_WIDTH-LINE_LSB-1:0] reserved_line =
        addr_q[ADDR_WIDTH-1:LINE_LSB];
    wire clear_line_match = clear_addr_valid &&
                            valid_q &&
                            (clear_line == reserved_line);

    assign strex_pass = strex_check_valid &&
                        valid_q &&
                        (strex_line == reserved_line);
    assign reservation_valid = valid_q;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q <= 1'b0;
            addr_q  <= {ADDR_WIDTH{1'b0}};
        end else if (clear || clear_all || clear_line_match || strex_commit) begin
            valid_q <= 1'b0;
        end else if (ldrex_complete) begin
            valid_q <= 1'b1;
            addr_q  <= ldrex_addr;
        end
    end
endmodule
