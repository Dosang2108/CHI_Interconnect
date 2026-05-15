`include "chi_defs.vh"

module chi_crossbar #(
    parameter NUM_IN  = `CHI_DEFAULT_NUM_RN,
    parameter NUM_OUT = `CHI_DEFAULT_NUM_TGT,
    parameter FLIT_W  = 128
)(
    input      [NUM_IN-1:0]        in_valid,
    output reg [NUM_IN-1:0]        in_ready,
    input      [NUM_IN*FLIT_W-1:0] in_flit,
    input      [NUM_OUT*NUM_IN-1:0] gnt_flat,
    output reg [NUM_OUT-1:0]       out_valid,
    input      [NUM_OUT-1:0]       out_ready,
    output reg [NUM_OUT*FLIT_W-1:0] out_flit
);
    integer i;
    integer o;
    integer assert_i;
    integer assert_o;
    integer assert_grant_count;
    reg [NUM_IN-1:0] input_has_grant;
    reg [NUM_IN-1:0] input_all_ready;

    always @(*) begin
        in_ready  = {NUM_IN{1'b0}};
        out_valid = {NUM_OUT{1'b0}};
        out_flit  = {NUM_OUT*FLIT_W{1'b0}};
        input_has_grant  = {NUM_IN{1'b0}};
        input_all_ready  = {NUM_IN{1'b1}};

        for (i = 0; i < NUM_IN; i = i + 1) begin
            for (o = 0; o < NUM_OUT; o = o + 1) begin
                if (gnt_flat[o*NUM_IN + i]) begin
                    input_has_grant[i] = 1'b1;
                    if (!out_ready[o])
                        input_all_ready[i] = 1'b0;
                end
            end
            in_ready[i] = input_has_grant[i] && input_all_ready[i];
        end

        for (o = 0; o < NUM_OUT; o = o + 1) begin
            for (i = 0; i < NUM_IN; i = i + 1) begin
                if (gnt_flat[o*NUM_IN + i]) begin
                    out_valid[o] = in_valid[i] && input_all_ready[i];
                    out_flit[o*FLIT_W +: FLIT_W] = in_flit[i*FLIT_W +: FLIT_W];
                end
            end
        end
    end

    // synthesis translate_off
    always @(*) begin
        for (assert_o = 0; assert_o < NUM_OUT; assert_o = assert_o + 1) begin
            assert_grant_count = 0;
            for (assert_i = 0; assert_i < NUM_IN; assert_i = assert_i + 1) begin
                if (gnt_flat[assert_o*NUM_IN + assert_i])
                    assert_grant_count = assert_grant_count + 1;
            end

            if (assert_grant_count > 1) begin
                $display("chi_crossbar grant conflict on output %0d", assert_o);
                $stop;
            end
        end
    end
    // synthesis translate_on
endmodule
