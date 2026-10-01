// -----------------------------------------------------------------------------
// chi_l1_coherence_scoreboard.svh
//
// Coherence scoreboard for the SoC configuration, where the RN caches are the
// external RV32 L1 D-caches (dcache.v) and the CHI RN-Fs have no cache of
// their own. Include it inside the testbench module after these are defined:
//
//     `define SBL1_ROOT <path to riscv_dual_core_chi_wrapper>, e.g. u_dut.u_cluster
//     localparam integer DC_WAYS, DC_INDEX_W, DC_TAG_W   (D-L1 geometry)
//     localparam integer HN_SF_SET_W, HN_SF_TAG_W        (HN snoop filter)
//     clk, rstn
//
// At every quiet point (fabric not busy, no open CHI transaction or snoop, both
// D-caches idle, for SBL1_IDLE_CYCLES cycles) it checks every valid L1 line:
//   SB_L1_SWMR         a dirty line (written back later, so owned) is valid in
//                      no other L1
//   SB_L1_SF_SUPERSET  the HN snoop filter tracks the line with that core's
//                      sharer bit set, so a write by the other core snoops it
// Violations print "CHI_SBL1 ERROR:". +CHI_SB_OFF disables it.
// A testbench that puts a line into an L1 behind the fabric's back (backdoor
// seeding) calls sbl1_exempt_line(addr); that line is not checked.
// -----------------------------------------------------------------------------
localparam integer SBL1_IDLE_CYCLES = 8;
localparam integer SBL1_SETS = 1 << DC_INDEX_W;

integer sbl1_errors = 0;
integer sbl1_checks = 0;
integer sbl1_lines  = 0;
integer sbl1_idle_cnt = 0;
bit     sbl1_enabled;
bit     sbl1_checked;
bit     sbl1_exempt [longint];

task automatic sbl1_exempt_line(input [ADDR_WIDTH-1:0] addr);
    sbl1_exempt[longint'(addr >> 6)] = 1'b1;
endtask

initial begin
    sbl1_enabled = !$test$plusargs("CHI_SB_OFF");
    sbl1_checked = 1'b0;
end

function automatic bit sbl1_valid(input int core, input int set, input int way);
    if (core == 0) sbl1_valid = `SBL1_ROOT.u_core0_tile.u_dcache.valid_arr[set][way];
    else           sbl1_valid = `SBL1_ROOT.u_core1_tile.u_dcache.valid_arr[set][way];
endfunction

function automatic bit sbl1_dirty(input int core, input int set, input int way);
    if (core == 0) sbl1_dirty = `SBL1_ROOT.u_core0_tile.u_dcache.dirty_arr[set][way];
    else           sbl1_dirty = `SBL1_ROOT.u_core1_tile.u_dcache.dirty_arr[set][way];
endfunction

function automatic [DC_TAG_W-1:0] sbl1_tag(input int core, input int set, input int way);
    sbl1_tag = '0;
    if (core == 0) begin
        case (way)
            0: sbl1_tag = `SBL1_ROOT.u_core0_tile.u_dcache.TAG_RAM.tag_ways[0].ram[set];
            1: sbl1_tag = `SBL1_ROOT.u_core0_tile.u_dcache.TAG_RAM.tag_ways[1].ram[set];
            2: sbl1_tag = `SBL1_ROOT.u_core0_tile.u_dcache.TAG_RAM.tag_ways[2].ram[set];
            default: sbl1_tag = `SBL1_ROOT.u_core0_tile.u_dcache.TAG_RAM.tag_ways[3].ram[set];
        endcase
    end else begin
        case (way)
            0: sbl1_tag = `SBL1_ROOT.u_core1_tile.u_dcache.TAG_RAM.tag_ways[0].ram[set];
            1: sbl1_tag = `SBL1_ROOT.u_core1_tile.u_dcache.TAG_RAM.tag_ways[1].ram[set];
            2: sbl1_tag = `SBL1_ROOT.u_core1_tile.u_dcache.TAG_RAM.tag_ways[2].ram[set];
            default: sbl1_tag = `SBL1_ROOT.u_core1_tile.u_dcache.TAG_RAM.tag_ways[3].ram[set];
        endcase
    end
endfunction

// Snoop-filter sharer vector for a line (0 if the line is not tracked).
function automatic [1:0] sbl1_sf_sharers(input [ADDR_WIDTH-1:0] line);
    int set;
    bit [HN_SF_TAG_W-1:0] tag;
    bit [HN_SF_TAG_W+4-1:0] meta;
    sbl1_sf_sharers = 2'b00;
    set = line[6 +: HN_SF_SET_W];
    tag = line[ADDR_WIDTH-1 -: HN_SF_TAG_W];
    if (`SBL1_ROOT.u_chi.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[0].valid_mem[set]) begin
        meta = `SBL1_ROOT.u_chi.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[0].meta_mem[set];
        if (meta[HN_SF_TAG_W+4-1 -: HN_SF_TAG_W] == tag) sbl1_sf_sharers = meta[1:0];
    end
    if (`SBL1_ROOT.u_chi.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[1].valid_mem[set]) begin
        meta = `SBL1_ROOT.u_chi.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[1].meta_mem[set];
        if (meta[HN_SF_TAG_W+4-1 -: HN_SF_TAG_W] == tag) sbl1_sf_sharers = meta[1:0];
    end
    if (`SBL1_ROOT.u_chi.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[2].valid_mem[set]) begin
        meta = `SBL1_ROOT.u_chi.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[2].meta_mem[set];
        if (meta[HN_SF_TAG_W+4-1 -: HN_SF_TAG_W] == tag) sbl1_sf_sharers = meta[1:0];
    end
    if (`SBL1_ROOT.u_chi.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[3].valid_mem[set]) begin
        meta = `SBL1_ROOT.u_chi.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[3].meta_mem[set];
        if (meta[HN_SF_TAG_W+4-1 -: HN_SF_TAG_W] == tag) sbl1_sf_sharers = meta[1:0];
    end
endfunction

function automatic bit sbl1_holds(input int core, input [ADDR_WIDTH-1:0] line);
    int set;
    sbl1_holds = 1'b0;
    set = line[6 +: DC_INDEX_W];
    for (int w = 0; w < DC_WAYS; w++)
        if (sbl1_valid(core, set, w) &&
            (sbl1_tag(core, set, w) == line[ADDR_WIDTH-1 -: DC_TAG_W]))
            sbl1_holds = 1'b1;
endfunction

task automatic sbl1_err(input string rule, input string msg);
    sbl1_errors = sbl1_errors + 1;
    $display("[%0t] CHI_SBL1 ERROR: %s %s", $time, rule, msg);
endtask

task automatic sbl1_check;
    bit [ADDR_WIDTH-1:0] line;
    bit [1:0]            sharers;
    sbl1_checks = sbl1_checks + 1;
    for (int c = 0; c < 2; c++)
        for (int s = 0; s < SBL1_SETS; s++)
            for (int w = 0; w < DC_WAYS; w++)
                if (sbl1_valid(c, s, w)) begin
                    line = {sbl1_tag(c, s, w), s[DC_INDEX_W-1:0], 6'b0};
                    if (sbl1_exempt.exists(longint'(line >> 6)))
                        continue;
                    sbl1_lines = sbl1_lines + 1;
                    if (sbl1_dirty(c, s, w) && sbl1_holds(1 - c, line))
                        sbl1_err("SB_L1_SWMR",
                                 $sformatf("core%0d holds line 0x%0h dirty while core%0d holds it too",
                                           c, line, 1 - c));
                    sharers = sbl1_sf_sharers(line);
                    if (!sharers[c])
                        sbl1_err("SB_L1_SF_SUPERSET",
                                 $sformatf("core%0d holds line 0x%0h but the SF sharers are %02b",
                                           c, line, sharers));
                end
endtask

always @(posedge clk) begin
    if (!rstn || !sbl1_enabled) begin
        sbl1_idle_cnt <= 0;
        sbl1_checked <= 1'b0;
    end else if (!`SBL1_ROOT.u_chi.chi_busy &&
                 (`SBL1_ROOT.u_chi.u_chi_protocol_checker.n_open == 0) &&
                 (`SBL1_ROOT.u_core0_tile.u_dcache.state == 4'd0) &&
                 (`SBL1_ROOT.u_core1_tile.u_dcache.state == 4'd0)) begin
        if (sbl1_idle_cnt < SBL1_IDLE_CYCLES)
            sbl1_idle_cnt <= sbl1_idle_cnt + 1;
        else if (!sbl1_checked) begin
            sbl1_check();
            sbl1_checked <= 1'b1;
        end
    end else begin
        sbl1_idle_cnt <= 0;
        sbl1_checked <= 1'b0;
    end
end

final begin
    if (sbl1_enabled)
        $display("CHI_SBL1 SUMMARY violations=%0d checks=%0d lines_checked=%0d",
                 sbl1_errors, sbl1_checks, sbl1_lines);
end
