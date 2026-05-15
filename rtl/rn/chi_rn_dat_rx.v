`include "chi_defs.vh"

module chi_rn_dat_rx #(
    parameter DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    parameter NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter LINE_BYTES = 64,
    parameter LINE_BUF_ENTRIES = 8
)(
    input                    clk,
    input                    rstn,
    input                    rx_dat_valid,
    input      [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] rx_dat_flit,
    output                   rx_dat_lcrdv,
    output                   data_valid,
    output     [DATA_WIDTH-1:0] data,
    output     [TXN_ID_W-1:0] txn_id,
    output     [1:0]         resp_err,
    output     [2:0]         resp,
    output                   line_valid,
    output     [LINE_BYTES*8-1:0] line_data
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

    localparam BE_W = DATA_WIDTH / 8;
    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam BEATS = LINE_BYTES / BE_W;
    localparam ENTRY_W = (LINE_BUF_ENTRIES <= 2) ? 1 : clog2(LINE_BUF_ENTRIES);

    localparam DAT_RESPERR_LSB = `CHI_DAT_RESPERR_LSB;
    localparam DAT_BE_LSB      = `CHI_DAT_BE_LSB;
    localparam DAT_DATA_LSB    = `CHI_DAT_DATA_LSB(DATA_WIDTH);
    localparam DAT_DATAID_LSB  = `CHI_DAT_DATAID_LSB(DATA_WIDTH);
    localparam DAT_DBID_LSB    = `CHI_DAT_DBID_LSB(DATA_WIDTH);
    localparam DAT_TXN_LSB     = `CHI_DAT_TXN_LSB(DATA_WIDTH,DBID_W);
    localparam DAT_SRC_LSB     = `CHI_DAT_SRC_LSB(DATA_WIDTH,DBID_W,TXN_ID_W);
    localparam DAT_TGT_LSB     = `CHI_DAT_TGT_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);
    localparam DAT_RESP_LSB    = `CHI_DAT_RESP_LSB(DATA_WIDTH,DBID_W,TXN_ID_W,NODE_ID_W);

    wire                 dat_in_ready;
    wire                 dat_valid_buf;
    wire [`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)-1:0] dat_flit_buf;
    wire [15:0]          dat_used_unused;
    wire [3:0]           data_id = dat_flit_buf[DAT_DATAID_LSB +: 4];
    wire                 data_id_in_range = (data_id < BEATS);
    wire [DATA_WIDTH-1:0] flit_data = dat_flit_buf[DAT_DATA_LSB +: DATA_WIDTH];
    wire [TXN_ID_W-1:0]  flit_txn_id = dat_flit_buf[DAT_TXN_LSB +: TXN_ID_W];
    wire [1:0]           flit_resp_err = dat_flit_buf[DAT_RESPERR_LSB +: 2];
    wire [2:0]           flit_resp = dat_flit_buf[DAT_RESP_LSB +: 3];

    reg                  entry_valid_q [0:LINE_BUF_ENTRIES-1];
    reg [TXN_ID_W-1:0]   entry_txn_id_q [0:LINE_BUF_ENTRIES-1];
    reg [LINE_WIDTH-1:0] entry_data_q [0:LINE_BUF_ENTRIES-1];
    reg [BEATS-1:0]      entry_mask_q [0:LINE_BUF_ENTRIES-1];

    reg                  match_valid;
    reg [ENTRY_W-1:0]    match_idx;
    reg                  free_valid;
    reg [ENTRY_W-1:0]    free_idx;
    reg                  target_valid;
    reg [ENTRY_W-1:0]    target_idx;
    reg [LINE_WIDTH-1:0] selected_data;
    reg [BEATS-1:0]      selected_mask;
    reg [LINE_WIDTH-1:0] updated_data;
    reg [BEATS-1:0]      updated_mask;
    integer              scan_i;
    integer              reset_i;

    wire dat_consume_ready;
    wire rx_fire;
    wire line_complete_next;

    always @(*) begin
        match_valid = 1'b0;
        match_idx = {ENTRY_W{1'b0}};
        free_valid = 1'b0;
        free_idx = {ENTRY_W{1'b0}};

        for (scan_i = 0; scan_i < LINE_BUF_ENTRIES; scan_i = scan_i + 1) begin
            if (!match_valid && entry_valid_q[scan_i] &&
                (entry_txn_id_q[scan_i] == flit_txn_id)) begin
                match_valid = 1'b1;
                match_idx = scan_i[ENTRY_W-1:0];
            end

            if (!free_valid && !entry_valid_q[scan_i]) begin
                free_valid = 1'b1;
                free_idx = scan_i[ENTRY_W-1:0];
            end
        end
    end

    always @(*) begin
        target_valid = match_valid || free_valid;
        target_idx = match_valid ? match_idx : free_idx;
        selected_data = {LINE_WIDTH{1'b0}};
        selected_mask = {BEATS{1'b0}};

        if (match_valid) begin
            selected_data = entry_data_q[match_idx];
            selected_mask = entry_mask_q[match_idx];
        end
    end

    always @(*) begin
        updated_data = selected_data;
        updated_mask = selected_mask;
        if (dat_valid_buf && target_valid && data_id_in_range) begin
            updated_data[data_id*DATA_WIDTH +: DATA_WIDTH] = flit_data;
            updated_mask[data_id] = 1'b1;
        end
    end

    assign dat_consume_ready = !dat_valid_buf ||
                               (target_valid && data_id_in_range);
    assign rx_fire = dat_valid_buf && dat_consume_ready;
    assign line_complete_next = rx_fire && (&updated_mask);

    assign rx_dat_lcrdv = rx_dat_valid && dat_in_ready;
    assign data_valid   = rx_fire;
    assign data         = flit_data;
    assign txn_id       = flit_txn_id;
    assign resp_err     = flit_resp_err;
    assign resp         = flit_resp;
    assign line_valid   = line_complete_next;
    assign line_data    = updated_data;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (reset_i = 0; reset_i < LINE_BUF_ENTRIES; reset_i = reset_i + 1) begin
                entry_valid_q[reset_i] <= 1'b0;
                entry_txn_id_q[reset_i] <= {TXN_ID_W{1'b0}};
                entry_data_q[reset_i] <= {LINE_WIDTH{1'b0}};
                entry_mask_q[reset_i] <= {BEATS{1'b0}};
            end
        end else if (rx_fire) begin
            entry_txn_id_q[target_idx] <= flit_txn_id;
            entry_data_q[target_idx] <= updated_data;
            if (line_complete_next) begin
                entry_valid_q[target_idx] <= 1'b0;
                entry_mask_q[target_idx] <= {BEATS{1'b0}};
            end else begin
                entry_valid_q[target_idx] <= 1'b1;
                entry_mask_q[target_idx] <= updated_mask;
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn && dat_valid_buf && !data_id_in_range) begin
            $display("chi_rn_dat_rx invalid DataID %0d", data_id);
            $stop;
        end
    end
    // synthesis translate_on

    chi_fifo #(
        .WIDTH(`CHI_DAT_W(DATA_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W)),
        .DEPTH(2)
    ) u_dat_fifo (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .in_valid(rx_dat_valid),
        .in_ready(dat_in_ready),
        .in_data(rx_dat_flit),
        .out_valid(dat_valid_buf),
        .out_ready(dat_consume_ready),
        .out_data(dat_flit_buf),
        .used_count(dat_used_unused)
    );
endmodule
