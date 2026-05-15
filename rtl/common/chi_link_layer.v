`include "chi_defs.vh"

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

    output     [CREDIT_W-1:0] credit_count
);
    wire credit_ok;
    wire credit_ok_bypass;
    wire underflow;
    wire overflow;
    wire tx_fire;

    assign tx_in_ready  = credit_ok_bypass;
    assign tx_out_valid = tx_in_valid && credit_ok_bypass;
    assign tx_out_flit  = tx_in_flit;
    assign tx_fire      = tx_out_valid;

    assign rx_out_valid = rx_in_valid;
    assign rx_out_flit  = rx_in_flit;
    assign rx_in_lcrdv  = rx_in_valid && rx_out_ready;

    chi_credit_counter #(
        .CREDIT_W(CREDIT_W),
        .INIT_CREDIT(INIT_CREDIT),
        .MAX_CREDIT(INIT_CREDIT)
    ) u_credit_counter (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .tx_fire(tx_fire),
        .lcrdv(tx_out_lcrdv),
        .credit_ok(credit_ok),
        .credit_ok_bypass(credit_ok_bypass),
        .credit_count(credit_count),
        .underflow(underflow),
        .overflow(overflow)
    );
endmodule
