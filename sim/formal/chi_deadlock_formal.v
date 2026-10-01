`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// File: chi_deadlock_formal
// Purpose: Simulation/formal monitors for CHI credit, DVM, liveness, TxnID, and
//          exclusive-reservation invariants. These modules are passive until
//          explicitly instantiated or bound by a simulation/formal script.
// -----------------------------------------------------------------------------

module chi_credit_no_deadlock_formal #(
    parameter CREDIT_W    = 4,
    parameter MAX_CREDIT  = `CHI_DEFAULT_INIT_CRD,
    parameter STALL_BOUND = 2048
)(
    input                  clk,
    input                  rstn,
    input                  valid,
    input                  ready,
    input                  tx_fire,
    input                  credit_return,
    input [CREDIT_W-1:0]   credit_count
);
`ifndef SYNTHESIS
`ifdef CHI_SIM_ASSERTIONS
    localparam [CREDIT_W-1:0] MAX_CREDIT_VALUE = MAX_CREDIT;
    localparam [15:0] STALL_BOUND_VALUE = STALL_BOUND;

    reg [15:0] stall_cnt_q;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            stall_cnt_q <= 16'd0;
        end else if (valid && !ready) begin
            if (stall_cnt_q != STALL_BOUND_VALUE)
                stall_cnt_q <= stall_cnt_q + 1'b1;
        end else begin
            stall_cnt_q <= 16'd0;
        end
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (credit_count > MAX_CREDIT_VALUE) begin
                $display("[B5 FATAL] credit_count overflow: %0d > %0d",
                         credit_count, MAX_CREDIT_VALUE);
                `ifdef CHI_SIM_ASSERTIONS_HALT
                    $stop;
                `endif
            end

            if (tx_fire && !ready) begin
                $display("[B5 FATAL] tx_fire while !ready");
                `ifdef CHI_SIM_ASSERTIONS_HALT
                    $stop;
                `endif
            end

            if (stall_cnt_q == STALL_BOUND_VALUE) begin
                $display("[B5 FATAL] credit stall bound reached: %0d",
                         STALL_BOUND);
                `ifdef CHI_SIM_ASSERTIONS_HALT
                    $stop;
                `endif
            end

            if ((credit_count == {CREDIT_W{1'b0}}) &&
                tx_fire &&
                !credit_return) begin
                $display("[B5 FATAL] tx_fire with no credit and no same-cycle return");
                `ifdef CHI_SIM_ASSERTIONS_HALT
                    $stop;
                `endif
            end
        end
    end
`endif
`endif
endmodule

module chi_dvm_sync_order_formal #(
    parameter DRAIN_BOUND = 32
)(
    input clk,
    input rstn,
    input dvm_drain_active,
    input sync_issue,
    input drain_done
);
`ifndef SYNTHESIS
`ifdef CHI_SIM_ASSERTIONS
    reg [15:0] drain_age_q;
    localparam [15:0] DRAIN_BOUND_VALUE = DRAIN_BOUND;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            drain_age_q <= 16'd0;
        end else if (dvm_drain_active && !drain_done) begin
            if (drain_age_q != DRAIN_BOUND_VALUE)
                drain_age_q <= drain_age_q + 1'b1;
        end else begin
            drain_age_q <= 16'd0;
        end
    end

    always @(posedge clk) begin
        if (rstn) begin
            if (sync_issue && dvm_drain_active && !drain_done) begin
                $display("[B5 FATAL] DVMSync issued before drain_done");
                `ifdef CHI_SIM_ASSERTIONS_HALT
                    $stop;
                `endif
            end

            if (drain_age_q == DRAIN_BOUND_VALUE) begin
                $display("[B5 FATAL] DVM drain bound reached: %0d",
                         DRAIN_BOUND);
                `ifdef CHI_SIM_ASSERTIONS_HALT
                    $stop;
                `endif
            end
        end
    end
`endif
`endif
endmodule

module chi_eventual_completion_formal #(
    parameter BOUND = 1024
)(
    input clk,
    input rstn,
    input start,
    input complete
);
`ifndef SYNTHESIS
`ifdef CHI_SIM_ASSERTIONS
    reg        busy_q;
    reg        reported_q;
    reg [15:0] age_q;
    localparam [15:0] BOUND_VALUE = BOUND;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_q <= 1'b0;
            reported_q <= 1'b0;
            age_q <= 16'd0;
        end else if (complete) begin
            busy_q <= 1'b0;
            reported_q <= 1'b0;
            age_q <= 16'd0;
        end else if (start && !busy_q) begin
            busy_q <= 1'b1;
            reported_q <= 1'b0;
            age_q <= 16'd0;
        end else if (busy_q && (age_q != BOUND_VALUE)) begin
            age_q <= age_q + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rstn && busy_q && !reported_q && (age_q == BOUND_VALUE)) begin
            $display("[B5 FATAL] eventual completion bound reached: %0d",
                     BOUND);
            reported_q <= 1'b1;
            `ifdef CHI_SIM_ASSERTIONS_HALT
                $stop;
            `endif
        end
    end
`endif
`endif
endmodule

module chi_txn_id_unique_formal #(
    parameter TXN_TBL_SIZE = `CHI_DEFAULT_RN_TXN_TBL_SIZE,
    parameter TXN_ID_W     = `CHI_DEFAULT_TXN_ID_W
)(
    input                          clk,
    input                          rstn,
    input [TXN_TBL_SIZE-1:0]       entry_valid,
    input [TXN_TBL_SIZE*TXN_ID_W-1:0] entry_txn_id_flat
);
`ifndef SYNTHESIS
`ifdef CHI_SIM_ASSERTIONS
    integer p3_i;
    integer p3_j;

    always @(posedge clk) begin
        if (rstn) begin
            for (p3_i = 0; p3_i < TXN_TBL_SIZE; p3_i = p3_i + 1) begin
                for (p3_j = p3_i + 1; p3_j < TXN_TBL_SIZE; p3_j = p3_j + 1) begin
                    if (entry_valid[p3_i] &&
                        entry_valid[p3_j] &&
                        (entry_txn_id_flat[p3_i*TXN_ID_W +: TXN_ID_W] ==
                         entry_txn_id_flat[p3_j*TXN_ID_W +: TXN_ID_W])) begin
                        $display("[B5 FATAL] duplicate TxnID at entries %0d,%0d",
                                 p3_i, p3_j);
                        `ifdef CHI_SIM_ASSERTIONS_HALT
                            $stop;
                        `endif
                    end
                end
            end
        end
    end
`endif
`endif
endmodule

module chi_compack_liveness_formal #(
    parameter BOUND = 256
)(
    input clk,
    input rstn,
    input compdata_last_beat_fire,
    input compack_fire
);
    chi_eventual_completion_formal #(
        .BOUND(BOUND)
    ) u_eventual_compack (
        .clk(clk),
        .rstn(rstn),
        .start(compdata_last_beat_fire),
        .complete(compack_fire)
    );
endmodule

module chi_snpresp_window_formal #(
    parameter BOUND = 1024
)(
    input clk,
    input rstn,
    input snp_fire,
    input snpresp_fire
);
    chi_eventual_completion_formal #(
        .BOUND(BOUND)
    ) u_eventual_snpresp (
        .clk(clk),
        .rstn(rstn),
        .start(snp_fire),
        .complete(snpresp_fire)
    );
endmodule

module chi_excl_mutex_formal #(
    parameter NUM_RN      = `CHI_DEFAULT_NUM_RN,
    parameter LINE_ADDR_W = 38
)(
    input clk,
    input rstn,
    input [NUM_RN-1:0]             excl_valid,
    input [NUM_RN*LINE_ADDR_W-1:0] excl_line_flat,
    // An exclusive store passed at the home this cycle, on this line.
    input                          excl_pass,
    input [LINE_ADDR_W-1:0]        excl_pass_line
);
`ifndef SYNTHESIS
`ifdef CHI_SIM_ASSERTIONS
    // Several RNs may hold a reservation on one line (an exclusive read is
    // ReadShared, B6.3). What must hold is that a passing exclusive store
    // ends every reservation on its line, so a second one cannot pass.
    integer p7_i;
    reg                   pass_q;
    reg [LINE_ADDR_W-1:0] pass_line_q;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            pass_q <= 1'b0;
            pass_line_q <= {LINE_ADDR_W{1'b0}};
        end else begin
            pass_q <= excl_pass;
            pass_line_q <= excl_pass_line;
        end
    end

    always @(posedge clk) begin
        if (rstn && pass_q) begin
            for (p7_i = 0; p7_i < NUM_RN; p7_i = p7_i + 1) begin
                if (excl_valid[p7_i] &&
                    (excl_line_flat[p7_i*LINE_ADDR_W +: LINE_ADDR_W] ==
                     pass_line_q)) begin
                    $display("[B5 FATAL] exclusive mutex violation: RN%0d still reserved after an exclusive store passed",
                             p7_i);
                    `ifdef CHI_SIM_ASSERTIONS_HALT
                        $stop;
                    `endif
                end
            end
        end
    end
`endif
`endif
endmodule
