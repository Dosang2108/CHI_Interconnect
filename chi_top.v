`include "chi_defs.vh"

// -----------------------------------------------------------------------------
// Module: chi_top
// Purpose: Top-level CHI MxN fabric wrapper. Instantiates RN/HN/SN/MN nodes,
//          address-based routing, CSR control, error IRQ, and channel fabrics.
// -----------------------------------------------------------------------------
module chi_top #(
    parameter integer NUM_RN     = `CHI_DEFAULT_NUM_RN,
    parameter integer NUM_HN     = `CHI_DEFAULT_NUM_HN,
    parameter integer NUM_SN     = `CHI_DEFAULT_NUM_SN,
    parameter integer NUM_MN     = `CHI_DEFAULT_NUM_MN,
    // CPU word and SN AXI width.
    parameter integer DATA_WIDTH = `CHI_DEFAULT_DATA_W,
    // CHI DAT channel data width (128/256/512).
    parameter integer DAT_DATA_W = `CHI_DEFAULT_DAT_DATA_W,
    parameter integer ADDR_WIDTH = `CHI_DEFAULT_ADDR_W,
    parameter integer NODE_ID_W  = `CHI_DEFAULT_NODE_ID_W,
    parameter integer TXN_ID_W   = `CHI_DEFAULT_TXN_ID_W,
    parameter integer QOS_W      = `CHI_DEFAULT_QOS_W,
    parameter integer DBID_W     = `CHI_DEFAULT_DBID_W,
    parameter integer CPU_TAG_W  = 2,
    parameter integer INIT_CRD   = `CHI_DEFAULT_INIT_CRD,
    parameter integer HN_POS_DEPTH = `CHI_DEFAULT_POS_DEPTH,
    parameter integer HN_SF_ENTRIES = `CHI_DEFAULT_SF_ENTRIES,
    parameter integer HN_LLC_LINES = `CHI_DEFAULT_LLC_LINES,
    parameter integer HN_LLC_WAYS = `CHI_DEFAULT_LLC_WAYS,
    parameter integer HN_WRITE_TRACKER_DEPTH = `CHI_DEFAULT_HN_WRITE_TRACKER_DEPTH,
    parameter integer HN_READ_TRACKER_DEPTH = `CHI_DEFAULT_HN_READ_TRACKER_DEPTH,
    parameter integer HN_SNOOP_TRACKER_DEPTH = `CHI_DEFAULT_HN_SNOOP_TRACKER_DEPTH,
    parameter integer HN_NUM_SLOTS = 2,
    parameter integer RN_CACHE_LINES = `CHI_DEFAULT_RN_CACHE_LINES,
    parameter integer RN_TXN_TBL_SIZE = `CHI_DEFAULT_RN_TXN_TBL_SIZE,
    parameter integer RN_TIMEOUT_CYCLES = 1024,
    // 0 (default): node timeouts are watchdogs that set ERR_STATUS[4]/IRQ
    // and never complete a transaction. 1: legacy functional timeouts.
    parameter integer FUNCTIONAL_TIMEOUT = 0,
    parameter integer FABRIC_FIFO_DEPTH = `CHI_DEFAULT_FIFO_DEPTH,
    parameter integer ENABLE_PERF = `CHI_DEFAULT_ENABLE_PERF,
    parameter integer HN_ENABLE_LLC_ECC = `CHI_DEFAULT_ENABLE_LLC_ECC,
    parameter integer FABRIC_OUTPUT_FIFO_DEPTH = `CHI_DEFAULT_OUTPUT_FIFO_DEPTH,
    parameter integer ENABLE_QOS_AGING = `CHI_DEFAULT_ENABLE_QOS_AGING,
    // Idle cycles before the links are deactivated (only with the clock gate
    // enabled); the fabric clock stops once every link is in STOP.
    parameter integer LINK_IDLE_CYCLES = 4,
    parameter integer USE_EXTERNAL_L1_SNOOP = 0,
    parameter integer EXTERNAL_L1_WRITE_THROUGH_NO_ALLOCATE = USE_EXTERNAL_L1_SNOOP
)(
    input                         clk,
    input                         rstn,

    input                         csr_valid,
    input                         csr_write,
    input      [7:0]              csr_addr,
    input      [63:0]             csr_wdata,
    output                        csr_ready,
    output     [63:0]             csr_rdata,
    output                        chi_irq,

    input      [NUM_RN-1:0]       cpu_req_valid,
    output     [NUM_RN-1:0]       cpu_req_ready,
    input      [NUM_RN*ADDR_WIDTH-1:0] cpu_req_addr,
    input      [NUM_RN*4-1:0]     cpu_req_op,
    input      [NUM_RN*3-1:0]     cpu_req_size,
    input      [NUM_RN*QOS_W-1:0] cpu_req_qos,
    input      [NUM_RN*CPU_TAG_W-1:0] cpu_req_tag,
    input      [NUM_RN*DATA_WIDTH-1:0] cpu_wdata,
    input      [NUM_RN*64*8-1:0]  cpu_wdata_line,
    input      [NUM_RN*64-1:0]    cpu_wstrb_line,
    output     [NUM_RN*DATA_WIDTH-1:0] cpu_rdata,
    output     [NUM_RN-1:0]       cpu_resp_valid,
    output     [NUM_RN*CPU_TAG_W-1:0] cpu_resp_tag,
    output     [NUM_RN-1:0]       cpu_resp_line_valid,
    output     [NUM_RN*64*8-1:0]  cpu_resp_line_data,
    output     [NUM_RN*CPU_TAG_W-1:0] cpu_resp_line_tag,

    output     [NUM_RN-1:0]       l1_snoop_valid,
    input      [NUM_RN-1:0]       l1_snoop_ready,
    output     [NUM_RN-1:0]       l1_snoop_invalidate,
    output     [NUM_RN*ADDR_WIDTH-1:0] l1_snoop_addr,
    input      [NUM_RN-1:0]       l1_snoop_result_valid,
    input      [NUM_RN-1:0]       l1_snoop_hit,
    input      [NUM_RN-1:0]       l1_snoop_dirty,
    input      [NUM_RN*64*8-1:0]  l1_snoop_data,

    output     [NUM_SN-1:0]       axi_arvalid,
    input      [NUM_SN-1:0]       axi_arready,
    output     [NUM_SN*ADDR_WIDTH-1:0] axi_araddr,
    output     [NUM_SN*3-1:0]     axi_arsize,
    output     [NUM_SN*8-1:0]     axi_arlen,
    output     [NUM_SN*2-1:0]     axi_arburst,
    input      [NUM_SN-1:0]       axi_rvalid,
    output     [NUM_SN-1:0]       axi_rready,
    input      [NUM_SN*DATA_WIDTH-1:0] axi_rdata,
    input      [NUM_SN*2-1:0]     axi_rresp,

    output     [NUM_SN-1:0]       axi_awvalid,
    input      [NUM_SN-1:0]       axi_awready,
    output     [NUM_SN*ADDR_WIDTH-1:0] axi_awaddr,
    output     [NUM_SN*3-1:0]     axi_awsize,
    output     [NUM_SN*8-1:0]     axi_awlen,
    output     [NUM_SN*2-1:0]     axi_awburst,
    output     [NUM_SN-1:0]       axi_wvalid,
    input      [NUM_SN-1:0]       axi_wready,
    output     [NUM_SN*DATA_WIDTH-1:0] axi_wdata,
    output     [NUM_SN*(DATA_WIDTH/8)-1:0] axi_wstrb,
    output     [NUM_SN-1:0]       axi_wlast,
    input      [NUM_SN-1:0]       axi_bvalid,
    output     [NUM_SN-1:0]       axi_bready,
    input      [NUM_SN*2-1:0]     axi_bresp
);
    `CHI_FLIT_PARAM_CHECK(ADDR_WIDTH,NODE_ID_W,TXN_ID_W,DBID_W,QOS_W,DAT_DATA_W)
    localparam NUM_NODES   = NUM_RN + NUM_HN + NUM_SN + NUM_MN;
    localparam NUM_REQ_SRC = NUM_RN + NUM_HN;
    localparam NUM_REQ_TGT = NUM_HN + NUM_SN + NUM_MN;
    localparam NUM_SNP_SRC = NUM_HN + NUM_MN;
    localparam integer RN_BASE_ID = 0;
    localparam integer HN_BASE_ID = NUM_RN;
    localparam integer SN_BASE_ID = NUM_RN + NUM_HN;
    localparam integer MN_BASE_ID = NUM_RN + NUM_HN + NUM_SN;

    localparam REQ_W   = `CHI_REQ_W(NODE_ID_W);
    localparam RSP_W   = `CHI_RSP_W(NODE_ID_W);
    localparam SNP_W   = `CHI_SNP_W(NODE_ID_W);
    localparam DAT_W   = `CHI_DAT_W(DAT_DATA_W,NODE_ID_W);

    localparam REQ_ADDR_LSB = `CHI_REQ_ADDR_LSB(NODE_ID_W);
    localparam REQ_TGT_LSB  = `CHI_REQ_TGT_LSB(NODE_ID_W);
    localparam REQ_QOS_LSB  = `CHI_REQ_QOS_LSB(NODE_ID_W);
    localparam RSP_TGT_LSB  = `CHI_RSP_TGT_LSB(NODE_ID_W);
    localparam RSP_QOS_LSB  = `CHI_RSP_QOS_LSB(NODE_ID_W);
    localparam SNP_QOS_LSB  = `CHI_SNP_QOS_LSB(NODE_ID_W);
    localparam DAT_TGT_LSB  = `CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W);
    localparam DAT_QOS_LSB  = `CHI_DAT_QOS_LSB(DAT_DATA_W,NODE_ID_W);
    localparam REQ_OPC_LSB  = `CHI_REQ_OPCODE_LSB(NODE_ID_W);
    localparam RSP_OPC_LSB  = `CHI_RSP_OPCODE_LSB(NODE_ID_W);
    localparam SNP_OPC_LSB  = `CHI_SNP_OPCODE_LSB(NODE_ID_W);
    localparam DAT_OPC_LSB  = `CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W);
    localparam REQ_OPC_W    = `CHI_REQ_OPCODE_W;
    localparam RSP_OPC_W    = `CHI_RSP_OPCODE_W;
    localparam SNP_OPC_W    = `CHI_SNP_OPCODE_W;
    localparam DAT_OPC_W    = 4;

    wire [NUM_REQ_SRC*QOS_W-1:0] req_qos_flat;
    wire [NUM_NODES*QOS_W-1:0]   rsp_qos_flat;
    wire [NUM_NODES*QOS_W-1:0]   dat_qos_flat;
    wire [NUM_SNP_SRC*QOS_W-1:0] snp_qos_flat;
    wire                         cfg_region_valid;
    wire [ADDR_WIDTH-1:0]        cfg_hnf_base;
    wire [ADDR_WIDTH-1:0]        cfg_hnf_end;
    wire [ADDR_WIDTH-1:0]        cfg_snf_base;
    wire [ADDR_WIDTH-1:0]        cfg_snf_end;
    wire [ADDR_WIDTH-1:0]        cfg_mn_base;
    wire [ADDR_WIDTH-1:0]        cfg_mn_end;
    wire                         cfg_dvm_enable;
    wire                         cfg_cg_enable;
    wire [15:0]                  cfg_excl_timeout;
    wire [15:0]                  cfg_mn_drain_cycles;
    wire [7:0]                   cfg_qos_age_shift;
    wire [7:0]                   cfg_qos_age_max;
    wire                         csr_bist_init_pulse;
    wire                         chi_cg_en;
    wire                         clk_int;
    wire                         fabric_clear;

    wire [NUM_RN-1:0]        rn_tx_req_valid;
    wire [NUM_RN-1:0]        rn_tx_req_flitv;
    wire [NUM_RN-1:0]        rn_tx_req_lcrdv;
    wire [NUM_RN*REQ_W-1:0]  rn_tx_req_flit;
    wire [NUM_RN-1:0]        rn_tx_rsp_valid;
    wire [NUM_RN-1:0]        rn_tx_rsp_flitv;
    wire [NUM_RN-1:0]        rn_tx_rsp_lcrdv;
    wire [NUM_RN*RSP_W-1:0]  rn_tx_rsp_flit;
    wire [NUM_RN-1:0]        rn_tx_dat_valid;
    wire [NUM_RN-1:0]        rn_tx_dat_flitv;
    wire [NUM_RN-1:0]        rn_tx_dat_lcrdv;
    wire [NUM_RN*DAT_W-1:0]  rn_tx_dat_flit;
    wire [NUM_RN*16*32-1:0]  rn_perf_counts_flat;
    wire [NUM_RN-1:0]        rn_cache_parity_error_event;

    wire [NUM_RN-1:0]        rn_rx_rsp_lcrdv_unused;
    wire [NUM_RN-1:0]        rn_rx_snp_lcrdv_unused;
    wire [NUM_RN-1:0]        rn_rx_dat_lcrdv_unused;
    wire [NUM_RN-1:0]        rn_rx_rsp_ready;
    wire [NUM_RN-1:0]        rn_rx_snp_ready;
    wire [NUM_RN-1:0]        rn_rx_dat_ready;

    wire [NUM_HN-1:0]        hn_rx_req_lcrdv_unused;
    wire [NUM_HN-1:0]        hn_rx_dat_lcrdv_unused;
    wire [NUM_HN-1:0]        hn_rx_rsp_lcrdv_unused;
    wire [NUM_HN-1:0]        hn_rx_req_ready;
    wire [NUM_HN-1:0]        hn_rx_dat_ready;
    wire [NUM_HN-1:0]        hn_rx_rsp_ready;
    wire [NUM_HN-1:0]        hn_tx_rsp_valid;
    wire [NUM_HN-1:0]        hn_tx_rsp_flitv;
    wire [NUM_HN-1:0]        hn_tx_rsp_lcrdv;
    wire [NUM_HN*RSP_W-1:0]  hn_tx_rsp_flit;
    wire [NUM_HN-1:0]        hn_tx_snp_valid;
    wire [NUM_HN-1:0]        hn_tx_snp_flitv;
    wire [NUM_HN-1:0]        hn_tx_snp_lcrdv;
    wire [NUM_HN*SNP_W-1:0]  hn_tx_snp_flit;
    wire [NUM_HN*NODE_ID_W-1:0] hn_tx_snp_tgt_id;
    wire [NUM_HN-1:0]        hn_tx_dat_valid;
    wire [NUM_HN-1:0]        hn_tx_dat_flitv;
    wire [NUM_HN-1:0]        hn_tx_dat_lcrdv;
    wire [NUM_HN*DAT_W-1:0]  hn_tx_dat_flit;
    wire [NUM_HN-1:0]        hn_tx_req_valid;
    wire [NUM_HN-1:0]        hn_tx_req_flitv;
    wire [NUM_HN-1:0]        hn_tx_req_lcrdv;
    wire [NUM_HN*REQ_W-1:0]  hn_tx_req_flit;
    wire [NUM_HN*16*32-1:0]  hn_perf_counts_flat;
    wire [NUM_HN-1:0]        hn_ecc_single_event;
    wire [NUM_HN-1:0]        hn_ecc_double_event;
    wire [NUM_HN-1:0]        hn_exclusive_fail_event;
    wire [NUM_HN-1:0]        hn_watchdog_event;
    wire [NUM_RN-1:0]        rn_watchdog_event;
    wire [NUM_MN-1:0]        mn_watchdog_event;
    wire [NUM_RN-1:0]        rn_busy;
    wire [NUM_HN-1:0]        hn_busy;
    wire [NUM_SN-1:0]        sn_busy;
    wire [NUM_MN-1:0]        mn_busy;
    wire                     fabric_busy;
    wire                     chi_busy;
    wire                     bist_reject_event;

    // Protocol-layer activity (B14.7). TXSACTIVE of a node is its busy
    // flag. RXSACTIVE of a node is the interconnect side of its interface:
    // work in the fabric, in a receive buffer or in any other node.
    wire [NUM_NODES-1:0]     node_txsactive;
    wire [NUM_NODES-1:0]     node_rxsactive;

    // System coherency (B15): one SYSCOREQ/SYSCOACK pair per RN.
    wire [NUM_RN-1:0]        cfg_sysco_connect;
    wire [NUM_RN-1:0]        rn_sysco_connect;
    wire [NUM_RN-1:0]        rn_syscoreq;
    reg  [NUM_RN-1:0]        rn_syscoack;
    wire [NUM_HN*NUM_RN-1:0] hn_sysco_quiet;
    wire [((NUM_MN == 0) ? 1 : NUM_MN)*NUM_RN-1:0] mn_sysco_quiet;
    reg  [NUM_RN-1:0]        sysco_quiet_r;
    integer                  sysco_i;

    wire [NUM_SN-1:0]        sn_rx_req_lcrdv_unused;
    wire [NUM_SN-1:0]        sn_rx_dat_lcrdv_unused;
    wire [NUM_SN-1:0]        sn_rx_req_ready;
    wire [NUM_SN-1:0]        sn_rx_dat_ready;
    wire [NUM_SN-1:0]        sn_tx_rsp_valid;
    wire [NUM_SN-1:0]        sn_tx_rsp_flitv;
    wire [NUM_SN-1:0]        sn_tx_rsp_lcrdv;
    wire [NUM_SN*RSP_W-1:0]  sn_tx_rsp_flit;
    wire [NUM_SN-1:0]        sn_tx_dat_valid;
    wire [NUM_SN-1:0]        sn_tx_dat_flitv;
    wire [NUM_SN-1:0]        sn_tx_dat_lcrdv;
    wire [NUM_SN*DAT_W-1:0]  sn_tx_dat_flit;

    wire [NUM_MN-1:0]        mn_rx_req_lcrdv_unused;
    wire [NUM_MN-1:0]        mn_rx_rsp_lcrdv_unused;
    wire [NUM_MN-1:0]        mn_rx_req_ready;
    wire [NUM_MN-1:0]        mn_rx_rsp_ready;
    wire [NUM_MN-1:0]        mn_rx_dat_ready;
    wire [NUM_MN-1:0]        mn_tx_rsp_valid;
    wire [NUM_MN-1:0]        mn_tx_rsp_flitv;
    wire [NUM_MN-1:0]        mn_tx_rsp_lcrdv;
    wire [NUM_MN*RSP_W-1:0]  mn_tx_rsp_flit;
    wire [NUM_MN-1:0]        mn_tx_snp_valid;
    wire [NUM_MN-1:0]        mn_tx_snp_flitv;
    wire [NUM_MN-1:0]        mn_tx_snp_lcrdv;
    wire [NUM_MN*SNP_W-1:0]  mn_tx_snp_flit;
    wire [NUM_MN*NODE_ID_W-1:0] mn_tx_snp_tgt_id;

    wire [NUM_REQ_SRC-1:0]        req_src_valid;
    wire [NUM_REQ_SRC-1:0]        req_src_ready;
    wire [NUM_REQ_SRC-1:0]        req_src_pop_pulse;
    wire [NUM_REQ_SRC*REQ_W-1:0]  req_src_flit;
    wire [NUM_REQ_SRC*NUM_REQ_TGT-1:0] req_route_onehot;
    wire [NUM_REQ_TGT-1:0]        req_tgt_valid;
    wire [NUM_REQ_TGT-1:0]        req_tgt_ready;
    wire [NUM_REQ_TGT*REQ_W-1:0]  req_tgt_flit;

    wire [NUM_NODES-1:0]        rsp_node_in_valid;
    wire [NUM_NODES-1:0]        rsp_node_in_ready;
    wire [NUM_NODES-1:0]        rsp_node_in_pop_pulse;
    wire [NUM_NODES*RSP_W-1:0]  rsp_node_in_flit;
    wire [NUM_NODES*NUM_NODES-1:0] rsp_route_onehot;
    wire [NUM_NODES-1:0]        rsp_node_out_valid;
    wire [NUM_NODES-1:0]        rsp_node_out_ready;
    wire [NUM_NODES*RSP_W-1:0]  rsp_node_out_flit;

    wire [NUM_NODES-1:0]        dat_node_in_valid;
    wire [NUM_NODES-1:0]        dat_node_in_ready;
    wire [NUM_NODES-1:0]        dat_node_in_pop_pulse;
    wire [NUM_NODES*DAT_W-1:0]  dat_node_in_flit;
    wire [NUM_NODES*NUM_NODES-1:0] dat_route_onehot;
    wire [NUM_NODES-1:0]        dat_node_out_valid;
    wire [NUM_NODES-1:0]        dat_node_out_ready;
    wire [NUM_NODES*DAT_W-1:0]  dat_node_out_flit;

    wire [NUM_SNP_SRC-1:0]   snp_src_valid;
    wire [NUM_SNP_SRC-1:0]   snp_src_ready;
    wire [NUM_SNP_SRC-1:0]   snp_src_pop_pulse;
    wire [NUM_SNP_SRC*SNP_W-1:0] snp_src_flit;
    wire [NUM_SNP_SRC*NUM_RN-1:0] snp_route_onehot;
    wire [NUM_RN-1:0]        snp_rn_out_valid;
    wire [NUM_RN-1:0]        snp_rn_out_ready;
    wire [NUM_RN*SNP_W-1:0]  snp_rn_out_flit;

    // L-Credit return at every node<->fabric link (B14.2.1). *_src_lcrdv /
    // *_in_lcrdv: the fabric returns a credit to the transmitting node;
    // *_tgt_lcrdv / *_out_lcrdv: the receiving node returns one to the
    // fabric. The link credit checker taps these together with the matching
    // valid (FLITV).
    //
    // Node -> fabric: each node transmits only with an L-Credit. The fabric
    // input FIFO of each link grants one credit per free entry, all
    // FABRIC_FIFO_DEPTH of them after reset and one more each time the FIFO
    // pops (chi_link_lcrd_gen), so a flit never finds the FIFO full.
    // Fabric -> node: each fabric output holds a credit counter for its node
    // (chi_link_tx_crd, credits start at 0) and pops its output register only
    // with a credit and the link in RUN. The node's receive side is a
    // chi_link_rx at the node boundary: an INIT_CRD-deep fall-through FIFO
    // that grants one credit per free entry and returns it when the node
    // takes the flit. The node ports (*_rx_*) stay valid/ready.
    // FLITPEND of every link, for the link checker.
    wire [NUM_REQ_SRC-1:0]   req_src_flitpend;
    wire [NUM_NODES-1:0]     rsp_node_in_flitpend;
    wire [NUM_NODES-1:0]     dat_node_in_flitpend;
    wire [NUM_SNP_SRC-1:0]   snp_src_flitpend;
    wire [NUM_REQ_TGT-1:0]   req_tgt_flitpend;
    wire [NUM_NODES-1:0]     rsp_node_out_flitpend;
    wire [NUM_NODES-1:0]     dat_node_out_flitpend;
    wire [NUM_RN-1:0]        snp_rn_out_flitpend;
    wire [NUM_REQ_SRC-1:0]   req_src_lcrdv;
    wire [NUM_NODES-1:0]     rsp_node_in_lcrdv;
    wire [NUM_NODES-1:0]     dat_node_in_lcrdv;
    wire [NUM_SNP_SRC-1:0]   snp_src_lcrdv;
    wire [NUM_REQ_TGT-1:0]   req_tgt_lcrdv;
    wire [NUM_NODES-1:0]     rsp_node_out_lcrdv;
    wire [NUM_NODES-1:0]     dat_node_out_lcrdv;
    wire [NUM_RN-1:0]        snp_rn_out_lcrdv;

    // FLITV of every link, LCrdReturn flits included, and those return
    // flits on their own. A return flit only gives its credit back
    // (B14.5.1): node -> fabric it stops before the fabric (the *_valid of a
    // node and of a fabric input is FLITV without it), fabric -> node
    // chi_link_rx drops it.
    wire [NUM_REQ_SRC-1:0]   req_src_flitv;
    wire [NUM_NODES-1:0]     rsp_node_in_flitv;
    wire [NUM_NODES-1:0]     dat_node_in_flitv;
    wire [NUM_SNP_SRC-1:0]   snp_src_flitv;
    wire [NUM_REQ_SRC-1:0]   req_src_ret;
    wire [NUM_NODES-1:0]     rsp_node_in_ret;
    wire [NUM_NODES-1:0]     dat_node_in_ret;
    wire [NUM_SNP_SRC-1:0]   snp_src_ret;
    wire [NUM_REQ_TGT-1:0]   req_tgt_flitv;
    wire [NUM_NODES-1:0]     rsp_node_out_flitv;
    wire [NUM_NODES-1:0]     dat_node_out_flitv;
    wire [NUM_RN-1:0]        snp_rn_out_flitv;
    wire [NUM_REQ_TGT*REQ_W-1:0] req_tgt_link_flit;
    wire [NUM_NODES*RSP_W-1:0]   rsp_node_out_link_flit;
    wire [NUM_NODES*DAT_W-1:0]   dat_node_out_link_flit;
    wire [NUM_RN*SNP_W-1:0]      snp_rn_out_link_flit;
    // FLITPEND of the fabric outputs, before the credit returns are added.
    wire [NUM_REQ_TGT-1:0]   req_tgt_pend;
    wire [NUM_NODES-1:0]     rsp_node_out_pend;
    wire [NUM_NODES-1:0]     dat_node_out_pend;
    wire [NUM_RN-1:0]        snp_rn_out_pend;

    // Link activation (B14.5.1). Every node has a transmit link (node ->
    // fabric, all the channels the node sends on) and a receive link
    // (fabric -> node). The transmitter of a link drives LINKACTIVEREQ and
    // its receiver LINKACTIVEACK; one pair covers all channels of the link.
    //   node_tx_*: the node transmits (chi_link_active_tx inside the node);
    //              the fabric side acknowledges and grants the credits.
    //   node_rx_*: the fabric side transmits; the node's receive buffers
    //              (chi_link_rx) acknowledge and grant the credits.
    // *_home: every credit granted on that channel is back at its receiver.
    wire                     link_want;
    wire                     links_stopped;
    wire [NUM_NODES-1:0]     node_tx_lareq;
    wire [NUM_NODES-1:0]     node_tx_laack;
    wire [NUM_NODES-1:0]     node_tx_grant_en;
    wire [NUM_NODES-1:0]     node_rx_lareq;
    wire [NUM_NODES-1:0]     node_rx_laack;
    wire [NUM_NODES-1:0]     node_rx_grant_en;
    wire [NUM_NODES-1:0]     node_rx_run;
    wire [NUM_NODES-1:0]     node_rx_deact;
    // node_tx_* by SNP source, for the link checker.
    wire [NUM_SNP_SRC-1:0]   snp_src_lareq;
    wire [NUM_SNP_SRC-1:0]   snp_src_laack;
    wire [NUM_REQ_SRC-1:0]   req_src_home;
    wire [NUM_NODES-1:0]     rsp_node_in_home;
    wire [NUM_NODES-1:0]     dat_node_in_home;
    wire [NUM_SNP_SRC-1:0]   snp_src_home;
    wire [NUM_REQ_TGT-1:0]   req_tgt_home;
    wire [NUM_NODES-1:0]     rsp_node_out_home;
    wire [NUM_NODES-1:0]     dat_node_out_home;
    wire [NUM_RN-1:0]        snp_rn_out_home;

    // Node side of the fabric -> node links.
    wire [NUM_REQ_TGT-1:0]       req_tgt_rx_valid;
    wire [NUM_REQ_TGT-1:0]       req_tgt_rx_ready;
    wire [NUM_REQ_TGT*REQ_W-1:0] req_tgt_rx_flit;
    wire [NUM_NODES-1:0]         rsp_node_rx_valid;
    wire [NUM_NODES-1:0]         rsp_node_rx_ready;
    wire [NUM_NODES*RSP_W-1:0]   rsp_node_rx_flit;
    wire [NUM_NODES-1:0]         dat_node_rx_valid;
    wire [NUM_NODES-1:0]         dat_node_rx_ready;
    wire [NUM_NODES*DAT_W-1:0]   dat_node_rx_flit;
    wire [NUM_RN-1:0]            snp_rn_rx_valid;
    wire [NUM_RN-1:0]            snp_rn_rx_ready;
    wire [NUM_RN*SNP_W-1:0]      snp_rn_rx_flit;
    wire [NUM_REQ_TGT-1:0]       req_tgt_rx_overflow;
    wire [NUM_NODES-1:0]         rsp_node_rx_overflow;
    wire [NUM_NODES-1:0]         dat_node_rx_overflow;
    wire [NUM_RN-1:0]            snp_rn_rx_overflow;
    // A flit is waiting in a node receive buffer.
    wire                         link_rx_busy = (|req_tgt_rx_valid) ||
                                                (|rsp_node_rx_valid) ||
                                                (|dat_node_rx_valid) ||
                                                (|snp_rn_rx_valid);

    genvar gl;
    generate
        // Node -> fabric links: the fabric input FIFO is the receive buffer.
        // REQ source gl is node gl (RNs, then HNs).
        for (gl = 0; gl < NUM_REQ_SRC; gl = gl + 1) begin : gen_req_in_lcrd
            chi_link_lcrd_gen #(.DEPTH(FABRIC_FIFO_DEPTH)) u_lcrd (
                .clk(clk_int), .rstn(rstn), .grant_en(node_tx_grant_en[gl]),
                .pop(req_src_pop_pulse[gl]), .flit(req_src_flitv[gl]), .ret(req_src_ret[gl]),
                .lcrdv(req_src_lcrdv[gl]), .owed(), .home(req_src_home[gl]));
        end
        for (gl = 0; gl < NUM_NODES; gl = gl + 1) begin : gen_rsp_in_lcrd
            chi_link_lcrd_gen #(.DEPTH(FABRIC_FIFO_DEPTH)) u_lcrd (
                .clk(clk_int), .rstn(rstn), .grant_en(node_tx_grant_en[gl]),
                .pop(rsp_node_in_pop_pulse[gl]), .flit(rsp_node_in_flitv[gl]), .ret(rsp_node_in_ret[gl]),
                .lcrdv(rsp_node_in_lcrdv[gl]), .owed(), .home(rsp_node_in_home[gl]));
        end
        // An MN has no DAT transmitter, so nothing would return its credits.
        for (gl = 0; gl < NUM_NODES; gl = gl + 1) begin : gen_dat_in_lcrd
            chi_link_lcrd_gen #(.DEPTH(FABRIC_FIFO_DEPTH)) u_lcrd (
                .clk(clk_int), .rstn(rstn), .grant_en((gl < MN_BASE_ID) && node_tx_grant_en[gl]),
                .pop(dat_node_in_pop_pulse[gl]), .flit(dat_node_in_flitv[gl]), .ret(dat_node_in_ret[gl]),
                .lcrdv(dat_node_in_lcrdv[gl]), .owed(), .home(dat_node_in_home[gl]));
        end
        for (gl = 0; gl < NUM_SNP_SRC; gl = gl + 1) begin : gen_snp_in_lcrd
            localparam integer NODE = (gl < NUM_HN) ? (HN_BASE_ID + gl) :
                                                      (MN_BASE_ID + gl - NUM_HN);
            assign snp_src_lareq[gl] = node_tx_lareq[NODE];
            assign snp_src_laack[gl] = node_tx_laack[NODE];
            chi_link_lcrd_gen #(.DEPTH(FABRIC_FIFO_DEPTH)) u_lcrd (
                .clk(clk_int), .rstn(rstn), .grant_en(node_tx_grant_en[NODE]),
                .pop(snp_src_pop_pulse[gl]), .flit(snp_src_flitv[gl]), .ret(snp_src_ret[gl]),
                .lcrdv(snp_src_lcrdv[gl]), .owed(), .home(snp_src_home[gl]));
        end

        // Fabric -> node links. REQ target gl is node HN_BASE_ID + gl (HNs,
        // SNs, then MNs).
        for (gl = 0; gl < NUM_REQ_TGT; gl = gl + 1) begin : gen_req_out_link
            localparam integer NODE = HN_BASE_ID + gl;
            chi_link_tx_crd #(
                .FLIT_W(REQ_W)
            ) u_tx (
                .clk(clk_int), .rstn(rstn),
                .link_run(node_rx_run[NODE]), .link_deact(node_rx_deact[NODE]),
                .in_valid(req_tgt_valid[gl]), .in_ready(req_tgt_ready[gl]),
                .in_flit(req_tgt_flit[gl*REQ_W +: REQ_W]), .in_pend(req_tgt_pend[gl]),
                .flitpend(req_tgt_flitpend[gl]), .flitv(req_tgt_flitv[gl]),
                .flit(req_tgt_link_flit[gl*REQ_W +: REQ_W]),
                .lcrdv(req_tgt_lcrdv[gl]), .credit_count());
            chi_link_rx #(
                .FLIT_W(REQ_W), .DEPTH(INIT_CRD), .FALLTHROUGH(1),
                .OPC_LSB(REQ_OPC_LSB), .OPC_W(REQ_OPC_W)
            ) u_rx (
                .clk(clk_int), .rstn(rstn), .clear(1'b0), .grant_en(node_rx_grant_en[NODE]),
                .flitv(req_tgt_flitv[gl]), .flit(req_tgt_link_flit[gl*REQ_W +: REQ_W]),
                .lcrdv(req_tgt_lcrdv[gl]), .home(req_tgt_home[gl]),
                .out_valid(req_tgt_rx_valid[gl]), .out_ready(req_tgt_rx_ready[gl]),
                .out_flit(req_tgt_rx_flit[gl*REQ_W +: REQ_W]), .overflow(req_tgt_rx_overflow[gl]));
        end
        for (gl = 0; gl < NUM_NODES; gl = gl + 1) begin : gen_rsp_out_link
            localparam integer NODE = gl;
            chi_link_tx_crd #(
                .FLIT_W(RSP_W)
            ) u_tx (
                .clk(clk_int), .rstn(rstn),
                .link_run(node_rx_run[NODE]), .link_deact(node_rx_deact[NODE]),
                .in_valid(rsp_node_out_valid[gl]), .in_ready(rsp_node_out_ready[gl]),
                .in_flit(rsp_node_out_flit[gl*RSP_W +: RSP_W]), .in_pend(rsp_node_out_pend[gl]),
                .flitpend(rsp_node_out_flitpend[gl]), .flitv(rsp_node_out_flitv[gl]),
                .flit(rsp_node_out_link_flit[gl*RSP_W +: RSP_W]),
                .lcrdv(rsp_node_out_lcrdv[gl]), .credit_count());
            chi_link_rx #(
                .FLIT_W(RSP_W), .DEPTH(INIT_CRD), .FALLTHROUGH(1),
                .OPC_LSB(RSP_OPC_LSB), .OPC_W(RSP_OPC_W)
            ) u_rx (
                .clk(clk_int), .rstn(rstn), .clear(1'b0), .grant_en(node_rx_grant_en[NODE]),
                .flitv(rsp_node_out_flitv[gl]), .flit(rsp_node_out_link_flit[gl*RSP_W +: RSP_W]),
                .lcrdv(rsp_node_out_lcrdv[gl]), .home(rsp_node_out_home[gl]),
                .out_valid(rsp_node_rx_valid[gl]), .out_ready(rsp_node_rx_ready[gl]),
                .out_flit(rsp_node_rx_flit[gl*RSP_W +: RSP_W]), .overflow(rsp_node_rx_overflow[gl]));
        end
        for (gl = 0; gl < NUM_NODES; gl = gl + 1) begin : gen_dat_out_link
            localparam integer NODE = gl;
            chi_link_tx_crd #(
                .FLIT_W(DAT_W)
            ) u_tx (
                .clk(clk_int), .rstn(rstn),
                .link_run(node_rx_run[NODE]), .link_deact(node_rx_deact[NODE]),
                .in_valid(dat_node_out_valid[gl]), .in_ready(dat_node_out_ready[gl]),
                .in_flit(dat_node_out_flit[gl*DAT_W +: DAT_W]), .in_pend(dat_node_out_pend[gl]),
                .flitpend(dat_node_out_flitpend[gl]), .flitv(dat_node_out_flitv[gl]),
                .flit(dat_node_out_link_flit[gl*DAT_W +: DAT_W]),
                .lcrdv(dat_node_out_lcrdv[gl]), .credit_count());
            chi_link_rx #(
                .FLIT_W(DAT_W), .DEPTH(INIT_CRD), .FALLTHROUGH(1),
                .OPC_LSB(DAT_OPC_LSB), .OPC_W(DAT_OPC_W)
            ) u_rx (
                .clk(clk_int), .rstn(rstn), .clear(1'b0), .grant_en(node_rx_grant_en[NODE]),
                .flitv(dat_node_out_flitv[gl]), .flit(dat_node_out_link_flit[gl*DAT_W +: DAT_W]),
                .lcrdv(dat_node_out_lcrdv[gl]), .home(dat_node_out_home[gl]),
                .out_valid(dat_node_rx_valid[gl]), .out_ready(dat_node_rx_ready[gl]),
                .out_flit(dat_node_rx_flit[gl*DAT_W +: DAT_W]), .overflow(dat_node_rx_overflow[gl]));
        end
        for (gl = 0; gl < NUM_RN; gl = gl + 1) begin : gen_snp_out_link
            localparam integer NODE = gl;
            chi_link_tx_crd #(
                .FLIT_W(SNP_W)
            ) u_tx (
                .clk(clk_int), .rstn(rstn),
                .link_run(node_rx_run[NODE]), .link_deact(node_rx_deact[NODE]),
                .in_valid(snp_rn_out_valid[gl]), .in_ready(snp_rn_out_ready[gl]),
                .in_flit(snp_rn_out_flit[gl*SNP_W +: SNP_W]), .in_pend(snp_rn_out_pend[gl]),
                .flitpend(snp_rn_out_flitpend[gl]), .flitv(snp_rn_out_flitv[gl]),
                .flit(snp_rn_out_link_flit[gl*SNP_W +: SNP_W]),
                .lcrdv(snp_rn_out_lcrdv[gl]), .credit_count());
            chi_link_rx #(
                .FLIT_W(SNP_W), .DEPTH(INIT_CRD), .FALLTHROUGH(1),
                .OPC_LSB(SNP_OPC_LSB), .OPC_W(SNP_OPC_W)
            ) u_rx (
                .clk(clk_int), .rstn(rstn), .clear(1'b0), .grant_en(node_rx_grant_en[NODE]),
                .flitv(snp_rn_out_flitv[gl]), .flit(snp_rn_out_link_flit[gl*SNP_W +: SNP_W]),
                .lcrdv(snp_rn_out_lcrdv[gl]), .home(snp_rn_out_home[gl]),
                .out_valid(snp_rn_rx_valid[gl]), .out_ready(snp_rn_rx_ready[gl]),
                .out_flit(snp_rn_rx_flit[gl*SNP_W +: SNP_W]), .overflow(snp_rn_rx_overflow[gl]));
        end

        // LINKACTIVE handshake of both links of every node. Channels only
        // some node types have: REQ out of RN/HN, SNP out of HN/MN, DAT out
        // of all but MN; REQ into HN/SN/MN, SNP into RN.
        for (gl = 0; gl < NUM_NODES; gl = gl + 1) begin : gen_link_active
            localparam integer IS_RN = (gl < HN_BASE_ID);
            localparam integer IS_HN = (gl >= HN_BASE_ID) && (gl < SN_BASE_ID);
            localparam integer IS_MN = (gl >= MN_BASE_ID);
            wire req_tx_home;
            wire snp_tx_home;
            wire dat_tx_home;
            wire req_rx_home;
            wire snp_rx_home;
            if (IS_RN || IS_HN) begin : g_req_tx
                assign req_tx_home = req_src_home[gl];
            end else begin : g_no_req_tx
                assign req_tx_home = 1'b1;
            end
            if (IS_HN) begin : g_snp_tx_hn
                assign snp_tx_home = snp_src_home[gl - HN_BASE_ID];
            end else if (IS_MN) begin : g_snp_tx_mn
                assign snp_tx_home = snp_src_home[gl - MN_BASE_ID + NUM_HN];
            end else begin : g_no_snp_tx
                assign snp_tx_home = 1'b1;
            end
            if (IS_MN) begin : g_no_dat_tx
                assign dat_tx_home = 1'b1;
            end else begin : g_dat_tx
                assign dat_tx_home = dat_node_in_home[gl];
            end
            if (IS_RN) begin : g_rn_rx
                assign req_rx_home = 1'b1;
                assign snp_rx_home = snp_rn_out_home[gl];
            end else begin : g_other_rx
                assign req_rx_home = req_tgt_home[gl - HN_BASE_ID];
                assign snp_rx_home = 1'b1;
            end

            // Transmit link of the node: the fabric side is the receiver.
            chi_link_active_rx u_tx_link_rx (
                .clk(clk_int), .rstn(rstn),
                .linkactivereq(node_tx_lareq[gl]), .linkactiveack(node_tx_laack[gl]),
                .credits_home(req_tx_home && rsp_node_in_home[gl] &&
                              dat_tx_home && snp_tx_home),
                .grant_en(node_tx_grant_en[gl]));
            // Receive link of the node: the fabric side is the transmitter.
            chi_link_active_tx u_rx_link_tx (
                .clk(clk_int), .rstn(rstn), .want(link_want),
                .linkactivereq(node_rx_lareq[gl]), .linkactiveack(node_rx_laack[gl]),
                .run(node_rx_run[gl]), .deact(node_rx_deact[gl]));
            chi_link_active_rx u_rx_link_rx (
                .clk(clk_int), .rstn(rstn),
                .linkactivereq(node_rx_lareq[gl]), .linkactiveack(node_rx_laack[gl]),
                .credits_home(req_rx_home && rsp_node_out_home[gl] &&
                              dat_node_out_home[gl] && snp_rx_home),
                .grant_en(node_rx_grant_en[gl]));
        end
    endgenerate

    // synthesis translate_off
    // A credited flit must always find room in the fabric input FIFO.
    always @(posedge clk_int) begin
        if (rstn && ((|(req_src_valid & ~req_src_ready)) ||
                     (|(rsp_node_in_valid & ~rsp_node_in_ready)) ||
                     (|(dat_node_in_valid & ~dat_node_in_ready)) ||
                     (|(snp_src_valid & ~snp_src_ready)))) begin
            $display("[%0t] chi_top %m: ERROR: flit arrived at a full fabric input FIFO (L-Credit overrun)", $time);
            $stop;
        end
    end
    // synthesis translate_on

    genvar ga;
    generate
        for (ga = 0; ga < NUM_NODES; ga = ga + 1) begin : gen_sactive
            if (ga < HN_BASE_ID) begin : g_rn
                assign node_txsactive[ga] = rn_busy[ga - RN_BASE_ID];
            end else if (ga < SN_BASE_ID) begin : g_hn
                assign node_txsactive[ga] = hn_busy[ga - HN_BASE_ID];
            end else if (ga < MN_BASE_ID) begin : g_sn
                assign node_txsactive[ga] = sn_busy[ga - SN_BASE_ID];
            end else begin : g_mn
                assign node_txsactive[ga] = mn_busy[ga - MN_BASE_ID];
            end
            assign node_rxsactive[ga] =
                fabric_busy || link_rx_busy ||
                (|(node_txsactive &
                   ~({{(NUM_NODES-1){1'b0}}, 1'b1} << ga)));
        end
    endgenerate

    // Work in flight anywhere in the interconnect.
    assign chi_busy = (|node_txsactive) || fabric_busy || link_rx_busy;

    // Link power control. link_wake is work in flight or a wake source: CPU
    // requests and AXI responses, and the BIST-init pulse for the cycle it has
    // to reach the fabric. The links come up on link_wake and go down after
    // LINK_IDLE_CYCLES idle cycles. The fabric clock may only stop with every
    // link in STOP, when all L-Credits are back at their receivers, so the
    // clock keeps running until the deactivation is complete (B14.5.1).
    wire      link_wake = !cfg_cg_enable ||
                          chi_busy ||
                          csr_bist_init_pulse ||
                          (|cpu_req_valid) ||
                          (|axi_rvalid) ||
                          (|axi_bvalid);
    reg [7:0] link_idle_q;

    always @(posedge clk_int or negedge rstn) begin
        if (!rstn)
            link_idle_q <= 8'd0;
        else if (link_wake)
            link_idle_q <= 8'd0;
        else if (link_idle_q != LINK_IDLE_CYCLES[7:0])
            link_idle_q <= link_idle_q + 8'd1;
    end

    assign link_want     = link_wake || (link_idle_q != LINK_IDLE_CYCLES[7:0]);
    assign links_stopped = ~|(node_tx_lareq | node_tx_laack |
                              node_rx_lareq | node_rx_laack);
    assign chi_cg_en     = link_want || !links_stopped;

    // fabric_clear only resets the fabric queues, not the node trackers, so
    // a BIST init while traffic is in flight would drop flits that nodes are
    // still waiting for. Refuse it then and report ERR_STATUS[5].
    assign fabric_clear = csr_bist_init_pulse && !chi_busy;
    assign bist_reject_event = csr_bist_init_pulse && chi_busy;

    // SYSCOACK (B15.2.2). It rises as soon as SYSCOREQ is seen high. It
    // falls once SYSCOREQ is low, every snoop to that RN has completed and
    // no snoop filter lists the RN any more. With the external L1 an RN
    // cannot flush its cache, so it is kept in the domain.
    assign rn_sysco_connect = (USE_EXTERNAL_L1_SNOOP != 0) ?
                              {NUM_RN{1'b1}} : cfg_sysco_connect;

    always @(*) begin
        sysco_quiet_r = {NUM_RN{1'b1}};
        for (sysco_i = 0; sysco_i < NUM_HN; sysco_i = sysco_i + 1)
            sysco_quiet_r = sysco_quiet_r &
                            hn_sysco_quiet[sysco_i*NUM_RN +: NUM_RN];
        for (sysco_i = 0; sysco_i < NUM_MN; sysco_i = sysco_i + 1)
            sysco_quiet_r = sysco_quiet_r &
                            mn_sysco_quiet[sysco_i*NUM_RN +: NUM_RN];
    end

    always @(posedge clk_int or negedge rstn) begin
        if (!rstn)
            rn_syscoack <= {NUM_RN{1'b0}};
        else
            rn_syscoack <= rn_syscoreq | (rn_syscoack & ~sysco_quiet_r);
    end

    chi_clock_gate_insert u_top_clock_gate (
        .clk_in(clk),
        .enable(chi_cg_en),
        .scan_enable(1'b0),
        .clk_out(clk_int)
    );

    chi_csr_regs #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_HN(NUM_HN),
        .NUM_RN(NUM_RN)
    ) u_csr_regs (
        .clk(clk),
        .rstn(rstn),
        .csr_valid(csr_valid),
        .csr_write(csr_write),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_ready(csr_ready),
        .csr_rdata(csr_rdata),
        .hn_perf_counts_flat(hn_perf_counts_flat),
        .rn_perf_counts_flat(rn_perf_counts_flat),
        .ecc_single_event(|hn_ecc_single_event),
        .ecc_double_event(|hn_ecc_double_event),
        .rn_parity_error_event(|rn_cache_parity_error_event),
        .exclusive_fail_event(|hn_exclusive_fail_event),
        .watchdog_event((|hn_watchdog_event) | (|rn_watchdog_event) |
                        (|mn_watchdog_event)),
        .bist_reject_event(bist_reject_event),
        .err_irq(chi_irq),
        .cfg_region_valid(cfg_region_valid),
        .cfg_hnf_base(cfg_hnf_base),
        .cfg_hnf_end(cfg_hnf_end),
        .cfg_snf_base(cfg_snf_base),
        .cfg_snf_end(cfg_snf_end),
        .cfg_mn_base(cfg_mn_base),
        .cfg_mn_end(cfg_mn_end),
        .cfg_dvm_enable(cfg_dvm_enable),
        .cfg_cg_enable(cfg_cg_enable),
        .cfg_excl_timeout(cfg_excl_timeout),
        .cfg_mn_drain_cycles(cfg_mn_drain_cycles),
        .cfg_qos_age_shift(cfg_qos_age_shift),
        .cfg_qos_age_max(cfg_qos_age_max),
        .cfg_sysco_connect(cfg_sysco_connect),
        .sysco_req(rn_syscoreq),
        .sysco_ack(rn_syscoack),
        .cfg_bist_init(csr_bist_init_pulse)
    );

    genvar gr;
    genvar gh;
    genvar gs;
    genvar gm;

    generate
        for (gr = 0; gr < NUM_RN; gr = gr + 1) begin : gen_rn
            localparam integer RN_NODE_ID = RN_BASE_ID + gr;
            localparam integer REQ_SRC_IDX = gr;
            localparam integer DVM_REQ_TGT_IDX = (NUM_MN == 0) ? 0 : (NUM_HN + NUM_SN);
            wire [ADDR_WIDTH-1:0] req_addr_for_route;
            wire [`CHI_REQ_OPCODE_W-1:0] req_opcode_for_route;
            wire [NODE_ID_W-1:0]  rsp_tgt_for_route;
            wire [NODE_ID_W-1:0]  dat_tgt_for_route;
            wire [`CHI_DAT_QOS_W-1:0] dat_qos_for_arb;
            wire [NODE_ID_W-1:0]  route_id_unused_req;
            wire [NODE_ID_W-1:0]  route_id_addr_req;
            wire [NODE_ID_W-1:0]  route_id_unused_rsp;
            wire [NODE_ID_W-1:0]  route_id_unused_dat;
            wire route_error_unused_req;
            wire route_error_addr_req;
            wire route_error_unused_rsp;
            wire route_error_unused_dat;
            wire req_is_dvm_for_route;
            wire req_is_no_snp_for_route;
            wire req_force_hn_for_route;
            wire [NODE_ID_W-1:0] hnf_route_id_for_route;
            wire [NUM_REQ_TGT-1:0] req_route_onehot_addr;
            reg  [NUM_REQ_TGT-1:0] req_route_onehot_sel;
            reg  [REQ_W-1:0]      rn_req_flit_global_tgt;

            assign req_src_flitv[REQ_SRC_IDX] = rn_tx_req_flitv[gr];
            assign req_src_ret[REQ_SRC_IDX] = rn_tx_req_flitv[gr] &&
                   (rn_tx_req_flit[gr*REQ_W + REQ_OPC_LSB +: REQ_OPC_W] == {REQ_OPC_W{1'b0}});
            assign rn_tx_req_valid[gr] = rn_tx_req_flitv[gr] && !req_src_ret[REQ_SRC_IDX];
            assign req_src_valid[REQ_SRC_IDX] = rn_tx_req_valid[gr];
            assign req_src_flit[REQ_SRC_IDX*REQ_W +: REQ_W] =
                   rn_req_flit_global_tgt;
            assign req_qos_flat[REQ_SRC_IDX*QOS_W +: QOS_W] =
                   rn_req_flit_global_tgt[REQ_QOS_LSB +: QOS_W];
            assign rn_tx_req_lcrdv[gr] = req_src_lcrdv[REQ_SRC_IDX];

            assign rsp_node_in_flitv[RN_NODE_ID] = rn_tx_rsp_flitv[gr];
            assign rsp_node_in_ret[RN_NODE_ID] = rn_tx_rsp_flitv[gr] &&
                   (rn_tx_rsp_flit[gr*RSP_W + RSP_OPC_LSB +: RSP_OPC_W] == {RSP_OPC_W{1'b0}});
            assign rn_tx_rsp_valid[gr] = rn_tx_rsp_flitv[gr] && !rsp_node_in_ret[RN_NODE_ID];
            assign rsp_node_in_valid[RN_NODE_ID] = rn_tx_rsp_valid[gr];
            assign rsp_node_in_flit[RN_NODE_ID*RSP_W +: RSP_W] =
                   rn_tx_rsp_flit[gr*RSP_W +: RSP_W];
            assign rsp_qos_flat[RN_NODE_ID*QOS_W +: QOS_W] =
                   rn_tx_rsp_flit[gr*RSP_W + RSP_QOS_LSB +: QOS_W];
            assign rn_tx_rsp_lcrdv[gr] = rsp_node_in_lcrdv[RN_NODE_ID];

            assign dat_node_in_flitv[RN_NODE_ID] = rn_tx_dat_flitv[gr];
            assign dat_node_in_ret[RN_NODE_ID] = rn_tx_dat_flitv[gr] &&
                   (rn_tx_dat_flit[gr*DAT_W + DAT_OPC_LSB +: DAT_OPC_W] == {DAT_OPC_W{1'b0}});
            assign rn_tx_dat_valid[gr] = rn_tx_dat_flitv[gr] && !dat_node_in_ret[RN_NODE_ID];
            assign dat_node_in_valid[RN_NODE_ID] = rn_tx_dat_valid[gr];
            assign dat_node_in_flit[RN_NODE_ID*DAT_W +: DAT_W] =
                   rn_tx_dat_flit[gr*DAT_W +: DAT_W];
            assign dat_qos_for_arb =
                   rn_tx_dat_flit[gr*DAT_W + DAT_QOS_LSB +: `CHI_DAT_QOS_W];
            assign rn_tx_dat_lcrdv[gr] = dat_node_in_lcrdv[RN_NODE_ID];

            if (QOS_W > `CHI_DAT_QOS_W) begin : gen_dat_qos_wide
                assign dat_qos_flat[RN_NODE_ID*QOS_W +: QOS_W] =
                       {{(QOS_W-`CHI_DAT_QOS_W){1'b0}}, dat_qos_for_arb};
            end else begin : gen_dat_qos_narrow
                assign dat_qos_flat[RN_NODE_ID*QOS_W +: QOS_W] =
                       dat_qos_for_arb[QOS_W-1:0];
            end

            assign rsp_node_rx_ready[RN_NODE_ID] = rn_rx_rsp_ready[gr];
            assign snp_rn_rx_ready[gr]           = rn_rx_snp_ready[gr];
            assign dat_node_rx_ready[RN_NODE_ID] = rn_rx_dat_ready[gr];

            assign req_addr_for_route = rn_tx_req_flit[gr*REQ_W + REQ_ADDR_LSB +: ADDR_WIDTH];
            assign req_opcode_for_route = rn_tx_req_flit[gr*REQ_W + `CHI_REQ_OPCODE_LSB(NODE_ID_W) +: `CHI_REQ_OPCODE_W];
            assign rsp_tgt_for_route  = rn_tx_rsp_flit[gr*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route  = rn_tx_dat_flit[gr*DAT_W + DAT_TGT_LSB +: NODE_ID_W];
            assign req_is_dvm_for_route =
                (req_opcode_for_route == `CHI_REQ_DVM_OP);
            assign req_is_no_snp_for_route =
                (req_opcode_for_route == `CHI_REQ_RD_NO_SNP) ||
                (req_opcode_for_route == `CHI_REQ_WR_NO_SNP);
            assign req_force_hn_for_route =
                !req_is_dvm_for_route && !req_is_no_snp_for_route;
            assign hnf_route_id_for_route =
                (NUM_HN > 1) ?
                ((req_addr_for_route >> 6) % NUM_HN) :
                {NODE_ID_W{1'b0}};
            assign route_id_unused_req = req_is_dvm_for_route ?
                                         DVM_REQ_TGT_IDX :
                                         (req_force_hn_for_route ?
                                          hnf_route_id_for_route :
                                          route_id_addr_req);
            assign route_error_unused_req = req_is_dvm_for_route ?
                                            (NUM_MN == 0) :
                                            (req_force_hn_for_route ?
                                             1'b0 :
                                             route_error_addr_req);
            assign req_route_onehot[REQ_SRC_IDX*NUM_REQ_TGT +: NUM_REQ_TGT] =
                   req_route_onehot_sel;

            always @(*) begin
                req_route_onehot_sel = req_route_onehot_addr;
                if (req_is_dvm_for_route) begin
                    req_route_onehot_sel = {NUM_REQ_TGT{1'b0}};
                    if (NUM_MN != 0)
                        req_route_onehot_sel[DVM_REQ_TGT_IDX] = 1'b1;
                end else if (req_force_hn_for_route) begin
                    req_route_onehot_sel = {NUM_REQ_TGT{1'b0}};
                    req_route_onehot_sel[hnf_route_id_for_route] = 1'b1;
                end
            end

            always @(*) begin
                rn_req_flit_global_tgt = rn_tx_req_flit[gr*REQ_W +: REQ_W];
                rn_req_flit_global_tgt[REQ_TGT_LSB +: NODE_ID_W] =
                    HN_BASE_ID + route_id_unused_req;
            end

            chi_rn_f #(
                .NODE_ID(RN_NODE_ID),
                .DATA_WIDTH(DATA_WIDTH),
                .DAT_DATA_W(DAT_DATA_W),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .CPU_TAG_W(CPU_TAG_W),
                .INIT_CRD(INIT_CRD),
                .TXN_TBL_SIZE(RN_TXN_TBL_SIZE),
                .RN_CACHE_LINES(RN_CACHE_LINES),
                .USE_EXTERNAL_L1_SNOOP(USE_EXTERNAL_L1_SNOOP),
                .TIMEOUT_CYCLES(RN_TIMEOUT_CYCLES),
                .FUNCTIONAL_TIMEOUT(FUNCTIONAL_TIMEOUT),
                .ENABLE_PERF(ENABLE_PERF)
            ) u_rn_f (
                .clk(clk_int),
                .rstn(rstn),
                .cpu_req_valid(cpu_req_valid[gr]),
                .cpu_req_ready(cpu_req_ready[gr]),
                .cpu_req_addr(cpu_req_addr[gr*ADDR_WIDTH +: ADDR_WIDTH]),
                .cpu_req_op(cpu_req_op[gr*4 +: 4]),
                .cpu_req_size(cpu_req_size[gr*3 +: 3]),
                .cpu_req_qos(cpu_req_qos[gr*QOS_W +: QOS_W]),
                .cpu_req_tag(cpu_req_tag[gr*CPU_TAG_W +: CPU_TAG_W]),
                .cpu_wdata(cpu_wdata[gr*DATA_WIDTH +: DATA_WIDTH]),
                .cpu_wdata_line_in(cpu_wdata_line[gr*64*8 +: 64*8]),
                .cpu_wstrb_line_in(cpu_wstrb_line[gr*64 +: 64]),
                .cpu_rdata(cpu_rdata[gr*DATA_WIDTH +: DATA_WIDTH]),
                .cpu_resp_valid(cpu_resp_valid[gr]),
                .cpu_resp_tag(cpu_resp_tag[gr*CPU_TAG_W +: CPU_TAG_W]),
                .cpu_resp_line_valid(cpu_resp_line_valid[gr]),
                .cpu_resp_line_data(cpu_resp_line_data[gr*64*8 +: 64*8]),
                .cpu_resp_line_tag(cpu_resp_line_tag[gr*CPU_TAG_W +: CPU_TAG_W]),
                .l1_snoop_valid(l1_snoop_valid[gr]),
                .l1_snoop_ready(l1_snoop_ready[gr]),
                .l1_snoop_invalidate(l1_snoop_invalidate[gr]),
                .l1_snoop_addr(l1_snoop_addr[gr*ADDR_WIDTH +: ADDR_WIDTH]),
                .l1_snoop_result_valid(l1_snoop_result_valid[gr]),
                .l1_snoop_hit(l1_snoop_hit[gr]),
                .l1_snoop_dirty(l1_snoop_dirty[gr]),
                .l1_snoop_data(l1_snoop_data[gr*64*8 +: 64*8]),
                .tx_req_valid(rn_tx_req_flitv[gr]),
                .tx_req_flit(rn_tx_req_flit[gr*REQ_W +: REQ_W]),
                .tx_req_lcrdv(rn_tx_req_lcrdv[gr]),
                .tx_req_flitpend(req_src_flitpend[REQ_SRC_IDX]),
                .tx_rsp_valid(rn_tx_rsp_flitv[gr]),
                .tx_rsp_flit(rn_tx_rsp_flit[gr*RSP_W +: RSP_W]),
                .tx_rsp_lcrdv(rn_tx_rsp_lcrdv[gr]),
                .tx_rsp_flitpend(rsp_node_in_flitpend[RN_NODE_ID]),
                .tx_dat_valid(rn_tx_dat_flitv[gr]),
                .tx_dat_flit(rn_tx_dat_flit[gr*DAT_W +: DAT_W]),
                .tx_dat_lcrdv(rn_tx_dat_lcrdv[gr]),
                .tx_dat_flitpend(dat_node_in_flitpend[RN_NODE_ID]),
                .rx_rsp_valid(rsp_node_rx_valid[RN_NODE_ID]),
                .rx_rsp_flit(rsp_node_rx_flit[RN_NODE_ID*RSP_W +: RSP_W]),
                .rx_rsp_ready(rn_rx_rsp_ready[gr]),
                .rx_rsp_lcrdv(rn_rx_rsp_lcrdv_unused[gr]),
                .rx_snp_valid(snp_rn_rx_valid[gr]),
                .rx_snp_flit(snp_rn_rx_flit[gr*SNP_W +: SNP_W]),
                .rx_snp_ready(rn_rx_snp_ready[gr]),
                .rx_snp_lcrdv(rn_rx_snp_lcrdv_unused[gr]),
                .rx_dat_valid(dat_node_rx_valid[RN_NODE_ID]),
                .rx_dat_flit(dat_node_rx_flit[RN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_ready(rn_rx_dat_ready[gr]),
                .rx_dat_lcrdv(rn_rx_dat_lcrdv_unused[gr]),
                .perf_counts(rn_perf_counts_flat[gr*16*32 +: 16*32]),
                .cache_parity_error_event(rn_cache_parity_error_event[gr]),
                .watchdog_event(rn_watchdog_event[gr]),
                .link_want(link_want),
                .tx_linkactivereq(node_tx_lareq[RN_NODE_ID]),
                .tx_linkactiveack(node_tx_laack[RN_NODE_ID]),
                .sysco_connect(rn_sysco_connect[gr]),
                .syscoreq(rn_syscoreq[gr]),
                .syscoack(rn_syscoack[gr]),
                .busy(rn_busy[gr])
            );

            chi_route_decode #(
                .USE_ADDR(1),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_REQ_TGT),
                .ROUTE_ID_W(NODE_ID_W),
                .NUM_HNF(NUM_HN),
                .HNF_PORT(0),
                .SNF_PORT(NUM_HN),
                .MN_PORT(NUM_HN + NUM_SN)
            ) u_req_route (
                .valid(rn_tx_req_valid[gr]),
                .addr(req_addr_for_route),
                .tgt_id({NODE_ID_W{1'b0}}),
                .cfg_region_valid(cfg_region_valid),
                .cfg_hnf_base(cfg_hnf_base),
                .cfg_hnf_end(cfg_hnf_end),
                .cfg_snf_base(cfg_snf_base),
                .cfg_snf_end(cfg_snf_end),
                .cfg_mn_base(cfg_mn_base),
                .cfg_mn_end(cfg_mn_end),
                .route_id(route_id_addr_req),
                .route_onehot(req_route_onehot_addr),
                .route_error(route_error_addr_req)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_rsp_route (
                .valid(rn_tx_rsp_valid[gr]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_route_onehot[RN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_dat_route (
                .valid(rn_tx_dat_valid[gr]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(dat_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[RN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk_int) begin
                if (rstn) begin
                    if (route_error_unused_req) begin
                        $display("chi_top RN node %0d REQ route error",
                                 RN_NODE_ID);
                        $stop;
                    end
                    if (route_error_unused_rsp) begin
                        $display("chi_top RN%0d RSP route error target %0d",
                                 RN_NODE_ID, rsp_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_dat) begin
                        $display("chi_top RN%0d DAT route error target %0d",
                                 RN_NODE_ID, dat_tgt_for_route);
                        $stop;
                    end
                end
            end
            // synthesis translate_on
        end

        for (gh = 0; gh < NUM_HN; gh = gh + 1) begin : gen_hn
            localparam integer HN_NODE_ID = HN_BASE_ID + gh;
            localparam integer REQ_SRC_IDX = NUM_RN + gh;
            wire [NODE_ID_W-1:0] mem_req_tgt_for_route;
            wire [NODE_ID_W-1:0] rsp_tgt_for_route;
            wire [NODE_ID_W-1:0] dat_tgt_for_route;
            wire [`CHI_DAT_QOS_W-1:0] dat_qos_for_arb;
            wire [NODE_ID_W-1:0] route_id_unused_mem_req;
            wire [NODE_ID_W-1:0] route_id_unused_rsp;
            wire [NODE_ID_W-1:0] route_id_unused_snp;
            wire [NODE_ID_W-1:0] route_id_unused_dat;
            wire route_error_unused_mem_req;
            wire route_error_unused_rsp;
            wire route_error_unused_snp;
            wire route_error_unused_dat;

            assign req_tgt_rx_ready[gh] = hn_rx_req_ready[gh];
            assign snp_src_flitv[gh] = hn_tx_snp_flitv[gh];
            assign snp_src_ret[gh] = hn_tx_snp_flitv[gh] &&
                   (hn_tx_snp_flit[gh*SNP_W + SNP_OPC_LSB +: SNP_OPC_W] == {SNP_OPC_W{1'b0}});
            assign hn_tx_snp_valid[gh] = hn_tx_snp_flitv[gh] && !snp_src_ret[gh];
            assign snp_src_valid[gh] = hn_tx_snp_valid[gh];
            assign snp_src_flit[gh*SNP_W +: SNP_W] =
                   hn_tx_snp_flit[gh*SNP_W +: SNP_W];
            assign snp_qos_flat[gh*QOS_W +: QOS_W] =
                   hn_tx_snp_flit[gh*SNP_W + SNP_QOS_LSB +: QOS_W];
            assign hn_tx_snp_lcrdv[gh] = snp_src_lcrdv[gh];

            assign req_src_flitv[REQ_SRC_IDX] = hn_tx_req_flitv[gh];
            assign req_src_ret[REQ_SRC_IDX] = hn_tx_req_flitv[gh] &&
                   (hn_tx_req_flit[gh*REQ_W + REQ_OPC_LSB +: REQ_OPC_W] == {REQ_OPC_W{1'b0}});
            assign hn_tx_req_valid[gh] = hn_tx_req_flitv[gh] && !req_src_ret[REQ_SRC_IDX];
            assign req_src_valid[REQ_SRC_IDX] = hn_tx_req_valid[gh];
            assign req_src_flit[REQ_SRC_IDX*REQ_W +: REQ_W] =
                   hn_tx_req_flit[gh*REQ_W +: REQ_W];
            assign req_qos_flat[REQ_SRC_IDX*QOS_W +: QOS_W] =
                   hn_tx_req_flit[gh*REQ_W + REQ_QOS_LSB +: QOS_W];
            assign hn_tx_req_lcrdv[gh] = req_src_lcrdv[REQ_SRC_IDX];

            assign rsp_node_in_flitv[HN_NODE_ID] = hn_tx_rsp_flitv[gh];
            assign rsp_node_in_ret[HN_NODE_ID] = hn_tx_rsp_flitv[gh] &&
                   (hn_tx_rsp_flit[gh*RSP_W + RSP_OPC_LSB +: RSP_OPC_W] == {RSP_OPC_W{1'b0}});
            assign hn_tx_rsp_valid[gh] = hn_tx_rsp_flitv[gh] && !rsp_node_in_ret[HN_NODE_ID];
            assign rsp_node_in_valid[HN_NODE_ID] = hn_tx_rsp_valid[gh];
            assign rsp_node_in_flit[HN_NODE_ID*RSP_W +: RSP_W] =
                   hn_tx_rsp_flit[gh*RSP_W +: RSP_W];
            assign rsp_qos_flat[HN_NODE_ID*QOS_W +: QOS_W] =
                   hn_tx_rsp_flit[gh*RSP_W + RSP_QOS_LSB +: QOS_W];
            assign hn_tx_rsp_lcrdv[gh] = rsp_node_in_lcrdv[HN_NODE_ID];

            assign dat_qos_for_arb =
                   hn_tx_dat_flit[gh*DAT_W + DAT_QOS_LSB +: `CHI_DAT_QOS_W];
            assign dat_node_in_flitv[HN_NODE_ID] = hn_tx_dat_flitv[gh];
            assign dat_node_in_ret[HN_NODE_ID] = hn_tx_dat_flitv[gh] &&
                   (hn_tx_dat_flit[gh*DAT_W + DAT_OPC_LSB +: DAT_OPC_W] == {DAT_OPC_W{1'b0}});
            assign hn_tx_dat_valid[gh] = hn_tx_dat_flitv[gh] && !dat_node_in_ret[HN_NODE_ID];
            assign dat_node_in_valid[HN_NODE_ID] = hn_tx_dat_valid[gh];
            assign dat_node_in_flit[HN_NODE_ID*DAT_W +: DAT_W] =
                   hn_tx_dat_flit[gh*DAT_W +: DAT_W];
            assign hn_tx_dat_lcrdv[gh] = dat_node_in_lcrdv[HN_NODE_ID];

            if (QOS_W > `CHI_DAT_QOS_W) begin : gen_dat_qos_wide
                assign dat_qos_flat[HN_NODE_ID*QOS_W +: QOS_W] =
                       {{(QOS_W-`CHI_DAT_QOS_W){1'b0}}, dat_qos_for_arb};
            end else begin : gen_dat_qos_narrow
                assign dat_qos_flat[HN_NODE_ID*QOS_W +: QOS_W] =
                       dat_qos_for_arb[QOS_W-1:0];
            end


            assign rsp_node_rx_ready[HN_NODE_ID] = hn_rx_rsp_ready[gh];
            assign dat_node_rx_ready[HN_NODE_ID] = hn_rx_dat_ready[gh];

            assign mem_req_tgt_for_route = hn_tx_req_flit[gh*REQ_W + REQ_TGT_LSB +: NODE_ID_W];
            assign rsp_tgt_for_route     = hn_tx_rsp_flit[gh*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route     = hn_tx_dat_flit[gh*DAT_W + DAT_TGT_LSB +: NODE_ID_W];

            chi_hn_f #(
                .NODE_ID(HN_NODE_ID),
                .MEM_TGT_ID(SN_BASE_ID),
                .NUM_RN(NUM_RN),
                .NUM_SN(NUM_SN),
                .SN_BASE_ID(SN_BASE_ID),
                .DATA_WIDTH(DAT_DATA_W),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .INIT_CRD(INIT_CRD),
                .POS_DEPTH(HN_POS_DEPTH),
                .SF_ENTRIES(HN_SF_ENTRIES),
                .LLC_LINES(HN_LLC_LINES),
                .LLC_WAYS(HN_LLC_WAYS),
                .WRITE_TRACKER_DEPTH(HN_WRITE_TRACKER_DEPTH),
                .READ_TRACKER_DEPTH(HN_READ_TRACKER_DEPTH),
                .SNOOP_TRACKER_DEPTH(HN_SNOOP_TRACKER_DEPTH),
                .HN_NUM_SLOTS(HN_NUM_SLOTS),
                .ENABLE_PERF(ENABLE_PERF),
                .ENABLE_LLC_ECC(HN_ENABLE_LLC_ECC),
                .WRITE_THROUGH_NO_ALLOCATE(EXTERNAL_L1_WRITE_THROUGH_NO_ALLOCATE),
                .FUNCTIONAL_TIMEOUT(FUNCTIONAL_TIMEOUT)
            ) u_hn_f (
                .clk(clk_int),
                .rstn(rstn),
                .rx_req_valid(req_tgt_rx_valid[gh]),
                .rx_req_flit(req_tgt_rx_flit[gh*REQ_W +: REQ_W]),
                .rx_req_ready(hn_rx_req_ready[gh]),
                .rx_req_lcrdv(hn_rx_req_lcrdv_unused[gh]),
                .rx_dat_valid(dat_node_rx_valid[HN_NODE_ID]),
                .rx_dat_flit(dat_node_rx_flit[HN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_ready(hn_rx_dat_ready[gh]),
                .rx_dat_lcrdv(hn_rx_dat_lcrdv_unused[gh]),
                .rx_rsp_valid(rsp_node_rx_valid[HN_NODE_ID]),
                .rx_rsp_flit(rsp_node_rx_flit[HN_NODE_ID*RSP_W +: RSP_W]),
                .rx_rsp_ready(hn_rx_rsp_ready[gh]),
                .rx_rsp_lcrdv(hn_rx_rsp_lcrdv_unused[gh]),
                .tx_rsp_valid(hn_tx_rsp_flitv[gh]),
                .tx_rsp_flit(hn_tx_rsp_flit[gh*RSP_W +: RSP_W]),
                .tx_rsp_lcrdv(hn_tx_rsp_lcrdv[gh]),
                .tx_rsp_flitpend(rsp_node_in_flitpend[HN_NODE_ID]),
                .tx_snp_valid(hn_tx_snp_flitv[gh]),
                .tx_snp_flit(hn_tx_snp_flit[gh*SNP_W +: SNP_W]),
                .tx_snp_tgt_id(hn_tx_snp_tgt_id[gh*NODE_ID_W +: NODE_ID_W]),
                .tx_snp_lcrdv(hn_tx_snp_lcrdv[gh]),
                .tx_snp_flitpend(snp_src_flitpend[gh]),
                .tx_dat_valid(hn_tx_dat_flitv[gh]),
                .tx_dat_flit(hn_tx_dat_flit[gh*DAT_W +: DAT_W]),
                .tx_dat_lcrdv(hn_tx_dat_lcrdv[gh]),
                .tx_dat_flitpend(dat_node_in_flitpend[HN_NODE_ID]),
                .tx_req_valid(hn_tx_req_flitv[gh]),
                .tx_req_flit(hn_tx_req_flit[gh*REQ_W +: REQ_W]),
                .tx_req_lcrdv(hn_tx_req_lcrdv[gh]),
                .tx_req_flitpend(req_src_flitpend[REQ_SRC_IDX]),
                .perf_counts(hn_perf_counts_flat[gh*16*32 +: 16*32]),
                .ecc_single_event(hn_ecc_single_event[gh]),
                .ecc_double_event(hn_ecc_double_event[gh]),
                .cfg_excl_timeout(cfg_excl_timeout),
                .exclusive_fail_event(hn_exclusive_fail_event[gh]),
                .watchdog_event(hn_watchdog_event[gh]),
                .link_want(link_want),
                .tx_linkactivereq(node_tx_lareq[HN_NODE_ID]),
                .tx_linkactiveack(node_tx_laack[HN_NODE_ID]),
                .rn_in_domain(rn_syscoreq),
                .sysco_quiet(hn_sysco_quiet[gh*NUM_RN +: NUM_RN]),
                .busy(hn_busy[gh])
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_REQ_TGT),
                .BASE_ID(HN_BASE_ID),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_mem_req_route (
                .valid(hn_tx_req_valid[gh]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(mem_req_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_mem_req),
                .route_onehot(req_route_onehot[REQ_SRC_IDX*NUM_REQ_TGT +: NUM_REQ_TGT]),
                .route_error(route_error_unused_mem_req)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_rsp_route (
                .valid(hn_tx_rsp_valid[gh]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_route_onehot[HN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_RN),
                .BASE_ID(RN_BASE_ID),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_snp_route (
                .valid(hn_tx_snp_valid[gh]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(hn_tx_snp_tgt_id[gh*NODE_ID_W +: NODE_ID_W]),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_snp),
                .route_onehot(snp_route_onehot[gh*NUM_RN +: NUM_RN]),
                .route_error(route_error_unused_snp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_dat_route (
                .valid(hn_tx_dat_valid[gh]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(dat_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[HN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk_int) begin
                if (rstn) begin
                    if (route_error_unused_mem_req) begin
                        $display("chi_top HN%0d MEM REQ route error target %0d",
                                 HN_NODE_ID, mem_req_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_rsp) begin
                        $display("chi_top HN%0d RSP route error target %0d",
                                 HN_NODE_ID, rsp_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_snp) begin
                        $display("chi_top HN node %0d SNP route error",
                                 HN_NODE_ID);
                        $stop;
                    end
                    if (route_error_unused_dat) begin
                        $display("chi_top HN%0d DAT route error target %0d",
                                 HN_NODE_ID, dat_tgt_for_route);
                        $stop;
                    end
                end
            end
            // synthesis translate_on
        end

        for (gs = 0; gs < NUM_SN; gs = gs + 1) begin : gen_sn
            localparam integer SN_NODE_ID = SN_BASE_ID + gs;
            localparam integer REQ_TGT_IDX = NUM_HN + gs;
            wire [NODE_ID_W-1:0] rsp_tgt_for_route;
            wire [NODE_ID_W-1:0] dat_tgt_for_route;
            wire [`CHI_DAT_QOS_W-1:0] dat_qos_for_arb;
            wire [NODE_ID_W-1:0] route_id_unused_rsp;
            wire [NODE_ID_W-1:0] route_id_unused_dat;
            wire route_error_unused_rsp;
            wire route_error_unused_dat;

            assign req_tgt_rx_ready[REQ_TGT_IDX] = sn_rx_req_ready[gs];
            assign dat_node_rx_ready[SN_NODE_ID] = sn_rx_dat_ready[gs];
            assign rsp_node_rx_ready[SN_NODE_ID] = 1'b1;

            assign rsp_node_in_flitv[SN_NODE_ID] = sn_tx_rsp_flitv[gs];
            assign rsp_node_in_ret[SN_NODE_ID] = sn_tx_rsp_flitv[gs] &&
                   (sn_tx_rsp_flit[gs*RSP_W + RSP_OPC_LSB +: RSP_OPC_W] == {RSP_OPC_W{1'b0}});
            assign sn_tx_rsp_valid[gs] = sn_tx_rsp_flitv[gs] && !rsp_node_in_ret[SN_NODE_ID];
            assign rsp_node_in_valid[SN_NODE_ID] = sn_tx_rsp_valid[gs];
            assign rsp_node_in_flit[SN_NODE_ID*RSP_W +: RSP_W] =
                   sn_tx_rsp_flit[gs*RSP_W +: RSP_W];
            assign rsp_qos_flat[SN_NODE_ID*QOS_W +: QOS_W] =
                   sn_tx_rsp_flit[gs*RSP_W + RSP_QOS_LSB +: QOS_W];
            assign sn_tx_rsp_lcrdv[gs] = rsp_node_in_lcrdv[SN_NODE_ID];

            assign dat_node_in_flitv[SN_NODE_ID] = sn_tx_dat_flitv[gs];
            assign dat_node_in_ret[SN_NODE_ID] = sn_tx_dat_flitv[gs] &&
                   (sn_tx_dat_flit[gs*DAT_W + DAT_OPC_LSB +: DAT_OPC_W] == {DAT_OPC_W{1'b0}});
            assign sn_tx_dat_valid[gs] = sn_tx_dat_flitv[gs] && !dat_node_in_ret[SN_NODE_ID];
            assign dat_node_in_valid[SN_NODE_ID] = sn_tx_dat_valid[gs];
            assign dat_node_in_flit[SN_NODE_ID*DAT_W +: DAT_W] =
                   sn_tx_dat_flit[gs*DAT_W +: DAT_W];
            assign dat_qos_for_arb =
                   sn_tx_dat_flit[gs*DAT_W + DAT_QOS_LSB +: `CHI_DAT_QOS_W];
            assign sn_tx_dat_lcrdv[gs] = dat_node_in_lcrdv[SN_NODE_ID];

            if (QOS_W > `CHI_DAT_QOS_W) begin : gen_dat_qos_wide
                assign dat_qos_flat[SN_NODE_ID*QOS_W +: QOS_W] =
                       {{(QOS_W-`CHI_DAT_QOS_W){1'b0}}, dat_qos_for_arb};
            end else begin : gen_dat_qos_narrow
                assign dat_qos_flat[SN_NODE_ID*QOS_W +: QOS_W] =
                       dat_qos_for_arb[QOS_W-1:0];
            end

            assign rsp_tgt_for_route = sn_tx_rsp_flit[gs*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign dat_tgt_for_route = sn_tx_dat_flit[gs*DAT_W + DAT_TGT_LSB +: NODE_ID_W];

            chi_sn_f #(
                .NODE_ID(SN_NODE_ID),
                .DATA_WIDTH(DATA_WIDTH),
                .DAT_DATA_W(DAT_DATA_W),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .INIT_CRD(INIT_CRD)
            ) u_sn_f (
                .clk(clk_int),
                .rstn(rstn),
                .rx_req_valid(req_tgt_rx_valid[REQ_TGT_IDX]),
                .rx_req_flit(req_tgt_rx_flit[REQ_TGT_IDX*REQ_W +: REQ_W]),
                .rx_req_ready(sn_rx_req_ready[gs]),
                .rx_req_lcrdv(sn_rx_req_lcrdv_unused[gs]),
                .rx_dat_valid(dat_node_rx_valid[SN_NODE_ID]),
                .rx_dat_flit(dat_node_rx_flit[SN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_ready(sn_rx_dat_ready[gs]),
                .rx_dat_lcrdv(sn_rx_dat_lcrdv_unused[gs]),
                .tx_rsp_valid(sn_tx_rsp_flitv[gs]),
                .tx_rsp_flit(sn_tx_rsp_flit[gs*RSP_W +: RSP_W]),
                .tx_rsp_lcrdv(sn_tx_rsp_lcrdv[gs]),
                .tx_rsp_flitpend(rsp_node_in_flitpend[SN_NODE_ID]),
                .tx_dat_valid(sn_tx_dat_flitv[gs]),
                .tx_dat_flit(sn_tx_dat_flit[gs*DAT_W +: DAT_W]),
                .tx_dat_lcrdv(sn_tx_dat_lcrdv[gs]),
                .tx_dat_flitpend(dat_node_in_flitpend[SN_NODE_ID]),
                .axi_arvalid(axi_arvalid[gs]),
                .axi_arready(axi_arready[gs]),
                .axi_araddr(axi_araddr[gs*ADDR_WIDTH +: ADDR_WIDTH]),
                .axi_arsize(axi_arsize[gs*3 +: 3]),
                .axi_arlen(axi_arlen[gs*8 +: 8]),
                .axi_arburst(axi_arburst[gs*2 +: 2]),
                .axi_rvalid(axi_rvalid[gs]),
                .axi_rready(axi_rready[gs]),
                .axi_rdata(axi_rdata[gs*DATA_WIDTH +: DATA_WIDTH]),
                .axi_rresp(axi_rresp[gs*2 +: 2]),
                .axi_awvalid(axi_awvalid[gs]),
                .axi_awready(axi_awready[gs]),
                .axi_awaddr(axi_awaddr[gs*ADDR_WIDTH +: ADDR_WIDTH]),
                .axi_awsize(axi_awsize[gs*3 +: 3]),
                .axi_awlen(axi_awlen[gs*8 +: 8]),
                .axi_awburst(axi_awburst[gs*2 +: 2]),
                .axi_wvalid(axi_wvalid[gs]),
                .axi_wready(axi_wready[gs]),
                .axi_wdata(axi_wdata[gs*DATA_WIDTH +: DATA_WIDTH]),
                .axi_wstrb(axi_wstrb[gs*(DATA_WIDTH/8) +: (DATA_WIDTH/8)]),
                .axi_wlast(axi_wlast[gs]),
                .axi_bvalid(axi_bvalid[gs]),
                .axi_bready(axi_bready[gs]),
                .axi_bresp(axi_bresp[gs*2 +: 2]),
                .link_want(link_want),
                .tx_linkactivereq(node_tx_lareq[SN_NODE_ID]),
                .tx_linkactiveack(node_tx_laack[SN_NODE_ID]),
                .busy(sn_busy[gs])
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_rsp_route (
                .valid(sn_tx_rsp_valid[gs]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_route_onehot[SN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_dat_route (
                .valid(sn_tx_dat_valid[gs]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(dat_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_dat),
                .route_onehot(dat_route_onehot[SN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_dat)
            );

            // synthesis translate_off
            always @(posedge clk_int) begin
                if (rstn) begin
                    if (route_error_unused_rsp) begin
                        $display("chi_top SN%0d RSP route error target %0d",
                                 SN_NODE_ID, rsp_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_dat) begin
                        $display("chi_top SN%0d DAT route error target %0d",
                                 SN_NODE_ID, dat_tgt_for_route);
                        $stop;
                    end
                end
            end
            // synthesis translate_on
        end

        for (gm = 0; gm < NUM_MN; gm = gm + 1) begin : gen_mn
            localparam integer MN_NODE_ID = MN_BASE_ID + gm;
            localparam integer REQ_TGT_IDX = NUM_HN + NUM_SN + gm;
            localparam integer SNP_SRC_IDX = NUM_HN + gm;
            wire [NODE_ID_W-1:0] rsp_tgt_for_route;
            wire [NODE_ID_W-1:0] snp_tgt_for_route;
            wire [NODE_ID_W-1:0] route_id_unused_rsp;
            wire [NODE_ID_W-1:0] route_id_unused_snp;
            wire route_error_unused_rsp;
            wire route_error_unused_snp;

            assign req_tgt_rx_ready[REQ_TGT_IDX] = mn_rx_req_ready[gm];
            assign rsp_node_rx_ready[MN_NODE_ID] = mn_rx_rsp_ready[gm];
            assign dat_node_rx_ready[MN_NODE_ID] = mn_rx_dat_ready[gm];

            assign rsp_node_in_flitv[MN_NODE_ID] = mn_tx_rsp_flitv[gm];
            assign rsp_node_in_ret[MN_NODE_ID] = mn_tx_rsp_flitv[gm] &&
                   (mn_tx_rsp_flit[gm*RSP_W + RSP_OPC_LSB +: RSP_OPC_W] == {RSP_OPC_W{1'b0}});
            assign mn_tx_rsp_valid[gm] = mn_tx_rsp_flitv[gm] && !rsp_node_in_ret[MN_NODE_ID];
            assign rsp_node_in_valid[MN_NODE_ID] = mn_tx_rsp_valid[gm];
            assign rsp_node_in_flit[MN_NODE_ID*RSP_W +: RSP_W] =
                   mn_tx_rsp_flit[gm*RSP_W +: RSP_W];
            assign rsp_qos_flat[MN_NODE_ID*QOS_W +: QOS_W] =
                   mn_tx_rsp_flit[gm*RSP_W + RSP_QOS_LSB +: QOS_W];
            assign mn_tx_rsp_lcrdv[gm] = rsp_node_in_lcrdv[MN_NODE_ID];

            assign dat_node_in_valid[MN_NODE_ID] = 1'b0;
            assign dat_node_in_flitv[MN_NODE_ID] = 1'b0;
            assign dat_node_in_ret[MN_NODE_ID] = 1'b0;
            assign dat_node_in_flitpend[MN_NODE_ID] = 1'b0;
            assign dat_node_in_flit[MN_NODE_ID*DAT_W +: DAT_W] = {DAT_W{1'b0}};
            assign dat_qos_flat[MN_NODE_ID*QOS_W +: QOS_W] = {QOS_W{1'b0}};

            assign snp_src_flitv[SNP_SRC_IDX] = mn_tx_snp_flitv[gm];
            assign snp_src_ret[SNP_SRC_IDX] = mn_tx_snp_flitv[gm] &&
                   (mn_tx_snp_flit[gm*SNP_W + SNP_OPC_LSB +: SNP_OPC_W] == {SNP_OPC_W{1'b0}});
            assign mn_tx_snp_valid[gm] = mn_tx_snp_flitv[gm] && !snp_src_ret[SNP_SRC_IDX];
            assign snp_src_valid[SNP_SRC_IDX] = mn_tx_snp_valid[gm];
            assign snp_src_flit[SNP_SRC_IDX*SNP_W +: SNP_W] =
                   mn_tx_snp_flit[gm*SNP_W +: SNP_W];
            assign snp_qos_flat[SNP_SRC_IDX*QOS_W +: QOS_W] =
                   mn_tx_snp_flit[gm*SNP_W + SNP_QOS_LSB +: QOS_W];
            assign mn_tx_snp_lcrdv[gm] = snp_src_lcrdv[SNP_SRC_IDX];

            assign rsp_tgt_for_route = mn_tx_rsp_flit[gm*RSP_W + RSP_TGT_LSB +: NODE_ID_W];
            assign snp_tgt_for_route = mn_tx_snp_tgt_id[gm*NODE_ID_W +: NODE_ID_W];

            chi_hn_i_mn #(
                .NODE_ID(MN_NODE_ID),
                .RN_BASE_ID(RN_BASE_ID),
                .NUM_RN(NUM_RN),
                .ADDR_WIDTH(ADDR_WIDTH),
                .DAT_DATA_W(DAT_DATA_W),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .FUNCTIONAL_TIMEOUT(FUNCTIONAL_TIMEOUT)
            ) u_hn_i_mn (
                .clk(clk_int),
                .rstn(rstn),
                .dvm_enable(cfg_dvm_enable),
                .cfg_drain_cycles(cfg_mn_drain_cycles),
                .rx_req_valid(req_tgt_rx_valid[REQ_TGT_IDX]),
                .rx_req_flit(req_tgt_rx_flit[REQ_TGT_IDX*REQ_W +: REQ_W]),
                .rx_req_ready(mn_rx_req_ready[gm]),
                .rx_req_lcrdv(mn_rx_req_lcrdv_unused[gm]),
                .rx_rsp_valid(rsp_node_rx_valid[MN_NODE_ID]),
                .rx_rsp_flit(rsp_node_rx_flit[MN_NODE_ID*RSP_W +: RSP_W]),
                .rx_rsp_ready(mn_rx_rsp_ready[gm]),
                .rx_rsp_lcrdv(mn_rx_rsp_lcrdv_unused[gm]),
                .rx_dat_valid(dat_node_rx_valid[MN_NODE_ID]),
                .rx_dat_flit(dat_node_rx_flit[MN_NODE_ID*DAT_W +: DAT_W]),
                .rx_dat_ready(mn_rx_dat_ready[gm]),
                .tx_snp_valid(mn_tx_snp_flitv[gm]),
                .tx_snp_flit(mn_tx_snp_flit[gm*SNP_W +: SNP_W]),
                .tx_snp_tgt_id(mn_tx_snp_tgt_id[gm*NODE_ID_W +: NODE_ID_W]),
                .tx_snp_lcrdv(mn_tx_snp_lcrdv[gm]),
                .tx_snp_flitpend(snp_src_flitpend[SNP_SRC_IDX]),
                .tx_rsp_valid(mn_tx_rsp_flitv[gm]),
                .tx_rsp_flit(mn_tx_rsp_flit[gm*RSP_W +: RSP_W]),
                .tx_rsp_lcrdv(mn_tx_rsp_lcrdv[gm]),
                .tx_rsp_flitpend(rsp_node_in_flitpend[MN_NODE_ID]),
                .watchdog_event(mn_watchdog_event[gm]),
                .link_want(link_want),
                .tx_linkactivereq(node_tx_lareq[MN_NODE_ID]),
                .tx_linkactiveack(node_tx_laack[MN_NODE_ID]),
                .rn_in_domain(rn_syscoreq),
                .sysco_quiet(mn_sysco_quiet[gm*NUM_RN +: NUM_RN]),
                .busy(mn_busy[gm])
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_NODES),
                .BASE_ID(0),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_rsp_route (
                .valid(mn_tx_rsp_valid[gm]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(rsp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_rsp),
                .route_onehot(rsp_route_onehot[MN_NODE_ID*NUM_NODES +: NUM_NODES]),
                .route_error(route_error_unused_rsp)
            );

            chi_route_decode #(
                .USE_ADDR(0),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .NUM_OUT(NUM_RN),
                .BASE_ID(RN_BASE_ID),
                .ROUTE_ID_W(NODE_ID_W)
            ) u_snp_route (
                .valid(mn_tx_snp_valid[gm]),
                .addr({ADDR_WIDTH{1'b0}}),
                .tgt_id(snp_tgt_for_route),
                .cfg_region_valid(1'b0),
                .cfg_hnf_base({ADDR_WIDTH{1'b0}}),
                .cfg_hnf_end({ADDR_WIDTH{1'b0}}),
                .cfg_snf_base({ADDR_WIDTH{1'b0}}),
                .cfg_snf_end({ADDR_WIDTH{1'b0}}),
                .cfg_mn_base({ADDR_WIDTH{1'b0}}),
                .cfg_mn_end({ADDR_WIDTH{1'b0}}),
                .route_id(route_id_unused_snp),
                .route_onehot(snp_route_onehot[SNP_SRC_IDX*NUM_RN +: NUM_RN]),
                .route_error(route_error_unused_snp)
            );

            // synthesis translate_off
            always @(posedge clk_int) begin
                if (rstn) begin
                    if (route_error_unused_rsp) begin
                        $display("chi_top MN%0d RSP route error target %0d",
                                 MN_NODE_ID, rsp_tgt_for_route);
                        $stop;
                    end
                    if (route_error_unused_snp) begin
                        $display("chi_top MN%0d SNP route error target %0d",
                                 MN_NODE_ID, snp_tgt_for_route);
                        $stop;
                    end
                end
            end
            // synthesis translate_on
        end

    endgenerate

    chi_fabric #(
        .NUM_RN(NUM_RN),
        .NUM_HN(NUM_HN),
        .NUM_SN(NUM_SN),
        .NUM_MN(NUM_MN),
        .NUM_NODES(NUM_NODES),
        .NUM_REQ_SRC(NUM_REQ_SRC),
        .NUM_REQ_TGT(NUM_REQ_TGT),
        .NUM_SNP_SRC(NUM_SNP_SRC),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DAT_DATA_W),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .FIFO_DEPTH(FABRIC_FIFO_DEPTH),
        .OUTPUT_FIFO_DEPTH(FABRIC_OUTPUT_FIFO_DEPTH),
        .ENABLE_QOS_AGING(ENABLE_QOS_AGING)
    ) u_fabric (
        .clk(clk_int),
        .rstn(rstn),
        .clear(fabric_clear),
        .busy(fabric_busy),
        .req_qos_flat(req_qos_flat),
        .rsp_qos_flat(rsp_qos_flat),
        .dat_qos_flat(dat_qos_flat),
        .snp_qos_flat(snp_qos_flat),
        .cfg_qos_age_shift(cfg_qos_age_shift),
        .cfg_qos_age_max(cfg_qos_age_max),
        .req_in_valid(req_src_valid),
        .req_in_ready(req_src_ready),
        .req_in_flit(req_src_flit),
        .req_in_pop_pulse(req_src_pop_pulse),
        .req_route_onehot(req_route_onehot),
        .req_out_valid(req_tgt_valid),
        .req_out_pend(req_tgt_pend),
        .req_out_ready(req_tgt_ready),
        .req_out_flit(req_tgt_flit),
        .rsp_in_valid(rsp_node_in_valid),
        .rsp_in_ready(rsp_node_in_ready),
        .rsp_in_flit(rsp_node_in_flit),
        .rsp_in_pop_pulse(rsp_node_in_pop_pulse),
        .rsp_route_onehot(rsp_route_onehot),
        .rsp_out_valid(rsp_node_out_valid),
        .rsp_out_pend(rsp_node_out_pend),
        .rsp_out_ready(rsp_node_out_ready),
        .rsp_out_flit(rsp_node_out_flit),
        .snp_in_valid(snp_src_valid),
        .snp_in_ready(snp_src_ready),
        .snp_in_flit(snp_src_flit),
        .snp_in_pop_pulse(snp_src_pop_pulse),
        .snp_route_onehot(snp_route_onehot),
        .snp_out_valid(snp_rn_out_valid),
        .snp_out_pend(snp_rn_out_pend),
        .snp_out_ready(snp_rn_out_ready),
        .snp_out_flit(snp_rn_out_flit),
        .dat_in_valid(dat_node_in_valid),
        .dat_in_ready(dat_node_in_ready),
        .dat_in_flit(dat_node_in_flit),
        .dat_in_pop_pulse(dat_node_in_pop_pulse),
        .dat_route_onehot(dat_route_onehot),
        .dat_out_valid(dat_node_out_valid),
        .dat_out_pend(dat_node_out_pend),
        .dat_out_ready(dat_node_out_ready),
        .dat_out_flit(dat_node_out_flit)
    );
endmodule
