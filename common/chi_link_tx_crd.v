`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_link_tx_crd
// Purpose: L-Credit side of one CHI link channel transmitter (IHI0050H
//          B14.2.1, B14.5.1): the credit counter, the link-state gating and
//          the LCrdReturn flits. It has no storage for flits; chi_link_tx
//          puts a hold register in front of it, and the fabric outputs drive
//          it straight from their output register.
//
//   - Credits start at 0 and arrive on LCRDV, one per cycle. A credit is
//     counted at the clock edge after LCRDV, so it is never used in the
//     cycle it is received. Credits are accepted in every link state.
//   - RUN (link_run): in_ready is high while a credit is held, and every
//     flit taken goes out on FLITV in the same cycle.
//   - DEACTIVATE (link_deact): no protocol flit is taken. Each credit held,
//     and each credit that still arrives, goes back as an LCrdReturn flit:
//     opcode 0 on every channel, so the whole flit is zero.
//   - FLITPEND is in_pend (the caller has, or is about to have, a flit) or a
//     credit waiting to be returned; a return flit waits for the cycle after
//     FLITPEND (B14.4).
// -----------------------------------------------------------------------------
module chi_link_tx_crd #(
    parameter integer FLIT_W = 128
)(
    input               clk,
    input               rstn,
    input               link_run,
    input               link_deact,
    input               in_valid,
    output              in_ready,
    input  [FLIT_W-1:0] in_flit,
    input               in_pend,
    output              flitpend,
    output              flitv,
    output [FLIT_W-1:0] flit,
    input               lcrdv,
    output [3:0]        credit_count
);
    reg [3:0] credit_q;
    reg       flitpend_q;

    wire credit_ok = (credit_q != 4'd0);
    wire ret_pend  = link_deact && credit_ok;
    wire ret       = ret_pend && flitpend_q;
    wire send      = in_valid && in_ready;

    assign in_ready     = link_run && credit_ok;
    assign flitv        = send || ret;
    assign flit         = ret ? {FLIT_W{1'b0}} : in_flit;
    assign flitpend     = in_pend || ret_pend;
    assign credit_count = credit_q;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            credit_q   <= 4'd0;
            flitpend_q <= 1'b0;
        end else begin
            credit_q   <= credit_q + {3'd0, lcrdv} - {3'd0, flitv};
            flitpend_q <= flitpend;
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && lcrdv && !flitv && (credit_q == 4'd15)) begin
            $display("[%0t] chi_link_tx_crd %m: LCRDV beyond 15 L-Credits (B14.2.1)", $time);
            $stop;
        end
    end
    // synthesis translate_on
endmodule
