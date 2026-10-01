`timescale 1ns/1ps
`include "chi_defs.vh"

// CHI protocol checker (roadmap 4.2), simulation only.
//
// Bound into every chi_top instance by chi_checker_binds. It watches every
// flit where the fabric hands it to the receiving node (REQ, RSP, DAT, SNP)
// and tracks each transaction by (requester, TxnID) and each snoop by
// (home, snoopee, TxnID). The node-local B5 monitors in formal/ check single
// blocks; this one checks the end-to-end exchange between nodes.
//
// Default rules check the transaction contract the RTL implements today:
//   read   : REQ -> 16 CompData beats -> (RN requester) CompAck
//   CleanUnique: REQ -> Comp -> (RN requester) CompAck
//   write  : REQ -> DBIDResp -> 16 WriteData beats -> Comp
//            (to an SN, WriteData may come before or without DBIDResp)
//   DVMOp  : REQ -> DBIDResp -> 1 NonCopyBackWriteData beat -> Comp
//   other  : REQ -> Comp
//   retry  : RetryAck, then the requester resends with the same TxnID
//   snoop  : SNP -> SnpRespData, or SnpResp; a forwarding snoop may also
//            send CompData to the requester and answer SnpRespFwded or
//            SnpRespDataFwded
//   SnpDVMOp: Part 1 and Part 2 (same TxnID, SNP.Addr[0]) -> SnpResp
//
// Rules the RTL does not meet yet, because they belong to roadmap phase 2,
// are off by default. Each one is enabled by +CHK_SPEC_<NAME>, or all of them
// by +CHK_SPEC_ALL. A phase-2 step turns its rule on and must keep it clean:
//   COMPACK_DBID     (2.1) CompAck.TxnID == DBID of the CompData
//   WDAT_TXNID_DBID  (2.1) WriteData.TxnID == DBID of the DBIDResp
//   COMPDATA_RESP    (2.2) CompData.Resp legal for the read opcode
//   SNPRESPDATA_ONLY (2.3) SnpRespData ends the snoop, no SnpResp after it
//   COPYBACK_COMPDBID(2.4) WriteBack* gets CompDBIDResp, not DBIDResp
//   SN_DBID_FIRST    (2.4) WriteData to an SN only after its DBIDResp
//   SNP_TXNID_HOME   (1.3) snoop TxnID unique per home over all snoopees
//   EXCL_OPCODE      (2.5) Excl=1 only on ReadShared, ReadNoSnp, CleanUnique
//                          or WriteNoSnp (B6.3); never ReadUnique/WriteUnique
//   DVM              (2.7) B8: DVMOp is Size 8B, Order 0, no ExpCompAck; its
//                          payload is one NonCopyBackWriteData beat with
//                          BE[7:0], DataID 0; Comp only after it; the MN
//                          snoops every other RN once (no Sync of its own,
//                          not the requester), after the payload; SnpResp
//                          only after both parts; Comp/SnpResp Resp zero
//   MKUNIQUE_COMPACK (2.8) while an RN owes the CompAck of a CleanUnique or
//                          MakeUnique, its home sends no snoop to that line
//                          (B5.6.4: the CompAck unblocks the next request)
//   SNPRESP_FWD      (2.9) a forwarding snoop gets one response: SnpRespFwded
//                          or SnpRespDataFwded, never followed by data to
//                          the home; Resp (snoopee state) and FwdState are a
//                          legal pair (Tables B4.58, B4.59; no data to the
//                          home after SnpUniqueFwd); FwdState equals the
//                          Resp of the CompData sent to the requester; a
//                          snoopee that forwarded CompData does not answer
//                          plain SnpResp/SnpRespData; while a forwarding
//                          snoop is open its home sends no other snoop to
//                          that line (B4.8.3.4: one RN-F)
//
// Every violation prints "CHI_CHK ERROR: <rule>", which run_regression.ps1
// counts as a failure. +CHI_CHK_OFF disables the checker.
module chi_protocol_checker #(
    parameter integer NUM_RN     = 2,
    parameter integer NUM_HN     = 1,
    parameter integer NUM_SN     = 1,
    parameter integer NUM_MN     = 1,
    // CHI DAT channel data width.
    parameter integer DATA_WIDTH = 128,
    parameter integer ADDR_WIDTH = 32,
    parameter integer NODE_ID_W  = 7,
    parameter integer TXN_ID_W   = 12,
    parameter integer QOS_W      = 4,
    parameter integer DBID_W     = 12,
    parameter integer LIVENESS_CYCLES = 20000
)(
    input clk,
    input rstn,

    input [NUM_HN+NUM_SN+NUM_MN-1:0] req_valid,
    input [NUM_HN+NUM_SN+NUM_MN-1:0] req_ready,
    input [(NUM_HN+NUM_SN+NUM_MN)*`CHI_REQ_W(NODE_ID_W)-1:0] req_flit,

    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] rsp_valid,
    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] rsp_ready,
    input [(NUM_RN+NUM_HN+NUM_SN+NUM_MN)*`CHI_RSP_W(NODE_ID_W)-1:0] rsp_flit,

    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] dat_valid,
    input [NUM_RN+NUM_HN+NUM_SN+NUM_MN-1:0] dat_ready,
    input [(NUM_RN+NUM_HN+NUM_SN+NUM_MN)*`CHI_DAT_W(DATA_WIDTH,NODE_ID_W)-1:0] dat_flit,

    input [NUM_RN-1:0] snp_valid,
    input [NUM_RN-1:0] snp_ready,
    input [NUM_RN*`CHI_SNP_W(NODE_ID_W)-1:0] snp_flit
);
    localparam integer NUM_REQ_TGT = NUM_HN + NUM_SN + NUM_MN;
    localparam integer NUM_NODES   = NUM_RN + NUM_HN + NUM_SN + NUM_MN;
    localparam integer SN_BASE_ID  = NUM_RN + NUM_HN;
    localparam integer BEATS       = 512 / DATA_WIDTH;

    localparam REQ_W = `CHI_REQ_W(NODE_ID_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W);
    localparam DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W);
    localparam SNP_W = `CHI_SNP_W(NODE_ID_W);

    localparam REQ_OPCODE_LSB = `CHI_REQ_OPCODE_LSB(NODE_ID_W);
    localparam REQ_TXN_LSB    = `CHI_REQ_TXN_LSB(NODE_ID_W);
    localparam REQ_SRC_LSB    = `CHI_REQ_SRC_LSB(NODE_ID_W);
    localparam REQ_TGT_LSB    = `CHI_REQ_TGT_LSB(NODE_ID_W);
    localparam REQ_EXCL_LSB   = `CHI_REQ_EXCL_LSB(NODE_ID_W);
    localparam REQ_SIZE_LSB   = `CHI_REQ_SIZE_LSB(NODE_ID_W);
    localparam REQ_ORDER_LSB  = `CHI_REQ_ORDER_LSB(NODE_ID_W);
    localparam REQ_EXP_COMP_ACK_LSB = `CHI_REQ_EXP_COMP_ACK_LSB(NODE_ID_W);
    localparam REQ_ADDR_LSB   = `CHI_REQ_ADDR_LSB(NODE_ID_W);

    localparam RSP_RESP_LSB    = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam DAT_BE_LSB      = `CHI_DAT_BE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DATA_WIDTH,NODE_ID_W);
    localparam RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(NODE_ID_W);

    localparam DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_OPCODE_LSB  = `CHI_DAT_OPCODE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_HOME_NID_LSB  = `CHI_DAT_HOME_NID_LSB(DATA_WIDTH,NODE_ID_W);
    localparam DAT_FWD_STATE_LSB = `CHI_DAT_FWD_STATE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam RSP_FWD_STATE_LSB = `CHI_RSP_FWD_STATE_LSB(NODE_ID_W);

    localparam SNP_OPCODE_LSB = `CHI_SNP_OPCODE_LSB(NODE_ID_W);
    localparam SNP_TXN_LSB    = `CHI_SNP_TXN_LSB(NODE_ID_W);
    localparam SNP_SRC_LSB    = `CHI_SNP_SRC_LSB(NODE_ID_W);
    localparam SNP_ADDR_LSB   = `CHI_SNP_ADDR_LSB(NODE_ID_W);

    typedef struct {
        int                  src;
        int                  tgt;
        int                  txn;
        bit [`CHI_REQ_OPCODE_W-1:0] op;
        bit [ADDR_WIDTH-1:0] addr;
        bit                  is_read;
        bit                  is_write;
        // A CleanUnique or MakeUnique from an RN owes a CompAck after its
        // Comp (B2.7.2, Table B2.8).
        bit                  ack_on_comp;
        // DVMOp: one payload beat, and the RNs its SnpDVMOps went to.
        bit                  is_dvm;
        int                  need_beats;
        bit [63:0]           dvm_snooped;
        bit                  retried;
        bit                  got_dbid;
        bit                  got_comp;
        bit [DBID_W-1:0]     dbid;
        int                  wbeats;
        bit [15:0]           rmask;
        int                  rbeats;
        bit [DBID_W-1:0]     cd_dbid;
        longint              t0;
        bit                  live_reported;
    } txn_t;

    typedef struct {
        int                  src;
        int                  home;
        int                  txn;
        bit [DBID_W-1:0]     dbid;
        // Line of a CleanUnique/MakeUnique: the home holds it until the
        // CompAck arrives.
        bit                  upgrade;
        bit [ADDR_WIDTH-1:0] addr;
        longint              t0;
        bit                  live_reported;
    } ack_t;

    typedef struct {
        int                  home;
        int                  rn;
        int                  txn;
        bit [`CHI_REQ_OPCODE_W-1:0] op;
        bit [ADDR_WIDTH-1:0] addr;
        int                  dbeats;
        // SnpDVMOp parts received, indexed by SNP.Addr[0].
        bit [1:0]            parts;
        // Forwarding snoop: answered by SnpRespFwded; FwdState reported;
        // Resp of the CompData the snoopee sent to the requester.
        bit                  fwd_rsp;
        bit                  fwd_state_valid;
        bit [2:0]            fwd_state;
        bit                  cd_seen;
        bit [2:0]            cd_resp;
        longint              t0;
        bit                  live_reported;
    } snp_t;

    txn_t   txns  [longint];
    snp_t   snps  [longint];
    int     early_wdat [longint];
    ack_t   acks  [$];
    // SnpRespData beats still owed after the SnpResp closed the snoop. The
    // snoopee hands its data beats to the link first, but the single SnpResp
    // flit overtakes them on the RSP channel; with forwarding, the copy to
    // the home follows SnpRespFwded.
    snp_t   snp_tail [longint];
    // DVMOp being served by each MN (its txns key); the MN takes one at a
    // time.
    longint dvm_active [int];
    int     rule_cnt [string];

    bit     enabled;
    // +TRACE_LINE=<hex addr>: print every flit that belongs to that line.
    bit                  trace_on;
    bit [ADDR_WIDTH-1:0] trace_line;
    bit     spec_compack_dbid;
    bit     spec_wdat_txnid_dbid;
    bit     spec_compdata_resp;
    bit     spec_snprespdata_only;
    bit     spec_copyback_compdbid;
    bit     spec_sn_dbid_first;
    bit     spec_snp_txnid_home;
    bit     spec_excl_opcode;
    bit     spec_dvm;
    bit     spec_mkunique_compack;
    bit     spec_snpresp_fwd;

    longint cycle;
    int     errors;
    int     n_req;
    int     n_snp;
    // Forwarding snoops answered by SnpRespFwded / SnpRespDataFwded.
    int     n_fwd_rsp;
    int     n_fwd_dat;
    int     n_done;
    // Open transactions, snoops and CompAcks still owed; read by the
    // coherence scoreboard to find quiet points.
    int     n_open;

    initial begin
        enabled = !$test$plusargs("CHI_CHK_OFF");
        trace_on = $value$plusargs("TRACE_LINE=%h", trace_line);
        spec_compack_dbid      = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_COMPACK_DBID");
        spec_wdat_txnid_dbid   = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_WDAT_TXNID_DBID");
        spec_compdata_resp     = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_COMPDATA_RESP");
        spec_snprespdata_only  = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_SNPRESPDATA_ONLY");
        spec_copyback_compdbid = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_COPYBACK_COMPDBID");
        spec_sn_dbid_first     = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_SN_DBID_FIRST");
        spec_snp_txnid_home    = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_SNP_TXNID_HOME");
        spec_excl_opcode       = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_EXCL_OPCODE");
        spec_dvm               = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_DVM");
        spec_mkunique_compack  = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_MKUNIQUE_COMPACK");
        spec_snpresp_fwd       = $test$plusargs("CHK_SPEC_ALL") || $test$plusargs("CHK_SPEC_SNPRESP_FWD");
        cycle  = 0;
        errors = 0;
        n_req  = 0;
        n_snp  = 0;
        n_fwd_rsp = 0;
        n_fwd_dat = 0;
        n_done = 0;
        n_open = 0;
    end

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function automatic longint tkey(input int node, input int txn);
        tkey = (longint'(node) << TXN_ID_W) | longint'(txn);
    endfunction

    function automatic longint skey(input int home, input int rn, input int txn);
        skey = (longint'(home) << (NODE_ID_W + TXN_ID_W)) |
               (longint'(rn) << TXN_ID_W) | longint'(txn);
    endfunction

    function automatic bit op_is_read(input bit [`CHI_REQ_OPCODE_W-1:0] op);
        op_is_read = (op == `CHI_REQ_RD_SHARED) || (op == `CHI_REQ_RD_ONCE) ||
                     (op == `CHI_REQ_RD_UNIQUE) || (op == `CHI_REQ_RD_NO_SNP);
    endfunction

    function automatic bit op_is_write(input bit [`CHI_REQ_OPCODE_W-1:0] op);
        op_is_write = (op == `CHI_REQ_WB_FULL) || (op == `CHI_REQ_WB_PTL) ||
                      (op == `CHI_REQ_WR_UNIQUE) || (op == `CHI_REQ_WR_NO_SNP);
    endfunction

    function automatic bit op_is_copyback(input bit [`CHI_REQ_OPCODE_W-1:0] op);
        op_is_copyback = (op == `CHI_REQ_WB_FULL) || (op == `CHI_REQ_WB_PTL);
    endfunction

    function automatic bit node_is_rn(input int node);
        node_is_rn = (node >= 0) && (node < NUM_RN);
    endfunction

    function automatic bit node_is_sn(input int node);
        node_is_sn = (node >= SN_BASE_ID) && (node < SN_BASE_ID + NUM_SN);
    endfunction

    // CompData Resp encodings (IHI0050H Table B13.35): I=0, SC=1, UC=2,
    // UD_PD=6, SD_PD=7.
    function automatic bit compdata_resp_ok(input bit [`CHI_REQ_OPCODE_W-1:0] op, input bit [2:0] resp);
        case (op)
            `CHI_REQ_RD_SHARED: compdata_resp_ok = (resp == 3'd1) || (resp == 3'd2) ||
                                                   (resp == 3'd6) || (resp == 3'd7);
            `CHI_REQ_RD_UNIQUE: compdata_resp_ok = (resp == 3'd2) || (resp == 3'd6);
            default:            compdata_resp_ok = (resp == 3'd0);
        endcase
    endfunction

    function automatic bit is_fwd_snp(input bit [`CHI_SNP_OPCODE_W-1:0] op);
        is_fwd_snp = (op == `CHI_SNP_SHARED_FWD) || (op == `CHI_SNP_UNIQUE_FWD);
    endfunction

    // Legal (Resp, FwdState) of a forwarding snoop's response (Tables B4.58,
    // B4.59, B13.37). with_data: SnpRespDataFwded.
    function automatic bit fwd_pair_ok(input bit [`CHI_REQ_OPCODE_W-1:0] op,
                                       input bit [2:0] resp,
                                       input bit [2:0] fwd,
                                       input bit       with_data);
        fwd_pair_ok = 1'b0;
        if (op == `CHI_SNP_SHARED_FWD) begin
            if (fwd == `CHI_COMPDATA_RESP_SC)
                fwd_pair_ok = (resp == `CHI_COMPDATA_RESP_I) ||
                              (resp == `CHI_COMPDATA_RESP_SC) ||
                              (resp == `CHI_SNPRESP_SD) ||
                              (with_data && ((resp == `CHI_SNPRESP_I_PD) ||
                                             (resp == `CHI_SNPRESP_SC_PD)));
            else if (fwd == `CHI_COMPDATA_RESP_SD_PD)
                fwd_pair_ok = (resp == `CHI_COMPDATA_RESP_I) ||
                              (resp == `CHI_COMPDATA_RESP_SC);
        end else if (op == `CHI_SNP_UNIQUE_FWD) begin
            fwd_pair_ok = !with_data && (resp == `CHI_COMPDATA_RESP_I) &&
                          ((fwd == `CHI_COMPDATA_RESP_UC) ||
                           (fwd == `CHI_COMPDATA_RESP_UD_PD));
        end
    endfunction

    function automatic bit traced(input bit [ADDR_WIDTH-1:0] a);
        traced = trace_on && (a[ADDR_WIDTH-1:6] == trace_line[ADDR_WIDTH-1:6]);
    endfunction

    // Line of the transaction or snoop a RSP/DAT flit belongs to, if known.
    function automatic bit flit_traced(input int src, input int tgt, input int txn);
        longint k;
        flit_traced = 1'b0;
        if (!trace_on)
            return 0;
        k = tkey(tgt, txn);
        if (txns.exists(k) && traced(txns[k].addr)) return 1;
        k = tkey(src, txn);
        if (txns.exists(k) && traced(txns[k].addr)) return 1;
        k = skey(tgt, src, txn);
        if (snps.exists(k) && traced(snps[k].addr)) return 1;
        if (snp_tail.exists(k) && traced(snp_tail[k].addr)) return 1;
        foreach (txns[kk])
            if (txns[kk].got_dbid && (txns[kk].dbid == txn) &&
                (txns[kk].src == src) && traced(txns[kk].addr))
                return 1;
    endfunction

    task automatic err(input string rule, input string msg);
        errors = errors + 1;
        if (rule_cnt.exists(rule))
            rule_cnt[rule] = rule_cnt[rule] + 1;
        else
            rule_cnt[rule] = 1;
        if (errors <= 50)
            $display("[%0t] CHI_CHK ERROR: %s %s", $time, rule, msg);
        else if (errors == 51)
            $display("[%0t] CHI_CHK ERROR: further violations counted but not printed", $time);
    endtask

    function automatic string tstr(input txn_t t);
        tstr = $sformatf("src=%0d tgt=%0d txn=0x%0h op=0x%02h addr=0x%0h",
                         t.src, t.tgt, t.txn, t.op, t.addr);
    endfunction

    // Clear all tracking, e.g. after a reset or when a testbench re-enables
    // the checker after driving the DUT outside the protocol.
    task automatic reset_state;
        txns.delete();
        snps.delete();
        snp_tail.delete();
        early_wdat.delete();
        acks.delete();
        dvm_active.delete();
    endtask

    task automatic close_txn(input longint k);
        ack_t a;
        if ((txns[k].is_read && node_is_rn(txns[k].src) && (txns[k].rbeats == BEATS)) ||
            txns[k].ack_on_comp) begin
            a.src  = txns[k].src;
            a.home = txns[k].tgt;
            a.txn  = txns[k].txn;
            a.dbid = txns[k].cd_dbid;
            a.upgrade = txns[k].ack_on_comp;
            a.addr = txns[k].addr;
            a.t0   = cycle;
            a.live_reported = 1'b0;
            acks.push_back(a);
        end
        txns.delete(k);
        n_done = n_done + 1;
    endtask

    // A write closes once its Comp is in and, if it got a DBID, all its data.
    task automatic try_close_write(input longint k);
        if (txns[k].got_comp &&
            (!txns[k].got_dbid || (txns[k].wbeats >= txns[k].need_beats) ||
             node_is_sn(txns[k].tgt)))
            close_txn(k);
    endtask

    // ------------------------------------------------------------------
    // REQ: a new transaction reaches its completer.
    // ------------------------------------------------------------------
    task automatic on_req(input [REQ_W-1:0] f);
        txn_t     t;
        longint   k;
        bit [`CHI_REQ_OPCODE_W-1:0] op;
        op = f[REQ_OPCODE_LSB +: `CHI_REQ_OPCODE_W];
        if (op == `CHI_REQ_PCRD_RETURN)
            return;
        t.src  = f[REQ_SRC_LSB +: NODE_ID_W];
        t.tgt  = f[REQ_TGT_LSB +: NODE_ID_W];
        t.txn  = f[REQ_TXN_LSB +: TXN_ID_W];
        t.op   = op;
        t.addr = f[`CHI_REQ_ADDR_LSB(NODE_ID_W) +: ADDR_WIDTH];
        k = tkey(t.src, t.txn);
        n_req = n_req + 1;
        if (traced(t.addr))
            $display("[%0t] CHI_TRACE REQ %0d->%0d op=0x%02h txn=0x%0h addr=0x%0h",
                     $time, t.src, t.tgt, op, t.txn, t.addr);

        if (txns.exists(k)) begin
            if (txns[k].retried && (txns[k].op == op)) begin
                // Resend after RetryAck: the same transaction starts over.
                txns[k].retried = 1'b0;
                txns[k].t0      = cycle;
                return;
            end
            err("REQ_TXNID_REUSE",
                $sformatf("new REQ op=0x%02h tgt=%0d while outstanding %s",
                          op, t.tgt, tstr(txns[k])));
        end

        t.is_read       = op_is_read(op);
        t.is_dvm        = (op == `CHI_REQ_DVM_OP);
        // A DVMOp is written like an 8-byte write: DBIDResp, one beat.
        t.is_write      = op_is_write(op) || t.is_dvm;
        t.need_beats    = t.is_dvm ? 1 : BEATS;
        t.dvm_snooped   = '0;
        t.ack_on_comp   = ((op == `CHI_REQ_CLN_UNIQUE) ||
                           (op == `CHI_REQ_MK_UNIQUE)) && node_is_rn(t.src);
        if (t.is_dvm) begin
            if (spec_dvm &&
                ((f[REQ_SIZE_LSB +: 3] != `CHI_DVM_REQ_SIZE) ||
                 (f[REQ_ORDER_LSB +: 2] != 2'b00) ||
                 f[REQ_EXP_COMP_ACK_LSB] || f[REQ_ADDR_LSB + 3]))
                err("SPEC_DVM",
                    $sformatf("DVMOp fields Size=%0d Order=%0d ExpCompAck=%0b Addr[3]=%0b src=%0d txn=0x%0h",
                              f[REQ_SIZE_LSB +: 3], f[REQ_ORDER_LSB +: 2],
                              f[REQ_EXP_COMP_ACK_LSB], f[REQ_ADDR_LSB + 3],
                              t.src, t.txn));
            dvm_active[t.tgt] = k;
        end
        if (spec_excl_opcode && f[REQ_EXCL_LSB] &&
            !((op == `CHI_REQ_RD_SHARED) || (op == `CHI_REQ_RD_NO_SNP) ||
              (op == `CHI_REQ_CLN_UNIQUE) || (op == `CHI_REQ_WR_NO_SNP)))
            err("SPEC_EXCL_OPCODE",
                $sformatf("Excl=1 on op=0x%02h src=%0d txn=0x%0h addr=0x%0h",
                          op, t.src, t.txn, t.addr));
        t.retried       = 1'b0;
        t.got_dbid      = 1'b0;
        t.got_comp      = 1'b0;
        t.dbid          = '0;
        t.wbeats        = 0;
        t.rmask         = '0;
        t.rbeats        = 0;
        t.cd_dbid       = '0;
        t.t0            = cycle;
        t.live_reported = 1'b0;

        // WriteData to an SN may overtake its REQ through the fabric.
        if (early_wdat.exists(k)) begin
            t.wbeats = early_wdat[k];
            early_wdat.delete(k);
        end
        txns[k] = t;
    endtask

    // ------------------------------------------------------------------
    // SNP: a snoop reaches an RN.
    // ------------------------------------------------------------------
    task automatic on_snp(input int rn, input [SNP_W-1:0] f);
        snp_t   s;
        snp_t   o;
        ack_t   a;
        longint k;
        longint ka;
        int     part;
        s.home   = f[SNP_SRC_LSB +: NODE_ID_W];
        s.rn     = rn;
        s.txn    = f[SNP_TXN_LSB +: TXN_ID_W];
        s.op     = f[SNP_OPCODE_LSB +: `CHI_SNP_OPCODE_W];
        // SNP Addr is Addr[43:3].
        s.addr   = {f[`CHI_SNP_ADDR_LSB(NODE_ID_W) +: ADDR_WIDTH-3], 3'b000};
        s.dbeats = 0;
        s.parts  = '0;
        s.fwd_rsp = 1'b0;
        s.fwd_state_valid = 1'b0;
        s.fwd_state = 3'd0;
        s.cd_seen = 1'b0;
        s.cd_resp = 3'd0;
        s.t0     = cycle;
        s.live_reported = 1'b0;
        k = skey(s.home, rn, s.txn);
        if (traced(s.addr))
            $display("[%0t] CHI_TRACE SNP %0d->%0d op=0x%02h txn=0x%0h addr=0x%0h",
                     $time, s.home, rn, s.op, s.txn, s.addr);

        if (s.op == `CHI_SNP_DVM_OP) begin
            part = f[SNP_ADDR_LSB];
            // The other part of an open SnpDVMOp.
            if (snps.exists(k) && (snps[k].op == `CHI_SNP_DVM_OP) &&
                !snps[k].parts[part]) begin
                snps[k].parts[part] = 1'b1;
                return;
            end
            s.parts[part] = 1'b1;
            if (spec_dvm) begin
                if (!dvm_active.exists(s.home) ||
                    !txns.exists(dvm_active[s.home])) begin
                    err("SPEC_DVM",
                        $sformatf("SnpDVMOp home=%0d rn=%0d txn=0x%0h with no DVMOp open at that MN",
                                  s.home, rn, s.txn));
                end else begin
                    ka = dvm_active[s.home];
                    if (txns[ka].src == rn)
                        err("SPEC_DVM",
                            $sformatf("SnpDVMOp to the requester rn=%0d: %s",
                                      rn, tstr(txns[ka])));
                    if (txns[ka].dvm_snooped[rn])
                        err("SPEC_DVM",
                            $sformatf("second SnpDVMOp to rn=%0d for one DVMOp (MN-inserted Sync?): %s",
                                      rn, tstr(txns[ka])));
                    if (txns[ka].wbeats < 1)
                        err("SPEC_DVM",
                            $sformatf("SnpDVMOp to rn=%0d before the DVMOp payload: %s",
                                      rn, tstr(txns[ka])));
                    txns[ka].dvm_snooped[rn] = 1'b1;
                end
            end
        end
        n_snp = n_snp + 1;

        // A forwarding snoop is the only snoop its home has open on the line
        // (B4.8.3.4): a second snoopee could send the requester another copy.
        if (spec_snpresp_fwd && (s.op != `CHI_SNP_DVM_OP)) begin
            foreach (snps[ko]) begin
                o = snps[ko];
                if ((o.home == s.home) && (o.rn != rn) &&
                    (o.op != `CHI_SNP_DVM_OP) &&
                    (o.addr[ADDR_WIDTH-1:6] == s.addr[ADDR_WIDTH-1:6]) &&
                    (is_fwd_snp(o.op) || is_fwd_snp(s.op)))
                    err("SPEC_SNPRESP_FWD",
                        $sformatf("snoop op=0x%02h to rn=%0d while op=0x%02h to rn=%0d is open on line 0x%0h home=%0d",
                                  s.op, rn, o.op, o.rn, s.addr, s.home));
            end
        end

        if (snps.exists(k))
            err("SNP_TXNID_REUSE",
                $sformatf("snoop home=%0d rn=%0d txn=0x%0h op=0x%02h while the previous one is open",
                          s.home, rn, s.txn, s.op));
        if (snp_tail.exists(k)) begin
            if (snp_tail[k].dbeats != 0)
                err("SNPDATA_INCOMPLETE",
                    $sformatf("new snoop home=%0d rn=%0d txn=0x%0h before the previous SnpRespData finished (%0d/%0d beats)",
                              s.home, rn, s.txn, snp_tail[k].dbeats, BEATS));
            snp_tail.delete(k);
        end
        if (spec_mkunique_compack && (s.op != `CHI_SNP_DVM_OP)) begin
            foreach (acks[ai]) begin
                a = acks[ai];
                if (a.upgrade && (a.home == s.home) &&
                    ((a.addr >> 6) == (s.addr >> 6)))
                    err("SPEC_MKUNIQUE_COMPACK",
                        $sformatf("snoop op=0x%02h home=%0d rn=%0d addr=0x%0h while rn=%0d owes the CompAck of txn=0x%0h",
                                  s.op, s.home, rn, s.addr, a.src, a.txn));
            end
        end
        if (spec_snp_txnid_home) begin
            foreach (snps[kk]) begin
                if ((snps[kk].home == s.home) && (snps[kk].txn == s.txn) &&
                    (snps[kk].rn != rn))
                    err("SPEC_SNP_TXNID_HOME",
                        $sformatf("home=%0d txn=0x%0h open to rn=%0d and rn=%0d",
                                  s.home, s.txn, snps[kk].rn, rn));
            end
        end
        snps[k] = s;
    endtask

    // ------------------------------------------------------------------
    // RSP
    // ------------------------------------------------------------------
    task automatic on_rsp(input [RSP_W-1:0] f);
        bit [4:0]        op;
        int              src;
        int              tgt;
        int              txn;
        bit [1:0]        resperr;
        bit [DBID_W-1:0] dbid;
        longint          k;
        int              i;
        int              idx;
        bit [DBID_W-1:0] txn_dbid;
        bit [2:0]        resp;
        bit [2:0]        fwd;
        snp_t            s;

        op      = f[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W];
        src     = f[RSP_SRC_LSB +: NODE_ID_W];
        tgt     = f[RSP_TGT_LSB +: NODE_ID_W];
        txn     = f[RSP_TXN_LSB +: TXN_ID_W];
        resperr = f[RSP_RESPERR_LSB +: 2];
        dbid    = f[RSP_DBID_LSB +: DBID_W];
        if (flit_traced(src, tgt, txn))
            $display("[%0t] CHI_TRACE RSP %0d->%0d op=0x%02h txn=0x%0h dbid=0x%0h resp=%0d err=%0d",
                     $time, src, tgt, op, txn, dbid, f[RSP_RESP_LSB +: 3], resperr);

        case (op)
            `CHI_RSP_RESP_LCRD_RETURN,
            `CHI_RSP_PCRD_GRANT: ;

            `CHI_RSP_SNP_RESP,
            `CHI_RSP_SNP_RESP_FWD: begin
                k = skey(tgt, src, txn);
                if (op == `CHI_RSP_SNP_RESP_FWD)
                    n_fwd_rsp = n_fwd_rsp + 1;
                if (!snps.exists(k)) begin
                    err("SNPRSP_UNKNOWN",
                        $sformatf("SnpResp op=0x%0h rn=%0d home=%0d txn=0x%0h matches no open snoop",
                                  op, src, tgt, txn));
                end else begin
                    if (spec_dvm && (snps[k].op == `CHI_SNP_DVM_OP) &&
                        ((snps[k].parts != 2'b11) || (f[RSP_RESP_LSB +: 3] != 3'd0) ||
                         (op != `CHI_RSP_SNP_RESP)))
                        err("SPEC_DVM",
                            $sformatf("SnpDVMOp answered with op=0x%0h Resp=%0d after parts=%02b rn=%0d home=%0d txn=0x%0h",
                                      op, f[RSP_RESP_LSB +: 3], snps[k].parts,
                                      src, tgt, txn));
                    if (spec_snprespdata_only && (snps[k].dbeats != 0))
                        err("SPEC_SNPRESPDATA_ONLY",
                            $sformatf("SnpResp after SnpRespData rn=%0d home=%0d txn=0x%0h",
                                      src, tgt, txn));
                    if (spec_snpresp_fwd) begin
                        s    = snps[k];
                        resp = f[RSP_RESP_LSB +: 3];
                        fwd  = f[RSP_FWD_STATE_LSB +: 3];
                        if (op == `CHI_RSP_SNP_RESP_FWD) begin
                            if (!fwd_pair_ok(s.op, resp, fwd, 1'b0))
                                err("SPEC_SNPRESP_FWD",
                                    $sformatf("SnpRespFwded Resp=%0d FwdState=%0d to snoop op=0x%02h rn=%0d home=%0d txn=0x%0h",
                                              resp, fwd, s.op, src, tgt, txn));
                            if (s.cd_seen && (s.cd_resp != fwd))
                                err("SPEC_SNPRESP_FWD",
                                    $sformatf("SnpRespFwded FwdState=%0d but CompData Resp=%0d rn=%0d home=%0d txn=0x%0h",
                                              fwd, s.cd_resp, src, tgt, txn));
                            snps[k].fwd_rsp = 1'b1;
                            snps[k].fwd_state_valid = 1'b1;
                            snps[k].fwd_state = fwd;
                        end else if (s.cd_seen) begin
                            err("SPEC_SNPRESP_FWD",
                                $sformatf("SnpResp (not Fwded) after forwarding CompData rn=%0d home=%0d txn=0x%0h",
                                          src, tgt, txn));
                        end
                    end
                    // Keep a tail for data beats still in flight; a tail
                    // with no beats yet is dropped by the next snoop.
                    if (snps[k].dbeats < BEATS) begin
                        snp_tail[k] = snps[k];
                        snp_tail[k].t0 = cycle;
                    end
                    snps.delete(k);
                end
            end

            `CHI_RSP_COMP_ACK: begin
                // Spec: CompAck carries the DBID of the CompData. Current
                // contract: it carries the requester's TxnID. With the spec
                // rule on, a TxnID match still retires the entry so one
                // violation is reported once and does not cascade.
                idx = -1;
                txn_dbid = txn;
                if (spec_compack_dbid) begin
                    for (i = 0; i < acks.size(); i = i + 1)
                        if ((idx < 0) && (acks[i].src == src) && (acks[i].home == tgt) &&
                            (acks[i].dbid == txn_dbid))
                            idx = i;
                    if (idx < 0)
                        err("SPEC_COMPACK_DBID",
                            $sformatf("CompAck src=%0d home=%0d txn=0x%0h is not the DBID of a completed read",
                                      src, tgt, txn));
                end
                if (idx < 0) begin
                    for (i = 0; i < acks.size(); i = i + 1)
                        if ((idx < 0) && (acks[i].src == src) && (acks[i].home == tgt) &&
                            (acks[i].txn == txn))
                            idx = i;
                    // (xsim 2024.1 crashes on a ?: of string literals passed
                    // to a task, so rule names are chosen with if/else.)
                    if ((idx < 0) && !spec_compack_dbid)
                        err("COMPACK_UNMATCHED",
                            $sformatf("CompAck src=%0d home=%0d txn=0x%0h matches no completed read",
                                      src, tgt, txn));
                end
                if (idx >= 0)
                    acks.delete(idx);
            end

            `CHI_RSP_COMP,
            `CHI_RSP_COMP_DBID,
            `CHI_RSP_DBID,
            `CHI_RSP_RETRY_ACK,
            `CHI_RSP_READ_RECEIPT: begin
                k = tkey(tgt, txn);
                if (!txns.exists(k)) begin
                    err("RSP_UNKNOWN_TXN",
                        $sformatf("RSP op=0x%0h src=%0d to=%0d txn=0x%0h matches no outstanding request",
                                  op, src, tgt, txn));
                    return;
                end
                if (txns[k].tgt != src)
                    err("RSP_WRONG_SRC",
                        $sformatf("RSP op=0x%0h from %0d for %s", op, src, tstr(txns[k])));

                if (op == `CHI_RSP_RETRY_ACK) begin
                    txns[k].retried = 1'b1;
                end else if (op != `CHI_RSP_READ_RECEIPT) begin
                    if ((op == `CHI_RSP_DBID) || (op == `CHI_RSP_COMP_DBID)) begin
                        if (!txns[k].is_write)
                            err("DBID_FOR_NON_WRITE",
                                $sformatf("DBID op=0x%0h for %s", op, tstr(txns[k])));
                        if (txns[k].got_dbid)
                            err("DBID_TWICE", tstr(txns[k]));
                        foreach (txns[kk]) begin
                            if ((kk != k) && txns[kk].got_dbid &&
                                (txns[kk].tgt == src) && (txns[kk].dbid == dbid) &&
                                (txns[kk].wbeats < txns[kk].need_beats))
                                err("DBID_DUP",
                                    $sformatf("DBID 0x%0h from %0d for %s already held by %s",
                                              dbid, src, tstr(txns[k]), tstr(txns[kk])));
                        end
                        if (spec_copyback_compdbid && op_is_copyback(txns[k].op) &&
                            (op == `CHI_RSP_DBID))
                            err("SPEC_COPYBACK_COMPDBID",
                                $sformatf("CopyBack got DBIDResp instead of CompDBIDResp: %s",
                                          tstr(txns[k])));
                        txns[k].got_dbid = 1'b1;
                        txns[k].dbid     = dbid;
                    end
                    if ((op == `CHI_RSP_COMP) || (op == `CHI_RSP_COMP_DBID)) begin
                        if ((op == `CHI_RSP_COMP) && txns[k].is_write &&
                            txns[k].got_dbid && (txns[k].wbeats < txns[k].need_beats) &&
                            (resperr == `CHI_RESPERR_OK) && !node_is_sn(txns[k].tgt))
                            err("COMP_BEFORE_WDAT",
                                $sformatf("Comp after %0d/%0d data beats: %s",
                                          txns[k].wbeats, txns[k].need_beats, tstr(txns[k])));
                        if (spec_dvm && txns[k].is_dvm) begin
                            if (!txns[k].got_dbid || (txns[k].wbeats < 1) ||
                                (f[RSP_RESP_LSB +: 3] != 3'd0))
                                err("SPEC_DVM",
                                    $sformatf("DVMOp Comp (dbid=%0b payload=%0d Resp=%0d): %s",
                                              txns[k].got_dbid, txns[k].wbeats,
                                              f[RSP_RESP_LSB +: 3], tstr(txns[k])));
                            // Every RN but the requester was snooped once.
                            if ((resperr == `CHI_RESPERR_OK) &&
                                (txns[k].dvm_snooped !=
                                 ((((64'd1 << NUM_RN) - 64'd1)) &
                                  ~(64'd1 << txns[k].src))))
                                err("SPEC_DVM",
                                    $sformatf("DVMOp completed after SnpDVMOp to RN mask 0x%0h: %s",
                                              txns[k].dvm_snooped, tstr(txns[k])));
                        end
                        if (txns[k].is_dvm && dvm_active.exists(txns[k].tgt) &&
                            (dvm_active[txns[k].tgt] == k))
                            dvm_active.delete(txns[k].tgt);
                        txns[k].got_comp = 1'b1;
                        if (txns[k].is_write) begin
                            try_close_write(k);
                        end else begin
                            txns[k].cd_dbid = dbid;
                            close_txn(k);
                        end
                    end
                end
            end

            default:
                err("RSP_BAD_OPCODE",
                    $sformatf("RSP opcode 0x%0h src=%0d to=%0d txn=0x%0h", op, src, tgt, txn));
        endcase
    endtask

    // ------------------------------------------------------------------
    // DAT
    // ------------------------------------------------------------------
    task automatic on_dat(input [DAT_W-1:0] f);
        bit [3:0]        op;
        int              src;
        int              tgt;
        int              txn;
        int              beat;
        bit [2:0]        resp;
        bit [DBID_W-1:0] dbid;
        bit [DBID_W-1:0] txn_dbid;
        longint          k;
        longint          ks;
        bit              found;
        bit [2:0]        fwd;
        snp_t            s;

        op   = f[DAT_OPCODE_LSB +: 4];
        src  = f[DAT_SRC_LSB +: NODE_ID_W];
        tgt  = f[DAT_TGT_LSB +: NODE_ID_W];
        txn  = f[DAT_TXN_LSB +: TXN_ID_W];
        // DataID is Addr[5:4] of the beat; beat index = DataID >> log2(DW/128).
        beat = f[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W] >> `CHI_DAT_DATAID_SHIFT(DATA_WIDTH);
        resp = f[DAT_RESP_LSB +: 3];
        dbid = f[DAT_DBID_LSB +: DBID_W];
        if (flit_traced(src, tgt, txn))
            $display("[%0t] CHI_TRACE DAT %0d->%0d op=0x%0h txn=0x%0h dbid=0x%0h beat=%0d resp=%0d be=0x%0h data=0x%08h",
                     $time, src, tgt, op, txn, dbid, beat, resp,
                     f[DAT_BE_LSB +: DATA_WIDTH/8], f[DAT_DATA_LSB +: 32]);

        case (op)
            // SnpRespData: snoopee -> home, TxnID of the snoop.
            `CHI_DAT_OPCODE_SNP_DATA: begin
                k = skey(tgt, src, txn);
                if (!snps.exists(k) && snp_tail.exists(k)) begin
                    if (spec_snpresp_fwd && snp_tail[k].fwd_rsp &&
                        (snp_tail[k].dbeats == 0))
                        err("SPEC_SNPRESP_FWD",
                            $sformatf("SnpRespData after SnpRespFwded rn=%0d home=%0d txn=0x%0h",
                                      src, tgt, txn));
                    snp_tail[k].dbeats = snp_tail[k].dbeats + 1;
                    if (snp_tail[k].dbeats == BEATS)
                        snp_tail.delete(k);
                end else if (!snps.exists(k)) begin
                    err("SNPDATA_UNKNOWN",
                        $sformatf("SnpRespData rn=%0d home=%0d txn=0x%0h matches no open snoop",
                                  src, tgt, txn));
                end else begin
                    snps[k].dbeats = snps[k].dbeats + 1;
                    if (spec_snpresp_fwd && (snps[k].dbeats == 1) &&
                        snps[k].cd_seen)
                        err("SPEC_SNPRESP_FWD",
                            $sformatf("SnpRespData (not Fwded) after forwarding CompData rn=%0d home=%0d txn=0x%0h",
                                      src, tgt, txn));
                    if (snps[k].dbeats > BEATS)
                        err("SNPDATA_EXTRA",
                            $sformatf("SnpRespData beat %0d rn=%0d home=%0d txn=0x%0h",
                                      snps[k].dbeats, src, tgt, txn));
                    if (spec_snprespdata_only && (snps[k].dbeats == BEATS))
                        snps.delete(k);
                end
            end

            // SnpRespDataFwded: snoopee -> home, the whole response to a
            // forwarding snoop.
            `CHI_DAT_OPCODE_SNP_DATA_FWD: begin
                k = skey(tgt, src, txn);
                if (!snps.exists(k)) begin
                    err("SNPDATA_UNKNOWN",
                        $sformatf("SnpRespDataFwded rn=%0d home=%0d txn=0x%0h matches no open snoop",
                                  src, tgt, txn));
                end else begin
                    snps[k].dbeats = snps[k].dbeats + 1;
                    if (spec_snpresp_fwd && (snps[k].dbeats == 1)) begin
                        s   = snps[k];
                        fwd = f[DAT_FWD_STATE_LSB +: 3];
                        if (!fwd_pair_ok(s.op, resp, fwd, 1'b1))
                            err("SPEC_SNPRESP_FWD",
                                $sformatf("SnpRespDataFwded Resp=%0d FwdState=%0d to snoop op=0x%02h rn=%0d home=%0d txn=0x%0h",
                                          resp, fwd, s.op, src, tgt, txn));
                        if (s.cd_seen && (s.cd_resp != fwd))
                            err("SPEC_SNPRESP_FWD",
                                $sformatf("SnpRespDataFwded FwdState=%0d but CompData Resp=%0d rn=%0d home=%0d txn=0x%0h",
                                          fwd, s.cd_resp, src, tgt, txn));
                        snps[k].fwd_state_valid = 1'b1;
                        snps[k].fwd_state = fwd;
                    end
                    if (snps[k].dbeats > BEATS)
                        err("SNPDATA_EXTRA",
                            $sformatf("SnpRespDataFwded beat %0d rn=%0d home=%0d txn=0x%0h",
                                      snps[k].dbeats, src, tgt, txn));
                    if (snps[k].dbeats == BEATS) begin
                        n_fwd_dat = n_fwd_dat + 1;
                        snps.delete(k);
                    end
                end
            end

            // CompData: completer (or a forwarding snoopee) -> requester.
            `CHI_DAT_OPCODE_RD_DATA: begin
                k = tkey(tgt, txn);
                if (!txns.exists(k)) begin
                    err("COMPDATA_UNKNOWN_TXN",
                        $sformatf("CompData src=%0d to=%0d txn=0x%0h beat=%0d matches no outstanding request",
                                  src, tgt, txn, beat));
                    return;
                end
                if (!txns[k].is_read)
                    err("COMPDATA_FOR_NON_READ",
                        $sformatf("CompData from %0d for %s", src, tstr(txns[k])));
                if ((src != txns[k].tgt) && !node_is_rn(src))
                    err("COMPDATA_WRONG_SRC",
                        $sformatf("CompData from %0d for %s", src, tstr(txns[k])));
                if (txns[k].rmask[beat])
                    err("COMPDATA_DUP_BEAT",
                        $sformatf("DataID %0d twice for %s", beat, tstr(txns[k])));
                if (spec_compdata_resp && !compdata_resp_ok(txns[k].op, resp))
                    err("SPEC_COMPDATA_RESP",
                        $sformatf("Resp=%0d for %s", resp, tstr(txns[k])));
                // DCT: the snoopee's CompData names the snoop by HomeNID
                // (its home) and DBID (its TxnID).
                if (spec_snpresp_fwd && node_is_rn(src) && (txns[k].rbeats == 0)) begin
                    ks = skey(f[DAT_HOME_NID_LSB +: NODE_ID_W], src, dbid);
                    found = 1'b1;
                    if (snps.exists(ks))
                        s = snps[ks];
                    else if (snp_tail.exists(ks))
                        s = snp_tail[ks];
                    else
                        found = 1'b0;
                    if (!found) begin
                        err("SPEC_SNPRESP_FWD",
                            $sformatf("CompData from rn=%0d matches no forwarding snoop: %s",
                                      src, tstr(txns[k])));
                    end else begin
                        if (!(((s.op == `CHI_SNP_SHARED_FWD) &&
                               ((resp == `CHI_COMPDATA_RESP_SC) ||
                                (resp == `CHI_COMPDATA_RESP_SD_PD))) ||
                              ((s.op == `CHI_SNP_UNIQUE_FWD) &&
                               ((resp == `CHI_COMPDATA_RESP_UC) ||
                                (resp == `CHI_COMPDATA_RESP_UD_PD)))))
                            err("SPEC_SNPRESP_FWD",
                                $sformatf("forwarded CompData Resp=%0d for snoop op=0x%02h: %s",
                                          resp, s.op, tstr(txns[k])));
                        if (s.fwd_state_valid && (s.fwd_state != resp))
                            err("SPEC_SNPRESP_FWD",
                                $sformatf("forwarded CompData Resp=%0d but FwdState=%0d: %s",
                                          resp, s.fwd_state, tstr(txns[k])));
                        if (snps.exists(ks)) begin
                            snps[ks].cd_seen = 1'b1;
                            snps[ks].cd_resp = resp;
                        end else begin
                            snp_tail[ks].cd_seen = 1'b1;
                            snp_tail[ks].cd_resp = resp;
                        end
                    end
                end
                txns[k].rmask[beat] = 1'b1;
                txns[k].rbeats  = txns[k].rbeats + 1;
                txns[k].cd_dbid = dbid;
                if (txns[k].rbeats == BEATS)
                    close_txn(k);
            end

            // WriteData: requester -> completer.
            `CHI_DAT_OPCODE_WDAT,
            `CHI_DAT_OPCODE_WB_DATA: begin
                found = 1'b0;
                k = tkey(src, txn);
                txn_dbid = txn;
                // An SN pairs WriteData with its write by the DBID it gave
                // (1.5), so WriteData to an SN is always matched that way.
                if (spec_wdat_txnid_dbid || node_is_sn(tgt)) begin
                    foreach (txns[kk]) begin
                        if (!found && (txns[kk].src == src) && (txns[kk].tgt == tgt) &&
                            txns[kk].got_dbid && (txns[kk].dbid == txn_dbid) &&
                            (txns[kk].wbeats < txns[kk].need_beats)) begin
                            k = kk;
                            found = 1'b1;
                        end
                    end
                    if (!found && spec_wdat_txnid_dbid)
                        err("SPEC_WDAT_TXNID_DBID",
                            $sformatf("WriteData src=%0d to=%0d txn=0x%0h is not a DBID it was given",
                                      src, tgt, txn));
                end
                // Current contract (and fallback after a spec violation):
                // WriteData carries the requester's TxnID.
                if (!found) begin
                    k = tkey(src, txn);
                    found = txns.exists(k);
                end

                if (!found) begin
                    if (node_is_sn(tgt)) begin
                        if (early_wdat.exists(k))
                            early_wdat[k] = early_wdat[k] + 1;
                        else
                            early_wdat[k] = 1;
                    end else begin
                        err("WDAT_UNKNOWN_TXN",
                            $sformatf("WriteData src=%0d to=%0d txn=0x%0h matches no outstanding write",
                                      src, tgt, txn));
                    end
                    return;
                end
                if (!txns[k].is_write)
                    err("WDAT_FOR_NON_WRITE",
                        $sformatf("WriteData for %s", tstr(txns[k])));
                if (txns[k].tgt != tgt)
                    err("WDAT_WRONG_TGT",
                        $sformatf("WriteData to %0d for %s", tgt, tstr(txns[k])));
                if (!txns[k].got_dbid && !node_is_sn(tgt))
                    err("WDAT_BEFORE_DBID",
                        $sformatf("WriteData before DBIDResp: %s", tstr(txns[k])));
                else if (!txns[k].got_dbid && spec_sn_dbid_first)
                    err("SPEC_SN_DBID_FIRST",
                        $sformatf("WriteData before DBIDResp: %s", tstr(txns[k])));
                if (txns[k].got_dbid && (dbid != txns[k].dbid))
                    err("WDAT_DBID_MISMATCH",
                        $sformatf("WriteData DBID 0x%0h, DBIDResp gave 0x%0h: %s",
                                  dbid, txns[k].dbid, tstr(txns[k])));
                // The DVM payload: NonCopyBackWriteData, BE[7:0] only,
                // DataID 0 (Table B8.4).
                if (spec_dvm && txns[k].is_dvm &&
                    ((op != `CHI_DAT_OPCODE_WB_DATA) || (beat != 0) ||
                     (f[DAT_BE_LSB +: DATA_WIDTH/8] !=
                      {{(DATA_WIDTH/8-8){1'b0}}, 8'hFF})))
                    err("SPEC_DVM",
                        $sformatf("DVMOp payload op=0x%0h DataID=%0d BE=0x%0h: %s",
                                  op, beat, f[DAT_BE_LSB +: DATA_WIDTH/8], tstr(txns[k])));
                txns[k].wbeats = txns[k].wbeats + 1;
                if (txns[k].wbeats > txns[k].need_beats)
                    err("WDAT_EXTRA",
                        $sformatf("WriteData beat %0d: %s", txns[k].wbeats, tstr(txns[k])));
                else if (txns[k].wbeats == txns[k].need_beats)
                    try_close_write(k);
            end

            default:
                err("DAT_BAD_OPCODE",
                    $sformatf("DAT opcode 0x%0h src=%0d to=%0d txn=0x%0h", op, src, tgt, txn));
        endcase
    endtask

    // ------------------------------------------------------------------
    // Liveness: nothing may stay open for LIVENESS_CYCLES.
    // ------------------------------------------------------------------
    task automatic check_liveness;
        int i;
        foreach (txns[k]) begin
            if (!txns[k].live_reported && (cycle - txns[k].t0 > LIVENESS_CYCLES)) begin
                err("LIVENESS_TXN",
                    $sformatf("open %0d cycles (dbid=%0b wbeats=%0d rbeats=%0d comp=%0b retried=%0b): %s",
                              cycle - txns[k].t0, txns[k].got_dbid, txns[k].wbeats,
                              txns[k].rbeats, txns[k].got_comp, txns[k].retried,
                              tstr(txns[k])));
                txns[k].live_reported = 1'b1;
            end
        end
        foreach (snps[k]) begin
            if (!snps[k].live_reported && (cycle - snps[k].t0 > LIVENESS_CYCLES)) begin
                err("LIVENESS_SNP",
                    $sformatf("snoop open %0d cycles home=%0d rn=%0d txn=0x%0h op=0x%02h addr=0x%0h",
                              cycle - snps[k].t0, snps[k].home, snps[k].rn,
                              snps[k].txn, snps[k].op, snps[k].addr));
                snps[k].live_reported = 1'b1;
            end
        end
        foreach (snp_tail[k]) begin
            if (!snp_tail[k].live_reported && (snp_tail[k].dbeats != 0) &&
                (cycle - snp_tail[k].t0 > LIVENESS_CYCLES)) begin
                err("SNPDATA_INCOMPLETE",
                    $sformatf("SnpRespData stuck at %0d/%0d beats home=%0d rn=%0d txn=0x%0h",
                              snp_tail[k].dbeats, BEATS, snp_tail[k].home,
                              snp_tail[k].rn, snp_tail[k].txn));
                snp_tail[k].live_reported = 1'b1;
            end
        end
        for (i = 0; i < acks.size(); i = i + 1) begin
            if (!acks[i].live_reported && (cycle - acks[i].t0 > LIVENESS_CYCLES)) begin
                err("COMPACK_MISSING",
                    $sformatf("no CompAck after %0d cycles src=%0d home=%0d txn=0x%0h",
                              cycle - acks[i].t0, acks[i].src, acks[i].home, acks[i].txn));
                acks[i].live_reported = 1'b1;
            end
        end
    endtask

    // Print every open transaction and snoop, for testbench failure reports.
    task automatic dump_open;
        foreach (txns[k])
            $display("[%0t] CHI_CHK OPEN txn age=%0d dbid=%0b wbeats=%0d rbeats=%0d comp=%0b retried=%0b %s",
                     $time, cycle - txns[k].t0, txns[k].got_dbid, txns[k].wbeats,
                     txns[k].rbeats, txns[k].got_comp, txns[k].retried, tstr(txns[k]));
        foreach (snps[k])
            $display("[%0t] CHI_CHK OPEN snoop age=%0d home=%0d rn=%0d txn=0x%0h op=0x%02h addr=0x%0h dbeats=%0d",
                     $time, cycle - snps[k].t0, snps[k].home, snps[k].rn, snps[k].txn,
                     snps[k].op, snps[k].addr, snps[k].dbeats);
    endtask

    // ------------------------------------------------------------------
    // Sampling
    // ------------------------------------------------------------------
    integer ch_i;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            reset_state();
        end else if (enabled) begin
            cycle = cycle + 1;
            for (ch_i = 0; ch_i < NUM_REQ_TGT; ch_i = ch_i + 1)
                if (req_valid[ch_i] && req_ready[ch_i])
                    on_req(req_flit[ch_i*REQ_W +: REQ_W]);
            for (ch_i = 0; ch_i < NUM_RN; ch_i = ch_i + 1)
                if (snp_valid[ch_i] && snp_ready[ch_i])
                    on_snp(ch_i, snp_flit[ch_i*SNP_W +: SNP_W]);
            for (ch_i = 0; ch_i < NUM_NODES; ch_i = ch_i + 1)
                if (rsp_valid[ch_i] && rsp_ready[ch_i])
                    on_rsp(rsp_flit[ch_i*RSP_W +: RSP_W]);
            for (ch_i = 0; ch_i < NUM_NODES; ch_i = ch_i + 1)
                if (dat_valid[ch_i] && dat_ready[ch_i])
                    on_dat(dat_flit[ch_i*DAT_W +: DAT_W]);
            if ((cycle % 256) == 0)
                check_liveness();
            n_open = txns.num() + snps.num() + acks.size();
        end
    end

    final begin
        if (enabled) begin
            check_liveness();
            $display("CHI_CHK SUMMARY %m violations=%0d requests=%0d completed=%0d snoops=%0d open_txn=%0d open_snp=%0d open_ack=%0d",
                     errors, n_req, n_done, n_snp, txns.num(), snps.num(), acks.size());
            $display("CHI_CHK SUMMARY %m forwards SnpRespFwded=%0d SnpRespDataFwded=%0d",
                     n_fwd_rsp, n_fwd_dat);
            foreach (rule_cnt[r])
                $display("CHI_CHK SUMMARY %m rule %s count=%0d", r, rule_cnt[r]);
        end
    end
endmodule
