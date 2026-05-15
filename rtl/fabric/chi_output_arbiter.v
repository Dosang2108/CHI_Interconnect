`include "chi_defs.vh"

module chi_output_arbiter #(
    parameter NUM_IN       = `CHI_DEFAULT_NUM_RN,
    parameter QOS_W        = `CHI_DEFAULT_QOS_W,
    parameter STARV_THRESH = `CHI_DEFAULT_STARV_THRESH
)(
    input                    clk,
    input                    rstn,
    input      [NUM_IN-1:0]  req_vec,
    input      [NUM_IN*QOS_W-1:0] qos_flat,
    input      [NUM_IN-1:0]  credit_ok,
    output reg [NUM_IN-1:0]  gnt_vec
);
    function integer clog2;
        input integer value;
        integer i;
        begin
            value = value - 1;
            for (i = 0; value > 0; i = i + 1)
                value = value >> 1;
            clog2 = i;
        end
    endfunction

    function [QOS_W-1:0] get_qos;
        input integer idx;
        begin
            get_qos = qos_flat[idx*QOS_W +: QOS_W];
        end
    endfunction

    localparam PTR_W = (NUM_IN <= 2) ? 1 : clog2(NUM_IN);
    localparam [15:0] STARV_LIMIT = STARV_THRESH;

    reg [PTR_W-1:0] rr_ptr;
    reg [15:0]      starv_cnt [0:NUM_IN-1];
    reg [QOS_W-1:0] qos_max;
    reg [QOS_W-1:0] eff_qos;
    reg             have_req;
    reg             grant_found;
    integer         i;
    integer         k;
    integer         idx;
    integer         grant_idx;

    always @(*) begin
        qos_max  = {QOS_W{1'b0}};
        have_req = 1'b0;

        for (i = 0; i < NUM_IN; i = i + 1) begin
            eff_qos = get_qos(i);
            if ((starv_cnt[i] >= STARV_LIMIT) && (eff_qos != {QOS_W{1'b1}}))
                eff_qos = eff_qos + 1'b1;

            if (req_vec[i] && credit_ok[i]) begin
                if (!have_req || (eff_qos > qos_max)) begin
                    qos_max  = eff_qos;
                    have_req = 1'b1;
                end
            end
        end
    end

    always @(*) begin
        gnt_vec     = {NUM_IN{1'b0}};
        grant_found = 1'b0;
        grant_idx   = 0;

        for (k = 0; k < NUM_IN; k = k + 1) begin
            idx = rr_ptr + k;
            if (idx >= NUM_IN)
                idx = idx - NUM_IN;

            eff_qos = get_qos(idx);
            if ((starv_cnt[idx] >= STARV_LIMIT) && (eff_qos != {QOS_W{1'b1}}))
                eff_qos = eff_qos + 1'b1;

            if (!grant_found && req_vec[idx] && credit_ok[idx] && (eff_qos == qos_max)) begin
                gnt_vec[idx] = 1'b1;
                grant_found  = 1'b1;
                grant_idx    = idx;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rr_ptr <= {PTR_W{1'b0}};
            for (i = 0; i < NUM_IN; i = i + 1)
                starv_cnt[i] <= 16'd0;
        end else begin
            if (grant_found) begin
                if (grant_idx == NUM_IN-1)
                    rr_ptr <= {PTR_W{1'b0}};
                else
                    rr_ptr <= grant_idx + 1;
            end

            for (i = 0; i < NUM_IN; i = i + 1) begin
                if (!req_vec[i] || gnt_vec[i])
                    starv_cnt[i] <= 16'd0;
                else if (starv_cnt[i] != 16'hFFFF)
                    starv_cnt[i] <= starv_cnt[i] + 16'd1;
            end
        end
    end
endmodule
