`timescale 1ns/1ps
`include "chi_defs.vh"

// chi_rn_dat_rx places each CompData beat by its DataID (B13.10.51:
// DataID = Addr[5:4] of the beat, so a DW-bit beat k has DataID
// k << log2(DW/128)). Beats are sent last-first; the assembled line must
// match. One case at 128 bits (DataID 3,2,1,0) and one at 256 bits
// (DataID 2,0).
module tb_chi_dat_dataid_rx_case #(
    parameter integer DW = 128
)(
    input          clk,
    input          rstn,
    output reg     done,
    output integer fails
);
    localparam integer NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W;
    localparam integer TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W;
    localparam integer DBID_W     = `CHI_DEFAULT_DBID_W;
    localparam integer LINE_BYTES = 64;
    localparam integer BEATS      = LINE_BYTES * 8 / DW;
    localparam integer LINE_WIDTH = LINE_BYTES * 8;
    localparam integer DAT_W      = `CHI_DAT_W(DW,NODE_ID_W);
    localparam integer SHIFT      = `CHI_DAT_DATAID_SHIFT(DW);

    reg              rx_dat_valid;
    reg  [DAT_W-1:0] rx_dat_flit;
    wire             rx_dat_ready;
    wire             line_valid;
    wire [LINE_WIDTH-1:0] line_data;

    reg  [LINE_WIDTH-1:0] expected_line;
    reg  [LINE_WIDTH-1:0] captured_line;
    reg                   got_line;
    integer               i;

    chi_rn_dat_rx #(
        .DATA_WIDTH(DW),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES),
        .LINE_BUF_ENTRIES(2)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .busy(),
        .rx_dat_valid(rx_dat_valid),
        .rx_dat_flit(rx_dat_flit),
        .rx_dat_ready(rx_dat_ready),
        .rx_dat_lcrdv(),
        .data_valid(),
        .data(),
        .txn_id(),
        .src_id(),
        .home_nid(),
        .resp_err(),
        .resp(),
        .dbid(),
        .line_valid(line_valid),
        .line_data(line_data)
    );

    function [DAT_W-1:0] make_dat_flit;
        input [`CHI_DAT_DATAID_W-1:0] data_id;
        input [DW-1:0]                beat_data;
        begin
            make_dat_flit = {DAT_W{1'b0}};
            make_dat_flit[`CHI_DAT_BE_LSB(DW,NODE_ID_W) +: DW/8] = {(DW/8){1'b1}};
            make_dat_flit[`CHI_DAT_DATA_LSB(DW,NODE_ID_W) +: DW] = beat_data;
            make_dat_flit[`CHI_DAT_DATAID_LSB(DW,NODE_ID_W) +: `CHI_DAT_DATAID_W] = data_id;
            make_dat_flit[`CHI_DAT_TXN_LSB(DW,NODE_ID_W) +: TXN_ID_W] = 12'h123;
            make_dat_flit[`CHI_DAT_SRC_LSB(DW,NODE_ID_W) +: NODE_ID_W] = 7'd2;
            make_dat_flit[`CHI_DAT_HOME_NID_LSB(DW,NODE_ID_W) +: NODE_ID_W] = 7'd2;
            make_dat_flit[`CHI_DAT_OPCODE_LSB(DW,NODE_ID_W) +: 4] = `CHI_DAT_OPCODE_RD_DATA;
        end
    endfunction

    function [DW-1:0] beat_pattern;
        input integer beat;
        integer w;
        begin
            for (w = 0; w < DW/32; w = w + 1)
                beat_pattern[w*32 +: 32] = 32'h5A00_0000 | (beat << 8) | w;
        end
    endfunction

    always @(posedge clk) begin
        if (line_valid) begin
            got_line <= 1'b1;
            captured_line <= line_data;
        end
    end

    initial begin
        done = 1'b0;
        fails = 0;
        rx_dat_valid = 1'b0;
        rx_dat_flit = {DAT_W{1'b0}};
        got_line = 1'b0;
        captured_line = {LINE_WIDTH{1'b0}};
        for (i = 0; i < BEATS; i = i + 1)
            expected_line[i*DW +: DW] = beat_pattern(i);

        wait (rstn);
        repeat (2) @(posedge clk);
        for (i = BEATS - 1; i >= 0; i = i - 1) begin
            @(posedge clk);
            rx_dat_flit  <= make_dat_flit(i << SHIFT, beat_pattern(i));
            rx_dat_valid <= 1'b1;
            @(posedge clk);
            while (!rx_dat_ready)
                @(posedge clk);
            rx_dat_valid <= 1'b0;
        end
        repeat (10) @(posedge clk);

        if (!got_line) begin
            fails = fails + 1;
            $display("[%0t] TEST FAIL tb_chi_dat_dataid_rx DW=%0d no assembled line", $time, DW);
        end else if (captured_line !== expected_line) begin
            fails = fails + 1;
            $display("[%0t] TEST FAIL tb_chi_dat_dataid_rx DW=%0d line exp=0x%0h got=0x%0h",
                     $time, DW, expected_line, captured_line);
        end
        done = 1'b1;
    end
endmodule

module tb_chi_dat_dataid_rx;
    reg     clk;
    reg     rstn;
    wire    done_128, done_256;
    integer fails_128, fails_256;

    tb_chi_dat_dataid_rx_case #(.DW(128)) u_128
        (.clk(clk), .rstn(rstn), .done(done_128), .fails(fails_128));
    tb_chi_dat_dataid_rx_case #(.DW(256)) u_256
        (.clk(clk), .rstn(rstn), .done(done_256), .fails(fails_256));

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rstn = 1'b0;
        $display("[%0t] TEST START tb_chi_dat_dataid_rx", $time);
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        wait (done_128 && done_256);
        if ((fails_128 != 0) || (fails_256 != 0)) begin
            $display("[%0t] TEST FAIL tb_chi_dat_dataid_rx fails=%0d/%0d",
                     $time, fails_128, fails_256);
            $finish;
        end
        $display("[%0t] TEST PASS tb_chi_dat_dataid_rx beats sent last-first were placed by DataID at 128 and 256 bits", $time);
        $finish;
    end
endmodule
