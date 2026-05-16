# Phase 0 Vivado baseline for the CHI interconnect RTL.
# Usage:
#   vivado -mode batch -source scripts/vivado_phase0_lint.tcl -tclargs xc7a35tcpg236-1

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ".."]]
set rtl_dir    [file join $repo_root "rtl"]
set rpt_dir    [file join $repo_root "reports"]
file mkdir $rpt_dir

if {[llength $argv] > 0} {
    set part_name [lindex $argv 0]
} else {
    set part_name "xc7a35tcpg236-1"
}

set include_dirs [list [file join $rtl_dir "common"]]

set srcs [list \
    [file join $rtl_dir "common" "chi_addr_decoder.v"] \
    [file join $rtl_dir "common" "chi_clock_gate_insert.v"] \
    [file join $rtl_dir "common" "chi_credit_counter.v"] \
    [file join $rtl_dir "common" "chi_csr_regs.v"] \
    [file join $rtl_dir "common" "chi_demux_1hot.v"] \
    [file join $rtl_dir "common" "chi_fifo.v"] \
    [file join $rtl_dir "common" "chi_flit_reg_slice.v"] \
    [file join $rtl_dir "common" "chi_link_layer.v"] \
    [file join $rtl_dir "common" "chi_mux_1hot.v"] \
    [file join $rtl_dir "common" "chi_route_decode.v"] \
    [file join $rtl_dir "common" "chi_skid_buffer.v"] \
    [file join $rtl_dir "fabric" "chi_channel_slice.v"] \
    [file join $rtl_dir "fabric" "chi_crossbar.v"] \
    [file join $rtl_dir "fabric" "chi_fabric.v"] \
    [file join $rtl_dir "fabric" "chi_input_buffer.v"] \
    [file join $rtl_dir "fabric" "chi_output_arbiter.v"] \
    [file join $rtl_dir "fabric" "chi_output_reg.v"] \
    [file join $rtl_dir "hn" "chi_hn_f.v"] \
    [file join $rtl_dir "hn" "chi_hn_llc.v"] \
    [file join $rtl_dir "hn" "chi_hn_mem_issuer.v"] \
    [file join $rtl_dir "hn" "chi_hn_pos_buffer.v"] \
    [file join $rtl_dir "hn" "chi_hn_req_parser.v"] \
    [file join $rtl_dir "hn" "chi_hn_resp_engine.v"] \
    [file join $rtl_dir "hn" "chi_hn_snoop_filter.v"] \
    [file join $rtl_dir "hn" "chi_hn_snoop_generator.v"] \
    [file join $rtl_dir "hn" "chi_hn_write_tracker.v"] \
    [file join $rtl_dir "mn" "chi_hn_i_mn.v"] \
    [file join $rtl_dir "mn" "chi_mn_dvm.v"] \
    [file join $rtl_dir "mn" "chi_mn_dvm_tracker.v"] \
    [file join $rtl_dir "rn" "chi_exclusive_monitor.v"] \
    [file join $rtl_dir "rn" "chi_rn_cache.v"] \
    [file join $rtl_dir "rn" "chi_rn_dat_rx.v"] \
    [file join $rtl_dir "rn" "chi_rn_f.v"] \
    [file join $rtl_dir "rn" "chi_rn_req_engine.v"] \
    [file join $rtl_dir "rn" "chi_rn_rsp_rx.v"] \
    [file join $rtl_dir "rn" "chi_rn_snoop_handler.v"] \
    [file join $rtl_dir "rn" "chi_rn_txn_tracker.v"] \
    [file join $rtl_dir "rn" "chi_rn_wdat_engine.v"] \
    [file join $rtl_dir "sn" "chi_sn_axi_bridge.v"] \
    [file join $rtl_dir "sn" "chi_sn_f.v"] \
    [file join $rtl_dir "sn" "chi_sn_rdata_buf.v"] \
    [file join $rtl_dir "sn" "chi_sn_req_decode.v"] \
    [file join $rtl_dir "sn" "chi_sn_wdata_buf.v"] \
    [file join $rtl_dir "chi_top.v"] \
]

foreach src $srcs {
    if {![file exists $src]} {
        error "Missing RTL source: $src"
    }
}

read_verilog -include_dirs $include_dirs $srcs
synth_design -top chi_top -part $part_name -mode out_of_context

report_compile_order -file [file join $rpt_dir "phase0_compile_order.rpt"]
report_utilization -file [file join $rpt_dir "phase0_utilization.rpt"]
report_timing_summary -file [file join $rpt_dir "phase0_timing_summary.rpt"]
