`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_exclusive_monitor
// Purpose: RN-local exclusive reservation monitor. LDREX sets one line
//          reservation; STREX consumes it and reports success/failure.
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
    output                   strex_fail,

    input                    strex_commit,
    input                    local_write_valid,
    input      [ADDR_WIDTH-1:0] local_write_addr,
    input                    clear_addr_valid,
    input      [ADDR_WIDTH-1:0] clear_addr,
    input                    clear_all,

    output                   reservation_valid,
    output                   reservation_match,
    output     [ADDR_WIDTH-1:0] reservation_addr,
    output                   ldrex_set_pulse,
    output                   reservation_clear_pulse
);
    reg                  valid_q;
    reg [ADDR_WIDTH-1:0] addr_q;

    wire [ADDR_WIDTH-LINE_LSB-1:0] ldrex_line =
        ldrex_addr[ADDR_WIDTH-1:LINE_LSB];
    wire [ADDR_WIDTH-LINE_LSB-1:0] strex_line =
        strex_addr[ADDR_WIDTH-1:LINE_LSB];
    wire [ADDR_WIDTH-LINE_LSB-1:0] local_write_line =
        local_write_addr[ADDR_WIDTH-1:LINE_LSB];
    wire [ADDR_WIDTH-LINE_LSB-1:0] clear_line =
        clear_addr[ADDR_WIDTH-1:LINE_LSB];
    wire [ADDR_WIDTH-LINE_LSB-1:0] reserved_line =
        addr_q[ADDR_WIDTH-1:LINE_LSB];
    wire strex_line_match = valid_q && (strex_line == reserved_line);
    wire local_write_line_match = local_write_valid &&
                                  valid_q &&
                                  (local_write_line == reserved_line);
    wire clear_line_match = clear_addr_valid &&
                            valid_q &&
                            (clear_line == reserved_line);
    wire clear_request = clear ||
                         clear_all ||
                         clear_line_match ||
                         local_write_line_match ||
                         strex_commit;

    assign strex_pass = strex_check_valid &&
                        strex_line_match;
    assign strex_fail = strex_check_valid && !strex_line_match;
    assign reservation_valid = valid_q;
    assign reservation_match = strex_line_match;
    assign reservation_addr = addr_q;
    assign ldrex_set_pulse = ldrex_complete && !clear_request;
    assign reservation_clear_pulse = valid_q && clear_request;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q <= 1'b0;
            addr_q  <= {ADDR_WIDTH{1'b0}};
        end else if (clear_request) begin
            valid_q <= 1'b0;
        end else if (ldrex_complete) begin
            valid_q <= 1'b1;
            addr_q  <= ldrex_addr;
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && strex_commit && !strex_line_match) begin
            $display("chi_exclusive_monitor STREX commit without reservation match");
            $stop;
        end
    end
    // synthesis translate_on
endmodule
