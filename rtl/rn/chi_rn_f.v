`include "chi_defs.vh"

module chi_rn_f #(
    parameter NODE_ID    = 0,
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter TXN_TBL_SIZE = 64
)(
    input                    clk,
    input                    rstn,

    input                    cpu_req_valid,
    output                   cpu_req_ready,
    input      [ADDR_WIDTH-1:0] cpu_req_addr,
    input      [3:0]         cpu_req_op,
    input      [2:0]         cpu_req_size,
    input      [DATA_WIDTH-1:0] cpu_wdata,
    output     [DATA_WIDTH-1:0] cpu_rdata,
    output                   cpu_resp_valid,

    output                   tx_req_valid,
    output     [`CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] tx_req_flit,
    input                    tx_req_lcrdv,

    output                   tx_rsp_valid,
    output     [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] tx_rsp_flit,
    input                    tx_rsp_lcrdv,

    output                   tx_dat_valid,
    output     [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] tx_dat_flit,
    input                    tx_dat_lcrdv,

    input                    rx_rsp_valid,
    input      [`CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W)-1:0] rx_rsp_flit,
    output                   rx_rsp_lcrdv,

    input                    rx_snp_valid,
    input      [`CHI_SNP_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W)-1:0] rx_snp_flit,
    output                   rx_snp_lcrdv,

    input                    rx_dat_valid,
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] rx_dat_flit,
    output                   rx_dat_lcrdv
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

    localparam REQ_W = `CHI_REQ_W(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,QOS_W);
    localparam RSP_W = `CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W);
    localparam DAT_W = `CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W);
    localparam LINE_BYTES = 64;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam TXN_IDX_W = (TXN_TBL_SIZE <= 2) ? 1 : clog2(TXN_TBL_SIZE);

    wire [NODE_ID_W-1:0] node_id_wire;
    wire [NODE_ID_W-1:0] target_id;
    wire [3:0]           route_id_unused;
    wire [3:0]           route_onehot_unused;
    wire                 route_error_unused;
    wire [QOS_W-1:0]     qos_value;

    wire                 txn_alloc_valid;
    wire                 txn_alloc_ready;
    wire [TXN_ID_W-1:0]  txn_alloc_id;
    wire [5:0]           req_opcode;
    wire [REQ_W-1:0]     req_engine_flit;
    wire                 req_engine_valid;
    wire                 req_engine_ready;

    wire                 rsp_comp_valid;
    wire                 rsp_dbid_valid;
    wire                 rsp_dbid_match_valid;
    wire                 rsp_rx_ready;
    wire [TXN_ID_W-1:0]  rsp_txn_id;
    wire [DBID_W-1:0]    rsp_dbid;
    wire [NODE_ID_W-1:0] rsp_src_id;
    wire [1:0]           rsp_resp_err;

    wire                 dat_data_valid;
    wire [DATA_WIDTH-1:0] dat_data;
    wire [LINE_WIDTH-1:0] dat_line_data_unused;
    wire [TXN_ID_W-1:0]  dat_txn_id;
    wire [1:0]           dat_resp_err;
    wire [2:0]           dat_resp_unused;
    wire                 dat_line_valid_unused;
    wire [DATA_WIDTH-1:0] dat_line_cpu_data;
    wire                 dat_txn_match;
    wire                 selected_complete_valid;
    wire [TXN_ID_W-1:0]  selected_complete_txn_id;
    wire                 selected_complete_match_valid;

    wire                 snoop_rsp_valid;
    wire                 snoop_rsp_ready;
    wire [RSP_W-1:0]     snoop_rsp_flit;

    wire                 wdat_valid;
    wire                 wdat_engine_ready;
    wire                 wdata_ready_unused;
    wire [DAT_W-1:0]     wdat_flit;
    wire [LINE_WIDTH-1:0] cpu_wdata_line;
    wire [LINE_BYTES-1:0] cpu_wstrb_line;
    wire                 dbid_ready_unused;
    wire                 wdat_accept;
    wire                 txn_alloc_is_write;
    wire [TXN_IDX_W-1:0] txn_alloc_idx;
    wire [TXN_IDX_W-1:0] rsp_txn_idx;
    wire [3:0]           tx_req_credit_unused;
    wire [3:0]           tx_rsp_credit_unused;
    wire [3:0]           tx_dat_credit_unused;
    wire                 timeout_valid_unused;
    wire [TXN_ID_W-1:0]  timeout_txn_id_unused;
    wire [15:0]          outstanding_count_unused;
    wire                 table_full_unused;

    reg [LINE_WIDTH-1:0] wdata_line_mem [0:TXN_TBL_SIZE-1];
    reg [LINE_BYTES-1:0] wstrb_line_mem [0:TXN_TBL_SIZE-1];
    reg [TXN_TBL_SIZE-1:0] wdata_valid_mem;
    reg                  pending_wdat_valid_q;
    reg [TXN_ID_W-1:0]   pending_wdat_txn_q;
    reg [DBID_W-1:0]     pending_wdat_dbid_q;
    reg [NODE_ID_W-1:0]  pending_wdat_src_q;
    reg [LINE_WIDTH-1:0] pending_wdat_data_q;
    reg [LINE_BYTES-1:0] pending_wdat_strb_q;
    integer              wdata_idx;

    assign node_id_wire = NODE_ID;
    assign qos_value    = {QOS_W{1'b0}};
    assign cpu_rdata    = dat_line_valid_unused ?
                          dat_line_cpu_data :
                          dat_data;
    assign cpu_resp_valid = (rsp_comp_valid && selected_complete_match_valid) ||
                            (dat_line_valid_unused && dat_txn_match);
    assign selected_complete_valid = rsp_comp_valid || dat_line_valid_unused;
    assign selected_complete_txn_id = rsp_comp_valid ? rsp_txn_id : dat_txn_id;
    assign rsp_rx_ready = !pending_wdat_valid_q || wdat_accept;
    assign wdat_accept = pending_wdat_valid_q &&
                         dbid_ready_unused &&
                         wdata_ready_unused;
    assign txn_alloc_is_write = (req_opcode == `CHI_REQ_WR_UNIQUE) ||
                                (req_opcode == `CHI_REQ_WR_NO_SNP) ||
                                (req_opcode == `CHI_REQ_WB_FULL) ||
                                (req_opcode == `CHI_REQ_WB_PTL);
    assign txn_alloc_idx = txn_alloc_id[TXN_IDX_W-1:0];
    assign rsp_txn_idx = rsp_txn_id[TXN_IDX_W-1:0];

    generate
        if (DATA_WIDTH <= LINE_WIDTH) begin : gen_rdata_truncate
            assign dat_line_cpu_data = dat_line_data_unused[DATA_WIDTH-1:0];
        end else begin : gen_rdata_extend
            assign dat_line_cpu_data = {{(DATA_WIDTH-LINE_WIDTH){1'b0}},
                                        dat_line_data_unused};
        end

        if (DATA_WIDTH >= LINE_WIDTH) begin : gen_wdata_truncate
            assign cpu_wdata_line = cpu_wdata[LINE_WIDTH-1:0];
        end else begin : gen_wdata_extend
            assign cpu_wdata_line = {{(LINE_WIDTH-DATA_WIDTH){1'b0}}, cpu_wdata};
        end

        if ((DATA_WIDTH/8) >= LINE_BYTES) begin : gen_wstrb_truncate
            assign cpu_wstrb_line = {(LINE_BYTES){1'b1}};
        end else begin : gen_wstrb_extend
            assign cpu_wstrb_line = {{(LINE_BYTES-(DATA_WIDTH/8)){1'b0}},
                                     {(DATA_WIDTH/8){1'b1}}};
        end
    endgenerate

    chi_addr_decoder #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_TGT(4),
        .TGT_ID_W(NODE_ID_W)
    ) u_addr_decoder (
        .valid(cpu_req_valid),
        .addr(cpu_req_addr),
        .tgt_id(target_id),
        .tgt_onehot(route_onehot_unused),
        .decode_error(route_error_unused)
    );

    chi_rn_txn_tracker #(
        .TXN_ID_W(TXN_ID_W),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DBID_W(DBID_W),
        .TXN_TBL_SIZE(TXN_TBL_SIZE)
    ) u_txn_tracker (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .alloc_valid(txn_alloc_valid),
        .alloc_ready(txn_alloc_ready),
        .alloc_txn_id(txn_alloc_id),
        .alloc_opcode(req_opcode),
        .alloc_addr(cpu_req_addr),
        .dbid_update_valid(rsp_dbid_valid),
        .dbid_update_txn_id(rsp_txn_id),
        .dbid_update_value(rsp_dbid),
        .dbid_match_valid(rsp_dbid_match_valid),
        .complete_valid(selected_complete_valid),
        .complete_txn_id(selected_complete_txn_id),
        .complete_match_valid(selected_complete_match_valid),
        .lookup_valid(dat_data_valid),
        .lookup_txn_id(dat_txn_id),
        .lookup_match(dat_txn_match),
        .timeout_valid(timeout_valid_unused),
        .timeout_txn_id(timeout_txn_id_unused),
        .outstanding_count(outstanding_count_unused),
        .table_full(table_full_unused)
    );

    chi_rn_req_engine #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W)
    ) u_req_engine (
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_op(cpu_req_op),
        .cpu_req_size(cpu_req_size),
        .qos_value(qos_value),
        .node_id(node_id_wire),
        .target_id(target_id),
        .txn_alloc_valid(txn_alloc_valid),
        .txn_alloc_ready(txn_alloc_ready),
        .txn_alloc_id(txn_alloc_id),
        .tx_req_valid(req_engine_valid),
        .tx_req_ready(req_engine_ready),
        .tx_req_flit(req_engine_flit),
        .tx_req_opcode(req_opcode)
    );

    chi_link_layer #(
        .FLIT_W(REQ_W),
        .INIT_CREDIT(INIT_CRD)
    ) u_tx_req_link (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .tx_in_valid(req_engine_valid),
        .tx_in_ready(req_engine_ready),
        .tx_in_flit(req_engine_flit),
        .tx_out_valid(tx_req_valid),
        .tx_out_flit(tx_req_flit),
        .tx_out_lcrdv(tx_req_lcrdv),
        .rx_in_valid(1'b0),
        .rx_in_flit({REQ_W{1'b0}}),
        .rx_in_lcrdv(),
        .rx_out_valid(),
        .rx_out_ready(1'b1),
        .rx_out_flit(),
        .credit_count(tx_req_credit_unused)
    );

    chi_rn_rsp_rx #(
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W)
    ) u_rsp_rx (
        .clk(clk),
        .rstn(rstn),
        .rx_rsp_valid(rx_rsp_valid),
        .rx_rsp_flit(rx_rsp_flit),
        .rx_rsp_lcrdv(rx_rsp_lcrdv),
        .rsp_ready(rsp_rx_ready),
        .comp_valid(rsp_comp_valid),
        .dbid_valid(rsp_dbid_valid),
        .rsp_txn_id(rsp_txn_id),
        .rsp_dbid(rsp_dbid),
        .rsp_src_id(rsp_src_id),
        .rsp_resp_err(rsp_resp_err)
    );

    chi_rn_dat_rx #(
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES)
    ) u_dat_rx (
        .clk(clk),
        .rstn(rstn),
        .rx_dat_valid(rx_dat_valid),
        .rx_dat_flit(rx_dat_flit),
        .rx_dat_lcrdv(rx_dat_lcrdv),
        .data_valid(dat_data_valid),
        .data(dat_data),
        .txn_id(dat_txn_id),
        .resp_err(dat_resp_err),
        .resp(dat_resp_unused),
        .line_valid(dat_line_valid_unused),
        .line_data(dat_line_data_unused)
    );

    chi_rn_snoop_handler #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W)
    ) u_snoop_handler (
        .rx_snp_valid(rx_snp_valid),
        .rx_snp_flit(rx_snp_flit),
        .rx_snp_lcrdv(rx_snp_lcrdv),
        .node_id(node_id_wire),
        .tx_rsp_valid(snoop_rsp_valid),
        .tx_rsp_ready(snoop_rsp_ready),
        .tx_rsp_flit(snoop_rsp_flit)
    );

    chi_link_layer #(
        .FLIT_W(RSP_W),
        .INIT_CREDIT(INIT_CRD)
    ) u_tx_rsp_link (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .tx_in_valid(snoop_rsp_valid),
        .tx_in_ready(snoop_rsp_ready),
        .tx_in_flit(snoop_rsp_flit),
        .tx_out_valid(tx_rsp_valid),
        .tx_out_flit(tx_rsp_flit),
        .tx_out_lcrdv(tx_rsp_lcrdv),
        .rx_in_valid(1'b0),
        .rx_in_flit({RSP_W{1'b0}}),
        .rx_in_lcrdv(),
        .rx_out_valid(),
        .rx_out_ready(1'b1),
        .rx_out_flit(),
        .credit_count(tx_rsp_credit_unused)
    );

    chi_rn_wdat_engine #(
        .DATA_WIDTH(DATA_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .DBID_W(DBID_W),
        .LINE_BYTES(LINE_BYTES)
    ) u_wdat_engine (
        .clk(clk),
        .rstn(rstn),
        .dbid_valid(pending_wdat_valid_q),
        .dbid_ready(dbid_ready_unused),
        .dbid_txn_id(pending_wdat_txn_q),
        .dbid_value(pending_wdat_dbid_q),
        .dbid_src_id(pending_wdat_src_q),
        .wdata_valid(pending_wdat_valid_q),
        .wdata_ready(wdata_ready_unused),
        .wdata(pending_wdat_data_q),
        .wstrb(pending_wdat_strb_q),
        .node_id(node_id_wire),
        .tx_dat_valid(wdat_valid),
        .tx_dat_ready(wdat_engine_ready),
        .tx_dat_flit(wdat_flit)
    );

    chi_link_layer #(
        .FLIT_W(DAT_W),
        .INIT_CREDIT(INIT_CRD)
    ) u_tx_dat_link (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .tx_in_valid(wdat_valid),
        .tx_in_ready(wdat_engine_ready),
        .tx_in_flit(wdat_flit),
        .tx_out_valid(tx_dat_valid),
        .tx_out_flit(tx_dat_flit),
        .tx_out_lcrdv(tx_dat_lcrdv),
        .rx_in_valid(1'b0),
        .rx_in_flit({DAT_W{1'b0}}),
        .rx_in_lcrdv(),
        .rx_out_valid(),
        .rx_out_ready(1'b1),
        .rx_out_flit(),
        .credit_count(tx_dat_credit_unused)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wdata_valid_mem      <= {TXN_TBL_SIZE{1'b0}};
            pending_wdat_valid_q <= 1'b0;
            pending_wdat_txn_q   <= {TXN_ID_W{1'b0}};
            pending_wdat_dbid_q  <= {DBID_W{1'b0}};
            pending_wdat_src_q   <= {NODE_ID_W{1'b0}};
            pending_wdat_data_q  <= {LINE_WIDTH{1'b0}};
            pending_wdat_strb_q  <= {LINE_BYTES{1'b0}};
            for (wdata_idx = 0; wdata_idx < TXN_TBL_SIZE; wdata_idx = wdata_idx + 1) begin
                wdata_line_mem[wdata_idx] <= {LINE_WIDTH{1'b0}};
                wstrb_line_mem[wdata_idx] <= {LINE_BYTES{1'b0}};
            end
        end else begin
            if (wdat_accept)
                pending_wdat_valid_q <= 1'b0;

            if (txn_alloc_valid) begin
                if (txn_alloc_is_write) begin
                    wdata_line_mem[txn_alloc_idx] <= cpu_wdata_line;
                    wstrb_line_mem[txn_alloc_idx] <= cpu_wstrb_line;
                    wdata_valid_mem[txn_alloc_idx] <= 1'b1;
                end else begin
                    wdata_valid_mem[txn_alloc_idx] <= 1'b0;
                end
            end

            if (selected_complete_match_valid)
                wdata_valid_mem[selected_complete_txn_id[TXN_IDX_W-1:0]] <= 1'b0;

            if (rsp_dbid_match_valid && wdata_valid_mem[rsp_txn_idx]) begin
                pending_wdat_valid_q <= 1'b1;
                pending_wdat_txn_q   <= rsp_txn_id;
                pending_wdat_dbid_q  <= rsp_dbid;
                pending_wdat_src_q   <= rsp_src_id;
                pending_wdat_data_q  <= wdata_line_mem[rsp_txn_idx];
                pending_wdat_strb_q  <= wstrb_line_mem[rsp_txn_idx];
                wdata_valid_mem[rsp_txn_idx] <= 1'b0;
            end
        end
    end
endmodule
