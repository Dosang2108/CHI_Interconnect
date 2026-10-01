`timescale 1ns/1ps
`include "chi_defs.vh"

module tb_chi_fabric_qos_xbar3;
    localparam integer NUM_RN      = 2;
    localparam integer NUM_HN      = 1;
    localparam integer NUM_SN      = 1;
    localparam integer NUM_MN      = 0;
    localparam integer NUM_NODES   = NUM_RN + NUM_HN + NUM_SN + NUM_MN;
    localparam integer NUM_REQ_SRC = NUM_RN + NUM_HN;
    localparam integer NUM_REQ_TGT = NUM_HN + NUM_SN + NUM_MN;
    localparam integer NUM_SNP_SRC = NUM_HN + NUM_MN;
    localparam integer ADDR_WIDTH  = 32;
    // CHI DAT channel width (B13.9.4 allows 128, 256 or 512).
    localparam integer DATA_WIDTH  = `CHI_DEFAULT_DAT_DATA_W;
    localparam integer NODE_ID_W   = 7;
    localparam integer TXN_ID_W    = 12;
    localparam integer QOS_W       = 4;
    localparam integer DBID_W      = 12;
    localparam integer FIFO_DEPTH  = 2;
    localparam integer OUTPUT_FIFO_DEPTH = 2;
    localparam integer TARGET_NODE = 2;

    localparam integer REQ_W = `CHI_REQ_W(NODE_ID_W);
    localparam integer RSP_W = `CHI_RSP_W(NODE_ID_W);
    localparam integer SNP_W = `CHI_SNP_W(NODE_ID_W);
    localparam integer DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W);

    localparam integer RSP_RESP_LSB    = `CHI_RSP_RESP_LSB(NODE_ID_W);
    localparam integer RSP_RESPERR_LSB = `CHI_RSP_RESPERR_LSB(NODE_ID_W);
    localparam integer RSP_DBID_LSB    = `CHI_RSP_DBID_LSB(NODE_ID_W);
    localparam integer RSP_OPCODE_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam integer RSP_TXN_LSB     = `CHI_RSP_TXN_LSB(NODE_ID_W);
    localparam integer RSP_SRC_LSB     = `CHI_RSP_SRC_LSB(NODE_ID_W);
    localparam integer RSP_TGT_LSB     = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam integer RSP_QOS_LSB     = `CHI_RSP_QOS_LSB(NODE_ID_W);

    localparam integer DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_BE_LSB      = `CHI_DAT_BE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_OPCODE_LSB  = `CHI_DAT_OPCODE_LSB(DATA_WIDTH,NODE_ID_W);
    localparam integer DAT_QOS_LSB     = `CHI_DAT_QOS_LSB(DATA_WIDTH,NODE_ID_W);

    reg clk;
    reg rstn;
    reg clear;

    reg  [NUM_REQ_SRC*QOS_W-1:0] req_qos_flat;
    reg  [NUM_NODES*QOS_W-1:0]   rsp_qos_flat;
    reg  [NUM_NODES*QOS_W-1:0]   dat_qos_flat;
    reg  [NUM_SNP_SRC*QOS_W-1:0] snp_qos_flat;
    reg  [7:0]                   cfg_qos_age_shift;
    reg  [7:0]                   cfg_qos_age_max;

    reg  [NUM_REQ_SRC-1:0] req_in_valid;
    wire [NUM_REQ_SRC-1:0] req_in_ready;
    reg  [NUM_REQ_SRC*REQ_W-1:0] req_in_flit;
    wire [NUM_REQ_SRC-1:0] req_in_pop_pulse;
    reg  [NUM_REQ_SRC*NUM_REQ_TGT-1:0] req_route_onehot;
    wire [NUM_REQ_TGT-1:0] req_out_valid;
    reg  [NUM_REQ_TGT-1:0] req_out_ready;
    wire [NUM_REQ_TGT*REQ_W-1:0] req_out_flit;

    reg  [NUM_NODES-1:0] rsp_in_valid;
    wire [NUM_NODES-1:0] rsp_in_ready;
    reg  [NUM_NODES*RSP_W-1:0] rsp_in_flit;
    wire [NUM_NODES-1:0] rsp_in_pop_pulse;
    reg  [NUM_NODES*NUM_NODES-1:0] rsp_route_onehot;
    wire [NUM_NODES-1:0] rsp_out_valid;
    reg  [NUM_NODES-1:0] rsp_out_ready;
    wire [NUM_NODES*RSP_W-1:0] rsp_out_flit;

    reg  [NUM_SNP_SRC-1:0] snp_in_valid;
    wire [NUM_SNP_SRC-1:0] snp_in_ready;
    reg  [NUM_SNP_SRC*SNP_W-1:0] snp_in_flit;
    wire [NUM_SNP_SRC-1:0] snp_in_pop_pulse;
    reg  [NUM_SNP_SRC*NUM_RN-1:0] snp_route_onehot;
    wire [NUM_RN-1:0] snp_out_valid;
    reg  [NUM_RN-1:0] snp_out_ready;
    wire [NUM_RN*SNP_W-1:0] snp_out_flit;

    reg  [NUM_NODES-1:0] dat_in_valid;
    wire [NUM_NODES-1:0] dat_in_ready;
    reg  [NUM_NODES*DAT_W-1:0] dat_in_flit;
    wire [NUM_NODES-1:0] dat_in_pop_pulse;
    reg  [NUM_NODES*NUM_NODES-1:0] dat_route_onehot;
    wire [NUM_NODES-1:0] dat_out_valid;
    reg  [NUM_NODES-1:0] dat_out_ready;
    wire [NUM_NODES*DAT_W-1:0] dat_out_flit;

    integer errors;
    integer tests;

    chi_fabric #(
        .NUM_RN(NUM_RN),
        .NUM_HN(NUM_HN),
        .NUM_SN(NUM_SN),
        .NUM_MN(NUM_MN),
        .NUM_NODES(NUM_NODES),
        .NUM_REQ_SRC(NUM_REQ_SRC),
        .NUM_REQ_TGT(NUM_REQ_TGT),
        .NUM_SNP_SRC(NUM_SNP_SRC),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .FIFO_DEPTH(FIFO_DEPTH),
        .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH),
        .ENABLE_QOS_AGING(0)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .req_qos_flat(req_qos_flat),
        .rsp_qos_flat(rsp_qos_flat),
        .dat_qos_flat(dat_qos_flat),
        .snp_qos_flat(snp_qos_flat),
        .cfg_qos_age_shift(cfg_qos_age_shift),
        .cfg_qos_age_max(cfg_qos_age_max),
        .req_in_valid(req_in_valid),
        .req_in_ready(req_in_ready),
        .req_in_flit(req_in_flit),
        .req_in_pop_pulse(req_in_pop_pulse),
        .req_route_onehot(req_route_onehot),
        .req_out_valid(req_out_valid),
        .req_out_ready(req_out_ready),
        .req_out_flit(req_out_flit),
        .rsp_in_valid(rsp_in_valid),
        .rsp_in_ready(rsp_in_ready),
        .rsp_in_flit(rsp_in_flit),
        .rsp_in_pop_pulse(rsp_in_pop_pulse),
        .rsp_route_onehot(rsp_route_onehot),
        .rsp_out_valid(rsp_out_valid),
        .rsp_out_ready(rsp_out_ready),
        .rsp_out_flit(rsp_out_flit),
        .snp_in_valid(snp_in_valid),
        .snp_in_ready(snp_in_ready),
        .snp_in_flit(snp_in_flit),
        .snp_in_pop_pulse(snp_in_pop_pulse),
        .snp_route_onehot(snp_route_onehot),
        .snp_out_valid(snp_out_valid),
        .snp_out_ready(snp_out_ready),
        .snp_out_flit(snp_out_flit),
        .dat_in_valid(dat_in_valid),
        .dat_in_ready(dat_in_ready),
        .dat_in_flit(dat_in_flit),
        .dat_in_pop_pulse(dat_in_pop_pulse),
        .dat_route_onehot(dat_route_onehot),
        .dat_out_valid(dat_out_valid),
        .dat_out_ready(dat_out_ready),
        .dat_out_flit(dat_out_flit)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function [RSP_W-1:0] make_rsp_flit;
        input [NODE_ID_W-1:0] src;
        input [NODE_ID_W-1:0] tgt;
        input [TXN_ID_W-1:0]  txn;
        input [QOS_W-1:0]     qos;
        begin
            make_rsp_flit = {RSP_W{1'b0}};
            make_rsp_flit[RSP_RESP_LSB +: 3]       = 3'd0;
            make_rsp_flit[RSP_RESPERR_LSB +: 2]    = `CHI_RESPERR_OK;
            make_rsp_flit[RSP_DBID_LSB +: DBID_W]  = {DBID_W{1'b0}};
            make_rsp_flit[RSP_OPCODE_LSB +: `CHI_RSP_OPCODE_W] = `CHI_RSP_COMP;
            make_rsp_flit[RSP_TXN_LSB +: TXN_ID_W] = txn;
            make_rsp_flit[RSP_SRC_LSB +: NODE_ID_W] = src;
            make_rsp_flit[RSP_TGT_LSB +: NODE_ID_W] = tgt;
            make_rsp_flit[RSP_QOS_LSB +: QOS_W]     = qos;
        end
    endfunction

    function [DAT_W-1:0] make_dat_flit;
        input [NODE_ID_W-1:0] src;
        input [NODE_ID_W-1:0] tgt;
        input [TXN_ID_W-1:0]  txn;
        input [QOS_W-1:0]     qos;
        input [DATA_WIDTH-1:0] data;
        begin
            make_dat_flit = {DAT_W{1'b0}};
            make_dat_flit[DAT_RESPERR_LSB +: 2] = `CHI_RESPERR_OK;
            make_dat_flit[DAT_BE_LSB +: (DATA_WIDTH/8)] = {(DATA_WIDTH/8){1'b1}};
            make_dat_flit[DAT_DATA_LSB +: DATA_WIDTH] = data;
            make_dat_flit[DAT_DATAID_LSB +: `CHI_DAT_DATAID_W] = {`CHI_DAT_DATAID_W{1'b0}};
            make_dat_flit[DAT_DBID_LSB +: DBID_W] = {DBID_W{1'b0}};
            make_dat_flit[DAT_TXN_LSB +: TXN_ID_W] = txn;
            make_dat_flit[DAT_SRC_LSB +: NODE_ID_W] = src;
            make_dat_flit[DAT_TGT_LSB +: NODE_ID_W] = tgt;
            make_dat_flit[DAT_RESP_LSB +: 3] = 3'd0;
            make_dat_flit[DAT_OPCODE_LSB +: 4] = `CHI_DAT_OPCODE_RD_DATA;
            make_dat_flit[DAT_QOS_LSB +: `CHI_DAT_QOS_W] = qos;
        end
    endfunction

    task reset_inputs;
        begin
            req_qos_flat = {NUM_REQ_SRC*QOS_W{1'b0}};
            rsp_qos_flat = {NUM_NODES*QOS_W{1'b0}};
            dat_qos_flat = {NUM_NODES*QOS_W{1'b0}};
            snp_qos_flat = {NUM_SNP_SRC*QOS_W{1'b0}};
            cfg_qos_age_shift = 8'd4;
            cfg_qos_age_max = 8'd255;
            req_in_valid = {NUM_REQ_SRC{1'b0}};
            req_in_flit = {NUM_REQ_SRC*REQ_W{1'b0}};
            req_route_onehot = {NUM_REQ_SRC*NUM_REQ_TGT{1'b0}};
            req_out_ready = {NUM_REQ_TGT{1'b1}};
            rsp_in_valid = {NUM_NODES{1'b0}};
            rsp_in_flit = {NUM_NODES*RSP_W{1'b0}};
            rsp_route_onehot = {NUM_NODES*NUM_NODES{1'b0}};
            rsp_out_ready = {NUM_NODES{1'b1}};
            snp_in_valid = {NUM_SNP_SRC{1'b0}};
            snp_in_flit = {NUM_SNP_SRC*SNP_W{1'b0}};
            snp_route_onehot = {NUM_SNP_SRC*NUM_RN{1'b0}};
            snp_out_ready = {NUM_RN{1'b1}};
            dat_in_valid = {NUM_NODES{1'b0}};
            dat_in_flit = {NUM_NODES*DAT_W{1'b0}};
            dat_route_onehot = {NUM_NODES*NUM_NODES{1'b0}};
            dat_out_ready = {NUM_NODES{1'b1}};
        end
    endtask

    task fail;
        input [1023:0] msg;
        begin
            errors = errors + 1;
            $display("[%0t] TEST FAIL %0s", $time, msg);
        end
    endtask

    task pass_step;
        input [1023:0] msg;
        begin
            $display("[%0t] TEST PASS %0s", $time, msg);
        end
    endtask

    task push_two_rsp;
        begin
            rsp_in_flit[0*RSP_W +: RSP_W] =
                make_rsp_flit(7'd0, TARGET_NODE[NODE_ID_W-1:0], 12'h100, 4'h1);
            rsp_in_flit[1*RSP_W +: RSP_W] =
                make_rsp_flit(7'd1, TARGET_NODE[NODE_ID_W-1:0], 12'h101, 4'hf);
            rsp_qos_flat[0*QOS_W +: QOS_W] = 4'h1;
            rsp_qos_flat[1*QOS_W +: QOS_W] = 4'hf;
            rsp_route_onehot[0*NUM_NODES + TARGET_NODE] = 1'b1;
            rsp_route_onehot[1*NUM_NODES + TARGET_NODE] = 1'b1;
            rsp_in_valid[1:0] = 2'b11;
            @(posedge clk);
            rsp_in_valid = {NUM_NODES{1'b0}};
        end
    endtask

    task push_two_dat;
        begin
            dat_in_flit[0*DAT_W +: DAT_W] =
                make_dat_flit(7'd0, TARGET_NODE[NODE_ID_W-1:0],
                              12'h200, 4'h2, 32'hd000_0000);
            dat_in_flit[1*DAT_W +: DAT_W] =
                make_dat_flit(7'd1, TARGET_NODE[NODE_ID_W-1:0],
                              12'h201, 4'he, 32'hd000_0001);
            dat_qos_flat[0*QOS_W +: QOS_W] = 4'h2;
            dat_qos_flat[1*QOS_W +: QOS_W] = 4'he;
            dat_route_onehot[0*NUM_NODES + TARGET_NODE] = 1'b1;
            dat_route_onehot[1*NUM_NODES + TARGET_NODE] = 1'b1;
            dat_in_valid[1:0] = 2'b11;
            @(posedge clk);
            dat_in_valid = {NUM_NODES{1'b0}};
        end
    endtask

    task expect_rsp_src;
        input [NODE_ID_W-1:0] exp_src;
        input [1023:0] label;
        integer wait_i;
        reg [NODE_ID_W-1:0] got_src;
        begin
            wait_i = 0;
            while (!rsp_out_valid[TARGET_NODE] && wait_i < 40) begin
                @(posedge clk);
                wait_i = wait_i + 1;
            end

            if (!rsp_out_valid[TARGET_NODE]) begin
                fail({label, " timeout waiting RSP"});
            end else begin
                got_src = rsp_out_flit[TARGET_NODE*RSP_W + RSP_SRC_LSB +: NODE_ID_W];
                if (got_src !== exp_src) begin
                    fail({label, " wrong RSP source"});
                    $display("[%0t] DETAIL expected_src=%0d got_src=%0d",
                             $time, exp_src, got_src);
                end else begin
                    pass_step(label);
                end
                @(posedge clk);
            end
        end
    endtask

    task expect_dat_src;
        input [NODE_ID_W-1:0] exp_src;
        input [DATA_WIDTH-1:0] exp_data;
        input [1023:0] label;
        integer wait_i;
        reg [NODE_ID_W-1:0] got_src;
        reg [DATA_WIDTH-1:0] got_data;
        begin
            wait_i = 0;
            while (!dat_out_valid[TARGET_NODE] && wait_i < 40) begin
                @(posedge clk);
                wait_i = wait_i + 1;
            end

            if (!dat_out_valid[TARGET_NODE]) begin
                fail({label, " timeout waiting DAT"});
            end else begin
                got_src = dat_out_flit[TARGET_NODE*DAT_W + DAT_SRC_LSB +: NODE_ID_W];
                got_data = dat_out_flit[TARGET_NODE*DAT_W + DAT_DATA_LSB +: DATA_WIDTH];
                if ((got_src !== exp_src) || (got_data !== exp_data)) begin
                    fail({label, " wrong DAT source/data"});
                    $display("[%0t] DETAIL expected_src=%0d got_src=%0d expected_data=0x%08h got_data=0x%08h",
                             $time, exp_src, got_src, exp_data, got_data);
                end else begin
                    pass_step(label);
                end
                @(posedge clk);
            end
        end
    endtask

    initial begin
        errors = 0;
        tests = 0;
        clear = 1'b0;
        rstn = 1'b0;
        reset_inputs();
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        tests = tests + 1;
        $display("[%0t] TEST START T01_XBAR3_RSP_QOS_HIGH_SOURCE_WINS", $time);
        push_two_rsp();
        expect_rsp_src(7'd1, "T01 step1 high-QoS RSP source granted first");
        expect_rsp_src(7'd0, "T01 step2 low-QoS RSP source granted second");

        repeat (2) @(posedge clk);
        clear = 1'b1;
        @(posedge clk);
        clear = 1'b0;
        repeat (2) @(posedge clk);

        tests = tests + 1;
        $display("[%0t] TEST START T02_XBAR3_DAT_QOS_HIGH_SOURCE_WINS", $time);
        push_two_dat();
        expect_dat_src(7'd1, 32'hd000_0001,
                       "T02 step1 high-QoS DAT source granted first");
        expect_dat_src(7'd0, 32'hd000_0000,
                       "T02 step2 low-QoS DAT source granted second");

        if (errors == 0)
            $display("[%0t] TEST PASS: tb_chi_fabric_qos_xbar3 completed tests=%0d",
                     $time, tests);
        else
            $display("[%0t] TEST FAIL: tb_chi_fabric_qos_xbar3 errors=%0d",
                     $time, errors);

        $finish;
    end
endmodule
