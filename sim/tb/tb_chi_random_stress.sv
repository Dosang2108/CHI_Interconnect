`timescale 1ns/1ps
`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// tb_chi_random_stress (roadmap 4.3)
//
// Every RN runs a random stream of CPU operations over a small shared line
// pool, against an AXI memory with random ready/valid backpressure and
// latency. The testbench only checks that each operation completes; data and
// protocol correctness come from the bound chi_protocol_checker and the
// included chi_coherence_scoreboard.
//
// The pool is chosen to hit replacement everywhere: 8 consecutive lines
// (both RN cache sets, 4 ways each, so the RN caches evict), plus lines at a
// 0x400 stride that share snoop-filter and LLC set 0 with the base line.
//
//   +SEED=<n>   random seed (default 1)
//   +OPS=<n>    operations per RN (default 300)
//   +BARRIER=<n> every n operations all RNs meet and stay quiet for 80
//               cycles (default 0: the streams never synchronize, and the
//               scoreboard samples state only when they happen to be idle
//               together)
//   +CG         keep CTRL.cg_enable set (use with -Defines CHI_SIM_REAL_ICG)
//   +NO_EXCL, +NO_EVICT, +NO_MKUNIQUE, +NO_WBFULL   drop that operation;
//               its share of the mix becomes ReadShared. A CPU WriteBackFull
//               is a CopyBack only when the RN owns the line; otherwise the
//               RN-F sends it as WriteUnique.
//   -Defines STRESS_NUM_RN=3   three RNs instead of two
// -----------------------------------------------------------------------------
module tb_chi_random_stress;
`ifdef STRESS_NUM_RN
    localparam integer NUM_RN     = `STRESS_NUM_RN;
`else
    localparam integer NUM_RN     = 2;
`endif
    localparam integer NUM_HN     = 1;
    localparam integer NUM_SN     = 1;
    localparam integer NUM_MN     = 1;
    localparam integer DATA_WIDTH = 32;
    localparam integer ADDR_WIDTH = 32;
    localparam integer NODE_ID_W  = 7;
    localparam integer TXN_ID_W   = 12;
    localparam integer QOS_W      = 4;
    localparam integer DBID_W     = 12;
    localparam integer CPU_TAG_W  = 2;
    localparam integer OP_TIMEOUT = 20000;
    localparam integer POOL_LINES = 12;
    localparam [ADDR_WIDTH-1:0] POOL_BASE = 32'h0002_4000;

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
    reg  [NUM_RN*CPU_TAG_W-1:0]  cpu_req_tag;
    reg  [NUM_RN*DATA_WIDTH-1:0] cpu_wdata;
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
    wire [NUM_SN*ADDR_WIDTH-1:0] axi_awaddr;
    wire [NUM_SN-1:0]            axi_wvalid;
    wire [NUM_SN-1:0]            axi_wready;
    wire [NUM_SN*DATA_WIDTH-1:0] axi_wdata;
    wire [NUM_SN*(DATA_WIDTH/8)-1:0] axi_wstrb;
    wire [NUM_SN-1:0]            axi_wlast;
    reg  [NUM_SN-1:0]            axi_bvalid;
    wire [NUM_SN-1:0]            axi_bready;

    int unsigned seed;
    int          ops_per_rn;
    int          barrier_every;
    bit          no_excl;
    bit          no_wbfull;
    bit          no_evict;
    bit          no_mkunique;
    int          ops_done [0:NUM_RN-1];
    int          op_hist  [0:15];
    int          barrier_cnt = 0;
    int          barrier_gen = 0;

    // Coherence scoreboard (roadmap 4.1). Included before the test body,
    // which reads sb_errors.
    localparam integer SB_RN_CACHE_LINES = 8;
    localparam integer SB_SF_ENTRIES     = 64;
    `include "chi_coherence_scoreboard.svh"

    always #5 clk = ~clk;

    task automatic fail(input string msg);
        test_failed = 1'b1;
        $display("[%0t] TEST FAIL tb_chi_random_stress seed=%0d %s", $time, seed, msg);
        dut.u_chi_protocol_checker.dump_open();
        $display("[%0t] HN0 state=%0d pos_used=%0d pos_out=%0b pos_lock_stall=%0b pos_full_stall=%0b sf_issued=%0b llc_evict_st=%0d llc_upd_st=%0d sf_busy=%0b llc_busy=%0b excl=%b wr_act=%b rd_act=%b snp_act=%b",
                 $time, dut.gen_hn[0].u_hn_f.state_q, dut.gen_hn[0].u_hn_f.pos_used,
                 dut.gen_hn[0].u_hn_f.pos_out_valid, dut.gen_hn[0].u_hn_f.pos_addr_lock_stall,
                 dut.gen_hn[0].u_hn_f.pos_full_stall, dut.gen_hn[0].u_hn_f.sf_lookup_issued_q,
                 dut.gen_hn[0].u_hn_f.llc_evict_state_q, dut.gen_hn[0].u_hn_f.llc_update_state_q,
                 dut.gen_hn[0].u_hn_f.sf_busy, dut.gen_hn[0].u_hn_f.llc_busy,
                 dut.gen_hn[0].u_hn_f.excl_valid_q, dut.gen_hn[0].u_hn_f.wr_tracker_active_valid_vec,
                 dut.gen_hn[0].u_hn_f.rd_tracker_active_valid_vec, dut.gen_hn[0].u_hn_f.snp_tracker_active_valid_vec);
        $display("[%0t] HN0 pf_valid=%0b pf_addr=0x%0h parsed=%0b needs_sf=%0b ftrk_idle=%0b rd_ack_v=%0b rd_llc_upd_v=%0b snp_filt_upd_v=%0b excl_fail=%0b replay_v=%0b retry_free=%0b err_rsp=%0b filt_upd_rdy=%0b llc_lk_rdy=%0b snp_alloc_rdy=%0b resp_req_rdy=%0b",
                 $time, dut.gen_hn[0].u_hn_f.front_prefetch_valid_q,
                 dut.gen_hn[0].u_hn_f.front_prefetch_flit_q[`CHI_REQ_ADDR_LSB(NODE_ID_W) +: ADDR_WIDTH],
                 dut.gen_hn[0].u_hn_f.parsed_valid, dut.gen_hn[0].u_hn_f.req_needs_sf,
                 dut.gen_hn[0].u_hn_f.filter_trackers_idle, dut.gen_hn[0].u_hn_f.rd_tracker_ack_valid,
                 dut.gen_hn[0].u_hn_f.rd_tracker_llc_update_valid, dut.gen_hn[0].u_hn_f.snp_tracker_filter_update_valid,
                 dut.gen_hn[0].u_hn_f.req_exclusive_fail, dut.gen_hn[0].u_hn_f.snp_tracker_replay_valid,
                 dut.gen_hn[0].u_hn_f.retry_slot_free, dut.gen_hn[0].u_hn_f.err_rsp_valid_q,
                 dut.gen_hn[0].u_hn_f.filter_update_ready, dut.gen_hn[0].u_hn_f.llc_lookup_ready,
                 dut.gen_hn[0].u_hn_f.snp_tracker_alloc_ready, dut.gen_hn[0].u_hn_f.resp_req_ready);
        $display("[%0t] HN0 snp_trk st0=%0d st1=%0d backinv0=%0b backinv1=%0b rd_trk st0=%0d st1=%0d",
                 $time, dut.gen_hn[0].u_hn_f.u_snoop_tracker.state_q[0], dut.gen_hn[0].u_hn_f.u_snoop_tracker.state_q[1],
                 dut.gen_hn[0].u_hn_f.u_snoop_tracker.mode_backinv_q[0], dut.gen_hn[0].u_hn_f.u_snoop_tracker.mode_backinv_q[1],
                 dut.gen_hn[0].u_hn_f.u_read_tracker.state_q[0], dut.gen_hn[0].u_hn_f.u_read_tracker.state_q[1]);
        #1;
        $finish;
    endtask

    function automatic [ADDR_WIDTH-1:0] pool_line(input int k);
        if (k < 8)
            pool_line = POOL_BASE + k * 32'h40;
        else
            pool_line = POOL_BASE + (k - 7) * 32'h400;
    endfunction

    // ------------------------------------------------------------ AXI memory
    bit [DATA_WIDTH-1:0] mem [longint];

    function automatic [DATA_WIDTH-1:0] mem_read(input [ADDR_WIDTH-1:0] a);
        longint w;
        w = longint'(a) >> 2;
        mem_read = mem.exists(w) ? mem[w] : (a ^ 32'h3C00_0000);
    endfunction

    reg                  rd_busy;
    reg [ADDR_WIDTH-1:0] rd_addr;
    reg [7:0]            rd_len;
    reg [7:0]            rd_beat;
    reg [3:0]            rd_gap;
    reg                  wr_busy;
    reg [ADDR_WIDTH-1:0] wr_addr;
    reg [7:0]            wr_beat;
    reg [3:0]            b_gap;
    reg                  wr_done;
    reg                  ar_rdy_q;
    reg                  aw_rdy_q;
    reg                  w_rdy_q;
    reg [DATA_WIDTH-1:0] wr_word;
    integer              bi;

    assign axi_arready = !rd_busy && ar_rdy_q;
    assign axi_awready = !wr_busy && !wr_done && !axi_bvalid[0] && aw_rdy_q;
    assign axi_wready  = wr_busy && w_rdy_q;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_busy    <= 1'b0;
            rd_beat    <= 8'd0;
            rd_gap     <= 4'd0;
            axi_rvalid <= 1'b0;
            axi_rdata  <= {DATA_WIDTH{1'b0}};
            wr_busy    <= 1'b0;
            wr_done    <= 1'b0;
            wr_beat    <= 8'd0;
            b_gap      <= 4'd0;
            axi_bvalid <= 1'b0;
            ar_rdy_q   <= 1'b1;
            aw_rdy_q   <= 1'b1;
            w_rdy_q    <= 1'b1;
        end else begin
            ar_rdy_q <= ($urandom_range(3) != 0);
            aw_rdy_q <= ($urandom_range(3) != 0);
            w_rdy_q  <= ($urandom_range(3) != 0);

            if (axi_arvalid[0] && axi_arready[0]) begin
                rd_busy <= 1'b1;
                rd_addr <= axi_araddr[ADDR_WIDTH-1:0];
                rd_len  <= axi_arlen[7:0];
                rd_beat <= 8'd0;
                rd_gap  <= $urandom_range(6);
            end
            if (rd_busy && !axi_rvalid[0]) begin
                if (rd_gap != 4'd0) begin
                    rd_gap <= rd_gap - 1'b1;
                end else begin
                    axi_rvalid[0] <= 1'b1;
                    axi_rdata[DATA_WIDTH-1:0] <= mem_read(rd_addr + rd_beat * 4);
                end
            end else if (axi_rvalid[0] && axi_rready[0]) begin
                axi_rvalid[0] <= 1'b0;
                if (rd_beat == rd_len) begin
                    rd_busy <= 1'b0;
                end else begin
                    rd_beat <= rd_beat + 1'b1;
                    rd_gap  <= $urandom_range(2);
                end
            end

            if (axi_awvalid[0] && axi_awready[0]) begin
                wr_busy <= 1'b1;
                wr_addr <= axi_awaddr[ADDR_WIDTH-1:0];
                wr_beat <= 8'd0;
            end
            if (axi_wvalid[0] && axi_wready[0]) begin
                wr_word = mem_read(wr_addr + wr_beat * 4);
                for (bi = 0; bi < DATA_WIDTH / 8; bi = bi + 1)
                    if (axi_wstrb[bi])
                        wr_word[bi*8 +: 8] = axi_wdata[bi*8 +: 8];
                mem[longint'(wr_addr + wr_beat * 4) >> 2] = wr_word;
                wr_beat <= wr_beat + 1'b1;
                if (axi_wlast[0]) begin
                    wr_busy <= 1'b0;
                    wr_done <= 1'b1;
                    b_gap   <= $urandom_range(8);
                end
            end
            if (wr_done && !axi_bvalid[0]) begin
                if (b_gap != 4'd0) begin
                    b_gap <= b_gap - 1'b1;
                end else begin
                    axi_bvalid[0] <= 1'b1;
                    wr_done <= 1'b0;
                end
            end
            if (axi_bvalid[0] && axi_bready[0])
                axi_bvalid[0] <= 1'b0;
        end
    end

    // ------------------------------------------------------------ CPU driver
    task automatic wait_cycles(input int n);
        repeat (n) @(posedge clk);
    endtask

    task automatic cpu_op(input int rn, input [3:0] op, input [ADDR_WIDTH-1:0] addr,
                          input [2:0] size, input [DATA_WIDTH-1:0] data,
                          input [CPU_TAG_W-1:0] tag, output [DATA_WIDTH-1:0] rdata);
        int t;
        @(negedge clk);
        cpu_req_addr[rn*ADDR_WIDTH +: ADDR_WIDTH] = addr;
        cpu_req_op[rn*4 +: 4]                   = op;
        cpu_req_size[rn*3 +: 3]                 = size;
        cpu_req_tag[rn*CPU_TAG_W +: CPU_TAG_W]  = tag;
        cpu_wdata[rn*DATA_WIDTH +: DATA_WIDTH]  = data;
        cpu_req_valid[rn] = 1'b1;
        t = 0;
        do begin
            @(posedge clk);
            t++;
        end while (!cpu_req_ready[rn] && (t < OP_TIMEOUT));
        if (!cpu_req_ready[rn])
            fail($sformatf("RN%0d op %0d addr 0x%0h not accepted", rn, op, addr));
        @(negedge clk);
        cpu_req_valid[rn] = 1'b0;
        t = 0;
        while (!cpu_resp_valid[rn] && (t < OP_TIMEOUT)) begin
            @(posedge clk);
            t++;
        end
        if (!cpu_resp_valid[rn])
            fail($sformatf("RN%0d op %0d addr 0x%0h got no response in %0d cycles",
                           rn, op, addr, OP_TIMEOUT));
        rdata = cpu_rdata[rn*DATA_WIDTH +: DATA_WIDTH];
        op_hist[op]++;
    endtask

    // +BARRIER only. All RN streams meet here, then stay quiet long enough
    // for the interconnect to drain, so the scoreboard samples an idle state.
    task automatic barrier;
        int gen;
        gen = barrier_gen;
        barrier_cnt++;
        if (barrier_cnt == NUM_RN) begin
            barrier_cnt = 0;
            barrier_gen++;
        end else begin
            wait (barrier_gen != gen);
        end
        wait_cycles(80);
    endtask

    task automatic rn_stream(input int rn);
        int                  i;
        int                  pick;
        bit [ADDR_WIDTH-1:0] line;
        bit [ADDR_WIDTH-1:0] addr;
        bit [DATA_WIDTH-1:0] rd;
        bit [CPU_TAG_W-1:0]  tag;
        tag = 0;
        for (i = 0; i < ops_per_rn; i++) begin
            line = pool_line($urandom_range(POOL_LINES - 1));
            addr = line + ($urandom_range(15) * 4);
            pick = $urandom_range(99);
            tag  = tag + 1;
            if (pick < 30)
                cpu_op(rn, `CHI_CPU_OP_RD_SHARED, line, 3'd6, 0, tag, rd);
            else if (pick < 42)
                cpu_op(rn, `CHI_CPU_OP_RD_UNIQUE, line, 3'd6, 0, tag, rd);
            else if (pick < 62)
                cpu_op(rn, `CHI_CPU_OP_WR_UNIQUE, addr, 3'd2, $urandom, tag, rd);
            else if ((pick < 72) && !no_wbfull)
                cpu_op(rn, `CHI_CPU_OP_WB_FULL, line, 3'd6, $urandom, tag, rd);
            else if ((pick >= 72) && (pick < 80) && !no_evict)
                cpu_op(rn, `CHI_CPU_OP_EVICT, line, 3'd6, 0, tag, rd);
            else if ((pick >= 80) && (pick < 85) && !no_mkunique)
                cpu_op(rn, `CHI_CPU_OP_MK_UNIQUE, line, 3'd6, 0, tag, rd);
            else if ((pick >= 85) && !no_excl) begin
                cpu_op(rn, `CHI_CPU_OP_LDREX, addr, 3'd2, 0, tag, rd);
                wait_cycles($urandom_range(4));
                tag = tag + 1;
                cpu_op(rn, `CHI_CPU_OP_STREX, addr, 3'd2, $urandom, tag, rd);
            end else begin
                cpu_op(rn, `CHI_CPU_OP_RD_SHARED, line, 3'd6, 0, tag, rd);
            end
            ops_done[rn] = i + 1;
            if ((barrier_every > 0) && ((i % barrier_every) == barrier_every - 1))
                barrier();
            // Mostly short gaps; now and then a long one so the interconnect
            // drains and the scoreboard samples an idle state.
            if ($urandom_range(9) == 0)
                wait_cycles(40 + $urandom_range(40));
            else
                wait_cycles($urandom_range(6));
        end
    endtask

    task automatic csr_write64(input [7:0] a, input [63:0] d);
        @(negedge clk);
        csr_valid = 1'b1;
        csr_write = 1'b1;
        csr_addr  = a;
        csr_wdata = d;
        @(posedge clk);
        @(negedge clk);
        csr_valid = 1'b0;
        csr_write = 1'b0;
    endtask

    initial begin
        int r;
        int idle;
        clk = 1'b0;
        rstn = 1'b0;
        test_failed = 1'b0;
        csr_valid = 1'b0;
        csr_write = 1'b0;
        csr_addr = 8'h00;
        csr_wdata = 64'd0;
        cpu_req_valid = '0;
        cpu_req_addr  = '0;
        cpu_req_op    = '0;
        cpu_req_size  = '0;
        cpu_req_tag   = '0;
        cpu_wdata     = '0;
        for (r = 0; r < 16; r++) op_hist[r] = 0;

        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("OPS=%d", ops_per_rn)) ops_per_rn = 300;
        if (!$value$plusargs("BARRIER=%d", barrier_every)) barrier_every = 0;
        no_excl     = $test$plusargs("NO_EXCL");
        // Off by default: a CPU WriteBackFull is only legal from the line's
        // owner, and random stimulus cannot keep that true against snoops.
        no_wbfull   = $test$plusargs("NO_WBFULL");
        no_evict    = $test$plusargs("NO_EVICT");
        no_mkunique = $test$plusargs("NO_MKUNIQUE");
        r = $urandom(seed);  // seeds this thread; forked streams inherit it
        $display("[%0t] STRESS START seed=%0d rns=%0d ops_per_rn=%0d cg=%0d excl=%0d barrier=%0d",
                 $time, seed, NUM_RN, ops_per_rn, $test$plusargs("CG"), !no_excl, barrier_every);

        wait_cycles(10);
        rstn = 1'b1;
        wait_cycles(10);
        if ($test$plusargs("CG"))
            csr_write64(8'h00, 64'h0000_0006);

        for (r = 0; r < NUM_RN; r++) begin
            automatic int rr = r;
            ops_done[rr] = 0;
            fork
                rn_stream(rr);
            join_none
        end
        wait fork;

        idle = 0;
        while (idle < 50) begin
            @(posedge clk);
            idle = dut.chi_busy ? 0 : idle + 1;
        end
        wait_cycles(20);

        $display("[%0t] STRESS OPS rdshared=%0d rdunique=%0d wrunique=%0d wbfull=%0d evict=%0d mkunique=%0d ldrex=%0d strex=%0d",
                 $time, op_hist[`CHI_CPU_OP_RD_SHARED], op_hist[`CHI_CPU_OP_RD_UNIQUE],
                 op_hist[`CHI_CPU_OP_WR_UNIQUE], op_hist[`CHI_CPU_OP_WB_FULL],
                 op_hist[`CHI_CPU_OP_EVICT], op_hist[`CHI_CPU_OP_MK_UNIQUE],
                 op_hist[`CHI_CPU_OP_LDREX], op_hist[`CHI_CPU_OP_STREX]);
        if ((sb_errors != 0) || (dut.u_chi_protocol_checker.errors != 0))
            fail($sformatf("scoreboard violations=%0d protocol violations=%0d",
                           sb_errors, dut.u_chi_protocol_checker.errors));
        if (!test_failed)
            $display("[%0t] TEST PASS: tb_chi_random_stress seed=%0d rns=%0d ops=%0d",
                     $time, seed, NUM_RN, NUM_RN * ops_per_rn);
        $finish;
    end

    initial begin
        #50000000;
        fail($sformatf("global watchdog: progress %0d/%0d ops on RN0", ops_done[0], ops_per_rn));
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
        .cpu_req_tag(cpu_req_tag),
        .cpu_wdata(cpu_wdata),
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
        .axi_awaddr(axi_awaddr),
        .axi_awsize(),
        .axi_awlen(),
        .axi_awburst(),
        .axi_wvalid(axi_wvalid),
        .axi_wready(axi_wready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wlast(axi_wlast),
        .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_bresp({NUM_SN*2{1'b0}})
    );

endmodule
