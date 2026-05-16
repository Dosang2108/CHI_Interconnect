`include "../common/chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_channel_slice
// Purpose: CHI interconnect RTL block.
// -----------------------------------------------------------------------------
module chi_channel_slice #(
    parameter NUM_IN     = `CHI_DEFAULT_NUM_RN,
    parameter NUM_OUT    = `CHI_DEFAULT_NUM_TGT,
    parameter FLIT_W     = 128,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter FIFO_DEPTH = `CHI_DEFAULT_FIFO_DEPTH
)(
    input                         clk,
    input                         rstn,
    input                         clear,
    input      [NUM_IN-1:0]       in_valid,
    output     [NUM_IN-1:0]       in_ready,
    input      [NUM_IN*FLIT_W-1:0] in_flit,
    output     [NUM_IN-1:0]       in_pop_pulse,
    input      [NUM_IN*NUM_OUT-1:0] route_onehot_flat,
    input      [NUM_IN*QOS_W-1:0] qos_flat,
    output     [NUM_OUT-1:0]      out_valid,
    input      [NUM_OUT-1:0]      out_ready,
    output     [NUM_OUT*FLIT_W-1:0] out_flit
);
    wire [NUM_IN-1:0]        buf_valid;
    wire [NUM_IN-1:0]        buf_ready;
    wire [NUM_IN*FLIT_W-1:0] buf_flit;
    wire [NUM_OUT-1:0]       xbar_valid;
    wire [NUM_OUT-1:0]       xbar_ready;
    wire [NUM_OUT*FLIT_W-1:0] xbar_flit;
    wire [NUM_OUT*NUM_IN-1:0] gnt_flat;

    genvar gi;
    genvar go;

    generate
        for (gi = 0; gi < NUM_IN; gi = gi + 1) begin : gen_input_buffer
            wire [15:0] unused_count;

            chi_input_buffer #(
                .FLIT_W(FLIT_W),
                .DEPTH(FIFO_DEPTH)
            ) u_input_buffer (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
                .in_valid(in_valid[gi]),
                .in_ready(in_ready[gi]),
                .in_flit(in_flit[gi*FLIT_W +: FLIT_W]),
                .out_valid(buf_valid[gi]),
                .out_ready(buf_ready[gi]),
                .out_flit(buf_flit[gi*FLIT_W +: FLIT_W]),
                .pop_pulse(in_pop_pulse[gi]),
                .used_count(unused_count)
            );
        end

        for (go = 0; go < NUM_OUT; go = go + 1) begin : gen_output_arbiter
            wire [NUM_IN-1:0] req_vec;
            wire [NUM_IN-1:0] gnt_vec;
            wire [NUM_IN-1:0] credit_ok;

            for (gi = 0; gi < NUM_IN; gi = gi + 1) begin : gen_req_vec
                assign req_vec[gi] = buf_valid[gi] && route_onehot_flat[gi*NUM_OUT + go];
            end

            assign credit_ok = {NUM_IN{xbar_ready[go]}};

            chi_output_arbiter #(
                .NUM_IN(NUM_IN),
                .QOS_W(QOS_W)
            ) u_output_arbiter (
                .clk(clk),
                .rstn(rstn),
                .req_vec(req_vec),
                .qos_flat(qos_flat),
                .credit_ok(credit_ok),
                .gnt_vec(gnt_vec)
            );

            assign gnt_flat[go*NUM_IN +: NUM_IN] = gnt_vec;
        end

        for (go = 0; go < NUM_OUT; go = go + 1) begin : gen_output_reg
            chi_output_reg #(
                .FLIT_W(FLIT_W)
            ) u_output_reg (
                .clk(clk),
                .rstn(rstn),
                .in_valid(xbar_valid[go]),
                .in_ready(xbar_ready[go]),
                .in_flit(xbar_flit[go*FLIT_W +: FLIT_W]),
                .out_valid(out_valid[go]),
                .out_ready(out_ready[go]),
                .out_flit(out_flit[go*FLIT_W +: FLIT_W])
            );
        end
    endgenerate

    chi_crossbar #(
        .NUM_IN(NUM_IN),
        .NUM_OUT(NUM_OUT),
        .FLIT_W(FLIT_W)
    ) u_crossbar (
        .in_valid(buf_valid),
        .in_ready(buf_ready),
        .in_flit(buf_flit),
        .gnt_flat(gnt_flat),
        .out_valid(xbar_valid),
        .out_ready(xbar_ready),
        .out_flit(xbar_flit)
    );
endmodule
