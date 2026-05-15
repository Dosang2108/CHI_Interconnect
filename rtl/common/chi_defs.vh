`ifndef CHI_DEFS_VH
`define CHI_DEFS_VH

// Default fabric parameters from the CHI MxN design spec.
`define CHI_DEFAULT_NUM_RN       2
`define CHI_DEFAULT_NUM_HN       3
`define CHI_DEFAULT_NUM_SN       1
`define CHI_DEFAULT_NUM_TGT      4
`define CHI_DEFAULT_ADDR_W       44
`define CHI_DEFAULT_DATA_W       128
`define CHI_DEFAULT_NODE_ID_W    7
`define CHI_DEFAULT_TXN_ID_W     12
`define CHI_DEFAULT_QOS_W        4
`define CHI_DEFAULT_DBID_W       12
`define CHI_DEFAULT_INIT_CRD     8
`define CHI_DEFAULT_FIFO_DEPTH   8
`define CHI_DEFAULT_STARV_THRESH 256

// Channel identifiers.
`define CHI_CH_REQ 2'd0
`define CHI_CH_RSP 2'd1
`define CHI_CH_SNP 2'd2
`define CHI_CH_DAT 2'd3

// Main REQ opcodes used by the skeleton RTL.
`define CHI_REQ_RD_NO_SNP     6'h04
`define CHI_REQ_RD_ONCE       6'h05
`define CHI_REQ_RD_SHARED     6'h06
`define CHI_REQ_RD_UNIQUE     6'h07
`define CHI_REQ_CLN_UNIQUE    6'h0B
`define CHI_REQ_MK_UNIQUE     6'h0E
`define CHI_REQ_EVICT         6'h12
`define CHI_REQ_WB_FULL       6'h18
`define CHI_REQ_WB_PTL        6'h19
`define CHI_REQ_WR_UNIQUE     6'h1A
`define CHI_REQ_WR_NO_SNP     6'h1C

// RSP opcodes.
`define CHI_RSP_DBID          4'h1
`define CHI_RSP_SNP_RESP      4'h2
`define CHI_RSP_COMP_ACK      4'h3
`define CHI_RSP_COMP          4'h4
`define CHI_RSP_COMP_DBID     4'h5

// SNP opcodes used by this first-pass skeleton.
`define CHI_SNP_SHARED        6'h01
`define CHI_SNP_UNIQUE        6'h02
`define CHI_SNP_INVALID       6'h03

// Response error encoding.
`define CHI_RESPERR_OK        2'b00
`define CHI_RESPERR_EXOKAY    2'b01
`define CHI_RESPERR_SLVERR    2'b10
`define CHI_RESPERR_DECERR    2'b11

// Simplified RN cache states.
`define CHI_STATE_I           3'd0
`define CHI_STATE_SC          3'd1
`define CHI_STATE_SD          3'd2
`define CHI_STATE_UC          3'd3
`define CHI_STATE_UD          3'd4

// Helpers for flattened flit widths.
// REQ lower fields keep the original skeleton layout. Attribute fields are
// appended above QoS so old extract code remains valid while the format grows.
`define CHI_REQ_W(ADDR_W,NODE_ID_W,TXN_ID_W,QOS_W) \
    ((ADDR_W) + 3 + 6 + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W) + (QOS_W) + \
     1 + 1 + 2 + (NODE_ID_W) + (TXN_ID_W))

`define CHI_SNP_W(ADDR_W,NODE_ID_W,TXN_ID_W,QOS_W) \
    ((ADDR_W) + 3 + 6 + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W) + (QOS_W))

`define CHI_RSP_W(NODE_ID_W,TXN_ID_W,QOS_W,DBID_W) \
    (3 + 2 + (DBID_W) + 4 + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W) + (QOS_W))

`define CHI_DAT_W(DATA_W,NODE_ID_W,TXN_ID_W,DBID_W) \
    (2 + ((DATA_W)/8) + (DATA_W) + 4 + (DBID_W) + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W) + 3)

// Flattened REQ field offsets.
`define CHI_REQ_ADDR_LSB                         0
`define CHI_REQ_SIZE_LSB(ADDR_W)                 ((ADDR_W))
`define CHI_REQ_OPCODE_LSB(ADDR_W)               ((ADDR_W) + 3)
`define CHI_REQ_TXN_LSB(ADDR_W)                  ((ADDR_W) + 3 + 6)
`define CHI_REQ_SRC_LSB(ADDR_W,TXN_ID_W)         ((ADDR_W) + 3 + 6 + (TXN_ID_W))
`define CHI_REQ_TGT_LSB(ADDR_W,TXN_ID_W,NODE_ID_W) \
    ((ADDR_W) + 3 + 6 + (TXN_ID_W) + (NODE_ID_W))
`define CHI_REQ_QOS_LSB(ADDR_W,TXN_ID_W,NODE_ID_W) \
    ((ADDR_W) + 3 + 6 + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W))
`define CHI_REQ_EXCL_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) \
    ((ADDR_W) + 3 + 6 + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W) + (QOS_W))
`define CHI_REQ_NS_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) \
    (`CHI_REQ_EXCL_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) + 1)
`define CHI_REQ_ORDER_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) \
    (`CHI_REQ_NS_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) + 1)
`define CHI_REQ_RET_NID_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) \
    (`CHI_REQ_ORDER_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) + 2)
`define CHI_REQ_RET_TXN_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) \
    (`CHI_REQ_RET_NID_LSB(ADDR_W,TXN_ID_W,NODE_ID_W,QOS_W) + (NODE_ID_W))

// Flattened SNP field offsets. SNP currently mirrors the base REQ layout.
`define CHI_SNP_ADDR_LSB                         0
`define CHI_SNP_SIZE_LSB(ADDR_W)                 ((ADDR_W))
`define CHI_SNP_OPCODE_LSB(ADDR_W)               ((ADDR_W) + 3)
`define CHI_SNP_TXN_LSB(ADDR_W)                  ((ADDR_W) + 3 + 6)
`define CHI_SNP_SRC_LSB(ADDR_W,TXN_ID_W)         ((ADDR_W) + 3 + 6 + (TXN_ID_W))
`define CHI_SNP_TGT_LSB(ADDR_W,TXN_ID_W,NODE_ID_W) \
    ((ADDR_W) + 3 + 6 + (TXN_ID_W) + (NODE_ID_W))
`define CHI_SNP_QOS_LSB(ADDR_W,TXN_ID_W,NODE_ID_W) \
    ((ADDR_W) + 3 + 6 + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W))

// Flattened RSP field offsets.
`define CHI_RSP_RESP_LSB                         0
`define CHI_RSP_RESPERR_LSB                      3
`define CHI_RSP_DBID_LSB                         5
`define CHI_RSP_OPCODE_LSB(DBID_W)               (5 + (DBID_W))
`define CHI_RSP_TXN_LSB(DBID_W)                  (5 + (DBID_W) + 4)
`define CHI_RSP_SRC_LSB(DBID_W,TXN_ID_W)         (5 + (DBID_W) + 4 + (TXN_ID_W))
`define CHI_RSP_TGT_LSB(DBID_W,TXN_ID_W,NODE_ID_W) \
    (5 + (DBID_W) + 4 + (TXN_ID_W) + (NODE_ID_W))
`define CHI_RSP_QOS_LSB(DBID_W,TXN_ID_W,NODE_ID_W) \
    (5 + (DBID_W) + 4 + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W))

// Flattened DAT field offsets.
`define CHI_DAT_RESPERR_LSB                      0
`define CHI_DAT_BE_LSB                           2
`define CHI_DAT_DATA_LSB(DATA_W)                 (2 + ((DATA_W)/8))
`define CHI_DAT_DATAID_LSB(DATA_W)               (2 + ((DATA_W)/8) + (DATA_W))
`define CHI_DAT_DBID_LSB(DATA_W)                 (2 + ((DATA_W)/8) + (DATA_W) + 4)
`define CHI_DAT_TXN_LSB(DATA_W,DBID_W)           (2 + ((DATA_W)/8) + (DATA_W) + 4 + (DBID_W))
`define CHI_DAT_SRC_LSB(DATA_W,DBID_W,TXN_ID_W)  (2 + ((DATA_W)/8) + (DATA_W) + 4 + (DBID_W) + (TXN_ID_W))
`define CHI_DAT_TGT_LSB(DATA_W,DBID_W,TXN_ID_W,NODE_ID_W) \
    (2 + ((DATA_W)/8) + (DATA_W) + 4 + (DBID_W) + (TXN_ID_W) + (NODE_ID_W))
`define CHI_DAT_RESP_LSB(DATA_W,DBID_W,TXN_ID_W,NODE_ID_W) \
    (2 + ((DATA_W)/8) + (DATA_W) + 4 + (DBID_W) + (TXN_ID_W) + (NODE_ID_W) + (NODE_ID_W))

`endif
