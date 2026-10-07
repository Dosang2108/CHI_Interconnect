`timescale 1ns / 1ps
`include "chi_defs.vh"

`ifndef CHI_DISABLE_SIM_ASSERTIONS
`include "chi_deadlock_formal.v"
`include "chi_formal_binds.v"
`endif

// -----------------------------------------------------------------------------
// Top-level CHI smoke/regression testbench.
//
// Scope:
// - Instantiates the resource-light dual-core 2RN/1HN/1SN/1MN chi_top profile.
// - Drives RN CPU-side requests across RN0/RN1, including same-line coherence,
//   dirty-owner snoop data, DVM broadcast, cross-core exclusive invalidation,
//   and concurrent request backpressure.
// - Models the single SN AXI memory port.
// - Self-checks CSR accesses, read miss/hit data, and write path AW/W/B.
// -----------------------------------------------------------------------------
module tb_CHI;
    localparam integer NUM_RN     = 2;
    localparam integer NUM_HN     = 1;
    localparam integer NUM_SN     = 1;
    localparam integer NUM_MN     = 1;
    localparam integer DATA_WIDTH = 32;
    localparam integer ADDR_WIDTH = 32;
    localparam integer NODE_ID_W  = 7;
    localparam integer TXN_ID_W   = 12;
    localparam integer QOS_W      = 4;
    localparam integer DBID_W     = 12;
    localparam integer CPU_TAG_W  = 2;
    // CHI DAT channel width (CPU and AXI stay DATA_WIDTH wide).
    localparam integer DAT_DATA_W = `CHI_DEFAULT_DAT_DATA_W;
    localparam integer DAT_W      = `CHI_DAT_W(DAT_DATA_W,NODE_ID_W);
    localparam integer HN0_NODE_ID = NUM_RN;
    localparam [NODE_ID_W-1:0] RN0_NODE_ID_VEC = {NODE_ID_W{1'b0}};
    localparam [NODE_ID_W-1:0] RN1_NODE_ID_VEC = {{(NODE_ID_W-1){1'b0}}, 1'b1};
    localparam [NODE_ID_W-1:0] HN0_NODE_ID_VEC = HN0_NODE_ID;
    localparam integer BE_W       = DATA_WIDTH / 8;
    localparam integer LINE_BYTES = 64;
    localparam integer LINE_WIDTH = LINE_BYTES * 8;
    localparam integer BEATS      = LINE_BYTES / BE_W;
    // DAT beats per line (BEATS counts CPU/AXI words).
    localparam integer DAT_BEATS  = LINE_BYTES / (DAT_DATA_W / 8);
    localparam integer MAX_WAIT   = 2000;
    localparam integer A1_ARB_CYCLES = 32;
    localparam integer A2_NUM_HN = 3;
    localparam integer A2_TRACKER_DEPTH = 2;
    localparam integer A2_HN_BANK_BITS = 4;
    localparam integer MEM_SHADOW_LINES = 256;
    localparam integer LLC_SETS   = 16;
    localparam integer LLC_SET_W  = 4;
    localparam integer LLC_TAG_W  = ADDR_WIDTH - 6 - LLC_SET_W;
    localparam integer LLC_EVICT_SET = 1;
    localparam integer LLC_CLEAN_EVICT_SET = 2;
    localparam integer LLC_HN_SLOT_SET = 3;
    localparam integer LLC_HN_HAZARD_SET = 4;
    localparam integer RN_CACHE_LINES = 8;
    localparam integer RN_CACHE_WAYS  = 4;
    localparam integer RN_CACHE_SETS  = RN_CACHE_LINES / RN_CACHE_WAYS;
    localparam integer RN_CACHE_SET_W = 1;
    localparam integer RN_CACHE_TAG_W = ADDR_WIDTH - 6 - RN_CACHE_SET_W;
    localparam integer RN_META_STATE_LSB = 1;
    localparam integer RN_META_TAG_LSB   = 4;

    localparam [63:0] CSR_MASK_CTRL = 64'h0000_0000_0000_0007;
    localparam [63:0] CSR_MASK_4B   = 64'h0000_0000_0000_000F;
    localparam [63:0] CSR_MASK_8B   = 64'h0000_0000_0000_00FF;
    localparam [63:0] CSR_MASK_16B  = 64'h0000_0000_0000_FFFF;
    localparam [63:0] CSR_MASK_32B  = 64'h0000_0000_FFFF_FFFF;

    localparam [ADDR_WIDTH-1:0] TEST_ADDR0 = 32'h0000_1000;
    localparam [ADDR_WIDTH-1:0] TEST_ADDR1 = 32'h0000_2000;
    localparam [ADDR_WIDTH-1:0] TEST_ADDR2 = 32'h0000_3000;
    localparam [ADDR_WIDTH-1:0] EVICT_DIRTY_ADDR0 = 32'h0000_4040;
    localparam [ADDR_WIDTH-1:0] EVICT_CLEAN_ADDR1 = 32'h0000_4440;
    localparam [ADDR_WIDTH-1:0] EVICT_CLEAN_ADDR2 = 32'h0000_4840;
    localparam [ADDR_WIDTH-1:0] EVICT_CLEAN_ADDR3 = 32'h0000_4C40;
    localparam [ADDR_WIDTH-1:0] EVICT_TRIGGER_ADDR = 32'h0000_5040;
    localparam [ADDR_WIDTH-1:0] CLEAN_EVICT_ADDR0 = 32'h0000_4080;
    localparam [ADDR_WIDTH-1:0] CLEAN_EVICT_ADDR1 = 32'h0000_4480;
    localparam [ADDR_WIDTH-1:0] CLEAN_EVICT_ADDR2 = 32'h0000_4880;
    localparam [ADDR_WIDTH-1:0] CLEAN_EVICT_ADDR3 = 32'h0000_4C80;
    localparam [ADDR_WIDTH-1:0] CLEAN_EVICT_TRIGGER_ADDR = 32'h0000_5080;
    localparam [ADDR_WIDTH-1:0] CONC_WRITE_ADDR = 32'h0000_6000;
    localparam [ADDR_WIDTH-1:0] EXCL_ADDR0 = 32'h0000_7000;
    localparam [ADDR_WIDTH-1:0] EXCL_FAIL_ADDR = 32'h0000_7400;
    localparam [ADDR_WIDTH-1:0] EXCL_TIMEOUT_ADDR = 32'h0000_7800;
    localparam [ADDR_WIDTH-1:0] IOT_BP_READ_ADDR = 32'h0000_80C0;
    localparam [ADDR_WIDTH-1:0] IOT_BP_WRITE_ADDR = 32'h0000_9140;
    localparam [ADDR_WIDTH-1:0] IOT_WAKE_ADDR = 32'h0000_A180;
    localparam [ADDR_WIDTH-1:0] IOT_RESET_ADDR = 32'h0000_B1C0;
    localparam [ADDR_WIDTH-1:0] IOT_RESET_RECOVERY_ADDR = 32'h0000_C200;
    localparam [ADDR_WIDTH-1:0] DUAL_RN1_ADDR = 32'h0000_D240;
    localparam [ADDR_WIDTH-1:0] DUAL_RN1_WB_ADDR = 32'h0000_D300;
    localparam [ADDR_WIDTH-1:0] DUAL_SHARED_LINE_ADDR = 32'h0000_D400;
    localparam [ADDR_WIDTH-1:0] DUAL_DIRTY_SNOOP_ADDR = 32'h0000_D500;
    localparam [ADDR_WIDTH-1:0] DIRECT_FWD_ADDR = 32'h0001_6000;
    localparam [ADDR_WIDTH-1:0] DATA_FWD_COPY_ADDR = 32'h0001_7000;
    localparam [ADDR_WIDTH-1:0] DAT_OPCODE_LEGALITY_ADDR = 32'h0001_8000;
    localparam [ADDR_WIDTH-1:0] DCT_HOME_NID_ADDR = 32'h0001_9000;
    localparam [ADDR_WIDTH-1:0] DUAL_DVM_ADDR0 = 32'h0000_D600;
    localparam [ADDR_WIDTH-1:0] DUAL_DVM_ADDR1 = 32'h0000_D680;
    localparam [ADDR_WIDTH-1:0] DUAL_EXCL_CROSS_ADDR = 32'h0000_D700;
    localparam [ADDR_WIDTH-1:0] P0_SF_ADDR = 32'h0001_A000;
    localparam [ADDR_WIDTH-1:0] P0_WB_ADDR0 = 32'h0001_B000;
    localparam [ADDR_WIDTH-1:0] P0_WB_ADDR1 = 32'h0001_B040;
    localparam [DATA_WIDTH-1:0] P0_WB_DATA0 = 32'hC0DE_0A0A;
    localparam [DATA_WIDTH-1:0] P0_WB_DATA1 = 32'hC0DE_1B1B;
    localparam [ADDR_WIDTH-1:0] WDOG_ADDR = 32'h0001_C000;
    localparam integer WDOG_HOLD_CYCLES = 1300;
    localparam [ADDR_WIDTH-1:0] SNTXN_WR_ADDR = 32'h0001_D000;
    localparam [ADDR_WIDTH-1:0] SNTXN_RD_ADDR = 32'h0001_D800;
    localparam [DATA_WIDTH-1:0] SNTXN_WR_DATA = 32'hC0DE_5E5E;
    localparam [ADDR_WIDTH-1:0] P0_EVW_ADDR = 32'h0001_E000;
    localparam [DATA_WIDTH-1:0] P0_EVW_DATA = 32'hC0DE_E7E7;
    localparam [ADDR_WIDTH-1:0] A1_HIT_ADDR = 32'h0002_0000;
    localparam [ADDR_WIDTH-1:0] A1_STORE_ADDR = 32'h0002_0400;
    localparam [ADDR_WIDTH-1:0] A1_WB_ADDR = 32'h0002_1000;
    localparam [ADDR_WIDTH-1:0] A1_PTL_ADDR = 32'h0002_2000;
    localparam [ADDR_WIDTH-1:0] A1_RU_ADDR = 32'h0002_3000;
    localparam [ADDR_WIDTH-1:0] A1_VIC_ADDR = 32'h0002_5000;
    localparam [ADDR_WIDTH-1:0] A1_VIC_BLOCK0 = 32'h0002_5800;
    localparam [ADDR_WIDTH-1:0] A1_VIC_BLOCK1 = 32'h0002_6800;
    localparam [DATA_WIDTH-1:0] A1_DATA2 = 32'hA1D2_2222;
    localparam [ADDR_WIDTH-1:0] RAW_ADDR = 32'h0002_7000;
    localparam [DATA_WIDTH-1:0] RAW_DATA = 32'hC0DE_5252;
    localparam [ADDR_WIDTH-1:0] RAW_BLOCK_ADDR = 32'h0002_7800;
    localparam [ADDR_WIDTH-1:0] MW_ADDR0 = 32'h0002_8000;
    localparam [ADDR_WIDTH-1:0] MW_ADDR1 = 32'h0002_8440;
    localparam [DATA_WIDTH-1:0] MW_DATA0 = 32'hC0DE_5300;
    localparam [DATA_WIDTH-1:0] MW_DATA1 = 32'hC0DE_5311;
    localparam [ADDR_WIDTH-1:0] XR_ADDR = 32'h0002_9000;
    localparam [DATA_WIDTH-1:0] XR_DATA0 = 32'hC0DE_5400;
    localparam [DATA_WIDTH-1:0] XR_DATA1 = 32'hC0DE_5411;
    localparam [ADDR_WIDTH-1:0] MU_ADDR = 32'h0002_A000;
    // 3.4: lines and data of the coherency-domain test (T57).
    localparam [ADDR_WIDTH-1:0] SYSCO_DIRTY_ADDR  = 32'h0002_B000;
    localparam [ADDR_WIDTH-1:0] SYSCO_CLEAN_ADDR  = 32'h0002_B400;
    localparam [ADDR_WIDTH-1:0] SYSCO_SHARED_ADDR = 32'h0002_B800;
    localparam [DATA_WIDTH-1:0] SYSCO_DATA0 = 32'h5C00_0AA0;
    localparam [DATA_WIDTH-1:0] SYSCO_DATA1 = 32'h5C01_0BB1;
    localparam [DATA_WIDTH-1:0] SYSCO_DATA2 = 32'h5C02_0CC2;
    localparam [7:0] CSR_SYSCO_CTRL   = 8'h58;
    localparam [7:0] CSR_SYSCO_STATUS = 8'h60;
    localparam [DATA_WIDTH-1:0] A1_DATA0 = 32'hA1D0_0000;
    localparam [DATA_WIDTH-1:0] A1_DATA1 = 32'hA1D1_1111;
    localparam [ADDR_WIDTH-1:0] P0_LLC_ADDR = 32'h0001_F000;
    localparam [DATA_WIDTH-1:0] P0_LLC_DATA = 32'hC0DE_4646;
    localparam integer P0_EVW_BEAT_STEP = 3;
    localparam integer P0_EVW_STALL_CYCLES = 120;
    localparam integer P0_EVW_CYCLE_STEP = 40;
    localparam [ADDR_WIDTH-1:0] DUAL_BP_RN0_ADDR = 32'h0000_D800;
    localparam [ADDR_WIDTH-1:0] DUAL_BP_RN1_ADDR = 32'h0000_D900;
    localparam [ADDR_WIDTH-1:0] RANDOM_BP_BASE = 32'h0000_E000;
    localparam [ADDR_WIDTH-1:0] RANDOM_BP_WRITE_BASE_ADDR = 32'h0000_E400;
    localparam [ADDR_WIDTH-1:0] MULTISEED_BP_BASE = 32'h0000_F000;
    localparam [ADDR_WIDTH-1:0] MULTISEED_BP_WRITE_BASE_ADDR = 32'h0001_0000;
    localparam [ADDR_WIDTH-1:0] SPARSE_BYTE_ADDR = 32'h0001_1402;
    localparam [ADDR_WIDTH-1:0] SPARSE_HALF_ADDR = 32'h0001_1482;
    localparam [ADDR_WIDTH-1:0] HN_SLOT_OVERLAP_ADDR0 = 32'h0001_2000;
    localparam [ADDR_WIDTH-1:0] HN_SLOT_OVERLAP_ADDR1 = 32'h0001_3000;
    localparam [ADDR_WIDTH-1:0] HN_SLOT_HIT_ADDR =
        {22'h000012, LLC_HN_SLOT_SET[3:0], 6'b00_0000};
    localparam [ADDR_WIDTH-1:0] HN_SLOT_SAME_LINE_ADDR =
        {22'h000013, LLC_HN_HAZARD_SET[3:0], 6'b00_0000};
    localparam [ADDR_WIDTH-1:0] SOC_CACHEABLE_HIGH_ADDR = 32'h8000_1000;
    localparam [ADDR_WIDTH-1:0] HN_RETRY_WRITE_ADDR = 32'h0001_5000;
    localparam integer A3_EXCL_TIMEOUT_CYCLES = 16;
    localparam [DATA_WIDTH-1:0] WRITE_DATA0 = 32'hCAFE_1234;
    localparam [DATA_WIDTH-1:0] CONC_WRITE_DATA = 32'hFACE_5EED;
    localparam [DATA_WIDTH-1:0] EXCL_WRITE_DATA = 32'h5EED_A301;
    localparam [DATA_WIDTH-1:0] EXCL_FAIL_DATA = 32'hBAD0_A302;
    localparam [DATA_WIDTH-1:0] EXCL_TIMEOUT_DATA = 32'hBAD0_A303;
    localparam [DATA_WIDTH-1:0] HN_RETRY_WRITE_DATA = 32'hC0DE_5A35;
    localparam [DATA_WIDTH-1:0] IOT_BP_WRITE_DATA = 32'h1A0B_B001;
    localparam [DATA_WIDTH-1:0] EVICT_DATA_BASE = 32'hD17A_5000;
    localparam [DATA_WIDTH-1:0] DUAL_RN1_WB_DATA = 32'hB105_0001;
    localparam [DATA_WIDTH-1:0] DUAL_SHARED_DATA0 = 32'hD440_0001;
    localparam [DATA_WIDTH-1:0] DUAL_SHARED_DATA1 = 32'hD440_0002;
    localparam [DATA_WIDTH-1:0] DUAL_DIRTY_DATA0 = 32'hD1A7_0001;
    localparam [DATA_WIDTH-1:0] DUAL_DIRTY_DATA1 = 32'hD1A7_0002;
    localparam [DATA_WIDTH-1:0] DIRECT_FWD_DATA0 = 32'hF0D0_0001;
    localparam [DATA_WIDTH-1:0] DIRECT_FWD_DATA1 = 32'hF0D0_0002;
    localparam [DATA_WIDTH-1:0] DATA_FWD_COPY_DATA0 = 32'hF0DC_0001;
    localparam [DATA_WIDTH-1:0] DATA_FWD_COPY_DATA1 = 32'hF0DC_0002;
    localparam [DATA_WIDTH-1:0] DAT_OPCODE_LEGALITY_DATA = 32'hDAD0_0038;
    localparam [DATA_WIDTH-1:0] DCT_HOME_NID_DATA = 32'hD17C_0039;
    localparam [DATA_WIDTH-1:0] DUAL_EXCL_CROSS_DATA = 32'hE110_0001;
    localparam [DATA_WIDTH-1:0] DUAL_EXCL_CROSS_FAIL_DATA = 32'hE110_0002;
    localparam [DATA_WIDTH-1:0] RANDOM_BP_WRITE_DATA_BASE = 32'hA11E_0000;
    localparam [DATA_WIDTH-1:0] MULTISEED_BP_WRITE_DATA_BASE = 32'hBEE0_0000;
    localparam [DATA_WIDTH-1:0] SPARSE_BYTE_DATA = 32'h0000_00A7;
    localparam [DATA_WIDTH-1:0] SPARSE_HALF_DATA = 32'h0000_B6C5;

    reg                         clk;
    reg                         rstn;

    reg                         csr_valid;
    reg                         csr_write;
    reg      [7:0]              csr_addr;
    reg      [63:0]             csr_wdata;
    wire                        csr_ready;
    wire     [63:0]             csr_rdata;
    wire                        chi_irq;

    reg      [NUM_RN-1:0]       cpu_req_valid;
    wire     [NUM_RN-1:0]       cpu_req_ready;
    reg      [NUM_RN*ADDR_WIDTH-1:0] cpu_req_addr;
    reg      [NUM_RN*4-1:0]     cpu_req_op;
    reg      [NUM_RN*3-1:0]     cpu_req_size;
    reg      [NUM_RN*QOS_W-1:0] cpu_req_qos;
    reg      [NUM_RN*CPU_TAG_W-1:0] cpu_req_tag;
    reg      [NUM_RN*DATA_WIDTH-1:0] cpu_wdata;
    reg      [NUM_RN*64*8-1:0]  cpu_wdata_line = {NUM_RN*64*8{1'b0}};
    reg      [NUM_RN*64-1:0]    cpu_wstrb_line = {NUM_RN*64{1'b0}};
    wire     [NUM_RN*DATA_WIDTH-1:0] cpu_rdata;
    wire     [NUM_RN-1:0]       cpu_resp_valid;
    wire     [NUM_RN*CPU_TAG_W-1:0] cpu_resp_tag;
    wire     [NUM_RN-1:0]       cpu_resp_line_valid;
    wire     [NUM_RN*64*8-1:0]  cpu_resp_line_data;
    wire     [NUM_RN*CPU_TAG_W-1:0] cpu_resp_line_tag;

    wire     [NUM_SN-1:0]       axi_arvalid;
    wire     [NUM_SN-1:0]       axi_arready;
    wire     [NUM_SN*ADDR_WIDTH-1:0] axi_araddr;
    wire     [NUM_SN*3-1:0]     axi_arsize;
    wire     [NUM_SN*8-1:0]     axi_arlen;
    wire     [NUM_SN*2-1:0]     axi_arburst;
    reg      [NUM_SN-1:0]       axi_rvalid;
    wire     [NUM_SN-1:0]       axi_rready;
    reg      [NUM_SN*DATA_WIDTH-1:0] axi_rdata;
    reg      [NUM_SN*2-1:0]     axi_rresp;

    wire     [NUM_SN-1:0]       axi_awvalid;
    wire     [NUM_SN-1:0]       axi_awready;
    wire     [NUM_SN*ADDR_WIDTH-1:0] axi_awaddr;
    wire     [NUM_SN*3-1:0]     axi_awsize;
    wire     [NUM_SN*8-1:0]     axi_awlen;
    wire     [NUM_SN*2-1:0]     axi_awburst;
    wire     [NUM_SN-1:0]       axi_wvalid;
    wire     [NUM_SN-1:0]       axi_wready;
    wire     [NUM_SN*DATA_WIDTH-1:0] axi_wdata;
    wire     [NUM_SN*BE_W-1:0]  axi_wstrb;
    wire     [NUM_SN-1:0]       axi_wlast;
    reg      [NUM_SN-1:0]       axi_bvalid;
    wire     [NUM_SN-1:0]       axi_bready;
    reg      [NUM_SN*2-1:0]     axi_bresp;

    reg                         rd_busy_q;
    reg      [ADDR_WIDTH-1:0]   rd_addr_q;
    reg      [7:0]              rd_len_q;
    reg      [7:0]              rd_beat_q;
    reg      [3:0]              rd_latency_q;

    reg                         wr_busy_q;
    reg      [ADDR_WIDTH-1:0]   wr_addr_q;
    reg      [7:0]              wr_beat_count_q;
    reg      [3:0]              wr_resp_latency_q;
    integer                     wr_shadow_idx_q;

    reg      [MEM_SHADOW_LINES-1:0] mem_shadow_valid;
    reg      [ADDR_WIDTH-1:0]   mem_shadow_addr [0:MEM_SHADOW_LINES-1];
    reg      [DATA_WIDTH-1:0]   mem_shadow_data [0:MEM_SHADOW_LINES-1][0:BEATS-1];
    integer                     mem_shadow_replace_q;

    integer                     axi_ar_count;
    integer                     axi_aw_count;
    integer                     axi_w_count;
    integer                     axi_b_count;
    integer                     axi_r_count;
    integer                     watchdog_i;
    integer                     shadow_i;
    integer                     shadow_j;
    integer                     shadow_b;
    integer                     shadow_idx;
    integer                     shadow_byte;
    integer                     evict_way_i;
    integer                     evict_beat_i;
    reg                         a5_conc_active;
    integer                     a5_conc_aw_seen;
    reg      [ADDR_WIDTH-1:0]   a5_conc_aw_addr0;
    reg      [ADDR_WIDTH-1:0]   a5_conc_aw_addr1;
    reg                         strict_cpu_sparse_write_active;
    reg      [ADDR_WIDTH-1:0]   strict_cpu_sparse_write_addr;
    reg      [DATA_WIDTH-1:0]   strict_cpu_sparse_write_data;
    integer                     strict_cpu_sparse_write_aw_count;
    integer                     strict_cpu_sparse_write_w_count;
    integer                     strict_cpu_sparse_write_b_count;
    reg                         direct_fwd_monitor_active;
    integer                     direct_fwd_rsp_fwd_count;
    integer                     direct_fwd_dat_count;
    integer                     direct_fwd_hn_dat_count;
    integer                     direct_fwd_hn_snp_data_count;
    integer                     direct_fwd_direct_bad_opcode_count;
    integer                     direct_fwd_hn_bad_opcode_count;
    integer                     direct_fwd_hn_snp_tracker_accept_count;
    integer                     direct_fwd_hn_snp_tracker_bad_opcode_count;
    integer                     direct_fwd_hn_rd_tracker_bad_accept_count;
    integer                     direct_fwd_direct_bad_home_count;
    integer                     direct_fwd_direct_legacy_src_count;
    integer                     direct_fwd_hn_bad_home_count;
    integer                     direct_fwd_compack_to_hn_count;
    integer                     direct_fwd_compack_to_owner_count;
    // Last SnpRespFwded from RN0 (Resp, FwdState) and last RN0->RN1 CompData
    // Resp.
    reg [2:0]                   direct_fwd_rsp_resp;
    reg [2:0]                   direct_fwd_rsp_fwd_state;
    reg [2:0]                   direct_fwd_cd_resp;
    reg                         allow_cpu_write_extra_axi;
    reg                         allow_chi_irq;
    reg                         axi_bp_enable;
    reg                         axi_r_hold;
    reg                         axi_b_hold;
    // When set, axi_b_hold only holds the BRESP of a write to axi_b_hold_addr.
    reg                         axi_b_hold_addr_en;
    reg      [ADDR_WIDTH-1:0]   axi_b_hold_addr;
    // Hold AXI W once the current burst has taken axi_w_hold_beat beats.
    reg                         axi_w_hold;
    reg      [7:0]              axi_w_hold_beat;
    reg      [(1<<TXN_ID_W)-1:0] sn_txn_busy;
    reg                         rn_watchdog_expected;
    // CG_ALWAYS: keep CTRL.cg_enable set for the whole run so every test
    // also checks that the clock-gate enable covers all in-flight work.
    reg                         cg_always;
    integer                     cg_gated_cycles = 0;
    integer                     fabric_clear_count = 0;
    reg                         axi_bp_random_enable;
    reg      [7:0]              axi_bp_cycle_q;
    reg      [15:0]             axi_bp_lfsr_q;
    reg                         test_failed;
    reg      [511:0]            current_test_id;
    reg      [511:0]            current_task_name;
    reg      [1023:0]           current_test_purpose;
    reg                         a2_tracker_clear;
    reg      [A2_NUM_HN-1:0]    a2_alloc_valid;
    wire     [A2_NUM_HN-1:0]    a2_alloc_ready;
    wire     [A2_NUM_HN*DBID_W-1:0] a2_alloc_dbid;
    wire     [A2_NUM_HN*A2_TRACKER_DEPTH-1:0] a2_active_valid_vec;
    wire     [A2_NUM_HN*16-1:0] a2_used_count;
    integer                     axi_ar_count_base;
    integer                     axi_aw_count_base;
    integer                     axi_w_count_base;
    integer                     axi_b_count_base;
    integer                     axi_r_count_base;
    genvar                      a2_hn_g;

    wire axi_arready_base = (!rd_busy_q && !axi_rvalid[0]) ? 1'b1 : 1'b0;
    wire axi_awready_base = (!wr_busy_q && !axi_bvalid[0]) ? 1'b1 : 1'b0;
    wire axi_wready_base  = wr_busy_q ? 1'b1 : 1'b0;
    wire axi_bp_ar_stall  = axi_bp_enable && (axi_bp_cycle_q[2:0] == 3'd0);
    wire axi_bp_aw_stall  = axi_bp_enable && (axi_bp_cycle_q[2:0] == 3'd1);
    wire axi_bp_w_stall   = axi_bp_enable && (axi_bp_cycle_q[1:0] == 2'd2);
    wire axi_bp_r_stall   = axi_bp_enable && (axi_bp_cycle_q[2:0] == 3'd3);
    wire axi_bp_b_stall   = axi_bp_enable && (axi_bp_cycle_q[2:0] == 3'd5);
    wire axi_bp_rand_ar_stall = axi_bp_random_enable && (axi_bp_lfsr_q[1:0] == 2'd0);
    wire axi_bp_rand_aw_stall = axi_bp_random_enable && (axi_bp_lfsr_q[2:1] == 2'd1);
    wire axi_bp_rand_w_stall  = axi_bp_random_enable && (axi_bp_lfsr_q[3:2] == 2'd2);
    wire axi_bp_rand_r_stall  = axi_bp_random_enable && (axi_bp_lfsr_q[4:3] == 2'd3);
    wire axi_bp_rand_b_stall  = axi_bp_random_enable && (axi_bp_lfsr_q[5:4] == 2'd1);
    wire [3:0] axi_bp_random_delay =
        {2'b00, axi_bp_lfsr_q[7:6]} + 4'd1;

    assign axi_arready = axi_arready_base && !axi_bp_ar_stall &&
                         !axi_bp_rand_ar_stall;
    assign axi_awready = axi_awready_base && !axi_bp_aw_stall &&
                         !axi_bp_rand_aw_stall;
    assign axi_wready  = axi_wready_base  && !axi_bp_w_stall &&
                         !axi_bp_rand_w_stall &&
                         !(axi_w_hold && (wr_beat_count_q >= axi_w_hold_beat));

    always #5 clk = ~clk;

    // An RN transaction timeout means a transaction was never completed by
    // the protocol and got reaped by the watchdog (it also emits a stray
    // zero-data CPU response). No test expects that, so it is a failure.
    genvar rn_to_g;
    generate
        for (rn_to_g = 0; rn_to_g < NUM_RN; rn_to_g = rn_to_g + 1) begin : gen_rn_timeout_mon
            always @(posedge clk) begin
                if (rstn && !rn_watchdog_expected &&
                    dut.gen_rn[rn_to_g].u_rn_f.timeout_valid) begin
                    $display("[%0t] RN%0d transaction timeout txn %0h",
                             $time, rn_to_g,
                             dut.gen_rn[rn_to_g].u_rn_f.timeout_txn_id);
                    tb_fail("RN transaction timeout: transaction never completed");
                end
            end
        end
    endgenerate

    // P0-3 window probe: the LLC eviction engine captured a victim while a
    // HN write tracker was still active (its burst may still be in flight).
    // p03_fwd_beats counts RN write beats HN has forwarded to the SN in the
    // current burst; non-zero means a HN->SN write burst is half sent.
    integer p03_window_count = 0;
    integer p03_midburst_count = 0;
    integer p03_fwd_beats = 0;
    always @(posedge clk) begin
        if (rstn && dut.gen_hn[0].u_hn_f.llc_evict_capture_fire &&
            !dut.gen_hn[0].u_hn_f.wr_trackers_idle) begin
            p03_window_count = p03_window_count + 1;
            if (p03_fwd_beats != 0)
                p03_midburst_count = p03_midburst_count + 1;
            $display("[%0t] P0-3 WINDOW evict captured while write tracker active fwd_beats=%0d",
                     $time, p03_fwd_beats);
        end
        if (rstn && dut.gen_hn[0].u_hn_f.mem_dat_valid &&
            dut.gen_hn[0].u_hn_f.mem_dat_ready &&
            !dut.gen_hn[0].u_hn_f.llc_evict_dat_valid)
            p03_fwd_beats = (p03_fwd_beats == DAT_BEATS - 1) ? 0 : p03_fwd_beats + 1;
    end

    // 2.7: DVM flits seen at the MN and at each RN's SNP port (T55).
    localparam integer MN0_NODE_ID = NUM_RN + NUM_HN + NUM_SN;
    reg        dvm_mon_on = 1'b0;
    integer    dvm_mon_snp [0:NUM_RN-1];
    reg [1:0]  dvm_mon_parts [0:NUM_RN-1];
    reg [`CHI_SNP_ADDR_W-1:0] dvm_mon_p1_addr [0:NUM_RN-1];
    reg [`CHI_SNP_ADDR_W-1:0] dvm_mon_p2_addr [0:NUM_RN-1];
    reg [NODE_ID_W-1:0] dvm_mon_p2_fwd_nid [0:NUM_RN-1];
    reg [TXN_ID_W-1:0]  dvm_mon_snp_txn [0:NUM_RN-1];
    integer    dvm_mon_txn_mismatch = 0;
    integer    dvm_mon_dat = 0;
    reg [63:0] dvm_mon_dat_data;
    reg [DAT_DATA_W/8-1:0] dvm_mon_dat_be;
    reg [3:0]  dvm_mon_dat_op;
    integer    dvm_mon_dbid = 0;
    integer    dvm_mon_comp = 0;
    integer    dvm_mon_snpresp = 0;

    task automatic dvm_mon_clear;
        integer i;
        begin
            for (i = 0; i < NUM_RN; i = i + 1) begin
                dvm_mon_snp[i] = 0;
                dvm_mon_parts[i] = 2'b00;
                dvm_mon_p1_addr[i] = '0;
                dvm_mon_p2_addr[i] = '0;
                dvm_mon_p2_fwd_nid[i] = '0;
                dvm_mon_snp_txn[i] = '0;
            end
            dvm_mon_txn_mismatch = 0;
            dvm_mon_dat = 0;
            dvm_mon_dat_data = '0;
            dvm_mon_dat_be = '0;
            dvm_mon_dat_op = '0;
            dvm_mon_dbid = 0;
            dvm_mon_comp = 0;
            dvm_mon_snpresp = 0;
        end
    endtask

    always @(posedge clk) begin : dvm_mon
        integer i;
        reg [`CHI_SNP_W(NODE_ID_W)-1:0] sf;
        reg [`CHI_RSP_W(NODE_ID_W)-1:0] rf;
        reg [DAT_W-1:0] df;
        if (rstn && dvm_mon_on) begin
            for (i = 0; i < NUM_RN; i = i + 1) begin
                sf = dut.snp_rn_out_flit[i*`CHI_SNP_W(NODE_ID_W) +: `CHI_SNP_W(NODE_ID_W)];
                if (dut.snp_rn_out_valid[i] && dut.snp_rn_out_ready[i] &&
                    (sf[`CHI_SNP_OPCODE_LSB(NODE_ID_W) +: `CHI_SNP_OPCODE_W] ==
                     `CHI_SNP_DVM_OP)) begin
                    if ((dvm_mon_snp[i] != 0) &&
                        (sf[`CHI_SNP_TXN_LSB(NODE_ID_W) +: TXN_ID_W] != dvm_mon_snp_txn[i]))
                        dvm_mon_txn_mismatch = dvm_mon_txn_mismatch + 1;
                    dvm_mon_snp_txn[i] = sf[`CHI_SNP_TXN_LSB(NODE_ID_W) +: TXN_ID_W];
                    dvm_mon_snp[i] = dvm_mon_snp[i] + 1;
                    if (sf[`CHI_SNP_ADDR_LSB(NODE_ID_W)]) begin
                        dvm_mon_parts[i][1] = 1'b1;
                        dvm_mon_p2_addr[i] =
                            sf[`CHI_SNP_ADDR_LSB(NODE_ID_W) +: `CHI_SNP_ADDR_W];
                        dvm_mon_p2_fwd_nid[i] =
                            sf[`CHI_SNP_FWD_NID_LSB(NODE_ID_W) +: NODE_ID_W];
                    end else begin
                        dvm_mon_parts[i][0] = 1'b1;
                        dvm_mon_p1_addr[i] =
                            sf[`CHI_SNP_ADDR_LSB(NODE_ID_W) +: `CHI_SNP_ADDR_W];
                    end
                end
            end
            df = dut.dat_node_out_flit[MN0_NODE_ID*DAT_W +: DAT_W];
            if (dut.dat_node_out_valid[MN0_NODE_ID] && dut.dat_node_out_ready[MN0_NODE_ID]) begin
                dvm_mon_dat = dvm_mon_dat + 1;
                dvm_mon_dat_op = df[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4];
                dvm_mon_dat_be = df[`CHI_DAT_BE_LSB(DAT_DATA_W,NODE_ID_W) +: DAT_DATA_W/8];
                dvm_mon_dat_data = df[`CHI_DAT_DATA_LSB(DAT_DATA_W,NODE_ID_W) +: 64];
            end
            rf = dut.mn_tx_rsp_flit[0 +: `CHI_RSP_W(NODE_ID_W)];
            if (dut.mn_tx_rsp_valid[0]) begin
                if (rf[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] == `CHI_RSP_DBID)
                    dvm_mon_dbid = dvm_mon_dbid + 1;
                if (rf[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] == `CHI_RSP_COMP)
                    dvm_mon_comp = dvm_mon_comp + 1;
            end
            rf = dut.rsp_node_out_flit[MN0_NODE_ID*`CHI_RSP_W(NODE_ID_W) +: `CHI_RSP_W(NODE_ID_W)];
            if (dut.rsp_node_out_valid[MN0_NODE_ID] && dut.rsp_node_out_ready[MN0_NODE_ID] &&
                (rf[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] == `CHI_RSP_SNP_RESP))
                dvm_mon_snpresp = dvm_mon_snpresp + 1;
        end
    end

    // 2.8: RN0 MakeUnique on MU_ADDR (T56): the REQ at HN0, its Comp and
    // CompAck, and the snoops to each RN on that line after the Comp.
    reg        mu_mon_on = 1'b0;
    integer    mu_mon_req = 0;
    reg        mu_mon_exp_ack = 1'b0;
    integer    mu_mon_comp = 0;
    reg [DBID_W-1:0]   mu_mon_comp_dbid = '0;
    integer    mu_mon_ack = 0;
    reg [TXN_ID_W-1:0] mu_mon_ack_txn = '0;
    integer    mu_mon_snp0 = 0;
    integer    mu_mon_snp1 = 0;
    longint    mu_mon_cycle = 0;
    longint    mu_mon_ack_cycle = 0;
    longint    mu_mon_snp0_cycle = 0;

    // 3.4, while sysco_mon_on: snoops handed to each RN, and the snoop-filter
    // entries that still listed an RN when its SYSCOACK fell.
    reg     sysco_mon_on = 1'b0;
    integer sysco_mon_snp [0:NUM_RN-1];
    integer sysco_mon_listed [0:NUM_RN-1];
    reg [NUM_RN-1:0] sysco_mon_ack_q = {NUM_RN{1'b0}};

    always @(posedge clk) begin : sysco_mon
        integer i;
        if (rstn && sysco_mon_on) begin
            for (i = 0; i < NUM_RN; i = i + 1) begin
                if (dut.snp_rn_out_valid[i] && dut.snp_rn_out_ready[i])
                    sysco_mon_snp[i] = sysco_mon_snp[i] + 1;
                if (sysco_mon_ack_q[i] && !dut.rn_syscoack[i])
                    sysco_mon_listed[i] = sysco_mon_listed[i] +
                                          sf_entries_listing_rn(i);
            end
        end
        sysco_mon_ack_q = dut.rn_syscoack;
    end

    task automatic mu_mon_clear;
        begin
            mu_mon_req = 0;
            mu_mon_exp_ack = 1'b0;
            mu_mon_comp = 0;
            mu_mon_comp_dbid = '0;
            mu_mon_ack = 0;
            mu_mon_ack_txn = '0;
            mu_mon_snp0 = 0;
            mu_mon_snp1 = 0;
            mu_mon_ack_cycle = 0;
            mu_mon_snp0_cycle = 0;
        end
    endtask

    always @(posedge clk) begin : mu_mon
        reg [`CHI_REQ_W(NODE_ID_W)-1:0] qf;
        reg [`CHI_RSP_W(NODE_ID_W)-1:0] rf;
        reg [`CHI_SNP_W(NODE_ID_W)-1:0] sf;
        reg [ADDR_WIDTH-1:0] sa;
        integer i;
        mu_mon_cycle = mu_mon_cycle + 1;
        if (rstn && mu_mon_on) begin
            qf = dut.req_tgt_flit[0 +: `CHI_REQ_W(NODE_ID_W)];
            if (dut.req_tgt_valid[0] && dut.req_tgt_ready[0] &&
                (qf[`CHI_REQ_OPCODE_LSB(NODE_ID_W) +: `CHI_REQ_OPCODE_W] == `CHI_REQ_MK_UNIQUE) &&
                (qf[`CHI_REQ_SRC_LSB(NODE_ID_W) +: NODE_ID_W] == 0)) begin
                mu_mon_req = mu_mon_req + 1;
                mu_mon_exp_ack = qf[`CHI_REQ_EXP_COMP_ACK_LSB(NODE_ID_W)];
            end
            rf = dut.rsp_node_out_flit[0 +: `CHI_RSP_W(NODE_ID_W)];
            if (dut.rsp_node_out_valid[0] && dut.rsp_node_out_ready[0] &&
                (mu_mon_req != 0) && (mu_mon_comp == 0) &&
                (rf[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] == `CHI_RSP_COMP)) begin
                mu_mon_comp = mu_mon_comp + 1;
                mu_mon_comp_dbid = rf[`CHI_RSP_DBID_LSB(NODE_ID_W) +: DBID_W];
            end
            rf = dut.rsp_node_out_flit[HN0_NODE_ID*`CHI_RSP_W(NODE_ID_W) +: `CHI_RSP_W(NODE_ID_W)];
            if (dut.rsp_node_out_valid[HN0_NODE_ID] && dut.rsp_node_out_ready[HN0_NODE_ID] &&
                (mu_mon_comp != 0) && (mu_mon_ack == 0) &&
                (rf[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] == `CHI_RSP_COMP_ACK) &&
                (rf[`CHI_RSP_SRC_LSB(NODE_ID_W) +: NODE_ID_W] == 0)) begin
                mu_mon_ack = mu_mon_ack + 1;
                mu_mon_ack_txn = rf[`CHI_RSP_TXN_LSB(NODE_ID_W) +: TXN_ID_W];
                mu_mon_ack_cycle = mu_mon_cycle;
            end
            for (i = 0; i < 2; i = i + 1) begin
                sf = dut.snp_rn_out_flit[i*`CHI_SNP_W(NODE_ID_W) +: `CHI_SNP_W(NODE_ID_W)];
                sa = {sf[`CHI_SNP_ADDR_LSB(NODE_ID_W) +: ADDR_WIDTH-3], 3'b000};
                if (dut.snp_rn_out_valid[i] && dut.snp_rn_out_ready[i] &&
                    (sa[ADDR_WIDTH-1:6] == MU_ADDR[ADDR_WIDTH-1:6])) begin
                    if (i == 1)
                        mu_mon_snp1 = mu_mon_snp1 + 1;
                    else if (mu_mon_comp != 0) begin
                        if (mu_mon_snp0 == 0)
                            mu_mon_snp0_cycle = mu_mon_cycle;
                        mu_mon_snp0 = mu_mon_snp0 + 1;
                    end
                end
            end
        end
    end

    // 1.5: most HN write trackers active at once, and WriteData beats at
    // the SN that switch to another write before the previous burst is
    // complete (interleaved bursts).
    integer mw_active_max = 0;
    integer mw_interleave_count = 0;
    int     mw_beats [int];
    int     mw_prev_txn = -1;
    always @(posedge clk) begin : mw_mon
        int txn;
        if (rstn && ($countones(dut.gen_hn[0].u_hn_f.wr_tracker_active_valid_vec) > mw_active_max))
            mw_active_max = $countones(dut.gen_hn[0].u_hn_f.wr_tracker_active_valid_vec);
        if (rstn && dut.gen_sn[0].u_sn_f.rx_dat_valid &&
            dut.gen_sn[0].u_sn_f.rx_dat_ready) begin
            txn = dut.gen_sn[0].u_sn_f.rx_dat_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W];
            if ($test$plusargs("MW_TRACE"))
                $display("[%0t] MW_TRACE SN beat txn=%0d dataid=%0d", $time, txn,
                         dut.gen_sn[0].u_sn_f.rx_dat_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W]);
            if ((mw_prev_txn >= 0) && (txn != mw_prev_txn) &&
                mw_beats.exists(mw_prev_txn) && (mw_beats[mw_prev_txn] != 0))
                mw_interleave_count = mw_interleave_count + 1;
            if (!mw_beats.exists(txn))
                mw_beats[txn] = 0;
            mw_beats[txn] = (mw_beats[txn] + 1) % DAT_BEATS;
            mw_prev_txn = txn;
        end
    end

    always @(posedge clk) begin
        if (rstn && !dut.chi_cg_en)
            cg_gated_cycles = cg_gated_cycles + 1;
        if (rstn && dut.fabric_clear)
            fabric_clear_count = fabric_clear_count + 1;
    end

    // CHI B2.5.1: a requester must not reuse a TxnID that is still
    // outstanding at the same completer. Track HN->SN requests from REQ
    // accept at the SN until Comp (write) or the last CompData beat (read).
    always @(posedge clk or negedge rstn) begin : sn_txn_unique_mon
        reg [TXN_ID_W-1:0] req_txn;
        reg [(1<<TXN_ID_W)-1:0] next_busy;
        if (!rstn) begin
            sn_txn_busy <= {(1<<TXN_ID_W){1'b0}};
        end else begin
            next_busy = sn_txn_busy;
            // A write ends at its Comp (the DBIDResp before it does not).
            if (dut.gen_sn[0].u_sn_f.tx_rsp_valid &&
                (dut.gen_sn[0].u_sn_f.tx_rsp_flit[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] == `CHI_RSP_COMP))
                next_busy[dut.gen_sn[0].u_sn_f.tx_rsp_flit[`CHI_RSP_TXN_LSB(NODE_ID_W) +: TXN_ID_W]] = 1'b0;
            if (dut.gen_sn[0].u_sn_f.tx_dat_valid &&
                (dut.gen_sn[0].u_sn_f.tx_dat_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W] == DAT_BEATS - 1))
                next_busy[dut.gen_sn[0].u_sn_f.tx_dat_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W]] = 1'b0;
            if (dut.gen_sn[0].u_sn_f.rx_req_valid &&
                dut.gen_sn[0].u_sn_f.rx_req_ready) begin
                req_txn = dut.gen_sn[0].u_sn_f.rx_req_flit[`CHI_REQ_TXN_LSB(NODE_ID_W) +: TXN_ID_W];
                if (next_busy[req_txn]) begin
                    $display("[%0t] SN TxnID 0x%0h reused while still outstanding", $time, req_txn);
                    tb_fail("HN->SN TxnID reused while outstanding at SN");
                end
                next_busy[req_txn] = 1'b1;
            end
            sn_txn_busy <= next_busy;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            axi_bp_cycle_q <= 8'd0;
            axi_bp_lfsr_q  <= 16'hACE1;
        end else if (axi_bp_random_enable) begin
            axi_bp_cycle_q <= axi_bp_cycle_q + 1'b1;
            axi_bp_lfsr_q <= {axi_bp_lfsr_q[14:0],
                              axi_bp_lfsr_q[15] ^
                              axi_bp_lfsr_q[13] ^
                              axi_bp_lfsr_q[12] ^
                              axi_bp_lfsr_q[10]};
        end else if (axi_bp_enable) begin
            axi_bp_cycle_q <= axi_bp_cycle_q + 1'b1;
        end else begin
            axi_bp_cycle_q <= 8'd0;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            direct_fwd_monitor_active <= 1'b0;
            direct_fwd_rsp_fwd_count  <= 0;
            direct_fwd_dat_count      <= 0;
            direct_fwd_hn_dat_count   <= 0;
            direct_fwd_hn_snp_data_count <= 0;
            direct_fwd_direct_bad_opcode_count <= 0;
            direct_fwd_hn_bad_opcode_count <= 0;
            direct_fwd_hn_snp_tracker_accept_count <= 0;
            direct_fwd_hn_snp_tracker_bad_opcode_count <= 0;
            direct_fwd_hn_rd_tracker_bad_accept_count <= 0;
            direct_fwd_direct_bad_home_count <= 0;
            direct_fwd_direct_legacy_src_count <= 0;
            direct_fwd_hn_bad_home_count <= 0;
            direct_fwd_compack_to_hn_count <= 0;
            direct_fwd_compack_to_owner_count <= 0;
            direct_fwd_rsp_resp <= 3'd0;
            direct_fwd_rsp_fwd_state <= 3'd0;
            direct_fwd_cd_resp <= 3'd0;
        end else if (direct_fwd_monitor_active) begin
            if (dut.gen_rn[0].u_rn_f.tx_rsp_valid &&
                (dut.gen_rn[0].u_rn_f.tx_rsp_flit[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] ==
                 `CHI_RSP_SNP_RESP_FWD) &&
                (dut.gen_rn[0].u_rn_f.tx_rsp_flit[`CHI_RSP_SRC_LSB(NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_rsp_flit[`CHI_RSP_TGT_LSB(NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC)) begin
                direct_fwd_rsp_fwd_count <= direct_fwd_rsp_fwd_count + 1;
                direct_fwd_rsp_resp <=
                    dut.gen_rn[0].u_rn_f.tx_rsp_flit[`CHI_RSP_RESP_LSB(NODE_ID_W) +: 3];
                direct_fwd_rsp_fwd_state <=
                    dut.gen_rn[0].u_rn_f.tx_rsp_flit[`CHI_RSP_FWD_STATE_LSB(NODE_ID_W) +: 3];
            end

            if (dut.gen_rn[0].u_rn_f.tx_dat_valid &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] ==
                 `CHI_DAT_OPCODE_RD_DATA) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN1_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_HOME_NID_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC)) begin
                direct_fwd_dat_count <= direct_fwd_dat_count + 1;
                direct_fwd_cd_resp <=
                    dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_RESP_LSB(DAT_DATA_W,NODE_ID_W) +: 3];
            end

            if (dut.gen_rn[0].u_rn_f.tx_dat_valid &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN1_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] !=
                 `CHI_DAT_OPCODE_RD_DATA)) begin
                direct_fwd_direct_bad_opcode_count <= direct_fwd_direct_bad_opcode_count + 1;
            end

            if (dut.gen_rn[0].u_rn_f.tx_dat_valid &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] ==
                 `CHI_DAT_OPCODE_RD_DATA) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN1_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_HOME_NID_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] !=
                 HN0_NODE_ID_VEC)) begin
                direct_fwd_direct_bad_home_count <= direct_fwd_direct_bad_home_count + 1;
            end

            if (dut.gen_rn[0].u_rn_f.tx_dat_valid &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] ==
                 `CHI_DAT_OPCODE_RD_DATA) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN1_NODE_ID_VEC)) begin
                direct_fwd_direct_legacy_src_count <= direct_fwd_direct_legacy_src_count + 1;
            end

            if (dut.gen_hn[0].u_hn_f.tx_dat_valid &&
                (dut.gen_hn[0].u_hn_f.tx_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] ==
                 `CHI_DAT_OPCODE_RD_DATA) &&
                (dut.gen_hn[0].u_hn_f.tx_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC) &&
                (dut.gen_hn[0].u_hn_f.tx_dat_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN1_NODE_ID_VEC)) begin
                direct_fwd_hn_dat_count <= direct_fwd_hn_dat_count + 1;
            end

            if (dut.gen_rn[0].u_rn_f.tx_dat_valid &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] ==
                 `CHI_DAT_OPCODE_SNP_DATA) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_HOME_NID_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC)) begin
                direct_fwd_hn_snp_data_count <= direct_fwd_hn_snp_data_count + 1;
            end

            if (dut.gen_rn[0].u_rn_f.tx_dat_valid &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] !=
                 `CHI_DAT_OPCODE_SNP_DATA)) begin
                direct_fwd_hn_bad_opcode_count <= direct_fwd_hn_bad_opcode_count + 1;
            end

            if (dut.gen_rn[0].u_rn_f.tx_dat_valid &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] ==
                 `CHI_DAT_OPCODE_SNP_DATA) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC) &&
                (dut.gen_rn[0].u_rn_f.tx_dat_flit[`CHI_DAT_HOME_NID_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] !=
                 HN0_NODE_ID_VEC)) begin
                direct_fwd_hn_bad_home_count <= direct_fwd_hn_bad_home_count + 1;
            end

            if (dut.gen_hn[0].u_hn_f.dat_sink_valid &&
                dut.gen_hn[0].u_hn_f.dat_sink_out_ready &&
                dut.gen_hn[0].u_hn_f.snp_tracker_dat_match &&
                (dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC) &&
                (dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] ==
                 `CHI_DAT_OPCODE_SNP_DATA) &&
                (dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_HOME_NID_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC)) begin
                direct_fwd_hn_snp_tracker_accept_count <= direct_fwd_hn_snp_tracker_accept_count + 1;
            end

            if (dut.gen_hn[0].u_hn_f.dat_sink_valid &&
                dut.gen_hn[0].u_hn_f.snp_tracker_dat_match &&
                (dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] !=
                 `CHI_DAT_OPCODE_SNP_DATA) &&
                (dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_OPCODE_LSB(DAT_DATA_W,NODE_ID_W) +: 4] !=
                 `CHI_DAT_OPCODE_SNP_DATA_FWD)) begin
                direct_fwd_hn_snp_tracker_bad_opcode_count <= direct_fwd_hn_snp_tracker_bad_opcode_count + 1;
            end

            if (dut.gen_hn[0].u_hn_f.dat_sink_valid &&
                dut.gen_hn[0].u_hn_f.rd_tracker_dat_match &&
                (dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_SRC_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC) &&
                (dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_TGT_LSB(DAT_DATA_W,NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC)) begin
                direct_fwd_hn_rd_tracker_bad_accept_count <= direct_fwd_hn_rd_tracker_bad_accept_count + 1;
            end

            if (dut.gen_rn[1].u_rn_f.tx_rsp_valid &&
                (dut.gen_rn[1].u_rn_f.tx_rsp_flit[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] ==
                 `CHI_RSP_COMP_ACK) &&
                (dut.gen_rn[1].u_rn_f.tx_rsp_flit[`CHI_RSP_SRC_LSB(NODE_ID_W) +: NODE_ID_W] ==
                 RN1_NODE_ID_VEC) &&
                (dut.gen_rn[1].u_rn_f.tx_rsp_flit[`CHI_RSP_TGT_LSB(NODE_ID_W) +: NODE_ID_W] ==
                 HN0_NODE_ID_VEC)) begin
                direct_fwd_compack_to_hn_count <= direct_fwd_compack_to_hn_count + 1;
            end

            if (dut.gen_rn[1].u_rn_f.tx_rsp_valid &&
                (dut.gen_rn[1].u_rn_f.tx_rsp_flit[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W] ==
                 `CHI_RSP_COMP_ACK) &&
                (dut.gen_rn[1].u_rn_f.tx_rsp_flit[`CHI_RSP_SRC_LSB(NODE_ID_W) +: NODE_ID_W] ==
                 RN1_NODE_ID_VEC) &&
                (dut.gen_rn[1].u_rn_f.tx_rsp_flit[`CHI_RSP_TGT_LSB(NODE_ID_W) +: NODE_ID_W] ==
                 RN0_NODE_ID_VEC)) begin
                direct_fwd_compack_to_owner_count <= direct_fwd_compack_to_owner_count + 1;
            end
        end
    end

    function automatic [ADDR_WIDTH-1:0] mem_line_base;
        input [ADDR_WIDTH-1:0] addr;
        begin
            mem_line_base = {addr[ADDR_WIDTH-1:6], 6'b0};
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] base_mem_pattern;
        input [ADDR_WIDTH-1:0] addr;
        input integer beat;
        reg [63:0] seed;
        reg [ADDR_WIDTH-1:0] line_addr;
        begin
            // Memory contents depend only on the line and beat, so an
            // unaligned request address sees the same word as the AXI
            // model, which indexes lines by their aligned AR/AW address.
            line_addr = mem_line_base(addr);
            seed = {line_addr[31:0] ^ (beat * 32'h0101_0101),
                    line_addr[31:0] + 32'hA5A5_0000 + beat};
            base_mem_pattern = seed[DATA_WIDTH-1:0];
        end
    endfunction

    function automatic integer mem_shadow_find;
        input [ADDR_WIDTH-1:0] addr;
        integer i;
        reg [ADDR_WIDTH-1:0] line_addr;
        begin
            line_addr = mem_line_base(addr);
            mem_shadow_find = -1;
            for (i = 0; i < MEM_SHADOW_LINES; i = i + 1) begin
                if (mem_shadow_valid[i] &&
                    (mem_shadow_addr[i] == line_addr))
                    mem_shadow_find = i;
            end
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] mem_pattern;
        input [ADDR_WIDTH-1:0] addr;
        input integer beat;
        integer idx;
        begin
            idx = mem_shadow_find(addr);
            if (idx >= 0)
                mem_pattern = mem_shadow_data[idx][beat];
            else
                mem_pattern = base_mem_pattern(addr, beat);
        end
    endfunction

    function automatic [LLC_TAG_W-1:0] llc_tag;
        input [ADDR_WIDTH-1:0] addr;
        begin
            llc_tag = addr[ADDR_WIDTH-1 -: LLC_TAG_W];
        end
    endfunction

    function automatic [LLC_SET_W-1:0] llc_set;
        input [ADDR_WIDTH-1:0] addr;
        begin
            llc_set = addr[6 +: LLC_SET_W];
        end
    endfunction

    function automatic [RN_CACHE_SET_W-1:0] rn_cache_set;
        input [ADDR_WIDTH-1:0] addr;
        begin
            rn_cache_set = addr[6 +: RN_CACHE_SET_W];
        end
    endfunction

    function automatic [RN_CACHE_TAG_W-1:0] rn_cache_tag;
        input [ADDR_WIDTH-1:0] addr;
        begin
            rn_cache_tag = addr[ADDR_WIDTH-1 -: RN_CACHE_TAG_W];
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] dirty_evict_word;
        input integer beat;
        begin
            dirty_evict_word = EVICT_DATA_BASE + beat[DATA_WIDTH-1:0];
        end
    endfunction

    function automatic [LINE_WIDTH-1:0] dirty_evict_line;
        integer beat;
        begin
            dirty_evict_line = {LINE_WIDTH{1'b0}};
            for (beat = 0; beat < BEATS; beat = beat + 1)
                dirty_evict_line[beat*DATA_WIDTH +: DATA_WIDTH] =
                    dirty_evict_word(beat);
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] apply_sparse_store_word;
        input [DATA_WIDTH-1:0] orig_word;
        input [DATA_WIDTH-1:0] store_data;
        input [2:0] size;
        input [1:0] byte_off;
        reg [DATA_WIDTH-1:0] result;
        begin
            result = orig_word;
            case (size)
                3'd0: begin
                    case (byte_off)
                        2'b00: result[7:0]   = store_data[7:0];
                        2'b01: result[15:8]  = store_data[7:0];
                        2'b10: result[23:16] = store_data[7:0];
                        2'b11: result[31:24] = store_data[7:0];
                    endcase
                end
                3'd1: begin
                    if (byte_off[1] == 1'b0)
                        result[15:0] = store_data[15:0];
                    else
                        result[31:16] = store_data[15:0];
                end
                default: result = store_data;
            endcase
            apply_sparse_store_word = result;
        end
    endfunction

    function automatic [LINE_WIDTH-1:0] clean_seed_line;
        input [ADDR_WIDTH-1:0] addr;
        integer beat;
        begin
            clean_seed_line = {LINE_WIDTH{1'b0}};
            for (beat = 0; beat < BEATS; beat = beat + 1)
                clean_seed_line[beat*DATA_WIDTH +: DATA_WIDTH] =
                base_mem_pattern(addr, beat);
        end
    endfunction

    task automatic llc_backdoor_seed_hn_slot_line;
        input [ADDR_WIDTH-1:0] addr;
        input integer set_idx;
        begin
            wait_cycles(2);
            // The LLC changes behind the interconnect: the scoreboard must
            // relearn this line.
            sb_forget_line(addr);
            dut.gen_hn[0].u_hn_f.u_llc.plru_mem[set_idx] = 3'b000;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].valid_mem[set_idx] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[set_idx] =
                {llc_tag(addr), `CHI_STATE_SC};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].data_mem[set_idx] =
                clean_seed_line(addr);
            wait_cycles(1);
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].valid_mem[set_idx] !== 1'b1) begin
                tb_fail("HN slot LLC seed valid bit failed");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[set_idx] !==
                {llc_tag(addr), `CHI_STATE_SC}) begin
                tb_fail("HN slot LLC seed metadata failed");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].data_mem[set_idx] !==
                clean_seed_line(addr)) begin
                tb_fail("HN slot LLC seed data failed");
                return;
            end
            $display("[%0t] TEST STEP  %0s task=%0s hn_slot_llc_seed addr=0x%011h set=%0d",
                     $time, current_test_id, current_task_name,
                     addr, set_idx);
        end
    endtask

    task automatic tb_test_start;
        input [511:0] id;
        input [511:0] task_name;
        input [1023:0] purpose;
        begin
            current_test_id = id;
            current_task_name = task_name;
            current_test_purpose = purpose;
            $display("[%0t] TEST START %0s task=%0s purpose=%0s",
                     $time, current_test_id, current_task_name,
                     current_test_purpose);
        end
    endtask

    task automatic tb_test_pass;
        input [1023:0] detail;
        begin
            $display("[%0t] TEST PASS  %0s task=%0s detail=%0s",
                     $time, current_test_id, current_task_name, detail);
        end
    endtask

    task automatic tb_fail;
        input [1023:0] msg;
        begin
            test_failed = 1'b1;
            $display("[%0t] TEST FAIL  %0s task=%0s reason=%0s",
                     $time, current_test_id, current_task_name, msg);
            #1;
            $finish;
        end
    endtask

    // tb_fail for a formatted message ($sformatf gives a string).
    task automatic tb_fail_str;
        input string msg;
        begin
            test_failed = 1'b1;
            $display("[%0t] TEST FAIL  %0s task=%0s reason=%0s",
                     $time, current_test_id, current_task_name, msg);
            #1;
            $finish;
        end
    endtask

    task automatic wait_cycles;
        input integer cycles;
        integer i;
        begin
            for (i = 0; i < cycles; i = i + 1)
                @(posedge clk);
        end
    endtask

    // Wait until no AXI write has been observed for quiet_cycles cycles.
    // Background RN dirty-victim writebacks can follow a CPU write; tests
    // that count AXI writes for a later operation must let them drain.
    task automatic wait_axi_write_quiet;
        input integer quiet_cycles;
        integer quiet;
        integer timeout;
        integer aw_seen;
        begin
            quiet = 0;
            timeout = 0;
            aw_seen = axi_aw_count;
            while ((quiet < quiet_cycles) && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if ((axi_aw_count != aw_seen) || wr_busy_q ||
                    (wr_resp_latency_q != 4'd0) || axi_bvalid[0]) begin
                    aw_seen = axi_aw_count;
                    quiet = 0;
                end else begin
                    quiet = quiet + 1;
                end
            end
            if (quiet < quiet_cycles)
                tb_fail("AXI write traffic did not go quiet");
        end
    endtask

    task automatic rn_cache_lookup;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        output reg found;
        output reg [2:0] state;
        output integer way;
        reg [RN_CACHE_SET_W-1:0] set;
        reg [RN_CACHE_TAG_W-1:0] tag;
        begin
            set = rn_cache_set(addr);
            tag = rn_cache_tag(addr);
            found = 1'b0;
            state = `CHI_STATE_I;
            way = -1;

            if (rn_idx == 0) begin
                if (!found &&
                    dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[0].valid_mem[set] &&
                    (dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[0].meta_mem[set][RN_META_TAG_LSB +: RN_CACHE_TAG_W] == tag)) begin
                    found = 1'b1;
                    state = dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[0].meta_mem[set][RN_META_STATE_LSB +: 3];
                    way = 0;
                end
                if (!found &&
                    dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[1].valid_mem[set] &&
                    (dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[1].meta_mem[set][RN_META_TAG_LSB +: RN_CACHE_TAG_W] == tag)) begin
                    found = 1'b1;
                    state = dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[1].meta_mem[set][RN_META_STATE_LSB +: 3];
                    way = 1;
                end
                if (!found &&
                    dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[2].valid_mem[set] &&
                    (dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[2].meta_mem[set][RN_META_TAG_LSB +: RN_CACHE_TAG_W] == tag)) begin
                    found = 1'b1;
                    state = dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[2].meta_mem[set][RN_META_STATE_LSB +: 3];
                    way = 2;
                end
                if (!found &&
                    dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[3].valid_mem[set] &&
                    (dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[3].meta_mem[set][RN_META_TAG_LSB +: RN_CACHE_TAG_W] == tag)) begin
                    found = 1'b1;
                    state = dut.gen_rn[0].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[3].meta_mem[set][RN_META_STATE_LSB +: 3];
                    way = 3;
                end
            end else begin
                if (!found &&
                    dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[0].valid_mem[set] &&
                    (dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[0].meta_mem[set][RN_META_TAG_LSB +: RN_CACHE_TAG_W] == tag)) begin
                    found = 1'b1;
                    state = dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[0].meta_mem[set][RN_META_STATE_LSB +: 3];
                    way = 0;
                end
                if (!found &&
                    dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[1].valid_mem[set] &&
                    (dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[1].meta_mem[set][RN_META_TAG_LSB +: RN_CACHE_TAG_W] == tag)) begin
                    found = 1'b1;
                    state = dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[1].meta_mem[set][RN_META_STATE_LSB +: 3];
                    way = 1;
                end
                if (!found &&
                    dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[2].valid_mem[set] &&
                    (dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[2].meta_mem[set][RN_META_TAG_LSB +: RN_CACHE_TAG_W] == tag)) begin
                    found = 1'b1;
                    state = dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[2].meta_mem[set][RN_META_STATE_LSB +: 3];
                    way = 2;
                end
                if (!found &&
                    dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[3].valid_mem[set] &&
                    (dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[3].meta_mem[set][RN_META_TAG_LSB +: RN_CACHE_TAG_W] == tag)) begin
                    found = 1'b1;
                    state = dut.gen_rn[1].u_rn_f.gen_internal_rn_cache.u_rn_cache.gen_way_ram[3].meta_mem[set][RN_META_STATE_LSB +: 3];
                    way = 3;
                end
            end
        end
    endtask

    task automatic rn_cache_expect_state;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        input exp_valid;
        input [2:0] exp_state;
        input [1023:0] name;
        integer timeout;
        integer way;
        reg found;
        reg [2:0] state;
        begin
            timeout = 0;
            rn_cache_lookup(rn_idx, addr, found, state, way);
            while (((found !== exp_valid) ||
                    (exp_valid && (state !== exp_state))) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                rn_cache_lookup(rn_idx, addr, found, state, way);
            end

            if (found !== exp_valid) begin
                $display("[%0t] TEST STEP  %0s task=%0s RN%0d cache valid mismatch step=%0s addr=0x%011h exp_valid=%0b got_valid=%0b state=%0d way=%0d",
                         $time, current_test_id, current_task_name,
                         rn_idx, name, addr, exp_valid, found, state, way);
                tb_fail("RN cache valid mismatch");
                return;
            end

            if (exp_valid && (state !== exp_state)) begin
                $display("[%0t] TEST STEP  %0s task=%0s RN%0d cache state mismatch step=%0s addr=0x%011h exp_state=%0d got_state=%0d way=%0d",
                         $time, current_test_id, current_task_name,
                         rn_idx, name, addr, exp_state, state, way);
                tb_fail("RN cache state mismatch");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s RN%0d cache step=%0s addr=0x%011h valid=%0b state=%0d way=%0d",
                     $time, current_test_id, current_task_name,
                     rn_idx, name, addr, found, state, way);
        end
    endtask

    task automatic llc_expect_line_word;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] exp_word;
        input [2:0] exp_state;
        input [1023:0] name;
        integer timeout;
        integer way;
        reg found;
        reg [2:0] state;
        reg [DATA_WIDTH-1:0] word;
        reg [LLC_SET_W-1:0] set;
        reg [LLC_TAG_W-1:0] tag;
        begin
            timeout = 0;
            found = 1'b0;
            state = `CHI_STATE_I;
            word = {DATA_WIDTH{1'b0}};
            way = -1;
            set = llc_set(addr);
            tag = llc_tag(addr);

            while (!found && (timeout < MAX_WAIT)) begin
                if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].valid_mem[set] &&
                    (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[set][3 +: LLC_TAG_W] == tag) &&
                    (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[set][2:0] == exp_state) &&
                    (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].data_mem[set][0 +: DATA_WIDTH] == exp_word)) begin
                    found = 1'b1;
                    state = dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[set][2:0];
                    word = dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].data_mem[set][0 +: DATA_WIDTH];
                    way = 0;
                end else if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].valid_mem[set] &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].meta_mem[set][3 +: LLC_TAG_W] == tag) &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].meta_mem[set][2:0] == exp_state) &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].data_mem[set][0 +: DATA_WIDTH] == exp_word)) begin
                    found = 1'b1;
                    state = dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].meta_mem[set][2:0];
                    word = dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].data_mem[set][0 +: DATA_WIDTH];
                    way = 1;
                end else if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].valid_mem[set] &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].meta_mem[set][3 +: LLC_TAG_W] == tag) &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].meta_mem[set][2:0] == exp_state) &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].data_mem[set][0 +: DATA_WIDTH] == exp_word)) begin
                    found = 1'b1;
                    state = dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].meta_mem[set][2:0];
                    word = dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].data_mem[set][0 +: DATA_WIDTH];
                    way = 2;
                end else if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].valid_mem[set] &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].meta_mem[set][3 +: LLC_TAG_W] == tag) &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].meta_mem[set][2:0] == exp_state) &&
                             (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].data_mem[set][0 +: DATA_WIDTH] == exp_word)) begin
                    found = 1'b1;
                    state = dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].meta_mem[set][2:0];
                    word = dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].data_mem[set][0 +: DATA_WIDTH];
                    way = 3;
                end else begin
                    timeout = timeout + 1;
                    @(posedge clk);
                end
            end

            if (!found) begin
                tb_fail("LLC copied line not found");
                return;
            end

            if (state !== exp_state) begin
                $display("[%0t] TEST STEP  %0s task=%0s LLC state mismatch step=%0s addr=0x%011h exp_state=%0d got_state=%0d way=%0d",
                         $time, current_test_id, current_task_name,
                         name, addr, exp_state, state, way);
                tb_fail("LLC copied line state mismatch");
                return;
            end

            if (word !== exp_word) begin
                $display("[%0t] TEST STEP  %0s task=%0s LLC data mismatch step=%0s addr=0x%011h exp=0x%08h got=0x%08h way=%0d",
                         $time, current_test_id, current_task_name,
                         name, addr, exp_word, word, way);
                tb_fail("LLC copied line data mismatch");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s LLC copy step=%0s addr=0x%011h state=%0d word0=0x%08h way=%0d",
                     $time, current_test_id, current_task_name,
                     name, addr, state, word, way);
        end
    endtask

    task automatic csr_write64;
        input [7:0] addr;
        input [63:0] data;
        integer timeout;
        begin
            @(negedge clk);
            csr_valid = 1'b1;
            csr_write = 1'b1;
            csr_addr  = addr;
            csr_wdata = data;
            if (cg_always && (addr == 8'h00))
                csr_wdata[2] = 1'b1;

            timeout = 0;
            while (timeout < MAX_WAIT) begin
                @(posedge clk);
                if (csr_ready)
                    timeout = MAX_WAIT;
                else
                    timeout = timeout + 1;
            end
            if (!csr_ready) begin
                tb_fail("CSR write timeout");
                return;
            end

            @(negedge clk);
            csr_valid = 1'b0;
            csr_write = 1'b0;
            csr_addr  = 8'h00;
            csr_wdata = 64'd0;
        end
    endtask

    task automatic csr_read_check;
        input [7:0] addr;
        input [63:0] exp_data;
        input [63:0] mask;
        integer timeout;
        begin
            @(negedge clk);
            csr_valid = 1'b1;
            csr_write = 1'b0;
            csr_addr  = addr;
            csr_wdata = 64'd0;

            timeout = 0;
            while (timeout < MAX_WAIT) begin
                @(posedge clk);
                if (csr_ready)
                    timeout = MAX_WAIT;
                else
                    timeout = timeout + 1;
            end
            if (!csr_ready) begin
                tb_fail("CSR read timeout");
                return;
            end

            if (cg_always && (addr == 8'h00))
                mask[2] = 1'b0;
            if ((csr_rdata & mask) !== (exp_data & mask)) begin
                $display("[%0t] TEST STEP  %0s task=%0s CSR read mismatch addr=0x%02h exp=0x%016h got=0x%016h mask=0x%016h",
                         $time, current_test_id, current_task_name,
                         addr, exp_data, csr_rdata, mask);
                tb_fail("CSR read data mismatch");
                return;
            end

            @(negedge clk);
            csr_valid = 1'b0;
            csr_addr  = 8'h00;
        end
    endtask

    task automatic csr_read_value;
        input [7:0] addr;
        output [63:0] data;
        integer timeout;
        begin
            data = 64'd0;
            @(negedge clk);
            csr_valid = 1'b1;
            csr_write = 1'b0;
            csr_addr  = addr;
            csr_wdata = 64'd0;

            timeout = 0;
            while (timeout < MAX_WAIT) begin
                @(posedge clk);
                if (csr_ready)
                    timeout = MAX_WAIT;
                else
                    timeout = timeout + 1;
            end
            if (!csr_ready) begin
                tb_fail("CSR read timeout");
                return;
            end

            data = csr_rdata;
            @(negedge clk);
            csr_valid = 1'b0;
            csr_addr  = 8'h00;
        end
    endtask

    task automatic csr_programmability_check;
        begin
            tb_test_start("T02_SMOKE_CSR_PROGRAMMABILITY",
                          "csr_programmability_check",
                          "CSR defaults, region RW, W1C no-event clear, QoS/DVM/perf reads");
            csr_read_check(8'h00, 64'h2, CSR_MASK_CTRL);
            if (test_failed) return;
            csr_read_check(8'h40, 64'h0, CSR_MASK_4B);
            if (test_failed) return;
            csr_read_check(8'h68, 64'd4096, CSR_MASK_16B);
            if (test_failed) return;
            csr_read_check(8'h70, 64'd4, CSR_MASK_16B);
            if (test_failed) return;
            csr_read_check(8'h78, `CHI_DEFAULT_QOS_AGE_SHIFT, CSR_MASK_8B);
            if (test_failed) return;
            csr_read_check(8'h7C, `CHI_DEFAULT_QOS_AGE_MAX, CSR_MASK_8B);
            if (test_failed) return;

            csr_read_check(8'h10, 64'h0000_0000, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h18, 64'h7FFF_FFFF, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h20, 64'h8000_0000, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h28, 64'hBFFF_FFFF, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h30, 64'hFFF0_0000, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h38, 64'hFFFF_FFFF, CSR_MASK_32B);
            if (test_failed) return;

            csr_write64(8'h10, 64'h0000_0100);
            if (test_failed) return;
            csr_write64(8'h18, 64'h7FFF_FEFF);
            if (test_failed) return;
            csr_write64(8'h20, 64'h8000_0100);
            if (test_failed) return;
            csr_write64(8'h28, 64'hBFFF_FEFF);
            if (test_failed) return;
            csr_write64(8'h30, 64'hFFF0_0100);
            if (test_failed) return;
            csr_write64(8'h38, 64'hFFFF_FFEF);
            if (test_failed) return;

            csr_read_check(8'h10, 64'h0000_0100, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h18, 64'h7FFF_FEFF, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h20, 64'h8000_0100, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h28, 64'hBFFF_FEFF, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h30, 64'hFFF0_0100, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'h38, 64'hFFFF_FFEF, CSR_MASK_32B);
            if (test_failed) return;

            csr_write64(8'h10, 64'h0000_0000);
            if (test_failed) return;
            csr_write64(8'h18, 64'h7FFF_FFFF);
            if (test_failed) return;
            csr_write64(8'h20, 64'h8000_0000);
            if (test_failed) return;
            csr_write64(8'h28, 64'hBFFF_FFFF);
            if (test_failed) return;
            csr_write64(8'h30, 64'hFFF0_0000);
            if (test_failed) return;
            csr_write64(8'h38, 64'hFFFF_FFFF);
            if (test_failed) return;

            csr_write64(8'h68, 64'h0000_0100);
            if (test_failed) return;
            csr_read_check(8'h68, 64'h0000_0100, CSR_MASK_16B);
            if (test_failed) return;
            csr_write64(8'h70, 64'h0000_0008);
            if (test_failed) return;
            csr_read_check(8'h70, 64'h0000_0008, CSR_MASK_16B);
            if (test_failed) return;
            csr_write64(8'h78, 64'h0000_0002);
            if (test_failed) return;
            csr_read_check(8'h78, 64'h0000_0002, CSR_MASK_8B);
            if (test_failed) return;
            csr_write64(8'h7C, 64'h0000_0010);
            if (test_failed) return;
            csr_read_check(8'h7C, 64'h0000_0010, CSR_MASK_8B);
            if (test_failed) return;

            csr_write64(8'h40, 64'h0000_000F);
            if (test_failed) return;
            csr_read_check(8'h40, 64'h0000_0000, CSR_MASK_4B);
            if (test_failed) return;
            csr_read_check(8'h80, 64'h0000_0000, CSR_MASK_32B);
            if (test_failed) return;
            csr_read_check(8'hC0, 64'h0000_0000, CSR_MASK_32B);
            if (test_failed) return;

            csr_write64(8'h00, 64'h0000_0007);
            if (test_failed) return;
            csr_read_check(8'h00, 64'h0000_0007, CSR_MASK_CTRL);
            if (test_failed) return;

            tb_test_pass("CSR programmability smoke completed");
        end
    endtask

    task automatic irq_ecc_double_w1c_check;
        integer timeout;
        begin
            tb_test_start("T03_SMOKE_IRQ_ECC_DOUBLE_W1C",
                          "irq_ecc_double_w1c_check",
                          "Injected HN ECC double event asserts IRQ, sets ERR_STATUS[1], then W1C clears it");
            allow_chi_irq = 1'b1;

            wait_cycles(1);
            if (chi_irq) begin
                tb_fail("CHI IRQ asserted before ECC double injection");
                return;
            end

            @(negedge clk);
            force dut.hn_ecc_double_event[0] = 1'b1;
            @(posedge clk);
            @(negedge clk);
            release dut.hn_ecc_double_event[0];

            timeout = 0;
            while (!chi_irq && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (!chi_irq) begin
                tb_fail("CHI IRQ did not assert on ECC double event");
                return;
            end

            csr_read_check(8'h40, 64'h0000_0002, CSR_MASK_4B);
            if (test_failed) return;

            csr_write64(8'h40, 64'h0000_0002);
            if (test_failed) return;
            wait_cycles(1);
            if (chi_irq) begin
                tb_fail("CHI IRQ did not clear after ECC double W1C");
                return;
            end

            csr_read_check(8'h40, 64'h0000_0000, CSR_MASK_4B);
            if (test_failed) return;

            allow_chi_irq = 1'b0;
            tb_test_pass("IRQ asserted and cleared through ERR_STATUS W1C");
        end
    endtask

    task automatic hn_dat_round_robin_check;
        integer i;
        integer tx_count;
        integer mem_count;
        integer diff;
        begin
            tb_test_start("T13_A1_DAT_RR_NO_STARVATION",
                          "hn_dat_round_robin_check",
                          "HN DAT arbiter alternates tx_dat and mem_dat under continuous contention");
            csr_write64(8'h00, 64'h0000_0003);
            if (test_failed) return;
            wait_cycles(2);

            // Both sources request, nothing reaches the DAT link, and every
            // cycle counts as a taken flit so the priority keeps flipping.
            @(negedge clk);
            force dut.gen_hn[0].u_hn_f.tx_dat_link_valid = 1'b1;
            force dut.gen_hn[0].u_hn_f.mem_dat_valid = 1'b1;
            force dut.gen_hn[0].u_hn_f.tx_dat_link_flit = {DAT_W{1'b0}};
            force dut.gen_hn[0].u_hn_f.mem_dat_flit = {DAT_W{1'b0}};
            force dut.gen_hn[0].u_hn_f.dat_arb_valid = 1'b0;
            force dut.gen_hn[0].u_hn_f.dat_arb_ready = 1'b0;
            force dut.gen_hn[0].u_hn_f.dat_arb_take = 1'b1;

            tx_count = 0;
            mem_count = 0;
            for (i = 0; i < A1_ARB_CYCLES; i = i + 1) begin
                @(negedge clk);
                if (dut.gen_hn[0].u_hn_f.tx_dat_wins)
                    tx_count = tx_count + 1;
                if (dut.gen_hn[0].u_hn_f.mem_dat_wins)
                    mem_count = mem_count + 1;
                if (dut.gen_hn[0].u_hn_f.tx_dat_wins && dut.gen_hn[0].u_hn_f.mem_dat_wins) begin
                    tb_fail("A1 DAT arbiter granted both sources");
                    return;
                end
                if (!dut.gen_hn[0].u_hn_f.tx_dat_wins && !dut.gen_hn[0].u_hn_f.mem_dat_wins) begin
                    tb_fail("A1 DAT arbiter granted no source under contention");
                    return;
                end
                if (dut.gen_hn[0].u_hn_f.tx_dat_link_ready ||
                    dut.gen_hn[0].u_hn_f.mem_dat_ready) begin
                    tb_fail("A1 DAT arbiter test leaked a credit handshake");
                    return;
                end
            end

            release dut.gen_hn[0].u_hn_f.dat_arb_take;
            release dut.gen_hn[0].u_hn_f.dat_arb_ready;
            release dut.gen_hn[0].u_hn_f.dat_arb_valid;
            release dut.gen_hn[0].u_hn_f.mem_dat_flit;
            release dut.gen_hn[0].u_hn_f.tx_dat_link_flit;
            release dut.gen_hn[0].u_hn_f.mem_dat_valid;
            release dut.gen_hn[0].u_hn_f.tx_dat_link_valid;

            csr_write64(8'h00, 64'h0000_0007);
            if (test_failed) return;

            diff = tx_count - mem_count;
            if (diff < 0)
                diff = -diff;
            if ((tx_count == 0) || (mem_count == 0)) begin
                tb_fail("A1 DAT arbiter starved one source");
                return;
            end
            if (diff > 1) begin
                tb_fail("A1 DAT arbiter round-robin ratio mismatch");
                return;
            end

            $display("[%0t] TEST PASS  %0s task=%0s detail=tx_dat_wins=%0d mem_dat_wins=%0d",
                     $time, current_test_id, current_task_name,
                     tx_count, mem_count);
        end
    endtask

    task automatic hn_dat_round_robin_reset_check;
        begin
            tb_test_start("T01_A1_DAT_RR_RESET",
                          "hn_dat_round_robin_reset_check",
                          "Mid-test reset restores HN DAT arbiter tx-first priority and the next taken flit toggles to mem");
            @(negedge clk);
            rstn = 1'b0;
            csr_valid = 1'b0;
            csr_write = 1'b0;
            csr_addr = 8'h00;
            csr_wdata = 64'd0;
            cpu_req_valid = {NUM_RN{1'b0}};
            cpu_req_addr = {NUM_RN*ADDR_WIDTH{1'b0}};
            cpu_req_op = {NUM_RN*4{1'b0}};
            cpu_req_size = {NUM_RN*3{1'b0}};
            cpu_req_qos = {NUM_RN*QOS_W{1'b0}};
            cpu_req_tag = {NUM_RN*CPU_TAG_W{1'b0}};
            cpu_wdata = {NUM_RN*DATA_WIDTH{1'b0}};
            strict_cpu_sparse_write_active = 1'b0;
            strict_cpu_sparse_write_addr = {ADDR_WIDTH{1'b0}};
            strict_cpu_sparse_write_data = {DATA_WIDTH{1'b0}};
            allow_chi_irq = 1'b0;
            axi_bp_enable = 1'b0;
            axi_bp_random_enable = 1'b0;
            a5_conc_active = 1'b0;
            wait_cycles(4);

            @(negedge clk);
            rstn = 1'b1;
            wait_cycles(2);

            @(negedge clk);
            force dut.gen_hn[0].u_hn_f.tx_dat_link_valid = 1'b1;
            force dut.gen_hn[0].u_hn_f.mem_dat_valid = 1'b1;
            force dut.gen_hn[0].u_hn_f.tx_dat_link_flit = {DAT_W{1'b0}};
            force dut.gen_hn[0].u_hn_f.mem_dat_flit = {DAT_W{1'b0}};
            force dut.gen_hn[0].u_hn_f.dat_arb_valid = 1'b0;
            force dut.gen_hn[0].u_hn_f.dat_arb_ready = 1'b0;
            force dut.gen_hn[0].u_hn_f.dat_arb_take = 1'b0;
            #1;

            if (!dut.gen_hn[0].u_hn_f.tx_dat_wins || dut.gen_hn[0].u_hn_f.mem_dat_wins) begin
                tb_fail("A1 DAT arbiter reset did not select tx_dat first");
                return;
            end

            force dut.gen_hn[0].u_hn_f.dat_arb_take = 1'b1;
            @(negedge clk);
            if (dut.gen_hn[0].u_hn_f.tx_dat_wins || !dut.gen_hn[0].u_hn_f.mem_dat_wins) begin
                tb_fail("A1 DAT arbiter did not toggle priority after reset pop");
                return;
            end

            release dut.gen_hn[0].u_hn_f.dat_arb_take;
            release dut.gen_hn[0].u_hn_f.dat_arb_ready;
            release dut.gen_hn[0].u_hn_f.dat_arb_valid;
            release dut.gen_hn[0].u_hn_f.mem_dat_flit;
            release dut.gen_hn[0].u_hn_f.tx_dat_link_flit;
            release dut.gen_hn[0].u_hn_f.mem_dat_valid;
            release dut.gen_hn[0].u_hn_f.tx_dat_link_valid;

            wait_cycles(2);
            tb_test_pass("Reset selected tx_dat first, one taken flit selected mem_dat next");
        end
    endtask

    task automatic a2_dbid_cross_hn_uniqueness_check;
        integer i;
        integer j;
        reg [DBID_W-1:0] dbid_i;
        reg [DBID_W-1:0] dbid_j;
        reg [DBID_W-1:0] dbid_seen [0:A2_NUM_HN-1];
        reg [DBID_W-1:0] expected_dbid;
        reg [A2_HN_BANK_BITS-1:0] observed_bank;
        reg [DBID_W-A2_HN_BANK_BITS-1:0] observed_slot;
        begin
            tb_test_start("T14_A2_DBID_CROSS_HN_UNIQUENESS",
                          "a2_dbid_cross_hn_uniqueness_check",
                          "Three HN write trackers allocate unique DBIDs with HN bank encoded in high bits");

            a2_alloc_valid = {A2_NUM_HN{1'b0}};
            a2_tracker_clear = 1'b1;
            wait_cycles(2);
            a2_tracker_clear = 1'b0;
            wait_cycles(1);

            @(negedge clk);
            a2_alloc_valid = {A2_NUM_HN{1'b1}};
            for (i = 0; i < A2_NUM_HN; i = i + 1) begin
                if (!a2_alloc_ready[i]) begin
                    tb_fail("A2 write tracker was not ready for first allocation");
                    return;
                end
                dbid_seen[i] = a2_alloc_dbid[i*DBID_W +: DBID_W];
            end

            @(posedge clk);
            @(negedge clk);
            a2_alloc_valid = {A2_NUM_HN{1'b0}};

            for (i = 0; i < A2_NUM_HN; i = i + 1) begin
                dbid_i = dbid_seen[i];
                expected_dbid = (i << (DBID_W - A2_HN_BANK_BITS)) | 1;
                observed_bank = dbid_i[DBID_W-1 -: A2_HN_BANK_BITS];
                observed_slot = dbid_i[0 +: (DBID_W-A2_HN_BANK_BITS)];

                if (dbid_i !== expected_dbid) begin
                    $display("[%0t] TEST STEP  %0s task=%0s HN%0d DBID mismatch exp=0x%0h got=0x%0h",
                             $time, current_test_id, current_task_name,
                             i, expected_dbid, dbid_i);
                    tb_fail("A2 DBID format mismatch");
                    return;
                end
                if (a2_used_count[i*16 +: 16] != 16'd1) begin
                    tb_fail("A2 write tracker did not hold exactly one active slot");
                    return;
                end
                if (!a2_active_valid_vec[i*A2_TRACKER_DEPTH]) begin
                    tb_fail("A2 write tracker active slot was not set");
                    return;
                end

                $display("[%0t] TEST STEP  %0s task=%0s HN%0d dbid=0x%0h bank=0x%0h slot=0x%0h",
                         $time, current_test_id, current_task_name,
                         i, dbid_i, observed_bank, observed_slot);
            end

            for (i = 0; i < A2_NUM_HN; i = i + 1) begin
                dbid_i = dbid_seen[i];
                for (j = i + 1; j < A2_NUM_HN; j = j + 1) begin
                    dbid_j = dbid_seen[j];
                    if (dbid_i == dbid_j) begin
                        tb_fail("A2 duplicate DBID across HN trackers");
                        return;
                    end
                end
            end

            a2_tracker_clear = 1'b1;
            wait_cycles(1);
            a2_tracker_clear = 1'b0;

            tb_test_pass("HN0/HN1/HN2 allocated distinct DBIDs 0x001/0x101/0x201");
        end
    endtask

    task automatic exclusive_ldrex_strex_success_check;
        integer timeout;
        begin
            tb_test_start("T15_A3_EXCLUSIVE_LDREX_STREX_SUCCESS",
                          "exclusive_ldrex_strex_success_check",
                          "LDREX sets RN/HN reservation and same-line STREX returns success result 1");

            cpu_read_check(EXCL_ADDR0,
                           `CHI_CPU_OP_LDREX,
                           mem_pattern(EXCL_ADDR0, 0),
                           "LDREX ReadShared reservation set");
            if (test_failed) return;

            timeout = 0;
            while (((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) ||
                    (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) begin
                tb_fail("LDREX did not set RN local exclusive reservation");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1) begin
                tb_fail("LDREX did not set HN global exclusive reservation");
                return;
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.addr_q[ADDR_WIDTH-1:6] !==
                EXCL_ADDR0[ADDR_WIDTH-1:6]) begin
                tb_fail("RN local exclusive reservation line mismatch");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_line_q[0] !==
                EXCL_ADDR0[ADDR_WIDTH-1:6]) begin
                tb_fail("HN global exclusive reservation line mismatch");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s exclusive reservation set addr=0x%011h rn_line=0x%0h hn_line=0x%0h",
                     $time, current_test_id, current_task_name,
                     EXCL_ADDR0,
                     dut.gen_rn[0].u_rn_f.u_exclusive_monitor.addr_q[ADDR_WIDTH-1:6],
                     dut.gen_hn[0].u_hn_f.excl_line_q[0]);

            // 2.5: LDREX filled the line SC, so STREX is CleanUnique(Excl)
            // and the store lands in RN0's own copy (UD): no AXI write.
            cpu_strex_result_check(EXCL_ADDR0,
                                   EXCL_WRITE_DATA,
                                   1'b1,
                                   1'b0,
                                   "STREX same-line success");
            if (test_failed) return;
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) begin
                tb_fail("STREX success did not clear RN local exclusive reservation");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0) begin
                tb_fail("STREX success did not clear HN global exclusive reservation");
                return;
            end

            cpu_read_check_rn(1, EXCL_ADDR0, `CHI_CPU_OP_RD_SHARED,
                              EXCL_WRITE_DATA,
                              "RN1 read sees the STREX data from RN0");
            if (test_failed) return;

            timeout = 0;
            while (((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) ||
                    (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) begin
                tb_fail("STREX success did not clear RN local exclusive reservation");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0) begin
                tb_fail("STREX success did not clear HN global exclusive reservation");
                return;
            end

            csr_read_check(8'h40, 64'h0000_0000, CSR_MASK_4B);
            if (test_failed) return;

            tb_test_pass("LDREX reservation was set in RN/HN, STREX returned 1, and both reservations cleared");
        end
    endtask

    task automatic exclusive_hn_invalidation_strex_fail_check;
        integer timeout;
        begin
            tb_test_start("T16_A3_EXCLUSIVE_HN_INVALIDATE_STREX_FAIL",
                          "exclusive_hn_invalidation_strex_fail_check",
                          "LDREX reservation is invalidated at HN while RN local monitor remains set, so STREX returns result 0");

            csr_write64(8'h40, 64'h0000_0008);
            if (test_failed) return;

            cpu_read_check(EXCL_FAIL_ADDR,
                           `CHI_CPU_OP_LDREX,
                           mem_pattern(EXCL_FAIL_ADDR, 0),
                           "LDREX before directed HN invalidation");
            if (test_failed) return;

            timeout = 0;
            while (((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) ||
                    (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) begin
                tb_fail("LDREX did not set RN reservation before invalidation");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1) begin
                tb_fail("LDREX did not set HN reservation before invalidation");
                return;
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.addr_q[ADDR_WIDTH-1:6] !==
                EXCL_FAIL_ADDR[ADDR_WIDTH-1:6]) begin
                tb_fail("RN reservation line mismatch before invalidation");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_line_q[0] !==
                EXCL_FAIL_ADDR[ADDR_WIDTH-1:6]) begin
                tb_fail("HN reservation line mismatch before invalidation");
                return;
            end

            @(negedge clk);
            force dut.gen_hn[0].u_hn_f.excl_valid_q = {NUM_RN{1'b0}};
            #1;
            release dut.gen_hn[0].u_hn_f.excl_valid_q;
            wait_cycles(1);

            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) begin
                tb_fail("Directed HN invalidation unexpectedly cleared RN local reservation");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0) begin
                tb_fail("Directed HN invalidation did not clear HN global reservation");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s directed_hn_invalidate addr=0x%011h rn_valid=%0b hn_valid=%0b",
                     $time, current_test_id, current_task_name,
                     EXCL_FAIL_ADDR,
                     dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q,
                     dut.gen_hn[0].u_hn_f.excl_valid_q[0]);

            cpu_strex_result_check(EXCL_FAIL_ADDR,
                                   EXCL_FAIL_DATA,
                                   1'b0,
                                   1'b0,
                                   "STREX after HN invalidation fail");
            if (test_failed) return;

            timeout = 0;
            while ((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) begin
                tb_fail("STREX fail did not clear RN local reservation");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0) begin
                tb_fail("HN reservation was unexpectedly restored after STREX fail");
                return;
            end

            csr_read_check(8'h40, 64'h0000_0008, CSR_MASK_4B);
            if (test_failed) return;
            csr_write64(8'h40, 64'h0000_0008);
            if (test_failed) return;
            csr_read_check(8'h40, 64'h0000_0000, CSR_MASK_4B);
            if (test_failed) return;

            tb_test_pass("HN invalidation forced STREX result 0, no AXI write, ERR_STATUS[3] W1C clear worked");
        end
    endtask

    task automatic exclusive_aging_timeout_strex_fail_check;
        integer timeout;
        integer age_at_clear;
        begin
            tb_test_start("T17_A3_EXCLUSIVE_AGING_TIMEOUT_STREX_FAIL",
                          "exclusive_aging_timeout_strex_fail_check",
                          "CSR_EXCL_TIMEOUT aging clears HN global reservation before STREX, forcing result 0");

            csr_write64(8'h40, 64'h0000_0008);
            if (test_failed) return;
            csr_write64(8'h68, A3_EXCL_TIMEOUT_CYCLES[15:0]);
            if (test_failed) return;
            csr_read_check(8'h68, A3_EXCL_TIMEOUT_CYCLES[15:0], CSR_MASK_16B);
            if (test_failed) return;

            cpu_read_check(EXCL_TIMEOUT_ADDR,
                           `CHI_CPU_OP_LDREX,
                           mem_pattern(EXCL_TIMEOUT_ADDR, 0),
                           "LDREX before exclusive aging timeout");
            if (test_failed) return;

            timeout = 0;
            while (((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) ||
                    (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) begin
                tb_fail("LDREX did not set RN reservation before aging timeout");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1) begin
                tb_fail("LDREX did not set HN reservation before aging timeout");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_line_q[0] !==
                EXCL_TIMEOUT_ADDR[ADDR_WIDTH-1:6]) begin
                tb_fail("HN reservation line mismatch before aging timeout");
                return;
            end

            timeout = 0;
            while ((dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            age_at_clear = timeout;
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0) begin
                tb_fail("HN exclusive reservation did not age out");
                return;
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) begin
                tb_fail("HN aging timeout unexpectedly cleared RN local reservation");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s exclusive_age_timeout addr=0x%011h cfg_cycles=%0d observed_wait=%0d rn_valid=%0b hn_valid=%0b",
                     $time, current_test_id, current_task_name,
                     EXCL_TIMEOUT_ADDR, A3_EXCL_TIMEOUT_CYCLES, age_at_clear,
                     dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q,
                     dut.gen_hn[0].u_hn_f.excl_valid_q[0]);

            cpu_strex_result_check(EXCL_TIMEOUT_ADDR,
                                   EXCL_TIMEOUT_DATA,
                                   1'b0,
                                   1'b0,
                                   "STREX after HN exclusive aging timeout");
            if (test_failed) return;

            timeout = 0;
            while ((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) begin
                tb_fail("STREX after aging timeout did not clear RN reservation");
                return;
            end

            csr_read_check(8'h40, 64'h0000_0008, CSR_MASK_4B);
            if (test_failed) return;
            csr_write64(8'h40, 64'h0000_0008);
            if (test_failed) return;
            csr_read_check(8'h40, 64'h0000_0000, CSR_MASK_4B);
            if (test_failed) return;
            csr_write64(8'h68, 64'h0000_0100);
            if (test_failed) return;

            tb_test_pass("HN exclusive reservation aged out, STREX returned 0, no AXI write, ERR_STATUS[3] W1C clear worked");
        end
    endtask

    task automatic exclusive_timeout_zero_clamp_check;
        begin
            tb_test_start("T18_A3_EXCL_TIMEOUT_ZERO_CLAMP",
                          "exclusive_timeout_zero_clamp_check",
                          "CSR_EXCL_TIMEOUT write of zero clamps to one and remains readable as a nonzero timeout");

            csr_write64(8'h68, 64'h0000_0000);
            if (test_failed) return;
            csr_read_check(8'h68, 64'h0000_0001, CSR_MASK_16B);
            if (test_failed) return;
            csr_write64(8'h68, 64'h0000_0100);
            if (test_failed) return;
            csr_read_check(8'h68, 64'h0000_0100, CSR_MASK_16B);
            if (test_failed) return;

            tb_test_pass("CSR_EXCL_TIMEOUT zero write clamped to one and restored to 0x0100");
        end
    endtask

    task automatic iot_axi_backpressure_check;
        integer ar_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        integer r_before;
        begin
            tb_test_start("T19_IOT_AXI_BACKPRESSURE_RW",
                          "iot_axi_backpressure_check",
                          "AXI slave stalls ARREADY/AWREADY/WREADY and delays R/B without creating false DUT timeouts");

            ar_before = axi_ar_count;
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;
            r_before  = axi_r_count;

            axi_bp_enable = 1'b1;
            wait_cycles(3);

            cpu_read_check(IOT_BP_READ_ADDR,
                           `CHI_CPU_OP_RD_SHARED,
                           mem_pattern(IOT_BP_READ_ADDR, 0),
                           "ReadShared under AXI ready/R backpressure");
            if (test_failed) return;

            cpu_write_check(IOT_BP_WRITE_ADDR,
                            `CHI_CPU_OP_WB_FULL,
                            IOT_BP_WRITE_DATA,
                            "WriteBackFull under AXI ready/B backpressure");
            if (test_failed) return;

            cpu_read_check(IOT_BP_WRITE_ADDR,
                           `CHI_CPU_OP_RD_SHARED,
                           IOT_BP_WRITE_DATA,
                           "ReadShared after backpressured writeback");
            if (test_failed) return;

            axi_bp_enable = 1'b0;
            wait_cycles(2);

            if (axi_ar_count != (ar_before + 2)) begin
                tb_fail("Backpressure test expected two AXI AR bursts");
                return;
            end
            if (axi_r_count != (r_before + (2 * BEATS))) begin
                tb_fail("Backpressure test expected two full AXI R bursts");
                return;
            end
            if (axi_aw_count != (aw_before + 1)) begin
                tb_fail("Backpressure test expected one AXI AW burst");
                return;
            end
            if (axi_w_count != (w_before + BEATS)) begin
                tb_fail("Backpressure test expected one full AXI W burst");
                return;
            end
            if (axi_b_count != (b_before + 1)) begin
                tb_fail("Backpressure test expected one AXI B response");
                return;
            end

            tb_test_pass("AXI AR/AW/W stalls plus delayed R/B completed without false timeout or data loss");
        end
    endtask

    // Print which busy term holds the clock-gate enable, for CG failures.
    task automatic cg_busy_dump;
        begin
            $display("[%0t] CG busy rn=%b hn=%b sn=%b mn=%b fabric=%b bist=%b cpu=%b axi_r=%b axi_b=%b",
                     $time, dut.rn_busy, dut.hn_busy, dut.sn_busy, dut.mn_busy,
                     dut.fabric_busy, dut.csr_bist_init_pulse, dut.cpu_req_valid,
                     dut.axi_rvalid, dut.axi_bvalid);
            $display("[%0t] CG hn0 state=%0d pos=%0d wr=%b rd=%b snp=%b evict_busy=%b llc=%b sf=%b resp=%b tx=%b%b%b mem=%b%b excl=%b",
                     $time, dut.gen_hn[0].u_hn_f.state_q, dut.gen_hn[0].u_hn_f.pos_used,
                     |dut.gen_hn[0].u_hn_f.wr_tracker_active_valid_vec,
                     |dut.gen_hn[0].u_hn_f.rd_tracker_active_valid_vec,
                     |dut.gen_hn[0].u_hn_f.snp_tracker_active_valid_vec,
                     !dut.gen_hn[0].u_hn_f.llc_evict_idle,
                     dut.gen_hn[0].u_hn_f.llc_busy, dut.gen_hn[0].u_hn_f.sf_busy,
                     dut.gen_hn[0].u_hn_f.resp_valid,
                     dut.gen_hn[0].u_hn_f.tx_rsp_valid, dut.gen_hn[0].u_hn_f.tx_snp_valid,
                     dut.gen_hn[0].u_hn_f.tx_dat_valid,
                     dut.gen_hn[0].u_hn_f.mem_req_valid, dut.gen_hn[0].u_hn_f.mem_dat_valid,
                     dut.gen_hn[0].u_hn_f.excl_valid_q);
            $display("[%0t] CG rn0 outstanding=%0d resv=%b tx=%b%b%b rsp_rx=%b dat_rx=%b snoop=%b wdat=%b cache=%b",
                     $time, dut.gen_rn[0].u_rn_f.outstanding_count,
                     dut.gen_rn[0].u_rn_f.reservation_valid,
                     dut.gen_rn[0].u_rn_f.tx_req_valid, dut.gen_rn[0].u_rn_f.tx_rsp_valid,
                     dut.gen_rn[0].u_rn_f.tx_dat_valid,
                     dut.gen_rn[0].u_rn_f.rsp_rx_busy, dut.gen_rn[0].u_rn_f.dat_rx_busy,
                     dut.gen_rn[0].u_rn_f.snoop_busy, dut.gen_rn[0].u_rn_f.wdat_busy,
                     dut.gen_rn[0].u_rn_f.cache_busy);
        end
    endtask

    task automatic iot_idle_wake_clock_gate_check;
        integer ar_before;
        begin
            tb_test_start("T20_IOT_IDLE_WAKE_CLOCK_GATE",
                          "iot_idle_wake_clock_gate_check",
                          "Clock-gate enable drops when idle and a later CPU read wakes the fabric path");

            csr_write64(8'h00, 64'h0000_0007);
            if (test_failed) return;

            wait_cycles(40);
            if (dut.chi_cg_en !== 1'b0) begin
                cg_busy_dump();
                tb_fail("chi_cg_en did not drop low after idle window");
                return;
            end
            // The clock may only stop with every link deactivated (B14.5.1).
            if (dut.links_stopped !== 1'b1) begin
                tb_fail("fabric clock gated with a link not in STOP");
                return;
            end

            ar_before = axi_ar_count;
            cpu_read_check(IOT_WAKE_ADDR,
                           `CHI_CPU_OP_RD_SHARED,
                           mem_pattern(IOT_WAKE_ADDR, 0),
                           "ReadShared after idle wake");
            if (test_failed) return;
            if (axi_ar_count != (ar_before + 1)) begin
                tb_fail("Idle wake read did not issue one AXI AR");
                return;
            end

            // The wake read's allocation can evict a dirty RN cache victim
            // (here the T12 line at 0x6000). That writeback runs in the
            // background and must keep the clock on, so only check the idle
            // drop once AXI writes have gone quiet.
            wait_axi_write_quiet(64);
            if (test_failed) return;
            wait_cycles(40);
            if (dut.chi_cg_en !== 1'b0) begin
                cg_busy_dump();
                tb_fail("chi_cg_en did not return low after wake read drained");
                return;
            end
            // The clock may only stop with every link deactivated (B14.5.1).
            if (dut.links_stopped !== 1'b1) begin
                tb_fail("fabric clock gated with a link not in STOP");
                return;
            end

            tb_test_pass("Idle indication dropped low, wake read completed, and idle indication returned low");
        end
    endtask

    task automatic iot_reset_mid_transaction_check;
        integer ar_before;
        integer timeout;
        reg request_accepted;
        begin
            tb_test_start("T21_IOT_RESET_MID_TRANSACTION_RECOVERY",
                          "iot_reset_mid_transaction_check",
                          "Reset during an outstanding read clears in-flight state and a new read works after reset release");

            ar_before = axi_ar_count;
            request_accepted = 1'b0;

            @(negedge clk);
            cpu_req_addr  = IOT_RESET_ADDR;
            cpu_req_op    = `CHI_CPU_OP_RD_SHARED;
            cpu_req_size  = 3'd6;
            cpu_wdata     = {DATA_WIDTH{1'b0}};
            cpu_req_valid = 1'b1;

            timeout = 0;
            while ((axi_ar_count == ar_before) && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_ready[0])
                    request_accepted = 1'b1;
            end
            if (axi_ar_count == ar_before) begin
                tb_fail("Reset-mid-transaction setup did not reach AXI AR");
                return;
            end
            if (!request_accepted) begin
                tb_fail("Reset-mid-transaction CPU request was not accepted");
                return;
            end

            @(negedge clk);
            cpu_req_valid = 1'b0;
            cpu_req_addr  = {NUM_RN*ADDR_WIDTH{1'b0}};
            cpu_req_op    = {NUM_RN*4{1'b0}};
            cpu_req_size  = {NUM_RN*3{1'b0}};
            cpu_wdata     = {NUM_RN*DATA_WIDTH{1'b0}};

            axi_ar_count_base = axi_ar_count_base + axi_ar_count;
            axi_aw_count_base = axi_aw_count_base + axi_aw_count;
            axi_w_count_base  = axi_w_count_base  + axi_w_count;
            axi_b_count_base  = axi_b_count_base  + axi_b_count;
            axi_r_count_base  = axi_r_count_base  + axi_r_count;

            rstn = 1'b0;
            csr_valid = 1'b0;
            csr_write = 1'b0;
            csr_addr = 8'h00;
            csr_wdata = 64'd0;
            allow_chi_irq = 1'b0;
            axi_bp_enable = 1'b0;
            axi_bp_random_enable = 1'b0;
            a5_conc_active = 1'b0;
            strict_cpu_sparse_write_active = 1'b0;
            wait_cycles(6);

            @(negedge clk);
            rstn = 1'b1;
            wait_cycles(10);

            csr_write64(8'h00, 64'h0000_0007);
            if (test_failed) return;

            cpu_read_check(IOT_RESET_RECOVERY_ADDR,
                           `CHI_CPU_OP_RD_SHARED,
                           mem_pattern(IOT_RESET_RECOVERY_ADDR, 0),
                           "ReadShared after reset recovery");
            if (test_failed) return;

            tb_test_pass("Reset during outstanding read cleared state and post-reset read completed");
        end
    endtask

    task automatic llc_backdoor_seed_dirty_victim;
        begin
            wait_cycles(5);
            sb_forget_line(EVICT_DIRTY_ADDR0);
            sb_forget_line(EVICT_CLEAN_ADDR1);
            sb_forget_line(EVICT_CLEAN_ADDR2);
            sb_forget_line(EVICT_CLEAN_ADDR3);

            dut.gen_hn[0].u_hn_f.u_llc.plru_mem[LLC_EVICT_SET] = 3'b000;

            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].valid_mem[LLC_EVICT_SET] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[LLC_EVICT_SET] =
                {llc_tag(EVICT_DIRTY_ADDR0), `CHI_STATE_UD};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].data_mem[LLC_EVICT_SET] =
                dirty_evict_line();

            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].valid_mem[LLC_EVICT_SET] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].meta_mem[LLC_EVICT_SET] =
                {llc_tag(EVICT_CLEAN_ADDR1), `CHI_STATE_SC};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].data_mem[LLC_EVICT_SET] =
                clean_seed_line(EVICT_CLEAN_ADDR1);

            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].valid_mem[LLC_EVICT_SET] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].meta_mem[LLC_EVICT_SET] =
                {llc_tag(EVICT_CLEAN_ADDR2), `CHI_STATE_SC};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].data_mem[LLC_EVICT_SET] =
                clean_seed_line(EVICT_CLEAN_ADDR2);

            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].valid_mem[LLC_EVICT_SET] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].meta_mem[LLC_EVICT_SET] =
                {llc_tag(EVICT_CLEAN_ADDR3), `CHI_STATE_SC};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].data_mem[LLC_EVICT_SET] =
                clean_seed_line(EVICT_CLEAN_ADDR3);

            wait_cycles(1);
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].valid_mem[LLC_EVICT_SET] !== 1'b1) begin
                tb_fail("LLC dirty victim seed valid bit failed");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[LLC_EVICT_SET] !==
                {llc_tag(EVICT_DIRTY_ADDR0), `CHI_STATE_UD}) begin
                tb_fail("LLC dirty victim seed metadata failed");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].data_mem[LLC_EVICT_SET] !==
                dirty_evict_line()) begin
                tb_fail("LLC dirty victim seed data failed");
                return;
            end
            $display("[%0t] TEST STEP  %0s task=%0s dirty_victim_seeded addr=0x%011h set=%0d",
                     $time, current_test_id, current_task_name,
                     EVICT_DIRTY_ADDR0, LLC_EVICT_SET);
        end
    endtask

    task automatic llc_dirty_evict_check;
        integer ar_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        integer timeout;
        begin
            tb_test_start("T10_A5_DIRTY_LLC_VICTIM_WB",
                          "llc_dirty_evict_check",
                          "Dirty LLC victim eviction issues silent AXI writeback and preserves victim data");
            ar_before = axi_ar_count;
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;

            llc_backdoor_seed_dirty_victim();
            if (test_failed) return;

            cpu_read_check(EVICT_TRIGGER_ADDR,
                           `CHI_CPU_OP_RD_SHARED,
                           mem_pattern(EVICT_TRIGGER_ADDR, 0),
                           "LLC dirty eviction trigger read");
            if (test_failed) return;

            if (axi_ar_count != (ar_before + 1)) begin
                tb_fail("Expected one AXI AR for dirty-eviction trigger read");
                return;
            end

            timeout = 0;
            while ((axi_b_count < (b_before + 1)) && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (axi_b_count < (b_before + 1)) begin
                tb_fail("Dirty LLC victim writeback timeout");
                return;
            end
            if (axi_aw_count != (aw_before + 1)) begin
                tb_fail("Expected one AXI AW for dirty LLC victim writeback");
                return;
            end
            if (axi_w_count != (w_before + BEATS)) begin
                tb_fail("Expected full AXI W burst for dirty LLC victim writeback");
                return;
            end
            if (axi_b_count != (b_before + 1)) begin
                tb_fail("Expected AXI B for dirty LLC victim writeback");
                return;
            end
            if (mem_pattern(EVICT_DIRTY_ADDR0, 0) !== dirty_evict_word(0)) begin
                tb_fail("Dirty LLC victim was not written into AXI shadow memory");
                return;
            end

            ar_before = axi_ar_count;
            aw_before = axi_aw_count;
            cpu_read_check(EVICT_DIRTY_ADDR0,
                           `CHI_CPU_OP_RD_SHARED,
                           dirty_evict_word(0),
                           "Read dirty victim after LLC writeback");
            if (test_failed) return;
            if (axi_ar_count != (ar_before + 1)) begin
                tb_fail("Expected AXI AR when reading evicted dirty victim");
                return;
            end
            if (axi_aw_count != aw_before) begin
                tb_fail("Unexpected dirty writeback on victim read refill");
                return;
            end

            tb_test_pass("Dirty victim writeback observed and readback matched");
        end
    endtask

    task automatic llc_backdoor_seed_clean_victim;
        begin
            wait_cycles(5);
            sb_forget_line(CLEAN_EVICT_ADDR0);
            sb_forget_line(CLEAN_EVICT_ADDR1);
            sb_forget_line(CLEAN_EVICT_ADDR2);
            sb_forget_line(CLEAN_EVICT_ADDR3);

            dut.gen_hn[0].u_hn_f.u_llc.plru_mem[LLC_CLEAN_EVICT_SET] = 3'b000;

            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].valid_mem[LLC_CLEAN_EVICT_SET] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[LLC_CLEAN_EVICT_SET] =
                {llc_tag(CLEAN_EVICT_ADDR0), `CHI_STATE_SC};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].data_mem[LLC_CLEAN_EVICT_SET] =
                clean_seed_line(CLEAN_EVICT_ADDR0);

            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].valid_mem[LLC_CLEAN_EVICT_SET] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].meta_mem[LLC_CLEAN_EVICT_SET] =
                {llc_tag(CLEAN_EVICT_ADDR1), `CHI_STATE_SC};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].data_mem[LLC_CLEAN_EVICT_SET] =
                clean_seed_line(CLEAN_EVICT_ADDR1);

            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].valid_mem[LLC_CLEAN_EVICT_SET] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].meta_mem[LLC_CLEAN_EVICT_SET] =
                {llc_tag(CLEAN_EVICT_ADDR2), `CHI_STATE_SC};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].data_mem[LLC_CLEAN_EVICT_SET] =
                clean_seed_line(CLEAN_EVICT_ADDR2);

            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].valid_mem[LLC_CLEAN_EVICT_SET] = 1'b1;
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].meta_mem[LLC_CLEAN_EVICT_SET] =
                {llc_tag(CLEAN_EVICT_ADDR3), `CHI_STATE_SC};
            dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].data_mem[LLC_CLEAN_EVICT_SET] =
                clean_seed_line(CLEAN_EVICT_ADDR3);

            wait_cycles(1);
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].valid_mem[LLC_CLEAN_EVICT_SET] !== 1'b1) begin
                tb_fail("LLC clean victim seed valid bit failed");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[LLC_CLEAN_EVICT_SET] !==
                {llc_tag(CLEAN_EVICT_ADDR0), `CHI_STATE_SC}) begin
                tb_fail("LLC clean victim seed metadata failed");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].data_mem[LLC_CLEAN_EVICT_SET] !==
                clean_seed_line(CLEAN_EVICT_ADDR0)) begin
                tb_fail("LLC clean victim seed data failed");
                return;
            end
            $display("[%0t] TEST STEP  %0s task=%0s clean_victim_seeded addr=0x%011h set=%0d",
                     $time, current_test_id, current_task_name,
                     CLEAN_EVICT_ADDR0, LLC_CLEAN_EVICT_SET);
        end
    endtask

    task automatic llc_clean_evict_check;
        integer ar_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        begin
            tb_test_start("T11_A5_CLEAN_LLC_VICTIM_NO_WB",
                          "llc_clean_evict_check",
                          "Clean LLC victim eviction must not issue AXI writeback");
            ar_before = axi_ar_count;
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;

            llc_backdoor_seed_clean_victim();
            if (test_failed) return;

            cpu_read_check(CLEAN_EVICT_TRIGGER_ADDR,
                           `CHI_CPU_OP_RD_SHARED,
                           mem_pattern(CLEAN_EVICT_TRIGGER_ADDR, 0),
                           "LLC clean eviction trigger read");
            if (test_failed) return;

            if (axi_ar_count != (ar_before + 1)) begin
                tb_fail("Expected one AXI AR for clean-eviction trigger read");
                return;
            end

            wait_cycles(40);
            if (axi_aw_count != aw_before) begin
                tb_fail("Unexpected AXI AW for clean LLC victim eviction");
                return;
            end
            if (axi_w_count != w_before) begin
                tb_fail("Unexpected AXI W for clean LLC victim eviction");
                return;
            end
            if (axi_b_count != b_before) begin
                tb_fail("Unexpected AXI B for clean LLC victim eviction");
                return;
            end

            tb_test_pass("Clean victim eviction had no AW/W/B traffic");
        end
    endtask

    task automatic llc_dirty_evict_concurrent_write_check;
        integer ar_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        integer timeout;
        reg accepted_before_dirty_b;
        begin
            tb_test_start("T12_A5_DIRTY_EVICT_RN_WRITE_CONCURRENT",
                          "llc_dirty_evict_concurrent_write_check",
                          "RN WriteBackFull accepted during dirty victim writeback and SN writes serialize cleanly");
            ar_before = axi_ar_count;
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;

            a5_conc_active = 1'b1;
            a5_conc_aw_seen = 0;
            a5_conc_aw_addr0 = {ADDR_WIDTH{1'b0}};
            a5_conc_aw_addr1 = {ADDR_WIDTH{1'b0}};

            llc_backdoor_seed_dirty_victim();
            if (test_failed) return;

            rn_drop_line(0, EVICT_TRIGGER_ADDR);
            if (test_failed) return;
            cpu_read_check(EVICT_TRIGGER_ADDR,
                           `CHI_CPU_OP_RD_SHARED,
                           mem_pattern(EVICT_TRIGGER_ADDR, 0),
                           "LLC dirty eviction overlap trigger read");
            if (test_failed) return;

            if (axi_ar_count != (ar_before + 1)) begin
                tb_fail("Expected one AXI AR for dirty-eviction overlap trigger");
                return;
            end

            @(negedge clk);
            cpu_req_addr  = CONC_WRITE_ADDR;
            cpu_req_op    = `CHI_CPU_OP_WB_FULL;
            cpu_req_size  = 3'd6;
            cpu_wdata     = CONC_WRITE_DATA;
            cpu_req_valid = 1'b1;
            strict_cpu_sparse_write_active = 1'b1;
            strict_cpu_sparse_write_addr = CONC_WRITE_ADDR;
            strict_cpu_sparse_write_data = CONC_WRITE_DATA;

            timeout = 0;
            accepted_before_dirty_b = 1'b0;
            while (timeout < MAX_WAIT) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_ready[0]) begin
                    accepted_before_dirty_b = (axi_b_count == b_before);
                    timeout = MAX_WAIT;
                end
            end
            if (!cpu_req_ready[0]) begin
                tb_fail("Concurrent CPU write request accept timeout");
                return;
            end

            @(negedge clk);
            cpu_req_valid = 1'b0;
            cpu_wdata     = {DATA_WIDTH{1'b0}};

            if (!accepted_before_dirty_b) begin
                tb_fail("Concurrent CPU write was not accepted before dirty victim B");
                return;
            end

            timeout = 0;
            while (!cpu_resp_valid[0] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (!cpu_resp_valid[0]) begin
                tb_fail("Concurrent CPU write response timeout");
                return;
            end

            @(negedge clk);
            if (axi_aw_count != (aw_before + 2)) begin
                tb_fail("Concurrent A5 test expected two AXI AW bursts");
                return;
            end
            if (axi_w_count != (w_before + (2 * BEATS))) begin
                tb_fail("Concurrent A5 test expected two full AXI W bursts");
                return;
            end
            if (axi_b_count != (b_before + 2)) begin
                tb_fail("Concurrent A5 test expected two AXI B responses");
                return;
            end
            if (a5_conc_aw_seen != 2) begin
                tb_fail("Concurrent A5 test did not observe exactly two AW handshakes");
                return;
            end
            if (a5_conc_aw_addr0 != EVICT_DIRTY_ADDR0) begin
                tb_fail("Concurrent A5 test expected dirty victim AW first");
                return;
            end
            if (a5_conc_aw_addr1 != CONC_WRITE_ADDR) begin
                tb_fail("Concurrent A5 test expected CPU write AW second");
                return;
            end
            if (mem_pattern(EVICT_DIRTY_ADDR0, 0) !== dirty_evict_word(0)) begin
                tb_fail("Concurrent A5 dirty victim shadow data mismatch");
                return;
            end
            if (mem_pattern(CONC_WRITE_ADDR, 0) !== CONC_WRITE_DATA) begin
                tb_fail("Concurrent A5 CPU write shadow data mismatch");
                return;
            end

            a5_conc_active = 1'b0;
            strict_cpu_sparse_write_active = 1'b0;
            tb_test_pass("Dirty victim writeback and RN writeback both preserved data");
        end
    endtask

    task automatic cpu_read_check;
        input [ADDR_WIDTH-1:0] addr;
        input [3:0] op;
        input [DATA_WIDTH-1:0] exp_data;
        input [1023:0] name;
        begin
            cpu_read_check_rn(0, addr, op, exp_data, name);
        end
    endtask

    task automatic cpu_read_check_rn;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [3:0] op;
        input [DATA_WIDTH-1:0] exp_data;
        input [1023:0] name;
        integer timeout;
        begin
            @(negedge clk);
            cpu_req_addr[rn_idx*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            cpu_req_op[rn_idx*4 +: 4] = op;
            cpu_req_size[rn_idx*3 +: 3] = 3'd6;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            cpu_req_valid[rn_idx] = 1'b1;

            timeout = 0;
            while (timeout < MAX_WAIT) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_ready[rn_idx])
                    timeout = MAX_WAIT;
            end
            if (!cpu_req_ready[rn_idx]) begin
                tb_fail("CPU request accept timeout");
                return;
            end

            @(negedge clk);
            cpu_req_valid[rn_idx] = 1'b0;

            timeout = 0;
            while (!cpu_resp_valid[rn_idx] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (!cpu_resp_valid[rn_idx]) begin
                tb_fail("CPU read response timeout");
                return;
            end

            if (cpu_rdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] !== exp_data) begin
                $display("[%0t] TEST STEP  %0s task=%0s CPU%0d read mismatch step=%0s addr=0x%011h exp=0x%016h got=0x%016h",
                         $time, current_test_id, current_task_name,
                         rn_idx, name, addr, exp_data,
                         cpu_rdata[rn_idx*DATA_WIDTH +: DATA_WIDTH]);
                tb_fail("CPU read data mismatch");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s CPU%0d read step=%0s addr=0x%011h data=0x%016h",
                     $time, current_test_id, current_task_name, rn_idx,
                     name, addr, cpu_rdata[rn_idx*DATA_WIDTH +: DATA_WIDTH]);
        end
    endtask

    task automatic dual_core_rn1_read_check;
        integer ar_before;
        begin
            tb_test_start("T22_DUAL_CORE_RN1_READ_SHARED_SN_MISS",
                          "dual_core_rn1_read_check",
                          "Second CPU/RN port must route a ReadShared miss through HN/SN and receive data on RN1");
            ar_before = axi_ar_count;
            cpu_read_check_rn(1,
                              DUAL_RN1_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(DUAL_RN1_ADDR, 0),
                              "RN1 ReadShared miss through SN");
            if (test_failed) return;
            if (axi_ar_count != (ar_before + 1)) begin
                tb_fail("RN1 read miss did not issue exactly one AXI AR");
                return;
            end
            tb_test_pass("RN1 request and response path completed through shared HN/SN");
        end
    endtask

    task automatic cpu_write_check;
        input [ADDR_WIDTH-1:0] addr;
        input [3:0] op;
        input [DATA_WIDTH-1:0] data;
        input [1023:0] name;
        begin
            cpu_write_check_rn(0, addr, op, data, name);
        end
    endtask

    task automatic cpu_write_check_rn;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [3:0] op;
        input [DATA_WIDTH-1:0] data;
        input [1023:0] name;
        integer timeout;
        integer aw_before;
        integer w_before;
        integer b_before;
        begin
            // Let earlier background dirty-victim writebacks drain so the
            // AXI write counts below only see this request.
            if (!allow_cpu_write_extra_axi) begin
                wait_axi_write_quiet(64);
                if (test_failed) return;
            end
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;
            strict_cpu_sparse_write_active = !allow_cpu_write_extra_axi;
            strict_cpu_sparse_write_addr = addr;
            strict_cpu_sparse_write_data = data;

            @(negedge clk);
            cpu_req_addr[rn_idx*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            cpu_req_op[rn_idx*4 +: 4] = op;
            cpu_req_size[rn_idx*3 +: 3] = 3'd6;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] = data;
            cpu_req_valid[rn_idx] = 1'b1;

            timeout = 0;
            while (timeout < MAX_WAIT) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_ready[rn_idx])
                    timeout = MAX_WAIT;
            end
            if (!cpu_req_ready[rn_idx]) begin
                tb_fail("CPU write request accept timeout");
                return;
            end

            @(negedge clk);
            cpu_req_valid[rn_idx] = 1'b0;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] =
                {DATA_WIDTH{1'b0}};

            timeout = 0;
            while (!cpu_resp_valid[rn_idx] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (!cpu_resp_valid[rn_idx]) begin
                tb_fail("CPU write response timeout");
                return;
            end

            @(negedge clk);
            if (allow_cpu_write_extra_axi) begin
                if (axi_aw_count < (aw_before + 1)) begin
                    tb_fail("CPU write did not issue any AXI AW");
                    return;
                end
                if (axi_w_count < (w_before + BEATS)) begin
                    tb_fail("CPU write did not issue at least one full AXI W burst");
                    return;
                end
                if (axi_b_count < (b_before + 1)) begin
                    tb_fail("CPU write did not complete any AXI B response");
                    return;
                end
                if (mem_pattern(addr, 0) !== data) begin
                    tb_fail("CPU write target data not observed in AXI shadow memory");
                    return;
                end
            end else begin
                if (axi_aw_count != (aw_before + 1)) begin
                    tb_fail("CPU write did not issue one AXI AW");
                    return;
                end
                if (axi_w_count != (w_before + BEATS)) begin
                    tb_fail("CPU write did not issue one full AXI W burst");
                    return;
                end
                if (axi_b_count != (b_before + 1)) begin
                    tb_fail("CPU write did not complete one AXI B response");
                    return;
                end
            end

            strict_cpu_sparse_write_active = 1'b0;
            $display("[%0t] TEST STEP  %0s task=%0s CPU%0d write step=%0s addr=0x%011h data=0x%016h",
                     $time, current_test_id, current_task_name,
                     rn_idx, name, addr, data);
        end
    endtask

    task automatic cpu_write_sized_check_rn;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [2:0] size;
        input [DATA_WIDTH-1:0] data;
        input [DATA_WIDTH-1:0] exp_word;
        input [1023:0] name;
        integer timeout;
        integer aw_before;
        integer w_before;
        integer b_before;
        integer beat_idx;
        begin
            // Let earlier background dirty-victim writebacks drain so the
            // AXI write counts below only see this request.
            if (!allow_cpu_write_extra_axi) begin
                wait_axi_write_quiet(64);
                if (test_failed) return;
            end
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;
            beat_idx = addr[5:2];

            @(negedge clk);
            cpu_req_addr[rn_idx*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            cpu_req_op[rn_idx*4 +: 4] = `CHI_CPU_OP_WB_FULL;
            cpu_req_size[rn_idx*3 +: 3] = size;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] = data;
            cpu_req_valid[rn_idx] = 1'b1;

            timeout = 0;
            while (timeout < MAX_WAIT) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_ready[rn_idx])
                    timeout = MAX_WAIT;
            end
            if (!cpu_req_ready[rn_idx]) begin
                tb_fail("CPU sized write request accept timeout");
                return;
            end

            @(negedge clk);
            cpu_req_valid[rn_idx] = 1'b0;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] =
                {DATA_WIDTH{1'b0}};

            timeout = 0;
            while (!cpu_resp_valid[rn_idx] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (!cpu_resp_valid[rn_idx]) begin
                tb_fail("CPU sized write response timeout");
                return;
            end

            @(negedge clk);
            if (axi_aw_count != (aw_before + 1)) begin
                tb_fail("CPU sized write did not issue one AXI AW");
                return;
            end
            if (axi_w_count != (w_before + BEATS)) begin
                tb_fail("CPU sized write did not issue one full AXI W burst");
                return;
            end
            if (axi_b_count != (b_before + 1)) begin
                tb_fail("CPU sized write did not complete one AXI B response");
                return;
            end
            if (mem_pattern(addr, beat_idx) !== exp_word) begin
                $display("[%0t] TEST STEP  %0s task=%0s CPU%0d sized write shadow mismatch step=%0s addr=0x%011h exp=0x%016h got=0x%016h",
                         $time, current_test_id, current_task_name,
                         rn_idx, name, addr, exp_word,
                         mem_pattern(addr, beat_idx));
                tb_fail("CPU sized write shadow mismatch");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s CPU%0d sized write step=%0s addr=0x%011h size=%0d data=0x%016h word=0x%016h",
                     $time, current_test_id, current_task_name,
                     rn_idx, name, addr, size, data, exp_word);
        end
    endtask

    task automatic cpu_strex_result_check;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        input exp_success;
        input expect_axi_write;
        input [1023:0] name;
        begin
            cpu_strex_result_check_rn(0, addr, data, exp_success,
                                      expect_axi_write, name);
        end
    endtask

    task automatic cpu_strex_result_check_rn;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        input exp_success;
        input expect_axi_write;
        input [1023:0] name;
        integer timeout;
        integer aw_before;
        integer w_before;
        integer b_before;
        reg [DATA_WIDTH-1:0] exp_result;
        reg [DATA_WIDTH-1:0] got_result;
        begin
            // Let earlier background dirty-victim writebacks drain so the
            // AXI write counts below only see this request.
            if (!allow_cpu_write_extra_axi) begin
                wait_axi_write_quiet(64);
                if (test_failed) return;
            end
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;
            exp_result = {{(DATA_WIDTH-1){1'b0}}, exp_success};

            @(negedge clk);
            cpu_req_addr[rn_idx*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            cpu_req_op[rn_idx*4 +: 4] = `CHI_CPU_OP_STREX;
            cpu_req_size[rn_idx*3 +: 3] = 3'd6;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] = data;
            cpu_req_valid[rn_idx] = 1'b1;

            timeout = 0;
            while (timeout < MAX_WAIT) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_ready[rn_idx])
                    timeout = MAX_WAIT;
            end
            if (!cpu_req_ready[rn_idx]) begin
                tb_fail("CPU STREX request accept timeout");
                return;
            end

            @(negedge clk);
            cpu_req_valid[rn_idx] = 1'b0;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] =
                {DATA_WIDTH{1'b0}};

            timeout = 0;
            while (!cpu_resp_valid[rn_idx] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (!cpu_resp_valid[rn_idx]) begin
                tb_fail("CPU STREX response timeout");
                return;
            end

            got_result = cpu_rdata[rn_idx*DATA_WIDTH +: DATA_WIDTH];
            if (got_result !== exp_result) begin
                $display("[%0t] TEST STEP  %0s task=%0s CPU%0d STREX result mismatch step=%0s addr=0x%011h exp=0x%016h got=0x%016h",
                         $time, current_test_id, current_task_name,
                         rn_idx, name, addr, exp_result, got_result);
                tb_fail("CPU STREX result mismatch");
                return;
            end

            if (expect_axi_write) begin
                @(negedge clk);
                if (axi_aw_count != (aw_before + 1)) begin
                    tb_fail("STREX success did not issue one AXI AW");
                    return;
                end
                if (axi_w_count != (w_before + BEATS)) begin
                    tb_fail("STREX success did not issue one full AXI W burst");
                    return;
                end
                if (axi_b_count != (b_before + 1)) begin
                    tb_fail("STREX success did not complete one AXI B response");
                    return;
                end
            end else begin
                wait_cycles(10);
                if (axi_aw_count != aw_before) begin
                    tb_fail("STREX fail unexpectedly issued AXI AW");
                    return;
                end
                if (axi_w_count != w_before) begin
                    tb_fail("STREX fail unexpectedly issued AXI W beats");
                    return;
                end
                if (axi_b_count != b_before) begin
                    tb_fail("STREX fail unexpectedly completed AXI B");
                    return;
                end
            end

            $display("[%0t] TEST STEP  %0s task=%0s CPU%0d STREX step=%0s addr=0x%011h data=0x%016h result=0x%016h axi_write=%0d",
                     $time, current_test_id, current_task_name,
                     rn_idx, name, addr, data, got_result, expect_axi_write);
        end
    endtask

    task automatic cpu_op_resp_check_rn;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [3:0] op;
        input [DATA_WIDTH-1:0] data;
        input [1023:0] name;
        integer timeout;
        begin
            @(negedge clk);
            cpu_req_addr[rn_idx*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            cpu_req_op[rn_idx*4 +: 4] = op;
            cpu_req_size[rn_idx*3 +: 3] = 3'd6;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] = data;
            cpu_req_valid[rn_idx] = 1'b1;

            timeout = 0;
            while (timeout < MAX_WAIT) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_ready[rn_idx])
                    timeout = MAX_WAIT;
            end
            if (!cpu_req_ready[rn_idx]) begin
                tb_fail("CPU op request accept timeout");
                return;
            end

            @(negedge clk);
            cpu_req_valid[rn_idx] = 1'b0;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] =
                {DATA_WIDTH{1'b0}};

            timeout = 0;
            while (!cpu_resp_valid[rn_idx] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (!cpu_resp_valid[rn_idx]) begin
                tb_fail("CPU op response timeout");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s CPU%0d op step=%0s op=0x%0h addr=0x%011h resp_data=0x%016h",
                     $time, current_test_id, current_task_name,
                     rn_idx, name, op, addr,
                     cpu_rdata[rn_idx*DATA_WIDTH +: DATA_WIDTH]);
        end
    endtask

    task automatic dual_rn_read_concurrent_check;
        input [ADDR_WIDTH-1:0] addr0;
        input [ADDR_WIDTH-1:0] addr1;
        input [DATA_WIDTH-1:0] exp0;
        input [DATA_WIDTH-1:0] exp1;
        input [1023:0] name;
        integer timeout;
        reg [NUM_RN-1:0] accepted;
        reg [NUM_RN-1:0] responded;
        reg [DATA_WIDTH-1:0] got0;
        reg [DATA_WIDTH-1:0] got1;
        begin
            accepted = {NUM_RN{1'b0}};
            responded = {NUM_RN{1'b0}};
            got0 = {DATA_WIDTH{1'b0}};
            got1 = {DATA_WIDTH{1'b0}};

            @(negedge clk);
            cpu_req_addr[0*ADDR_WIDTH +: ADDR_WIDTH] = addr0;
            cpu_req_addr[1*ADDR_WIDTH +: ADDR_WIDTH] = addr1;
            cpu_req_op[0*4 +: 4] = `CHI_CPU_OP_RD_SHARED;
            cpu_req_op[1*4 +: 4] = `CHI_CPU_OP_RD_SHARED;
            cpu_req_size[0*3 +: 3] = 3'd6;
            cpu_req_size[1*3 +: 3] = 3'd6;
            cpu_wdata[0*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            cpu_wdata[1*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            cpu_req_valid[0] = 1'b1;
            cpu_req_valid[1] = 1'b1;

            timeout = 0;
            while (((accepted[0] == 1'b0) || (accepted[1] == 1'b0)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_valid[0] && cpu_req_ready[0])
                    accepted[0] = 1'b1;
                if (cpu_req_valid[1] && cpu_req_ready[1])
                    accepted[1] = 1'b1;
                @(negedge clk);
                if (accepted[0])
                    cpu_req_valid[0] = 1'b0;
                if (accepted[1])
                    cpu_req_valid[1] = 1'b0;
            end
            if ((accepted[0] == 1'b0) || (accepted[1] == 1'b0)) begin
                tb_fail("Dual RN read request accept timeout");
                return;
            end

            timeout = 0;
            while (((responded[0] == 1'b0) || (responded[1] == 1'b0)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (!responded[0] && cpu_resp_valid[0]) begin
                    responded[0] = 1'b1;
                    got0 = cpu_rdata[0*DATA_WIDTH +: DATA_WIDTH];
                end
                if (!responded[1] && cpu_resp_valid[1]) begin
                    responded[1] = 1'b1;
                    got1 = cpu_rdata[1*DATA_WIDTH +: DATA_WIDTH];
                end
            end
            if ((responded[0] == 1'b0) || (responded[1] == 1'b0)) begin
                tb_fail("Dual RN read response timeout");
                return;
            end
            if (got0 !== exp0) begin
                $display("[%0t] TEST STEP  %0s task=%0s CPU0 concurrent read mismatch step=%0s addr=0x%011h exp=0x%016h got=0x%016h",
                         $time, current_test_id, current_task_name,
                         name, addr0, exp0, got0);
                tb_fail("CPU0 concurrent read data mismatch");
                return;
            end
            if (got1 !== exp1) begin
                $display("[%0t] TEST STEP  %0s task=%0s CPU1 concurrent read mismatch step=%0s addr=0x%011h exp=0x%016h got=0x%016h",
                         $time, current_test_id, current_task_name,
                         name, addr1, exp1, got1);
                tb_fail("CPU1 concurrent read data mismatch");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s dual read step=%0s rn0_addr=0x%011h rn0_data=0x%016h rn1_addr=0x%011h rn1_data=0x%016h",
                     $time, current_test_id, current_task_name,
                     name, addr0, got0, addr1, got1);
        end
    endtask

    task automatic dual_core_rn1_writeback_check;
        begin
            tb_test_start("T23_DUAL_CORE_RN1_WRITEBACK_FULL_SN",
                          "dual_core_rn1_writeback_check",
                          "RN1 CPU WriteBackFull of a line it does not own goes out as WriteUnique, updates AXI shadow memory and leaves no RN1 copy");

            cpu_write_check_rn(1,
                               DUAL_RN1_WB_ADDR,
                               `CHI_CPU_OP_WB_FULL,
                               DUAL_RN1_WB_DATA,
                               "RN1 WriteBackFull through SN");
            if (test_failed) return;

            if (mem_pattern(DUAL_RN1_WB_ADDR, 0) !== DUAL_RN1_WB_DATA) begin
                tb_fail("RN1 WriteBackFull did not update AXI shadow memory");
                return;
            end

            rn_cache_expect_state(1,
                                  DUAL_RN1_WB_ADDR,
                                  1'b0,
                                  `CHI_STATE_I,
                                  "RN1 keeps no copy after the write");
            if (test_failed) return;

            tb_test_pass("RN1 write completed through AXI and left no RN1 copy");
        end
    endtask

    task automatic dual_core_same_line_rw_check;
        begin
            tb_test_start("T24_DUAL_CORE_SAME_LINE_RW",
                          "dual_core_same_line_rw_check",
                          "RN0 and RN1 read/write the same cache line and observe latest writer data");

            cpu_write_check_rn(0,
                               DUAL_SHARED_LINE_ADDR,
                               `CHI_CPU_OP_WB_FULL,
                               DUAL_SHARED_DATA0,
                               "RN0 writes shared line");
            if (test_failed) return;

            cpu_read_check_rn(1,
                              DUAL_SHARED_LINE_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              DUAL_SHARED_DATA0,
                              "RN1 reads RN0 same-line data");
            if (test_failed) return;

            cpu_write_check_rn(1,
                               DUAL_SHARED_LINE_ADDR,
                               `CHI_CPU_OP_WB_FULL,
                               DUAL_SHARED_DATA1,
                               "RN1 overwrites shared line");
            if (test_failed) return;

            cpu_read_check_rn(0,
                              DUAL_SHARED_LINE_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              DUAL_SHARED_DATA1,
                              "RN0 reads RN1 same-line data");
            if (test_failed) return;

            tb_test_pass("Same-line RN0/RN1 read/write sequence preserved latest writer data");
        end
    endtask

    // P0-1: a clean ReadShared from a second RN must keep the first sharer
    // in the snoop filter, so a later ReadUnique still invalidates it.
    // The RN cache serves hits locally, so a test that needs a read to reach
    // the fabric first makes the RN give its copy up (a dirty copy is
    // written back).
    task automatic rn_drop_line;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        begin
            cpu_op_resp_check_rn(rn_idx, addr, `CHI_CPU_OP_EVICT,
                                 {DATA_WIDTH{1'b0}}, "drop RN copy");
        end
    endtask

    // Make RN rn_idx the dirty (UD) owner of a line the way a CPU does:
    // ReadUnique for ownership, then a store that hits the owned line and
    // is merged locally.
    task automatic rn_make_dirty;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        input [1023:0] name;
        begin
            cpu_op_resp_check_rn(rn_idx, addr, `CHI_CPU_OP_RD_UNIQUE,
                                 {DATA_WIDTH{1'b0}}, "ReadUnique for ownership");
            if (test_failed) return;
            cpu_op_resp_check_rn(rn_idx, addr, `CHI_CPU_OP_WR_UNIQUE,
                                 data, name);
            if (test_failed) return;
            rn_cache_expect_state(rn_idx, addr, 1'b1, `CHI_STATE_UD, name);
        end
    endtask

    task automatic p0_sf_shared_sharer_retained_check;
        integer way;
        reg found;
        reg [2:0] state;
        begin
            tb_test_start("T40_P0_SF_SHARED_SHARER_RETAINED",
                          "p0_sf_shared_sharer_retained_check",
                          "RN0+RN1 ReadShared keep both sharers in SF; RN1 ReadUnique must invalidate RN0");

            cpu_read_check_rn(0, P0_SF_ADDR, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(P0_SF_ADDR, 0),
                              "RN0 ReadShared fill");
            if (test_failed) return;

            cpu_read_check_rn(1, P0_SF_ADDR, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(P0_SF_ADDR, 0),
                              "RN1 ReadShared joins sharers");
            if (test_failed) return;

            wait_cycles(20);
            rn_cache_lookup(0, P0_SF_ADDR, found, state, way);
            if (!found) begin
                tb_fail("RN0 lost its shared copy after RN1 ReadShared");
                return;
            end

            cpu_read_check_rn(1, P0_SF_ADDR, `CHI_CPU_OP_RD_UNIQUE,
                              mem_pattern(P0_SF_ADDR, 0),
                              "RN1 ReadUnique upgrades");
            if (test_failed) return;

            rn_cache_expect_state(0, P0_SF_ADDR, 1'b0, `CHI_STATE_I,
                                  "RN0 invalidated by RN1 ReadUnique");
            if (test_failed) return;

            tb_test_pass("Snoop filter kept RN0 as sharer and RN1 ReadUnique invalidated it");
        end
    endtask

    // P0-3: two RNs writing different lines at the same time must not have
    // their write-data beats mixed at the SN/AXI boundary.
    task automatic p0_concurrent_writeback_data_check;
        integer timeout;
        integer b;
        integer rn;
        reg [NUM_RN-1:0] accepted;
        reg [NUM_RN-1:0] responded;
        reg [ADDR_WIDTH-1:0] line_addr;
        reg [DATA_WIDTH-1:0] exp_word;
        reg [DATA_WIDTH-1:0] got_word;
        begin
            tb_test_start("T41_P0_CONCURRENT_WRITEBACK_DATA",
                          "p0_concurrent_writeback_data_check",
                          "RN0 and RN1 WriteBackFull to different lines at once; each AXI line must hold only its own data");

            accepted = {NUM_RN{1'b0}};
            responded = {NUM_RN{1'b0}};

            @(negedge clk);
            cpu_req_addr[0*ADDR_WIDTH +: ADDR_WIDTH] = P0_WB_ADDR0;
            cpu_req_addr[1*ADDR_WIDTH +: ADDR_WIDTH] = P0_WB_ADDR1;
            cpu_req_op[0*4 +: 4] = `CHI_CPU_OP_WB_FULL;
            cpu_req_op[1*4 +: 4] = `CHI_CPU_OP_WB_FULL;
            cpu_req_size[0*3 +: 3] = 3'd6;
            cpu_req_size[1*3 +: 3] = 3'd6;
            cpu_wdata[0*DATA_WIDTH +: DATA_WIDTH] = P0_WB_DATA0;
            cpu_wdata[1*DATA_WIDTH +: DATA_WIDTH] = P0_WB_DATA1;
            cpu_req_valid[0] = 1'b1;
            cpu_req_valid[1] = 1'b1;

            timeout = 0;
            while ((accepted != {NUM_RN{1'b1}}) && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                for (rn = 0; rn < NUM_RN; rn = rn + 1)
                    if (cpu_req_valid[rn] && cpu_req_ready[rn])
                        accepted[rn] = 1'b1;
                @(negedge clk);
                for (rn = 0; rn < NUM_RN; rn = rn + 1)
                    if (accepted[rn]) begin
                        cpu_req_valid[rn] = 1'b0;
                        cpu_wdata[rn*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
                    end
            end
            if (accepted != {NUM_RN{1'b1}}) begin
                tb_fail("Concurrent WriteBack accept timeout");
                return;
            end

            timeout = 0;
            while ((responded != {NUM_RN{1'b1}}) && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                for (rn = 0; rn < NUM_RN; rn = rn + 1)
                    if (cpu_resp_valid[rn])
                        responded[rn] = 1'b1;
            end
            if (responded != {NUM_RN{1'b1}}) begin
                tb_fail("Concurrent WriteBack completion timeout");
                return;
            end
            wait_cycles(20);

            for (rn = 0; rn < NUM_RN; rn = rn + 1) begin
                line_addr = (rn == 0) ? P0_WB_ADDR0 : P0_WB_ADDR1;
                if (mem_shadow_find(line_addr) < 0) begin
                    $display("[%0t] TEST STEP  %0s task=%0s no AXI write observed for line 0x%011h",
                             $time, current_test_id, current_task_name, line_addr);
                    tb_fail("Concurrent WriteBack line never reached AXI");
                    return;
                end
                for (b = 0; b < BEATS; b = b + 1) begin
                    exp_word = (b == 0) ?
                               ((rn == 0) ? P0_WB_DATA0 : P0_WB_DATA1) :
                               base_mem_pattern(line_addr, b);
                    got_word = mem_pattern(line_addr, b);
                    if (got_word !== exp_word) begin
                        $display("[%0t] TEST STEP  %0s task=%0s line=0x%011h beat=%0d exp=0x%08h got=0x%08h",
                                 $time, current_test_id, current_task_name,
                                 line_addr, b, exp_word, got_word);
                        tb_fail("Concurrent WriteBack data mixed between lines");
                        return;
                    end
                end
            end

            tb_test_pass("Concurrent RN0/RN1 WriteBackFull kept per-line AXI data intact");
        end
    endtask

    // Watchdog, not functional timeout: a slow memory that holds AXI R for
    // longer than the node timeouts must still complete the read with the
    // right data. The timeout may only raise ERR_STATUS[4] (watchdog).
    task automatic watchdog_slow_memory_read_check;
        begin
            tb_test_start("T42_WATCHDOG_SLOW_MEMORY_READ",
                          "watchdog_slow_memory_read_check",
                          "AXI R held longer than RN/HN timeouts; read completes with correct data and only ERR_STATUS[4] reports it");

            csr_write64(8'h40, 64'h1F);
            csr_read_check(8'h40, 64'h00, 64'h1F);
            if (test_failed) return;

            rn_watchdog_expected = 1'b1;
            allow_chi_irq = 1'b1;
            axi_r_hold = 1'b1;
            fork
                begin
                    wait_cycles(WDOG_HOLD_CYCLES);
                    axi_r_hold = 1'b0;
                end
                cpu_read_check_rn(0, WDOG_ADDR, `CHI_CPU_OP_RD_SHARED,
                                  mem_pattern(WDOG_ADDR, 0),
                                  "Read held past the timeout still returns memory data");
            join
            axi_r_hold = 1'b0;
            if (test_failed) return;

            wait_cycles(20);
            rn_watchdog_expected = 1'b0;

            csr_read_check(8'h40, 64'h10, 64'h1F);
            if (test_failed) return;
            if (!chi_irq) begin
                tb_fail("Watchdog event did not raise the CHI IRQ");
                return;
            end
            csr_write64(8'h40, 64'h10);
            csr_read_check(8'h40, 64'h00, 64'h1F);
            if (test_failed) return;
            wait_cycles(2);
            if (chi_irq) begin
                tb_fail("CHI IRQ stayed high after ERR_STATUS[4] W1C clear");
                return;
            end
            allow_chi_irq = 1'b0;

            cpu_read_check_rn(0, WDOG_ADDR + 32'h40, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(WDOG_ADDR + 32'h40, 0),
                              "Next read after watchdog event completes normally");
            if (test_failed) return;

            tb_test_pass("Slow read completed with correct data; watchdog only set ERR_STATUS[4]");
        end
    endtask

    // fabric_clear only resets the fabric queues, not the node trackers, so
    // a BIST init while traffic is in flight must be refused: no clear
    // pulse, ERR_STATUS[5] set, and the in-flight read still completes. An
    // idle BIST init is accepted and pulses fabric_clear once.
    task automatic bist_init_busy_reject_check;
        reg [63:0] ctrl;
        integer    clears_before;
        begin
            tb_test_start("T45_BIST_INIT_REJECTED_WHILE_BUSY",
                          "bist_init_busy_reject_check",
                          "BIST init while a read is held at AXI R is refused with ERR_STATUS[5]; an idle BIST init pulses fabric_clear");

            csr_write64(8'h40, 64'h3F);
            csr_read_check(8'h40, 64'h00, 64'h3F);
            if (test_failed) return;
            csr_read_value(8'h00, ctrl);
            if (test_failed) return;

            wait_axi_write_quiet(64);
            if (test_failed) return;
            wait_cycles(20);
            if (dut.chi_busy) begin
                cg_busy_dump();
                tb_fail("Interconnect still busy before the idle BIST init");
                return;
            end
            clears_before = fabric_clear_count;
            csr_write64(8'h00, ctrl | 64'h8);
            wait_cycles(4);
            if (fabric_clear_count != clears_before + 1) begin
                tb_fail("Idle BIST init did not pulse fabric_clear exactly once");
                return;
            end
            csr_read_check(8'h40, 64'h00, 64'h3F);
            if (test_failed) return;

            clears_before = fabric_clear_count;
            axi_r_hold = 1'b1;
            fork
                begin
                    wait_cycles(80);
                    if (!dut.chi_busy)
                        tb_fail("Read held at AXI R did not keep the interconnect busy");
                    csr_write64(8'h00, ctrl | 64'h8);
                    wait_cycles(4);
                    axi_r_hold = 1'b0;
                end
                cpu_read_check_rn(0, WDOG_ADDR + 32'h100, `CHI_CPU_OP_RD_SHARED,
                                  mem_pattern(WDOG_ADDR + 32'h100, 0),
                                  "Read in flight across a refused BIST init still returns memory data");
            join
            axi_r_hold = 1'b0;
            if (test_failed) return;

            if (fabric_clear_count != clears_before) begin
                tb_fail("BIST init while busy still pulsed fabric_clear");
                return;
            end
            csr_read_check(8'h40, 64'h20, 64'h3F);
            if (test_failed) return;
            csr_write64(8'h40, 64'h20);
            csr_read_check(8'h40, 64'h00, 64'h3F);
            if (test_failed) return;

            tb_test_pass("Busy BIST init refused with ERR_STATUS[5] and no fabric_clear; idle BIST init pulsed fabric_clear once");
        end
    endtask

    integer a1_req_count [0:NUM_RN-1];
    reg [`CHI_REQ_OPCODE_W-1:0] a1_last_req_op [0:NUM_RN-1];
    integer a1_mon_i;
    initial begin
        for (a1_mon_i = 0; a1_mon_i < NUM_RN; a1_mon_i = a1_mon_i + 1) begin
            a1_req_count[a1_mon_i] = 0;
            a1_last_req_op[a1_mon_i] = 6'd0;
        end
    end
    always @(posedge clk) begin
        if (dut.rn_tx_req_valid[0]) begin
            a1_req_count[0] <= a1_req_count[0] + 1;
            a1_last_req_op[0] <= dut.gen_rn[0].u_rn_f.tx_req_flit[`CHI_REQ_OPCODE_LSB(NODE_ID_W) +: `CHI_REQ_OPCODE_W];
        end
        if (dut.rn_tx_req_valid[1]) begin
            a1_req_count[1] <= a1_req_count[1] + 1;
            a1_last_req_op[1] <= dut.gen_rn[1].u_rn_f.tx_req_flit[`CHI_REQ_OPCODE_LSB(NODE_ID_W) +: `CHI_REQ_OPCODE_W];
        end
    end

    // P0-4 / A1: the RN cache is a real cache. A read of a held line and a
    // store to an owned line are served locally, with no request on REQ.
    task automatic a1_local_hit_check;
        integer ar_before;
        integer req_before;
        begin
            tb_test_start("T47_A1_LOCAL_READ_STORE_HIT",
                          "a1_local_hit_check",
                          "Read of a held line and store to an owned line complete in the RN without REQ traffic");

            cpu_read_check_rn(0, A1_HIT_ADDR, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(A1_HIT_ADDR, 0), "RN0 ReadShared fill");
            if (test_failed) return;
            wait_cycles(10);
            ar_before = axi_ar_count;
            req_before = a1_req_count[0];
            cpu_read_check_rn(0, A1_HIT_ADDR + 4, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(A1_HIT_ADDR, 1), "RN0 read hit word 1");
            if (test_failed) return;
            if ((axi_ar_count != ar_before) || (a1_req_count[0] != req_before)) begin
                tb_fail("Read hit on a held line left the RN");
                return;
            end

            cpu_read_check_rn(0, A1_STORE_ADDR, `CHI_CPU_OP_RD_UNIQUE,
                              mem_pattern(A1_STORE_ADDR, 0), "RN0 ReadUnique fill");
            if (test_failed) return;
            wait_cycles(10);
            req_before = a1_req_count[0];
            cpu_op_resp_check_rn(0, A1_STORE_ADDR + 8, `CHI_CPU_OP_WR_UNIQUE,
                                 A1_DATA0, "RN0 store hit word 2");
            if (test_failed) return;
            rn_cache_expect_state(0, A1_STORE_ADDR, 1'b1, `CHI_STATE_UD,
                                  "RN0 line dirty after local store");
            if (test_failed) return;
            cpu_read_check_rn(0, A1_STORE_ADDR + 8, `CHI_CPU_OP_RD_SHARED,
                              A1_DATA0, "RN0 reads its own store");
            if (test_failed) return;
            cpu_read_check_rn(0, A1_STORE_ADDR + 12, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(A1_STORE_ADDR, 3), "RN0 other words kept");
            if (test_failed) return;
            if (a1_req_count[0] != req_before) begin
                tb_fail("Store hit or read hit on an owned line left the RN");
                return;
            end

            // Another RN sees the store: RN1 read snoops the dirty owner.
            cpu_read_check_rn(1, A1_STORE_ADDR + 8, `CHI_CPU_OP_RD_SHARED,
                              A1_DATA0, "RN1 reads RN0 dirty store");
            if (test_failed) return;

            tb_test_pass("Local read and store hits needed no REQ; the dirty line was visible to RN1");
        end
    endtask

    // Per-RN, per-tag CPU responses, for tests that keep several requests
    // outstanding on one RN.
    reg a1_resp_seen [0:NUM_RN-1][0:(1<<CPU_TAG_W)-1];
    reg [DATA_WIDTH-1:0] a1_resp_data [0:NUM_RN-1][0:(1<<CPU_TAG_W)-1];
    always @(posedge clk) begin
        if (cpu_resp_valid[0]) begin
            a1_resp_seen[0][cpu_resp_tag[0*CPU_TAG_W +: CPU_TAG_W]] <= 1'b1;
            a1_resp_data[0][cpu_resp_tag[0*CPU_TAG_W +: CPU_TAG_W]] <=
                cpu_rdata[0*DATA_WIDTH +: DATA_WIDTH];
        end
        if (cpu_resp_valid[1]) begin
            a1_resp_seen[1][cpu_resp_tag[1*CPU_TAG_W +: CPU_TAG_W]] <= 1'b1;
            a1_resp_data[1][cpu_resp_tag[1*CPU_TAG_W +: CPU_TAG_W]] <=
                cpu_rdata[1*DATA_WIDTH +: DATA_WIDTH];
        end
    end

    // Issue one CPU request with a tag and return once it is accepted.
    task automatic a1_issue;
        input integer rn_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [3:0] op;
        input [DATA_WIDTH-1:0] data;
        input [CPU_TAG_W-1:0] tag;
        integer timeout;
        begin
            @(negedge clk);
            a1_resp_seen[rn_idx][tag] = 1'b0;
            cpu_req_addr[rn_idx*ADDR_WIDTH +: ADDR_WIDTH] = addr;
            cpu_req_op[rn_idx*4 +: 4] = op;
            cpu_req_size[rn_idx*3 +: 3] = 3'd6;
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] = data;
            cpu_req_tag[rn_idx*CPU_TAG_W +: CPU_TAG_W] = tag;
            cpu_req_valid[rn_idx] = 1'b1;
            timeout = 0;
            while (timeout < MAX_WAIT) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_ready[rn_idx])
                    timeout = MAX_WAIT;
            end
            @(negedge clk);
            cpu_req_valid[rn_idx] = 1'b0;
            cpu_req_tag[rn_idx*CPU_TAG_W +: CPU_TAG_W] = {CPU_TAG_W{1'b0}};
            cpu_wdata[rn_idx*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
        end
    endtask

    task automatic a1_wait_resp;
        input integer rn_idx;
        input [CPU_TAG_W-1:0] tag;
        input integer max_cycles;
        output reg seen;
        integer timeout;
        begin
            timeout = 0;
            while (!a1_resp_seen[rn_idx][tag] && (timeout < max_cycles)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            seen = a1_resp_seen[rn_idx][tag];
        end
    endtask

    // A snoop must see a dirty line whose WriteBackFull is still queued, and
    // a WriteBack that lost that race must not overwrite newer data.
    // An RN1 read held at AXI R keeps the HN from starting any other
    // request, so the order at the HN is fixed:
    //   RN1 ReadUnique X, RN1 read B1, RN0 WriteBackFull X (from Evict).
    // RN1's ReadUnique snoops RN0 while RN0's WriteBack is still queued.
    // RN1 then stores to X locally before RN0's WriteBack reaches the HN.
    task automatic a1_victim_snoop_check;
        reg seen;
        integer r_before;
        reg [DATA_WIDTH-1:0] x_data;
        begin
            tb_test_start("T51_A1_SNOOP_PENDING_WRITEBACK",
                          "a1_victim_snoop_check",
                          "Snoop hits a queued WriteBack's dirty line; the stale WriteBack must not overwrite the new owner's data");

            rn_make_dirty(0, A1_VIC_ADDR, A1_DATA0, "RN0 dirty word 0");
            if (test_failed) return;
            wait_axi_write_quiet(64);
            if (test_failed) return;

            axi_r_hold = 1'b1;
            r_before = axi_ar_count;
            a1_issue(1, A1_VIC_BLOCK0, `CHI_CPU_OP_RD_SHARED, {DATA_WIDTH{1'b0}}, 2'd1);
            wait (axi_ar_count > r_before);
            a1_issue(1, A1_VIC_ADDR, `CHI_CPU_OP_RD_UNIQUE, {DATA_WIDTH{1'b0}}, 2'd2);
            wait_cycles(30);
            a1_issue(1, A1_VIC_BLOCK1, `CHI_CPU_OP_RD_SHARED, {DATA_WIDTH{1'b0}}, 2'd3);
            wait_cycles(30);

            fork
                cpu_op_resp_check_rn(0, A1_VIC_ADDR, `CHI_CPU_OP_EVICT,
                                     {DATA_WIDTH{1'b0}}, "RN0 Evict writes back X");
                begin
                    wait (a1_last_req_op[0] == `CHI_REQ_WB_FULL);
                    wait_cycles(20);
                    // Let B0 finish, then hold R again so B1 blocks the HN
                    // in front of RN0's WriteBack.
                    r_before = axi_r_count;
                    axi_r_hold = 1'b0;
                    wait (axi_r_count >= (r_before + BEATS));
                    axi_r_hold = 1'b1;
                    a1_wait_resp(1, 2'd2, 3000, seen);
                    if (!seen) begin
                        // X itself needed memory (the snoop missed); let it
                        // finish so the data check below reports the error.
                        axi_r_hold = 1'b0;
                        a1_wait_resp(1, 2'd2, MAX_WAIT, seen);
                        axi_r_hold = 1'b1;
                    end
                    x_data = a1_resp_data[1][2];
                    if (seen) begin
                        a1_issue(1, A1_VIC_ADDR + 4, `CHI_CPU_OP_WR_UNIQUE, A1_DATA2, 2'd0);
                        a1_wait_resp(1, 2'd0, MAX_WAIT, seen);
                    end
                    wait_cycles(20);
                    axi_r_hold = 1'b0;
                end
            join
            axi_r_hold = 1'b0;
            if (test_failed) return;
            a1_wait_resp(1, 2'd1, MAX_WAIT, seen);
            a1_wait_resp(1, 2'd3, MAX_WAIT, seen);
            if (!seen) begin
                tb_fail("RN1 blocking reads did not complete");
                return;
            end

            if (x_data !== A1_DATA0) begin
                $display("[%0t] TEST STEP  %0s task=%0s RN1 ReadUnique got 0x%08h exp 0x%08h",
                         $time, current_test_id, current_task_name, x_data, A1_DATA0);
                tb_fail("Snoop missed the dirty line of a queued WriteBack");
                return;
            end

            rn_drop_line(1, A1_VIC_ADDR);
            if (test_failed) return;
            wait_axi_write_quiet(64);
            if (test_failed) return;
            cpu_read_check_rn(0, A1_VIC_ADDR + 4, `CHI_CPU_OP_RD_SHARED,
                              A1_DATA2, "RN1 store survives RN0 stale WriteBack");
            if (test_failed) return;
            cpu_read_check_rn(0, A1_VIC_ADDR, `CHI_CPU_OP_RD_SHARED,
                              A1_DATA0, "RN0 dirty word 0 kept");
            if (test_failed) return;

            tb_test_pass("Queued WriteBack data served the snoop; its late copy did not overwrite RN1's store");
        end
    endtask

    // HN: a read miss must not overtake a write to the same line that the
    // HN has already started. An RN1 read held at AXI R stalls the HN while
    // RN0's WriteUnique X and then RN1's read of X queue up. When the stall
    // ends the HN starts the write first; RN0's DAT link is held, so the
    // write has no data yet when the HN reaches RN1's read.
    task automatic hn_read_after_write_hazard_check;
        reg seen;
        integer ar_before;
        begin
            tb_test_start("T52_HN_READ_AFTER_WRITE_SAME_LINE",
                          "hn_read_after_write_hazard_check",
                          "Read miss of a line whose write is still in flight to the SN returns the written data");
            wait_axi_write_quiet(64);
            if (test_failed) return;
            allow_cpu_write_extra_axi = 1'b1;
            // Close RN0's DAT link on both sides of the handshake so no flit
            // is lost or repeated while it is held.
            force dut.gen_rn[0].u_rn_f.tx_dat_link_valid = 1'b0;
            force dut.gen_rn[0].u_rn_f.tx_dat_link_ready = 1'b0;
            axi_r_hold = 1'b1;
            ar_before = axi_ar_count;
            a1_issue(1, RAW_BLOCK_ADDR, `CHI_CPU_OP_RD_SHARED, {DATA_WIDTH{1'b0}}, 2'd1);
            wait (axi_ar_count > ar_before);
            fork
                cpu_write_check_rn(0, RAW_ADDR, `CHI_CPU_OP_WR_UNIQUE, RAW_DATA,
                                   "RN0 WriteUnique with WriteData held");
                begin
                    wait_cycles(30);
                    a1_issue(1, RAW_ADDR, `CHI_CPU_OP_RD_SHARED, {DATA_WIDTH{1'b0}}, 2'd2);
                    wait_cycles(30);
                    axi_r_hold = 1'b0;
                    wait (|dut.gen_hn[0].u_hn_f.wr_tracker_active_valid_vec);
                    wait_cycles(300);
                    release dut.gen_rn[0].u_rn_f.tx_dat_link_valid;
                    release dut.gen_rn[0].u_rn_f.tx_dat_link_ready;
                end
            join
            release dut.gen_rn[0].u_rn_f.tx_dat_link_valid;
            release dut.gen_rn[0].u_rn_f.tx_dat_link_ready;
            axi_r_hold = 1'b0;
            allow_cpu_write_extra_axi = 1'b0;
            if (test_failed) return;
            a1_wait_resp(1, 2'd1, MAX_WAIT, seen);
            a1_wait_resp(1, 2'd2, MAX_WAIT, seen);
            if (!seen) begin
                tb_fail("RN1 read of the written line did not complete");
                return;
            end
            if (a1_resp_data[1][2] !== RAW_DATA) begin
                $display("[%0t] TEST STEP  %0s task=%0s RN1 read got 0x%08h exp 0x%08h",
                         $time, current_test_id, current_task_name,
                         a1_resp_data[1][2], RAW_DATA);
                tb_fail("Read overtook the in-flight write to the same line");
                return;
            end
            tb_test_pass("Read waited for the in-flight write and returned its data");
        end
    endtask

    // 1.5: the HN keeps more than one write outstanding at the SN, and the
    // SN pairs each WriteData beat with its write by DBID. Both RNs' DAT
    // links are held while their WriteUniques start, then released in the
    // same cycle so the two bursts interleave on the way to the SN.
    task automatic hn_multi_write_outstanding_check;
        reg seen0;
        reg seen1;
        integer b;
        integer t;
        integer il_before;
        reg [DATA_WIDTH-1:0] exp_word;
        begin
            tb_test_start("T53_HN_TWO_WRITES_OUTSTANDING",
                          "hn_multi_write_outstanding_check",
                          "Two WriteUniques are outstanding at the HN and SN together; their interleaved WriteData lands in the right lines");
            wait_axi_write_quiet(64);
            if (test_failed) return;
            allow_cpu_write_extra_axi = 1'b1;
            mw_active_max = 0;
            il_before = mw_interleave_count;
            // Equal QoS, so the fabric alternates between the two bursts
            // (an earlier test leaves RN0 at QoS 9).
            cpu_req_qos = {NUM_RN*QOS_W{1'b0}};
            // Hold both RNs' WriteData between the wdat engine and the DAT
            // link: the link sees no valid, the engine sees no ready.
            force dut.gen_rn[0].u_rn_f.tx_dat_link_valid = 1'b0;
            force dut.gen_rn[0].u_rn_f.wdat_engine_ready = 1'b0;
            force dut.gen_rn[1].u_rn_f.tx_dat_link_valid = 1'b0;
            force dut.gen_rn[1].u_rn_f.wdat_engine_ready = 1'b0;
            a1_issue(0, MW_ADDR0, `CHI_CPU_OP_WR_UNIQUE, MW_DATA0, 2'd1);
            a1_issue(1, MW_ADDR1, `CHI_CPU_OP_WR_UNIQUE, MW_DATA1, 2'd1);
            t = 0;
            while ((mw_active_max < 2) && (t < 400)) begin
                t = t + 1;
                @(posedge clk);
            end
            // Let both DBIDResps reach their RNs.
            wait_cycles(60);
            if ($test$plusargs("MW_TRACE"))
                $display("[%0t] MW_TRACE release wdat_valid rn0=%0b rn1=%0b trackers=%b",
                         $time, dut.gen_rn[0].u_rn_f.wdat_valid,
                         dut.gen_rn[1].u_rn_f.wdat_valid,
                         dut.gen_hn[0].u_hn_f.wr_tracker_active_valid_vec);
            // Open the two DAT links in turn, a few cycles each, so the
            // bursts interleave whatever the fabric arbitration state is.
            t = 0;
            while ((mw_active_max >= 2) && (t < 64) &&
                   (dut.gen_rn[0].u_rn_f.wdat_valid ||
                    dut.gen_rn[1].u_rn_f.wdat_valid)) begin
                @(negedge clk);
                if (t % 2) begin
                    release dut.gen_rn[1].u_rn_f.tx_dat_link_valid;
                    release dut.gen_rn[1].u_rn_f.wdat_engine_ready;
                end else begin
                    release dut.gen_rn[0].u_rn_f.tx_dat_link_valid;
                    release dut.gen_rn[0].u_rn_f.wdat_engine_ready;
                end
                wait_cycles(3);
                @(negedge clk);
                if (t % 2) begin
                    force dut.gen_rn[1].u_rn_f.tx_dat_link_valid = 1'b0;
                    force dut.gen_rn[1].u_rn_f.wdat_engine_ready = 1'b0;
                end else begin
                    force dut.gen_rn[0].u_rn_f.tx_dat_link_valid = 1'b0;
                    force dut.gen_rn[0].u_rn_f.wdat_engine_ready = 1'b0;
                end
                t = t + 1;
            end
            @(negedge clk);
            release dut.gen_rn[0].u_rn_f.tx_dat_link_valid;
            release dut.gen_rn[0].u_rn_f.wdat_engine_ready;
            release dut.gen_rn[1].u_rn_f.tx_dat_link_valid;
            release dut.gen_rn[1].u_rn_f.wdat_engine_ready;
            if (mw_active_max < 2) begin
                $display("[%0t] TEST STEP  %0s task=%0s most write trackers active at once=%0d",
                         $time, current_test_id, current_task_name, mw_active_max);
                tb_fail("HN did not start a second write while the first was outstanding");
                return;
            end
            a1_wait_resp(0, 2'd1, MAX_WAIT, seen0);
            a1_wait_resp(1, 2'd1, MAX_WAIT, seen1);
            if (!seen0 || !seen1) begin
                tb_fail("A WriteUnique did not complete");
                return;
            end
            wait_axi_write_quiet(64);
            if (test_failed) return;
            allow_cpu_write_extra_axi = 1'b0;
            for (b = 0; b < BEATS; b = b + 1) begin
                exp_word = (b == 0) ? MW_DATA0 : base_mem_pattern(MW_ADDR0, b);
                if (mem_pattern(MW_ADDR0, b) !== exp_word) begin
                    $display("[%0t] TEST STEP  %0s task=%0s line0 beat=%0d exp=0x%08h got=0x%08h",
                             $time, current_test_id, current_task_name, b,
                             exp_word, mem_pattern(MW_ADDR0, b));
                    tb_fail("RN0 line corrupted by the interleaved write");
                    return;
                end
                exp_word = (b == 0) ? MW_DATA1 : base_mem_pattern(MW_ADDR1, b);
                if (mem_pattern(MW_ADDR1, b) !== exp_word) begin
                    $display("[%0t] TEST STEP  %0s task=%0s line1 beat=%0d exp=0x%08h got=0x%08h",
                             $time, current_test_id, current_task_name, b,
                             exp_word, mem_pattern(MW_ADDR1, b));
                    tb_fail("RN1 line corrupted by the interleaved write");
                    return;
                end
            end
            $display("[%0t] TEST STEP  %0s write trackers active at once=%0d interleaved beats at SN=%0d",
                     $time, current_test_id, mw_active_max,
                     mw_interleave_count - il_before);
            if (mw_interleave_count == il_before) begin
                tb_fail("The two WriteData bursts did not interleave at the SN");
                return;
            end
            tb_test_pass("Two writes outstanding; interleaved WriteData reached the right lines");
        end
    endtask

    // 2.5: both RNs LDREX the same line (ReadShared(Excl), both SC), then
    // both STREX it at once (CleanUnique(Excl)). The home serializes the
    // two: the first one passes and ends the other's reservation, so
    // exactly one STREX succeeds, and a later read by the loser returns the
    // winner's data.
    task automatic exclusive_strex_race_check;
        integer t;
        reg seen0;
        reg seen1;
        reg ok0;
        reg ok1;
        begin
            tb_test_start("T54_EXCLUSIVE_STREX_RACE",
                          "exclusive_strex_race_check",
                          "Two RNs LDREX one line and STREX it together; exactly one succeeds and its data is what both then read");
            cpu_read_check_rn(0, XR_ADDR, `CHI_CPU_OP_LDREX,
                              mem_pattern(XR_ADDR, 0), "RN0 LDREX");
            if (test_failed) return;
            cpu_read_check_rn(1, XR_ADDR, `CHI_CPU_OP_LDREX,
                              mem_pattern(XR_ADDR, 0), "RN1 LDREX");
            if (test_failed) return;
            // The home sets a reservation when the read's CompAck arrives.
            t = 0;
            while (((dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1) ||
                    (dut.gen_hn[0].u_hn_f.excl_valid_q[1] !== 1'b1)) &&
                   (t < 200)) begin
                t = t + 1;
                @(posedge clk);
            end
            if ((dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1) ||
                (dut.gen_hn[0].u_hn_f.excl_valid_q[1] !== 1'b1)) begin
                tb_fail("Both LDREX must leave a home reservation (ReadShared(Excl) keeps both copies)");
                return;
            end
            allow_cpu_write_extra_axi = 1'b1;
            fork
                a1_issue(0, XR_ADDR, `CHI_CPU_OP_STREX, XR_DATA0, 2'd1);
                a1_issue(1, XR_ADDR, `CHI_CPU_OP_STREX, XR_DATA1, 2'd1);
            join
            a1_wait_resp(0, 2'd1, MAX_WAIT, seen0);
            a1_wait_resp(1, 2'd1, MAX_WAIT, seen1);
            if (!seen0 || !seen1) begin
                tb_fail("A STREX did not complete");
                return;
            end
            ok0 = a1_resp_data[0][1][0];
            ok1 = a1_resp_data[1][1][0];
            $display("[%0t] TEST STEP  %0s task=%0s STREX results rn0=%0d rn1=%0d",
                     $time, current_test_id, current_task_name, ok0, ok1);
            if (ok0 == ok1) begin
                tb_fail("Exactly one of the racing STREX must succeed");
                return;
            end
            cpu_read_check_rn(ok0 ? 1 : 0, XR_ADDR, `CHI_CPU_OP_RD_SHARED,
                              ok0 ? XR_DATA0 : XR_DATA1,
                              "Loser reads the winner's STREX data");
            if (test_failed) return;
            wait_axi_write_quiet(64);
            allow_cpu_write_extra_axi = 1'b0;
            if (test_failed) return;
            tb_test_pass("One STREX won, the other failed, and the winner's data is coherent");
        end
    endtask

    // A1: CPU WriteBackFull from the owner is a CopyBack of the merged line
    // and leaves the line invalid; from a non-owner it is a WriteUnique of
    // the CPU bytes only.
    task automatic a1_writeback_owner_check;
        integer aw_before;
        begin
            tb_test_start("T48_A1_WRITEBACK_OWNER_ONLY",
                          "a1_writeback_owner_check",
                          "Owner WriteBackFull copies back the merged line and ends in I; non-owner WriteBackFull is sent as WriteUnique");

            rn_make_dirty(0, A1_WB_ADDR, A1_DATA0, "RN0 dirty word 0");
            if (test_failed) return;
            wait_axi_write_quiet(64);
            if (test_failed) return;
            aw_before = axi_aw_count;
            cpu_op_resp_check_rn(0, A1_WB_ADDR + 4, `CHI_CPU_OP_WB_FULL,
                                 A1_DATA1, "RN0 owner WriteBackFull word 1");
            if (test_failed) return;
            wait_axi_write_quiet(64);
            if (test_failed) return;
            if (a1_last_req_op[0] != `CHI_REQ_WB_FULL) begin
                tb_fail("Owner WriteBackFull did not go out as WriteBackFull");
                return;
            end
            if (axi_aw_count != (aw_before + 1)) begin
                tb_fail("Owner WriteBackFull expected one AXI AW");
                return;
            end
            if ((mem_pattern(A1_WB_ADDR, 0) !== A1_DATA0) ||
                (mem_pattern(A1_WB_ADDR, 1) !== A1_DATA1) ||
                (mem_pattern(A1_WB_ADDR, 2) !== base_mem_pattern(A1_WB_ADDR, 2))) begin
                tb_fail("Owner WriteBackFull did not write the merged line");
                return;
            end
            rn_cache_expect_state(0, A1_WB_ADDR, 1'b0, `CHI_STATE_I,
                                  "RN0 invalid after WriteBackFull");
            if (test_failed) return;

            cpu_op_resp_check_rn(1, A1_WB_ADDR + 8, `CHI_CPU_OP_WB_FULL,
                                 A1_DATA1, "RN1 non-owner WriteBackFull word 2");
            if (test_failed) return;
            wait_axi_write_quiet(64);
            if (test_failed) return;
            if (a1_last_req_op[1] != `CHI_REQ_WR_UNIQUE) begin
                tb_fail("Non-owner WriteBackFull was not sent as WriteUnique");
                return;
            end
            if ((mem_pattern(A1_WB_ADDR, 0) !== A1_DATA0) ||
                (mem_pattern(A1_WB_ADDR, 2) !== A1_DATA1)) begin
                tb_fail("Non-owner write lost bytes of the line");
                return;
            end

            tb_test_pass("Owner copied back the merged line and went to I; non-owner wrote only its bytes");
        end
    endtask

    // HN: dirty data returned by a snoop must not be lost. A partial
    // WriteUnique from RN1 snoops the dirty owner RN0; RN0's other bytes
    // must survive the write.
    task automatic a1_dirty_partial_write_check;
        begin
            tb_test_start("T49_A1_DIRTY_SNOOP_PARTIAL_WRITE",
                          "a1_dirty_partial_write_check",
                          "Partial WriteUnique over a dirty line owned by another RN keeps the owner's bytes");

            rn_make_dirty(0, A1_PTL_ADDR, A1_DATA0, "RN0 dirty word 0");
            if (test_failed) return;
            cpu_op_resp_check_rn(1, A1_PTL_ADDR + 4, `CHI_CPU_OP_WR_UNIQUE,
                                 A1_DATA1, "RN1 partial write word 1");
            if (test_failed) return;
            rn_cache_expect_state(0, A1_PTL_ADDR, 1'b0, `CHI_STATE_I,
                                  "RN0 invalidated by RN1 write");
            if (test_failed) return;
            cpu_read_check_rn(1, A1_PTL_ADDR, `CHI_CPU_OP_RD_SHARED,
                              A1_DATA0, "RN1 reads RN0 dirty word 0");
            if (test_failed) return;
            cpu_read_check_rn(1, A1_PTL_ADDR + 4, `CHI_CPU_OP_RD_SHARED,
                              A1_DATA1, "RN1 reads its own word 1");
            if (test_failed) return;

            tb_test_pass("Owner's dirty bytes and the partial write both reached memory");
        end
    endtask

    // HN: RN1 ReadUnique takes a dirty line from RN0 as UC. When RN1 then
    // drops it silently (Evict of a clean line) and the LLC copy is gone,
    // the dirty data must already be in memory.
    task automatic a1_dirty_read_unique_check;
        reg found;
        integer k;
        reg [ADDR_WIDTH-1:0] filler;
        begin
            tb_test_start("T50_A1_DIRTY_SNOOP_READ_UNIQUE",
                          "a1_dirty_read_unique_check",
                          "Dirty data passed to a ReadUnique requester survives its silent Evict and LLC eviction");

            rn_make_dirty(0, A1_RU_ADDR, A1_DATA0, "RN0 dirty word 0");
            if (test_failed) return;
            cpu_read_check_rn(1, A1_RU_ADDR, `CHI_CPU_OP_RD_UNIQUE,
                              A1_DATA0, "RN1 ReadUnique gets dirty data");
            if (test_failed) return;
            rn_drop_line(1, A1_RU_ADDR);
            if (test_failed) return;

            // Push the line out of the LLC with reads to the same LLC set
            // (addr[9:6]); RN1 drops each filler again.
            k = 1;
            llc_line_present(A1_RU_ADDR, found);
            while (found && (k < 12)) begin
                filler = A1_RU_ADDR + (k * 32'h400);
                cpu_read_check_rn(1, filler, `CHI_CPU_OP_RD_SHARED,
                                  mem_pattern(filler, 0), "RN1 LLC filler read");
                if (test_failed) return;
                rn_drop_line(1, filler);
                if (test_failed) return;
                wait_cycles(10);
                llc_line_present(A1_RU_ADDR, found);
                k = k + 1;
            end
            if (found) begin
                tb_fail("precondition: line did not leave the LLC");
                return;
            end
            wait_axi_write_quiet(64);
            if (test_failed) return;

            cpu_read_check_rn(0, A1_RU_ADDR, `CHI_CPU_OP_RD_SHARED,
                              A1_DATA0, "RN0 re-read after LLC eviction");
            if (test_failed) return;

            tb_test_pass("Dirty data reached memory before its last cached copy disappeared");
        end
    endtask

    task automatic llc_line_present;
        input [ADDR_WIDTH-1:0] addr;
        output reg found;
        reg [LLC_SET_W-1:0] set;
        reg [LLC_TAG_W-1:0] tag;
        begin
            set = llc_set(addr);
            tag = llc_tag(addr);
            found =
                (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].valid_mem[set] &&
                 (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[0].meta_mem[set][3 +: LLC_TAG_W] == tag)) ||
                (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].valid_mem[set] &&
                 (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[1].meta_mem[set][3 +: LLC_TAG_W] == tag)) ||
                (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].valid_mem[set] &&
                 (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[2].meta_mem[set][3 +: LLC_TAG_W] == tag)) ||
                (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].valid_mem[set] &&
                 (dut.gen_hn[0].u_hn_f.u_llc.gen_way_ram[3].meta_mem[set][3 +: LLC_TAG_W] == tag));
        end
    endtask

    function automatic [LINE_WIDTH-1:0] p0_llc_line;
        integer beat;
        begin
            p0_llc_line = {LINE_WIDTH{1'b0}};
            for (beat = 0; beat < BEATS; beat = beat + 1)
                p0_llc_line[beat*DATA_WIDTH +: DATA_WIDTH] =
                    P0_LLC_DATA + beat;
        end
    endfunction

    // P0-2: a write must not leave an older copy of the line in the LLC.
    // With the internal RN cache the HN records the writer as the SF owner,
    // so a later read snoops the writer and never looks at the LLC. The LLC
    // is only consulted once the writer has lost the line, so RN1 drops it by
    // capacity eviction (WriteBackFull). The SF still names RN1, the snoop
    // misses, the read replays and then looks up the LLC.
    task automatic p0_llc_stale_after_write_check;
        reg found;
        reg [2:0] state;
        integer way;
        integer k;
        reg [ADDR_WIDTH-1:0] filler;
        begin
            tb_test_start("T46_P0_LLC_STALE_AFTER_WRITE",
                          "p0_llc_stale_after_write_check",
                          "RN0 fills the LLC, RN1 writes the line and evicts it, RN0 re-read must see RN1 data, not the LLC copy");

            cpu_read_check_rn(0, P0_LLC_ADDR, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(P0_LLC_ADDR, 0),
                              "RN0 ReadShared fills LLC");
            if (test_failed) return;

            found = 1'b0;
            repeat (64) begin
                if (!found) begin
                    @(posedge clk);
                    llc_line_present(P0_LLC_ADDR, found);
                end
            end
            if (!found) begin
                tb_fail("precondition: RN0 read miss did not fill the LLC");
                return;
            end

            // Full-line WriteUnique so RN1's own copy is complete (P0-4
            // leaves a partial write's other bytes at zero in the RN cache).
            @(negedge clk);
            cpu_wdata_line[1*64*8 +: 64*8] = p0_llc_line();
            cpu_wstrb_line[1*64 +: 64] = {64{1'b1}};
            cpu_op_resp_check_rn(1, P0_LLC_ADDR, `CHI_CPU_OP_WR_UNIQUE,
                                 P0_LLC_DATA, "RN1 full-line WriteUnique");
            @(negedge clk);
            cpu_wdata_line[1*64*8 +: 64*8] = {64*8{1'b0}};
            cpu_wstrb_line[1*64 +: 64] = {64{1'b0}};
            if (test_failed) return;
            wait_axi_write_quiet(64);
            if (test_failed) return;
            for (k = 0; k < BEATS; k = k + 1) begin
                if (mem_pattern(P0_LLC_ADDR, k) !== (P0_LLC_DATA + k)) begin
                    tb_fail("RN1 full-line WriteUnique did not reach memory");
                    return;
                end
            end

            rn_cache_expect_state(0, P0_LLC_ADDR, 1'b0, `CHI_STATE_I,
                                  "RN0 invalidated by RN1 WriteUnique");
            if (test_failed) return;
            llc_line_present(P0_LLC_ADDR, found);
            $display("[%0t] TEST STEP  %0s task=%0s LLC holds line after write=%0b",
                     $time, current_test_id, current_task_name, found);

            // Same RN-cache set (addr[6]), different LLC sets.
            k = 1;
            rn_cache_lookup(1, P0_LLC_ADDR, found, state, way);
            while (found && (k < 8)) begin
                filler = P0_LLC_ADDR + (k * 32'h80);
                cpu_read_check_rn(1, filler, `CHI_CPU_OP_RD_SHARED,
                                  mem_pattern(filler, 0),
                                  "RN1 filler read");
                if (test_failed) return;
                wait_cycles(10);
                rn_cache_lookup(1, P0_LLC_ADDR, found, state, way);
                k = k + 1;
            end
            if (found) begin
                tb_fail("precondition: RN1 did not evict the written line");
                return;
            end
            wait_axi_write_quiet(64);
            if (test_failed) return;
            llc_line_present(P0_LLC_ADDR, found);
            $display("[%0t] TEST STEP  %0s task=%0s LLC holds line after RN1 evict=%0b",
                     $time, current_test_id, current_task_name, found);

            cpu_read_check_rn(0, P0_LLC_ADDR, `CHI_CPU_OP_RD_SHARED,
                              P0_LLC_DATA,
                              "RN0 re-read sees RN1 write");
            if (test_failed) return;

            tb_test_pass("Read after write+evict returned the written line, not the older LLC copy");
        end
    endtask

    // HN must give its SN requests distinct TxnIDs: hold BRESP so a HN->SN
    // write stays outstanding while another RN's read miss goes to the SN.
    // The SN TxnID monitor fails the test on any reuse.
    task automatic sn_txnid_unique_read_during_write_check;
        integer aw_before;
        begin
            tb_test_start("T43_SN_TXNID_UNIQUE_READ_DURING_WRITE",
                          "sn_txnid_unique_read_during_write_check",
                          "HN->SN read and write outstanding together must use different TxnIDs");
            axi_b_hold = 1'b1;
            axi_b_hold_addr_en = 1'b1;
            axi_b_hold_addr = SNTXN_WR_ADDR;
            aw_before = axi_aw_count;
            // Dirty lines left by earlier tests may be back-invalidated and
            // written back first, so allow extra AXI writes and wait for the
            // AW of this write.
            allow_cpu_write_extra_axi = 1'b1;
            fork
                cpu_write_check_rn(0, SNTXN_WR_ADDR, `CHI_CPU_OP_WB_FULL,
                                   SNTXN_WR_DATA,
                                   "WriteBackFull held at BRESP");
                begin
                    // The write is outstanding at the SN once its AW is out
                    // and BRESP is held.
                    wait ((axi_aw_count > aw_before) &&
                          (wr_addr_q == SNTXN_WR_ADDR));
                    wait_cycles(4);
                    fork
                        cpu_read_check_rn(1, SNTXN_RD_ADDR, `CHI_CPU_OP_RD_SHARED,
                                          mem_pattern(SNTXN_RD_ADDR, 0),
                                          "ReadShared miss while the write is outstanding");
                        begin
                            wait_cycles(400);
                            axi_b_hold = 1'b0;
                        end
                    join
                end
            join
            axi_b_hold = 1'b0;
            axi_b_hold_addr_en = 1'b0;
            allow_cpu_write_extra_axi = 1'b0;
            if (test_failed) return;
            tb_test_pass("HN->SN read and write used distinct TxnIDs while both were outstanding");
        end
    endtask

    // P0-3: a dirty LLC victim writeback must not be spliced into a HN->SN
    // write burst that is already in flight. RN0's WriteBackFull is stalled
    // on AXI W after stall_beat beats; RN1's read miss then refills the LLC
    // and evicts the dirty victim. The AXI W checker fails on any splice.
    task automatic p0_evict_write_burst_case;
        input integer stall_beat;
        input integer stall_cycles;
        input integer read_delay;
        input [ADDR_WIDTH-1:0] wr_addr;
        input [DATA_WIDTH-1:0] wr_data;
        input [ADDR_WIDTH-1:0] trig_addr;
        integer aw_before;
        integer b;
        reg [DATA_WIDTH-1:0] exp_word;
        reg [DATA_WIDTH-1:0] got_word;
        begin
            wait_axi_write_quiet(64);
            if (test_failed) return;
            llc_backdoor_seed_dirty_victim();
            if (test_failed) return;

            aw_before = axi_aw_count;
            allow_cpu_write_extra_axi = 1'b1;
            axi_w_hold_beat = stall_beat;
            axi_w_hold = 1'b1;
            fork
                cpu_write_check_rn(0, wr_addr, `CHI_CPU_OP_WB_FULL, wr_data,
                                   "WriteBackFull stalled mid-burst on AXI W");
                begin
                    wait ((axi_aw_count > aw_before) &&
                          (wr_beat_count_q >= stall_beat));
                    wait_cycles(read_delay);
                    fork
                        cpu_read_check_rn(1, trig_addr, `CHI_CPU_OP_RD_SHARED,
                                          mem_pattern(trig_addr, 0),
                                          "Read miss whose refill evicts the dirty victim");
                        begin
                            wait_cycles(stall_cycles);
                            axi_w_hold = 1'b0;
                        end
                    join
                end
            join
            axi_w_hold = 1'b0;
            allow_cpu_write_extra_axi = 1'b0;
            if (test_failed) return;

            wait_axi_write_quiet(64);
            if (test_failed) return;

            for (b = 0; b < BEATS; b = b + 1) begin
                exp_word = (b == 0) ? wr_data : base_mem_pattern(wr_addr, b);
                got_word = mem_pattern(wr_addr, b);
                if (got_word !== exp_word) begin
                    $display("[%0t] TEST STEP  %0s task=%0s write line beat=%0d exp=0x%08h got=0x%08h",
                             $time, current_test_id, current_task_name,
                             b, exp_word, got_word);
                    tb_fail("WriteBackFull line corrupted by concurrent LLC eviction");
                    return;
                end
                got_word = mem_pattern(EVICT_DIRTY_ADDR0, b);
                if (got_word !== dirty_evict_word(b)) begin
                    $display("[%0t] TEST STEP  %0s task=%0s victim line beat=%0d exp=0x%08h got=0x%08h",
                             $time, current_test_id, current_task_name,
                             b, dirty_evict_word(b), got_word);
                    tb_fail("Dirty LLC victim corrupted by concurrent WriteBackFull");
                    return;
                end
            end
        end
    endtask

    // P0-3, queued variant: RN1's read miss is held at AXI R while RN0's
    // WriteBackFull waits behind it at HN. Releasing R retires the read and
    // starts the write while the refill's dirty eviction is still pending,
    // so the victim burst and the write burst race for the SN.
    task automatic p0_evict_queued_write_case;
        input integer queue_cycles;
        input [ADDR_WIDTH-1:0] wr_addr;
        input [DATA_WIDTH-1:0] wr_data;
        input [ADDR_WIDTH-1:0] trig_addr;
        integer ar_before;
        integer b;
        reg [DATA_WIDTH-1:0] exp_word;
        reg [DATA_WIDTH-1:0] got_word;
        begin
            wait_axi_write_quiet(64);
            if (test_failed) return;
            llc_backdoor_seed_dirty_victim();
            if (test_failed) return;

            ar_before = axi_ar_count;
            allow_cpu_write_extra_axi = 1'b1;
            axi_r_hold = 1'b1;
            fork
                cpu_read_check_rn(1, trig_addr, `CHI_CPU_OP_RD_SHARED,
                                  mem_pattern(trig_addr, 0),
                                  "Read miss held at AXI R");
                begin
                    wait (axi_ar_count > ar_before);
                    fork
                        cpu_write_check_rn(0, wr_addr, `CHI_CPU_OP_WB_FULL, wr_data,
                                           "WriteBackFull queued behind the refill read");
                        begin
                            wait_cycles(queue_cycles);
                            axi_r_hold = 1'b0;
                        end
                    join
                end
            join
            axi_r_hold = 1'b0;
            allow_cpu_write_extra_axi = 1'b0;
            if (test_failed) return;

            wait_axi_write_quiet(64);
            if (test_failed) return;

            for (b = 0; b < BEATS; b = b + 1) begin
                exp_word = (b == 0) ? wr_data : base_mem_pattern(wr_addr, b);
                got_word = mem_pattern(wr_addr, b);
                if (got_word !== exp_word) begin
                    $display("[%0t] TEST STEP  %0s task=%0s write line beat=%0d exp=0x%08h got=0x%08h",
                             $time, current_test_id, current_task_name,
                             b, exp_word, got_word);
                    tb_fail("Queued WriteBackFull line corrupted by LLC eviction");
                    return;
                end
                got_word = mem_pattern(EVICT_DIRTY_ADDR0, b);
                if (got_word !== dirty_evict_word(b)) begin
                    $display("[%0t] TEST STEP  %0s task=%0s victim line beat=%0d exp=0x%08h got=0x%08h",
                             $time, current_test_id, current_task_name,
                             b, dirty_evict_word(b), got_word);
                    tb_fail("Dirty LLC victim corrupted by queued WriteBackFull");
                    return;
                end
            end
        end
    endtask

    task automatic p0_evict_during_write_burst_check;
        integer sb;
        integer sc;
        integer rd;
        integer n;
        integer windows_before;
        begin
            tb_test_start("T44_P0_EVICT_DURING_WRITE_BURST",
                          "p0_evict_during_write_burst_check",
                          "Dirty LLC victim evicted while a WriteBackFull burst is stalled on AXI W; both lines must reach AXI intact");
            windows_before = p03_window_count;
            n = 0;
            // Sweep where the write stalls, how long, and when the refill
            // read starts. Each case uses fresh lines: the write in LLC set
            // 0, the trigger read in the seeded victim set.
            for (sb = 1; sb < BEATS; sb = sb + P0_EVW_BEAT_STEP) begin
                for (sc = 0; sc <= P0_EVW_STALL_CYCLES; sc = sc + P0_EVW_CYCLE_STEP) begin
                    for (rd = 0; rd <= 24; rd = rd + 8) begin
                        p0_evict_write_burst_case(sb, sc, rd,
                                                  P0_EVW_ADDR + (n * 32'h400),
                                                  P0_EVW_DATA + n,
                                                  EVICT_TRIGGER_ADDR + ((n + 1) * 32'h1_0000));
                        if (test_failed) begin
                            $display("[%0t] TEST STEP  %0s failing case stall_beat=%0d stall_cycles=%0d read_delay=%0d",
                                     $time, current_test_id, sb, sc, rd);
                            return;
                        end
                        n = n + 1;
                    end
                end
            end
            for (rd = 4; rd <= 64; rd = rd + 12) begin
                p0_evict_queued_write_case(rd,
                                           P0_EVW_ADDR + (n * 32'h400),
                                           P0_EVW_DATA + n,
                                           EVICT_TRIGGER_ADDR + ((n + 1) * 32'h1_0000));
                if (test_failed) begin
                    $display("[%0t] TEST STEP  %0s failing queued case queue_cycles=%0d",
                             $time, current_test_id, rd);
                    return;
                end
                n = n + 1;
            end
            $display("[%0t] TEST STEP  %0s cases=%0d evict_captured_while_write_active=%0d mid_burst=%0d",
                     $time, current_test_id, n, p03_window_count - windows_before,
                     p03_midburst_count);
            tb_test_pass("LLC eviction during an in-flight write burst; both lines intact in every case");
        end
    endtask

    task automatic dual_core_dirty_snoop_invalidate_check;
        integer ar_before;
        begin
            tb_test_start("T25_DUAL_CORE_DIRTY_SNOOP_SHARED_UNIQUE",
                          "dual_core_dirty_snoop_invalidate_check",
                          "RN0 dirty owner must supply RN1 ReadShared data and be invalidated by RN1 ReadUnique");

            rn_make_dirty(0,
                          DUAL_DIRTY_SNOOP_ADDR,
                          DUAL_DIRTY_DATA0,
                          "RN0 creates dirty owner line");
            if (test_failed) return;

            rn_cache_expect_state(0,
                                  DUAL_DIRTY_SNOOP_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN0 dirty before RN1 ReadShared");
            if (test_failed) return;

            ar_before = axi_ar_count;
            cpu_read_check_rn(1,
                              DUAL_DIRTY_SNOOP_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              DUAL_DIRTY_DATA0,
                              "RN1 ReadShared snoops RN0 dirty data");
            if (test_failed) return;
            if (axi_ar_count != ar_before) begin
                tb_fail("Dirty-owner ReadShared unexpectedly fetched from AXI");
                return;
            end

            rn_cache_expect_state(0,
                                  DUAL_DIRTY_SNOOP_ADDR,
                                  1'b1,
                                  `CHI_STATE_SD,
                                  "RN0 downgraded after Shared snoop");
            if (test_failed) return;
            rn_cache_expect_state(1,
                                  DUAL_DIRTY_SNOOP_ADDR,
                                  1'b1,
                                  `CHI_STATE_SC,
                                  "RN1 shared fill after Shared snoop");
            if (test_failed) return;

            rn_make_dirty(0,
                          DUAL_DIRTY_SNOOP_ADDR,
                          DUAL_DIRTY_DATA1,
                          "RN0 recreates dirty owner before ReadUnique");
            if (test_failed) return;
            rn_cache_expect_state(0,
                                  DUAL_DIRTY_SNOOP_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN0 dirty before RN1 ReadUnique");
            if (test_failed) return;

            ar_before = axi_ar_count;
            cpu_read_check_rn(1,
                              DUAL_DIRTY_SNOOP_ADDR,
                              `CHI_CPU_OP_RD_UNIQUE,
                              DUAL_DIRTY_DATA1,
                              "RN1 ReadUnique snoops and invalidates RN0");
            if (test_failed) return;
            if (axi_ar_count != ar_before) begin
                tb_fail("Dirty-owner ReadUnique unexpectedly fetched from AXI");
                return;
            end

            rn_cache_expect_state(0,
                                  DUAL_DIRTY_SNOOP_ADDR,
                                  1'b0,
                                  `CHI_STATE_I,
                                  "RN0 invalidated by RN1 ReadUnique");
            if (test_failed) return;
            // SnpUniqueFwd passes RN0's dirty line to RN1 (CompData_UD_PD).
            rn_cache_expect_state(1,
                                  DUAL_DIRTY_SNOOP_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN1 owns the dirty line after ReadUnique");
            if (test_failed) return;

            tb_test_pass("Dirty-owner snoop data, Shared downgrade, and Unique invalidation all completed");
        end
    endtask

    task automatic dual_core_direct_snpresp_fwd_check;
        integer ar_before;
        begin
            tb_test_start("T36_DUAL_CORE_SNPRESP_FWD_DIRECT",
                          "dual_core_direct_snpresp_fwd_check",
                          "Dirty RN0 owner must forward ReadShared/ReadUnique data directly to RN1 and report SnpResp_SD_Fwded_SC / SnpResp_I_Fwded_UD_PD to HN");

            rn_make_dirty(0,
                          DIRECT_FWD_ADDR,
                          DIRECT_FWD_DATA0,
                          "RN0 creates dirty owner line for direct ReadShared");
            if (test_failed) return;
            rn_cache_expect_state(0,
                                  DIRECT_FWD_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN0 dirty before direct ReadShared");
            if (test_failed) return;

            direct_fwd_monitor_active = 1'b1;
            direct_fwd_rsp_fwd_count  = 0;
            direct_fwd_dat_count      = 0;
            direct_fwd_hn_dat_count   = 0;
            direct_fwd_hn_snp_data_count = 0;
            wait_cycles(1);

            ar_before = axi_ar_count;
            cpu_read_check_rn(1,
                              DIRECT_FWD_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              DIRECT_FWD_DATA0,
                              "RN1 ReadShared receives RN0 direct forward");
            if (test_failed) return;
            wait_cycles(1);
            if (axi_ar_count != ar_before) begin
                tb_fail("Direct ReadShared unexpectedly fetched from AXI");
                return;
            end
            if (direct_fwd_rsp_fwd_count == 0) begin
                tb_fail("Direct ReadShared did not observe RN0 SnpRespFwded");
                return;
            end
            if (direct_fwd_dat_count == 0) begin
                tb_fail("Direct ReadShared did not observe RN0-to-RN1 RD_DATA");
                return;
            end
            if (direct_fwd_hn_dat_count != 0) begin
                tb_fail("Direct ReadShared unexpectedly used HN proxy RD_DATA");
                return;
            end
            // Table B4.58: RN0 keeps the dirty line (SD) and forwards SC.
            if ((direct_fwd_rsp_resp != `CHI_SNPRESP_SD) ||
                (direct_fwd_rsp_fwd_state != `CHI_COMPDATA_RESP_SC) ||
                (direct_fwd_cd_resp != `CHI_COMPDATA_RESP_SC)) begin
                tb_fail_str($sformatf("Direct ReadShared: SnpRespFwded Resp=%0d FwdState=%0d CompData Resp=%0d, expected SD/SC/SC",
                                  direct_fwd_rsp_resp, direct_fwd_rsp_fwd_state,
                                  direct_fwd_cd_resp));
                return;
            end

            rn_cache_expect_state(0,
                                  DIRECT_FWD_ADDR,
                                  1'b1,
                                  `CHI_STATE_SD,
                                  "RN0 downgraded after direct Shared forward");
            if (test_failed) return;
            rn_cache_expect_state(1,
                                  DIRECT_FWD_ADDR,
                                  1'b1,
                                  `CHI_STATE_SC,
                                  "RN1 shared fill after direct Shared forward");
            if (test_failed) return;

            rn_make_dirty(0,
                          DIRECT_FWD_ADDR,
                          DIRECT_FWD_DATA1,
                          "RN0 recreates dirty owner line for direct ReadUnique");
            if (test_failed) return;
            rn_cache_expect_state(0,
                                  DIRECT_FWD_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN0 dirty before direct ReadUnique");
            if (test_failed) return;

            direct_fwd_rsp_fwd_count  = 0;
            direct_fwd_dat_count      = 0;
            direct_fwd_hn_dat_count   = 0;
            direct_fwd_hn_snp_data_count = 0;
            wait_cycles(1);

            ar_before = axi_ar_count;
            cpu_read_check_rn(1,
                              DIRECT_FWD_ADDR,
                              `CHI_CPU_OP_RD_UNIQUE,
                              DIRECT_FWD_DATA1,
                              "RN1 ReadUnique receives RN0 direct forward");
            if (test_failed) return;
            wait_cycles(1);
            if (axi_ar_count != ar_before) begin
                tb_fail("Direct ReadUnique unexpectedly fetched from AXI");
                return;
            end
            if (direct_fwd_rsp_fwd_count == 0) begin
                tb_fail("Direct ReadUnique did not observe RN0 SnpRespFwded");
                return;
            end
            if (direct_fwd_dat_count == 0) begin
                tb_fail("Direct ReadUnique did not observe RN0-to-RN1 RD_DATA");
                return;
            end
            if (direct_fwd_hn_dat_count != 0) begin
                tb_fail("Direct ReadUnique unexpectedly used HN proxy RD_DATA");
                return;
            end
            // Table B4.59: a dirty line is passed to the requester.
            if ((direct_fwd_rsp_resp != `CHI_COMPDATA_RESP_I) ||
                (direct_fwd_rsp_fwd_state != `CHI_COMPDATA_RESP_UD_PD) ||
                (direct_fwd_cd_resp != `CHI_COMPDATA_RESP_UD_PD)) begin
                tb_fail_str($sformatf("Direct ReadUnique: SnpRespFwded Resp=%0d FwdState=%0d CompData Resp=%0d, expected I/UD_PD/UD_PD",
                                  direct_fwd_rsp_resp, direct_fwd_rsp_fwd_state,
                                  direct_fwd_cd_resp));
                return;
            end

            rn_cache_expect_state(0,
                                  DIRECT_FWD_ADDR,
                                  1'b0,
                                  `CHI_STATE_I,
                                  "RN0 invalidated after direct Unique forward");
            if (test_failed) return;
            rn_cache_expect_state(1,
                                  DIRECT_FWD_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN1 owns the dirty line after direct Unique forward");
            if (test_failed) return;

            direct_fwd_monitor_active = 1'b0;
            tb_test_pass("SnpResp_SD_Fwded_SC and SnpResp_I_Fwded_UD_PD with matching direct CompData for Shared and Unique");
        end
    endtask

    // Checks that RN0 sent nothing to HN0 after its SnpRespFwded.
    task automatic direct_fwd_expect_no_home_data;
        input [320*8-1:0] msg;
        begin
            if (direct_fwd_rsp_fwd_count != 1) begin
                tb_fail_str($sformatf("%0s: %0d SnpRespFwded from RN0, expected 1",
                                  msg, direct_fwd_rsp_fwd_count));
                return;
            end
            if ((direct_fwd_hn_snp_data_count != 0) ||
                (direct_fwd_hn_bad_opcode_count != 0) ||
                (direct_fwd_hn_snp_tracker_accept_count != 0)) begin
                tb_fail_str($sformatf("%0s: RN0 sent %0d SnpRespData and %0d other DAT beats to HN after SnpRespFwded",
                                  msg, direct_fwd_hn_snp_data_count,
                                  direct_fwd_hn_bad_opcode_count));
                return;
            end
            if (direct_fwd_dat_count != DAT_BEATS) begin
                tb_fail_str($sformatf("%0s: %0d forwarded CompData beats, expected %0d",
                                  msg, direct_fwd_dat_count, DAT_BEATS));
                return;
            end
        end
    endtask

    task automatic direct_fwd_clear_counts;
        begin
            direct_fwd_rsp_fwd_count  = 0;
            direct_fwd_dat_count      = 0;
            direct_fwd_hn_dat_count   = 0;
            direct_fwd_hn_snp_data_count = 0;
            direct_fwd_hn_bad_opcode_count = 0;
            direct_fwd_hn_snp_tracker_accept_count = 0;
            wait_cycles(1);
        end
    endtask

    task automatic dual_core_snpresp_fwd_no_home_copy_check;
        begin
            tb_test_start("T37_DUAL_CORE_SNPRESP_FWD_NO_HOME_COPY",
                          "dual_core_snpresp_fwd_no_home_copy_check",
                          "SnpRespFwded is the whole snoop response: no data follows to HN; the dirty line stays at RN0 (SD) or moves to RN1 (UD_PD)");

            rn_make_dirty(0,
                          DATA_FWD_COPY_ADDR,
                          DATA_FWD_COPY_DATA0,
                          "RN0 creates dirty owner line for ReadShared");
            if (test_failed) return;

            direct_fwd_monitor_active = 1'b1;
            direct_fwd_clear_counts();
            cpu_read_check_rn(1,
                              DATA_FWD_COPY_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              DATA_FWD_COPY_DATA0,
                              "RN1 ReadShared receives RN0 direct forward");
            if (test_failed) return;
            wait_cycles(200);
            direct_fwd_expect_no_home_data("ReadShared");
            if (test_failed) return;
            rn_cache_expect_state(0,
                                  DATA_FWD_COPY_ADDR,
                                  1'b1,
                                  `CHI_STATE_SD,
                                  "RN0 keeps the dirty line after SnpResp_SD_Fwded_SC");
            if (test_failed) return;
            rn_cache_expect_state(1,
                                  DATA_FWD_COPY_ADDR,
                                  1'b1,
                                  `CHI_STATE_SC,
                                  "RN1 shared fill after Shared forward");
            if (test_failed) return;

            rn_make_dirty(0,
                          DATA_FWD_COPY_ADDR,
                          DATA_FWD_COPY_DATA1,
                          "RN0 recreates dirty owner line for ReadUnique");
            if (test_failed) return;

            direct_fwd_clear_counts();
            cpu_read_check_rn(1,
                              DATA_FWD_COPY_ADDR,
                              `CHI_CPU_OP_RD_UNIQUE,
                              DATA_FWD_COPY_DATA1,
                              "RN1 ReadUnique receives RN0 direct forward");
            if (test_failed) return;
            wait_cycles(200);
            direct_fwd_expect_no_home_data("ReadUnique");
            if (test_failed) return;
            rn_cache_expect_state(0,
                                  DATA_FWD_COPY_ADDR,
                                  1'b0,
                                  `CHI_STATE_I,
                                  "RN0 invalidated after SnpResp_I_Fwded_UD_PD");
            if (test_failed) return;
            rn_cache_expect_state(1,
                                  DATA_FWD_COPY_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN1 owns the dirty line after CompData_UD_PD");
            if (test_failed) return;
            direct_fwd_monitor_active = 1'b0;

            // Only RN1 holds the data now: RN0 reads it back from RN1.
            cpu_read_check_rn(0,
                              DATA_FWD_COPY_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              DATA_FWD_COPY_DATA1,
                              "RN0 reads the line RN1 owns dirty");
            if (test_failed) return;
            rn_cache_expect_state(1,
                                  DATA_FWD_COPY_ADDR,
                                  1'b1,
                                  `CHI_STATE_SD,
                                  "RN1 keeps the dirty line after forwarding to RN0");
            if (test_failed) return;

            tb_test_pass("SnpRespFwded closed both forwards without data to HN, and dirty ownership stayed at RN0 (Shared) or moved to RN1 (Unique)");
        end
    endtask

    task automatic dat_opcode_legality_check;
        integer ar_before;
        integer timeout;
        begin
            tb_test_start("T38_DAT_OPCODE_LEGALITY",
                          "dat_opcode_legality_check",
                          "Forwarded direct data must remain RD_DATA, and after SnpRespFwded no snoop data reaches HN");

            rn_make_dirty(0,
                          DAT_OPCODE_LEGALITY_ADDR,
                          DAT_OPCODE_LEGALITY_DATA,
                          "RN0 creates dirty owner line for DAT opcode legality");
            if (test_failed) return;
            rn_cache_expect_state(0,
                                  DAT_OPCODE_LEGALITY_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN0 dirty before DAT opcode legality ReadShared");
            if (test_failed) return;

            direct_fwd_monitor_active = 1'b1;
            direct_fwd_rsp_fwd_count  = 0;
            direct_fwd_dat_count      = 0;
            direct_fwd_hn_dat_count   = 0;
            direct_fwd_hn_snp_data_count = 0;
            direct_fwd_direct_bad_opcode_count = 0;
            direct_fwd_hn_bad_opcode_count = 0;
            direct_fwd_hn_snp_tracker_accept_count = 0;
            direct_fwd_hn_snp_tracker_bad_opcode_count = 0;
            direct_fwd_hn_rd_tracker_bad_accept_count = 0;
            direct_fwd_direct_bad_home_count = 0;
            direct_fwd_direct_legacy_src_count = 0;
            direct_fwd_hn_bad_home_count = 0;
            direct_fwd_compack_to_hn_count = 0;
            direct_fwd_compack_to_owner_count = 0;
            wait_cycles(1);

            ar_before = axi_ar_count;
            cpu_read_check_rn(1,
                              DAT_OPCODE_LEGALITY_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              DAT_OPCODE_LEGALITY_DATA,
                              "RN1 ReadShared exercises DAT opcode legality on the forward");
            if (test_failed) return;
            wait_cycles(200);

            if (axi_ar_count != ar_before) begin
                tb_fail("DAT opcode legality unexpectedly fetched from AXI");
                return;
            end
            if (direct_fwd_rsp_fwd_count == 0) begin
                tb_fail("DAT opcode legality did not observe RN0 SnpRespFwded");
                return;
            end
            if (direct_fwd_dat_count < DAT_BEATS) begin
                tb_fail("DAT opcode legality did not observe full direct RD_DATA stream");
                return;
            end
            if (direct_fwd_hn_snp_data_count != 0) begin
                tb_fail("DAT opcode legality saw RN0-to-HN SNP_DATA after SnpRespFwded");
                return;
            end
            if (direct_fwd_hn_snp_tracker_accept_count != 0) begin
                tb_fail("DAT opcode legality saw HN snoop tracker accept data after SnpRespFwded");
                return;
            end
            if (direct_fwd_hn_dat_count != 0) begin
                tb_fail("DAT opcode legality unexpectedly used HN proxy RD_DATA");
                return;
            end
            if (direct_fwd_direct_bad_opcode_count != 0) begin
                tb_fail("DAT opcode legality saw non-RD_DATA opcode on direct requester stream");
                return;
            end
            if (direct_fwd_hn_bad_opcode_count != 0) begin
                tb_fail("DAT opcode legality saw RN0-to-HN DAT after SnpRespFwded");
                return;
            end
            if (direct_fwd_hn_snp_tracker_bad_opcode_count != 0) begin
                tb_fail("DAT opcode legality saw snoop tracker match a non-SNP_DATA opcode");
                return;
            end
            if (direct_fwd_hn_rd_tracker_bad_accept_count != 0) begin
                tb_fail("DAT opcode legality saw read tracker accept the HN-bound snoop copy");
                return;
            end

            rn_cache_expect_state(0,
                                  DAT_OPCODE_LEGALITY_ADDR,
                                  1'b1,
                                  `CHI_STATE_SD,
                                  "RN0 downgraded after DAT opcode legality Shared forward");
            if (test_failed) return;
            rn_cache_expect_state(1,
                                  DAT_OPCODE_LEGALITY_ADDR,
                                  1'b1,
                                  `CHI_STATE_SC,
                                  "RN1 shared fill after DAT opcode legality Shared forward");
            if (test_failed) return;

            direct_fwd_monitor_active = 1'b0;
            tb_test_pass("DAT opcode legality kept direct RD_DATA and sent no snoop data to HN after SnpRespFwded");
        end
    endtask

    task automatic dct_home_nid_identity_check;
        integer ar_before;
        integer timeout;
        begin
            tb_test_start("T39_DCT_HOME_NID_IDENTITY",
                          "dct_home_nid_identity_check",
                          "Direct DCT DAT must expose owner SrcID while HomeNID drives requester CompAck to HN");

            rn_make_dirty(0,
                          DCT_HOME_NID_ADDR,
                          DCT_HOME_NID_DATA,
                          "RN0 creates dirty owner line for DCT HomeNID identity");
            if (test_failed) return;
            rn_cache_expect_state(0,
                                  DCT_HOME_NID_ADDR,
                                  1'b1,
                                  `CHI_STATE_UD,
                                  "RN0 dirty before DCT HomeNID ReadShared");
            if (test_failed) return;

            direct_fwd_monitor_active = 1'b1;
            direct_fwd_rsp_fwd_count  = 0;
            direct_fwd_dat_count      = 0;
            direct_fwd_hn_dat_count   = 0;
            direct_fwd_hn_snp_data_count = 0;
            direct_fwd_direct_bad_opcode_count = 0;
            direct_fwd_hn_bad_opcode_count = 0;
            direct_fwd_hn_snp_tracker_accept_count = 0;
            direct_fwd_hn_snp_tracker_bad_opcode_count = 0;
            direct_fwd_hn_rd_tracker_bad_accept_count = 0;
            direct_fwd_direct_bad_home_count = 0;
            direct_fwd_direct_legacy_src_count = 0;
            direct_fwd_hn_bad_home_count = 0;
            direct_fwd_compack_to_hn_count = 0;
            direct_fwd_compack_to_owner_count = 0;
            wait_cycles(1);

            ar_before = axi_ar_count;
            cpu_read_check_rn(1,
                              DCT_HOME_NID_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              DCT_HOME_NID_DATA,
                              "RN1 ReadShared receives DCT data with true SrcID and HomeNID");
            if (test_failed) return;

            timeout = 0;
            while ((direct_fwd_compack_to_hn_count == 0) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end

            if (axi_ar_count != ar_before) begin
                tb_fail("DCT HomeNID identity unexpectedly fetched from AXI");
                return;
            end
            if (direct_fwd_rsp_fwd_count == 0) begin
                tb_fail("DCT HomeNID identity did not observe RN0 SnpRespFwded");
                return;
            end
            if (direct_fwd_dat_count < DAT_BEATS) begin
                tb_fail("DCT HomeNID identity did not observe full direct RN0-to-RN1 RD_DATA stream");
                return;
            end
            if (direct_fwd_direct_legacy_src_count != 0) begin
                tb_fail("DCT HomeNID identity saw legacy direct DAT SrcID=HN");
                return;
            end
            if (direct_fwd_direct_bad_home_count != 0) begin
                tb_fail("DCT HomeNID identity saw direct DAT with wrong HomeNID");
                return;
            end
            if (direct_fwd_hn_snp_data_count != 0) begin
                tb_fail("DCT HomeNID identity saw HN-bound SNP_DATA after SnpRespFwded");
                return;
            end
            if (direct_fwd_hn_bad_home_count != 0) begin
                tb_fail("DCT HomeNID identity saw HN-bound SNP_DATA with wrong HomeNID");
                return;
            end
            if (direct_fwd_compack_to_hn_count == 0) begin
                tb_fail("DCT HomeNID identity did not observe requester CompAck to HN");
                return;
            end
            if (direct_fwd_compack_to_owner_count != 0) begin
                tb_fail("DCT HomeNID identity saw requester CompAck sent to owner RN");
                return;
            end

            rn_cache_expect_state(0,
                                  DCT_HOME_NID_ADDR,
                                  1'b1,
                                  `CHI_STATE_SD,
                                  "RN0 downgraded after DCT HomeNID Shared forward");
            if (test_failed) return;
            rn_cache_expect_state(1,
                                  DCT_HOME_NID_ADDR,
                                  1'b1,
                                  `CHI_STATE_SC,
                                  "RN1 shared fill after DCT HomeNID Shared forward");
            if (test_failed) return;

            direct_fwd_monitor_active = 1'b0;
            tb_test_pass("DCT DAT SrcID and HomeNID identity matched Issue-H-style completion routing");
        end
    endtask

    task automatic dual_core_dvm_broadcast_check;
        integer timeout;
        begin
            tb_test_start("T26_DUAL_CORE_DVM_BROADCAST_BOTH_RN",
                          "dual_core_dvm_broadcast_check",
                          "DVMOp from RN0 clears RN0's reservation on issue and RN1's through its SnpDVMOp");

            cpu_read_check_rn(0,
                              DUAL_DVM_ADDR0,
                              `CHI_CPU_OP_LDREX,
                              mem_pattern(DUAL_DVM_ADDR0, 0),
                              "RN0 LDREX before DVM");
            if (test_failed) return;
            cpu_read_check_rn(1,
                              DUAL_DVM_ADDR1,
                              `CHI_CPU_OP_LDREX,
                              mem_pattern(DUAL_DVM_ADDR1, 0),
                              "RN1 LDREX before DVM");
            if (test_failed) return;

            timeout = 0;
            while (((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) ||
                    (dut.gen_rn[1].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) begin
                tb_fail("RN0 local reservation not set before DVM");
                return;
            end
            if (dut.gen_rn[1].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) begin
                tb_fail("RN1 local reservation not set before DVM");
                return;
            end

            cpu_op_resp_check_rn(0,
                                 DUAL_DVM_ADDR0,
                                 `CHI_CPU_OP_DVM_OP,
                                 {DATA_WIDTH{1'b0}},
                                 "RN0 DVM_OP broadcast");
            if (test_failed) return;

            timeout = 0;
            while (((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) ||
                    (dut.gen_rn[1].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) begin
                tb_fail("DVM did not clear RN0 local reservation");
                return;
            end
            if (dut.gen_rn[1].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) begin
                tb_fail("DVM did not clear RN1 local reservation");
                return;
            end

            tb_test_pass("DVMOp cleared the requester's reservation and, by SnpDVMOp, the other RN's");
        end
    endtask

    // 2.7: the DVM flow of B8 at flit level. A non-sync DVMOp and a Sync
    // each get DBIDResp, one NonCopyBackWriteData payload beat, one
    // two-part SnpDVMOp to the other RN only, its SnpResp and one Comp.
    task automatic dvm_b8_flow_check;
        reg [`CHI_REQ_ADDR_W-1:0] a44;
        reg [63:0]                payload;
        reg [`CHI_SNP_ADDR_W-1:0] p1_exp;
        reg [`CHI_SNP_ADDR_W-1:0] p2_exp;
        begin
            tb_test_start("T55_DVM_B8_FLOW",
                          "dvm_b8_flow_check",
                          "DVMOp gets DBIDResp and a payload beat; the MN sends a two-part SnpDVMOp to the other RN only, adds no Sync, then Comp");

            a44 = 44'h0000_1234_5670;
            payload = 64'h0000_0000_CAFE_F00D;
            dvm_mon_clear();
            dvm_mon_on = 1'b1;
            cpu_op_resp_check_rn(0, a44[ADDR_WIDTH-1:0], `CHI_CPU_OP_DVM_OP,
                                 payload[DATA_WIDTH-1:0], "RN0 non-sync DVMOp");
            if (test_failed) return;
            wait_cycles(20);
            // Part 1: SNP.Addr = {Data[46:44], REQ.Addr[40:4], 0};
            // Part 2: SNP.Addr = {Data[43:4], 1}, FwdNID = Num = {Addr[42], Data[3:0]}.
            p1_exp = {payload[46:44], a44[40:4], 1'b0};
            p2_exp = {payload[43:4], 1'b1};
            if ((dvm_mon_dbid != 1) || (dvm_mon_comp != 1)) begin
                tb_fail_str($sformatf("non-sync: MN sent %0d DBIDResp and %0d Comp, expected 1 each",
                                  dvm_mon_dbid, dvm_mon_comp));
                return;
            end
            if ((dvm_mon_dat != 1) || (dvm_mon_dat_op != `CHI_DAT_OPCODE_WB_DATA) ||
                (dvm_mon_dat_be != {{(DAT_DATA_W/8-8){1'b0}}, 8'hFF}) ||
                (dvm_mon_dat_data != payload)) begin
                tb_fail_str($sformatf("non-sync payload: %0d beats op=0x%0h BE=0x%0h data=0x%016h",
                                  dvm_mon_dat, dvm_mon_dat_op, dvm_mon_dat_be, dvm_mon_dat_data));
                return;
            end
            if ((dvm_mon_snp[0] != 0) || (dvm_mon_snp[1] != 2) ||
                (dvm_mon_parts[1] != 2'b11) || (dvm_mon_txn_mismatch != 0)) begin
                tb_fail_str($sformatf("non-sync SnpDVMOp flits RN0=%0d RN1=%0d parts=%02b txn_mismatch=%0d; expected 0, 2 (both parts, one TxnID)",
                                  dvm_mon_snp[0], dvm_mon_snp[1], dvm_mon_parts[1],
                                  dvm_mon_txn_mismatch));
                return;
            end
            if ((dvm_mon_p1_addr[1] != p1_exp) || (dvm_mon_p2_addr[1] != p2_exp) ||
                (dvm_mon_p2_fwd_nid[1][4:0] != {a44[42], payload[3:0]})) begin
                tb_fail_str($sformatf("non-sync payload in SnpDVMOp: P1 Addr=0x%0h exp 0x%0h, P2 Addr=0x%0h exp 0x%0h, P2 FwdNID=0x%0h",
                                  dvm_mon_p1_addr[1], p1_exp, dvm_mon_p2_addr[1], p2_exp,
                                  dvm_mon_p2_fwd_nid[1]));
                return;
            end
            if (dvm_mon_snpresp != 1) begin
                tb_fail_str($sformatf("non-sync: %0d SnpResp at the MN, expected 1", dvm_mon_snpresp));
                return;
            end

            dvm_mon_clear();
            cpu_op_resp_check_rn(1, 32'h0000_0000, `CHI_CPU_OP_DVM_SYNC,
                                 {DATA_WIDTH{1'b0}}, "RN1 DVMOp(Sync)");
            if (test_failed) return;
            wait_cycles(20);
            dvm_mon_on = 1'b0;
            if ((dvm_mon_dbid != 1) || (dvm_mon_comp != 1) || (dvm_mon_dat != 1) ||
                (dvm_mon_snp[0] != 2) || (dvm_mon_snp[1] != 0) ||
                (dvm_mon_parts[0] != 2'b11) || (dvm_mon_snpresp != 1)) begin
                tb_fail_str($sformatf("Sync: DBIDResp=%0d Comp=%0d payload=%0d SnpDVMOp RN0=%0d RN1=%0d parts=%02b SnpResp=%0d",
                                  dvm_mon_dbid, dvm_mon_comp, dvm_mon_dat,
                                  dvm_mon_snp[0], dvm_mon_snp[1], dvm_mon_parts[0],
                                  dvm_mon_snpresp));
                return;
            end
            if (dvm_mon_p1_addr[0][`CHI_DVM_TYPE_LSB-3 +: 3] != `CHI_DVM_TYPE_SYNC) begin
                tb_fail_str($sformatf("Sync SnpDVMOp Part 1 DVMType=%0b",
                                  dvm_mon_p1_addr[0][`CHI_DVM_TYPE_LSB-3 +: 3]));
                return;
            end

            tb_test_pass("DBIDResp, payload beat, two-part SnpDVMOp to the other RN only, no extra Sync, one Comp");
        end
    endtask

    // 2.8: MakeUnique carries ExpCompAck and the RN answers its Comp with
    // CompAck (TxnID = DBID of the Comp, B2.7.2). The home holds the line
    // until then (B5.6.4): with RN0's RSP output held, an RN1 read of the
    // line must not snoop RN0 before the CompAck.
    task automatic mk_unique_compack_check;
        reg seen;
        integer t;
        begin
            tb_test_start("T56_MAKEUNIQUE_COMPACK",
                          "mk_unique_compack_check",
                          "MakeUnique gets CompAck with the Comp's DBID; the home snoops the line again only after it");

            cpu_read_check_rn(1, MU_ADDR, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(MU_ADDR, 0), "RN1 ReadShared makes RN1 a sharer");
            if (test_failed) return;
            wait_cycles(20);

            mu_mon_clear();
            mu_mon_on = 1'b1;
            // Hold RN0's RSP output: valid and ready at the source-to-link
            // boundary, so no flit is lost or sent twice.
            force dut.gen_rn[0].u_rn_f.tx_rsp_link_valid = 1'b0;
            force dut.gen_rn[0].u_rn_f.tx_rsp_link_ready = 1'b0;
            cpu_op_resp_check_rn(0, MU_ADDR, `CHI_CPU_OP_MK_UNIQUE,
                                 {DATA_WIDTH{1'b0}}, "RN0 MakeUnique");
            if (test_failed) begin
                release dut.gen_rn[0].u_rn_f.tx_rsp_link_valid;
                release dut.gen_rn[0].u_rn_f.tx_rsp_link_ready;
                return;
            end
            if ((mu_mon_req != 1) || !mu_mon_exp_ack || (mu_mon_comp != 1) ||
                (mu_mon_snp1 == 0)) begin
                release dut.gen_rn[0].u_rn_f.tx_rsp_link_valid;
                release dut.gen_rn[0].u_rn_f.tx_rsp_link_ready;
                tb_fail_str($sformatf("MakeUnique REQ=%0d ExpCompAck=%0b Comp=%0d snoops to RN1=%0d; expected 1, 1, 1, >0",
                                      mu_mon_req, mu_mon_exp_ack, mu_mon_comp, mu_mon_snp1));
                return;
            end

            a1_issue(1, MU_ADDR, `CHI_CPU_OP_RD_SHARED, {DATA_WIDTH{1'b0}}, 2'd3);
            for (t = 0; t < 300; t = t + 1)
                @(posedge clk);
            if ((mu_mon_snp0 != 0) || a1_resp_seen[1][3]) begin
                release dut.gen_rn[0].u_rn_f.tx_rsp_link_valid;
                release dut.gen_rn[0].u_rn_f.tx_rsp_link_ready;
                tb_fail_str($sformatf("before RN0's CompAck: %0d snoops to RN0, RN1 read done=%0b; the home must hold the line",
                                      mu_mon_snp0, a1_resp_seen[1][3]));
                return;
            end
            release dut.gen_rn[0].u_rn_f.tx_rsp_link_valid;
            release dut.gen_rn[0].u_rn_f.tx_rsp_link_ready;

            a1_wait_resp(1, 2'd3, MAX_WAIT, seen);
            wait_cycles(20);
            mu_mon_on = 1'b0;
            if (!seen) begin
                tb_fail("RN1 read of the MakeUnique line did not complete after the CompAck");
                return;
            end
            if ((mu_mon_ack != 1) || (mu_mon_ack_txn != mu_mon_comp_dbid[TXN_ID_W-1:0])) begin
                tb_fail_str($sformatf("RN0 sent %0d CompAck, TxnID=0x%0h, Comp DBID=0x%0h; expected one with TxnID = DBID",
                                      mu_mon_ack, mu_mon_ack_txn, mu_mon_comp_dbid));
                return;
            end
            if ((mu_mon_snp0 == 0) || (mu_mon_snp0_cycle <= mu_mon_ack_cycle)) begin
                tb_fail_str($sformatf("snoops to RN0=%0d at cycle %0d, CompAck at %0d; RN0 owns the line and must be snooped after its CompAck",
                                      mu_mon_snp0, mu_mon_snp0_cycle, mu_mon_ack_cycle));
                return;
            end
            if (a1_resp_data[1][3] !== mem_pattern(MU_ADDR, 0)) begin
                tb_fail_str($sformatf("RN1 read after MakeUnique got 0x%0h, expected 0x%0h (no one wrote the line)",
                                      a1_resp_data[1][3], mem_pattern(MU_ADDR, 0)));
                return;
            end

            tb_test_pass("MakeUnique CompAck carried the Comp's DBID; RN0 was snooped for the line only after it");
        end
    endtask

    // Number of HN0 snoop-filter entries that list RN rn_idx as a sharer.
    function automatic integer sf_entries_listing_rn;
        input integer rn_idx;
        integer s;
        integer n;
        begin
            n = 0;
            for (s = 0; s < dut.gen_hn[0].u_hn_f.u_snoop_filter.SETS; s = s + 1) begin
                if (dut.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[0].valid_mem[s] &&
                    dut.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[0].meta_mem[s][rn_idx])
                    n = n + 1;
                if (dut.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[1].valid_mem[s] &&
                    dut.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[1].meta_mem[s][rn_idx])
                    n = n + 1;
                if (dut.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[2].valid_mem[s] &&
                    dut.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[2].meta_mem[s][rn_idx])
                    n = n + 1;
                if (dut.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[3].valid_mem[s] &&
                    dut.gen_hn[0].u_hn_f.u_snoop_filter.gen_way_ram[3].meta_mem[s][rn_idx])
                    n = n + 1;
            end
            sf_entries_listing_rn = n;
        end
    endfunction

    // Wait until SYSCOREQ/SYSCOACK of RN rn_idx both read exp in
    // SYSCO_STATUS.
    task automatic sysco_wait_state;
        input integer rn_idx;
        input exp;
        output reg ok;
        reg [63:0] status;
        integer t;
        begin
            ok = 1'b0;
            for (t = 0; (t < MAX_WAIT) && !ok; t = t + 1) begin
                csr_read_value(CSR_SYSCO_STATUS, status);
                ok = (status[rn_idx] === exp) && (status[16 + rn_idx] === exp);
            end
        end
    endtask

    // 3.4: an RN leaves the coherency domain through SYSCO_CTRL. It must
    // flush its cache first (dirty lines reach the home), the home must then
    // neither list nor snoop it, and after it rejoins it is coherent again.
    task automatic sysco_leave_domain_check;
        reg ok;
        reg [63:0] status;
        integer listed;
        integer i;
        begin
            tb_test_start("T57_SYSCO_RN_LEAVES_DOMAIN",
                          "sysco_leave_domain_check",
                          "RN0 flushes and leaves the coherency domain; RN1 uses its lines with no snoop to RN0; RN0 rejoins and is snooped again");

            csr_read_value(CSR_SYSCO_STATUS, status);
            if ((status[NUM_RN-1:0] !== {NUM_RN{1'b1}}) ||
                (status[16 +: NUM_RN] !== {NUM_RN{1'b1}})) begin
                tb_fail_str($sformatf("SYSCO_STATUS=0x%0h after reset; every RN must be in Coherency Enabled",
                                      status));
                return;
            end

            // RN0 holds a dirty line, a clean line of its own and a line it
            // shares with RN1.
            rn_make_dirty(0, SYSCO_DIRTY_ADDR, SYSCO_DATA0, "RN0 dirty line");
            if (test_failed) return;
            cpu_read_check_rn(0, SYSCO_CLEAN_ADDR, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(SYSCO_CLEAN_ADDR, 0), "RN0 clean line");
            if (test_failed) return;
            cpu_read_check_rn(0, SYSCO_SHARED_ADDR, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(SYSCO_SHARED_ADDR, 0), "RN0 shared line");
            if (test_failed) return;
            cpu_read_check_rn(1, SYSCO_SHARED_ADDR, `CHI_CPU_OP_RD_SHARED,
                              mem_pattern(SYSCO_SHARED_ADDR, 0), "RN1 shared line");
            if (test_failed) return;
            wait_cycles(20);
            listed = sf_entries_listing_rn(0);
            if (listed < 3) begin
                tb_fail_str($sformatf("snoop filter lists RN0 in %0d entries before it leaves, expected at least 3",
                                      listed));
                return;
            end

            for (i = 0; i < NUM_RN; i = i + 1) begin
                sysco_mon_snp[i] = 0;
                sysco_mon_listed[i] = 0;
            end
            sysco_mon_on = 1'b1;
            csr_write64(CSR_SYSCO_CTRL, 64'h2);
            sysco_wait_state(0, 1'b0, ok);
            if (!ok) begin
                csr_read_value(CSR_SYSCO_STATUS, status);
                tb_fail_str($sformatf("RN0 did not reach Coherency Disabled, SYSCO_STATUS=0x%0h", status));
                return;
            end
            csr_read_value(CSR_SYSCO_STATUS, status);
            if (!status[1] || !status[17]) begin
                tb_fail_str($sformatf("RN1 left the domain with RN0, SYSCO_STATUS=0x%0h", status));
                return;
            end
            rn_cache_expect_state(0, SYSCO_DIRTY_ADDR, 1'b0, `CHI_STATE_I, "RN0 dirty line flushed");
            if (test_failed) return;
            rn_cache_expect_state(0, SYSCO_CLEAN_ADDR, 1'b0, `CHI_STATE_I, "RN0 clean line flushed");
            if (test_failed) return;
            rn_cache_expect_state(0, SYSCO_SHARED_ADDR, 1'b0, `CHI_STATE_I, "RN0 shared line flushed");
            if (test_failed) return;
            listed = sf_entries_listing_rn(0);
            if ((listed != 0) || (sysco_mon_listed[0] != 0)) begin
                tb_fail_str($sformatf("snoop filter lists RN0 in %0d entries now and listed it in %0d when SYSCOACK fell; expected 0 and 0",
                                      listed, sysco_mon_listed[0]));
                return;
            end
            if (cpu_req_ready[0] !== 1'b0) begin
                tb_fail("RN0 accepts CPU requests outside the coherency domain");
                return;
            end

            // RN1 works on RN0's old lines: it sees RN0's dirty data and
            // nothing is sent to RN0, not even a SnpDVMOp.
            cpu_read_check_rn(1, SYSCO_DIRTY_ADDR, `CHI_CPU_OP_RD_SHARED,
                              SYSCO_DATA0, "RN1 reads the line RN0 wrote back");
            if (test_failed) return;
            cpu_read_check_rn(1, SYSCO_SHARED_ADDR, `CHI_CPU_OP_RD_UNIQUE,
                              mem_pattern(SYSCO_SHARED_ADDR, 0), "RN1 ReadUnique of the old shared line");
            if (test_failed) return;
            rn_make_dirty(1, SYSCO_CLEAN_ADDR, SYSCO_DATA1, "RN1 writes RN0's old clean line");
            if (test_failed) return;
            cpu_op_resp_check_rn(1, 32'h0000_2340, `CHI_CPU_OP_DVM_OP,
                                 32'h0000_00D1, "RN1 DVMOp with RN0 outside the domain");
            if (test_failed) return;
            wait_cycles(20);
            if (sysco_mon_snp[0] != 0) begin
                tb_fail_str($sformatf("%0d snoops reached RN0 outside the coherency domain", sysco_mon_snp[0]));
                return;
            end

            // RN0 rejoins: it reads RN1's dirty data, and is snooped again.
            csr_write64(CSR_SYSCO_CTRL, {{(64-NUM_RN){1'b0}}, {NUM_RN{1'b1}}});
            sysco_wait_state(0, 1'b1, ok);
            if (!ok) begin
                csr_read_value(CSR_SYSCO_STATUS, status);
                tb_fail_str($sformatf("RN0 did not return to Coherency Enabled, SYSCO_STATUS=0x%0h", status));
                return;
            end
            cpu_read_check_rn(0, SYSCO_CLEAN_ADDR, `CHI_CPU_OP_RD_SHARED,
                              SYSCO_DATA1, "RN0 reads RN1's dirty line after rejoining");
            if (test_failed) return;
            cpu_read_check_rn(0, SYSCO_DIRTY_ADDR, `CHI_CPU_OP_RD_SHARED,
                              SYSCO_DATA0, "RN0 reads back its own old line");
            if (test_failed) return;
            cpu_op_resp_check_rn(1, SYSCO_CLEAN_ADDR, `CHI_CPU_OP_WR_UNIQUE,
                                 SYSCO_DATA2, "RN1 store invalidates RN0's new copy");
            if (test_failed) return;
            rn_cache_expect_state(0, SYSCO_CLEAN_ADDR, 1'b0, `CHI_STATE_I,
                                  "RN0 copy invalidated by RN1's store");
            if (test_failed) return;
            wait_cycles(20);
            sysco_mon_on = 1'b0;
            if (sysco_mon_snp[0] == 0) begin
                tb_fail("RN0 was not snooped after it rejoined the coherency domain");
                return;
            end
            cpu_read_check_rn(0, SYSCO_CLEAN_ADDR, `CHI_CPU_OP_RD_SHARED,
                              SYSCO_DATA2, "RN0 reads RN1's second store");
            if (test_failed) return;
            wait_cycles(20);

            tb_test_pass("RN0 flushed and left with no snoop reaching it; RN1 saw its data; RN0 rejoined coherent");
        end
    endtask

    task automatic dual_core_exclusive_cross_invalidate_check;
        integer timeout;
        begin
            tb_test_start("T27_DUAL_CORE_EXCLUSIVE_CROSS_INVALIDATION",
                          "dual_core_exclusive_cross_invalidate_check",
                          "RN1 write to RN0 LDREX line must snoop/invalidate RN0 and force RN0 STREX failure");

            csr_write64(8'h40, 64'h0000_0008);
            if (test_failed) return;

            cpu_read_check_rn(0,
                              DUAL_EXCL_CROSS_ADDR,
                              `CHI_CPU_OP_LDREX,
                              mem_pattern(DUAL_EXCL_CROSS_ADDR, 0),
                              "RN0 LDREX before RN1 write");
            if (test_failed) return;

            timeout = 0;
            while (((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) ||
                    (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b1) begin
                tb_fail("RN0 local reservation not set before RN1 write");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b1) begin
                tb_fail("HN reservation not set before RN1 write");
                return;
            end

            allow_cpu_write_extra_axi = 1'b1;
            cpu_write_check_rn(1,
                               DUAL_EXCL_CROSS_ADDR,
                               `CHI_CPU_OP_WB_FULL,
                               DUAL_EXCL_CROSS_DATA,
                               "RN1 WriteBackFull invalidates RN0 line");
            allow_cpu_write_extra_axi = 1'b0;
            if (test_failed) return;

            timeout = 0;
            while (((dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) ||
                    (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
            end
            if (dut.gen_rn[0].u_rn_f.u_exclusive_monitor.valid_q !== 1'b0) begin
                tb_fail("RN1 write did not clear RN0 local reservation");
                return;
            end
            if (dut.gen_hn[0].u_hn_f.excl_valid_q[0] !== 1'b0) begin
                tb_fail("RN1 write did not clear HN RN0 reservation");
                return;
            end

            // RN1's write can evict an older RN1 dirty line; let that
            // writeback finish so it is not counted against RN0 STREX.
            wait_axi_write_quiet(64);
            if (test_failed) return;

            cpu_strex_result_check_rn(0,
                                      DUAL_EXCL_CROSS_ADDR,
                                      DUAL_EXCL_CROSS_FAIL_DATA,
                                      1'b0,
                                      1'b0,
                                      "RN0 STREX after RN1 invalidation");
            if (test_failed) return;

            csr_read_check(8'h40, 64'h0000_0000, CSR_MASK_4B);
            if (test_failed) return;

            tb_test_pass("RN1 same-line write invalidated RN0 exclusive state and RN0 STREX failed locally");
        end
    endtask

    task automatic dual_core_backpressure_concurrent_check;
        integer ar_before;
        integer r_before;
        begin
            tb_test_start("T28_DUAL_CORE_BACKPRESSURE_CONCURRENT_REQ",
                          "dual_core_backpressure_concurrent_check",
                          "RN0 and RN1 issue concurrent ReadShared misses while AXI ready/response backpressure is active");

            ar_before = axi_ar_count;
            r_before = axi_r_count;
            axi_bp_enable = 1'b1;
            dual_rn_read_concurrent_check(DUAL_BP_RN0_ADDR,
                                          DUAL_BP_RN1_ADDR,
                                          mem_pattern(DUAL_BP_RN0_ADDR, 0),
                                          mem_pattern(DUAL_BP_RN1_ADDR, 0),
                                          "RN0/RN1 concurrent backpressure reads");
            axi_bp_enable = 1'b0;
            if (test_failed) return;

            if (axi_ar_count != (ar_before + 2)) begin
                tb_fail("Concurrent dual-RN reads did not issue two AXI AR bursts");
                return;
            end
            if (axi_r_count != (r_before + (2 * BEATS))) begin
                tb_fail("Concurrent dual-RN reads did not receive two full AXI R bursts");
                return;
            end

            tb_test_pass("Both RN requests completed under deterministic AXI backpressure");
        end
    endtask

    task automatic hn_slots_overlap_prefetch_check;
        integer ar_before;
        integer timeout;
        reg [NUM_RN-1:0] accepted;
        reg [NUM_RN-1:0] responded;
        reg [DATA_WIDTH-1:0] got0;
        reg [DATA_WIDTH-1:0] got1;
        reg [63:0] perf_front_before;
        reg [63:0] perf_front_after;
        reg [63:0] perf_slot2_before;
        reg [63:0] perf_slot2_after;
        begin
            tb_test_start("T33_HN_SLOTS_DUAL_POP_OVERLAP",
                          "hn_slots_overlap_prefetch_check",
                          "Independent RN request should use the second HN front slot while an LLC-hit response is stalled");

            wait_cycles(80);
            llc_backdoor_seed_hn_slot_line(HN_SLOT_HIT_ADDR,
                                           LLC_HN_SLOT_SET);
            if (test_failed) return;
            wait_cycles(10);

            csr_read_value(8'h80, perf_front_before);
            if (test_failed) return;
            csr_read_value(8'h8E, perf_slot2_before);
            if (test_failed) return;

            ar_before = axi_ar_count;

            accepted = {NUM_RN{1'b0}};
            responded = {NUM_RN{1'b0}};
            got0 = {DATA_WIDTH{1'b0}};
            got1 = {DATA_WIDTH{1'b0}};

            @(negedge clk);
            force dut.gen_hn[0].u_hn_f.dat_arb_valid = 1'b0;
            force dut.gen_hn[0].u_hn_f.dat_arb_ready = 1'b0;

            cpu_req_addr[0*ADDR_WIDTH +: ADDR_WIDTH] = HN_SLOT_HIT_ADDR;
            cpu_req_op[0*4 +: 4] = `CHI_CPU_OP_RD_SHARED;
            cpu_req_size[0*3 +: 3] = 3'd6;
            cpu_wdata[0*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            cpu_req_valid[0] = 1'b1;

            timeout = 0;
            while (!accepted[0] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_valid[0] && cpu_req_ready[0])
                    accepted[0] = 1'b1;
            end
            if (!accepted[0]) begin
                tb_fail("HN slot overlap RN0 hit request accept timeout");
                return;
            end
            @(negedge clk);
            cpu_req_valid[0] = 1'b0;

            cpu_req_addr[1*ADDR_WIDTH +: ADDR_WIDTH] = HN_SLOT_OVERLAP_ADDR1;
            cpu_req_op[1*4 +: 4] = `CHI_CPU_OP_RD_SHARED;
            cpu_req_size[1*3 +: 3] = 3'd6;
            cpu_wdata[1*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            cpu_req_valid[1] = 1'b1;

            timeout = 0;
            while (!accepted[1] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_valid[1] && cpu_req_ready[1])
                    accepted[1] = 1'b1;
            end
            if (!accepted[1]) begin
                tb_fail("HN slot overlap RN1 miss request accept timeout");
                return;
            end
            @(negedge clk);
            cpu_req_valid[1] = 1'b0;

            wait_cycles(80);
            release dut.gen_hn[0].u_hn_f.dat_arb_ready;
            release dut.gen_hn[0].u_hn_f.dat_arb_valid;

            timeout = 0;
            while (((responded[0] == 1'b0) || (responded[1] == 1'b0)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (!responded[0] && cpu_resp_valid[0]) begin
                    responded[0] = 1'b1;
                    got0 = cpu_rdata[0*DATA_WIDTH +: DATA_WIDTH];
                end
                if (!responded[1] && cpu_resp_valid[1]) begin
                    responded[1] = 1'b1;
                    got1 = cpu_rdata[1*DATA_WIDTH +: DATA_WIDTH];
                end
            end
            if ((responded[0] == 1'b0) || (responded[1] == 1'b0)) begin
                tb_fail("HN slot overlap response timeout");
                return;
            end
            if (got0 !== base_mem_pattern(HN_SLOT_HIT_ADDR, 0)) begin
                tb_fail("HN slot overlap RN0 hit data mismatch");
                return;
            end
            if (got1 !== mem_pattern(HN_SLOT_OVERLAP_ADDR1, 0)) begin
                tb_fail("HN slot overlap RN1 miss data mismatch");
                return;
            end

            csr_read_value(8'h80, perf_front_after);
            if (test_failed) return;
            csr_read_value(8'h8E, perf_slot2_after);
            if (test_failed) return;

            if (axi_ar_count != (ar_before + 1)) begin
                tb_fail("HN slot overlap test expected one new AXI AR for the second independent line");
                return;
            end
            if (perf_slot2_after <= perf_slot2_before) begin
                tb_fail("HN second-slot prefetch counter did not increment");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s HN slot counters front=%0d->%0d slot2=%0d->%0d",
                     $time, current_test_id, current_task_name,
                     perf_front_before[31:0], perf_front_after[31:0],
                     perf_slot2_before[31:0], perf_slot2_after[31:0]);
            tb_test_pass("Independent-line request was captured while HN DAT path was stalled and completed after release");
        end
    endtask

    task automatic hn_slots_same_line_hazard_check;
        integer ar_before;
        integer timeout;
        reg [NUM_RN-1:0] accepted;
        reg [NUM_RN-1:0] responded;
        reg [DATA_WIDTH-1:0] got0;
        reg [DATA_WIDTH-1:0] got1;
        reg [63:0] perf_lock_before;
        reg [63:0] perf_lock_after;
        reg [63:0] perf_slot2_before;
        reg [63:0] perf_slot2_after;
        begin
            tb_test_start("T34_HN_SLOTS_SAME_LINE_HAZARD",
                          "hn_slots_same_line_hazard_check",
                          "Two RN reads to the same cache line must not dual-pop into independent HN front slots");

            wait_cycles(40);
            llc_backdoor_seed_hn_slot_line(HN_SLOT_SAME_LINE_ADDR,
                                           LLC_HN_HAZARD_SET);
            if (test_failed) return;
            wait_cycles(10);

            csr_read_value(8'h8C, perf_lock_before);
            if (test_failed) return;
            csr_read_value(8'h8E, perf_slot2_before);
            if (test_failed) return;

            ar_before = axi_ar_count;

            accepted = {NUM_RN{1'b0}};
            responded = {NUM_RN{1'b0}};
            got0 = {DATA_WIDTH{1'b0}};
            got1 = {DATA_WIDTH{1'b0}};

            @(negedge clk);
            force dut.gen_hn[0].u_hn_f.dat_arb_valid = 1'b0;
            force dut.gen_hn[0].u_hn_f.dat_arb_ready = 1'b0;

            cpu_req_addr[0*ADDR_WIDTH +: ADDR_WIDTH] = HN_SLOT_SAME_LINE_ADDR;
            cpu_req_op[0*4 +: 4] = `CHI_CPU_OP_RD_SHARED;
            cpu_req_size[0*3 +: 3] = 3'd6;
            cpu_wdata[0*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            cpu_req_valid[0] = 1'b1;

            timeout = 0;
            while (!accepted[0] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_valid[0] && cpu_req_ready[0])
                    accepted[0] = 1'b1;
            end
            if (!accepted[0]) begin
                tb_fail("HN same-line RN0 hit request accept timeout");
                return;
            end
            @(negedge clk);
            cpu_req_valid[0] = 1'b0;

            cpu_req_addr[1*ADDR_WIDTH +: ADDR_WIDTH] = HN_SLOT_SAME_LINE_ADDR;
            cpu_req_op[1*4 +: 4] = `CHI_CPU_OP_RD_SHARED;
            cpu_req_size[1*3 +: 3] = 3'd6;
            cpu_wdata[1*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            cpu_req_valid[1] = 1'b1;

            timeout = 0;
            while (!accepted[1] && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_valid[1] && cpu_req_ready[1])
                    accepted[1] = 1'b1;
            end
            if (!accepted[1]) begin
                tb_fail("HN same-line RN1 request accept timeout");
                return;
            end
            @(negedge clk);
            cpu_req_valid[1] = 1'b0;

            wait_cycles(80);
            release dut.gen_hn[0].u_hn_f.dat_arb_ready;
            release dut.gen_hn[0].u_hn_f.dat_arb_valid;

            timeout = 0;
            while (((responded[0] == 1'b0) || (responded[1] == 1'b0)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (!responded[0] && cpu_resp_valid[0]) begin
                    responded[0] = 1'b1;
                    got0 = cpu_rdata[0*DATA_WIDTH +: DATA_WIDTH];
                end
                if (!responded[1] && cpu_resp_valid[1]) begin
                    responded[1] = 1'b1;
                    got1 = cpu_rdata[1*DATA_WIDTH +: DATA_WIDTH];
                end
            end
            if ((responded[0] == 1'b0) || (responded[1] == 1'b0)) begin
                tb_fail("HN same-line response timeout");
                return;
            end
            if ((got0 !== base_mem_pattern(HN_SLOT_SAME_LINE_ADDR, 0)) ||
                (got1 !== base_mem_pattern(HN_SLOT_SAME_LINE_ADDR, 0))) begin
                tb_fail("HN same-line read data mismatch");
                return;
            end

            csr_read_value(8'h8C, perf_lock_after);
            if (test_failed) return;
            csr_read_value(8'h8E, perf_slot2_after);
            if (test_failed) return;

            if (axi_ar_count != ar_before) begin
                tb_fail("Same-line HN hazard test expected no new AXI AR from seeded LLC line");
                return;
            end
            if (perf_slot2_after != perf_slot2_before) begin
                tb_fail("Same-line HN hazard incorrectly used second-slot dual-pop");
                return;
            end
            if (perf_lock_after <= perf_lock_before) begin
                tb_fail("Same-line HN hazard did not raise address-lock stall evidence");
                return;
            end

            $display("[%0t] TEST STEP  %0s task=%0s HN same-line counters lock=%0d->%0d slot2=%0d->%0d",
                     $time, current_test_id, current_task_name,
                     perf_lock_before[31:0], perf_lock_after[31:0],
                     perf_slot2_before[31:0], perf_slot2_after[31:0]);
            tb_test_pass("Same-line requests serialized and did not consume the second HN front slot");
        end
    endtask

    task automatic hn_retry_pcredit_write_check;
        integer timeout;
        reg accepted;
        reg saw_ack;
        reg saw_grant;
        reg saw_reissue;
        reg responded;
        begin
            tb_test_start("T35_HN_RETRY_PCRD_WRITE_UNIQUE",
                          "hn_retry_pcredit_write_check",
                          "HN must RetryAck a blocked retryable write, issue PCrdGrant, and RN must reissue before completion");

            wait_cycles(20);
            accepted = 1'b0;
            saw_ack = 1'b0;
            saw_grant = 1'b0;
            saw_reissue = 1'b0;
            responded = 1'b0;
            strict_cpu_sparse_write_aw_count = 0;
            strict_cpu_sparse_write_w_count = 0;
            strict_cpu_sparse_write_b_count = 0;
            strict_cpu_sparse_write_active = 1'b1;
            strict_cpu_sparse_write_addr = HN_RETRY_WRITE_ADDR;
            strict_cpu_sparse_write_data = HN_RETRY_WRITE_DATA;

            @(negedge clk);
            force dut.gen_hn[0].u_hn_f.wr_tracker_alloc_ready = 1'b0;

            cpu_req_addr[0*ADDR_WIDTH +: ADDR_WIDTH] = HN_RETRY_WRITE_ADDR;
            cpu_req_op[0*4 +: 4] = `CHI_CPU_OP_WR_UNIQUE;
            cpu_req_size[0*3 +: 3] = 3'd6;
            cpu_req_qos[0*QOS_W +: QOS_W] = 4'h9;
            cpu_req_tag[0*CPU_TAG_W +: CPU_TAG_W] = 2'b01;
            cpu_wdata[0*DATA_WIDTH +: DATA_WIDTH] = HN_RETRY_WRITE_DATA;
            cpu_req_valid[0] = 1'b1;

            timeout = 0;
            while (!accepted && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (cpu_req_valid[0] && cpu_req_ready[0])
                    accepted = 1'b1;
            end
            if (!accepted) begin
                release dut.gen_hn[0].u_hn_f.wr_tracker_alloc_ready;
                tb_fail("HN retry write request accept timeout");
                return;
            end

            @(negedge clk);
            cpu_req_valid[0] = 1'b0;

            timeout = 0;
            while (!saw_ack && (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (dut.gen_hn[0].u_hn_f.retry_ack_fire)
                    saw_ack = 1'b1;
            end
            if (!saw_ack) begin
                release dut.gen_hn[0].u_hn_f.wr_tracker_alloc_ready;
                tb_fail("HN retry path did not emit RetryAck");
                return;
            end

            release dut.gen_hn[0].u_hn_f.wr_tracker_alloc_ready;

            timeout = 0;
            while (((!saw_grant) || (!saw_reissue) || (!responded)) &&
                   (timeout < MAX_WAIT)) begin
                timeout = timeout + 1;
                @(posedge clk);
                if (dut.gen_hn[0].u_hn_f.retry_grant_fire)
                    saw_grant = 1'b1;
                if (dut.gen_rn[0].u_rn_f.retry_reissue_fire)
                    saw_reissue = 1'b1;
                if (cpu_resp_valid[0])
                    responded = 1'b1;
            end
            if (!saw_grant) begin
                tb_fail("HN retry path did not emit PCrdGrant");
                return;
            end
            if (!saw_reissue) begin
                tb_fail("RN did not reissue after PCrdGrant");
                return;
            end
            if (!responded) begin
                tb_fail("Retried WriteUnique did not complete");
                return;
            end

            @(negedge clk);
            cpu_wdata[0*DATA_WIDTH +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};

            if (strict_cpu_sparse_write_aw_count != 1) begin
                tb_fail("Retried WriteUnique did not issue exactly one AXI AW");
                return;
            end
            if (strict_cpu_sparse_write_w_count != BEATS) begin
                tb_fail("Retried WriteUnique did not issue exactly one full AXI W burst");
                return;
            end
            if (strict_cpu_sparse_write_b_count != 1) begin
                tb_fail("Retried WriteUnique did not complete exactly one AXI B response");
                return;
            end
            if (mem_pattern(HN_RETRY_WRITE_ADDR, 0) !== HN_RETRY_WRITE_DATA) begin
                tb_fail("Retried WriteUnique data not observed in AXI shadow memory");
                return;
            end
            strict_cpu_sparse_write_active = 1'b0;

            $display("[%0t] TEST STEP  %0s task=%0s retry write ack=%0b grant=%0b reissue=%0b addr=0x%011h data=0x%016h",
                     $time, current_test_id, current_task_name,
                     saw_ack, saw_grant, saw_reissue,
                     HN_RETRY_WRITE_ADDR, HN_RETRY_WRITE_DATA);
            tb_test_pass("RetryAck, PCrdGrant, and RN reissue were observed before the WriteUnique completed once");
        end
    endtask

    task automatic random_axi_backpressure_dual_mix_check;
        integer ar_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        integer r_before;
        integer i;
        integer rd_rn;
        integer wr_rn;
        reg [ADDR_WIDTH-1:0] rd_addr;
        reg [ADDR_WIDTH-1:0] wr_addr;
        reg [DATA_WIDTH-1:0] wr_data;
        begin
            tb_test_start("T29_STRESS_RANDOM_AXI_BP_DUAL_MIX",
                          "random_axi_backpressure_dual_mix_check",
                          "Pseudo-random AXI stalls stress mixed RN0/RN1 reads, writes, and readbacks");

            ar_before = axi_ar_count;
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;
            r_before  = axi_r_count;

            axi_bp_random_enable = 1'b1;
            axi_bp_lfsr_q = 16'hACE1;
            wait_cycles(3);

            for (i = 0; i < 4; i = i + 1) begin
                rd_rn = i & 1;
                wr_rn = (i + 1) & 1;
                rd_addr = RANDOM_BP_BASE + (i * 32'h0000_0080);
                wr_addr = RANDOM_BP_WRITE_BASE_ADDR + (i * 32'h0000_0080);
                wr_data = RANDOM_BP_WRITE_DATA_BASE + i;

                cpu_read_check_rn(rd_rn,
                                  rd_addr,
                                  `CHI_CPU_OP_RD_SHARED,
                                  mem_pattern(rd_addr, 0),
                                  "Pseudo-random backpressure read");
                if (test_failed) begin
                    axi_bp_random_enable = 1'b0;
                    return;
                end

                allow_cpu_write_extra_axi = 1'b1;
                cpu_write_check_rn(wr_rn,
                                   wr_addr,
                                   `CHI_CPU_OP_WB_FULL,
                                   wr_data,
                                   "Pseudo-random backpressure WriteBackFull");
                allow_cpu_write_extra_axi = 1'b0;
                if (test_failed) begin
                    axi_bp_random_enable = 1'b0;
                    return;
                end

                cpu_read_check_rn(rd_rn,
                                  wr_addr,
                                  `CHI_CPU_OP_RD_SHARED,
                                  wr_data,
                                  "Pseudo-random backpressure readback");
                if (test_failed) begin
                    axi_bp_random_enable = 1'b0;
                    return;
                end
            end

            axi_bp_random_enable = 1'b0;
            wait_cycles(4);

            if (axi_ar_count < (ar_before + 4)) begin
                tb_fail("Random AXI backpressure stress expected at least four AXI AR bursts");
                return;
            end
            if (axi_r_count < (r_before + (4 * BEATS))) begin
                tb_fail("Random AXI backpressure stress expected at least four full AXI R bursts");
                return;
            end
            if (axi_aw_count < (aw_before + 4)) begin
                tb_fail("Random AXI backpressure stress expected at least four AXI AW bursts");
                return;
            end
            if (axi_w_count < (w_before + (4 * BEATS))) begin
                tb_fail("Random AXI backpressure stress expected at least four full AXI W bursts");
                return;
            end
            if (axi_b_count < (b_before + 4)) begin
                tb_fail("Random AXI backpressure stress expected at least four AXI B responses");
                return;
            end

            csr_read_check(8'h40, 64'h0000_0000, CSR_MASK_4B);
            if (test_failed) return;

            tb_test_pass("Pseudo-random AXI stalls completed mixed dual-RN read/write/readback traffic without errors");
        end
    endtask

    task automatic random_axi_backpressure_multiseed_check;
        integer ar_before;
        integer aw_before;
        integer w_before;
        integer b_before;
        integer r_before;
        integer seed_idx;
        integer i;
        integer global_i;
        integer rd_rn;
        integer wr_rn;
        reg [15:0] seed;
        reg [ADDR_WIDTH-1:0] rd_addr;
        reg [ADDR_WIDTH-1:0] wr_addr;
        reg [DATA_WIDTH-1:0] wr_data;
        begin
            tb_test_start("T30_STRESS_MULTI_SEED_AXI_BP_DUAL_MIX",
                          "random_axi_backpressure_multiseed_check",
                          "Multiple LFSR seeds stress mixed RN0/RN1 traffic under different AXI stall phases");

            ar_before = axi_ar_count;
            aw_before = axi_aw_count;
            w_before  = axi_w_count;
            b_before  = axi_b_count;
            r_before  = axi_r_count;

            for (seed_idx = 0; seed_idx < 3; seed_idx = seed_idx + 1) begin
                case (seed_idx)
                    0: seed = 16'hACE1;
                    1: seed = 16'hBEEF;
                    default: seed = 16'h1234;
                endcase

                axi_bp_random_enable = 1'b1;
                axi_bp_lfsr_q = seed;
                wait_cycles(3);

                for (i = 0; i < 2; i = i + 1) begin
                    global_i = (seed_idx * 2) + i;
                    rd_rn = global_i & 1;
                    wr_rn = (global_i + 1) & 1;
                    rd_addr = MULTISEED_BP_BASE +
                              (global_i * 32'h0000_0080);
                    wr_addr = MULTISEED_BP_WRITE_BASE_ADDR +
                              (global_i * 32'h0000_0080);
                    wr_data = MULTISEED_BP_WRITE_DATA_BASE + global_i;

                    cpu_read_check_rn(rd_rn,
                                      rd_addr,
                                      `CHI_CPU_OP_RD_SHARED,
                                      mem_pattern(rd_addr, 0),
                                      "Multi-seed backpressure read");
                    if (test_failed) begin
                        axi_bp_random_enable = 1'b0;
                        return;
                    end

                    allow_cpu_write_extra_axi = 1'b1;
                    cpu_write_check_rn(wr_rn,
                                       wr_addr,
                                       `CHI_CPU_OP_WB_FULL,
                                       wr_data,
                                       "Multi-seed backpressure WriteBackFull");
                    allow_cpu_write_extra_axi = 1'b0;
                    if (test_failed) begin
                        axi_bp_random_enable = 1'b0;
                        return;
                    end

                    cpu_read_check_rn(rd_rn,
                                      wr_addr,
                                      `CHI_CPU_OP_RD_SHARED,
                                      wr_data,
                                      "Multi-seed backpressure readback");
                    if (test_failed) begin
                        axi_bp_random_enable = 1'b0;
                        return;
                    end
                end

                axi_bp_random_enable = 1'b0;
                wait_cycles(3);
            end

            if (axi_ar_count < (ar_before + 6)) begin
                tb_fail("Multi-seed AXI backpressure stress expected at least six AXI AR bursts");
                return;
            end
            if (axi_r_count < (r_before + (6 * BEATS))) begin
                tb_fail("Multi-seed AXI backpressure stress expected at least six full AXI R bursts");
                return;
            end
            if (axi_aw_count < (aw_before + 6)) begin
                tb_fail("Multi-seed AXI backpressure stress expected at least six AXI AW bursts");
                return;
            end
            if (axi_w_count < (w_before + (6 * BEATS))) begin
                tb_fail("Multi-seed AXI backpressure stress expected at least six full AXI W bursts");
                return;
            end
            if (axi_b_count < (b_before + 6)) begin
                tb_fail("Multi-seed AXI backpressure stress expected at least six AXI B responses");
                return;
            end

            csr_read_check(8'h40, 64'h0000_0000, CSR_MASK_4B);
            if (test_failed) return;

            tb_test_pass("Three AXI stall seeds completed mixed dual-RN traffic without errors");
        end
    endtask

    task automatic rv32_sparse_store_lane_check;
        reg [DATA_WIDTH-1:0] exp_byte_word;
        reg [DATA_WIDTH-1:0] exp_half_word;
        begin
            tb_test_start("T31_RV32_SPARSE_STORE_LANES",
                          "rv32_sparse_store_lane_check",
                          "RV32 byte and halfword stores must update only the addressed AXI/CHI byte lanes");

            exp_byte_word =
                apply_sparse_store_word(mem_pattern(SPARSE_BYTE_ADDR,
                                                    SPARSE_BYTE_ADDR[5:2]),
                                        SPARSE_BYTE_DATA,
                                        3'd0,
                                        SPARSE_BYTE_ADDR[1:0]);
            cpu_write_sized_check_rn(0,
                                     SPARSE_BYTE_ADDR,
                                     3'd0,
                                     SPARSE_BYTE_DATA,
                                     exp_byte_word,
                                     "SB offset2 lane update");
            if (test_failed) return;
            cpu_read_check_rn(1,
                              SPARSE_BYTE_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              exp_byte_word,
                              "RN1 ReadShared after RN0 SB");
            if (test_failed) return;

            exp_half_word =
                apply_sparse_store_word(mem_pattern(SPARSE_HALF_ADDR,
                                                    SPARSE_HALF_ADDR[5:2]),
                                        SPARSE_HALF_DATA,
                                        3'd1,
                                        SPARSE_HALF_ADDR[1:0]);
            cpu_write_sized_check_rn(1,
                                     SPARSE_HALF_ADDR,
                                     3'd1,
                                     SPARSE_HALF_DATA,
                                     exp_half_word,
                                     "SH offset2 lane update");
            if (test_failed) return;
            cpu_read_check_rn(0,
                              SPARSE_HALF_ADDR,
                              `CHI_CPU_OP_RD_SHARED,
                              exp_half_word,
                              "RN0 ReadShared after RN1 SH");
            if (test_failed) return;

            tb_test_pass("RV32 sparse store byte lanes updated correctly across RN-F/HN-F/SN");
        end
    endtask

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_busy_q    <= 1'b0;
            rd_addr_q    <= {ADDR_WIDTH{1'b0}};
            rd_len_q     <= 8'd0;
            rd_beat_q    <= 8'd0;
            rd_latency_q <= 4'd0;
            axi_rvalid   <= {NUM_SN{1'b0}};
            axi_rdata    <= {NUM_SN*DATA_WIDTH{1'b0}};
            axi_rresp    <= {NUM_SN*2{1'b0}};
            axi_ar_count <= 0;
            axi_r_count  <= 0;
        end else begin
            if (axi_arvalid[0] && axi_arready[0]) begin
                rd_busy_q    <= 1'b1;
                rd_addr_q    <= axi_araddr[ADDR_WIDTH-1:0];
                rd_len_q     <= axi_arlen[7:0];
                rd_beat_q    <= 8'd0;
                rd_latency_q <= 4'd2;
                axi_ar_count <= axi_ar_count + 1;
                $display("[%0t] BUS AXI_AR %0s task=%0s addr=0x%011h len=%0d size=%0d burst=%0d",
                         $time, current_test_id, current_task_name,
                         axi_araddr[ADDR_WIDTH-1:0],
                         axi_arlen[7:0], axi_arsize[2:0],
                         axi_arburst[1:0]);
                // This model reads whole lines, which hides a misaligned
                // start. A real INCR slave returns the burst from ARADDR, so
                // a full-line burst must start on the line.
                if ((axi_arlen[7:0] == BEATS - 1) && (axi_araddr[5:0] != 6'd0))
                    tb_fail("AXI full-line read burst starts inside the line (ARADDR not line aligned)");
            end

            if (rd_busy_q && !axi_rvalid[0]) begin
                if (rd_latency_q != 4'd0) begin
                    rd_latency_q <= rd_latency_q - 1'b1;
                end else if (!axi_bp_r_stall && !axi_bp_rand_r_stall &&
                             !axi_r_hold) begin
                    axi_rvalid[0] <= 1'b1;
                    axi_rdata[DATA_WIDTH-1:0] <=
                        mem_pattern(rd_addr_q, rd_beat_q);
                    axi_rresp[1:0] <= `CHI_RESPERR_OK;
                end
            end else if (axi_rvalid[0] && axi_rready[0]) begin
                axi_r_count <= axi_r_count + 1;
                if (rd_beat_q == rd_len_q) begin
                    axi_rvalid[0] <= 1'b0;
                    rd_busy_q <= 1'b0;
                    rd_beat_q <= 8'd0;
                end else begin
                    rd_beat_q <= rd_beat_q + 1'b1;
                    if (axi_bp_random_enable) begin
                        axi_rvalid[0] <= 1'b0;
                        rd_latency_q <= axi_bp_random_delay;
                    end else if (axi_bp_enable) begin
                        axi_rvalid[0] <= 1'b0;
                        rd_latency_q <= {2'b00, axi_bp_cycle_q[1:0]} + 1'b1;
                    end else begin
                        axi_rdata[DATA_WIDTH-1:0] <=
                            mem_pattern(rd_addr_q, rd_beat_q + 1'b1);
                    end
                end
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_busy_q         <= 1'b0;
            wr_addr_q         <= {ADDR_WIDTH{1'b0}};
            wr_beat_count_q   <= 8'd0;
            wr_resp_latency_q <= 4'd0;
            axi_bvalid        <= {NUM_SN{1'b0}};
            axi_bresp         <= {NUM_SN*2{1'b0}};
            axi_aw_count      <= 0;
            axi_w_count       <= 0;
            axi_b_count       <= 0;
            wr_shadow_idx_q   <= -1;
            mem_shadow_valid  <= {MEM_SHADOW_LINES{1'b0}};
            mem_shadow_replace_q <= 0;
            for (shadow_i = 0; shadow_i < MEM_SHADOW_LINES; shadow_i = shadow_i + 1) begin
                mem_shadow_addr[shadow_i] <= {ADDR_WIDTH{1'b0}};
                for (shadow_j = 0; shadow_j < BEATS; shadow_j = shadow_j + 1)
                    mem_shadow_data[shadow_i][shadow_j] <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            if (axi_awvalid[0] && axi_awready[0]) begin
                wr_busy_q       <= 1'b1;
                wr_addr_q       <= axi_awaddr[ADDR_WIDTH-1:0];
                wr_beat_count_q <= 8'd0;
                axi_aw_count    <= axi_aw_count + 1;
                if (strict_cpu_sparse_write_active &&
                    (axi_awaddr[ADDR_WIDTH-1:0] == strict_cpu_sparse_write_addr))
                    strict_cpu_sparse_write_aw_count <=
                        strict_cpu_sparse_write_aw_count + 1;
                shadow_idx = mem_shadow_find(axi_awaddr[ADDR_WIDTH-1:0]);
                if (shadow_idx < 0) begin
                    shadow_idx = mem_shadow_replace_q;
                    mem_shadow_replace_q <=
                        (mem_shadow_replace_q == (MEM_SHADOW_LINES - 1)) ?
                        0 : (mem_shadow_replace_q + 1);
                    mem_shadow_valid[shadow_idx] <= 1'b1;
                    mem_shadow_addr[shadow_idx] <=
                        mem_line_base(axi_awaddr[ADDR_WIDTH-1:0]);
                    for (shadow_b = 0; shadow_b < BEATS; shadow_b = shadow_b + 1) begin
                        mem_shadow_data[shadow_idx][shadow_b] <=
                            base_mem_pattern(axi_awaddr[ADDR_WIDTH-1:0],
                                             shadow_b);
                    end
                end
                wr_shadow_idx_q <= shadow_idx;
                if (a5_conc_active) begin
                    if (a5_conc_aw_seen == 0)
                        a5_conc_aw_addr0 <= axi_awaddr[ADDR_WIDTH-1:0];
                    else if (a5_conc_aw_seen == 1)
                        a5_conc_aw_addr1 <= axi_awaddr[ADDR_WIDTH-1:0];
                    a5_conc_aw_seen <= a5_conc_aw_seen + 1;
                end
                $display("[%0t] BUS AXI_AW %0s task=%0s addr=0x%011h len=%0d",
                         $time, current_test_id, current_task_name,
                         axi_awaddr[ADDR_WIDTH-1:0],
                         axi_awlen[7:0]);
            end

            if (axi_wvalid[0] && axi_wready[0]) begin
                wr_beat_count_q <= wr_beat_count_q + 1'b1;
                axi_w_count <= axi_w_count + 1;
                if (strict_cpu_sparse_write_active &&
                    (wr_addr_q == strict_cpu_sparse_write_addr))
                    strict_cpu_sparse_write_w_count <=
                        strict_cpu_sparse_write_w_count + 1;
                if (wr_shadow_idx_q < 0) begin
                    tb_fail("AXI W beat arrived before tracked AW");
                end else begin
                    if (strict_cpu_sparse_write_active &&
                        (wr_addr_q == strict_cpu_sparse_write_addr)) begin
                        if (wr_beat_count_q == 8'd0) begin
                            if (axi_wdata[DATA_WIDTH-1:0] !==
                                strict_cpu_sparse_write_data)
                                tb_fail("CPU sparse W beat0 data mismatch");
                            if (axi_wstrb[BE_W-1:0] !== {BE_W{1'b1}})
                                tb_fail("CPU sparse W beat0 strobe mismatch");
                        end else if (axi_wstrb[BE_W-1:0] !== {BE_W{1'b0}}) begin
                            tb_fail("CPU sparse W upper beat strobe mismatch");
                        end
                    end

                    if (wr_addr_q == EVICT_DIRTY_ADDR0) begin
                        if (axi_wdata[DATA_WIDTH-1:0] !==
                            dirty_evict_word(wr_beat_count_q))
                            tb_fail("LLC dirty victim W data mismatch");
                        if (axi_wstrb[BE_W-1:0] !== {BE_W{1'b1}})
                            tb_fail("LLC dirty victim W strobe mismatch");
                    end

                    for (shadow_byte = 0; shadow_byte < BE_W; shadow_byte = shadow_byte + 1) begin
                        if (axi_wstrb[shadow_byte])
                            mem_shadow_data[wr_shadow_idx_q][wr_beat_count_q]
                                [shadow_byte*8 +: 8] <=
                                axi_wdata[shadow_byte*8 +: 8];
                    end
                end
                if (axi_wlast[0] != (wr_beat_count_q == (BEATS - 1))) begin
                    $display("[%0t] AXI W burst addr=0x%011h beat=%0d wlast=%0b",
                             $time, wr_addr_q, wr_beat_count_q, axi_wlast[0]);
                    tb_fail("AXI W burst length does not match AWLEN (beats spliced)");
                end
                if (axi_wlast[0]) begin
                    wr_busy_q <= 1'b0;
                    wr_resp_latency_q <= 4'd2;
                    wr_shadow_idx_q <= -1;
                end
            end

            if (!wr_busy_q && (wr_resp_latency_q != 4'd0) &&
                !((wr_resp_latency_q == 4'd1) &&
                  (axi_bp_b_stall || axi_bp_rand_b_stall ||
                   (axi_b_hold &&
                    (!axi_b_hold_addr_en || (wr_addr_q == axi_b_hold_addr)))))) begin
                wr_resp_latency_q <= wr_resp_latency_q - 1'b1;
                if (wr_resp_latency_q == 4'd1) begin
                    axi_bvalid[0] <= 1'b1;
                    axi_bresp[1:0] <= `CHI_RESPERR_OK;
                end
            end

            if (axi_bvalid[0] && axi_bready[0]) begin
                axi_bvalid[0] <= 1'b0;
                axi_b_count <= axi_b_count + 1;
                if (strict_cpu_sparse_write_active &&
                    (wr_addr_q == strict_cpu_sparse_write_addr))
                    strict_cpu_sparse_write_b_count <=
                        strict_cpu_sparse_write_b_count + 1;
                $display("[%0t] BUS AXI_B  %0s task=%0s addr=0x%011h beats=%0d",
                         $time, current_test_id, current_task_name,
                         wr_addr_q, wr_beat_count_q);
            end
        end
    end

    initial begin : main_test
        clk = 1'b0;
        rstn = 1'b0;
        test_failed = 1'b0;

        csr_valid = 1'b0;
        csr_write = 1'b0;
        csr_addr = 8'h00;
        csr_wdata = 64'd0;

        cpu_req_valid = {NUM_RN{1'b0}};
        cpu_req_addr = {NUM_RN*ADDR_WIDTH{1'b0}};
        cpu_req_op = {NUM_RN*4{1'b0}};
        cpu_req_size = {NUM_RN*3{1'b0}};
        cpu_req_qos = {NUM_RN*QOS_W{1'b0}};
        cpu_req_tag = {NUM_RN*CPU_TAG_W{1'b0}};
        cpu_wdata = {NUM_RN*DATA_WIDTH{1'b0}};
        axi_r_hold = 1'b0;
        axi_b_hold = 1'b0;
        axi_b_hold_addr_en = 1'b0;
        axi_b_hold_addr = {ADDR_WIDTH{1'b0}};
        axi_w_hold = 1'b0;
        axi_w_hold_beat = 8'd0;
        rn_watchdog_expected = 1'b0;
        a5_conc_active = 1'b0;
        a5_conc_aw_seen = 0;
        a5_conc_aw_addr0 = {ADDR_WIDTH{1'b0}};
        a5_conc_aw_addr1 = {ADDR_WIDTH{1'b0}};
        strict_cpu_sparse_write_active = 1'b0;
        strict_cpu_sparse_write_addr = {ADDR_WIDTH{1'b0}};
        strict_cpu_sparse_write_data = {DATA_WIDTH{1'b0}};
        strict_cpu_sparse_write_aw_count = 0;
        strict_cpu_sparse_write_w_count = 0;
        strict_cpu_sparse_write_b_count = 0;
        allow_cpu_write_extra_axi = 1'b0;
        allow_chi_irq = 1'b0;
        axi_bp_enable = 1'b0;
        axi_ar_count_base = 0;
        axi_aw_count_base = 0;
        axi_w_count_base = 0;
        axi_b_count_base = 0;
        axi_r_count_base = 0;
        current_test_id = "TB_INIT";
        current_task_name = "main_test";
        current_test_purpose = "Initialize testbench and release reset";
        a2_tracker_clear = 1'b0;
        a2_alloc_valid = {A2_NUM_HN{1'b0}};

        cg_always = $test$plusargs("CG_ALWAYS");
        wait_cycles(10);
        rstn = 1'b1;
        wait_cycles(10);
        if (cg_always)
            csr_write64(8'h00, 64'h0000_0006);

        if ($test$plusargs("T31_ONLY")) begin
            rv32_sparse_store_lane_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T31 (T31_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("SNTXN_ONLY")) begin
            sn_txnid_unique_read_during_write_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T43 (SNTXN_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("EVW_ONLY")) begin
            p0_evict_during_write_burst_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T44 (EVW_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("DVM_ONLY")) begin
            dual_core_dvm_broadcast_check();
            if (test_failed) disable main_test;
            dvm_b8_flow_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T26,T55 (DVM_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("SYSCO_ONLY")) begin
            sysco_leave_domain_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T57 (SYSCO_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("MU_ONLY")) begin
            mk_unique_compack_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T56 (MU_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("FWD_ONLY")) begin
            dual_core_direct_snpresp_fwd_check();
            if (test_failed) disable main_test;
            dual_core_snpresp_fwd_no_home_copy_check();
            if (test_failed) disable main_test;
            dat_opcode_legality_check();
            if (test_failed) disable main_test;
            dct_home_nid_identity_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T36..T39 (FWD_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("XR_ONLY")) begin
            exclusive_strex_race_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T54 (XR_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("MW_ONLY")) begin
            hn_multi_write_outstanding_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T53 (MW_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("RAW_ONLY")) begin
            hn_read_after_write_hazard_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T52 (RAW_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("VIC_ONLY")) begin
            a1_victim_snoop_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T51 (VIC_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("A1_ONLY")) begin
            a1_local_hit_check();
            if (test_failed) disable main_test;
            a1_writeback_owner_check();
            if (test_failed) disable main_test;
            a1_dirty_partial_write_check();
            if (test_failed) disable main_test;
            a1_dirty_read_unique_check();
            if (test_failed) disable main_test;
            a1_victim_snoop_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T47..T51 (A1_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("LLC_ONLY")) begin
            p0_llc_stale_after_write_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T46 (LLC_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("BIST_ONLY")) begin
            bist_init_busy_reject_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T45 (BIST_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("WDOG_ONLY")) begin
            watchdog_slow_memory_read_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T42 (WDOG_ONLY)", $time);
            $finish;
        end

        if ($test$plusargs("P0_ONLY")) begin
            p0_sf_shared_sharer_retained_check();
            if (test_failed) disable main_test;
            p0_concurrent_writeback_data_check();
            if (test_failed) disable main_test;
            $display("[%0t] REGRESSION PASS tb_CHI tests=T40..T41 (P0_ONLY)", $time);
            $finish;
        end

        hn_dat_round_robin_reset_check();
        if (test_failed) disable main_test;

        csr_programmability_check();
        if (test_failed) disable main_test;

        irq_ecc_double_w1c_check();
        if (test_failed) disable main_test;

        tb_test_start("T04_SMOKE_READ_SHARED_SN_MISS",
                      "cpu_read_check",
                      "ReadShared miss must fetch one line from SN/AXI and return expected data");
        cpu_read_check(TEST_ADDR0,
                       `CHI_CPU_OP_RD_SHARED,
                       mem_pattern(TEST_ADDR0, 0),
                       "ReadShared miss through SN");
        if (test_failed) disable main_test;
        tb_test_pass("ReadShared miss returned expected SN data");

        wait_cycles(20);
        watchdog_i = axi_ar_count;
        tb_test_start("T05_COH_READ_SHARED_LLC_HIT",
                      "cpu_read_check",
                      "Repeated ReadShared to filled line must hit LLC without new AXI AR");
        cpu_read_check(TEST_ADDR0,
                       `CHI_CPU_OP_RD_SHARED,
                       mem_pattern(TEST_ADDR0, 0),
                       "ReadShared LLC hit");
        if (test_failed) disable main_test;
        if (axi_ar_count != watchdog_i) begin
            $display("[%0t] TEST STEP  %0s task=%0s expected no new AXI_AR before=%0d after=%0d",
                     $time, current_test_id, current_task_name,
                     watchdog_i, axi_ar_count);
            tb_fail("Unexpected AXI AR on LLC hit");
            disable main_test;
        end
        tb_test_pass("LLC hit reused cached line with no new AXI AR");

        tb_test_start("T06_SMOKE_READ_UNIQUE_SN_MISS",
                      "cpu_read_check",
                      "ReadUnique miss must fetch from SN/AXI and return expected data");
        cpu_read_check(TEST_ADDR1,
                       `CHI_CPU_OP_RD_UNIQUE,
                       mem_pattern(TEST_ADDR1, 0),
                       "ReadUnique miss through SN");
        if (test_failed) disable main_test;
        tb_test_pass("ReadUnique miss returned expected SN data");

        tb_test_start("T07_SMOKE_WRITEBACK_FULL_SN",
                      "cpu_write_check",
                      "WriteBackFull must issue one AXI AW, 16 W beats, and one B response");
        cpu_write_check(TEST_ADDR2,
                        `CHI_CPU_OP_WB_FULL,
                        WRITE_DATA0,
                        "WriteBackFull through SN");
        if (test_failed) disable main_test;
        tb_test_pass("WriteBackFull completed through SN/AXI");

        watchdog_i = axi_ar_count;
        tb_test_start("T08_COH_READ_AFTER_WRITEBACK_SN",
                      "cpu_read_check",
                      "Read after WriteBackFull must fetch written data from AXI shadow memory");
        cpu_read_check(TEST_ADDR2,
                       `CHI_CPU_OP_RD_SHARED,
                       WRITE_DATA0,
                       "ReadShared after writeback through SN");
        if (test_failed) disable main_test;
        if (axi_ar_count != (watchdog_i + 1)) begin
            tb_fail("Expected AXI AR for first read after writeback");
            disable main_test;
        end
        tb_test_pass("Read after writeback observed one AXI AR and matching data");

        wait_cycles(20);
        watchdog_i = axi_ar_count;
        tb_test_start("T09_COH_POST_WRITE_LLC_HIT",
                      "cpu_read_check",
                      "Second read after writeback refill must hit LLC with no new AXI AR");
        cpu_read_check(TEST_ADDR2,
                       `CHI_CPU_OP_RD_SHARED,
                       WRITE_DATA0,
                       "ReadShared post-write LLC hit");
        if (test_failed) disable main_test;
        if (axi_ar_count != watchdog_i) begin
            tb_fail("Unexpected AXI AR on post-write LLC hit");
            disable main_test;
        end
        tb_test_pass("Post-write LLC hit reused filled line with no new AXI AR");

        llc_dirty_evict_check();
        if (test_failed) disable main_test;

        llc_clean_evict_check();
        if (test_failed) disable main_test;

        llc_dirty_evict_concurrent_write_check();
        if (test_failed) disable main_test;

        hn_dat_round_robin_check();
        if (test_failed) disable main_test;

        a2_dbid_cross_hn_uniqueness_check();
        if (test_failed) disable main_test;

        exclusive_ldrex_strex_success_check();
        if (test_failed) disable main_test;

        exclusive_hn_invalidation_strex_fail_check();
        if (test_failed) disable main_test;

        exclusive_aging_timeout_strex_fail_check();
        if (test_failed) disable main_test;

        exclusive_timeout_zero_clamp_check();
        if (test_failed) disable main_test;

        iot_axi_backpressure_check();
        if (test_failed) disable main_test;

        iot_idle_wake_clock_gate_check();
        if (test_failed) disable main_test;

        iot_reset_mid_transaction_check();
        if (test_failed) disable main_test;

        dual_core_rn1_read_check();
        if (test_failed) disable main_test;

        dual_core_rn1_writeback_check();
        if (test_failed) disable main_test;

        dual_core_same_line_rw_check();
        if (test_failed) disable main_test;

        dual_core_dirty_snoop_invalidate_check();
        if (test_failed) disable main_test;

        dual_core_dvm_broadcast_check();
        if (test_failed) disable main_test;

        dual_core_exclusive_cross_invalidate_check();
        if (test_failed) disable main_test;

        dual_core_backpressure_concurrent_check();
        if (test_failed) disable main_test;

        random_axi_backpressure_dual_mix_check();
        if (test_failed) disable main_test;

        random_axi_backpressure_multiseed_check();
        if (test_failed) disable main_test;

        rv32_sparse_store_lane_check();
        if (test_failed) disable main_test;

        watchdog_i = axi_ar_count;
        tb_test_start("T32_SOC_RN_COH_8000_ROUTE_HN",
                      "soc_cacheable_high_addr_route_check",
                      "RN coherent ReadShared at 0x8000_0000 window must route through HN, not direct SN");
        cpu_read_check(SOC_CACHEABLE_HIGH_ADDR,
                       `CHI_CPU_OP_RD_SHARED,
                       mem_pattern(SOC_CACHEABLE_HIGH_ADDR, 0),
                       "ReadShared high cacheable SoC address");
        if (test_failed) disable main_test;
        if (axi_ar_count != (watchdog_i + 1)) begin
            tb_fail("Expected one AXI AR behind HN for high cacheable SoC read");
            disable main_test;
        end
        tb_test_pass("High cacheable SoC address completed through HN/SN path");

        hn_slots_overlap_prefetch_check();
        if (test_failed) disable main_test;

        hn_slots_same_line_hazard_check();
        if (test_failed) disable main_test;

        hn_retry_pcredit_write_check();
        if (test_failed) disable main_test;

        dual_core_direct_snpresp_fwd_check();
        if (test_failed) disable main_test;

        dual_core_snpresp_fwd_no_home_copy_check();
        if (test_failed) disable main_test;

        dat_opcode_legality_check();
        if (test_failed) disable main_test;

        dct_home_nid_identity_check();
        if (test_failed) disable main_test;

        p0_sf_shared_sharer_retained_check();
        if (test_failed) disable main_test;

        p0_concurrent_writeback_data_check();
        if (test_failed) disable main_test;

        watchdog_slow_memory_read_check();
        if (test_failed) disable main_test;

        sn_txnid_unique_read_during_write_check();
        if (test_failed) disable main_test;

        p0_evict_during_write_burst_check();
        if (test_failed) disable main_test;

        bist_init_busy_reject_check();
        if (test_failed) disable main_test;

        p0_llc_stale_after_write_check();
        if (test_failed) disable main_test;

        a1_local_hit_check();
        if (test_failed) disable main_test;

        a1_writeback_owner_check();
        if (test_failed) disable main_test;

        a1_dirty_partial_write_check();
        if (test_failed) disable main_test;

        a1_dirty_read_unique_check();
        if (test_failed) disable main_test;

        a1_victim_snoop_check();
        if (test_failed) disable main_test;

        hn_read_after_write_hazard_check();
        if (test_failed) disable main_test;

        hn_multi_write_outstanding_check();
        if (test_failed) disable main_test;

        exclusive_strex_race_check();
        if (test_failed) disable main_test;

        dvm_b8_flow_check();
        if (test_failed) disable main_test;

        mk_unique_compack_check();
        if (test_failed) disable main_test;

        sysco_leave_domain_check();
        if (test_failed) disable main_test;

        wait_cycles(20);
        if (!test_failed) begin
            $display("[%0t] REGRESSION PASS tb_CHI tests=T01..T57 cg_always=%0d cg_gated_cycles=%0d AR=%0d R=%0d AW=%0d W=%0d B=%0d",
                     $time, cg_always, cg_gated_cycles,
                     axi_ar_count_base + axi_ar_count,
                     axi_r_count_base + axi_r_count,
                     axi_aw_count_base + axi_aw_count,
                     axi_w_count_base + axi_w_count,
                     axi_b_count_base + axi_b_count);
        end
        $finish;
    end

    // Debug-only DAT/W beat trace, enabled with +TRACE_WDAT.
    always @(posedge clk) begin
        if (rstn && $test$plusargs("TRACE_WDAT")) begin
            if (dut.rn_tx_dat_valid[0])
                $display("[%0t] TRACE RN0_TXDAT be=%b data=0x%08h", $time,
                         dut.rn_tx_dat_flit[`CHI_DAT_BE_LSB(DAT_DATA_W,NODE_ID_W) +: BE_W],
                         dut.rn_tx_dat_flit[`CHI_DAT_DATA_LSB(DAT_DATA_W,NODE_ID_W) +: DATA_WIDTH]);
            if (dut.gen_hn[0].u_hn_f.mem_dat_valid && dut.gen_hn[0].u_hn_f.mem_dat_ready)
                $display("[%0t] TRACE HN_MEMDAT be=%b data=0x%08h", $time,
                         dut.gen_hn[0].u_hn_f.mem_dat_flit[`CHI_DAT_BE_LSB(DAT_DATA_W,NODE_ID_W) +: BE_W],
                         dut.gen_hn[0].u_hn_f.mem_dat_flit[`CHI_DAT_DATA_LSB(DAT_DATA_W,NODE_ID_W) +: DATA_WIDTH]);
            if (axi_wvalid[0] && axi_wready[0])
                $display("[%0t] TRACE AXI_W strb=%b data=0x%08h last=%b", $time,
                         axi_wstrb[BE_W-1:0], axi_wdata[DATA_WIDTH-1:0], axi_wlast[0]);
        end
    end

    always @(posedge clk) begin
        if (rstn && chi_irq && !allow_chi_irq)
            tb_fail("Unexpected CHI IRQ during smoke test");
    end

    generate
        for (a2_hn_g = 0; a2_hn_g < A2_NUM_HN; a2_hn_g = a2_hn_g + 1) begin : gen_a2_dbid_tracker
            localparam [TXN_ID_W-1:0] A2_ALLOC_TXN_ID = 12'h120 + a2_hn_g;
            localparam [ADDR_WIDTH-1:0] A2_ALLOC_ADDR =
                32'h0000_7000 + (a2_hn_g << 12);
            localparam [NODE_ID_W-1:0] A2_MEM_TGT_ID = 7'd2;

            chi_hn_write_tracker #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .NODE_ID_W(NODE_ID_W),
                .TXN_ID_W(TXN_ID_W),
                .QOS_W(QOS_W),
                .DBID_W(DBID_W),
                .DEPTH(A2_TRACKER_DEPTH),
                .HN_BANK_BITS(A2_HN_BANK_BITS),
                .HN_BANK_ID(a2_hn_g)
            ) u_a2_wr_tracker (
                .clk(clk),
                .rstn(rstn),
                .clear(a2_tracker_clear),
                .alloc_valid(a2_alloc_valid[a2_hn_g]),
                .alloc_ready(a2_alloc_ready[a2_hn_g]),
                .alloc_txn_id(A2_ALLOC_TXN_ID),
                .alloc_src_id({NODE_ID_W{1'b0}}),
                .alloc_qos({QOS_W{1'b0}}),
                .alloc_resp_err(`CHI_RESPERR_OK),
                .alloc_addr(A2_ALLOC_ADDR),
                .alloc_mem_tgt_id(A2_MEM_TGT_ID),
                .alloc_dbid(a2_alloc_dbid[a2_hn_g*DBID_W +: DBID_W]),
                .alloc_mem_txn_id(),
                .comp_valid(1'b0),
                .comp_ready(),
                .comp_txn_id({TXN_ID_W{1'b0}}),
                .comp_src_id({NODE_ID_W{1'b0}}),
                .comp_match(),
                .wdat_dbid({DBID_W{1'b0}}),
                .wdat_src_id({NODE_ID_W{1'b0}}),
                .wdat_txn_id({TXN_ID_W{1'b0}}),
                .wdat_match(),
                .wdat_mem_txn_id(),
                .wdat_mem_tgt_id(),
                .rsp_valid(),
                .rsp_ready(1'b1),
                .rsp_txn_id(),
                .rsp_tgt_id(),
                .rsp_qos(),
                .rsp_resp_err(),
                .active_valid_vec(a2_active_valid_vec[a2_hn_g*A2_TRACKER_DEPTH +: A2_TRACKER_DEPTH]),
                .active_addr_flat(),
                .used_count(a2_used_count[a2_hn_g*16 +: 16])
            );
        end
    endgenerate

    chi_top #(
        .NUM_RN(NUM_RN),
        .NUM_HN(NUM_HN),
        .NUM_SN(NUM_SN),
        .NUM_MN(NUM_MN),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(DBID_W),
        .INIT_CRD(2),
        .HN_POS_DEPTH(4),
        .HN_SF_ENTRIES(64),
        .HN_LLC_LINES(64),
        .HN_LLC_WAYS(4),
        .HN_WRITE_TRACKER_DEPTH(2),
        .HN_READ_TRACKER_DEPTH(2),
        .HN_SNOOP_TRACKER_DEPTH(2),
        .RN_CACHE_LINES(8),
        .RN_TXN_TBL_SIZE(4),
        .FABRIC_FIFO_DEPTH(2),
        .ENABLE_PERF(1),
        .HN_ENABLE_LLC_ECC(0),
        .FABRIC_OUTPUT_FIFO_DEPTH(1),
        .ENABLE_QOS_AGING(0)
    ) dut (
        .clk(clk),
        .rstn(rstn),

        .csr_valid(csr_valid),
        .csr_write(csr_write),
        .csr_addr(csr_addr),
        .csr_wdata(csr_wdata),
        .csr_ready(csr_ready),
        .csr_rdata(csr_rdata),
        .chi_irq(chi_irq),

        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_op(cpu_req_op),
        .cpu_req_size(cpu_req_size),
        .cpu_req_qos(cpu_req_qos),
        .cpu_req_tag(cpu_req_tag),
        .cpu_wdata(cpu_wdata),
        .cpu_wdata_line(cpu_wdata_line),
        .cpu_wstrb_line(cpu_wstrb_line),
        .cpu_rdata(cpu_rdata),
        .cpu_resp_valid(cpu_resp_valid),
        .cpu_resp_tag(cpu_resp_tag),
        .cpu_resp_line_valid(cpu_resp_line_valid),
        .cpu_resp_line_data(cpu_resp_line_data),
        .cpu_resp_line_tag(cpu_resp_line_tag),

        .l1_snoop_valid(),
        .l1_snoop_ready({NUM_RN{1'b1}}),
        .l1_snoop_invalidate(),
        .l1_snoop_addr(),
        .l1_snoop_result_valid({NUM_RN{1'b0}}),
        .l1_snoop_hit({NUM_RN{1'b0}}),
        .l1_snoop_dirty({NUM_RN{1'b0}}),
        .l1_snoop_data({NUM_RN*64*8{1'b0}}),

        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_araddr(axi_araddr),
        .axi_arsize(axi_arsize),
        .axi_arlen(axi_arlen),
        .axi_arburst(axi_arburst),
        .axi_rvalid(axi_rvalid),
        .axi_rready(axi_rready),
        .axi_rdata(axi_rdata),
        .axi_rresp(axi_rresp),

        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_awaddr(axi_awaddr),
        .axi_awsize(axi_awsize),
        .axi_awlen(axi_awlen),
        .axi_awburst(axi_awburst),
        .axi_wvalid(axi_wvalid),
        .axi_wready(axi_wready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wlast(axi_wlast),
        .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_bresp(axi_bresp)
    );

`ifdef TB_CHI_TRACE
    always @(posedge clk) begin
        if (rstn) begin
            if (cpu_req_valid[0] && cpu_req_ready[0])
                $display("[%0t] TRACE CPU_REQ op=0x%0h addr=0x%011h",
                         $time, cpu_req_op[3:0],
                         cpu_req_addr[ADDR_WIDTH-1:0]);

            if (dut.gen_rn[0].u_rn_f.tx_req_valid)
                $display("[%0t] TRACE RN_TX_REQ txn=0x%0h",
                         $time,
                         dut.gen_rn[0].u_rn_f.req_engine_valid ?
                         dut.gen_rn[0].u_rn_f.tx_req_flit[`CHI_REQ_TXN_LSB(NODE_ID_W) +: TXN_ID_W] :
                         {TXN_ID_W{1'b0}});

            if (dut.gen_rn[0].u_rn_f.u_tx_req_link.u_tx.hold_valid_q ||
                dut.gen_rn[0].u_rn_f.u_tx_req_link.u_tx.take ||
                dut.gen_rn[0].u_rn_f.u_tx_req_link.u_tx.send)
                $display("[%0t] TRACE RN_REQ_LINK hold=%0b in_v=%0b in_r=%0b lcrdv=%0b accept=%0b launch=%0b credit=%0d cpu_v=%0b evict_v=%0b req_v=%0b retry_v=%0b op=0x%0h addr=0x%011h",
                         $time,
                         dut.gen_rn[0].u_rn_f.u_tx_req_link.u_tx.hold_valid_q,
                         dut.gen_rn[0].u_rn_f.u_tx_req_link.tx_in_valid,
                         dut.gen_rn[0].u_rn_f.u_tx_req_link.tx_in_ready,
                         dut.gen_rn[0].u_rn_f.u_tx_req_link.tx_out_lcrdv,
                         dut.gen_rn[0].u_rn_f.u_tx_req_link.u_tx.take,
                         dut.gen_rn[0].u_rn_f.u_tx_req_link.u_tx.send,
                         dut.gen_rn[0].u_rn_f.u_tx_req_link.credit_count,
                         dut.gen_rn[0].u_rn_f.cpu_req_valid,
                         dut.gen_rn[0].u_rn_f.cache_evict_valid,
                         dut.gen_rn[0].u_rn_f.req_engine_valid,
                         dut.gen_rn[0].u_rn_f.retry_reissue_valid_r,
                         dut.gen_rn[0].u_rn_f.req_opcode,
                         dut.gen_rn[0].u_rn_f.req_engine_input_addr);

            if (dut.gen_hn[0].u_hn_f.rx_req_valid &&
                dut.gen_hn[0].u_hn_f.rx_req_lcrdv)
                $display("[%0t] TRACE HN_RX_REQ state=%0d txn=0x%0h",
                         $time,
                         dut.gen_hn[0].u_hn_f.state_q,
                         dut.gen_hn[0].u_hn_f.rx_req_flit[`CHI_REQ_TXN_LSB(NODE_ID_W) +: TXN_ID_W]);

            if (dut.gen_hn[0].u_hn_f.start_sf_lookup)
                $display("[%0t] TRACE HN_SF_START txn=0x%0h",
                         $time, dut.gen_hn[0].u_hn_f.req_txn_id);

            if (dut.gen_hn[0].u_hn_f.sf_result_valid)
                $display("[%0t] TRACE HN_SF_DONE hit=%0b backinv=%0b",
                         $time,
                         dut.gen_hn[0].u_hn_f.filter_hit,
                         dut.gen_hn[0].u_hn_f.backinv_valid);

            if (dut.gen_hn[0].u_hn_f.start_llc_lookup)
                $display("[%0t] TRACE HN_LLC_START txn=0x%0h",
                         $time, dut.gen_hn[0].u_hn_f.req_txn_id);

            if (dut.gen_hn[0].u_hn_f.llc_lookup_result_valid)
                $display("[%0t] TRACE HN_LLC_DONE hit=%0b",
                         $time, dut.gen_hn[0].u_hn_f.llc_hit);

            if (dut.gen_hn[0].u_hn_f.start_llc_read)
                $display("[%0t] TRACE HN_LLC_READ_HIT txn=0x%0h",
                         $time, dut.gen_hn[0].u_hn_f.req_txn_id);

            if (dut.gen_hn[0].u_hn_f.start_mem_read)
                $display("[%0t] TRACE HN_MEM_READ txn=0x%0h mem_txn=0x%0h",
                         $time,
                         dut.gen_hn[0].u_hn_f.req_txn_id,
                         dut.gen_hn[0].u_hn_f.rd_tracker_alloc_mem_txn_id);

            if (dut.gen_hn[0].u_hn_f.mem_req_valid &&
                dut.gen_hn[0].u_hn_f.mem_req_ready)
                $display("[%0t] TRACE HN_MEM_REQ_FIRE txn=0x%0h",
                         $time,
                         dut.gen_hn[0].u_hn_f.mem_req_flit[`CHI_REQ_TXN_LSB(NODE_ID_W) +: TXN_ID_W]);

            if (dut.gen_sn[0].u_sn_f.rx_req_valid &&
                dut.gen_sn[0].u_sn_f.rx_req_lcrdv)
                $display("[%0t] TRACE SN_RX_REQ_ACCEPT txn=0x%0h",
                         $time,
                         dut.gen_sn[0].u_sn_f.rx_req_flit[`CHI_REQ_TXN_LSB(NODE_ID_W) +: TXN_ID_W]);

            if (dut.gen_sn[0].u_sn_f.reqbuf_valid &&
                dut.gen_sn[0].u_sn_f.reqbuf_out_ready)
                $display("[%0t] TRACE SN_REQBUF_POP txn=0x%0h",
                         $time,
                         dut.gen_sn[0].u_sn_f.reqbuf_flit[`CHI_REQ_TXN_LSB(NODE_ID_W) +: TXN_ID_W]);

            if (dut.gen_sn[0].u_sn_f.u_axi_bridge.read_start_fire)
                $display("[%0t] TRACE SN_AXI_AR_START txn=0x%0h",
                         $time,
                         dut.gen_sn[0].u_sn_f.reqbuf_flit[`CHI_REQ_TXN_LSB(NODE_ID_W) +: TXN_ID_W]);

            if (dut.gen_sn[0].u_sn_f.tx_dat_valid ||
                dut.gen_hn[0].u_hn_f.rx_dat_valid ||
                dut.gen_hn[0].u_hn_f.dat_sink_valid)
                $display("[%0t] TRACE DAT_PIPE sn_v=%0b sn_lcrdv=%0b sn_id=%0d hn_rx_v=%0b hn_rx_rdy=%0b hn_lcrdv=%0b sink_in_rdy=%0b sink_v=%0b sink_rdy=%0b cap=%0b rd_match=%0b rd_rdy=%0b sink_id=%0d rd_state0=%0d rd_mask0=0x%0h sink_used=%0d",
                         $time,
                         dut.gen_sn[0].u_sn_f.tx_dat_valid,
                         dut.gen_sn[0].u_sn_f.tx_dat_lcrdv,
                         dut.gen_sn[0].u_sn_f.tx_dat_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W],
                         dut.gen_hn[0].u_hn_f.rx_dat_valid,
                         dut.gen_hn[0].u_hn_f.rx_dat_ready,
                         dut.gen_hn[0].u_hn_f.rx_dat_lcrdv,
                         dut.gen_hn[0].u_hn_f.dat_sink_in_ready,
                         dut.gen_hn[0].u_hn_f.dat_sink_valid,
                         dut.gen_hn[0].u_hn_f.dat_sink_out_ready,
                         dut.gen_hn[0].u_hn_f.dat_sink_valid,
                         dut.gen_hn[0].u_hn_f.rd_tracker_dat_match,
                         dut.gen_hn[0].u_hn_f.rd_tracker_dat_ready,
                         dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W],
                         dut.gen_hn[0].u_hn_f.u_read_tracker.state_q[0],
                         dut.gen_hn[0].u_hn_f.u_read_tracker.beat_mask_q[0],
                         dut.gen_hn[0].u_hn_f.dat_sink_used_unused);

            if (dut.gen_hn[0].u_hn_f.rd_tracker_dat_match &&
                dut.gen_hn[0].u_hn_f.rd_tracker_dat_ready)
                $display("[%0t] TRACE HN_RD_DAT_MATCH txn=0x%0h dataid=%0d",
                         $time,
                         dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W],
                         dut.gen_hn[0].u_hn_f.dat_sink_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W]);

            if (dut.gen_hn[0].u_hn_f.rd_tracker_tx_dat_valid &&
                dut.gen_hn[0].u_hn_f.rd_tracker_tx_dat_ready)
                $display("[%0t] TRACE HN_RD_TX_DAT txn=0x%0h dataid=%0d",
                         $time,
                         dut.gen_hn[0].u_hn_f.rd_tracker_tx_dat_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W],
                         dut.gen_hn[0].u_hn_f.rd_tracker_tx_dat_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W]);

            if (dut.gen_hn[0].u_hn_f.rd_tracker_llc_update_valid ||
                dut.gen_hn[0].u_hn_f.llc_update_valid)
                $display("[%0t] TRACE HN_LLC_UPDATE valid=%0b ready=%0b rd_valid=%0b rd_ready=%0b addr=0x%011h state=%0d",
                         $time,
                         dut.gen_hn[0].u_hn_f.llc_update_valid,
                         dut.gen_hn[0].u_hn_f.llc_line_update_ready,
                         dut.gen_hn[0].u_hn_f.rd_tracker_llc_update_valid,
                         dut.gen_hn[0].u_hn_f.rd_tracker_llc_update_ready,
                         dut.gen_hn[0].u_hn_f.llc_update_addr,
                         dut.gen_hn[0].u_hn_f.llc_update_state);

            if (dut.gen_hn[0].u_hn_f.u_llc.update_commit_fire)
                $display("[%0t] TRACE LLC_UPDATE_COMMIT way=%0d dirty_replace=%0b victim=0x%011h",
                         $time,
                         dut.gen_hn[0].u_hn_f.u_llc.update_way_r,
                         dut.gen_hn[0].u_hn_f.u_llc.update_replaces_valid_dirty,
                         dut.gen_hn[0].u_hn_f.u_llc.update_victim_addr);

            if (dut.gen_hn[0].u_hn_f.llc_evict_capture_fire)
                $display("[%0t] TRACE HN_LLC_EVICT_CAPTURE addr=0x%011h",
                         $time,
                         dut.gen_hn[0].u_hn_f.llc_evict_addr);

            if (dut.gen_hn[0].u_hn_f.llc_evict_req_fire)
                $display("[%0t] TRACE HN_LLC_EVICT_REQ_FIRE addr=0x%011h",
                         $time,
                         dut.gen_hn[0].u_hn_f.llc_evict_addr_q);

            if (dut.gen_hn[0].u_hn_f.llc_evict_dat_fire)
                $display("[%0t] TRACE HN_LLC_EVICT_DAT beat=%0d",
                         $time,
                         dut.gen_hn[0].u_hn_f.llc_evict_beat_q);

            if (dut.gen_hn[0].u_hn_f.llc_evict_comp_fire)
                $display("[%0t] TRACE HN_LLC_EVICT_COMP", $time);

            if (dut.gen_hn[0].u_hn_f.resp_dat_fire)
                $display("[%0t] TRACE HN_SCALAR_DAT_FIRE txn=0x%0h dataid=%0d",
                         $time,
                         dut.gen_hn[0].u_hn_f.resp_dat_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W],
                         dut.gen_hn[0].u_hn_f.resp_dat_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W]);

            if (dut.gen_hn[0].u_hn_f.tx_dat_valid)
                $display("[%0t] TRACE HN_TX_DAT_ACCEPT txn=0x%0h dataid=%0d",
                         $time,
                         dut.gen_hn[0].u_hn_f.tx_dat_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W],
                         dut.gen_hn[0].u_hn_f.tx_dat_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W]);

            if (dut.gen_rn[0].u_rn_f.rx_dat_valid &&
                dut.gen_rn[0].u_rn_f.rx_dat_lcrdv)
                $display("[%0t] TRACE RN_RX_DAT_ACCEPT txn=0x%0h dataid=%0d",
                         $time,
                         dut.gen_rn[0].u_rn_f.rx_dat_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W],
                         dut.gen_rn[0].u_rn_f.rx_dat_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W]);

            if (dut.gen_rn[0].u_rn_f.rsp_dbid_valid)
                $display("[%0t] TRACE RN_DBID txn=0x%0h dbid=0x%0h src=0x%0h match=%0b wvalid=%0b",
                         $time,
                         dut.gen_rn[0].u_rn_f.rsp_txn_id,
                         dut.gen_rn[0].u_rn_f.rsp_dbid,
                         dut.gen_rn[0].u_rn_f.rsp_src_id,
                         dut.gen_rn[0].u_rn_f.rsp_dbid_match_valid,
                         dut.gen_rn[0].u_rn_f.wdata_valid_mem[
                             dut.gen_rn[0].u_rn_f.rsp_txn_idx]);

            if (dut.gen_rn[0].u_rn_f.rx_rsp_valid &&
                dut.gen_rn[0].u_rn_f.rx_rsp_lcrdv)
                $display("[%0t] TRACE RN_RX_RSP_ACCEPT opc=0x%0h txn=0x%0h",
                         $time,
                         dut.gen_rn[0].u_rn_f.rx_rsp_flit[`CHI_RSP_OPCODE_LSB(NODE_ID_W) +: `CHI_RSP_OPCODE_W],
                         dut.gen_rn[0].u_rn_f.rx_rsp_flit[`CHI_RSP_TXN_LSB(NODE_ID_W) +: TXN_ID_W]);

            if (dut.gen_rn[0].u_rn_f.rsp_retry_ack_valid ||
                dut.gen_rn[0].u_rn_f.rsp_pcrd_grant_valid)
                $display("[%0t] TRACE RN_RETRY_RSP ack=%0b grant=%0b txn=0x%0h touch=%0b mem_ack=0x%0h mem_grant=0x%0h",
                         $time,
                         dut.gen_rn[0].u_rn_f.rsp_retry_ack_valid,
                         dut.gen_rn[0].u_rn_f.rsp_pcrd_grant_valid,
                         dut.gen_rn[0].u_rn_f.rsp_txn_id,
                         dut.gen_rn[0].u_rn_f.rsp_retry_touch_match_valid,
                         dut.gen_rn[0].u_rn_f.retry_ack_mem,
                         dut.gen_rn[0].u_rn_f.retry_grant_mem);

            if (dut.gen_rn[0].u_rn_f.pending_wdat_valid_q)
                $display("[%0t] TRACE RN_PENDING_WDAT txn=0x%0h dbid=0x%0h ready=%0b accept=%0b",
                         $time,
                         dut.gen_rn[0].u_rn_f.pending_wdat_txn_q,
                         dut.gen_rn[0].u_rn_f.pending_wdat_dbid_q,
                         dut.gen_rn[0].u_rn_f.wdat_engine_ready,
                         dut.gen_rn[0].u_rn_f.wdat_accept);

            if (dut.gen_rn[0].u_rn_f.tx_dat_link_valid)
                $display("[%0t] TRACE RN_TX_DAT_LINK txn=0x%0h dbid=0x%0h dataid=%0d ready=%0b",
                         $time,
                         dut.gen_rn[0].u_rn_f.tx_dat_link_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W],
                         dut.gen_rn[0].u_rn_f.tx_dat_link_flit[`CHI_DAT_DBID_LSB(DAT_DATA_W,NODE_ID_W) +: DBID_W],
                         dut.gen_rn[0].u_rn_f.tx_dat_link_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W],
                         dut.gen_rn[0].u_rn_f.tx_dat_link_ready);

            if (dut.gen_hn[0].u_hn_f.dat_sink_valid &&
                dut.gen_hn[0].u_hn_f.dat_is_wdat)
                $display("[%0t] TRACE HN_WDAT_SINK txn=0x%0h dbid=0x%0h dataid=%0d match=%0b ready=%0b evict_dat=%0b mem_ready=%0b",
                         $time,
                         dut.gen_hn[0].u_hn_f.dat_txn_id,
                         dut.gen_hn[0].u_hn_f.dat_dbid,
                         dut.gen_hn[0].u_hn_f.dat_data_id,
                         dut.gen_hn[0].u_hn_f.wr_tracker_wdat_match,
                         dut.gen_hn[0].u_hn_f.dat_sink_out_ready,
                         dut.gen_hn[0].u_hn_f.llc_evict_dat_valid,
                         dut.gen_hn[0].u_hn_f.mem_dat_ready);

            if (dut.gen_sn[0].u_sn_f.wbuf_valid)
                $display("[%0t] TRACE SN_WDAT_BUF txn=0x%0h dataid=%0d ready=%0b",
                         $time,
                         dut.gen_sn[0].u_sn_f.wbuf_flit[`CHI_DAT_TXN_LSB(DAT_DATA_W,NODE_ID_W) +: TXN_ID_W],
                         dut.gen_sn[0].u_sn_f.wbuf_flit[`CHI_DAT_DATAID_LSB(DAT_DATA_W,NODE_ID_W) +: `CHI_DAT_DATAID_W],
                         dut.gen_sn[0].u_sn_f.bridge_wdat_ready);

            if (dut.gen_hn[0].u_hn_f.state_timeout_fire)
                $display("[%0t] TRACE HN_TIMEOUT state=%0d txn=0x%0h",
                         $time,
                         dut.gen_hn[0].u_hn_f.state_q,
                         dut.gen_hn[0].u_hn_f.req_txn_id);

            if (dut.gen_rn[0].u_rn_f.dat_line_valid_unused)
                $display("[%0t] TRACE RN_LINE_DONE txn=0x%0h match=%0b",
                         $time,
                         dut.gen_rn[0].u_rn_f.dat_txn_id,
                         dut.gen_rn[0].u_rn_f.dat_txn_match);

            if (dut.gen_rn[0].u_rn_f.timeout_valid)
                $display("[%0t] TRACE RN_TIMEOUT txn=0x%0h",
                         $time, dut.gen_rn[0].u_rn_f.timeout_txn_id);
        end
    end
`endif

    // Coherence scoreboard (roadmap 4.1).
    localparam integer SB_RN_CACHE_LINES = 8;
    localparam integer SB_SF_ENTRIES     = 64;
    `include "chi_coherence_scoreboard.svh"
endmodule

module tb_CHI_a2_dbid_width_neg;
    localparam integer ADDR_WIDTH = 32;
    localparam integer NODE_ID_W  = 7;
    localparam integer TXN_ID_W   = 12;
    localparam integer QOS_W      = 4;
    localparam integer BAD_DBID_W = 4;
    localparam integer BAD_DEPTH  = 2;
    localparam integer BAD_HN_BANK_BITS = 4;

    reg clk;
    reg rstn;

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rstn = 1'b1;
        $display("[%0t] TEST START T15_A2_DBID_WIDTH_NEG task=tb_CHI_a2_dbid_width_neg purpose=Expect [A2 FATAL] when DBID_W is too small for HN bank plus slot ID",
                 $time);
        #100;
        $display("[%0t] TEST FAIL  T15_A2_DBID_WIDTH_NEG task=tb_CHI_a2_dbid_width_neg reason=Expected chi_hn_write_tracker [A2 FATAL] did not fire",
                 $time);
        $finish;
    end

    chi_hn_write_tracker #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NODE_ID_W(NODE_ID_W),
        .TXN_ID_W(TXN_ID_W),
        .QOS_W(QOS_W),
        .DBID_W(BAD_DBID_W),
        .DEPTH(BAD_DEPTH),
        .HN_BANK_BITS(BAD_HN_BANK_BITS),
        .HN_BANK_ID(1)
    ) u_bad_dbid_tracker (
        .clk(clk),
        .rstn(rstn),
        .clear(1'b0),
        .alloc_valid(1'b0),
        .alloc_ready(),
        .alloc_txn_id({TXN_ID_W{1'b0}}),
        .alloc_src_id({NODE_ID_W{1'b0}}),
        .alloc_qos({QOS_W{1'b0}}),
        .alloc_resp_err(`CHI_RESPERR_OK),
        .alloc_addr({ADDR_WIDTH{1'b0}}),
        .alloc_mem_tgt_id({NODE_ID_W{1'b0}}),
        .alloc_dbid(),
        .alloc_mem_txn_id(),
        .comp_valid(1'b0),
        .comp_ready(),
        .comp_txn_id({TXN_ID_W{1'b0}}),
        .comp_src_id({NODE_ID_W{1'b0}}),
        .comp_match(),
        .wdat_dbid({BAD_DBID_W{1'b0}}),
        .wdat_src_id({NODE_ID_W{1'b0}}),
        .wdat_txn_id({TXN_ID_W{1'b0}}),
        .wdat_match(),
        .wdat_mem_txn_id(),
        .wdat_mem_tgt_id(),
        .rsp_valid(),
        .rsp_ready(1'b1),
        .rsp_txn_id(),
        .rsp_tgt_id(),
        .rsp_qos(),
        .rsp_resp_err(),
        .active_valid_vec(),
        .active_addr_flat(),
        .used_count()
    );
endmodule
