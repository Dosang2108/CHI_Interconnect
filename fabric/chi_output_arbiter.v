`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_output_arbiter
// Purpose: Per-output request arbiter with round-robin tie break and optional
//          QoS aging promotion for long-waiting inputs.
// -----------------------------------------------------------------------------
module chi_output_arbiter #(
    parameter NUM_IN       = `CHI_DEFAULT_NUM_RN,
    parameter QOS_W        = `CHI_DEFAULT_QOS_W,
    parameter AGE_W        = 8,
    parameter ENABLE_QOS_AGING = `CHI_DEFAULT_ENABLE_QOS_AGING
)(
    input                    clk,
    input                    rstn,
    input      [NUM_IN-1:0]  req_vec,
    input      [NUM_IN*QOS_W-1:0] qos_flat,
    input      [NUM_IN-1:0]  credit_ok,
    input      [7:0]         cfg_qos_age_shift,
    input      [7:0]         cfg_qos_age_max,
    output reg [NUM_IN-1:0]  gnt_vec
);
    `include "../common/chi_clog2.vh"
    localparam EFF_QOS_W = QOS_W + AGE_W;
    localparam PTR_W = (NUM_IN <= 2) ? 1 : `CHI_CLOG2(NUM_IN);

    reg [PTR_W-1:0] rr_ptr;
    wire [NUM_IN*EFF_QOS_W-1:0] eff_qos_flat;
    reg [EFF_QOS_W-1:0] qos_max;
    reg [EFF_QOS_W-1:0] scan_eff_qos;
    reg [EFF_QOS_W-1:0] grant_eff_qos;
    reg             have_req;
    reg             grant_found;
    integer         scan_i;
    integer         grant_k;
    integer         grant_idx_scan;
    integer         grant_idx;
    genvar          qos_g;

    function [QOS_W-1:0] get_qos;
        input integer idx;
        begin
            get_qos = qos_flat[idx*QOS_W +: QOS_W];
        end
    endfunction

    function [EFF_QOS_W-1:0] get_eff_qos;
        input integer idx;
        begin
            get_eff_qos = eff_qos_flat[idx*EFF_QOS_W +: EFF_QOS_W];
        end
    endfunction

    generate
        if (ENABLE_QOS_AGING != 0) begin : gen_qos_aging
            reg [AGE_W-1:0] starv_cnt [0:NUM_IN-1];
            wire [AGE_W-1:0] age_max_cfg;
            integer         starv_i;

            if (AGE_W <= 8) begin : gen_age_max_narrow
                assign age_max_cfg = cfg_qos_age_max[AGE_W-1:0];
            end else begin : gen_age_max_wide
                assign age_max_cfg = {{(AGE_W-8){1'b0}}, cfg_qos_age_max};
            end

            for (qos_g = 0; qos_g < NUM_IN; qos_g = qos_g + 1) begin : gen_eff_qos
                wire [AGE_W-1:0] age_bonus =
                    (cfg_qos_age_shift >= AGE_W) ?
                    {AGE_W{1'b0}} :
                    (starv_cnt[qos_g] >> cfg_qos_age_shift);

                assign eff_qos_flat[qos_g*EFF_QOS_W +: EFF_QOS_W] =
                    {{AGE_W{1'b0}}, qos_flat[qos_g*QOS_W +: QOS_W]} +
                    {{QOS_W{1'b0}}, age_bonus};
            end

            always @(posedge clk or negedge rstn) begin
                if (!rstn) begin
                    for (starv_i = 0; starv_i < NUM_IN; starv_i = starv_i + 1)
                        starv_cnt[starv_i] <= {AGE_W{1'b0}};
                end else begin
                    for (starv_i = 0; starv_i < NUM_IN; starv_i = starv_i + 1) begin
                        if (!req_vec[starv_i] || gnt_vec[starv_i]) begin
                            starv_cnt[starv_i] <= {AGE_W{1'b0}};
                        end else if (starv_cnt[starv_i] != age_max_cfg) begin
                            starv_cnt[starv_i] <= starv_cnt[starv_i] + 1'b1;
                        end
                    end
                end
            end
        end else begin : gen_static_qos
            for (qos_g = 0; qos_g < NUM_IN; qos_g = qos_g + 1) begin : gen_eff_qos
                assign eff_qos_flat[qos_g*EFF_QOS_W +: EFF_QOS_W] =
                    {{AGE_W{1'b0}}, qos_flat[qos_g*QOS_W +: QOS_W]};
            end
        end
    endgenerate

    always @(*) begin
        qos_max  = {EFF_QOS_W{1'b0}};
        have_req = 1'b0;

        for (scan_i = 0; scan_i < NUM_IN; scan_i = scan_i + 1) begin
            scan_eff_qos = get_eff_qos(scan_i);

            if (req_vec[scan_i] && credit_ok[scan_i]) begin
                if (!have_req || (scan_eff_qos > qos_max)) begin
                    qos_max  = scan_eff_qos;
                    have_req = 1'b1;
                end
            end
        end
    end

    always @(*) begin
        gnt_vec     = {NUM_IN{1'b0}};
        grant_found = 1'b0;
        grant_idx   = 0;

        for (grant_k = 0; grant_k < NUM_IN; grant_k = grant_k + 1) begin
            grant_idx_scan = rr_ptr + grant_k;
            if (grant_idx_scan >= NUM_IN)
                grant_idx_scan = grant_idx_scan - NUM_IN;

            grant_eff_qos = get_eff_qos(grant_idx_scan);

            if (!grant_found && req_vec[grant_idx_scan] &&
                credit_ok[grant_idx_scan] && (grant_eff_qos == qos_max)) begin
                gnt_vec[grant_idx_scan] = 1'b1;
                grant_found  = 1'b1;
                grant_idx    = grant_idx_scan;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rr_ptr <= {PTR_W{1'b0}};
        end else begin
            if (grant_found) begin
                if (grant_idx == NUM_IN-1)
                    rr_ptr <= {PTR_W{1'b0}};
                else
                    rr_ptr <= grant_idx + 1;
            end
        end
    end
endmodule
