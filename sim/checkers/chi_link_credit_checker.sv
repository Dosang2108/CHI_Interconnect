`timescale 1ns/1ps

// CHI link-layer L-Credit checker (roadmap 3.0), simulation only.
//
// One instance watches one channel (REQ, RSP, SNP or DAT) in one direction
// over N links, each with its own credit count. chi_checker_binds binds one
// per channel and direction into chi_top, tapping the node<->fabric link
// boundary: FLITV is the flit valid the transmitter drives, LCRDV the
// credit the receiver returns. Rules (IHI0050H B14.2.1):
//   - every cycle with FLITV high transfers one flit and consumes one
//     L-Credit; FLITV with no credit is an error,
//   - an L-Credit cannot be used in the cycle it is received, so FLITV is
//     checked against the count at the start of the cycle,
//   - a receiver provides at most 15 L-Credits, and no more than it has
//     buffers for (MAX_CREDIT); LCRDV beyond that is an error.
// Rule SPEC_LINK_FLITPEND (B14.4): FLITPEND is high in the cycle before
// every FLITV.
// Rule SPEC_LINK_ACTIVE (B14.5.1), on the LINKACTIVEREQ/ACK pair of the link
// each port belongs to:
//   - the pair only moves STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP,
//   - no FLITV and no LCRDV in STOP or ACTIVATE,
//   - the link reaches STOP only with every L-Credit returned.
// LCrdReturn flits are flits like any other here: each has FLITV and uses
// one credit.
// INIT_CREDIT is the credit count after reset: 0 on a credited link (the
// receiver grants every credit on LCRDV), or the pre-granted count of a
// link still using valid/ready.
//
// Rule SPEC_LINK_CREDIT, off by default like the other spec rules; enabled
// by +CHK_SPEC_LINK_CREDIT, and by +CHK_SPEC_ALL on links bound with
// IN_SPEC_ALL=1 (a direction joins CHK_SPEC_ALL once roadmap 3.1 makes it
// credited and clean). +CHI_CHK_OFF disables it.
// Violations print "CHI_CHK ERROR: SPEC_LINK_CREDIT", which
// run_regression.ps1 counts as a failure.
module chi_link_credit_checker #(
    parameter integer N           = 1,
    parameter integer INIT_CREDIT = 2,
    parameter integer MAX_CREDIT  = 2,
    parameter integer IN_SPEC_ALL = 1,
    parameter         LINK        = "link"
)(
    input         clk,
    input         rstn,
    input [N-1:0] flitv,
    input [N-1:0] flitpend,
    input [N-1:0] lcrdv,
    input [N-1:0] linkactivereq,
    input [N-1:0] linkactiveack
);
    localparam integer SPEC_MAX_CREDIT = 15;
    localparam integer CAP = (MAX_CREDIT < SPEC_MAX_CREDIT) ? MAX_CREDIT : SPEC_MAX_CREDIT;

    bit     enabled;
    int     credit [N];
    int     errors;
    int     pend_errors;
    int     act_errors;
    reg [N-1:0] flitpend_q;
    reg [N-1:0] req_q;
    reg [N-1:0] ack_q;
    reg [1:0]   st;
    reg [1:0]   pst;
    longint n_stop;
    longint n_flit;
    longint n_lcrdv;
    longint cycle;

    initial begin
        enabled = !$test$plusargs("CHI_CHK_OFF") &&
                  (((IN_SPEC_ALL != 0) && $test$plusargs("CHK_SPEC_ALL")) ||
                   $test$plusargs("CHK_SPEC_LINK_CREDIT"));
        errors  = 0;
        pend_errors = 0;
        act_errors = 0;
        n_stop  = 0;
        n_flit  = 0;
        n_lcrdv = 0;
        cycle   = 0;
        if (enabled && (INIT_CREDIT > CAP))
            $display("[%0t] CHI_CHK ERROR: SPEC_LINK_CREDIT %s %m: INIT_CREDIT %0d exceeds receiver limit %0d",
                     $time, LINK, INIT_CREDIT, CAP);
    end

    task automatic err(input string msg);
        errors = errors + 1;
        if (errors <= 20)
            $display("[%0t] CHI_CHK ERROR: SPEC_LINK_CREDIT %s %s", $time, LINK, msg);
        else if (errors == 21)
            $display("[%0t] CHI_CHK ERROR: SPEC_LINK_CREDIT %s further violations counted but not printed",
                     $time, LINK);
    endtask

    task automatic pend_err(input string msg);
        pend_errors = pend_errors + 1;
        if (pend_errors <= 20)
            $display("[%0t] CHI_CHK ERROR: SPEC_LINK_FLITPEND %s %s", $time, LINK, msg);
    endtask

    // STOP or ACTIVATE, the two states with LINKACTIVEACK low.
    function automatic string st_name(input [1:0] v);
        if (v[1])
            st_name = "ACTIVATE";
        else
            st_name = "STOP";
    endfunction

    task automatic act_err(input string msg);
        act_errors = act_errors + 1;
        if (act_errors <= 20)
            $display("[%0t] CHI_CHK ERROR: SPEC_LINK_ACTIVE %s %s", $time, LINK, msg);
    endtask

    integer i;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (i = 0; i < N; i = i + 1)
                credit[i] = INIT_CREDIT;
            flitpend_q = {N{1'b0}};
            req_q = {N{1'b0}};
            ack_q = {N{1'b0}};
        end else if (enabled) begin
            cycle = cycle + 1;
            for (i = 0; i < N; i = i + 1) begin
                // {REQ, ACK}: 00 STOP, 10 ACTIVATE, 11 RUN, 01 DEACTIVATE.
                st  = {linkactivereq[i], linkactiveack[i]};
                pst = {req_q[i], ack_q[i]};
                if ((st != pst) &&
                    !(((pst == 2'b00) && (st == 2'b10)) || ((pst == 2'b10) && (st == 2'b11)) ||
                      ((pst == 2'b11) && (st == 2'b01)) || ((pst == 2'b01) && (st == 2'b00))))
                    act_err($sformatf("port %0d: LINKACTIVEREQ/ACK went %b -> %b (cycle %0d)", i, pst, st, cycle));
                if ((pst == 2'b01) && (st == 2'b00)) begin
                    n_stop = n_stop + 1;
                    if (credit[i] != 0)
                        act_err($sformatf("port %0d: link stopped with %0d L-Credits not returned (cycle %0d)",
                                          i, credit[i], cycle));
                end
                if (flitv[i] && !st[0])
                    act_err($sformatf("port %0d: FLITV in %s (cycle %0d)", i, st_name(st), cycle));
                if (lcrdv[i] && !st[0])
                    act_err($sformatf("port %0d: LCRDV in %s (cycle %0d)", i, st_name(st), cycle));
                if (flitv[i] && !flitpend_q[i])
                    pend_err($sformatf("port %0d: FLITV without FLITPEND the cycle before (cycle %0d)", i, cycle));
                if (flitv[i]) begin
                    n_flit = n_flit + 1;
                    if (credit[i] == 0)
                        err($sformatf("port %0d: FLITV with no L-Credit (cycle %0d)", i, cycle));
                    else
                        credit[i] = credit[i] - 1;
                end
                if (lcrdv[i]) begin
                    n_lcrdv = n_lcrdv + 1;
                    if (credit[i] >= CAP)
                        err($sformatf("port %0d: LCRDV beyond %0d L-Credits (cycle %0d)", i, CAP, cycle));
                    else
                        credit[i] = credit[i] + 1;
                end
            end
            flitpend_q = flitpend;
            req_q = linkactivereq;
            ack_q = linkactiveack;
        end
    end

    final begin
        if (enabled)
            $display("CHI_CHK SUMMARY %m SPEC_LINK_CREDIT %s violations=%0d flitpend_violations=%0d flits=%0d lcrdv=%0d link_active_violations=%0d link_stops=%0d",
                     LINK, errors, pend_errors, n_flit, n_lcrdv, act_errors, n_stop);
    end
endmodule
