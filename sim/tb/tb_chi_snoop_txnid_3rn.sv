`timescale 1ns/1ps
`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// tb_chi_snoop_txnid_3rn
// Three RN-F ports on one HN-F. RN0 and RN1 both allocate TxnID 0 for their
// first request after reset. When both requests need a snoop of RN2 at the
// same time, the HN must still give the two snoops distinct TxnIDs (CHI
// B2.5.1: Home generates its own unique snoop TxnID), otherwise the snoop
// responses cannot be told apart.
// -----------------------------------------------------------------------------
module tb_chi_snoop_txnid_3rn;
    localparam integer NUM_RN     = 3;
    localparam integer NUM_HN     = 1;
    localparam integer NUM_SN     = 1;
    localparam integer NUM_MN     = 1;
    localparam integer DATA_WIDTH = 32;
    // CHI DAT channel width inside the DUT.
    localparam integer DAT_DATA_W = `CHI_DEFAULT_DAT_DATA_W;
    localparam integer ADDR_WIDTH = 32;
    localparam integer NODE_ID_W  = 7;
    localparam integer TXN_ID_W   = 12;
    localparam integer QOS_W      = 4;
    localparam integer DBID_W     = 12;
    localparam integer CPU_TAG_W  = 2;
    // DAT beats per line.
    localparam integer BEATS      = 64 / (DAT_DATA_W / 8);
    localparam integer MAX_WAIT   = 4000;
    localparam integer SNP_W      = `CHI_SNP_W(NODE_ID_W);
    localparam integer RSP_W      = `CHI_RSP_W(NODE_ID_W);
    localparam integer DAT_W      = `CHI_DAT_W(DAT_DATA_W,NODE_ID_W);

    localparam [ADDR_WIDTH-1:0] LINE_A = 32'h0002_1000;
    localparam [ADDR_WIDTH-1:0] LINE_B = 32'h0002_2040;

    reg clk;
    reg rstn;
    reg test_failed;

    reg                          csr_valid;
    reg                          csr_write;
    reg  [7:0]                   csr_addr;
    reg  [63:0]                  csr_wdata;
    wire                         csr_ready;
    wire [63:0]                  csr_rdata;
    wire                         chi_irq;

    reg  [NUM_RN-1:0]            cpu_req_valid;
    wire [NUM_RN-1:0]            cpu_req_ready;
    reg  [NUM_RN*ADDR_WIDTH-1:0] cpu_req_addr;
    reg  [NUM_RN*4-1:0]          cpu_req_op;
    reg  [NUM_RN*3-1:0]          cpu_req_size;
    wire [NUM_RN*DATA_WIDTH-1:0] cpu_rdata;
    wire [NUM_RN-1:0]            cpu_resp_valid;

    wire [NUM_SN-1:0]            axi_arvalid;
    wire [NUM_SN-1:0]            axi_arready;
    wire [NUM_SN*ADDR_WIDTH-1:0] axi_araddr;
    wire [NUM_SN*8-1:0]          axi_arlen;
    reg  [NUM_SN-1:0]            axi_rvalid;
    wire [NUM_SN-1:0]            axi_rready;
    reg  [NUM_SN*DATA_WIDTH-1:0] axi_rdata;
    wire [NUM_SN-1:0]            axi_awvalid;
    wire [NUM_SN-1:0]            axi_awready;
    wire [NUM_SN-1:0]            axi_wvalid;
    wire [NUM_SN-1:0]            axi_wready;
    wire [NUM_SN-1:0]            axi_wlast;
    reg  [NUM_SN-1:0]            axi_bvalid;
    wire [NUM_SN-1:0]            axi_bready;

    always #5 clk = ~clk;

    function automatic [DATA_WIDTH-1:0] mem_pattern;
        input [ADDR_WIDTH-1:0] addr;
        input integer beat;
        reg [ADDR_WIDTH-1:0] line;
        begin
            line = {addr[ADDR_WIDTH-1:6], 6'd0};
            mem_pattern = line ^ 32'h5A00_0000 ^ beat;
        end
    endfunction

    task automatic fail;
        input [1023:0] msg;
        begin
            test_failed = 1'b1;
            $display("[%0t] TEST FAIL tb_chi_snoop_txnid_3rn %0s", $time, msg);
            #1;
            $finish;
        end
    endtask

    // ---------------------------------------------------------------- AXI slave
    reg        rd_busy;
    reg [ADDR_WIDTH-1:0] rd_addr;
    reg [7:0]  rd_len;
    reg [7:0]  rd_beat;
    reg [1:0]  rd_delay;
    reg        wr_busy;

    assign axi_arready = !rd_busy;
    assign axi_awready = !wr_busy && !axi_bvalid[0];
    assign axi_wready  = wr_busy;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_busy <= 1'b0;
            rd_beat <= 8'd0;
            rd_delay <= 2'd0;
            axi_rvalid <= 1'b0;
            axi_rdata <= {DATA_WIDTH{1'b0}};
            wr_busy <= 1'b0;
            axi_bvalid <= 1'b0;
        end else begin
            if (axi_arvalid[0] && axi_arready[0]) begin
                rd_busy <= 1'b1;
                rd_addr <= axi_araddr[ADDR_WIDTH-1:0];
                rd_len <= axi_arlen[7:0];
                rd_beat <= 8'd0;
                rd_delay <= 2'd2;
            end
            if (rd_busy && !axi_rvalid[0]) begin
                if (rd_delay != 2'd0) begin
                    rd_delay <= rd_delay - 1'b1;
                end else begin
                    axi_rvalid[0] <= 1'b1;
                    axi_rdata[DATA_WIDTH-1:0] <= mem_pattern(rd_addr, rd_beat);
                end
            end else if (axi_rvalid[0] && axi_rready[0]) begin
                if (rd_beat == rd_len) begin
                    axi_rvalid[0] <= 1'b0;
                    rd_busy <= 1'b0;
                end else begin
                    rd_beat <= rd_beat + 1'b1;
                    axi_rdata[DATA_WIDTH-1:0] <= mem_pattern(rd_addr, rd_beat + 1);
                end
            end

            if (axi_awvalid[0] && axi_awready[0])
                wr_busy <= 1'b1;
            if (axi_wvalid[0] && axi_wready[0] && axi_wlast[0]) begin
                wr_busy <= 1'b0;
                axi_bvalid[0] <= 1'b1;
            end
            if (axi_bvalid[0] && axi_bready[0])
                axi_bvalid[0] <= 1'b0;
        end
    end

    // ------------------------------------------- HN snoop TxnID uniqueness check
    // A snoop is outstanding from the HN sending it until the HN receives the
    // target's SnpResp/SnpRespFwded or the last beat of its SnpRespData.
    reg [(1<<TXN_ID_W)-1:0] snp_busy [0:NUM_RN-1];
    integer mi;

    wire                 hn_snp_fire = dut.gen_hn[0].u_hn_f.tx_snp_valid &&
                                       dut.gen_hn[0].u_hn_f.tx_snp_lcrdv;
    wire [NODE_ID_W-1:0] hn_snp_tgt  = dut.gen_hn[0].u_hn_f.tx_snp_tgt_id;
    wire [SNP_W-1:0]     hn_snp_flit = dut.gen_hn[0].u_hn_f.tx_snp_flit;
    wire                 hn_rsp_fire = dut.gen_hn[0].u_hn_f.rx_rsp_valid &&
                                       dut.gen_hn[0].u_hn_f.rx_rsp_ready;
    wire [RSP_W-1:0]     hn_rsp_flit = dut.gen_hn[0].u_hn_f.rx_rsp_flit;
    wire                 hn_dat_fire = dut.gen_hn[0].u_hn_f.rx_dat_valid &&
                                       dut.gen_hn[0].u_hn_f.rx_dat_ready;
    wire [DAT_W-1:0]     hn_dat_flit = dut.gen_hn[0].u_hn_f.rx_dat_flit;

    wire [`CHI_RSP_OPCODE_W-1:0] hn_rsp_opcode =
        hn_rsp_flit[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W];
    wire [TXN_ID_W-1:0]  hn_rsp_txn = hn_rsp_flit[`CHI_RSP_TXN_LSB(NODE_ID_W) +: TXN_ID_W];
    wire [NODE_ID_W-1:0] hn_rsp_src = hn_rsp_flit[`CHI_RSP_SRC_LSB(NODE_ID_W) +: NODE_ID_W];
    wire [3:0]           hn_dat_opcode =
        hn_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4];
    wire [TXN_ID_W-1:0]  hn_dat_txn = hn_dat_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W];
    wire [NODE_ID_W-1:0] hn_dat_src = hn_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W];
    wire [3:0]           hn_dat_id  = hn_dat_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W];
    wire [TXN_ID_W-1:0]  hn_snp_txn = hn_snp_flit[`CHI_SNP_TXN_LSB(NODE_ID_W) +: TXN_ID_W];

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (mi = 0; mi < NUM_RN; mi = mi + 1)
                snp_busy[mi] <= {(1<<TXN_ID_W){1'b0}};
        end else begin
            if (hn_rsp_fire && (hn_rsp_src < NUM_RN) &&
                ((hn_rsp_opcode == `CHI_RSP_SNP_RESP) ||
                 (hn_rsp_opcode == `CHI_RSP_SNP_RESP_FWD)))
                snp_busy[hn_rsp_src][hn_rsp_txn] <= 1'b0;
            if (hn_dat_fire && (hn_dat_src < NUM_RN) &&
                ((hn_dat_opcode == `CHI_DAT_OPCODE_SNP_DATA) ||
                 (hn_dat_opcode == `CHI_DAT_OPCODE_SNP_DATA_FWD)) &&
                (hn_dat_id == BEATS - 1))
                snp_busy[hn_dat_src][hn_dat_txn] <= 1'b0;
            if (hn_snp_fire)
                $display("[%0t] HN SNP  -> node %0d txn 0x%0h", $time, hn_snp_tgt, hn_snp_txn);
            if (hn_rsp_fire && ((hn_rsp_opcode == `CHI_RSP_SNP_RESP) ||
                                (hn_rsp_opcode == `CHI_RSP_SNP_RESP_FWD)))
                $display("[%0t] HN RSP  <- node %0d txn 0x%0h opcode 0x%0h", $time,
                         hn_rsp_src, hn_rsp_txn, hn_rsp_opcode);
            if (hn_snp_fire && (hn_snp_tgt < NUM_RN)) begin
                if (snp_busy[hn_snp_tgt][hn_snp_txn]) begin
                    $display("[%0t] HN snoop to RN%0d reuses outstanding TxnID 0x%0h",
                             $time, hn_snp_tgt, hn_snp_txn);
                    fail("HN snoop TxnID reused while a snoop with the same TxnID is outstanding at that RN");
                end
                snp_busy[hn_snp_tgt][hn_snp_txn] <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------- CPU helpers
    task automatic cpu_read;
        input integer rn;
        input [ADDR_WIDTH-1:0] addr;
        input [3:0] op;
        input [1023:0] name;
        integer t;
        begin
            @(negedge clk);
            cpu_req_addr[rn*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            cpu_req_op[rn*4 +: 4] = op;
            cpu_req_size[rn*3 +: 3] = 3'd6;
            cpu_req_valid[rn] = 1'b1;
            t = 0;
            while (t < MAX_WAIT) begin
                @(posedge clk);
                t = t + 1;
                if (cpu_req_ready[rn]) t = MAX_WAIT + 1;
            end
            if (t != MAX_WAIT + 1) fail({name, ": request not accepted"});
            @(negedge clk);
            cpu_req_valid[rn] = 1'b0;
            t = 0;
            while (!cpu_resp_valid[rn] && (t < MAX_WAIT)) begin
                @(posedge clk);
                t = t + 1;
            end
            if (!cpu_resp_valid[rn]) fail({name, ": no CPU response"});
            if (cpu_rdata[rn*DATA_WIDTH +: DATA_WIDTH] !== mem_pattern(addr, 0)) begin
                $display("[%0t] %0s exp=0x%08h got=0x%08h", $time, name,
                         mem_pattern(addr, 0), cpu_rdata[rn*DATA_WIDTH +: DATA_WIDTH]);
                fail({name, ": wrong data"});
            end
            $display("[%0t] STEP %0s RN%0d addr=0x%08h data=0x%08h ok", $time, name, rn,
                     addr, cpu_rdata[rn*DATA_WIDTH +: DATA_WIDTH]);
        end
    endtask

    task automatic wait_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rstn = 1'b0;
        test_failed = 1'b0;
        csr_valid = 1'b0;
        csr_write = 1'b0;
        csr_addr = 8'h00;
        csr_wdata = 64'd0;
        cpu_req_valid = {NUM_RN{1'b0}};
        cpu_req_addr = {NUM_RN*ADDR_WIDTH{1'b0}};
        cpu_req_op = {NUM_RN*4{1'b0}};
        cpu_req_size = {NUM_RN*3{1'b0}};

        wait_cycles(10);
        rstn = 1'b1;
        wait_cycles(10);

        // RN2 owns both lines, so the HN must snoop RN2 for any other reader.
        cpu_read(2, LINE_A, `CHI_CPU_OP_RD_UNIQUE, "RN2 ReadUnique line A");
        cpu_read(2, LINE_B, `CHI_CPU_OP_RD_UNIQUE, "RN2 ReadUnique line B");
        wait_cycles(20);

        // First request of RN0 and RN1 after reset: both use TxnID 0, so the
        // HN's snoops of RN2 for them carry the same requester TxnID. Today
        // the HN finishes one snoop-requiring request before starting the
        // next, so the two snoops never overlap; the checker above fails if
        // a future HN change lets them overlap with a shared TxnID.
        fork
            cpu_read(0, LINE_A, `CHI_CPU_OP_RD_SHARED, "RN0 ReadShared line A (snoops RN2)");
            cpu_read(1, LINE_B, `CHI_CPU_OP_RD_SHARED, "RN1 ReadShared line B (snoops RN2)");
        join
        wait_cycles(50);

        if (!test_failed)
            $display("[%0t] TEST PASS tb_chi_snoop_txnid_3rn no HN snoop TxnID was reused while outstanding at RN2", $time);
        $finish;
    end

    initial begin
        #2000000;
        fail("global watchdog: simulation did not finish");
    end

    chi_top #(
        .NUM_RN(NUM_RN),
        .NUM_HN(NUM_HN),
        .NUM_SN(NUM_SN),
        .NUM_MN(NUM_MN),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .INIT_CRD(2),
        .HN_POS_DEPTH(4),
        .HN_SF_ENTRIES(64),
        .HN_LLC_LINES(64),
        .HN_LLC_WAYS(4),
        .HN_WRITE_TRACKER_DEPTH(2),
        .HN_READ_TRACKER_DEPTH(2),
        .HN_SNOOP_TRACKER_DEPTH(2),
        .RN_CACHE_LINES(8),
        .RN_TXN_TBL_SIZE(4),
        .FABRIC_FIFO_DEPTH(2),
        .ENABLE_PERF(0),
        .HN_ENABLE_LLC_ECC(0),
        .FABRIC_OUTPUT_FIFO_DEPTH(1),
        .ENABLE_QOS_AGING(0)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .csr_valid(csr_valid),
        .csr_write(csr_write),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_ready(csr_ready),
        .csr_rdata(csr_rdata),
        .chi_irq(chi_irq),
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_op(cpu_req_op),
        .cpu_req_size(cpu_req_size),
        .cpu_req_qos({NUM_RN*QOS_W{1'b0}}),
        .cpu_req_tag({NUM_RN*CPU_TAG_W{1'b0}}),
        .cpu_wdata({NUM_RN*DATA_WIDTH{1'b0}}),
        .cpu_wdata_line({NUM_RN*64*8{1'b0}}),
        .cpu_wstrb_line({NUM_RN*64{1'b0}}),
        .cpu_rdata(cpu_rdata),
        .cpu_resp_valid(cpu_resp_valid),
        .cpu_resp_tag(),
        .cpu_resp_line_valid(),
        .cpu_resp_line_data(),
        .cpu_resp_line_tag(),
        .l1_snoop_valid(),
        .l1_snoop_ready({NUM_RN{1'b1}}),
        .l1_snoop_invalidate(),
        .l1_snoop_addr(),
        .l1_snoop_result_valid({NUM_RN{1'b0}}),
        .l1_snoop_hit({NUM_RN{1'b0}}),
        .l1_snoop_dirty({NUM_RN{1'b0}}),
        .l1_snoop_data({NUM_RN*64*8{1'b0}}),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_araddr(axi_araddr),
        .axi_arsize(),
        .axi_arlen(axi_arlen),
        .axi_arburst(),
        .axi_rvalid(axi_rvalid),
        .axi_rready(axi_rready),
        .axi_rdata(axi_rdata),
        .axi_rresp({NUM_SN*2{1'b0}}),
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_awaddr(),
        .axi_awsize(),
        .axi_awlen(),
        .axi_awburst(),
        .axi_wvalid(axi_wvalid),
        .axi_wready(axi_wready),
        .axi_wdata(),
        .axi_wstrb(),
        .axi_wlast(axi_wlast),
        .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_bresp({NUM_SN*2{1'b0}})
    );

    // Coherence scoreboard (roadmap 4.1).
    localparam integer SB_RN_CACHE_LINES = 8;
    localparam integer SB_SF_ENTRIES     = 64;
    `include "chi_coherence_scoreboard.svh"
endmodule
