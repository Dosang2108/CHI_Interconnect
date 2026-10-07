`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_link_lcrd_gen
// Purpose: Receiver side of one CHI link channel's L-Credit flow control
//          (IHI0050H B14.2.1). It owns DEPTH buffer entries and grants one
//          L-Credit per free entry: all DEPTH once the link runs, then one
//          more each time the buffer pops. LCRDV is high for one cycle per
//          credit, so credits still owed go out one per cycle.
//
//          owed_q counts free entries not yet granted, out_q the credits
//          granted and not yet used. Every flit (flit) uses one; a protocol
//          flit fills its entry until the buffer pops it (pop), an LCrdReturn
//          flit (ret, with flit) frees it at once. owed_q + out_q + buffer
//          occupancy is always DEPTH.
//
//          grant_en gates LCRDV (link activation, B14.5.1); credits stay
//          owed while it is low. home is high when no granted credit is
//          outstanding, which is what the receiver needs before it may
//          acknowledge the move to STOP.
// -----------------------------------------------------------------------------
module chi_link_lcrd_gen #(
    parameter integer DEPTH = `CHI_DEFAULT_FIFO_DEPTH
)(
    input        clk,
    input        rstn,
    input        grant_en,
    input        pop,
    input        flit,
    input        ret,
    output       lcrdv,
    output [3:0] owed,
    output       home
);
    reg [3:0] owed_q;
    reg [3:0] out_q;

    assign lcrdv = grant_en && (owed_q != 4'd0);
    assign owed  = owed_q;
    assign home  = (out_q == 4'd0);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            owed_q <= DEPTH[3:0];
            out_q  <= 4'd0;
        end else begin
            owed_q <= owed_q + {3'd0, pop} + {3'd0, ret} - {3'd0, lcrdv};
            out_q  <= out_q + {3'd0, lcrdv} - {3'd0, flit};
        end
    end

    // synthesis translate_off
    initial begin
        if ((DEPTH < 1) || (DEPTH > 15)) begin
            $display("chi_link_lcrd_gen: DEPTH %0d outside 1..15 (B14.2.1)", DEPTH);
            $finish;
        end
    end
    always @(posedge clk) begin
        if (rstn && (({1'b0, owed_q} + {4'd0, pop} + {4'd0, ret}) > DEPTH)) begin
            $display("[%0t] chi_link_lcrd_gen %m: entry freed with all %0d entries free", $time, DEPTH);
            $stop;
        end
        if (rstn && flit && (out_q == 4'd0)) begin
            $display("[%0t] chi_link_lcrd_gen %m: FLITV with no L-Credit outstanding", $time);
            $stop;
        end
    end
    // synthesis translate_on
endmodule
