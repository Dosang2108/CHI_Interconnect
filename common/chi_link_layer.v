`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_link_layer
// Purpose: CHI link-layer credit gate.  Each per-channel (REQ/SNP/RSP/DAT)
//          instance pairs a TX credit counter with a passthrough RX path.
//
//   TX:  tx_in_*  -- credit_ok --> tx_out_*       (gated by registered credit)
//        A registered hold buffer preserves flits when the fabric does not
//        accept in the same cycle. Returned L-Credit still takes effect on the
//        next clock edge, and tx_out_valid is registered to avoid valid/ready
//        combinational loops through fabric backpressure.
//   RX:  rx_in_*  -- skid --> rx_out_*  ; rx_in_lcrdv pulses when the skid
//        buffer accepts the flit, decoupling credit return from one-cycle
//        downstream stalls.
//
//   underflow / overflow assertions live in chi_credit_counter (simulation).
// -----------------------------------------------------------------------------
module chi_link_layer #(
    parameter FLIT_W      = 128,
    parameter CREDIT_W    = 4,
    parameter INIT_CREDIT = `CHI_DEFAULT_INIT_CRD
)(
    input                  clk,
    input                  rstn,
    input                  clear,

    input                  tx_in_valid,
    output                 tx_in_ready,
    input      [FLIT_W-1:0] tx_in_flit,
    output                 tx_out_valid,
    output     [FLIT_W-1:0] tx_out_flit,
    input                  tx_out_lcrdv,

    input                  rx_in_valid,
    input      [FLIT_W-1:0] rx_in_flit,
    output                 rx_in_lcrdv,
    output                 rx_out_valid,
    input                  rx_out_ready,
    output     [FLIT_W-1:0] rx_out_flit,

    output     [CREDIT_W-1:0] credit_count,
    output                 tx_fire_pulse,
    output                 tx_credit_return_pulse,
    output                 tx_credit_stall
);
    wire credit_ok;
    wire credit_ok_bypass;
    wire underflow;
    wire overflow;
    wire tx_accept_fire;
    wire tx_launch_fire;
    wire rx_skid_in_ready;
    reg                  tx_hold_valid_q;
    reg [FLIT_W-1:0]     tx_hold_flit_q;

    assign tx_out_valid = tx_hold_valid_q;
    assign tx_out_flit  = tx_hold_flit_q;
    assign tx_launch_fire = tx_hold_valid_q && tx_out_lcrdv;
    assign tx_in_ready  = credit_ok_bypass && (!tx_hold_valid_q || tx_launch_fire);
    assign tx_accept_fire = tx_in_valid && tx_in_ready;
    assign tx_fire_pulse = tx_launch_fire;
    assign tx_credit_return_pulse = tx_out_lcrdv;
    assign tx_credit_stall = tx_in_valid && !tx_in_ready;

    assign rx_in_lcrdv = rx_in_valid && rx_skid_in_ready;

    chi_skid_buffer #(
        .WIDTH(FLIT_W)
    ) u_rx_skid (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(rx_in_valid),
        .in_ready(rx_skid_in_ready),
        .in_data(rx_in_flit),
        .out_valid(rx_out_valid),
        .out_ready(rx_out_ready),
        .out_data(rx_out_flit)
    );

    chi_credit_counter #(
        .CREDIT_W(CREDIT_W),
        .INIT_CREDIT(INIT_CREDIT),
        .MAX_CREDIT(INIT_CREDIT)
    ) u_credit_counter (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .tx_fire(tx_launch_fire),
        .lcrdv(tx_out_lcrdv),
        .credit_ok(credit_ok),
        .credit_ok_bypass(credit_ok_bypass),
        .credit_count(credit_count),
        .underflow(underflow),
        .overflow(overflow)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            tx_hold_valid_q <= 1'b0;
            tx_hold_flit_q  <= {FLIT_W{1'b0}};
        end else if (clear) begin
            tx_hold_valid_q <= 1'b0;
            tx_hold_flit_q  <= {FLIT_W{1'b0}};
        end else begin
            case ({tx_accept_fire, tx_launch_fire})
                2'b10: begin
                    tx_hold_valid_q <= 1'b1;
                    tx_hold_flit_q  <= tx_in_flit;
                end
                2'b01: begin
                    tx_hold_valid_q <= 1'b0;
                end
                2'b11: begin
                    tx_hold_valid_q <= 1'b1;
                    tx_hold_flit_q  <= tx_in_flit;
                end
                default: begin
                    tx_hold_valid_q <= tx_hold_valid_q;
                end
            endcase
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && tx_launch_fire && !credit_ok_bypass) begin
            $display("chi_link_layer transmitted without credit");
            $stop;
        end
    end
    // synthesis translate_on
endmodule
