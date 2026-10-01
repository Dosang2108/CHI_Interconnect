`include "chi_defs.vh"
// -----------------------------------------------------------------------------
// Module: chi_channel_slice
// Purpose: One CHI fabric channel slice. It combines per-input buffering,
//          one-hot routing, crossbar arbitration, and per-output elasticity.
// -----------------------------------------------------------------------------
module chi_channel_slice #(
    parameter NUM_IN     = `CHI_DEFAULT_NUM_RN,
    parameter NUM_OUT    = `CHI_DEFAULT_NUM_TGT,
    parameter FLIT_W     = 128,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter FIFO_DEPTH = `CHI_DEFAULT_FIFO_DEPTH,
    parameter OUTPUT_FIFO_DEPTH = `CHI_DEFAULT_OUTPUT_FIFO_DEPTH,
    parameter ENABLE_QOS_AGING = `CHI_DEFAULT_ENABLE_QOS_AGING
)(
    input                         clk,
    input                         rstn,
    output                   busy,
    input                         clear,
    input      [NUM_IN-1:0]       in_valid,
    output     [NUM_IN-1:0]       in_ready,
    input      [NUM_IN*FLIT_W-1:0] in_flit,
    output     [NUM_IN-1:0]       in_pop_pulse,
    input      [NUM_IN*NUM_OUT-1:0] route_onehot_flat,
    input      [NUM_IN*QOS_W-1:0] qos_flat,
    input      [7:0]               cfg_qos_age_shift,
    input      [7:0]               cfg_qos_age_max,
    output     [NUM_OUT-1:0]      out_valid,
    input      [NUM_OUT-1:0]      out_ready,
    output     [NUM_OUT*FLIT_W-1:0] out_flit
);
    localparam BUF_W = FLIT_W + NUM_OUT + QOS_W;

    wire [NUM_IN-1:0]        buf_valid;
    wire [NUM_IN-1:0]        buf_ready;
    wire [NUM_IN*FLIT_W-1:0] buf_flit;
    wire [NUM_IN*NUM_OUT-1:0] buf_route_onehot_flat;
    wire [NUM_IN*QOS_W-1:0]  buf_qos_flat;
    wire [NUM_IN*BUF_W-1:0]  buf_payload_in;
    wire [NUM_IN*BUF_W-1:0]  buf_payload_out;
    wire [NUM_OUT-1:0]       xbar_valid;
    wire [NUM_OUT-1:0]       xbar_ready;
    wire [NUM_OUT*FLIT_W-1:0] xbar_flit;
    wire [NUM_OUT*NUM_IN-1:0] gnt_flat;

    genvar gi;
    genvar go;

    generate
        for (gi = 0; gi < NUM_IN; gi = gi + 1) begin : gen_input_buffer
            wire [15:0] unused_count;

            assign buf_payload_in[gi*BUF_W +: BUF_W] = {
                qos_flat[gi*QOS_W +: QOS_W],
                route_onehot_flat[gi*NUM_OUT +: NUM_OUT],
                in_flit[gi*FLIT_W +: FLIT_W]
            };
            assign buf_flit[gi*FLIT_W +: FLIT_W] =
                buf_payload_out[gi*BUF_W +: FLIT_W];
            assign buf_route_onehot_flat[gi*NUM_OUT +: NUM_OUT] =
                buf_payload_out[gi*BUF_W + FLIT_W +: NUM_OUT];
            assign buf_qos_flat[gi*QOS_W +: QOS_W] =
                buf_payload_out[gi*BUF_W + FLIT_W + NUM_OUT +: QOS_W];

            chi_input_buffer #(
                .FLIT_W(BUF_W),
                .DEPTH(FIFO_DEPTH)
            ) u_input_buffer (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
                .in_valid(in_valid[gi]),
                .in_ready(in_ready[gi]),
                .in_flit(buf_payload_in[gi*BUF_W +: BUF_W]),
                .out_valid(buf_valid[gi]),
                .out_ready(buf_ready[gi]),
                .out_flit(buf_payload_out[gi*BUF_W +: BUF_W]),
                .pop_pulse(in_pop_pulse[gi]),
                .used_count(unused_count)
            );
        end

        for (go = 0; go < NUM_OUT; go = go + 1) begin : gen_output_arbiter
            wire [NUM_IN-1:0] req_vec;
            wire [NUM_IN-1:0] gnt_vec;
            wire [NUM_IN-1:0] credit_ok;

            for (gi = 0; gi < NUM_IN; gi = gi + 1) begin : gen_req_vec
                assign req_vec[gi] = buf_valid[gi] &&
                                     buf_route_onehot_flat[gi*NUM_OUT + go];
            end

            assign credit_ok = {NUM_IN{xbar_ready[go]}};

            chi_output_arbiter #(
                .NUM_IN(NUM_IN),
                .QOS_W(QOS_W),
                .ENABLE_QOS_AGING(ENABLE_QOS_AGING)
            ) u_output_arbiter (
                .clk(clk),
                .rstn(rstn),
                .req_vec(req_vec),
                .qos_flat(buf_qos_flat),
                .credit_ok(credit_ok),
                .cfg_qos_age_shift(cfg_qos_age_shift),
                .cfg_qos_age_max(cfg_qos_age_max),
                .gnt_vec(gnt_vec)
            );

            assign gnt_flat[go*NUM_IN +: NUM_IN] = gnt_vec;
        end

        for (go = 0; go < NUM_OUT; go = go + 1) begin : gen_output_reg
            chi_output_reg #(
                .FLIT_W(FLIT_W),
                .FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
            ) u_output_reg (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
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

    // A flit is held in an input buffer or an output register.
    assign busy = (|buf_valid) || (|out_valid);
endmodule
