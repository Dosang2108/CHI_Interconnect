`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_link_tx
// Purpose: Transmitter of one CHI link channel (IHI0050H B14.2.1). The
//          protocol layer hands flits in with valid/ready; on the link each
//          cycle with FLITV high is one flit, sent only while an L-Credit is
//          held. There is no ready: the receiver granted the buffer entry
//          when it sent the credit.
//
//   - One hold register sits between the protocol layer and the link. The
//     held flit goes out in the first cycle the link is in RUN with a credit
//     (chi_link_tx_crd), and back-to-back flits go out every cycle while
//     credits last.
//   - Outside RUN the held flit waits. In DEACTIVATE the credits go back as
//     LCrdReturn flits (B14.5.1).
//   - pending is high whenever a protocol flit is held or offered. FLITPEND
//     is that or a credit waiting to be returned, so it always precedes
//     FLITV by at least one cycle (B14.4).
// -----------------------------------------------------------------------------
module chi_link_tx #(
    parameter integer FLIT_W = 128
)(
    input               clk,
    input               rstn,
    input               link_run,
    input               link_deact,
    input               in_valid,
    output              in_ready,
    input  [FLIT_W-1:0] in_flit,
    output              pending,
    output              flitpend,
    output              flitv,
    output [FLIT_W-1:0] flit,
    input               lcrdv,
    output [3:0]        credit_count
);
    reg              hold_valid_q;
    reg [FLIT_W-1:0] hold_flit_q;
    wire             crd_ready;

    wire send = hold_valid_q && crd_ready;
    wire take = in_valid && in_ready;

    assign in_ready = !hold_valid_q || send;
    assign pending  = hold_valid_q || in_valid;

    chi_link_tx_crd #(
        .FLIT_W(FLIT_W)
    ) u_crd (
        .clk(clk),
        .rstn(rstn),
        .link_run(link_run),
        .link_deact(link_deact),
        .in_valid(hold_valid_q),
        .in_ready(crd_ready),
        .in_flit(hold_flit_q),
        .in_pend(pending),
        .flitpend(flitpend),
        .flitv(flitv),
        .flit(flit),
        .lcrdv(lcrdv),
        .credit_count(credit_count)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            hold_valid_q <= 1'b0;
            hold_flit_q  <= {FLIT_W{1'b0}};
        end else begin
            if (take) begin
                hold_valid_q <= 1'b1;
                hold_flit_q  <= in_flit;
            end else if (send) begin
                hold_valid_q <= 1'b0;
            end
        end
    end
endmodule
