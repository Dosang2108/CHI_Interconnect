`include "chi_defs.vh"

module chi_hn_mem_issuer #(
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W
)(
    input                    clk,
    input                    rstn,
    input                    req_valid,
    output                   req_ready,
    input      [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] req_flit,
    output                   mem_req_valid,
    input                    mem_req_ready,
    output     [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] mem_req_flit
);
    reg             valid_q;
    reg [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] flit_q;

    wire req_fire = req_valid && req_ready;
    wire mem_fire = mem_req_valid && mem_req_ready;

    assign req_ready     = !valid_q || mem_fire;
    assign mem_req_valid = valid_q;
    assign mem_req_flit  = flit_q;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_q <= 1'b0;
            flit_q  <= {`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W){1'b0}};
        end else begin
            if (req_fire) begin
                valid_q <= 1'b1;
                flit_q  <= req_flit;
            end else if (mem_fire) begin
                valid_q <= 1'b0;
            end
        end
    end
endmodule
