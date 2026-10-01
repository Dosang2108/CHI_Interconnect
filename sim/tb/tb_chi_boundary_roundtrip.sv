`timescale 1ns / 1ps
`include "chi_defs.vh"

// Boundary adapters for REQ, RSP and SNP, and DAT with no added properties.
//  - Field positions at NodeID_Width = 7 are compared with bit numbers
//    counted by hand from IHI0050H Tables B13.6-B13.8, not with the macros.
//  - A legal flit survives compact -> boundary -> compact unchanged and the
//    added properties (REQ MPAM + RSVDC, SNP MPAM) are driven as zero.
//  - boundary -> compact flags and clears each unsupported field.
module tb_chi_boundary_roundtrip;
    localparam integer NODE_ID_W = 7;
    localparam integer DAT_DW    = 128;
    localparam integer REQ_MPAM_W  = 12;
    localparam integer REQ_RSVDC_W = 8;
    localparam integer SNP_MPAM_W  = 15;

    localparam integer REQ_W  = `CHI_REQ_W(NODE_ID_W);
    localparam integer RSP_W  = `CHI_RSP_W(NODE_ID_W);
    localparam integer SNP_W  = `CHI_SNP_W(NODE_ID_W);
    localparam integer DAT_W  = `CHI_DAT_W(DAT_DW,NODE_ID_W);
    localparam integer REQ_BW = REQ_W + REQ_MPAM_W + REQ_RSVDC_W;
    localparam integer SNP_BW = SNP_W + SNP_MPAM_W;

    // REQ field positions, Table B13.6 at NodeID_Width 7 and Req_Addr_Width 44.
    localparam integer RQ_QOS = 0,   RQ_TGT = 4,   RQ_SRC = 11,  RQ_TXN = 18;
    localparam integer RQ_RETNID = 30, RQ_STASHNV = 37, RQ_RETTXN = 38;
    localparam integer RQ_OP = 50,   RQ_MULTI = 57, RQ_NUMREQ = 58, RQ_ADDR = 64;
    localparam integer RQ_PAS = 108, RQ_LIKELY = 111, RQ_ALLOWRETRY = 112;
    localparam integer RQ_ORDER = 113, RQ_PCRD = 115, RQ_MEMATTR = 119;
    localparam integer RQ_SNPATTR = 123, RQ_LPID = 124, RQ_EXCL = 132;
    localparam integer RQ_EXPCA = 133, RQ_TAGOP = 134, RQ_TRACE = 136;
    localparam integer RQ_TOTAL = 137;
    // RSP, Table B13.7.
    localparam integer RS_QOS = 0, RS_TGT = 4, RS_SRC = 11, RS_TXN = 18;
    localparam integer RS_OP = 30, RS_RESPERR = 35, RS_RESP = 37, RS_FWDSTATE = 40;
    localparam integer RS_CBUSY = 43, RS_DBID = 46, RS_PCRD = 58, RS_TAGOP = 62;
    localparam integer RS_TRACE = 64, RS_CLID = 65, RS_TOTAL = 71;
    // SNP, Table B13.8 (Addr is Addr[43:3], 41 bits).
    localparam integer SN_QOS = 0, SN_SRC = 4, SN_TXN = 11, SN_FWDNID = 23;
    localparam integer SN_FWDTXN = 30, SN_OP = 42, SN_ADDR = 47, SN_PAS = 88;
    localparam integer SN_DNGTSD = 91, SN_RETTOSRC = 92, SN_TRACE = 93;
    localparam integer SN_TOTAL = 94;

    reg  [REQ_W-1:0]  req_c;
    wire [REQ_BW-1:0] req_b_from_c;
    reg  [REQ_BW-1:0] req_b;
    wire [REQ_W-1:0]  req_c_from_b;
    wire              req_bad;

    reg  [RSP_W-1:0]  rsp_c;
    wire [RSP_W-1:0]  rsp_b_from_c;
    reg  [RSP_W-1:0]  rsp_b;
    wire [RSP_W-1:0]  rsp_c_from_b;
    wire              rsp_bad;

    reg  [SNP_W-1:0]  snp_c;
    wire [SNP_BW-1:0] snp_b_from_c;
    reg  [SNP_BW-1:0] snp_b;
    wire [SNP_W-1:0]  snp_c_from_b;
    wire              snp_bad;

    reg  [DAT_W-1:0]  dat_c;
    wire [DAT_W-1:0]  dat_b_from_c;
    wire [DAT_W-1:0]  dat_c_from_b;
    wire              dat_bad;

    integer fail_count;

    chi_req_compact_to_boundary #(.NODE_ID_W(NODE_ID_W), .MPAM_W(REQ_MPAM_W),
                                  .RSVDC_W(REQ_RSVDC_W))
        u_req_c2b (.compact_flit(req_c), .boundary_flit(req_b_from_c));
    chi_req_boundary_to_compact #(.NODE_ID_W(NODE_ID_W), .MPAM_W(REQ_MPAM_W),
                                  .RSVDC_W(REQ_RSVDC_W))
        u_req_b2c (.boundary_flit(req_b), .compact_flit(req_c_from_b),
                   .unsupported_attr(req_bad));
    chi_rsp_compact_to_boundary #(.NODE_ID_W(NODE_ID_W))
        u_rsp_c2b (.compact_flit(rsp_c), .boundary_flit(rsp_b_from_c));
    chi_rsp_boundary_to_compact #(.NODE_ID_W(NODE_ID_W))
        u_rsp_b2c (.boundary_flit(rsp_b), .compact_flit(rsp_c_from_b),
                   .unsupported_attr(rsp_bad));
    chi_snp_compact_to_boundary #(.NODE_ID_W(NODE_ID_W), .MPAM_W(SNP_MPAM_W))
        u_snp_c2b (.compact_flit(snp_c), .boundary_flit(snp_b_from_c));
    chi_snp_boundary_to_compact #(.NODE_ID_W(NODE_ID_W), .MPAM_W(SNP_MPAM_W))
        u_snp_b2c (.boundary_flit(snp_b), .compact_flit(snp_c_from_b),
                   .unsupported_attr(snp_bad));
    chi_dat_compact_to_boundary #(.DATA_WIDTH(DAT_DW), .NODE_ID_W(NODE_ID_W))
        u_dat_c2b (.compact_flit(dat_c), .boundary_flit(dat_b_from_c));
    chi_dat_boundary_to_compact #(.DATA_WIDTH(DAT_DW), .NODE_ID_W(NODE_ID_W))
        u_dat_b2c (.boundary_flit(dat_b_from_c), .compact_flit(dat_c_from_b),
                   .unsupported_attr(dat_bad));

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fail_count = fail_count + 1;
            $display("[%0t] TEST FAIL tb_chi_boundary_roundtrip %0s", $time, msg);
        end
    endtask

    // REQ: ReadShared with every supported field set.
    task automatic fill_req_readshared;
        begin
            req_c = '0;
            req_c[RQ_QOS +: 4]        = 4'h9;
            req_c[RQ_TGT +: 7]        = 7'h02;
            req_c[RQ_SRC +: 7]        = 7'h01;
            req_c[RQ_TXN +: 12]       = 12'h5A3;
            req_c[RQ_RETNID +: 7]     = 7'h04;
            req_c[RQ_RETTXN +: 12]    = 12'h0C1;
            req_c[RQ_OP +: 7]         = `CHI_REQ_RD_SHARED;
            req_c[RQ_NUMREQ +: 3]     = 3'd6;
            req_c[RQ_ADDR +: 32]      = 32'h8765_4340;
            req_c[RQ_LIKELY]          = 1'b1;
            req_c[RQ_ALLOWRETRY]      = 1'b1;
            req_c[RQ_ORDER +: 2]      = 2'b10;
            req_c[RQ_MEMATTR +: 4]    = `CHI_REQ_MEMATTR_NORMAL_CACHE;
            req_c[RQ_SNPATTR]         = `CHI_REQ_SNPATTR_COHERENT;
            req_c[RQ_EXCL]            = 1'b1;
            req_c[RQ_EXPCA]           = 1'b1;
        end
    endtask

    task automatic req_bad_case(input integer lsb, input integer w, input string what);
        begin
            fill_req_readshared();
            #1;
            req_b = req_b_from_c;
            req_b[lsb +: 1] = 1'b1;
            if (w > 1) req_b[lsb + w - 1] = 1'b1;
            #1;
            check(req_bad, {"REQ did not flag ", what});
            check(req_c_from_b === req_c, {"REQ did not clear ", what});
        end
    endtask

    task automatic fill_rsp_comp;
        begin
            rsp_c = '0;
            rsp_c[RS_QOS +: 4]     = 4'h3;
            rsp_c[RS_TGT +: 7]     = 7'h01;
            rsp_c[RS_SRC +: 7]     = 7'h02;
            rsp_c[RS_TXN +: 12]    = 12'hABC;
            rsp_c[RS_OP +: 5]      = `CHI_RSP_COMP;
            rsp_c[RS_RESPERR +: 2] = `CHI_RESPERR_EXOKAY;
            rsp_c[RS_RESP +: 3]    = `CHI_COMPDATA_RESP_UC;
            rsp_c[RS_CBUSY +: 3]   = 3'b101;
            rsp_c[RS_DBID +: 12]   = 12'h321;
        end
    endtask

    task automatic rsp_bad_case(input integer lsb, input string what);
        begin
            fill_rsp_comp();
            #1;
            rsp_b = rsp_b_from_c;
            rsp_b[lsb] = 1'b1;
            #1;
            check(rsp_bad, {"RSP did not flag ", what});
            check(rsp_c_from_b === rsp_c, {"RSP did not clear ", what});
        end
    endtask

    task automatic fill_snp(input [4:0] op, input bit fwd);
        begin
            snp_c = '0;
            snp_c[SN_QOS +: 4]  = 4'h6;
            snp_c[SN_SRC +: 7]  = 7'h02;
            snp_c[SN_TXN +: 12] = 12'h081;
            snp_c[SN_OP +: 5]   = op;
            snp_c[SN_ADDR +: 29] = 32'h8765_4340 >> 3;
            snp_c[SN_DNGTSD]    = 1'b1;
            if (fwd) begin
                snp_c[SN_FWDNID +: 7]  = 7'h01;
                snp_c[SN_FWDTXN +: 12] = 12'h5A3;
            end
        end
    endtask

    task automatic snp_bad_case(input integer lsb, input string what);
        begin
            fill_snp(`CHI_SNP_SHARED_FWD, 1'b1);
            #1;
            snp_b = snp_b_from_c;
            snp_b[lsb] = 1'b1;
            #1;
            check(snp_bad, {"SNP did not flag ", what});
            check(snp_c_from_b === snp_c, {"SNP did not clear ", what});
        end
    endtask

    initial begin
        fail_count = 0;
        $display("[%0t] TEST START tb_chi_boundary_roundtrip", $time);

        // Layout against the tables.
        check(REQ_W == RQ_TOTAL, "REQ width is not the Table B13.6 total");
        check(RSP_W == RS_TOTAL, "RSP width is not the Table B13.7 total");
        check(SNP_W == SN_TOTAL, "SNP width is not the Table B13.8 total");
        check(`CHI_REQ_OPCODE_LSB(NODE_ID_W) == RQ_OP, "REQ Opcode position");
        check(`CHI_REQ_SIZE_LSB(NODE_ID_W) == RQ_NUMREQ, "REQ Size is not NumReq[2:0]");
        check(`CHI_REQ_ADDR_LSB(NODE_ID_W) == RQ_ADDR, "REQ Addr position");
        check(`CHI_REQ_PAS_LSB(NODE_ID_W) == RQ_PAS, "REQ PAS position");
        check(`CHI_REQ_PCRD_TYPE_LSB(NODE_ID_W) == RQ_PCRD, "REQ PCrdType position");
        check(`CHI_REQ_LPID_LSB(NODE_ID_W) == RQ_LPID, "REQ LPID position");
        check(`CHI_REQ_EXCL_LSB(NODE_ID_W) == RQ_EXCL, "REQ Excl position");
        check(`CHI_REQ_EXP_COMP_ACK_LSB(NODE_ID_W) == RQ_EXPCA, "REQ ExpCompAck position");
        check(`CHI_REQ_TRACE_TAG_LSB(NODE_ID_W) == RQ_TRACE, "REQ TraceTag position");
        check(`CHI_RSP_OPCODE_LSB(NODE_ID_W) == RS_OP, "RSP Opcode position");
        check(`CHI_RSP_FWD_STATE_LSB(NODE_ID_W) == RS_FWDSTATE, "RSP FwdState position");
        check(`CHI_RSP_DBID_LSB(NODE_ID_W) == RS_DBID, "RSP DBID position");
        check(`CHI_RSP_PCRD_TYPE_LSB(NODE_ID_W) == RS_PCRD, "RSP PCrdType position");
        check(`CHI_RSP_CACHE_LINE_ID_LSB(NODE_ID_W) == RS_CLID, "RSP CacheLineID position");
        check(`CHI_SNP_FWD_NID_LSB(NODE_ID_W) == SN_FWDNID, "SNP FwdNID position");
        check(`CHI_SNP_OPCODE_LSB(NODE_ID_W) == SN_OP, "SNP Opcode position");
        check(`CHI_SNP_ADDR_LSB(NODE_ID_W) == SN_ADDR, "SNP Addr position");
        check(`CHI_SNP_TRACE_TAG_LSB(NODE_ID_W) == SN_TRACE, "SNP TraceTag position");
        // NodeID_Width 16: the upper end of each table total.
        check(`CHI_REQ_W(16) == 120 + 44, "REQ width at NodeID_Width 16");
        check(`CHI_RSP_W(16) == 89, "RSP width at NodeID_Width 16");
        check(`CHI_SNP_W(16) == 71 + 41, "SNP width at NodeID_Width 16");

        // REQ legal round trip; MPAM and RSVDC driven as zero.
        fill_req_readshared();
        #1;
        check(req_b_from_c[REQ_W-1:0] === req_c, "REQ base bits changed on the way out");
        check(req_b_from_c[REQ_BW-1:REQ_W] == '0, "REQ MPAM/RSVDC not zero");
        req_b = req_b_from_c;
        #1;
        check(!req_bad, "REQ legal ReadShared flagged");
        check(req_c_from_b === req_c, "REQ legal round trip changed the flit");

        // PCrdReturn may carry PCrdType.
        req_c = '0;
        req_c[RQ_OP +: 7]   = `CHI_REQ_PCRD_RETURN;
        req_c[RQ_PCRD +: 4] = 4'hA;
        #1;
        req_b = req_b_from_c;
        #1;
        check(!req_bad, "REQ PCrdReturn PCrdType flagged");
        check(req_c_from_b === req_c, "REQ PCrdReturn round trip changed the flit");

        req_bad_case(RQ_PCRD, 4, "PCrdType outside PCrdReturn");
        req_bad_case(RQ_STASHNV, 1, "StashNIDValid");
        req_bad_case(RQ_MULTI, 1, "MultiReq");
        req_bad_case(RQ_NUMREQ + 3, 3, "NumReq above Size");
        req_bad_case(RQ_PAS, 3, "non-default PAS");
        req_bad_case(RQ_LPID, 8, "LPID");
        req_bad_case(RQ_TAGOP, 2, "TagOp");
        req_bad_case(RQ_TRACE, 1, "TraceTag");
        req_bad_case(REQ_W, REQ_MPAM_W, "MPAM");
        req_bad_case(REQ_W + REQ_MPAM_W, REQ_RSVDC_W, "RSVDC");

        // RSP legal round trips.
        fill_rsp_comp();
        #1;
        check(rsp_b_from_c === rsp_c, "RSP changed on the way out");
        rsp_b = rsp_b_from_c;
        #1;
        check(!rsp_bad, "RSP legal Comp flagged");
        check(rsp_c_from_b === rsp_c, "RSP legal round trip changed the flit");
        fill_rsp_comp();
        rsp_c[RS_OP +: 5]      = `CHI_RSP_SNP_RESP_FWD;
        rsp_c[RS_FWDSTATE +: 3] = `CHI_COMPDATA_RESP_SC;
        #1;
        rsp_b = rsp_b_from_c;
        #1;
        check(!rsp_bad && (rsp_c_from_b === rsp_c), "RSP SnpRespFwded FwdState lost");
        fill_rsp_comp();
        rsp_c[RS_OP +: 5]   = `CHI_RSP_PCRD_GRANT;
        rsp_c[RS_PCRD +: 4] = 4'hD;
        #1;
        rsp_b = rsp_b_from_c;
        #1;
        check(!rsp_bad && (rsp_c_from_b === rsp_c), "RSP PCrdGrant PCrdType lost");

        rsp_bad_case(RS_PCRD, "PCrdType outside RetryAck/PCrdGrant");
        rsp_bad_case(RS_TAGOP, "TagOp");
        rsp_bad_case(RS_TRACE, "TraceTag");
        rsp_bad_case(RS_CLID + 5, "CacheLineID");
        fill_rsp_comp();
        rsp_c[RS_OP +: 5] = `CHI_RSP_READ_RECEIPT;
        #1;
        rsp_b = rsp_b_from_c;
        #1;
        check(rsp_bad, "RSP did not flag ReadReceipt");

        // SNP: forwarding snoop and DVM keep the Fwd fields; Addr is [43:3].
        fill_snp(`CHI_SNP_SHARED_FWD, 1'b1);
        #1;
        check(snp_b_from_c[SNP_W-1:0] === snp_c, "SNP base bits changed on the way out");
        check(snp_b_from_c[SNP_BW-1:SNP_W] == '0, "SNP MPAM not zero");
        snp_b = snp_b_from_c;
        #1;
        check(!snp_bad, "SNP legal SnpSharedFwd flagged");
        check(snp_c_from_b === snp_c, "SNP legal round trip changed the flit");
        check({snp_c_from_b[SN_ADDR +: 29], 3'b000} == 32'h8765_4340,
              "SNP Addr[43:3] does not give back the line address");
        fill_snp(`CHI_SNP_DVM_OP, 1'b1);
        snp_c[SN_DNGTSD] = 1'b0;
        #1;
        snp_b = snp_b_from_c;
        #1;
        check(!snp_bad && (snp_c_from_b === snp_c), "SNP DVM payload in Fwd fields flagged");

        // A non-forwarding snoop must not carry Fwd fields.
        fill_snp(`CHI_SNP_SHARED, 1'b1);
        #1;
        snp_b = snp_b_from_c;
        #1;
        check(snp_bad, "SNP did not flag Fwd fields on SnpShared");
        check(snp_c_from_b[SN_FWDNID +: 19] == '0, "SNP did not clear stale Fwd fields");
        snp_bad_case(SN_PAS, "PAS");
        snp_bad_case(SN_TRACE, "TraceTag");
        snp_bad_case(SNP_W + SNP_MPAM_W - 1, "MPAM");

        // DAT with no added properties is the fabric flit unchanged.
        dat_c = '0;
        dat_c[`CHI_DAT_HOME_NID_LSB(DAT_DW,NODE_ID_W) +: 7] = 7'h33;
        dat_c[`CHI_DAT_DATA_LSB(DAT_DW,NODE_ID_W) +: DAT_DW] = {4{32'hC2C2_0039}};
        dat_c[`CHI_DAT_BE_LSB(DAT_DW,NODE_ID_W) +: DAT_DW/8] = '1;
        dat_c[`CHI_DAT_DATAID_LSB(DAT_DW,NODE_ID_W) +: 2] = 2'b11;
        #1;
        check(dat_b_from_c === dat_c, "DAT without added properties changed on the way out");
        check(!dat_bad && (dat_c_from_b === dat_c), "DAT legal round trip failed");

        if (fail_count != 0) begin
            $display("[%0t] TEST FAIL tb_chi_boundary_roundtrip fail_count=%0d",
                     $time, fail_count);
            $finish;
        end
        $display("[%0t] TEST PASS tb_chi_boundary_roundtrip REQ/RSP/SNP match Tables B13.6-B13.8 and the boundary contract held", $time);
        $finish;
    end
endmodule
