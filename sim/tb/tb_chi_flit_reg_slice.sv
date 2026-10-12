`timescale 1ns/1ps

// Unit test for chi_flit_reg_slice, the fabric output register (roadmap O1).
// The slice must
//   - deliver every flit once, in order, unchanged,
//   - hold out_valid and out_data steady while the sink stalls,
//   - move one flit per cycle when source and sink are both ready,
//   - take exactly two flits while the sink stalls, then drop in_ready,
//   - keep in_ready independent of out_ready in the same cycle, so it
//     cannot close a ready loop through the fabric,
//   - be empty after clear.
module tb_chi_flit_reg_slice;
    localparam integer W = 24;

    reg          clk = 1'b0;
    reg          rstn = 1'b0;
    reg          clear = 1'b0;
    reg          in_valid = 1'b0;
    reg  [W-1:0] in_data = {W{1'b0}};
    reg          out_ready = 1'b0;
    wire         in_ready;
    wire         out_valid;
    wire [W-1:0] out_data;

    always #5 clk = ~clk;

    chi_flit_reg_slice #(
        .WIDTH(W)
    ) dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data(in_data),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data(out_data)
    );

    integer fails = 0;
    integer n_in = 0;
    integer n_out = 0;
    reg [W-1:0] exp_q [$];

    task automatic fail(input string msg);
        fails = fails + 1;
        $display("FAIL: %s (t=%0t)", msg, $time);
    endtask

    // xorshift32
    reg [31:0] rng = 32'h1357_9bdf;
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

    // Source and sink, driven on the falling edge. The source holds a flit
    // until the slice takes it.
    reg     src_en = 1'b0;
    reg     sink_en = 1'b0;
    integer p_valid = 100;
    integer p_ready = 100;
    reg     last_acc = 1'b0;
    integer seq = 1;

    always @(negedge clk) begin
        rng = xs(rng);
        out_ready <= sink_en && ((rng[15:0] % 100) < p_ready);
        if (!in_valid || last_acc) begin
            if (src_en && ((rng[31:16] % 100) < p_valid)) begin
                in_valid <= 1'b1;
                in_data <= {seq[11:0], rng[11:0]};
                seq = seq + 1;
            end else begin
                in_valid <= 1'b0;
            end
        end
    end

    // Scoreboard
    reg         prev_stall = 1'b0;
    reg [W-1:0] prev_data = {W{1'b0}};
    reg [W-1:0] exp_flit;

    always @(posedge clk) begin
        last_acc = 1'b0;
        if (!rstn || clear) begin
            prev_stall <= 1'b0;
        end else begin
            if (in_valid && in_ready) begin
                exp_q.push_back(in_data);
                n_in = n_in + 1;
                last_acc = 1'b1;
            end
            if (prev_stall && !out_valid)
                fail("out_valid dropped while the sink stalled");
            if (prev_stall && out_valid && (out_data !== prev_data))
                fail("out_data changed while the sink stalled");
            if (out_valid && out_ready) begin
                if (exp_q.size() == 0) begin
                    fail("a flit came out that never went in");
                end else begin
                    exp_flit = exp_q.pop_front();
                    if (exp_flit !== out_data)
                        fail($sformatf("flit out of order or changed: got 0x%0h, expected 0x%0h",
                                       out_data, exp_flit));
                end
                n_out = n_out + 1;
            end
            prev_stall <= out_valid && !out_ready;
            prev_data <= out_data;
        end
    end

    task automatic run_cycles(input integer n);
        repeat (n) @(posedge clk);
    endtask

    // Stop the source, open the sink and wait until the slice is empty.
    task automatic drain;
        begin
            src_en = 1'b0;
            sink_en = 1'b1;
            p_ready = 100;
            run_cycles(8);
            if (in_valid || out_valid || (exp_q.size() != 0))
                fail("slice did not drain");
        end
    endtask

    // in_ready must not follow out_ready within a cycle.
    task automatic check_ready_independent(input string where);
        reg r0;
        reg r1;
        reg saved;
        begin
            @(negedge clk);
            #1;
            saved = out_ready;
            out_ready = 1'b0;
            #1 r0 = in_ready;
            out_ready = 1'b1;
            #1 r1 = in_ready;
            out_ready = saved;
            if (r0 !== r1)
                fail({"in_ready depends on out_ready in the same cycle, ", where});
        end
    endtask

    integer n_in_before;
    integer n_out_before;
    integer full_rate_out;
    integer mix;

    initial begin
        run_cycles(4);
        rstn = 1'b1;
        run_cycles(2);

        // T1: source and sink always ready.
        src_en = 1'b1;
        sink_en = 1'b1;
        p_valid = 100;
        p_ready = 100;
        run_cycles(8);
        n_out_before = n_out;
        run_cycles(200);
        full_rate_out = n_out - n_out_before;
        if (full_rate_out < 199)
            fail($sformatf("full-rate throughput is %0d flits in 200 cycles, expected one per cycle",
                           full_rate_out));
        drain();
        check_ready_independent("empty");

        // T2: the sink stalls. Two flits fit, the third waits at the source.
        sink_en = 1'b0;
        run_cycles(2);
        n_in_before = n_in;
        src_en = 1'b1;
        p_valid = 100;
        run_cycles(2);
        check_ready_independent("one flit held");
        run_cycles(10);
        if ((n_in - n_in_before) != 2)
            fail($sformatf("took %0d flits while the sink stalled, expected 2",
                           n_in - n_in_before));
        if (in_ready !== 1'b0)
            fail("in_ready still high with two flits held");
        if (out_valid !== 1'b1)
            fail("out_valid low with flits held");
        check_ready_independent("two flits held");
        drain();

        // T3: random source and sink rates.
        for (mix = 0; mix < 4; mix = mix + 1) begin
            case (mix)
                0: begin p_valid = 30;  p_ready = 100; end
                1: begin p_valid = 100; p_ready = 30;  end
                2: begin p_valid = 50;  p_ready = 50;  end
                default: begin p_valid = 85; p_ready = 85; end
            endcase
            src_en = 1'b1;
            sink_en = 1'b1;
            run_cycles(2000);
            drain();
        end
        if (n_in != n_out)
            fail($sformatf("%0d flits went in, %0d came out", n_in, n_out));

        // T4: clear empties the slice.
        sink_en = 1'b0;
        src_en = 1'b1;
        p_valid = 100;
        run_cycles(6);
        src_en = 1'b0;
        @(negedge clk);
        in_valid = 1'b0;
        clear = 1'b1;
        @(negedge clk);
        clear = 1'b0;
        exp_q.delete();
        #1;
        if (out_valid !== 1'b0)
            fail("out_valid high after clear");
        if (in_ready !== 1'b1)
            fail("in_ready low after clear");
        src_en = 1'b1;
        sink_en = 1'b1;
        p_ready = 100;
        run_cycles(50);
        drain();

        if (fails == 0)
            $display("PASS: tb_chi_flit_reg_slice, %0d flits, full rate %0d flits in 200 cycles",
                     n_out, full_rate_out);
        else
            $display("FAIL: tb_chi_flit_reg_slice, %0d errors", fails);
        $finish;
    end
endmodule
