`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_link_rx
// Purpose: Receiver of one CHI link channel (IHI0050H B14.2.1). Every cycle
//          with FLITV high delivers one flit, which goes into a DEPTH-entry
//          FIFO without backpressure: the transmitter only sends with an
//          L-Credit, and this side grants one credit per free entry
//          (chi_link_lcrd_gen), so the FIFO always has room. The credit goes
//          back when the protocol layer takes the flit, not when it arrives.
//          overflow flags a flit that found the FIFO full (a credit bug on
//          the other side); the flit is dropped.
//
//          An LCrdReturn flit (opcode field OPC_LSB/OPC_W all zero, B14.5.1)
//          returns its credit and stops here: it is neither stored nor
//          offered to the protocol layer. grant_en comes from the link's
//          chi_link_active_rx, and home tells it that every credit granted
//          on this channel is back.
//
//          FALLTHROUGH=1: a flit that arrives while the FIFO is empty is
//          offered to the protocol layer in the same cycle and only stored
//          if it is not taken, so the link adds no latency. FALLTHROUGH=0
//          always stores first (out_valid one cycle after FLITV).
// -----------------------------------------------------------------------------
module chi_link_rx #(
    parameter integer FLIT_W      = 128,
    parameter integer DEPTH       = `CHI_DEFAULT_INIT_CRD,
    parameter integer FALLTHROUGH = 0,
    parameter integer OPC_LSB     = 0,
    parameter integer OPC_W       = 4
)(
    input               clk,
    input               rstn,
    input               clear,
    input               grant_en,
    input               flitv,
    input  [FLIT_W-1:0] flit,
    output              lcrdv,
    output              home,
    output              out_valid,
    input               out_ready,
    output [FLIT_W-1:0] out_flit,
    output              overflow
);
    wire              fifo_in_valid;
    wire              fifo_in_ready;
    wire              fifo_out_valid;
    wire [FLIT_W-1:0] fifo_out_flit;
    wire              fifo_pop_unused;
    wire [15:0]       used_count;
    wire [3:0]        owed_unused;
    wire              is_return;
    wire              flit_in;
    wire              bypass;
    wire              take;

    assign is_return     = flitv && (flit[OPC_LSB +: OPC_W] == {OPC_W{1'b0}});
    assign flit_in       = flitv && !is_return;
    assign bypass        = (FALLTHROUGH != 0) && flit_in && !fifo_out_valid;
    assign out_valid     = fifo_out_valid || bypass;
    assign out_flit      = fifo_out_valid ? fifo_out_flit : flit;
    assign take          = out_valid && out_ready;
    assign fifo_in_valid = flit_in && !(bypass && out_ready);
    assign overflow      = fifo_in_valid && !fifo_in_ready;

    chi_fifo #(
        .WIDTH(FLIT_W),
        .DEPTH(DEPTH),
        .BYPASS_READY(0)
    ) u_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(fifo_in_valid),
        .in_ready(fifo_in_ready),
        .in_data(flit),
        .out_valid(fifo_out_valid),
        .out_ready(out_ready),
        .out_data(fifo_out_flit),
        .pop_pulse(fifo_pop_unused),
        .used_count(used_count)
    );

    // One credit back per flit the protocol layer takes, stored or not.
    chi_link_lcrd_gen #(
        .DEPTH(DEPTH)
    ) u_lcrd (
        .clk(clk),
        .rstn(rstn),
        .grant_en(grant_en),
        .pop(take),
        .flit(flitv),
        .ret(is_return),
        .lcrdv(lcrdv),
        .owed(owed_unused),
        .home(home)
    );

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && overflow) begin
            $display("[%0t] chi_link_rx %m: FLITV with the buffer full (flit without L-Credit)", $time);
            $stop;
        end
    end
    // synthesis translate_on
endmodule
