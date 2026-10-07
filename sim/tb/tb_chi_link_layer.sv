`timescale 1ns/1ps
`include "chi_defs.vh"

// Link-layer unit test (roadmap 3.5). One chi_link_tx drives one
// chi_link_rx over a FLITPEND/FLITV/FLIT/LCRDV link, as across a CHI
// channel (IHI0050H B14.2.1). The source offers flits at random, the sink
// pops at random, and the link wires get extra flit latency (LAT pipeline
// stages) and random LCRDV delay (credits parked in the testbench and
// released later). Each case checks:
//   - every flit arrives once, in order, unchanged (no loss, no duplicate),
//   - FLITV only with an L-Credit, not one received the same cycle
//     (chi_link_credit_checker plus the TX underflow monitor),
//   - FLITPEND was high the cycle before every FLITV,
//   - the RX buffer never overflows,
//   - credits are conserved: TX credits + credits parked on the wire +
//     flits on the wire + RX buffer occupancy + RX credits not yet granted
//     always equals the RX buffer depth,
//   - after the traffic drains, all credits are back at the TX.
// The link has its LINKACTIVE handshake (chi_link_active_tx/_rx, B14.5.1).
// With P_ACT < 100 the testbench asks for the link at random, so it goes
// through STOP -> ACTIVATE -> RUN -> DEACTIVATE over and over with traffic
// waiting. Then also:
//   - no flit and no credit in STOP or ACTIVATE (SPEC_LINK_ACTIVE),
//   - in STOP the TX holds no credit and nothing is on the wire: every
//     credit went back as an LCrdReturn flit, which never reaches the sink.
// A full-rate case reports throughput per depth so the credit round trip
// can be compared against the buffer depth. FT=1 cases use the fall-through
// receive buffer of the fabric -> node links.
module tb_chi_link_layer_case #(
    parameter integer DEPTH   = 2,
    parameter integer LAT     = 0,     // extra flit pipeline stages on the wire
    parameter integer SEED    = 1,
    parameter integer P_VALID = 100,   // % of cycles the source offers a flit
    parameter integer P_READY = 100,   // % of cycles the sink pops
    parameter integer P_CRD   = 100,   // % of cycles a parked credit is released
    parameter integer P_ACT   = 100,   // % of redraws that ask for the link (100: always up)
    parameter integer NFLITS  = 400,
    parameter integer FT      = 0,     // chi_link_rx FALLTHROUGH
    parameter         NAME    = "case"
)(
    input          clk,
    input          rstn,
    output reg     done,
    output integer fails
);
    // Flit: {sequence number, opcode, random}. Opcode 0 is LCrdReturn, so
    // the source always sends a non-zero one.
    localparam integer FLIT_W  = 44;
    localparam integer OPC_LSB = 24;
    localparam integer OPC_W   = 4;

    // xorshift32, so each case has its own reproducible stream.
    reg [31:0] rng;
    function automatic [31:0] xs(input [31:0] s);
        reg [31:0] x;
        begin
            x = s;
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            xs = x;
        end
    endfunction

    // Source
    reg               src_valid;
    reg  [FLIT_W-1:0] src_flit;
    wire              src_ready;
    integer           n_sent;

    // TX -> wire
    wire              tx_flitpend;
    wire              tx_flitv;
    wire [FLIT_W-1:0] tx_flit;
    wire              tx_lcrdv;
    wire [3:0]        tx_credits;

    // wire -> RX
    wire              rx_flitv;
    wire [FLIT_W-1:0] rx_flit;
    wire              rx_lcrdv;
    wire              rx_out_valid;
    wire [FLIT_W-1:0] rx_out_flit;
    reg               sink_ready;
    wire              rx_overflow;

    // Link activation
    reg               want;
    reg               finishing;
    integer           act_hold;
    wire              lareq;
    wire              laack;
    wire              link_run;
    wire              link_deact;
    wire              rx_grant_en;
    wire              rx_home;
    reg               prev_laack;
    integer           n_stop;

    chi_link_active_tx u_act_tx (
        .clk(clk),
        .rstn(rstn),
        .want(want),
        .linkactivereq(lareq),
        .linkactiveack(laack),
        .run(link_run),
        .deact(link_deact)
    );

    chi_link_active_rx u_act_rx (
        .clk(clk),
        .rstn(rstn),
        .linkactivereq(lareq),
        .linkactiveack(laack),
        .credits_home(rx_home),
        .grant_en(rx_grant_en)
    );

    chi_link_tx #(
        .FLIT_W(FLIT_W)
    ) u_tx (
        .clk(clk),
        .rstn(rstn),
        .link_run(link_run),
        .link_deact(link_deact),
        .in_valid(src_valid),
        .in_ready(src_ready),
        .in_flit(src_flit),
        .pending(),
        .flitpend(tx_flitpend),
        .flitv(tx_flitv),
        .flit(tx_flit),
        .lcrdv(tx_lcrdv),
        .credit_count(tx_credits)
    );

    // Flit pipeline on the wire.
    reg              pipe_v [0:LAT];
    reg [FLIT_W-1:0] pipe_f [0:LAT];
    integer          k;
    always @(*) begin
        pipe_v[0] = tx_flitv;
        pipe_f[0] = tx_flit;
    end
    always @(posedge clk or negedge rstn) begin
        for (k = 1; k <= LAT; k = k + 1) begin
            if (!rstn) begin
                pipe_v[k] <= 1'b0;
                pipe_f[k] <= {FLIT_W{1'b0}};
            end else begin
                pipe_v[k] <= pipe_v[k-1];
                pipe_f[k] <= pipe_f[k-1];
            end
        end
    end
    assign rx_flitv = pipe_v[LAT];
    assign rx_flit  = pipe_f[LAT];

    chi_link_rx #(
        .FLIT_W(FLIT_W),
        .DEPTH(DEPTH),
        .FALLTHROUGH(FT),
        .OPC_LSB(OPC_LSB),
        .OPC_W(OPC_W)
    ) u_rx (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .grant_en(rx_grant_en),
        .flitv(rx_flitv),
        .flit(rx_flit),
        .lcrdv(rx_lcrdv),
        .home(rx_home),
        .out_valid(rx_out_valid),
        .out_ready(sink_ready),
        .out_flit(rx_out_flit),
        .overflow(rx_overflow)
    );

    // LCRDV delay: credits the RX grants are parked and released at random.
    // P_CRD = 100 wires LCRDV straight through, so the full-rate cases
    // measure the RTL credit round trip alone.
    integer parked;
    reg     release_crd;
    assign tx_lcrdv = (P_CRD >= 100) ? rx_lcrdv : release_crd;

    chi_link_credit_checker #(
        .N(1),
        .INIT_CREDIT(0),
        .MAX_CREDIT(DEPTH),
        .LINK(NAME)
    ) u_chk (
        .clk(clk),
        .rstn(rstn),
        .flitv(tx_flitv),
        .flitpend(tx_flitpend),
        .lcrdv(tx_lcrdv),
        .linkactivereq(lareq),
        .linkactiveack(laack)
    );

    // Scoreboard
    reg [FLIT_W-1:0] expq [$];
    integer n_recv;
    integer cyc;
    integer first_cyc;
    integer last_cyc;
    reg     prev_flitpend;
    integer wire_flits;

    task automatic fail(input string msg);
        fails = fails + 1;
        if (fails <= 10)
            $display("[%0t] LINK_TB ERROR: %s %s", $time, NAME, msg);
    endtask

    initial begin
        rng       = 32'h1234_5678 ^ (SEED * 32'h9E37_79B9);
        if (rng == 0) rng = 32'h1;
        done      = 1'b0;
        fails     = 0;
        n_sent    = 0;
        n_recv    = 0;
        cyc       = 0;
        first_cyc = -1;
        last_cyc  = 0;
        parked    = 0;
        finishing = 1'b0;
        act_hold  = 0;
        n_stop    = 0;
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            src_valid     <= 1'b0;
            src_flit      <= {FLIT_W{1'b0}};
            sink_ready    <= 1'b0;
            release_crd   <= 1'b0;
            prev_flitpend <= 1'b0;
            want          <= 1'b0;
            prev_laack    <= 1'b0;
        end else begin
            cyc = cyc + 1;

            // Ask for the link: always, or redrawn every 1..30 cycles.
            if ((P_ACT >= 100) || finishing) begin
                want <= 1'b1;
            end else if (act_hold == 0) begin
                rng = xs(rng);
                want <= ((rng % 100) < P_ACT);
                rng = xs(rng);
                act_hold = 1 + (rng % 30);
            end else begin
                act_hold = act_hold - 1;
            end
            if (prev_laack && !laack)
                n_stop = n_stop + 1;
            prev_laack <= laack;

            // FLITV needs FLITPEND the cycle before (B14.4).
            if (tx_flitv && !prev_flitpend)
                fail($sformatf("FLITV at cycle %0d without FLITPEND the cycle before", cyc));
            prev_flitpend <= tx_flitpend;

            if (rx_overflow)
                fail($sformatf("RX buffer overflow at cycle %0d", cyc));

            // Source handshake (internal valid/ready into the TX).
            if (src_valid && src_ready) begin
                expq.push_back(src_flit);
                n_sent = n_sent + 1;
            end
            rng = xs(rng);
            if (!src_valid || src_ready) begin
                if ((n_sent < NFLITS) && ((rng % 100) < P_VALID)) begin
                    src_valid <= 1'b1;
                    src_flit  <= {n_sent[15:0], 4'hA, rng[23:0]};
                end else begin
                    src_valid <= 1'b0;
                end
            end

            // Sink
            if (rx_out_valid && sink_ready) begin
                if (expq.size() == 0) begin
                    fail($sformatf("flit 0x%0h popped with nothing outstanding (duplicate)", rx_out_flit));
                end else begin
                    if (rx_out_flit !== expq[0])
                        fail($sformatf("flit %0d: got 0x%0h expected 0x%0h (order/loss)",
                                       n_recv, rx_out_flit, expq[0]));
                    void'(expq.pop_front());
                end
                n_recv = n_recv + 1;
                if (first_cyc < 0) first_cyc = cyc;
                last_cyc = cyc;
            end
            rng = xs(rng);
            sink_ready <= ((rng % 100) < P_READY);

            // LCRDV wire delay
            if (P_CRD < 100) begin
                if (release_crd)
                    parked = parked - 1;
                if (rx_lcrdv)
                    parked = parked + 1;
                rng = xs(rng);
                release_crd <= (parked > 0) && ((rng % 100) < P_CRD);
            end
        end
    end

    // Credit conservation, sampled after every edge's updates settle.
    always @(negedge clk) begin
        if (rstn) begin
            wire_flits = 0;
            for (int j = 1; j <= LAT; j = j + 1)
                if (pipe_v[j]) wire_flits = wire_flits + 1;
            if (tx_credits + parked + wire_flits + u_rx.used_count + u_rx.u_lcrd.owed_q != DEPTH)
                fail($sformatf("credits not conserved at cycle %0d: tx=%0d parked=%0d wire=%0d rx_used=%0d rx_owed=%0d depth=%0d",
                               cyc, tx_credits, parked, wire_flits, u_rx.used_count,
                               u_rx.u_lcrd.owed_q, DEPTH));
            if (!lareq && !laack && ((tx_credits != 0) || (parked != 0) || (wire_flits != 0)))
                fail($sformatf("link in STOP at cycle %0d with tx credits=%0d parked=%0d wire flits=%0d",
                               cyc, tx_credits, parked, wire_flits));
        end
    end

    // Completion: all flits received, then every credit must return to TX.
    initial begin
        wait (rstn === 1'b1);
        wait (n_recv == NFLITS);
        // Bring the link up for good and let the credits settle.
        finishing = 1'b1;
        repeat (400) @(posedge clk);
        if ((P_ACT < 100) && (n_stop < 3))
            fail($sformatf("link was deactivated only %0d times", n_stop));
        if (expq.size() != 0)
            fail($sformatf("%0d flits never delivered", expq.size()));
        if (tx_credits != DEPTH)
            fail($sformatf("TX holds %0d credits after drain, expected %0d", tx_credits, DEPTH));
        if (u_chk.enabled && (u_chk.errors != 0))
            fail($sformatf("credit checker reported %0d violations", u_chk.errors));
        if (u_chk.enabled && (u_chk.act_errors != 0))
            fail($sformatf("link activation checker reported %0d violations", u_chk.act_errors));
        $display("LINK_TB CASE %s depth=%0d lat=%0d ft=%0d pv=%0d pr=%0d pc=%0d pa=%0d flits=%0d cycles=%0d rate=%0.3f stops=%0d fails=%0d",
                 NAME, DEPTH, LAT, FT, P_VALID, P_READY, P_CRD, P_ACT, n_recv, last_cyc - first_cyc + 1,
                 real'(n_recv) / real'(last_cyc - first_cyc + 1), n_stop, fails);
        done = 1'b1;
    end
endmodule

module tb_chi_link_layer;
    reg clk;
    reg rstn;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    localparam integer NC = 21;
    wire    [NC-1:0] done;
    integer          fails [NC];

    // Full rate: throughput versus credit round trip.
    tb_chi_link_layer_case #(.DEPTH(1),  .LAT(0), .SEED(1),  .NAME("rate_d1"))  c0 (clk, rstn, done[0], fails[0]);
    tb_chi_link_layer_case #(.DEPTH(2),  .LAT(0), .SEED(2),  .NAME("rate_d2"))  c1 (clk, rstn, done[1], fails[1]);
    tb_chi_link_layer_case #(.DEPTH(4),  .LAT(0), .SEED(3),  .NAME("rate_d4"))  c2 (clk, rstn, done[2], fails[2]);
    tb_chi_link_layer_case #(.DEPTH(8),  .LAT(2), .SEED(4),  .NAME("rate_d8_lat2")) c3 (clk, rstn, done[3], fails[3]);
    tb_chi_link_layer_case #(.DEPTH(15), .LAT(0), .SEED(5),  .NAME("rate_d15")) c4 (clk, rstn, done[4], fails[4]);
    // Random source, sink and credit delay.
    tb_chi_link_layer_case #(.DEPTH(1),  .LAT(1), .SEED(11), .P_VALID(70), .P_READY(40), .P_CRD(50), .NAME("rand_d1"))  c5 (clk, rstn, done[5], fails[5]);
    tb_chi_link_layer_case #(.DEPTH(2),  .LAT(0), .SEED(12), .P_VALID(90), .P_READY(30), .P_CRD(60), .NAME("rand_d2"))  c6 (clk, rstn, done[6], fails[6]);
    tb_chi_link_layer_case #(.DEPTH(2),  .LAT(2), .SEED(13), .P_VALID(50), .P_READY(90), .P_CRD(30), .NAME("rand_d2_lat2")) c7 (clk, rstn, done[7], fails[7]);
    tb_chi_link_layer_case #(.DEPTH(4),  .LAT(1), .SEED(14), .P_VALID(80), .P_READY(50), .P_CRD(80), .NAME("rand_d4"))  c8 (clk, rstn, done[8], fails[8]);
    tb_chi_link_layer_case #(.DEPTH(15), .LAT(3), .SEED(15), .P_VALID(95), .P_READY(20), .P_CRD(40), .NAME("rand_d15")) c9 (clk, rstn, done[9], fails[9]);
    // Fall-through receive buffer (chi_top's fabric -> node links).
    tb_chi_link_layer_case #(.DEPTH(1),  .LAT(0), .SEED(21), .FT(1), .NAME("ft_rate_d1")) c10 (clk, rstn, done[10], fails[10]);
    tb_chi_link_layer_case #(.DEPTH(2),  .LAT(0), .SEED(22), .FT(1), .NAME("ft_rate_d2")) c11 (clk, rstn, done[11], fails[11]);
    tb_chi_link_layer_case #(.DEPTH(2),  .LAT(1), .SEED(23), .FT(1), .P_VALID(90), .P_READY(30), .P_CRD(60), .NAME("ft_rand_d2"))  c12 (clk, rstn, done[12], fails[12]);
    tb_chi_link_layer_case #(.DEPTH(4),  .LAT(0), .SEED(24), .FT(1), .P_VALID(80), .P_READY(70), .P_CRD(90), .NAME("ft_rand_d4"))  c13 (clk, rstn, done[13], fails[13]);
    tb_chi_link_layer_case #(.DEPTH(8),  .LAT(2), .SEED(25), .FT(1), .P_VALID(95), .P_READY(15), .P_CRD(40), .NAME("ft_rand_d8")) c14 (clk, rstn, done[14], fails[14]);
    // Random activation and deactivation with traffic waiting (3.3).
    tb_chi_link_layer_case #(.DEPTH(1),  .LAT(0), .SEED(31), .P_ACT(60), .NAME("act_d1")) c15 (clk, rstn, done[15], fails[15]);
    tb_chi_link_layer_case #(.DEPTH(2),  .LAT(0), .SEED(32), .P_VALID(90), .P_READY(50), .P_ACT(50), .NAME("act_d2")) c16 (clk, rstn, done[16], fails[16]);
    tb_chi_link_layer_case #(.DEPTH(4),  .LAT(1), .SEED(33), .P_VALID(80), .P_READY(60), .P_CRD(60), .P_ACT(70), .NAME("act_d4_lat1")) c17 (clk, rstn, done[17], fails[17]);
    tb_chi_link_layer_case #(.DEPTH(15), .LAT(3), .SEED(34), .P_VALID(95), .P_READY(20), .P_CRD(40), .P_ACT(60), .NAME("act_d15_lat3")) c18 (clk, rstn, done[18], fails[18]);
    tb_chi_link_layer_case #(.DEPTH(2),  .LAT(0), .SEED(35), .FT(1), .P_ACT(50), .NAME("ft_act_d2")) c19 (clk, rstn, done[19], fails[19]);
    tb_chi_link_layer_case #(.DEPTH(8),  .LAT(2), .SEED(36), .FT(1), .P_VALID(90), .P_READY(40), .P_CRD(40), .P_ACT(70), .NAME("ft_act_d8_lat2")) c20 (clk, rstn, done[20], fails[20]);

    integer total;
    integer i;

    initial begin
        rstn = 1'b0;
        repeat (5) @(posedge clk);
        rstn = 1'b1;
        fork
            wait (&done);
            begin
                repeat (200000) @(posedge clk);
                $display("LINK_TB ERROR: timeout, done=%b", done);
            end
        join_any
        total = 0;
        for (i = 0; i < NC; i = i + 1)
            total = total + fails[i];
        if (&done && total == 0)
            $display("LINK_TB PASS tb_chi_link_layer cases=%0d", NC);
        else
            $display("LINK_TB ERROR: tb_chi_link_layer FAIL fails=%0d done=%b", total, done);
        $finish;
    end
endmodule
