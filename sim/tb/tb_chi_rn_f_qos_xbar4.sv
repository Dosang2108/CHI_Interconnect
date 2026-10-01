`timescale 1ns/1ps
`include "chi_defs.vh"

module tb_chi_rn_f_qos_xbar4;
    localparam integer DATA_WIDTH = 32;
    // CHI DAT channel width inside the DUT.
    localparam integer DAT_DATA_W = `CHI_DEFAULT_DAT_DATA_W;
    localparam integer ADDR_WIDTH = 32;
    localparam integer NODE_ID_W  = 7;
    localparam integer TXN_ID_W   = 12;
    localparam integer QOS_W      = 4;
    localparam integer DBID_W     = 12;
    localparam integer CPU_TAG_W  = 2;
    localparam integer REQ_W      = `CHI_REQ_W(NODE_ID_W);
    localparam integer RSP_W      = `CHI_RSP_W(NODE_ID_W);
    localparam integer SNP_W      = `CHI_SNP_W(NODE_ID_W);
    localparam integer DAT_W      = `CHI_DAT_W(DAT_DATA_W,NODE_ID_W);
    localparam integer REQ_QOS_LSB = `CHI_REQ_QOS_LSB(NODE_ID_W);

    reg clk;
    reg rstn;

    reg                  cpu_req_valid;
    wire                 cpu_req_ready;
    reg [ADDR_WIDTH-1:0] cpu_req_addr;
    reg [3:0]            cpu_req_op;
    reg [2:0]            cpu_req_size;
    reg [QOS_W-1:0]      cpu_req_qos;
    reg [CPU_TAG_W-1:0]  cpu_req_tag;
    reg [DATA_WIDTH-1:0] cpu_wdata;
    wire [DATA_WIDTH-1:0] cpu_rdata;
    wire                 cpu_resp_valid;
    wire [CPU_TAG_W-1:0] cpu_resp_tag;
    wire                 cpu_resp_line_valid;
    wire [64*8-1:0]      cpu_resp_line_data;
    wire [CPU_TAG_W-1:0] cpu_resp_line_tag;

    wire                 tx_req_valid;
    wire [REQ_W-1:0]     tx_req_flit;
    reg                  tx_req_lcrdv;
    wire                 tx_rsp_valid;
    wire [RSP_W-1:0]     tx_rsp_flit;
    reg                  tx_rsp_lcrdv;
    wire                 tx_dat_valid;
    wire [DAT_W-1:0]     tx_dat_flit;
    reg                  tx_dat_lcrdv;

    wire                 rx_rsp_ready;
    wire                 rx_rsp_lcrdv;
    wire                 rx_snp_ready;
    wire                 rx_snp_lcrdv;
    wire                 rx_dat_ready;
    wire                 rx_dat_lcrdv;
    wire [16*32-1:0]     perf_counts;
    wire                 cache_parity_error_event;

    integer wait_i;
    integer errors;

    chi_rn_f #(
        .NODE_ID(0),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .CPU_TAG_W(CPU_TAG_W),
        .INIT_CRD(2),
        .TXN_TBL_SIZE(4),
        .RN_CACHE_LINES(8),
        .ENABLE_PERF(0)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_op(cpu_req_op),
        .cpu_req_size(cpu_req_size),
        .cpu_req_qos(cpu_req_qos),
        .cpu_req_tag(cpu_req_tag),
        .cpu_wdata(cpu_wdata),
        .cpu_wdata_line_in({64*8{1'b0}}),
        .cpu_wstrb_line_in({64{1'b0}}),
        .cpu_rdata(cpu_rdata),
        .cpu_resp_valid(cpu_resp_valid),
        .cpu_resp_tag(cpu_resp_tag),
        .cpu_resp_line_valid(cpu_resp_line_valid),
        .cpu_resp_line_data(cpu_resp_line_data),
        .cpu_resp_line_tag(cpu_resp_line_tag),
        .tx_req_valid(tx_req_valid),
        .tx_req_flit(tx_req_flit),
        .tx_req_lcrdv(tx_req_lcrdv),
        .tx_rsp_valid(tx_rsp_valid),
        .tx_rsp_flit(tx_rsp_flit),
        .tx_rsp_lcrdv(tx_rsp_lcrdv),
        .tx_dat_valid(tx_dat_valid),
        .tx_dat_flit(tx_dat_flit),
        .tx_dat_lcrdv(tx_dat_lcrdv),
        .rx_rsp_valid(1'b0),
        .rx_rsp_flit({RSP_W{1'b0}}),
        .rx_rsp_ready(rx_rsp_ready),
        .rx_rsp_lcrdv(rx_rsp_lcrdv),
        .rx_snp_valid(1'b0),
        .rx_snp_flit({SNP_W{1'b0}}),
        .rx_snp_ready(rx_snp_ready),
        .rx_snp_lcrdv(rx_snp_lcrdv),
        .rx_dat_valid(1'b0),
        .rx_dat_flit({DAT_W{1'b0}}),
        .rx_dat_ready(rx_dat_ready),
        .rx_dat_lcrdv(rx_dat_lcrdv),
        .perf_counts(perf_counts),
        .cache_parity_error_event(cache_parity_error_event)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task fail;
        input [1023:0] msg;
        begin
            errors = errors + 1;
            $display("[%0t] TEST FAIL %0s", $time, msg);
        end
    endtask

    initial begin
        errors = 0;
        rstn = 1'b0;
        cpu_req_valid = 1'b0;
        cpu_req_addr = {ADDR_WIDTH{1'b0}};
        cpu_req_op = 4'd0;
        cpu_req_size = 3'd0;
        cpu_req_qos = {QOS_W{1'b0}};
        cpu_req_tag = {CPU_TAG_W{1'b0}};
        cpu_wdata = {DATA_WIDTH{1'b0}};
        tx_req_lcrdv = 1'b0;
        tx_rsp_lcrdv = 1'b0;
        tx_dat_lcrdv = 1'b0;

        repeat (6) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        $display("[%0t] TEST START T01_XBAR4_RNF_CPU_QOS_TO_REQ_FLIT", $time);
        @(negedge clk);
        cpu_req_addr = 32'h0000_1000;
        cpu_req_op = `CHI_CPU_OP_RD_SHARED;
        cpu_req_size = 3'd2;
        cpu_req_qos = 4'ha;
        cpu_req_valid = 1'b1;

        wait_i = 0;
        while (!cpu_req_ready && wait_i < 20) begin
            @(posedge clk);
            wait_i = wait_i + 1;
        end

        if (!cpu_req_ready) begin
            fail("RN-F did not accept CPU request");
        end else begin
            // Hold valid across the accepting edge; dropping it right after
            // @(posedge clk) races the RN-F's own sampling of that edge.
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;
        end

        wait_i = 0;
        while (!tx_req_valid && wait_i < 30) begin
            @(posedge clk);
            wait_i = wait_i + 1;
        end

        if (!tx_req_valid) begin
            fail("RN-F did not produce REQ flit");
        end else if (tx_req_flit[REQ_QOS_LSB +: QOS_W] !== 4'ha) begin
            fail("REQ flit QoS did not match CPU ingress QoS");
            $display("[%0t] DETAIL expected_qos=0xa got_qos=0x%0h",
                     $time, tx_req_flit[REQ_QOS_LSB +: QOS_W]);
        end else begin
            $display("[%0t] TEST PASS T01 RN-F propagated CPU QoS into REQ flit qos=0x%0h",
                     $time, tx_req_flit[REQ_QOS_LSB +: QOS_W]);
        end

        if (errors == 0)
            $display("[%0t] TEST PASS: tb_chi_rn_f_qos_xbar4 completed", $time);
        else
            $display("[%0t] TEST FAIL: tb_chi_rn_f_qos_xbar4 errors=%0d",
                     $time, errors);

        $finish;
    end
endmodule
