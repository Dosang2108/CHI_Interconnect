`timescale 1ns/1ps

// CHI protocol-activity and system-coherency checker (roadmap 3.4),
// simulation only. chi_checker_binds binds one into every chi_top.
//
// Rule SPEC_SACTIVE (IHI0050H B14.7, B15.2.1):
//   - a node sends a protocol flit only with its TXSACTIVE high,
//   - the interconnect hands a protocol flit to a node only with that
//     node's RXSACTIVE (the interconnect's TXSACTIVE) high,
//   - an RN keeps TXSACTIVE high during a coherency state transition
//     (SYSCOREQ != SYSCOACK).
// Rule SPEC_SYSCO (B15.2), per RN:
//   - SYSCOREQ only changes while SYSCOACK has the same value, and SYSCOACK
//     only changes while SYSCOREQ has the opposite value,
//   - no snoop reaches an RN in Coherency Disabled (both low).
// The flit inputs are protocol flits only: the caller leaves out the
// LCrdReturn flits of a link deactivation.
//
// Both rules are off by default like the other spec rules; they are enabled
// by +CHK_SPEC_SACTIVE, +CHK_SPEC_SYSCO or +CHK_SPEC_ALL, and +CHI_CHK_OFF
// disables them. Violations print "CHI_CHK ERROR: SPEC_...", which
// run_regression.ps1 counts as a failure.
module chi_sysco_checker #(
    parameter integer NUM_RN = 2,
    parameter integer NUM_HN = 1,
    parameter integer NUM_SN = 1,
    parameter integer NUM_MN = 1
)(
    input                                   clk,
    input                                   rstn,
    input [NUM_RN-1:0]                      syscoreq,
    input [NUM_RN-1:0]                      syscoack,
    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] txsactive,
    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] rxsactive,
    // Flits leaving a node. REQ source i is node i (RNs, then HNs); SNP
    // source i is HN i, then the MNs.
    input [NUM_RN+NUM_HN-1:0]               req_tx,
    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] rsp_tx,
    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] dat_tx,
    input [NUM_HN+NUM_MN-1:0]               snp_tx,
    // Flits handed to a node. REQ target i is node NUM_RN + i; SNP target i
    // is RN i.
    input [NUM_HN+NUM_SN+NUM_MN-1:0]        req_rx,
    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] rsp_rx,
    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] dat_rx,
    input [NUM_RN-1:0]                      snp_rx
);
    localparam integer NUM_NODES  = NUM_RN + NUM_HN + NUM_SN + NUM_MN;
    localparam integer HN_BASE_ID = NUM_RN;
    localparam integer MN_BASE_ID = NUM_RN + NUM_HN + NUM_SN;

    bit     sactive_on;
    bit     sysco_on;
    int     sactive_errors;
    int     sysco_errors;
    longint n_join;
    longint n_leave;
    longint n_snp;
    longint cycle;
    reg [NUM_RN-1:0] req_q;
    reg [NUM_RN-1:0] ack_q;

    initial begin
        sactive_on = !$test$plusargs("CHI_CHK_OFF") &&
                     ($test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_SACTIVE"));
        sysco_on = !$test$plusargs("CHI_CHK_OFF") &&
                   ($test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_SYSCO"));
        sactive_errors = 0;
        sysco_errors = 0;
        n_join = 0;
        n_leave = 0;
        n_snp = 0;
        cycle = 0;
    end

    task automatic sactive_err(input string msg);
        sactive_errors = sactive_errors + 1;
        if (sactive_errors <= 20)
            $display("[%0t] CHI_CHK ERROR: SPEC_SACTIVE %s (cycle %0d)", $time, msg, cycle);
    endtask

    task automatic sysco_err(input string msg);
        sysco_errors = sysco_errors + 1;
        if (sysco_errors <= 20)
            $display("[%0t] CHI_CHK ERROR: SPEC_SYSCO %s (cycle %0d)", $time, msg, cycle);
    endtask

    // Messages are only built on a violation: xsim 2024.1 does not free the
    // string temporaries of a task call made every cycle.
    integer i;
    integer snp_node;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            req_q = {NUM_RN{1'b0}};
            ack_q = {NUM_RN{1'b0}};
        end else begin
            cycle = cycle + 1;
            if (sactive_on) begin
                for (i = 0; i < NUM_RN + NUM_HN; i = i + 1)
                    if (req_tx[i] && !txsactive[i])
                        sactive_err($sformatf("node %0d sent a REQ flit with TXSACTIVE low", i));
                for (i = 0; i < NUM_NODES; i = i + 1) begin
                    if (rsp_tx[i] && !txsactive[i])
                        sactive_err($sformatf("node %0d sent a RSP flit with TXSACTIVE low", i));
                    if (dat_tx[i] && !txsactive[i])
                        sactive_err($sformatf("node %0d sent a DAT flit with TXSACTIVE low", i));
                    if (rsp_rx[i] && !rxsactive[i])
                        sactive_err($sformatf("node %0d was handed a RSP flit with RXSACTIVE low", i));
                    if (dat_rx[i] && !rxsactive[i])
                        sactive_err($sformatf("node %0d was handed a DAT flit with RXSACTIVE low", i));
                end
                for (i = 0; i < NUM_HN + NUM_MN; i = i + 1) begin
                    snp_node = (i < NUM_HN) ? (HN_BASE_ID + i) : (MN_BASE_ID + i - NUM_HN);
                    if (snp_tx[i] && !txsactive[snp_node])
                        sactive_err($sformatf("node %0d sent a SNP flit with TXSACTIVE low", snp_node));
                end
                for (i = 0; i < NUM_HN + NUM_SN + NUM_MN; i = i + 1)
                    if (req_rx[i] && !rxsactive[NUM_RN + i])
                        sactive_err($sformatf("node %0d was handed a REQ flit with RXSACTIVE low", NUM_RN + i));
                for (i = 0; i < NUM_RN; i = i + 1) begin
                    if (snp_rx[i] && !rxsactive[i])
                        sactive_err($sformatf("node %0d was handed a SNP flit with RXSACTIVE low", i));
                    if ((syscoreq[i] != syscoack[i]) && !txsactive[i])
                        sactive_err($sformatf("RN %0d has TXSACTIVE low in a coherency state transition (SYSCOREQ=%0b SYSCOACK=%0b)",
                                              i, syscoreq[i], syscoack[i]));
                end
            end
            if (sysco_on) begin
                for (i = 0; i < NUM_RN; i = i + 1) begin
                    if ((syscoreq[i] != req_q[i]) && (ack_q[i] != req_q[i]))
                        sysco_err($sformatf("RN %0d: SYSCOREQ went %0b -> %0b while SYSCOACK was %0b",
                                            i, req_q[i], syscoreq[i], ack_q[i]));
                    if ((syscoack[i] != ack_q[i]) && (req_q[i] == ack_q[i]))
                        sysco_err($sformatf("RN %0d: SYSCOACK went %0b -> %0b while SYSCOREQ was %0b",
                                            i, ack_q[i], syscoack[i], req_q[i]));
                    if (syscoack[i] && !ack_q[i])
                        n_join = n_join + 1;
                    if (!syscoack[i] && ack_q[i])
                        n_leave = n_leave + 1;
                    if (snp_rx[i]) begin
                        n_snp = n_snp + 1;
                        if (!syscoreq[i] && !syscoack[i])
                            sysco_err($sformatf("RN %0d was snooped outside the coherency domain (SYSCOREQ=0 SYSCOACK=0)", i));
                    end
                end
            end
            req_q = syscoreq;
            ack_q = syscoack;
        end
    end

    final begin
        if (sactive_on || sysco_on)
            $display("CHI_CHK SUMMARY %m SPEC_SACTIVE violations=%0d SPEC_SYSCO violations=%0d joins=%0d leaves=%0d snoops=%0d",
                     sactive_errors, sysco_errors, n_join, n_leave, n_snp);
    end
endmodule
