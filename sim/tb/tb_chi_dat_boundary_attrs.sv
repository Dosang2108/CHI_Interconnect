`timescale 1ns / 1ps
`include "chi_defs.vh"

// DAT boundary adapters against IHI0050H Table B13.9, with RSVDC and Poison
// added at the external port. One case per data width; each case checks
// the field positions against bit numbers counted by hand from the table,
// the placement of RSVDC (below BE) and Poison (above Data), the round
// trip, and that every unsupported field is flagged and cleared.
module tb_chi_dat_boundary_attrs_case #(
    parameter integer DW       = 128,
    parameter integer RSVDC_W  = 4,
    // Hand-counted positions at NodeID_Width 7 for this DW.
    parameter integer P_TU     = 90,
    parameter integer P_TRACE  = 91,
    parameter integer P_CAH    = 92,
    parameter integer P_NUMDAT = 93,
    parameter integer P_REPL   = 95,
    parameter integer P_BE     = 96,
    parameter integer P_DATA   = 112,
    parameter integer P_TOTAL  = 240
)(
    output reg     done,
    output integer fails
);
    localparam integer NODE_ID_W = 7;
    localparam integer POISON_W  = DW / 64;
    localparam integer C_W = `CHI_DAT_W(DW,NODE_ID_W);
    localparam integer B_W = C_W + RSVDC_W + POISON_W;
    // Positions below Tag do not depend on DW.
    localparam integer P_QOS = 0, P_TGT = 4, P_SRC = 11, P_TXN = 18;
    localparam integer P_HOME = 30, P_OP = 37, P_RESPERR = 41, P_RESP = 43;
    localparam integer P_DSRC = 46, P_DPULL = 54, P_CBUSY = 55, P_DBID = 58;
    localparam integer P_CCID = 74, P_DATAID = 76, P_CLID = 78, P_TAGOP = 84;
    localparam integer P_TAG = 86;

    reg  [C_W-1:0] c;
    wire [B_W-1:0] b_from_c;
    reg  [B_W-1:0] b;
    wire [C_W-1:0] c_from_b;
    wire           bad;

    chi_dat_compact_to_boundary #(.DATA_WIDTH(DW), .NODE_ID_W(NODE_ID_W),
                                  .RSVDC_W(RSVDC_W), .POISON(1))
        u_c2b (.compact_flit(c), .boundary_flit(b_from_c));
    chi_dat_boundary_to_compact #(.DATA_WIDTH(DW), .NODE_ID_W(NODE_ID_W),
                                  .RSVDC_W(RSVDC_W), .POISON(1))
        u_b2c (.boundary_flit(b), .compact_flit(c_from_b), .unsupported_attr(bad));

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            fails = fails + 1;
            $display("[%0t] TEST FAIL tb_chi_dat_boundary_attrs DW=%0d %0s", $time, DW, msg);
        end
    endtask

    // CompData with every supported field non-zero.
    task automatic fill;
        begin
            c = '0;
            c[P_QOS +: 4]     = 4'hA;
            c[P_TGT +: 7]     = 7'h22;
            c[P_SRC +: 7]     = 7'h11;
            c[P_TXN +: 12]    = 12'h456;
            c[P_HOME +: 7]    = 7'h33;
            c[P_OP +: 4]      = `CHI_DAT_OPCODE_RD_DATA;
            c[P_RESPERR +: 2] = `CHI_RESPERR_EXOKAY;
            c[P_RESP +: 3]    = `CHI_COMPDATA_RESP_UD_PD;
            c[P_DSRC +: 8]    = 8'h05;
            c[P_CBUSY +: 3]   = 3'b011;
            c[P_DBID +: 12]   = 12'h123;
            c[P_CCID +: 2]    = 2'b01;
            c[P_DATAID +: 2]  = 2'b10;
            c[P_CAH]          = 1'b1;
            c[P_BE +: DW/8]   = {(DW/16){2'b10}};
            c[P_DATA +: DW]   = {(DW/32){32'hC2C2_0039}};
        end
    endtask

    // Posts a boundary flit with one extra bit set and expects it flagged
    // and cleared.
    task automatic bad_case(input integer lsb, input string what);
        begin
            fill();
            #1;
            b = b_from_c;
            b[lsb] = 1'b1;
            #1;
            check(bad, {"did not flag ", what});
            check(c_from_b === c, {"did not clear ", what});
        end
    endtask

    initial begin
        done  = 1'b0;
        fails = 0;

        check(C_W == P_TOTAL, "width is not the Table B13.9 total");
        check(`CHI_DAT_W_SPEC(DW,NODE_ID_W) == P_TOTAL, "spec total macro");
        check(`CHI_DAT_HOME_NID_LSB(DW,NODE_ID_W) == P_HOME, "HomeNID position");
        check(`CHI_DAT_OPCODE_LSB(DW,NODE_ID_W) == P_OP, "Opcode position");
        check(`CHI_DAT_RESP_LSB(DW,NODE_ID_W) == P_RESP, "Resp position");
        check(`CHI_DAT_DATA_SOURCE_LSB(DW,NODE_ID_W) == P_DSRC, "DataSource position");
        check(`CHI_DAT_DATA_PULL_LSB(DW,NODE_ID_W) == P_DPULL, "DataPull position");
        check(`CHI_DAT_DBID_LSB(DW,NODE_ID_W) == P_DBID, "DBID position");
        check(`CHI_DAT_CCID_LSB(DW,NODE_ID_W) == P_CCID, "CCID position");
        check(`CHI_DAT_DATAID_LSB(DW,NODE_ID_W) == P_DATAID, "DataID position");
        check(`CHI_DAT_CACHE_LINE_ID_LSB(DW,NODE_ID_W) == P_CLID, "CacheLineID position");
        check(`CHI_DAT_TAG_LSB(DW,NODE_ID_W) == P_TAG, "Tag position");
        check(`CHI_DAT_TU_LSB(DW,NODE_ID_W) == P_TU, "TU position");
        check(`CHI_DAT_TRACE_TAG_LSB(DW,NODE_ID_W) == P_TRACE, "TraceTag position");
        check(`CHI_DAT_NUM_DAT_LSB(DW,NODE_ID_W) == P_NUMDAT, "NumDat position");
        check(`CHI_DAT_REPLICATE_LSB(DW,NODE_ID_W) == P_REPL, "Replicate position");
        check(`CHI_DAT_BE_LSB(DW,NODE_ID_W) == P_BE, "BE position");
        check(`CHI_DAT_DATA_LSB(DW,NODE_ID_W) == P_DATA, "Data position");

        // Outbound: fields below BE stay put, RSVDC opens below BE, Poison
        // follows Data, and both are zero.
        fill();
        #1;
        check(b_from_c[P_BE-1:0] === c[P_BE-1:0], "fields below BE moved");
        check(b_from_c[P_BE +: RSVDC_W] == '0, "RSVDC not zero");
        check(b_from_c[P_BE+RSVDC_W +: DW/8] === c[P_BE +: DW/8], "BE not above RSVDC");
        check(b_from_c[P_DATA+RSVDC_W +: DW] === c[P_DATA +: DW], "Data not above BE");
        check(b_from_c[C_W+RSVDC_W +: POISON_W] == '0, "Poison not zero");
        b = b_from_c;
        #1;
        check(!bad, "legal CompData flagged");
        check(c_from_b === c, "legal round trip changed the flit");

        // HomeNID and DataSource are supported and pass through.
        b = b_from_c;
        b[P_HOME +: 7] = 7'h55;
        b[P_DSRC +: 8] = 8'h0F;
        #1;
        check(!bad, "HomeNID/DataSource flagged");
        check((c_from_b[P_HOME +: 7] == 7'h55) && (c_from_b[P_DSRC +: 8] == 8'h0F),
              "HomeNID/DataSource not kept");

        bad_case(P_BE + RSVDC_W - 1, "RSVDC");
        bad_case(C_W + RSVDC_W + POISON_W - 1, "Poison");
        bad_case(P_DPULL, "DataPull");
        bad_case(P_TAGOP + 1, "TagOp");
        bad_case(P_TAG + DW/32 - 1, "Tag");
        bad_case(P_TU, "TU");
        bad_case(P_TRACE, "TraceTag");
        bad_case(P_NUMDAT + 1, "NumDat");
        bad_case(P_REPL, "Replicate");

        done = 1'b1;
    end
endmodule

module tb_chi_dat_boundary_attrs;
    wire    done_128, done_256;
    integer fails_128, fails_256;

    tb_chi_dat_boundary_attrs_case #(
        .DW(128), .RSVDC_W(4),
        .P_TU(90), .P_TRACE(91), .P_CAH(92), .P_NUMDAT(93), .P_REPL(95),
        .P_BE(96), .P_DATA(112), .P_TOTAL(240)
    ) u_128 (.done(done_128), .fails(fails_128));

    tb_chi_dat_boundary_attrs_case #(
        .DW(256), .RSVDC_W(8),
        .P_TU(94), .P_TRACE(96), .P_CAH(97), .P_NUMDAT(98), .P_REPL(100),
        .P_BE(101), .P_DATA(133), .P_TOTAL(389)
    ) u_256 (.done(done_256), .fails(fails_256));

    initial begin
        $display("[%0t] TEST START tb_chi_dat_boundary_attrs", $time);
        wait (done_128 && done_256);
        if ((fails_128 != 0) || (fails_256 != 0)) begin
            $display("[%0t] TEST FAIL tb_chi_dat_boundary_attrs fails=%0d/%0d",
                     $time, fails_128, fails_256);
            $finish;
        end
        $display("[%0t] TEST PASS tb_chi_dat_boundary_attrs DAT matches Table B13.9 at 128 and 256 bits; RSVDC/Poison placed and unsupported attrs flagged", $time);
        $finish;
    end
endmodule
