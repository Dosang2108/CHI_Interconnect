// CHI coherence scoreboard (roadmap 4.1), simulation only.
//
// `include this file inside a testbench module whose chi_top instance is
// named `dut` and uses the internal RN caches (USE_EXTERNAL_L1_SNOOP=0).
// The including module must provide clk, rstn, NUM_RN, NUM_HN, ADDR_WIDTH,
// DATA_WIDTH, and, before the include:
//     localparam integer SB_RN_CACHE_LINES = <chi_top RN_CACHE_LINES>;
//     localparam integer SB_SF_ENTRIES     = <chi_top HN_SF_ENTRIES>;
//
// Two independent checks:
//
// 1. State invariants, sampled whenever nothing has been in flight for
//    SB_IDLE_CYCLES: no CPU request, no open transaction or snoop in the
//    protocol checker, and HN, SN, fabric and the RN engines idle (an
//    exclusive reservation alone does not count as activity):
//      SB_SWMR        an RN in UC/UD is the only RN holding the line, and at
//                     most one RN holds it in SD
//      SB_SF_SUPERSET every line an RN holds is tracked by a snoop filter
//                     with that RN's sharer bit set
//
// 2. Data, at the CPU interface of every RN, against a golden byte memory:
//    a write (WriteBackFull, WriteUnique, successful STREX) updates the
//    golden copy when its CPU response returns; a read line response must
//    match every known golden byte. Unknown bytes are learnt from the first
//    unambiguous read. A read that overlaps a write to the same line (still
//    pending when the read starts, or completing before the read returns)
//    is not checked, because either value is legal. Two writes to the same
//    line that overlap in time may be ordered either way by the home, so a
//    byte that both write becomes unknown instead of taking the value of
//    whichever response came last.
//
// Testbenches that change memory, the LLC or caches behind the
// interconnect's back must call sb_forget_line(addr) for each line. A reset
// forgets everything. +CHI_SB_OFF disables the scoreboard, +CHI_SB_NO_DATA
// only the data check. Violations print "CHI_SB ERROR:".

localparam integer SB_IDLE_CYCLES = 8;
localparam integer SB_TAG_W    = 2;
localparam integer SB_RN_WAYS  = 4;
localparam integer SB_RN_SETS  = SB_RN_CACHE_LINES / SB_RN_WAYS;
localparam integer SB_RN_SET_W = (SB_RN_SETS <= 2) ? 1 : $clog2(SB_RN_SETS);
localparam integer SB_RN_TAG_W = ADDR_WIDTH - SB_RN_SET_W - 6;
localparam integer SB_SF_WAYS  = 4;
localparam integer SB_SF_SETS  = SB_SF_ENTRIES / SB_SF_WAYS;
localparam integer SB_SF_SET_W = (SB_SF_SETS <= 2) ? 1 : $clog2(SB_SF_SETS);
localparam integer SB_SF_TAG_W = ADDR_WIDTH - SB_SF_SET_W - 6;

reg                  sb_enabled;
reg                  sb_data_enabled;
integer              sb_errors = 0;
integer              sb_state_checks = 0;
integer              sb_reads_checked = 0;
integer              sb_reads_skipped = 0;
integer              sb_writes_committed = 0;
integer              sb_idle_cnt = 0;
reg                  sb_idle_checked;
reg                  sb_snap;
reg                  sb_eval;
// +TRACE_LINE=<hex addr> (shared with the protocol checker): print CPU
// requests and responses on that line.
bit                  sb_trace_on;
bit [ADDR_WIDTH-1:0] sb_trace_addr;


initial begin
    sb_enabled      = !$test$plusargs("CHI_SB_OFF");
    sb_data_enabled = sb_enabled && !$test$plusargs("CHI_SB_NO_DATA");
    sb_trace_on = $value$plusargs("TRACE_LINE=%h", sb_trace_addr);
    sb_idle_checked = 1'b0;
    sb_snap         = 1'b0;
    sb_eval         = 1'b0;
end

task automatic sb_err(input string rule, input string msg);
    sb_errors = sb_errors + 1;
    if (sb_errors <= 40)
        $display("[%0t] CHI_SB ERROR: %s %s", $time, rule, msg);
    else if (sb_errors == 41)
        $display("[%0t] CHI_SB ERROR: further violations counted but not printed", $time);
endtask

// ----------------------------------------------------------------------
// 1. State invariants
// ----------------------------------------------------------------------
reg [2:0]            sb_rn_state [0:NUM_RN-1][0:SB_RN_CACHE_LINES-1];
reg [ADDR_WIDTH-1:0] sb_rn_addr  [0:NUM_RN-1][0:SB_RN_CACHE_LINES-1];
reg [NUM_RN-1:0]     sb_sf_sharer [0:NUM_HN-1][0:SB_SF_ENTRIES-1];
reg [ADDR_WIDTH-1:0] sb_sf_addr   [0:NUM_HN-1][0:SB_SF_ENTRIES-1];

genvar sb_g, sb_w;
generate
    for (sb_g = 0; sb_g < NUM_RN; sb_g = sb_g + 1) begin : gen_sb_rn
        for (sb_w = 0; sb_w < SB_RN_WAYS; sb_w = sb_w + 1) begin : gen_sb_rn_way
            integer s;
            always @(posedge clk) begin
                if (sb_snap) begin
                    for (s = 0; s < SB_RN_SETS; s = s + 1) begin
                        sb_rn_state[sb_g][sb_w*SB_RN_SETS + s] =
                            dut.gen_rn[sb_g].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[sb_w].valid_mem[s] ?
                            dut.gen_rn[sb_g].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[sb_w].meta_mem[s][1 +: 3] :
                            `CHI_STATE_I;
                        sb_rn_addr[sb_g][sb_w*SB_RN_SETS + s] =
                            {dut.gen_rn[sb_g].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[sb_w].meta_mem[s][4 +: SB_RN_TAG_W],
                             s[SB_RN_SET_W-1:0], 6'b0};
                    end
                end
            end
        end
    end
    for (sb_g = 0; sb_g < NUM_HN; sb_g = sb_g + 1) begin : gen_sb_hn
        for (sb_w = 0; sb_w < SB_SF_WAYS; sb_w = sb_w + 1) begin : gen_sb_sf_way
            integer s;
            always @(posedge clk) begin
                if (sb_snap) begin
                    for (s = 0; s < SB_SF_SETS; s = s + 1) begin
                        sb_sf_sharer[sb_g][sb_w*SB_SF_SETS + s] =
                            dut.gen_hn[sb_g].u_hn_f.u_snoop_filter.gen_way_ram[sb_w].valid_mem[s] ?
                            dut.gen_hn[sb_g].u_hn_f.u_snoop_filter.gen_way_ram[sb_w].meta_mem[s][0 +: NUM_RN] :
                            {NUM_RN{1'b0}};
                        sb_sf_addr[sb_g][sb_w*SB_SF_SETS + s] =
                            {dut.gen_hn[sb_g].u_hn_f.u_snoop_filter.gen_way_ram[sb_w].meta_mem[s][NUM_RN + 2 +: SB_SF_TAG_W],
                             s[SB_SF_SET_W-1:0], 6'b0};
                    end
                end
            end
        end
    end
endgenerate

function automatic bit sb_unique(input [2:0] st);
    sb_unique = (st == `CHI_STATE_UC) || (st == `CHI_STATE_UD);
endfunction

task automatic sb_check_states;
    integer g, h, i, j, hn, e;
    bit     found;
    sb_state_checks = sb_state_checks + 1;
    for (g = 0; g < NUM_RN; g = g + 1) begin
        for (i = 0; i < SB_RN_CACHE_LINES; i = i + 1) begin
            if (sb_rn_state[g][i] != `CHI_STATE_I) begin
                for (h = g + 1; h < NUM_RN; h = h + 1)
                    for (j = 0; j < SB_RN_CACHE_LINES; j = j + 1)
                        if ((sb_rn_state[h][j] != `CHI_STATE_I) &&
                            (sb_rn_addr[h][j] == sb_rn_addr[g][i]) &&
                            (sb_unique(sb_rn_state[g][i]) || sb_unique(sb_rn_state[h][j]) ||
                             ((sb_rn_state[g][i] == `CHI_STATE_SD) &&
                              (sb_rn_state[h][j] == `CHI_STATE_SD))))
                            sb_err("SB_SWMR",
                                   $sformatf("line 0x%0h held by RN%0d state %0d and RN%0d state %0d",
                                             sb_rn_addr[g][i], g, sb_rn_state[g][i],
                                             h, sb_rn_state[h][j]));
                found = 1'b0;
                for (hn = 0; hn < NUM_HN; hn = hn + 1)
                    for (e = 0; e < SB_SF_ENTRIES; e = e + 1)
                        if (sb_sf_sharer[hn][e][g] && (sb_sf_addr[hn][e] == sb_rn_addr[g][i]))
                            found = 1'b1;
                if (!found)
                    sb_err("SB_SF_SUPERSET",
                           $sformatf("RN%0d holds line 0x%0h in state %0d but no snoop filter lists it",
                                     g, sb_rn_addr[g][i], sb_rn_state[g][i]));
            end
        end
    end
endtask

// Activity other than an exclusive reservation, which keeps chi_busy high
// for as long as a LDREX is waiting for its STREX.
wire [NUM_RN-1:0] sb_rn_active;
generate
    for (sb_g = 0; sb_g < NUM_RN; sb_g = sb_g + 1) begin : gen_sb_rn_active
        assign sb_rn_active[sb_g] =
            (dut.gen_rn[sb_g].u_rn_f.outstanding_count != 16'd0) ||
            dut.gen_rn[sb_g].u_rn_f.cache_busy || dut.gen_rn[sb_g].u_rn_f.snoop_busy ||
            dut.gen_rn[sb_g].u_rn_f.wdat_busy || dut.gen_rn[sb_g].u_rn_f.rsp_rx_busy ||
            dut.gen_rn[sb_g].u_rn_f.dat_rx_busy || dut.gen_rn[sb_g].u_rn_f.pending_wdat_valid_q ||
            dut.gen_rn[sb_g].u_rn_f.compack_valid_q || dut.gen_rn[sb_g].u_rn_f.tx_req_valid ||
            dut.gen_rn[sb_g].u_rn_f.tx_rsp_valid || dut.gen_rn[sb_g].u_rn_f.tx_dat_valid;
    end
endgenerate
wire sb_quiet = !(|sb_rn_active) && !(|dut.hn_busy) && !(|dut.sn_busy) &&
                !dut.fabric_busy && (dut.u_chi_protocol_checker.n_open == 0);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        sb_idle_cnt     <= 0;
        sb_idle_checked <= 1'b0;
        sb_snap         <= 1'b0;
        sb_eval         <= 1'b0;
    end else begin
        sb_snap <= 1'b0;
        sb_eval <= sb_snap;
        if (!sb_quiet || (|dut.cpu_req_valid)) begin
            sb_idle_cnt     <= 0;
            sb_idle_checked <= 1'b0;
        end else if (sb_idle_cnt < SB_IDLE_CYCLES) begin
            sb_idle_cnt <= sb_idle_cnt + 1;
        end else if (!sb_idle_checked && sb_enabled) begin
            sb_snap         <= 1'b1;
            sb_idle_checked <= 1'b1;
        end
    end
end

always @(negedge clk)
    if (rstn && sb_eval)
        sb_check_states();

// ----------------------------------------------------------------------
// 2. Data
// ----------------------------------------------------------------------
typedef struct {
    bit                  valid;
    bit [3:0]            op;
    bit [ADDR_WIDTH-1:0] addr;
    bit [64*8-1:0]       wdata;
    bit [63:0]           wstrb;
    bit                  ambiguous;
    int                  ver;
    bit                  line_done;
    // Bytes that another write to the same line wrote while this one was
    // pending.
    bit [63:0]           overlap;
} sb_pend_t;

sb_pend_t   sb_pend [0:NUM_RN-1][0:(1<<SB_TAG_W)-1];
bit [7:0]   sb_gold   [longint];
int         sb_ver    [longint];
int         sb_wpend  [longint];

function automatic longint sb_line(input [ADDR_WIDTH-1:0] addr);
    sb_line = longint'(addr) >> 6;
endfunction

function automatic bit sb_op_is_read(input [3:0] op);
    sb_op_is_read = (op == `CHI_CPU_OP_RD_SHARED) || (op == `CHI_CPU_OP_RD_UNIQUE) ||
                    (op == `CHI_CPU_OP_LDREX);
endfunction

function automatic bit sb_op_is_write(input [3:0] op);
    sb_op_is_write = (op == `CHI_CPU_OP_WB_FULL) || (op == `CHI_CPU_OP_WR_UNIQUE) ||
                     (op == `CHI_CPU_OP_STREX);
endfunction

function automatic int sb_ver_of(input longint ln);
    sb_ver_of = sb_ver.exists(ln) ? sb_ver[ln] : 0;
endfunction

function automatic int sb_wpend_of(input longint ln);
    sb_wpend_of = sb_wpend.exists(ln) ? sb_wpend[ln] : 0;
endfunction

task automatic sb_forget_line(input [ADDR_WIDTH-1:0] addr);
    longint ln;
    integer b;
    ln = sb_line(addr);
    for (b = 0; b < 64; b = b + 1)
        if (sb_gold.exists(ln*64 + b))
            sb_gold.delete(ln*64 + b);
    sb_ver[ln] = sb_ver_of(ln) + 1;
endtask

task automatic sb_forget_all;
    integer g, t;
    sb_gold.delete();
    sb_wpend.delete();
    foreach (sb_ver[k])
        sb_ver[k] = sb_ver[k] + 1;
    for (g = 0; g < NUM_RN; g = g + 1)
        for (t = 0; t < (1 << SB_TAG_W); t = t + 1)
            sb_pend[g][t].valid = 1'b0;
endtask

task automatic sb_read_line(input integer g, input integer tag, input [64*8-1:0] data);
    longint   ln;
    integer   b;
    integer   bad;
    bit [7:0] got;
    if (!sb_pend[g][tag].valid || !sb_op_is_read(sb_pend[g][tag].op))
        return;
    ln = sb_line(sb_pend[g][tag].addr);
    sb_pend[g][tag].line_done = 1'b1;
    if (sb_trace_on && (ln == sb_line(sb_trace_addr)))
        $display("[%0t] SB_TRACE RN%0d line data tag=%0d w0=0x%08h w1=0x%08h w4=0x%08h w11=0x%08h w13=0x%08h",
                 $time, g, tag, data[0 +: 32], data[32 +: 32], data[128 +: 32],
                 data[352 +: 32], data[416 +: 32]);
    if (sb_pend[g][tag].ambiguous || (sb_wpend_of(ln) != 0) ||
        (sb_ver_of(ln) != sb_pend[g][tag].ver)) begin
        sb_reads_skipped = sb_reads_skipped + 1;
        return;
    end
    sb_reads_checked = sb_reads_checked + 1;
    bad = -1;
    for (b = 0; b < 64; b = b + 1) begin
        got = data[b*8 +: 8];
        if (sb_gold.exists(ln*64 + b)) begin
            if ((sb_gold[ln*64 + b] != got) && (bad < 0))
                bad = b;
        end else begin
            sb_gold[ln*64 + b] = got;
        end
    end
    if (bad >= 0)
        sb_err("SB_DATA",
               $sformatf("RN%0d read of line 0x%0h: byte %0d is 0x%02h, last write left 0x%02h (word %0d got 0x%08h)",
                         g, ln << 6, bad, data[bad*8 +: 8], sb_gold[ln*64 + bad],
                         bad / 4, data[(bad/4)*32 +: 32]));
endtask

task automatic sb_cpu_resp(input integer g, input integer tag, input [DATA_WIDTH-1:0] rdata);
    longint ln;
    integer b;
    bit     commit;
    if (!sb_pend[g][tag].valid)
        return;
    ln = sb_line(sb_pend[g][tag].addr);
    if (sb_trace_on && (ln == sb_line(sb_trace_addr)))
        $display("[%0t] SB_TRACE RN%0d resp op=%0d tag=%0d rdata=0x%08h",
                 $time, g, sb_pend[g][tag].op, tag, rdata);
    // MakeUnique grants ownership without data: the line is undefined
    // until the requester writes all of it (IHI0050H B4.2), so relearn it.
    // The RN drops its own copy when it accepts the request, so the line
    // was already undefined for reads that overlapped it.
    if (sb_pend[g][tag].op == `CHI_CPU_OP_MK_UNIQUE) begin
        if (sb_wpend_of(ln) > 0)
            sb_wpend[ln] = sb_wpend[ln] - 1;
        sb_forget_line(sb_pend[g][tag].addr);
    end
    if (sb_op_is_write(sb_pend[g][tag].op)) begin
        if (sb_wpend_of(ln) > 0)
            sb_wpend[ln] = sb_wpend[ln] - 1;
        commit = (sb_pend[g][tag].op != `CHI_CPU_OP_STREX) || (rdata[0] == 1'b1);
        if (commit) begin
            for (b = 0; b < 64; b = b + 1)
                if (sb_pend[g][tag].wstrb[b]) begin
                    if (sb_pend[g][tag].overlap[b]) begin
                        if (sb_gold.exists(ln*64 + b))
                            sb_gold.delete(ln*64 + b);
                    end else begin
                        sb_gold[ln*64 + b] = sb_pend[g][tag].wdata[b*8 +: 8];
                    end
                end
            sb_ver[ln] = sb_ver_of(ln) + 1;
            sb_writes_committed = sb_writes_committed + 1;
        end
    end
    sb_pend[g][tag].valid = 1'b0;
endtask

task automatic sb_cpu_accept(input integer g, input integer tag,
                             input [3:0] op, input [ADDR_WIDTH-1:0] addr,
                             input [64*8-1:0] wdata, input [63:0] wstrb);
    longint ln;
    integer og, ot;
    ln = sb_line(addr);
    if (sb_trace_on && (ln == sb_line(sb_trace_addr)))
        $display("[%0t] SB_TRACE RN%0d accept op=%0d tag=%0d addr=0x%0h wstrb=0x%016h wdata_w0=0x%08h",
                 $time, g, op, tag, addr, wstrb, wdata[0 +: 32]);
    sb_pend[g][tag].valid     = 1'b1;
    sb_pend[g][tag].op        = op;
    sb_pend[g][tag].addr      = addr;
    sb_pend[g][tag].wdata     = wdata;
    sb_pend[g][tag].wstrb     = wstrb;
    sb_pend[g][tag].line_done = 1'b0;
    sb_pend[g][tag].ver       = sb_ver_of(ln);
    sb_pend[g][tag].ambiguous = (sb_wpend_of(ln) != 0);
    sb_pend[g][tag].overlap   = '0;
    if (sb_op_is_write(op)) begin
        // Pending writes to this line and this one overlap each other.
        for (og = 0; og < NUM_RN; og = og + 1)
            for (ot = 0; ot < (1 << SB_TAG_W); ot = ot + 1)
                if (sb_pend[og][ot].valid && sb_op_is_write(sb_pend[og][ot].op) &&
                    (sb_line(sb_pend[og][ot].addr) == ln) &&
                    !((og == g) && (ot == tag))) begin
                    sb_pend[og][ot].overlap = sb_pend[og][ot].overlap | wstrb;
                    sb_pend[g][tag].overlap = sb_pend[g][tag].overlap |
                                              sb_pend[og][ot].wstrb;
                end
        sb_wpend[ln] = sb_wpend_of(ln) + 1;
    end else if (op == `CHI_CPU_OP_MK_UNIQUE) begin
        sb_wpend[ln] = sb_wpend_of(ln) + 1;
    end
endtask

generate
    for (sb_g = 0; sb_g < NUM_RN; sb_g = sb_g + 1) begin : gen_sb_cpu
        always @(posedge clk) begin
            if (rstn && sb_data_enabled) begin
                // Responses first: a trailing response and a new request with
                // the same tag can share a cycle.
                if (dut.cpu_resp_line_valid[sb_g])
                    sb_read_line(sb_g, dut.cpu_resp_line_tag[sb_g*SB_TAG_W +: SB_TAG_W],
                                 dut.cpu_resp_line_data[sb_g*64*8 +: 64*8]);
                if (dut.cpu_resp_valid[sb_g])
                    sb_cpu_resp(sb_g, dut.cpu_resp_tag[sb_g*SB_TAG_W +: SB_TAG_W],
                                dut.cpu_rdata[sb_g*DATA_WIDTH +: DATA_WIDTH]);
                if (dut.cpu_req_valid[sb_g] && dut.cpu_req_ready[sb_g])
                    sb_cpu_accept(sb_g, dut.cpu_req_tag[sb_g*SB_TAG_W +: SB_TAG_W],
                                  dut.cpu_req_op[sb_g*4 +: 4],
                                  dut.cpu_req_addr[sb_g*ADDR_WIDTH +: ADDR_WIDTH],
                                  dut.gen_rn[sb_g].u_rn_f.cpu_wdata_line,
                                  dut.gen_rn[sb_g].u_rn_f.cpu_wstrb_line);
            end
        end
    end
endgenerate

always @(negedge rstn)
    sb_forget_all();

final begin
    if (sb_enabled)
        $display("CHI_SB SUMMARY violations=%0d state_checks=%0d reads_checked=%0d reads_skipped=%0d writes=%0d",
                 sb_errors, sb_state_checks, sb_reads_checked, sb_reads_skipped,
                 sb_writes_committed);
end
