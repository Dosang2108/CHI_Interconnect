`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_link_layer
// Purpose: Transmit side of one CHI link channel (REQ/SNP/RSP/DAT) inside a
//          node, with the node's ports as real CHI link signals
//          (IHI0050H B14.2.1).
//
//   TX:  tx_in_*  -- valid/ready from the protocol layer
//        tx_out_valid is FLITV: each cycle it is high is one flit, sent only
//        while the node holds an L-Credit. tx_out_lcrdv is LCRDV from the
//        receiver: one credit per cycle it is high, counted from the next
//        cycle. Credits start at 0; the receiver grants them after reset.
//        tx_out_flitpend is FLITPEND, high at least one cycle before FLITV.
//        Flits go out in RUN only (link_run); in DEACTIVATE (link_deact) the
//        credits held go back as LCrdReturn flits (B14.5.1). tx_pending is
//        high while a protocol flit is held or offered. See chi_link_tx.
//   RX:  rx_in_* -- skid --> rx_out_*. Unused: every node ties rx_in_valid
//        low and chi_top owns the receive side (chi_link_rx).
//
//   tx_fire_pulse marks a protocol flit sent (flits go out in RUN only, so
//   an LCrdReturn flit is not counted), tx_credit_return_pulse a credit
//   received, tx_credit_stall a flit offered but not taken this cycle.
//   INIT_CREDIT is kept for the instance parameter lists; credits now come
//   from the receiver, so it has no effect.
// -----------------------------------------------------------------------------
module chi_link_layer #(
    parameter FLIT_W      = 128,
    parameter CREDIT_W    = 4,
    parameter INIT_CREDIT = `CHI_DEFAULT_INIT_CRD
)(
    input                  clk,
    input                  rstn,
    input                  clear,

    // Link state from the node's chi_link_active_tx.
    input                  link_run,
    input                  link_deact,

    input                  tx_in_valid,
    output                 tx_in_ready,
    input      [FLIT_W-1:0] tx_in_flit,
    output                 tx_out_valid,
    output     [FLIT_W-1:0] tx_out_flit,
    input                  tx_out_lcrdv,
    output                 tx_out_flitpend,
    output                 tx_pending,

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
    wire       rx_skid_in_ready;
    wire [3:0] tx_credits;

    chi_link_tx #(
        .FLIT_W(FLIT_W)
    ) u_tx (
        .clk(clk),
        .rstn(rstn),
        .link_run(link_run),
        .link_deact(link_deact),
        .in_valid(tx_in_valid),
        .in_ready(tx_in_ready),
        .in_flit(tx_in_flit),
        .pending(tx_pending),
        .flitpend(tx_out_flitpend),
        .flitv(tx_out_valid),
        .flit(tx_out_flit),
        .lcrdv(tx_out_lcrdv),
        .credit_count(tx_credits)
    );

    assign credit_count           = tx_credits[CREDIT_W-1:0];
    assign tx_fire_pulse          = tx_out_valid && link_run;
    assign tx_credit_return_pulse = tx_out_lcrdv;
    assign tx_credit_stall        = tx_in_valid && !tx_in_ready;

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
endmodule
