`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_link_active_tx
// Purpose: Transmitter side of the LINKACTIVE handshake of one link, that is
//          all channels of an interface that carry flits the same way
//          (IHI0050H B14.5.1). The transmitter owns LINKACTIVEREQ:
//
//            STOP  (REQ 0, ACK 0)  no credits held, no flits
//            ACT   (REQ 1, ACK 0)  waiting for the receiver
//            RUN   (REQ 1, ACK 1)  flits go out while credits last
//            DEACT (REQ 0, ACK 1)  every credit held goes back as LCrdReturn
//
//          want asks for the link to be up. It is sampled in STOP and RUN
//          only, so a deactivation always completes before the link is
//          activated again.
// -----------------------------------------------------------------------------
module chi_link_active_tx (
    input      clk,
    input      rstn,
    input      want,
    output reg linkactivereq,
    input      linkactiveack,
    output     run,
    output     deact
);
    assign run   = linkactivereq && linkactiveack;
    assign deact = !linkactivereq && linkactiveack;

    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            linkactivereq <= 1'b0;
        else if (!linkactivereq && !linkactiveack && want)
            linkactivereq <= 1'b1;
        else if (linkactivereq && linkactiveack && !want)
            linkactivereq <= 1'b0;
    end
endmodule
