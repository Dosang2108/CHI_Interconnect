`include "chi_defs.vh"

module chi_addr_decoder #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NUM_TGT    = `CHI_DEFAULT_NUM_TGT,
    parameter TGT_ID_W   = 4,
    parameter HNF_PORT   = 0,
    parameter HNI_PORT   = 1,
    parameter MN_PORT    = 2,
    parameter SNF_PORT   = 3
)(
    input                    valid,
    input      [ADDR_WIDTH-1:0] addr,
    output reg [TGT_ID_W-1:0]   tgt_id,
    output reg [NUM_TGT-1:0]    tgt_onehot,
    output reg                  decode_error
);
    localparam [ADDR_WIDTH-1:0] HNI_BASE = 32'h8000_0000;
    localparam [ADDR_WIDTH-1:0] HNI_END  = 32'hBFFF_FFFF;
    localparam [ADDR_WIDTH-1:0] COH_BASE = 32'hC000_0000;
    localparam [ADDR_WIDTH-1:0] COH_END  = 32'hCFFF_FFFF;
    localparam [ADDR_WIDTH-1:0] MN_BASE  = 32'hFFF0_0000;
    localparam [ADDR_WIDTH-1:0] MN_END   = 32'hFFFF_FFFF;

    task set_target;
        input integer port_id;
        begin
            tgt_id = port_id;
            if (port_id < NUM_TGT)
                tgt_onehot[port_id] = 1'b1;
        end
    endtask

    always @(*) begin
        tgt_id       = {TGT_ID_W{1'b0}};
        tgt_onehot   = {NUM_TGT{1'b0}};
        decode_error = 1'b0;

        if (valid) begin
            if (addr <= 32'h7FFF_FFFF) begin
                set_target(HNF_PORT);
            end else if ((addr >= HNI_BASE) && (addr <= HNI_END)) begin
                set_target(HNI_PORT);
            end else if ((addr >= COH_BASE) && (addr <= COH_END)) begin
                set_target(HNF_PORT);
            end else if ((addr >= MN_BASE) && (addr <= MN_END)) begin
                set_target(MN_PORT);
            end else begin
                decode_error = 1'b1;
            end
        end
    end
endmodule
