`include "chi_defs.vh"

module chi_route_decode #(
    parameter USE_ADDR    = 1,
    parameter ADDR_WIDTH  = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W   = `CHI_DEFAULT_NODE_ID_W,
    parameter NUM_OUT     = `CHI_DEFAULT_NUM_TGT,
    parameter ROUTE_ID_W  = 4
)(
    input                    valid,
    input      [ADDR_WIDTH-1:0] addr,
    input      [NODE_ID_W-1:0]  tgt_id,
    output reg [ROUTE_ID_W-1:0] route_id,
    output reg [NUM_OUT-1:0]    route_onehot,
    output reg                  route_error
);
    wire [ROUTE_ID_W-1:0] addr_route_id;
    wire [NUM_OUT-1:0]    addr_route_onehot;
    wire                  addr_decode_error;

    integer i;
    integer tgt_index;

    chi_addr_decoder #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_TGT(NUM_OUT),
        .TGT_ID_W(ROUTE_ID_W)
    ) u_addr_decoder (
        .valid(valid),
        .addr(addr),
        .tgt_id(addr_route_id),
        .tgt_onehot(addr_route_onehot),
        .decode_error(addr_decode_error)
    );

    always @(*) begin
        route_id     = {ROUTE_ID_W{1'b0}};
        route_onehot = {NUM_OUT{1'b0}};
        route_error  = 1'b0;
        tgt_index    = 0;

        if (USE_ADDR) begin
            route_id     = addr_route_id;
            route_onehot = addr_route_onehot;
            route_error  = addr_decode_error;
        end else if (valid) begin
            tgt_index = tgt_id;
            if (tgt_index < NUM_OUT) begin
                route_id = tgt_index;
                for (i = 0; i < NUM_OUT; i = i + 1) begin
                    route_onehot[i] = (i == tgt_index);
                end
            end else begin
                route_error = 1'b1;
            end
        end
    end
endmodule
