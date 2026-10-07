`timescale 1ns/1ps

`ifndef CHI_DEFS_VH
`define CHI_DEFS_VH

// DATA_W is the CPU word and SN AXI width. DAT_DATA_W is the CHI DAT
// channel data width (IHI0050H B13.9.4: 128, 256 or 512), so a 64-byte
// line is 4 DAT beats at 128 bits; the SN converts between the two.
// Default fabric parameters. The normal compile-check profile targets a
// dual-core IoT configuration: 2 RN-F CPU ports sharing one HN-F, one SN-F,
// and one MN. Define CHI_FULL_PROFILE, or override top-level parameters, for
// the larger review configuration.
`ifdef CHI_FULL_PROFILE
`define CHI_DEFAULT_NUM_RN       2
`define CHI_DEFAULT_NUM_HN       3
`define CHI_DEFAULT_NUM_SN       1
`define CHI_DEFAULT_NUM_MN       1
`define CHI_DEFAULT_NUM_TGT      4
`define CHI_DEFAULT_ADDR_W       32
`define CHI_DEFAULT_DATA_W       32
`define CHI_DEFAULT_DAT_DATA_W   128
`define CHI_DEFAULT_NODE_ID_W    7
`define CHI_DEFAULT_TXN_ID_W     12
`define CHI_DEFAULT_QOS_W        4
`define CHI_DEFAULT_DBID_W       12
`define CHI_DEFAULT_INIT_CRD     8
`define CHI_DEFAULT_FIFO_DEPTH   8
`define CHI_DEFAULT_OUTPUT_FIFO_DEPTH 4
`define CHI_DEFAULT_STARV_THRESH 256
`define CHI_DEFAULT_QOS_AGE_SHIFT 4
`define CHI_DEFAULT_QOS_AGE_MAX   255
`define CHI_DEFAULT_POS_DEPTH    16
`define CHI_DEFAULT_SF_ENTRIES   256
`define CHI_DEFAULT_LLC_LINES    256
`define CHI_DEFAULT_LLC_WAYS     16
`define CHI_DEFAULT_HN_WRITE_TRACKER_DEPTH 8
`define CHI_DEFAULT_HN_READ_TRACKER_DEPTH 4
`define CHI_DEFAULT_HN_SNOOP_TRACKER_DEPTH 4
// SN-F write slots: writes the SN holds at once, each with its own DBID
// and line buffer.
`define CHI_DEFAULT_SN_WR_SLOTS 8
`define CHI_DEFAULT_RN_CACHE_LINES 16
`define CHI_DEFAULT_RN_TXN_TBL_SIZE 16
`define CHI_DEFAULT_RN_LINE_BUF_ENTRIES 8
`define CHI_DEFAULT_ENABLE_PERF  1
`define CHI_DEFAULT_ENABLE_LLC_ECC 1
`define CHI_DEFAULT_ENABLE_QOS_AGING 1
`else
`define CHI_DEFAULT_NUM_RN       2
`define CHI_DEFAULT_NUM_HN       1
`define CHI_DEFAULT_NUM_SN       1
`define CHI_DEFAULT_NUM_MN       1
`define CHI_DEFAULT_NUM_TGT      4
`define CHI_DEFAULT_ADDR_W       32
`define CHI_DEFAULT_DATA_W       32
`define CHI_DEFAULT_DAT_DATA_W   128
`define CHI_DEFAULT_NODE_ID_W    7
`define CHI_DEFAULT_TXN_ID_W     12
`define CHI_DEFAULT_QOS_W        4
`define CHI_DEFAULT_DBID_W       12
`define CHI_DEFAULT_INIT_CRD     2
`define CHI_DEFAULT_FIFO_DEPTH   2
`define CHI_DEFAULT_OUTPUT_FIFO_DEPTH 1
`define CHI_DEFAULT_STARV_THRESH 256
`define CHI_DEFAULT_QOS_AGE_SHIFT 4
`define CHI_DEFAULT_QOS_AGE_MAX   255
`define CHI_DEFAULT_POS_DEPTH    4
`define CHI_DEFAULT_SF_ENTRIES   256
`define CHI_DEFAULT_LLC_LINES    64
`define CHI_DEFAULT_LLC_WAYS     4
`define CHI_DEFAULT_HN_WRITE_TRACKER_DEPTH 2
`define CHI_DEFAULT_HN_READ_TRACKER_DEPTH 2
`define CHI_DEFAULT_HN_SNOOP_TRACKER_DEPTH 2
`define CHI_DEFAULT_SN_WR_SLOTS 4
`define CHI_DEFAULT_RN_CACHE_LINES 8
`define CHI_DEFAULT_RN_TXN_TBL_SIZE 4
`define CHI_DEFAULT_RN_LINE_BUF_ENTRIES 4
`define CHI_DEFAULT_ENABLE_PERF  0
`define CHI_DEFAULT_ENABLE_LLC_ECC 0
`define CHI_DEFAULT_ENABLE_QOS_AGING 0
`endif

// Simulation/formal monitors are enabled by default when their files are
// loaded. Define CHI_DISABLE_SIM_ASSERTIONS to compile them out.
`ifndef CHI_DISABLE_SIM_ASSERTIONS
`define CHI_SIM_ASSERTIONS
`endif

// CPU-side operation map used by the simple RN-F ingress.
`define CHI_CPU_OP_RD_SHARED     4'd0
`define CHI_CPU_OP_RD_UNIQUE     4'd1
`define CHI_CPU_OP_EVICT         4'd2
`define CHI_CPU_OP_WB_FULL       4'd3
`define CHI_CPU_OP_MK_UNIQUE     4'd4
`define CHI_CPU_OP_LDREX         4'd5
`define CHI_CPU_OP_STREX         4'd6
`define CHI_CPU_OP_DVM_OP        4'd7
`define CHI_CPU_OP_DVM_SYNC      4'd8
`define CHI_CPU_OP_WR_UNIQUE     4'd9

// Channel identifiers.
`define CHI_CH_REQ 2'd0
`define CHI_CH_RSP 2'd1
`define CHI_CH_SNP 2'd2
`define CHI_CH_DAT 2'd3

// Main REQ opcodes used by the compact IoT RTL profile.
// Values verified 2026-06-20 against the real ARM AMBA CHI Architecture
// Specification, ARM IHI 0050 Issue H (Table B13.12, REQ channel opcodes
// with Opcode[6]=0/1, pp.482-484). Earlier in-repo reviews believed several
// of these were already "Issue-F aligned"; that was incorrect -- they were
// checked against the wrong document number ("DDI0464H", which does not
// match this opcode table) and several values collided with real opcodes
// that mean something else. The flit field layout follows Tables
// B13.6-B13.9 (see "Flit layout" below).
// REQ Opcode is 7 bits (Opcode[6:0]); SNP Opcode is 5 bits.
`define CHI_REQ_OPCODE_W      7
`define CHI_SNP_OPCODE_W      5
`define CHI_REQ_LCRD_RETURN   7'h00  // ReqLCrdReturn (link layer, B13.11)
`define CHI_REQ_RD_NO_SNP     7'h04  // ReadNoSnp
`define CHI_REQ_PCRD_RETURN   7'h05  // PCrdReturn
`define CHI_REQ_RD_ONCE       7'h03  // ReadOnce
`define CHI_REQ_RD_SHARED     7'h01  // ReadShared
`define CHI_REQ_RD_UNIQUE     7'h07  // ReadUnique
`define CHI_REQ_CLN_UNIQUE    7'h0B  // CleanUnique
`define CHI_REQ_MK_UNIQUE     7'h0C  // MakeUnique (was 0x0E -- wrong slot)
`define CHI_REQ_EVICT         7'h0D  // Evict (was 0x12, which is Reserved)
`define CHI_REQ_WB_FULL       7'h1B  // WriteBackFull
`define CHI_REQ_WB_PTL        7'h1A  // WriteBackPtl (was 0x1C, which is WriteNoSnpPtl)
`define CHI_REQ_WR_UNIQUE     7'h18  // WriteUniquePtl (was 0x1A, which is WriteBackPtl)
`define CHI_REQ_WR_NO_SNP     7'h1D  // WriteNoSnpFull (was 0x18, which is WriteUniquePtl)
`define CHI_REQ_DVM_OP        7'h14  // DVMOp (was 0x28, which collides with real AtomicStore)

// RSP opcodes. Verified 2026-06-20 against Table B13.14 (RSP channel
// opcodes, pp.484-485). Issue-H uses Opcode[4:0], so the compact RTL now uses
// the same 5-bit field width. Retry/PCrdGrant are implemented as a single
// generic PCrdType=0 pool in this compact profile.
`define CHI_RSP_OPCODE_W      5
`define CHI_RSP_RESP_LCRD_RETURN 5'h00
`define CHI_RSP_SNP_RESP      5'h01  // SnpResp
`define CHI_RSP_COMP_ACK      5'h02  // CompAck
`define CHI_RSP_RETRY_ACK     5'h03  // RetryAck
`define CHI_RSP_COMP          5'h04  // Comp
`define CHI_RSP_COMP_DBID     5'h05  // CompDBIDResp
`define CHI_RSP_DBID          5'h06  // DBIDResp
`define CHI_RSP_PCRD_GRANT    5'h07  // PCrdGrant
`define CHI_RSP_READ_RECEIPT  5'h08  // ReadReceipt, unsupported in this subset
`define CHI_RSP_SNP_RESP_FWD  5'h09  // SnpRespFwded

// DAT opcodes used by the compact profile. Verified 2026-06-20 against
// Table B13.16 (DAT channel opcodes, p.486). This field is 4 bits wide,
// matching the real spec's DAT Opcode[3:0] exactly -- only values needed
// correction, not field width.
`define CHI_DAT_QOS_W          4
`define CHI_DAT_OPCODE_LCRD_RETURN 4'h0 // DataLCrdReturn (link layer, B13.11)
`define CHI_DAT_OPCODE_RD_DATA 4'h4  // CompData (was 0x1, which is SnpRespData)
`define CHI_DAT_OPCODE_WDAT    4'h2  // CopyBackWriteData (already correct)
`define CHI_DAT_OPCODE_SNP_DATA 4'h1 // SnpRespData (was 0x3, which is NonCopyBackWriteData)
`define CHI_DAT_OPCODE_WB_DATA 4'h3  // NonCopyBackWriteData (was 0x4, which is CompData)
`define CHI_DAT_OPCODE_SNP_DATA_FWD 4'h6 // SnpRespDataFwded

// SNP opcodes used by the compact RTL profile. Verified 2026-06-20
// against Table B13.15 (SNP channel opcodes, pp.485-486).
`define CHI_SNP_LCRD_RETURN   5'h00  // SnpLCrdReturn (link layer, B13.11)
`define CHI_SNP_SHARED        5'h01  // SnpShared
`define CHI_SNP_UNIQUE        5'h07  // SnpUnique
// Real CHI has no opcode literally named "SnpInvalid". The closest real
// semantic match for "force invalidate, no data expected back" is
// SnpMakeInvalid. (Was 0x0D, which is actually SnpDVMOp.)
`define CHI_SNP_INVALID       5'h0A  // SnpMakeInvalid
`define CHI_SNP_DVM_OP        5'h0D  // SnpDVMOp (was 0x0E, which is Reserved)
`define CHI_SNP_SHARED_FWD    5'h11  // SnpSharedFwd
`define CHI_SNP_UNIQUE_FWD    5'h17  // SnpUniqueFwd

// CompData Resp (IHI0050H Table B13.35): the state the requester gets.
// Resp[2] is PassDirty.
`define CHI_COMPDATA_RESP_I     3'b000
`define CHI_COMPDATA_RESP_SC    3'b001
`define CHI_COMPDATA_RESP_UC    3'b010
`define CHI_COMPDATA_RESP_UD_PD 3'b110
`define CHI_COMPDATA_RESP_SD_PD 3'b111
// SnpResp*/SnpRespData* Resp: snoopee final state, Resp[2] = PassDirty
// (Table B13.34). I and SC share the CompData codes.
`define CHI_SNPRESP_SD          3'b011
`define CHI_SNPRESP_I_PD        3'b100
`define CHI_SNPRESP_SC_PD       3'b101
// SnpRespFwded/SnpRespDataFwded FwdState: the CompData Resp the snoopee
// sent to the requester (Table B13.37), so it uses the CompData codes.
// CompData Resp for a read opcode when the home returns clean data.
`define CHI_COMPDATA_RESP_FOR(OP) \
    (((OP) == `CHI_REQ_RD_UNIQUE) ? `CHI_COMPDATA_RESP_UC : \
     (((OP) == `CHI_REQ_RD_SHARED) ? `CHI_COMPDATA_RESP_SC : \
      `CHI_COMPDATA_RESP_I))

// Response error encoding.
`define CHI_RESPERR_OK        2'b00
`define CHI_RESPERR_EXOKAY    2'b01
`define CHI_RESPERR_SLVERR    2'b10
`define CHI_RESPERR_DECERR    2'b11

// Issue-H compact-profile capability markers.
`define CHI_CAP_RETRY_SUPPORT       1
`define CHI_CAP_RETRY_PCRD_TYPES    1
`define CHI_CAP_DIRECT_C2C_FWD       1
`define CHI_CAP_MPAM_SUPPORT        0
`define CHI_CAP_LPID_SUPPORT        0
`define CHI_CAP_PBHA_SUPPORT        0
`define CHI_CAP_MTE_SUPPORT         0
`define CHI_CAP_DATA_POISON_SUPPORT 0
`define CHI_CAP_DATA_CHECK_SUPPORT  0

// REQ attribute field widths (Table B13.6).
`define CHI_REQ_ALLOW_RETRY_W  1
`define CHI_REQ_PCRD_TYPE_W    4
`define CHI_REQ_EXP_COMP_ACK_W 1
`define CHI_REQ_MEMATTR_W      4
`define CHI_REQ_SNPATTR_W      1
`define CHI_REQ_PAS_W          3
`define CHI_REQ_LPID_W         8
`define CHI_REQ_TRACE_TAG_W    1

`define CHI_REQ_MEMATTR_DEVICE        4'b0000
`define CHI_REQ_MEMATTR_NORMAL_CACHE  4'b0101
`define CHI_REQ_SNPATTR_NONE          1'b0
`define CHI_REQ_SNPATTR_COHERENT      1'b1
// PAS (Table B13.47) replaces the NS bit; 0b000 is Secure, as NS=0 was.
`define CHI_REQ_PAS_DEFAULT           3'b000
`define CHI_REQ_PCRD_TYPE_NONE        4'b0000
`define CHI_REQ_PCRD_TYPE_GENERIC     4'b0000

// DVM (chapter B8). A DVMOp is a write of 8 bytes (Size 0b011) to the MN:
// the payload is REQ.Addr plus NonCopyBackWriteData Data[63:0], and the MN
// passes it on in a two-part SnpDVMOp (Table B8.10). DVMType is
// REQ.Addr[13:11], which is SNP.Addr[10:8] of Part 1 (SNP Addr is
// Addr[43:3]). SNP.Addr[0] is 0 in Part 1 and 1 in Part 2.
`define CHI_DVM_REQ_SIZE              3'b011
`define CHI_DVM_TYPE_LSB              11
`define CHI_DVM_TYPE_SYNC             3'b100
`define CHI_DVM_PAYLOAD_BYTES         8

// Simplified RN cache states.
`define CHI_STATE_I           3'd0
`define CHI_STATE_SC          3'd1
`define CHI_STATE_SD          3'd2
`define CHI_STATE_UC          3'd3
`define CHI_STATE_UD          3'd4

// -----------------------------------------------------------------------------
// Flit layout, IHI0050H B13.9 (Tables B13.6-B13.9), fields from bit 0.
//
// Every CHI flit inside the fabric uses this layout. Interface properties:
//   NodeID_Width    = NID (7..16, the NODE_ID_W parameter)
//   Req_Addr_Width  = 44 (`CHI_REQ_ADDR_W); the RTL keeps ADDR_WIDTH (32)
//                     bits of address and drives the rest of Addr as zero.
//   Data_Width      = DW (128, 256 or 512, the DAT_DATA_W parameter)
//   MPAM, PBHA, MECID, StreamID, SecSID1, RSVDC, DataCheck and Poison are
//   all absent (width 0). chi_*_boundary_* adds them at an external port.
// TxnID and DBID are 12 bits and QoS is 4; TXN_ID_W, DBID_W and QOS_W must
// match (`CHI_FLIT_PARAM_CHECK).
// -----------------------------------------------------------------------------
`define CHI_REQ_ADDR_W   44
`define CHI_SNP_ADDR_W   (`CHI_REQ_ADDR_W - 3)
`define CHI_FLIT_TXN_W   12
`define CHI_FLIT_DBID_W  12
`define CHI_FLIT_QOS_W   4

// REQ, Table B13.6. R = 116 + 3*NID (137 at NID 7).
`define CHI_REQ_QOS_LSB(NID)            0
`define CHI_REQ_TGT_LSB(NID)            4
`define CHI_REQ_SRC_LSB(NID)            (4 + (NID))
`define CHI_REQ_TXN_LSB(NID)            (4 + 2*(NID))
`define CHI_REQ_RET_NID_LSB(NID)        (16 + 2*(NID))
`define CHI_REQ_STASH_NID_VALID_LSB(NID) (16 + 3*(NID))
`define CHI_REQ_RET_TXN_LSB(NID)        (17 + 3*(NID))
`define CHI_REQ_OPCODE_LSB(NID)         (29 + 3*(NID))
`define CHI_REQ_MULTI_REQ_LSB(NID)      (36 + 3*(NID))
// NumReq[5:0]; with MultiReq = 0 it is {3'b0, Size}.
`define CHI_REQ_NUM_REQ_LSB(NID)        (37 + 3*(NID))
`define CHI_REQ_SIZE_LSB(NID)           `CHI_REQ_NUM_REQ_LSB(NID)
`define CHI_REQ_ADDR_LSB(NID)           (43 + 3*(NID))
`define CHI_REQ_PAS_LSB(NID)            (`CHI_REQ_ADDR_LSB(NID) + `CHI_REQ_ADDR_W)
`define CHI_REQ_LIKELY_SHARED_LSB(NID)  (`CHI_REQ_PAS_LSB(NID) + 3)
`define CHI_REQ_ALLOW_RETRY_LSB(NID)    (`CHI_REQ_PAS_LSB(NID) + 4)
`define CHI_REQ_ORDER_LSB(NID)          (`CHI_REQ_PAS_LSB(NID) + 5)
`define CHI_REQ_PCRD_TYPE_LSB(NID)      (`CHI_REQ_PAS_LSB(NID) + 7)
`define CHI_REQ_MEMATTR_LSB(NID)        (`CHI_REQ_PAS_LSB(NID) + 11)
`define CHI_REQ_SNPATTR_LSB(NID)        (`CHI_REQ_PAS_LSB(NID) + 15)
// PGroupID[7:0]; {3'b0, LPID[4:0]} outside PCMO/Stash/Tag transactions.
`define CHI_REQ_LPID_LSB(NID)           (`CHI_REQ_PAS_LSB(NID) + 16)
`define CHI_REQ_EXCL_LSB(NID)           (`CHI_REQ_PAS_LSB(NID) + 24)
`define CHI_REQ_EXP_COMP_ACK_LSB(NID)   (`CHI_REQ_PAS_LSB(NID) + 25)
`define CHI_REQ_TAGOP_LSB(NID)          (`CHI_REQ_PAS_LSB(NID) + 26)
`define CHI_REQ_TRACE_TAG_LSB(NID)      (`CHI_REQ_PAS_LSB(NID) + 28)
`define CHI_REQ_W(NID)                  (`CHI_REQ_PAS_LSB(NID) + 29)

// RSP, Table B13.7. T = 57 + 2*NID (71 at NID 7).
`define CHI_RSP_QOS_LSB(NID)            0
`define CHI_RSP_TGT_LSB(NID)            4
`define CHI_RSP_SRC_LSB(NID)            (4 + (NID))
`define CHI_RSP_TXN_LSB(NID)            (4 + 2*(NID))
`define CHI_RSP_OPCODE_LSB(NID)         (16 + 2*(NID))
`define CHI_RSP_RESPERR_LSB(NID)        (21 + 2*(NID))
`define CHI_RSP_RESP_LSB(NID)           (23 + 2*(NID))
// FwdState[2:0]; {2'b0, DataPull} in Stash transactions.
`define CHI_RSP_FWD_STATE_LSB(NID)      (26 + 2*(NID))
`define CHI_RSP_CBUSY_LSB(NID)          (29 + 2*(NID))
`define CHI_RSP_DBID_LSB(NID)           (32 + 2*(NID))
`define CHI_RSP_PCRD_TYPE_LSB(NID)      (44 + 2*(NID))
`define CHI_RSP_TAGOP_LSB(NID)          (48 + 2*(NID))
`define CHI_RSP_TRACE_TAG_LSB(NID)      (50 + 2*(NID))
`define CHI_RSP_CACHE_LINE_ID_LSB(NID)  (51 + 2*(NID))
`define CHI_RSP_W(NID)                  (57 + 2*(NID))

// SNP, Table B13.8. S = 39 + 2*NID + SAW (94 at NID 7). There is no TgtID
// or Size: the fabric routes snoops by port, and Addr is Addr[43:3].
`define CHI_SNP_QOS_LSB(NID)            0
`define CHI_SNP_SRC_LSB(NID)            4
`define CHI_SNP_TXN_LSB(NID)            (4 + (NID))
`define CHI_SNP_FWD_NID_LSB(NID)        (16 + (NID))
// FwdTxnID[11:0]; {4'b0, VMIDExt[7:0]} in DVM snoops.
`define CHI_SNP_FWD_TXN_LSB(NID)        (16 + 2*(NID))
`define CHI_SNP_OPCODE_LSB(NID)         (28 + 2*(NID))
`define CHI_SNP_ADDR_LSB(NID)           (33 + 2*(NID))
`define CHI_SNP_PAS_LSB(NID)            (`CHI_SNP_ADDR_LSB(NID) + `CHI_SNP_ADDR_W)
`define CHI_SNP_DO_NOT_GO_TO_SD_LSB(NID) (`CHI_SNP_PAS_LSB(NID) + 3)
`define CHI_SNP_RET_TO_SRC_LSB(NID)     (`CHI_SNP_PAS_LSB(NID) + 4)
`define CHI_SNP_TRACE_TAG_LSB(NID)      (`CHI_SNP_PAS_LSB(NID) + 5)
`define CHI_SNP_W(NID)                  (`CHI_SNP_PAS_LSB(NID) + 6)

// DAT, Table B13.9. D = 70 + 3*NID + DW/32 + DW/128 + DW/8 + DW
// (240, 389 or 687 at NID 7).
`define CHI_DAT_QOS_LSB(DW,NID)         0
`define CHI_DAT_TGT_LSB(DW,NID)         4
`define CHI_DAT_SRC_LSB(DW,NID)         (4 + (NID))
`define CHI_DAT_TXN_LSB(DW,NID)         (4 + 2*(NID))
`define CHI_DAT_HOME_NID_LSB(DW,NID)    (16 + 2*(NID))
`define CHI_DAT_OPCODE_LSB(DW,NID)      (16 + 3*(NID))
`define CHI_DAT_RESPERR_LSB(DW,NID)     (20 + 3*(NID))
`define CHI_DAT_RESP_LSB(DW,NID)        (22 + 3*(NID))
// DataSource[7:0]; {5'b0, FwdState[2:0]} in DCT CompData.
`define CHI_DAT_DATA_SOURCE_LSB(DW,NID) (25 + 3*(NID))
`define CHI_DAT_FWD_STATE_LSB(DW,NID)   `CHI_DAT_DATA_SOURCE_LSB(DW,NID)
`define CHI_DAT_DATA_PULL_LSB(DW,NID)   (33 + 3*(NID))
`define CHI_DAT_CBUSY_LSB(DW,NID)       (34 + 3*(NID))
// {4'b0, DBID[11:0]}.
`define CHI_DAT_DBID_LSB(DW,NID)        (37 + 3*(NID))
`define CHI_DAT_CCID_LSB(DW,NID)        (53 + 3*(NID))
`define CHI_DAT_DATAID_LSB(DW,NID)      (55 + 3*(NID))
`define CHI_DAT_CACHE_LINE_ID_LSB(DW,NID) (57 + 3*(NID))
`define CHI_DAT_TAGOP_LSB(DW,NID)       (63 + 3*(NID))
`define CHI_DAT_TAG_LSB(DW,NID)         (65 + 3*(NID))
`define CHI_DAT_TU_LSB(DW,NID)          (`CHI_DAT_TAG_LSB(DW,NID) + (DW)/32)
`define CHI_DAT_TRACE_TAG_LSB(DW,NID)   (`CHI_DAT_TU_LSB(DW,NID) + (DW)/128)
`define CHI_DAT_CAH_LSB(DW,NID)         (`CHI_DAT_TRACE_TAG_LSB(DW,NID) + 1)
`define CHI_DAT_NUM_DAT_LSB(DW,NID)     (`CHI_DAT_TRACE_TAG_LSB(DW,NID) + 2)
`define CHI_DAT_REPLICATE_LSB(DW,NID)   (`CHI_DAT_TRACE_TAG_LSB(DW,NID) + 4)
`define CHI_DAT_BE_LSB(DW,NID)          (`CHI_DAT_TRACE_TAG_LSB(DW,NID) + 5)
`define CHI_DAT_DATA_LSB(DW,NID)        (`CHI_DAT_BE_LSB(DW,NID) + (DW)/8)
`define CHI_DAT_W(DW,NID)               (`CHI_DAT_DATA_LSB(DW,NID) + (DW))

// DataID (B13.10.51) is Addr[5:4] of the beat's lowest byte, so a DW-bit
// beat index maps to DataID = beat << log2(DW/128).
`define CHI_DAT_DATAID_W                2
`define CHI_DAT_DATAID_SHIFT(DW)        (((DW) >= 512) ? 2 : (((DW) >= 256) ? 1 : 0))

// Spec totals the layout must reproduce (B13.9 "Total" rows).
`define CHI_REQ_W_SPEC(NID)   (93 + `CHI_REQ_ADDR_W + 3*((NID) - 7))
`define CHI_RSP_W_SPEC(NID)   (71 + 2*((NID) - 7))
`define CHI_SNP_W_SPEC(NID)   (53 + `CHI_SNP_ADDR_W + 2*((NID) - 7))
`define CHI_DAT_W_SPEC(DW,NID) \
    ((((DW) == 512) ? 687 : (((DW) == 256) ? 389 : 240)) + 3*((NID) - 7))

// Elaboration check of flit parameters against B13.9. Use once in each
// module that builds or parses flits; pass the spec constant for a
// parameter the module does not have.
`define CHI_FLIT_PARAM_CHECK(ADDR_W,NID,TXN_W,DBIDW,QOSW,DW)     generate         if (((NID) < 7) || ((NID) > 16)) begin : g_chi_flit_bad_nid             $fatal(1, "CHI flit: NODE_ID_W=%0d, NodeID_Width is 7..16 (B13.9)", (NID));         end         if (((ADDR_W) < 7) || ((ADDR_W) > `CHI_REQ_ADDR_W)) begin : g_chi_flit_bad_addr             $fatal(1, "CHI flit: ADDR_WIDTH=%0d does not fit the %0d-bit Addr field",                    (ADDR_W), `CHI_REQ_ADDR_W);         end         if ((TXN_W) != `CHI_FLIT_TXN_W) begin : g_chi_flit_bad_txn             $fatal(1, "CHI flit: TXN_ID_W=%0d, TxnID is %0d bits (B13.9)",                    (TXN_W), `CHI_FLIT_TXN_W);         end         if ((DBIDW) != `CHI_FLIT_DBID_W) begin : g_chi_flit_bad_dbid             $fatal(1, "CHI flit: DBID_W=%0d, DBID is %0d bits (B13.9)",                    (DBIDW), `CHI_FLIT_DBID_W);         end         if ((QOSW) != `CHI_FLIT_QOS_W) begin : g_chi_flit_bad_qos             $fatal(1, "CHI flit: QOS_W=%0d, QoS is %0d bits (B13.9)",                    (QOSW), `CHI_FLIT_QOS_W);         end         if (((DW) != 128) && ((DW) != 256) && ((DW) != 512)) begin : g_chi_flit_bad_dw             $fatal(1, "CHI flit: DAT data width %0d, Data_Width is 128, 256 or 512 (B13.9.4)",                    (DW));         end         if ((`CHI_REQ_W(NID) != `CHI_REQ_W_SPEC(NID)) ||             (`CHI_RSP_W(NID) != `CHI_RSP_W_SPEC(NID)) ||             (`CHI_SNP_W(NID) != `CHI_SNP_W_SPEC(NID)) ||             (`CHI_DAT_W(DW,NID) != `CHI_DAT_W_SPEC(DW,NID))) begin : g_chi_flit_bad_total             $fatal(1, "CHI flit: widths REQ=%0d RSP=%0d SNP=%0d DAT=%0d differ from B13.9 totals %0d/%0d/%0d/%0d",                    `CHI_REQ_W(NID), `CHI_RSP_W(NID), `CHI_SNP_W(NID), `CHI_DAT_W(DW,NID),                    `CHI_REQ_W_SPEC(NID), `CHI_RSP_W_SPEC(NID), `CHI_SNP_W_SPEC(NID),                    `CHI_DAT_W_SPEC(DW,NID));         end     endgenerate

`endif
