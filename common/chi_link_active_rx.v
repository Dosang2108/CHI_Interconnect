`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_link_active_rx
// Purpose: Receiver side of the LINKACTIVE handshake of one link
//          (IHI0050H B14.5.1). The receiver owns LINKACTIVEACK: it follows
//          LINKACTIVEREQ up, and follows it down only once every L-Credit it
//          granted on every channel of the link has come back (credits_home),
//          so in STOP the receiver holds all the credits again.
//
//          grant_en is high in RUN only: no credit is granted before the
//          acknowledge or after the transmitter asked to deactivate.
// -----------------------------------------------------------------------------
module chi_link_active_rx (
    input      clk,
    input      rstn,
    input      linkactivereq,
    output reg linkactiveack,
    input      credits_home,
    output     grant_en
);
    assign grant_en = linkactivereq && linkactiveack;

    always @(posedge clk or negedge rstn) begin
        if (!rstn)
            linkactiveack <= 1'b0;
        else if (!linkactiveack && linkactivereq)
            linkactiveack <= 1'b1;
        else if (linkactiveack && !linkactivereq && credits_home)
            linkactiveack <= 1'b0;
    end
endmodule
