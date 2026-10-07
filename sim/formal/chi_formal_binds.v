`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// File: chi_formal_binds
// Purpose: Optional bind layer for B5 simulation/formal monitors. Load this
//          file after RTL sources and formal/chi_deadlock_formal.v.
// -----------------------------------------------------------------------------

`ifndef SYNTHESIS
`ifdef CHI_SIM_ASSERTIONS

bind chi_link_layer chi_credit_no_deadlock_formal #(
    .CREDIT_W(CREDIT_W),
    // Credits come from the receiver (B14.2.1), at most 15 per channel.
    .MAX_CREDIT(15),
    .STALL_BOUND(2048)
) u_b5_credit_no_deadlock (
    .clk(clk),
    .rstn(rstn),
    .valid(tx_in_valid),
    .ready(tx_in_ready),
    .tx_fire(tx_fire_pulse),
    .credit_return(tx_credit_return_pulse),
    .credit_count(credit_count)
);

bind chi_mn_dvm chi_dvm_sync_order_formal #(
    .DRAIN_BOUND(1024)
) u_b5_dvm_sync_order (
    .clk(clk),
    .rstn(rstn),
    .dvm_drain_active(b5_dvm_drain_active),
    .sync_issue(b5_dvm_sync_issue),
    .drain_done(b5_dvm_drain_done)
);

bind chi_rn_txn_tracker chi_txn_id_unique_formal #(
    .TXN_TBL_SIZE(TXN_TBL_SIZE),
    .TXN_ID_W(TXN_ID_W)
) u_b5_txn_id_unique (
    .clk(clk),
    .rstn(rstn),
    .entry_valid(debug_entry_valid),
    .entry_txn_id_flat(debug_entry_txn_id_flat)
);

bind chi_hn_f chi_compack_liveness_formal #(
    .BOUND(1024)
) u_b5_compack_liveness (
    .clk(clk),
    .rstn(rstn),
    .compdata_last_beat_fire(resp_dat_last),
    .compack_fire(comp_ack_fire)
);

bind chi_hn_f chi_snpresp_window_formal #(
    .BOUND(1024)
) u_b5_snpresp_window (
    .clk(clk),
    .rstn(rstn),
    // FLITV in RUN is a snoop; in DEACTIVATE it is an LCrdReturn flit.
    .snp_fire(tx_snp_valid && tx_link_run),
    .snpresp_fire(rsp_sink_valid &&
                  (rsp_opcode == `CHI_RSP_SNP_RESP) &&
                  rsp_sink_pop)
);

bind chi_hn_f chi_excl_mutex_formal #(
    .NUM_RN(NUM_RN),
    .LINE_ADDR_W(LINE_ADDR_W)
) u_b5_excl_mutex (
    .clk(clk),
    .rstn(rstn),
    .excl_valid(b5_excl_valid_flat),
    .excl_line_flat(b5_excl_line_flat),
    .excl_pass(b5_excl_pass),
    .excl_pass_line(b5_excl_pass_line)
);

`endif
`endif
