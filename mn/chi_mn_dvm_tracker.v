`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_mn_dvm_tracker
// Purpose: Single outstanding DVM tracker for MN. It owns send/wait masks,
//          timeout age, active request context, and ack collection state.
// -----------------------------------------------------------------------------
module chi_mn_dvm_tracker #(
    parameter NUM_RN         = `CHI_DEFAULT_NUM_RN,
    parameter NODE_ID_W      = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W       = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W          = `CHI_DEFAULT_QOS_W,
    parameter TIMEOUT_CYCLES = 1024
)(
    input                    clk,
    input                    rstn,
    input                    clear,

    input                    alloc_valid,
    output                   alloc_ready,
    input      [TXN_ID_W-1:0] alloc_txn_id,
    input      [NODE_ID_W-1:0] alloc_src_id,
    input      [QOS_W-1:0]   alloc_qos,
    input      [NUM_RN-1:0]  alloc_mask,

    input                    phase_start_valid,
    input      [NUM_RN-1:0]  phase_mask,
    input                    mark_sent_valid,
    input      [NUM_RN-1:0]  mark_sent_onehot,
    input                    mark_ack_valid,
    input      [NUM_RN-1:0]  mark_ack_onehot,
    input                    complete_clear,

    output                   busy,
    output     [TXN_ID_W-1:0] active_txn_id,
    output     [NODE_ID_W-1:0] active_src_id,
    output     [QOS_W-1:0]   active_qos,
    output     [NUM_RN-1:0]  active_send_mask,
    output     [NUM_RN-1:0]  active_wait_mask,
    output                   all_sent,
    output                   all_acked,
    output                   timeout_fire
);
    `include "../common/chi_clog2.vh"
localparam TIMEOUT_W = (TIMEOUT_CYCLES <= 2) ? 1 :
                           `CHI_CLOG2(TIMEOUT_CYCLES + 1);
    localparam [TIMEOUT_W-1:0] TIMEOUT_VALUE = TIMEOUT_CYCLES;

    reg                  valid_q;
    reg [TXN_ID_W-1:0]   txn_id_q;
    reg [NODE_ID_W-1:0]  src_id_q;
    reg [QOS_W-1:0]      qos_q;
    reg [NUM_RN-1:0]     send_mask_q;
    reg [NUM_RN-1:0]     wait_mask_q;
    reg [TIMEOUT_W-1:0]  age_q;

    assign alloc_ready = !valid_q;
    assign busy = valid_q;
    assign active_txn_id = txn_id_q;
    assign active_src_id = src_id_q;
    assign active_qos = qos_q;
    assign active_send_mask = send_mask_q;
    assign active_wait_mask = wait_mask_q;
    assign all_sent = (send_mask_q == {NUM_RN{1'b0}});
    assign all_acked = (wait_mask_q == {NUM_RN{1'b0}});
    assign timeout_fire = valid_q && (age_q >= TIMEOUT_VALUE);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q     <= 1'b0;
            txn_id_q    <= {TXN_ID_W{1'b0}};
            src_id_q    <= {NODE_ID_W{1'b0}};
            qos_q       <= {QOS_W{1'b0}};
            send_mask_q <= {NUM_RN{1'b0}};
            wait_mask_q <= {NUM_RN{1'b0}};
            age_q       <= {TIMEOUT_W{1'b0}};
        end else if (clear || complete_clear) begin
            valid_q     <= 1'b0;
            send_mask_q <= {NUM_RN{1'b0}};
            wait_mask_q <= {NUM_RN{1'b0}};
            age_q       <= {TIMEOUT_W{1'b0}};
        end else if (alloc_valid && alloc_ready) begin
            valid_q     <= 1'b1;
            txn_id_q    <= alloc_txn_id;
            src_id_q    <= alloc_src_id;
            qos_q       <= alloc_qos;
            send_mask_q <= alloc_mask;
            wait_mask_q <= alloc_mask;
            age_q       <= {TIMEOUT_W{1'b0}};
        end else begin
            if (valid_q && (age_q != TIMEOUT_VALUE))
                age_q <= age_q + 1'b1;

            if (phase_start_valid) begin
                send_mask_q <= phase_mask;
                wait_mask_q <= phase_mask;
            end else begin
                if (mark_sent_valid)
                    send_mask_q <= send_mask_q & ~mark_sent_onehot;
                if (mark_ack_valid)
                    wait_mask_q <= wait_mask_q & ~mark_ack_onehot;
            end
        end
    end
endmodule
