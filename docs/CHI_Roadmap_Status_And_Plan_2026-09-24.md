# CHI Interconnect: trạng thái lộ trình sửa lỗi và kế hoạch tiếp theo (2026-09-24, cập nhật 2026-10-07: xong Giai đoạn 2 trừ UCE; xong Giai đoạn 3)

Tài liệu này đối chiếu lộ trình 4 giai đoạn trong bản review AMBA 5 CHI (IHI0050H) với RTL hiện tại ở `D:\Github\CHI_Interconnect`. Nó ghi lại mục nào đã sửa và mục nào còn tồn đọng, rồi lập kế hoạch cho phần còn lại.

Đường dẫn RTL viết tắt: `rtl/` = `CHI_Interconnect.srcs/sources_1/imports/CHI_Interconnect/rtl/`.
Testbench: `tb_CHI.sv` = `CHI_Interconnect.srcs/sim_1/new/tb_CHI.sv`.

## 0. Bối cảnh và cách kiểm

- Bản review gốc được viết trên **bản cũ** ở `D:\GITHUB_PROJECT\CHI_Interconnect`. Bản Vivado ở `D:\Github\CHI_Interconnect` mới hơn nhiều: đã có sẵn phần lớn công việc "Issue-H strict subset", gồm opcode, Retry/PCrd, SnpRespFwded và DCT. Vì vậy một số mục trong review đã được xử lý **trước** phiên sửa P0.
- Từ 2026-09-25 repo đã có git: baseline `e9aa824` trên `main`. Giai đoạn 1 nằm trên `fix/phase1-correctness`. Giai đoạn 4 (`verif/4.1-4.2-checkers`) và công việc 2026-09-26 (`work/p02-wb-phase2`: P0-2, P0-4, N-4, 2.1–2.4, mở rộng stress) đã gộp fast-forward vào đó (`9b99fad`). Mọi công việc sau đó (1.5 đầy đủ, 2.5–2.9) đã gộp fast-forward vào `fix/phase1-correctness` (`a16a0a5`). "Đã sửa" nghĩa là có commit, có test tái hiện (fail trước, pass sau, trừ khi ghi rõ là lỗ hổng tiềm ẩn) và regression sạch.
- Regression chung: `scripts/run_regression.ps1` (14 testbench, xsim Vivado 2024.1), mặc định bật **mọi luật spec** (11 luật sau 2.9, `-SpecPlusArgs "CHK_SPEC_ALL"`). Testbench bị tính FAIL khi log có `transaction timeout`, `ERROR:` (gồm `CHI_CHK ERROR:`, `CHI_SB ERROR:`, `CHI_SBL1 ERROR:`), và HANG khi không tới `$finish`. Stress nhiều seed: `scripts/run_stress_seeds.ps1`.

**Regression hiện tại** (`fix/phase1-correctness` = `a16a0a5`, sau 2.9, `CHK_SPEC_ALL` = 11 luật spec): tb_CHI T01..T56 PASS ở cả chế độ mặc định lẫn `CHI_SIM_REAL_ICG +CG_ALWAYS`, 0 lỗi checker và scoreboard. Regression 14/14, stress 24/24 (seed 1–8 × rn2/rn3/icg, lượt `p29s2`), `tb_chi_soc_cluster_ip_deep` 13/13.

**Sau Giai đoạn 3 bước 3.2** (`work/p30-link` = `b155a73`, `CHK_SPEC_ALL` = 13 luật spec, thêm `SPEC_LINK_CREDIT` và `SPEC_LINK_FLITPEND`): regression 16/16 (thêm `tb_riscv_core_amo` và `tb_chi_link_layer`), stress 24/24, tb_CHI T01..T56 PASS ở cả hai chế độ, 0 lỗi credit và FLITPEND trên cả 8 nhóm link.

**Sau Giai đoạn 3 bước 3.3** (2026-10-05, `CHK_SPEC_ALL` = 14 luật spec, thêm `SPEC_LINK_ACTIVE`): regression 16/16, stress 24/24, tb_CHI T01..T56 PASS ở cả hai chế độ. Ở chế độ `CHI_SIM_REAL_ICG +CG_ALWAYS` mỗi link về STOP 128 lần trong một lượt tb_CHI, 0 lỗi `SPEC_LINK_ACTIVE`, và clock vẫn tắt được (`cg_gated_cycles` = 12413). `tb_chi_link_layer` có 21 case, 6 case bật/tắt link ngẫu nhiên.

**Sau Giai đoạn 3 bước 3.4** (2026-10-07, `CHK_SPEC_ALL` = 16 luật spec, thêm `SPEC_SACTIVE` và `SPEC_SYSCO`): regression 16/16, stress 24/24, tb_CHI T01..T57 PASS ở cả hai chế độ, 0 lỗi checker và scoreboard. Ở chế độ `CHI_SIM_REAL_ICG +CG_ALWAYS` clock vẫn tắt được (`cg_gated_cycles` = 12449).

## Tổng kết tiến độ (2026-10-07)

**Đã sửa** (mỗi mục có commit, test và regression sạch; chi tiết ở các bảng bên dưới):

| Nhóm | Mục |
|---|---|
| Bước 0 | 0.1 git baseline, 0.2 chạy lại SoC TB (2 lỗi TB có sẵn đã sửa), 0.3 regression chung |
| Giai đoạn 1 | P0-1 (SF merge), P0-2 (T46), P0-3 / 1.5 đầy đủ (slot DBID ở SN), P0-4 / 1.6 (cache RN thật, A1), N-1, N-2, N-3, N-4, 1.2 (bỏ timeout chức năng), 1.3 (TxnID snoop do home cấp, trong 2.3), 1.4 (TxnID HN→SN), 1.7 (clock gate + `fabric_clear`) |
| Giai đoạn 2 | 2.1 CompAck/WriteData = DBID, 2.2 Resp CompData, 2.3 SnpRespData, 2.4 CompDBIDResp + DBID của SN, 2.5 exclusive B6.3, 2.6a DAT 128 bit (gồm O2), 2.6b opcode 7/5 bit, 2.6c layout B13.6–B13.9, 2.7 DVM B8, 2.8 CompAck cho MakeUnique, 2.9 SnpRespFwded/SnpRespDataFwded |
| Giai đoạn 3 | 3.0 luật `SPEC_LINK_CREDIT` + opcode LCrdReturn, 3.5 TB đơn vị link, 3.1a credit thật node → fabric, 3.1b credit thật fabric → node, 3.2 FLITPEND, 3.3 LINKACTIVE (FSM activate/deactivate, trả credit bằng LCrdReturn, clock gate chờ mọi link về STOP), 3.4 TX/RXSACTIVE + SYSCOREQ/SYSCOACK (RN tự flush rồi rời coherency domain, HN/MN không snoop RN ngoài domain, snoop filter xóa RN đã rời) |
| Giai đoạn 4 | 4.1 scoreboard coherence (RN nội bộ + L1 ngoài), 4.2 checker giao thức (16 luật spec), 4.3 stress ngẫu nhiên + `run_stress_seeds.ps1` |

**Chưa sửa / còn mở:**

| Mục | Trạng thái | Ghi chú |
|---|---|---|
| UCE ở RN | ⏸ để sau | RN chưa có trạng thái UCE nên không CleanUnique từ I. Mục duy nhất còn lại của Giai đoạn 2. |
| STREX ở chế độ L1 ngoài | ⏸ để sau | Vẫn gửi WriteUnique (tham số `STREX_CLEAN_UNIQUE` chưa ai dùng), vì SoC chưa dùng LDREX/STREX qua đường này. |
| SYSCO ở chế độ L1 ngoài | ⏸ để sau | RN không flush được L1 của core nên luôn ở trong coherency domain (`SYSCO_CTRL` bị bỏ qua). Cần cổng flush/"đã rỗng" từ L1. |
| Giao dịch của RN ngoài domain | ⏸ để sau | RN ngoài domain không nhận lệnh CPU (`cpu_req_ready` thấp); chưa hỗ trợ giao dịch không cache (ReadOnce). |
| 4.4 CoreMark trong regression | ✅ (2026-10-07) | CoreMark dual-core PASS trở lại (CoreMark = 433,35, CRC đúng) và là bước cuối của `run_regression.ps1`. Nguyên nhân timeout: lần re-sync core `4329555` làm mất bản vá `id_ex_jal \| id_ex_jalr` ở thanh ghi EX/MEM, nên JALR ghi địa chỉ đích vào `rd` thay vì `pc+4` (chi tiết ở mục 5). Kết luận cũ "lỗi có sẵn" là sai: các lượt so sánh khi đó chạy với `SplitImages 0`. Còn lại: gắn scoreboard L1 vào TB CoreMark. |
| 4.3 phần còn lại | 🟡 | ✅ Stress mặc định không còn barrier (`+BARRIER=<n>` để bật lại); `run_stress_seeds.ps1` chạy cả hai chế độ (40 lượt). ❌ Lên lịch chạy stress định kỳ. |
| O1 băng thông fabric | ❌ | `chi_flit_reg_slice` vẫn half-buffer. |
| O3 LLC-hit qua read tracker | ❌ | FSM chính vẫn bị giữ ở SEND_DAT/WAIT_ACK. |
| Git | 🟡 | `fix/phase1-correctness` có đủ Giai đoạn 1–3 (`work/p30-link` đã gộp; 3.4 là `9b3605b`). Repo dev không có remote và `main` của nó vẫn là baseline `e9aa824`. Mã CHI lên GitHub qua `scripts/export_github.sh` (repo phẳng); Giai đoạn 3 được export ngày 2026-10-07. |

## Cập nhật tiến độ (2026-09-25, branch `fix/phase1-correctness`)

| Bước | Trạng thái | Commit / bằng chứng |
|---|---|---|
| 0.1 git baseline | ✅ | `e9aa824` trên `main` (thêm `.gitignore`, `core.autocrlf=false` cho repo; `coremark/` là repo riêng nên bị bỏ qua) |
| 0.2 chạy lại SoC TB | ✅ | Lúc đầu `tb_chi_soc_cluster_ip_deep` fail ở T4 và `tb_riscv_l1_axi_to_chi_bridge_mmio` treo ở T03. Cả hai fail y hệt trên baseline và khi tắt merge SF, tức là lỗi có sẵn, không do P0-1. **Cả hai đều là lỗi testbench và đã sửa** (xem hai dòng cuối bảng). |
| 0.3 regression chung | ✅ | `scripts/run_regression.ps1`: chạy 13 TB, có giới hạn `-RunTime`/`-WallTimeoutSec`. Tính là FAIL khi có `transaction timeout`, và HANG khi không tới `$finish`. `run_tb_chi_xsim.ps1` có thêm `-Top` và `-Defines`, và giữ nguyên plusarg dạng `NAME=VALUE`. |
| **1.1 N-1** | ✅ **Đã sửa** (`20e88f4`) | Nguyên nhân: bảng txn của RN chỉ có 1 cổng hoàn tất. Khi RSP Comp và beat DAT cuối của một lệnh đọc đến **cùng chu kỳ**, Comp thắng mux. Lệnh đọc vẫn trả dữ liệu cho CPU nhưng entry không được xóa, và 1024 chu kỳ sau timeout dọn nó, đồng thời phát thêm một `cpu_resp_valid` **ma với dữ liệu 0**. Sửa: giữ flit RSP trong FIFO đúng chu kỳ DAT-line hoàn tất (`chi_rn_f.v`, `rsp_rx_ready`). Đã xác nhận có đúng 3 va chạm, khớp 1-1 với 3 timeout. tb_CHI giờ fail khi có bất kỳ timeout nào ở RN. |
| **1.2 bỏ timeout chức năng** | ✅ **Đã sửa** (`153194a`) | Thêm tham số `FUNCTIONAL_TIMEOUT` (mặc định 0) ở `chi_top` → RN-F/txn tracker, HN-F (FSM chính, read tracker, snoop tracker), MN (DVM tracker). Khi bằng 0, timeout chỉ phát **một xung watchdog** mỗi lần kẹt, không hoàn tất giao dịch, không trả SLVERR, không giải phóng slot. Xung này set **`ERR_STATUS[4]`** (W1C) và kéo `chi_irq`. Đặt `FUNCTIONAL_TIMEOUT=1` để lấy lại hành vi cũ. Test mới **T42**: AXI R bị giữ 1300 chu kỳ (lớn hơn 1024). Trước khi sửa, CPU nhận `0x0`; sau khi sửa, dữ liệu đúng, `ERR_STATUS[4]`=1, IRQ lên, W1C xóa được. |
| **1.3 TxnID snoop** | ✅ **Đã sửa sau trong 2.3** (`38200cf`); ghi chú lúc 2026-09-25: tiềm ẩn, chưa thể kích hoạt | Testbench mới `tb_chi_snoop_txnid_3rn` (3 RN) xác nhận HN gửi snoop với **TxnID của requester**: RN0 và RN1 cùng dùng TxnID 0, và cả hai snoop tới RN2 đều mang `txn 0x0`. Tuy vậy HN hiện hoàn tất một request cần snoop rồi mới bắt đầu request kế tiếp (snoop thứ hai chỉ được gửi sau khi giao dịch đầu kết thúc), nên hai snoop không bao giờ chồng lấn và không có response bị gán nhầm. Mọi cách ép chồng lấn bằng `force` ở link đều tạo nhiễu, không đáng tin. **Quyết định:** chưa sửa mò khi không có test RED. Giữ tb này trong regression làm chốt chặn (checker sẽ FAIL khi snoop trùng TxnID chồng lấn), và gộp việc sửa TxnID snoop do HN tự cấp vào **2.3** (viết lại SnpResp/SnpRespData) hoặc **O3** (HN xử lý song song hơn), vì cả hai cùng đụng logic so khớp snoop này. |
| **1.4 TxnID HN→SN** | ✅ **Đã sửa** (`44ebf4c`) | TxnID xuống SN được gắn tag lớp ở 2 bit cao: read tracker `2'b01`, write tracker `2'b10`, LLC evict all-ones. tb_CHI có thêm checker "TxnID không được dùng lại khi còn outstanding ở SN" và test **T43**: giữ BRESP để lệnh ghi HN→SN còn outstanding trong lúc một lệnh đọc miss của RN khác đi xuống SN. Trước khi sửa: `SN TxnID 0x1 reused`; sau khi sửa: PASS. |
| **1.5 P0-3 (tối thiểu)** | ✅ **Đã sửa phần tối thiểu** (`627a266`) | HN theo dõi một burst ghi HN→SN đang mở (từ `start_write` tới beat thứ 16 được forward, `wr_burst_open_q`) và chặn capture LLC eviction trong lúc đó ([chi_hn_f.v:1166](../hn/chi_hn_f.v#L1166)). Không thể deadlock vì burst ghi tự xả mà không chờ eviction hay LLC. Test **T44** quét 80 điểm/độ dài stall AXI W của một WriteBackFull trong lúc refill đọc evict một victim LLC dirty, cộng 6 trường hợp lệnh ghi xếp sau refill. **Trên RTL cũ T44 cũng không tách được burst** (DAT sink chung của HN đã tuần tự hóa refill sau các beat ghi), nên đây là vá lỗ hổng tiềm ẩn, không phải lỗi đã tái hiện. Checker mới: mô hình AXI fail khi WLAST lệch AWLEN; SN báo beat ghi có TxnID khác lệnh ghi đang chạy; probe đếm eviction bị capture khi write tracker đang hoạt động. Phần đầy đủ (buffer theo TxnID/DBID ở SN) vẫn gộp với 2.4. |
| **1.7 clock gate + `fabric_clear`** | ✅ **Đã sửa** (`7774b8a`) | Mọi node (RN-F và các khối con, HN-F cùng LLC/SF, SN-F, MN) và fabric xuất cờ `busy`. `chi_top` OR thành `chi_busy` và giữ `chi_cg_en` khi cờ này bật ([chi_top.v:268-285](../chi_top.v#L268)). Reservation exclusive cũng tính là busy để bộ đếm aging tiếp tục chạy. `fabric_clear` chỉ phát khi `chi_busy`=0; BIST init lúc đang bận bị từ chối và set **`ERR_STATUS[5]`** (W1C, không kéo IRQ). `chi_clock_gate_insert` có mô hình ICG kiểu latch khi define `CHI_SIM_REAL_ICG`; plusarg `+CG_ALWAYS` giữ `CTRL.cg_enable` bật suốt lượt chạy. **T20** giờ chờ writeback victim chạy nền xong mới kiểm idle (enable cũ bỏ qua việc này). Test mới **T45**: BIST init khi một lệnh đọc đang bị giữ ở AXI R phải bị từ chối, lệnh đọc vẫn đúng dữ liệu, còn BIST init lúc rảnh phát đúng 1 xung `fabric_clear`. T45 fail với `fabric_clear` cũ. tb_CHI T01..T45 PASS ở cả chế độ mặc định lẫn `CHI_SIM_REAL_ICG +CG_ALWAYS` (clock bị tắt thật 12 386 chu kỳ). |
| SoC deep T4 (lỗi có sẵn) | ✅ **Đã sửa, lỗi TB** (`d4d4eae`, merge `e7c3800`) | TB backdoor-seed tag D-cache và snoop filter theo geometry cũ. DCACHE 1K→4K (16 set, tag 22 bit) và SF 64→256 entry (64 set) trong đợt sửa CoreMark tháng 7, nhưng TB vẫn dùng 4 set/tag 24 bit và 16 set SF. TB giờ suy ra độ rộng từ tham số và `$fatal` ở time 0 nếu lệch với `u_dcache`/`u_snoop_filter`. RTL không đổi. |
| Bridge MMIO T03 treo (lỗi có sẵn) | ✅ **Đã sửa, lỗi TB** (`4d65fd8`, merge `dcb1822`) | Bridge chỉ hoàn tất lệnh đọc cacheable bằng line response (`cpu_resp_line_valid`) và phải bỏ qua word response đi sau cùng tag. T03/T09 vẫn chỉ lái word response kiểu cũ nên bridge không bao giờ xong, và TB chờ vô hạn. T03/T09 giờ lái line response giống `chi_rn_f`; T03 kiểm thêm là word pulse đi sau không phát lại lệnh đọc. Thêm watchdog toàn cục 50 µs. `run_regression.ps1` khớp `ERROR:` thay vì `ERROR` để tên test `T05_MMIO_READ_ERROR_RESPONSE_*` không bị tính là fail. |

**Regression sau khi gộp** (`dcb1822`, worktree sạch `D:\Github\CHI_verify`): **13/13 PASS**. Danh sách: tb_CHI (T01..T45), tb_chi_soc_cluster_ip, tb_chi_soc_cluster_ip_deep, tb_chi_soc_mmio_2m_arbiter, tb_riscv_cache_maintenance, tb_riscv_dcache_writeback_chi, tb_riscv_l1_axi_to_chi_bridge_mmio, tb_chi_boundary_roundtrip, tb_chi_dat_boundary_attrs, tb_chi_dat_byte_offset_xbar5, tb_chi_fabric_qos_xbar3, tb_chi_rn_f_qos_xbar4, tb_chi_snoop_txnid_3rn.

## Cập nhật tiến độ Giai đoạn 4 (2026-09-25, branch `verif/4.1-4.2-checkers`)

| Bước | Trạng thái | Commit / bằng chứng |
|---|---|---|
| **4.2 checker giao thức** | ✅ (`4cd5894`) | `sim_1/checkers/chi_protocol_checker.sv`, được `chi_checker_binds.sv` bind vào **mọi** `chi_top`, nên mọi TB (kể cả SoC) đều có checker. `run_tb_chi_xsim.ps1` tự compile thư mục `checkers/` và elaborate `chi_checker_binds` làm top thứ hai. Checker quan sát flit ở đầu ra fabric (REQ/RSP/DAT/SNP). Nó theo dõi giao dịch theo (requester, TxnID), snoop theo (home, RN, TxnID) và CompAck còn nợ. **Luật mặc định**, theo hợp đồng RTL hiện tại: TxnID không bị dùng lại khi còn outstanding; response/CompData/WriteData phải khớp một giao dịch đang mở; nguồn đúng; DataID không lặp; WriteData chỉ sau DBIDResp (trừ tới SN); DBID của WriteData khớp; DBID không trùng ở cùng completer; Comp không đến trước khi đủ WriteData; CompAck khớp một read đã xong; liveness (20 000 chu kỳ) cho giao dịch, snoop, CompAck và SnpRespData còn thiếu beat. **7 luật spec cho Giai đoạn 2**, mặc định tắt, bật bằng `+CHK_SPEC_<TÊN>` hoặc `+CHK_SPEC_ALL`: `COMPACK_DBID` và `WDAT_TXNID_DBID` (2.1), `COMPDATA_RESP` (2.2), `SNPRESPDATA_ONLY` (2.3), `COPYBACK_COMPDBID` và `SN_DBID_FIRST` (2.4), `SNP_TXNID_HOME` (1.3). **Kiểm chứng:** tb_CHI sạch (726 request, 259 snoop). Với `+CHK_SPEC_ALL`, đúng 7 luật spec báo lỗi và không có lỗi dây chuyền. Đột biến M1 (CompAck sai TxnID) bị `COMPACK_UNMATCHED` bắt; M2 (bỏ tag lớp TxnID HN→SN) bị `REQ_TXNID_REUSE` bắt. |
| **4.1 scoreboard coherence** | ✅ (`0c1f269`) | `sim_1/checkers/chi_coherence_scoreboard.svh`, được include trong tb_CHI, tb_chi_snoop_txnid_3rn và tb_chi_random_stress (các TB dùng cache RN nội bộ). (1) Mỗi khi hệ yên (không request CPU, checker không còn giao dịch mở, HN/SN/fabric/RN rảnh; reservation exclusive không tính là bận), scoreboard chụp trạng thái cache RN và SF rồi kiểm `SB_SWMR` (RN ở UC/UD là người giữ duy nhất, tối đa một SD) và `SB_SF_SUPERSET` (mọi dòng RN đang giữ đều có trong SF, đúng bit sharer). (2) `SB_DATA`: bộ nhớ vàng theo byte ở giao diện CPU. Ghi (WriteBackFull, WriteUnique, STREX thành công) cập nhật khi có response CPU; đọc phải khớp mọi byte đã biết; đọc chồng với ghi cùng dòng thì bỏ qua. MakeUnique làm dòng thành không xác định (quên dòng). TB backdoor LLC gọi `sb_forget_line`. **Kiểm chứng:** tb_CHI sạch (117 lần kiểm trạng thái, 152 lần đọc, 118 lần ghi). Đột biến S1 (bỏ merge SF, tức P0-1) bị `SB_SF_SUPERSET` và `SB_SWMR` bắt ngay ở lần yên đầu tiên; S3 (lật 1 bit WriteData) bị `SB_DATA` bắt trên TB stress, chỉ đúng byte đó. |
| **4.3 stress ngẫu nhiên** | ✅ (`d231a2a`) | `tb_chi_random_stress.sv`: 2 RN (hoặc 3 với `-Defines STRESS_NUM_RN=3`). Tập 12 dòng được chọn để gây eviction ở cache RN, SF và LLC. Bộ nhớ AXI có backpressure ready/valid và độ trễ ngẫu nhiên. Mỗi RN chạy luồng ReadShared/ReadUnique/WriteUnique/Evict/MakeUnique/LDREX+STREX, có barrier mỗi 25 thao tác để scoreboard được lấy mẫu. `+SEED`, `+OPS`, `+CG` (dùng với `CHI_SIM_REAL_ICG`). Đã có trong `run_regression.ps1`. **Kết quả:** seed 1–4 với 2 RN, seed 1–2 với 3 RN và seed 4 ở chế độ ICG thật đều PASS, 0 vi phạm. CPU WriteBackFull mặc định tắt (`+WBFULL` để bật), xem mục mở bên dưới. |
| **N-2** read HN→SN không căn dòng | ✅ **Đã sửa** (`9af897a`) | Do 4.3 phát hiện. HN căn địa chỉ về đầu dòng cho write HN→SN nhưng **không** cho read. LDREX/ReadShared tới một word giữa dòng thành AXI INCR 16 beat bắt đầu giữa dòng, và AXI slave thật trả dữ liệu lệch word (và tràn sang dòng kế). Mô hình AXI của tb_CHI tự căn nên che mất lỗi. Sửa: `chi_hn_f.v` căn địa chỉ và đặt Size=6 cho mọi request HN→SN. **RED:** mô hình AXI của tb_CHI giờ fail khi burst cả dòng không căn; T31 fail ở `ARADDR=0x11402` trước khi sửa, T01..T45 PASS sau khi sửa. |
| **N-3** deadlock POS `out1` | ✅ **Đã sửa** (`79c72e0`) | Do 4.3 phát hiện: ReadUnique của RN0 và ReadShared của RN1 cùng dòng treo mãi, HN rảnh hoàn toàn, POS giữ 2 entry. `chi_hn_pos_buffer.v` có 2 cổng ra; `out1` chỉ được lấy **cùng lúc** HN nhận `out`. Khi `out` được lấy đi trong lúc `out1` còn giữ entry B, entry còn lại C (cùng dòng, trẻ hơn B) bị B chặn nên không lên được `out`, và `out1` không bao giờ được lấy. Sửa: `out` trống thì đôn `out1` lên `out`. **RED:** stress seed 1–3 (với Evict + LDREX/STREX) đều treo ở cùng mẫu này trước khi sửa, và PASS sau khi sửa. |

**Regression sau Giai đoạn 4** (`d231a2a`, worktree sạch): **14/14 PASS** (13 TB cũ + `tb_chi_random_stress`). Checker giao thức 0 vi phạm ở mọi TB có `chi_top` (tb_CHI, tb_chi_snoop_txnid_3rn, tb_chi_random_stress, tb_chi_soc_cluster_ip, tb_chi_soc_cluster_ip_deep); scoreboard 0 vi phạm ở 3 TB có cache RN nội bộ.

**Mục mở do Giai đoạn 4 phát hiện:** cả hai đã xử lý ngày 2026-09-26 (P0-2 có test RED T46; CPU WriteBackFull khi không sở hữu được giải quyết cùng P0-4 theo hướng A1). Xem mục kế tiếp.

**CoreMark dual-core** (image mặc định, `-Iterations 1`): **vẫn mở**. Không kết thúc trong 3M và cả 6M chu kỳ; hai hart đọc timer mãi, không in UART. Hành vi **giống hệt baseline `e9aa824`** trong 3M chu kỳ đầu (so từng giá trị timer), nên đây là lỗi có sẵn phía firmware/RISC-V; lần PASS cuối là 07-09 09:36. Đã tách thành task riêng. **Đính chính 2026-10-07:** các lượt này chạy với `SplitImages 0` (cấu hình sai, core1 lấy lệnh toàn 0). Với `-SplitImages 1 -StartMask 3`, CoreMark PASS ở baseline và tới tận `16c219b`; nó chỉ hỏng từ lần re-sync core `4329555` (mất đường link của JALR), đã sửa ngày 2026-10-07.

**Lưu ý môi trường:** ở working tree chính, 9 file `rtl/core/*` (phần AMO của RISC-V), `tb_chi_coremark_dual_core.sv`, một dòng `tb_riscv_core_amo` trong `run_regression.ps1` và file mới `tb_riscv_core_amo.sv` đang được một phiên khác sửa dở, chưa commit, và chưa compile được. Việc gộp nhánh giữ nguyên các thay đổi này. Mọi kiểm chứng chạy trong worktree sạch `D:\Github\CHI_verify`.

## Cập nhật tiến độ 2026-09-26 (branch `work/p02-wb-phase2`)

| Bước | Trạng thái | Commit / bằng chứng |
|---|---|---|
| Gộp Giai đoạn 4 | ✅ | `git merge --ff-only verif/4.1-4.2-checkers` ở `D:\Github\CHI_Interconnect` (`065f874..8c26336`). Thay đổi AMO dở của phiên khác được giữ nguyên; dòng `tb_riscv_core_amo` trong `run_regression.ps1` tự gộp, còn cả hai dòng. |
| **P0-2** test bảo vệ | ✅ (`4760670`) | Cơ chế thật: với cache RN nội bộ, mọi lệnh ghi ghi người ghi vào SF làm chủ, nên đọc sau đó snoop người ghi và không nhìn LLC. LLC chỉ lộ ra khi người ghi đã mất dòng mà SF vẫn trỏ vào nó. **T46**: RN0 đọc (LLC fill), RN1 WriteUnique cả dòng rồi evict (WriteBackFull) do đầy set, RN0 đọc lại. Với đột biến `llc_invalidate_valid = 0`: LLC vẫn giữ dòng cũ, RN0 đọc `0xa5a6f000` thay vì `0xc0de4646` (check trực tiếp và `SB_DATA` cùng bắt). Không đột biến: PASS. Sau H1 bên dưới, SF không còn ghi người ghi, nên invalidate LLC là cơ chế duy nhất bảo vệ, ở mọi cấu hình. |
| Công cụ | ✅ (`d940c5d`) | `+TRACE_LINE=<hex>`: checker và scoreboard in mọi flit và mọi request/response CPU của một dòng. Scoreboard: hai lệnh ghi cùng dòng chồng lấn thời gian thì byte cả hai cùng ghi thành "không xác định" (home có thể xếp thứ tự bất kỳ). Kiểm chứng bằng đột biến: tắt H2 vẫn cho 22 lỗi `SB_DATA`. |
| **P0-4 / 1.6** cache RN thật (hướng **A1**) + WriteBackFull khi không sở hữu | ✅ (`3187ff1`) | **RN-F** (`chi_rn_f.v`, `chi_rn_cache.v`) có front end xử lý từng request CPU: chờ hết giao dịch cùng dòng, rồi một lần truy cập cache nguyên tử (cổng CPU mới: `READ/READ_UQ/FLUSH/CLEAN/STORE/STORE_WB/EVICT/DROP`), sau đó phục vụ tại chỗ hoặc gửi ra fabric. Đọc trúng dòng đang giữ, và store vào dòng UC/UD (merge thành UD), không phát REQ. WB_FULL của owner là CopyBack dòng đã merge rồi về I. WB_FULL của non-owner gửi WriteUnique chỉ với byte của CPU. SD được writeback trước khi store/ReadUnique; bản SC bị bỏ trước lệnh ghi; Evict dòng dirty là writeback. Lệnh ghi không cấp phát; chỉ read fill mới cấp phát. Snoop miss cache vẫn thấy dòng dirty đang chờ WriteBack (hàng đợi victim hoặc WDAT chưa có DBID). **HN**: (H1) lệnh ghi để SF không còn sharer; (H2) dữ liệu dirty nhận từ snoop được ghi về bộ nhớ qua bộ ghi victim LLC trước khi dòng được dùng lại (trước đây WriteUnique từng phần hay ReadUnique rồi bỏ bản sạch làm mất byte của owner); (H) CopyBack từ RN mà SF không còn liệt kê là CopyBack cũ: beat đi xuống với BE=0, không snoop, không cập nhật SF. **Test mới** T47..T51 (T49, T50, T51 RED trước sửa; T51 RED cả khi chỉ bỏ (H)). Test dirty-owner (T25/T36/T37/DCT/opcode) tạo owner bằng `rn_make_dirty` (ReadUnique + store tại chỗ). Stress bật WriteBackFull mặc định (`+NO_WBFULL` để tắt). |
| **N-4** đọc vượt lệnh ghi cùng dòng | ✅ (`7ad2028`) | Do stress 3-RN seed 1 phát hiện. Read vượt qua khóa cùng dòng của POS trước khi write cùng dòng (cũ hơn) bắt đầu; HN bắt đầu write (WriteNoSnp chờ dữ liệu RN) rồi ReadNoSnp của read tới SN trước; SN trả dữ liệu cũ và LLC giữ nó. Sửa: `start_mem_read` chờ khi có write tracker giữ dòng. **T52**: fail khi bỏ cổng chặn, pass khi có. |
| **2.1** CompAck/WriteData dùng DBID | ✅ (`6eaba0c`) | WriteData có TxnID = DBID của DBIDResp; write tracker khớp theo (DBID, nguồn). Mọi CompData của HN mang DBID `{bank, lớp, chỉ số}` (lớp 1 read tracker, 2 snoop tracker, 3 LLC-hit của FSM chính; lớp 0 là write); CompAck trả DBID đó. Trước: 176 lỗi `SPEC_COMPACK_DBID`, 1888 lỗi `SPEC_WDAT_TXNID_DBID` trong tb_CHI; sau: 0. |
| **2.2** Resp CompData theo spec | ✅ (`a090b28`) | `CHI_COMPDATA_RESP_*` (I/SC/UC/UD_PD/SD_PD). HN gửi SC cho ReadShared, UC cho ReadUnique, I cho các loại khác; DCT forward UC/SC. RN chọn trạng thái fill theo Resp. |
| **2.3 + 1.3** SnpRespData một mình; TxnID snoop do home cấp | ✅ (`38200cf`) | Snoop có dữ liệu chỉ trả SnpRespData (Resp = trạng thái cuối + PassDirty); snoop tracker coi SnpRespData đủ beat là response (dirty). TxnID snoop = `DBID_SNP_BASE \| (entry << RN_W) \| rn`, duy nhất theo đích; MN đặt TxnID của DVM snoop = chỉ số RN. |
| **2.4** CopyBack nhận CompDBIDResp; SN cấp DBID trước dữ liệu | ✅ (`8a03450`) | HN trả CompDBIDResp cho WriteBack; entry CopyBack được giải phóng khi SN Comp mà không gửi Comp nữa. SN gửi DBIDResp (DBID 0, một lệnh ghi/lần) khi nhận WriteNoSnp; HN chỉ chuyển dữ liệu ghi sau khi có DBID của SN (write tracker và bộ ghi victim có trạng thái WAIT_DBID). **Còn lại (1.5 đầy đủ):** buffer theo DBID ở SN để HN có nhiều lệnh ghi outstanding (`wr_trackers_idle` vẫn giữ). Đã xong ở `841be1a`. |
| **5** mở rộng stress | ✅ (commit bước 5) | `scripts/run_stress_seeds.ps1` chạy nhiều seed cho rn2/rn3/icg với `CHK_SPEC_ALL`, dùng để chạy định kỳ. Scoreboard coherence cho L1 ngoài (`checkers/chi_l1_coherence_scoreboard.svh`: `SB_L1_SWMR`, `SB_L1_SF_SUPERSET`) gắn vào hai SoC TB; dòng seed bằng backdoor được miễn qua `sbl1_exempt_line`. |

**Kiểm chứng sau 2.4** (`CHK_SPEC_ALL`): regression 14/14; tb_CHI T01..T52 ở chế độ mặc định và ICG thật; stress 3-RN seed 1/4/5, 2-RN seed 2/3, ICG seed 4. `run_stress_seeds.ps1` mặc định (seed 1–8 × rn2/rn3/icg, `CHK_SPEC_ALL`, WriteBackFull bật): **24/24 PASS**. Hai SoC TB PASS với scoreboard L1 (0 vi phạm).

## Cập nhật tiến độ 2026-09-27 (branch `work/p15-p25` → `work/p25-exclusive`)

| Bước | Trạng thái | Commit / bằng chứng |
|---|---|---|
| Gộp `work/p02-wb-phase2` | ✅ | `git merge --ff-only` ở `D:\Github\CHI_Interconnect` (`8c26336..9b99fad`); `run_regression.ps1` được stash riêng rồi pop, dòng AMO của phiên khác giữ nguyên. |
| **1.5 đầy đủ** (P0-3) | ✅ (`841be1a`) | **SN** (`chi_sn_axi_bridge.v`): mỗi WriteNoSnp nhận một slot (`CHI_DEFAULT_SN_WR_SLOTS`: 4 IoT, 8 full); số slot là DBID trong DBIDResp và là TxnID mà WriteData phải mang. Beat vào line buffer của slot theo DataID, thứ tự và xen kẽ tùy ý; slot đủ 16 beat vào hàng đợi AXI; AW + 16 W với WLAST từ bộ đếm của chính engine; Comp mang BRESP. SN luôn nhận WriteData (không backpressure). **HN**: WriteData tới SN mang DBID của SN (write tracker, bộ ghi victim/dirty-snoop). DBIDResp/CompDBIDResp cho RN do write tracker gửi **sau khi** SN đã cấp DBID, nên beat của RN tới HN luôn chuyển tiếp được, không kẹt đầu DAT sink chung (tránh deadlock HOL). Bỏ `wr_trackers_idle` và `wr_burst_open_q`; chỉ chặn lệnh ghi thứ hai **cùng dòng** (`wr_line_hazard`). Cờ discard của CopyBack cũ nằm trong entry tracker. **T53** (RED trên RTL cũ: chỉ 1 tracker hoạt động): giữ WriteData của hai RN, mở link luân phiên để hai burst xen kẽ tại SN (28–30 beat xen kẽ), kiểm cả hai dòng. Checker khớp WriteData tới SN theo DBID. |
| Sửa sau 1.5 | ✅ (`4e7dba0`) | `run_stress_seeds.ps1` bắt 2 lỗi (22/24): (a) rn3 seed 4 treo — DBIDResp của write tracker đứng trước Comp exclusive-fail trong mux TX RSP nhưng `excl_fail_valid_q` vẫn bị xóa khi cả hai cùng valid, Comp bị mất; (b) rn2 seed 6 — lỗi scoreboard: RN bỏ bản của mình khi **nhận** MakeUnique, nhưng scoreboard chỉ quên dòng khi MakeUnique xong; giờ MakeUnique tính là thay đổi đang chờ từ lúc nhận tới response. Sau sửa: stress 24/24, regression 14/14. |
| **2.5** exclusive theo B6.3 | ✅ (commit 2.5) | **RED**: luật checker mới `SPEC_EXCL_OPCODE` (Excl chỉ trên ReadShared, ReadNoSnp, CleanUnique, WriteNoSnp) báo 10 lỗi trên tb_CHI cũ (ReadUnique/WriteUnique mang Excl). **RN** (chế độ cache nội bộ): LDREX → ReadShared(Excl) (fill SC). STREX: FE kiểm monitor cục bộ; dòng UC/UD → store tại chỗ (thành công, không giao dịch); SC/SD → CleanUnique(Excl); dòng đã mất → thất bại tại chỗ. Comp EXOKAY → merge store vào dòng (→ UD) rồi gửi **CompAck** (TxnID = DBID của Comp); Comp OKAY → thất bại + CompAck. Chế độ L1 ngoài giữ WriteUnique (tham số `STREX_CLEAN_UNIQUE`, chưa có ai dùng LDREX/STREX ở đó). **HN**: CleanUnique(Excl) kiểm monitor như store; cả hai nhánh chờ CompAck (`HN_ST_WAIT_ACK`, Comp mang `DBID_MAIN`); CompAck chỉ cập nhật SF với lệnh đọc; monitor được đặt khi ReadShared(Excl) xong (cả đường LLC-hit); request sắp làm RN khác unique (ReadUnique/CleanUnique/MakeUnique, trừ exclusive thất bại) xóa reservation của RN khác trên dòng; CleanUnique snoop bằng SnpUnique (không dùng SnpMakeInvalid vì nó bỏ dữ liệu dirty). **Checker**: CleanUnique từ RN nợ CompAck sau Comp; trace RSP in thêm RespErr. **Monitor P7** (`chi_excl_mutex_formal`) giả định một reservation/dòng — sai với B6.3; viết lại thành “exclusive store thành công kết thúc mọi reservation trên dòng”. `run_regression.ps1`/`run_stress_seeds.ps1` giờ tính `FATAL` là lỗi. **Test**: T15 kiểm dữ liệu STREX qua lần đọc coherent của RN1 (không còn AXI write); **T54** hai RN cùng LDREX rồi cùng STREX: đúng một bên thắng, bên thua đọc dữ liệu bên thắng (bắt được lỗi exclusive thất bại vẫn xóa reservation của RN kia). |
| Sửa sau 2.5 | ✅ (cùng commit 2.5) | Stress lần đầu 23/24: rn3 seed 7 dừng ở `chi_hn_f unexpected RSP opcode 2 txn c0 in state 7`. Không phải trùng DBID: CompAck đúng là của CleanUnique đang giữ (TxnID = `DBID_MAIN`, src khớp), nhưng `comp_ack_fire` còn chờ `filter_update_ready` (snoop filter đang bận một thao tác 2 chu kỳ của tracker khác). Danh sách `rsp_expected_stall` của bộ chẩn đoán thiếu trường hợp này — lỗ hổng tiềm ẩn từ trước (đường LLC-hit cũng chờ ở `HN_ST_WAIT_ACK`), 2.5 làm lộ ra vì CleanUnique giờ cũng chờ CompAck. Sửa: tách `main_comp_ack_match`, `comp_ack_fire = main_comp_ack_match && filter_update_ready`, và thêm `main_comp_ack_match` vào `rsp_expected_stall`; câu báo lỗi RSP in thêm src, opcode/src/addr của request đang giữ và `filter_update_ready`. Sau sửa: rn3 seed 7 PASS, stress 24/24, regression 14/14, tb_CHI T01..T54 ICG sạch. |

**Còn lại sau 2.5:** MakeUnique vẫn không gửi CompAck (ExpCompAck=1 nhưng HN không chờ; đã sửa ở 2.8); STREX thất bại “giả” khi dòng đã bị evict khỏi cache RN giữa LDREX và STREX (được phép theo kiến trúc, nhưng cần nhớ khi chạy CoreMark/LR-SC); RN chưa hỗ trợ trạng thái UCE nên không CleanUnique từ I.

## Cập nhật tiến độ 2026-09-28 (branch `work/p26-flit`)

`work/p25-exclusive` đã gộp fast-forward vào `fix/phase1-correctness` (`9b99fad..41c3365`, stash riêng `run_regression.ps1` như trước). 2.6 chia ba bước, mỗi bước commit riêng khi regression 14/14, stress 24/24 và tb_CHI ICG sạch:

| Bước | Trạng thái | Nội dung |
|---|---|---|
| **2.6a** DAT 128 bit (O2) | ✅ | Tham số mới `DAT_DATA_W` (`CHI_DEFAULT_DAT_DATA_W`=128) cho kênh DAT của CHI: 4 beat/dòng. `DATA_WIDTH` giữ nghĩa độ rộng word CPU và AXI của SN (32), nên giao diện `chi_top`, TB, SoC và bridge RISC-V không đổi. `chi_top` truyền `DAT_DATA_W` cho HN, fabric, checker và phần DAT của RN (`dat_rx`, `wdat_engine`, `snoop_handler`). **SN** đổi độ rộng: line buffer của slot ghi theo beat DAT, AXI W đọc lần lượt từng lát `DATA_WIDTH`; phía đọc gom `DAT_DATA_W/DATA_WIDTH` beat R thành một beat CompData (RespErr = RRESP nặng nhất), `rready` chờ khi beat trước chưa được nhận. TB giải mã flit trong DUT dùng `DAT_DATA_W`; tb_CHI tách `DAT_BEATS` (bộ đếm beat DAT) khỏi `BEATS` (word CPU/AXI). Kết quả: tb_CHI T01..T54 (mặc định + ICG), regression 14/14, stress 24/24; T53 vẫn thấy WriteData xen kẽ ở SN (4 beat), mô phỏng stress nhanh hơn khoảng 25%. |
| **2.6b** opcode REQ 7 bit, SNP 5 bit | ✅ | Thêm `CHI_REQ_OPCODE_W`=7 (B13.9.1, Opcode[6:0]) và `CHI_SNP_OPCODE_W`=5; hằng opcode REQ thành `7'h..`, SNP thành `5'h..`. Mọi chỗ hardcode `[5:0]`, `+: 6`, `3 + 6` và `6'd0` (RTL, boundary adapter, checker, tb_CHI, tb_chi_boundary_roundtrip) dùng hai macro này; biến giữ opcode snoop (cache RN, snoop handler) giờ 5 bit. Kết quả: regression 14/14, stress 24/24, tb_CHI T01..T54 ICG (`CHI_SIM_REAL_ICG +CG_ALWAYS`), 0 lỗi checker. |
| **2.6c** layout Table B13.6–B13.9 | ✅ | `chi_defs.vh` là include duy nhất cho layout flit: mọi offset field tính từ bit 0 theo đúng thứ tự Table B13.6–B13.9 và chỉ phụ thuộc NID (DAT thêm DW). Addr trên dây 44 bit (`CHI_REQ_ADDR_W`), RTL giữ `ADDR_WIDTH`=32 bit thấp và lái phần còn lại bằng 0. PAS 3 bit (thay NS), LPID 8 bit, TxnID/DBID 12 bit, QoS 4 bit. **SNP** không còn TgtID/Size, Addr là Addr[43:3]; Sync của DVM giờ nằm ở DVMType = SNP.Addr[10:8] (Table B8.10). **DAT** bỏ `BYTE_OFF`, dùng DataID 2 bit (= Addr[5:4] của byte thấp nhất trong beat, `CHI_DAT_DATAID_SHIFT`). Macro `CHI_FLIT_PARAM_CHECK` `$fatal` lúc elaborate khi NID/ADDR/TxnID/DBID/QoS/DW sai hoặc tổng độ rộng lệch dòng "Total" của B13.9 (REQ 137, RSP 71, SNP 94, DAT 240 ở NID 7, DW 128); gọi ở `chi_top` và mọi module tự dựng/tách flit. `synth_iot_direct_reports.tcl` đọc RTL ở chế độ `-sv` để check này chạy khi tổng hợp. Boundary adapter viết lại theo layout mới; `tb_chi_dat_byte_offset_xbar5` đổi thành `tb_chi_dat_dataid_rx`; `tb_chi_boundary_roundtrip`, `tb_chi_dat_boundary_attrs` kiểm field theo bảng spec. Kết quả: regression 14/14, stress 24/24, tb_CHI T01..T54 mặc định và ICG, 0 lỗi checker. |

## Cập nhật tiến độ 2026-09-29: xong 2.6, Giai đoạn 2 còn lại

`work/p26-flit` (2.6a, 2.6b, 2.6c) gộp fast-forward vào `fix/phase1-correctness`. Giai đoạn 2 còn các mục sau:

| Mục | Mức | Nội dung |
|---|---|---|
| **2.7** DVM theo B8 | ✅ | Xem mục “Cập nhật 2.7” bên dưới. |
| **2.8** CompAck cho MakeUnique | ✅ | Xem mục “Cập nhật 2.8” bên dưới. |
| **2.9** SnpRespFwded / SnpRespDataFwded | ✅ | Xem mục “Cập nhật 2.9” bên dưới. |
| Trạng thái UCE ở RN | để sau | RN chưa có UCE, nên không CleanUnique từ trạng thái I được. |

### Cập nhật 2.7 (branch `work/p27-dvm`)

| Mục | Trạng thái | Nội dung |
|---|---|---|
| **2.7** DVM theo B8 | ✅ (commit 2.7) | **Luồng**: DVMOp là lệnh ghi 8 byte tới MN (`CHI_DVM_REQ_SIZE`=0b011, Order 0, không ExpCompAck, Addr[3]=0). MN trả **DBIDResp**, RN gửi **một beat NonCopyBackWriteData** (BE[7:0], Data[63:0] = payload; Sync không có payload, Table B8.21), MN gửi **SnpDVMOp 2 phần** (cùng TxnID, SNP.Addr[0] = số phần; Part 1 `{Data[46:44], REQ.Addr[40:4], 0}`, Part 2 `{Data[43:4], 1}`) tới **mọi RN trừ RN khởi tạo**, chờ SnpResp_I của từng RN rồi gửi một Comp. Loại Sync lấy từ DVMType = REQ.Addr[13:11] (bỏ mã hóa qua Size và `CHI_DVM_KIND_*`, `CHI_RESP_DVM_ACK`). MN không tự chèn Sync; Sync chỉ chờ `cfg_drain_cycles` trước khi snoop. **RTL**: `chi_mn_dvm.v` viết lại (thêm cổng DAT vào MN qua `chi_hn_i_mn` và `chi_top`); `chi_rn_req_engine`/`chi_rn_wdat_engine` coi DVMOp như lệnh ghi 1 beat; `chi_rn_snoop_handler` có bộ gom SnpDVMOp riêng (`DVM_SLOTS` ≥ 2, nhận hai phần theo thứ tự bất kỳ mà không chặn snoop khác, trả SnpResp khi đủ hai phần); `chi_rn_f` xóa reservation của RN khởi tạo khi nó phát DVMOp (MN không snoop nó nữa). **Checker**: luật spec mới `SPEC_DVM` (Size/Order/ExpCompAck/Addr[3] của DVMOp; SnpDVMOp chỉ khi MN có DVMOp đang mở và đã nhận payload; không snoop RN khởi tạo; mỗi RN một SnpDVMOp mỗi DVMOp; Comp sau khi đủ SnpResp); DVMOp có DBIDResp và đúng 1 beat WriteData. **RED**: trên RTL cũ, `SPEC_DVM` báo 4 lỗi (SnpDVMOp tới RN khởi tạo, Comp sau khi snoop mask 0x3) và **T55** fail (mỗi RN nhận 2 SnpDVMOp non-sync, 11 flit phần). **Test**: T26 cập nhật (DVMOp xóa reservation của RN khởi tạo và, qua SnpDVMOp, của RN kia); **T55** kiểm luồng B8 ở mức flit cho DVMOp non-sync và Sync. Plusarg `DVM_ONLY` chạy T26 và T55. **Kết quả**: regression 14/14, stress 24/24, tb_CHI T01..T55 ở chế độ mặc định và `CHI_SIM_REAL_ICG +CG_ALWAYS` (clock bị tắt 12 965 chu kỳ), 0 lỗi checker (736 request, 149 snoop) và scoreboard. |

### Cập nhật 2.8 (branch `work/p28-makeunique-ack`)

| Mục | Trạng thái | Nội dung |
|---|---|---|
| **2.8** CompAck cho MakeUnique | ✅ (commit 2.8) | **Spec**: RN-F phải gửi CompAck cho CleanUnique và MakeUnique (B2.7.2, Table B2.8; Figure B5.11). Home giữ dòng tới khi nhận CompAck (B5.6.4). Trước 2.8, RN đặt ExpCompAck=1 cho MakeUnique nhưng không gửi CompAck, còn HN không chờ. **RN** (`chi_rn_f.v`): thanh ghi riêng `mu_compack_*` gửi CompAck (TxnID = DBID của Comp, TgtID = SrcID của Comp) khi Comp của MakeUnique tới. Cơ chế này dùng chung cho chế độ cache nội bộ lẫn L1 ngoài (dcache của SoC cũng phát MakeUnique). Khi CompAck đó còn chờ thì giữ RSP kế tiếp; thanh ghi được tính vào `busy` (clock gate). Thứ tự ưu tiên trên RSP: SnpResp > CompAck của read > CompAck của MakeUnique > CompAck của CleanUnique. **HN** (`chi_hn_f.v`): mọi `start_upgrade` (CleanUnique và MakeUnique) vào `HN_ST_WAIT_ACK`, Comp mang `DBID_MAIN`. **Checker**: MakeUnique từ RN nợ CompAck sau Comp (hợp đồng mặc định, như CleanUnique). Luật spec mới `SPEC_MKUNIQUE_COMPACK`: home không được snoop một dòng khi RN còn nợ CompAck của CleanUnique/MakeUnique trên dòng đó. **Test T56** (`MU_ONLY`): RN1 ReadShared rồi RN0 MakeUnique; giữ đầu ra RSP của RN0 (ép cả `tx_rsp_link_valid` lẫn `tx_rsp_link_ready` ở ranh giới nguồn→link), RN1 đọc lại dòng. Trong 300 chu kỳ HN không được snoop RN0 và lệnh đọc chưa xong; sau khi thả, CompAck có TxnID = DBID của Comp, snoop tới RN0 đến sau CompAck, RN1 nhận đúng dữ liệu. **RED**: trên RTL cũ, `SPEC_MKUNIQUE_COMPACK` báo 1 lỗi (SnpSharedFwd tới RN0 khi còn nợ CompAck) và T56 fail. **Kết quả**: tb_CHI T01..T56 ở chế độ mặc định và `CHI_SIM_REAL_ICG +CG_ALWAYS` (clock bị tắt 12 994 chu kỳ), 0 lỗi checker (740 request, 152 snoop) và scoreboard; regression 14/14; stress 24/24. |

### Cập nhật 2.9 (branch `work/p29-snprespfwded`)

| Mục | Trạng thái | Nội dung |
|---|---|---|
| **2.9** SnpRespFwded / SnpRespDataFwded | ✅ (commit 2.9) | **Spec**: snoopee của SnpSharedFwd/SnpUniqueFwd gửi CompData cho requester và **một** phản hồi cho home: SnpRespFwded (không dữ liệu) hoặc SnpRespDataFwded (có dữ liệu, DAT opcode 0x6). Resp = trạng thái cuối của snoopee, FwdState = Resp của CompData đã gửi (Table B4.58, B4.59, B13.37). Trước 2.9, RN trả SnpRespFwded mang mã nội bộ `{0,dirty,hit}` rồi còn gửi thêm SnpRespData làm bản sao về home. **RN** (`chi_rn_snoop_handler.v`): chỉ dòng dirty mới được forward. SnpSharedFwd: RN giữ dòng dirty, gửi CompData_SC và SnpResp_SD_Fwded_SC. SnpUniqueFwd: RN chuyển dòng dirty cho requester, gửi CompData_UD_PD và SnpResp_I_Fwded_UD_PD. Riêng L1 ngoài (SoC): L1 xóa dirty khi nhận SnpSharedFwd, nên RN gửi CompData_SC rồi **SnpRespData_SC_PD_Fwded_SC** về home (`forward_home_q`), không gửi SnpRespFwded. **HN** (`chi_hn_f.v`): bỏ `forward_copy_expected_q` và mã `CHI_RESP_DIRTY_BIT`. Chỉ phản hồi có dữ liệu mới làm dòng dirty ở home. SnpRespDataFwded đi qua LLC; SnpRespFwded chỉ cập nhật SF. **Fwd snoop chỉ gửi khi snoop đúng một RN-F** (`chi_hn_snoop_generator.v`, B4.8.3.4). Có từ hai sharer trở lên thì mọi sharer nhận SnpShared/SnpUnique thường và home cấp dữ liệu. Trước đây HN gửi Fwd snoop tới mọi sharer: với 3 RN, một sharer forward còn sharer kia trả SnpResp_I, và nhánh phản hồi thường cuối cùng đưa tracker về `SNP_ST_REPLAY`, nên requester nhận CompData hai lần (stress rn3 fail 8/8, `COMPDATA_UNKNOWN_TXN`). **Checker**: luật `SPEC_SNPRESP_FWD` kiểm tra: mỗi Fwd snoop có đúng một phản hồi; cặp (Resp, FwdState) hợp lệ; FwdState bằng Resp của CompData; snoopee đã forward thì không trả SnpResp/SnpRespData thường; khi một Fwd snoop còn mở thì home không snoop RN khác trên cùng dòng. Bộ đếm `SnpRespFwded=`/`SnpRespDataFwded=` in trong `CHI_CHK SUMMARY`. **Test**: T36/T37 của tb_CHI viết lại (Resp/FwdState của cả hai loại, không có dữ liệu về home sau SnpRespFwded, RN1 nhận UD sau ReadUnique). **tb_chi_soc_cluster_ip_deep T9** (mới) là test duy nhất chạy qua nhánh SnpRespDataFwded: L1 core1 giữ dòng dirty, core0 ReadShared cả dòng. Test kiểm SnpSharedFwd, CompData_SC mang dữ liệu dirty tới core0, SnpRespDataFwded SC_PD/FwdState SC tới HN, HN ghi dòng về bộ nhớ, L1 core1 còn valid và sạch, SF có cả hai core. Các test sau trong TB này lùi một số (T10..T13). CoreMark dual-core không chạm nhánh này vì TB đặt `USE_EXTERNAL_L1_SNOOP(0)`. **dcache và CompData_UD_PD**: an toàn. dcache chỉ gửi ReadUnique khi `req_write_q`=1 và lúc fill đặt `dirty = req_write_q` (`dcache.v:433`), nên dòng được cài dirty ngay trong chu kỳ fill; T02 của `tb_riscv_dcache_writeback_chi` chứng minh (eviction ghi lại dữ liệu store). **RED**: trên RTL cũ, FWD_ONLY báo 3 lỗi `SPEC_SNPRESP_FWD` và T36 fail. Khi bỏ điều kiện một sharer, rn3 s8 báo `SPEC_SNPRESP_FWD` ở 8,1 µs, trước `COMPDATA_UNKNOWN_TXN`. **Kết quả**: regression 14/14; stress 24/24 (rn2, rn3, icg × 8 seed; 0 lỗi checker và scoreboard); tb_CHI T01..T56 ở chế độ mặc định và `CHI_SIM_REAL_ICG +CG_ALWAYS` (clock bị tắt 13 548 chu kỳ), 0 lỗi checker (719 request, 148 snoop) và scoreboard; deep TB 13/13. |

## Cập nhật tiến độ 2026-10-01: Giai đoạn 3 (branch `work/p30-link`)

| Mục | Trạng thái | Nội dung |
|---|---|---|
| **3.0** luật `SPEC_LINK_CREDIT`, opcode LCrdReturn | ✅ `4596ffd` | **Checker** `chi_link_credit_checker.sv` (bind vào `chi_top`, một instance cho mỗi kênh và mỗi chiều, tổng 8): mỗi link có bộ đếm credit riêng; FLITV khi credit = 0 là lỗi; credit nhận ở chu kỳ t chỉ dùng được từ t+1; LCRDV vượt 15 hoặc vượt số buffer của bên nhận là lỗi (B14.2.1). `chi_top` đặt tên dây LCRDV cho từng link (`*_src_lcrdv`, `*_in_lcrdv`, `*_tgt_lcrdv`, `*_out_lcrdv`). `chi_defs.vh` thêm `CHI_REQ_LCRD_RETURN`, `CHI_SNP_LCRD_RETURN`, `CHI_DAT_OPCODE_LCRD_RETURN` (B13.11). **RED**: trên RTL cũ tb_CHI vẫn PASS chức năng nhưng luật báo 542 lỗi ở DAT node → fabric (chủ yếu HN): khi input buffer của fabric backpressure, FLITV bị giữ nhiều chu kỳ mà không có credit. |
| **3.5** TB đơn vị link | ✅ `4596ffd` | Module mới: `chi_link_tx` (một thanh ghi giữ, credit bắt đầu từ 0, FLITV chỉ khi có credit, FLITPEND trước FLITV), `chi_link_rx` (FIFO, cấp một credit cho mỗi ô trống, trả credit khi pop), `chi_link_lcrd_gen` (bộ cấp credit, dùng chung cho `chi_link_rx` và input FIFO của fabric). `tb_chi_link_layer`: 15 case với nguồn, đích, độ trễ dây và độ trễ LCRDV ngẫu nhiên; kiểm thứ tự, mất/lặp flit, FLITPEND, tràn RX và bảo toàn credit (credit ở TX + trên dây + trong FIFO + chưa cấp = độ sâu). Đã thêm vào `run_regression.ps1`. **RED bằng đột biến**: dùng credit ngay chu kỳ nhận, trả credit lúc nhận thay vì lúc pop, và bỏ ready ở TX đều bị bắt. Activate/deactivate ngẫu nhiên để lại cho 3.3. |
| **3.1a** credit thật node → fabric | ✅ `5dbca06` | `chi_link_layer` bọc `chi_link_tx`: cổng TX của node là cổng link thật (`tx_*_valid` = FLITV, `tx_*_lcrdv` = LCRDV). Trong `chi_top`, mỗi input FIFO của fabric cấp `FABRIC_FIFO_DEPTH` credit sau reset và thêm một credit mỗi lần pop (`*_in_pop_pulse`); có `$stop` nếu flit gặp FIFO đầy. Các đường TX trước đây đi thẳng vào fabric nay qua link: **HN** có link SNP (target ID đi kèm flit), link REQ tới SN (cổng `mem_req_*` cũ thành `tx_req_*`) và một link DAT duy nhất. Arbiter round-robin giữa CompData và WriteData tới SN chuyển từ `chi_top` vào `chi_hn_f`, đứng trước link DAT; **MN** có link SNP và RSP. `busy` của node tính theo FLITPEND, nên clock gate không tắt clock khi node còn giữ flit chờ credit. **Testbench**: monitor coi `valid && lcrdv` là flit đã gửi nay chỉ dùng FLITV; T01/T13 xem arbiter bên trong `chi_hn_f`; các test HN slot giữ DAT ở ranh giới arbiter → link của HN (ép cả `dat_arb_valid` lẫn `dat_arb_ready`); `tb_chi_rn_f_qos_xbar4` cấp cho RN một credit REQ. tb_CHI chạy 445,6 µs so với 438,3 µs (+1,7%). |
| **3.1b** credit thật fabric → node | ✅ `4856529` | Mỗi output của fabric có bộ đếm credit riêng cho node đích (bắt đầu từ 0) và chỉ pop output register khi có credit: FLITV = `*_out_valid && *_out_ready`. Phía nhận là `chi_link_rx` đặt ở ranh giới node trong `chi_top`, sâu `INIT_CRD`, trả LCRDV khi node lấy flit; cổng RX của node vẫn là valid/ready. **Module fabric và arbiter QoS không đổi**, nên rủi ro QoS trong kế hoạch không xảy ra. `chi_link_rx` có `FALLTHROUGH`: flit tới buffer rỗng được đưa cho node ngay trong chu kỳ đó, nên link không thêm độ trễ (tb_CHI vẫn 445,6 µs). Flit nằm trong buffer RX được tính là busy cho clock gate. |
| **3.2** FLITPEND | ✅ `b155a73` | Node: `tx_*_flitpend` ra cổng của RN/HN/SN/MN (và `chi_hn_i_mn`). Fabric: `chi_channel_slice`/`chi_fabric` thêm `*_out_pend` (flit đang ở hoặc đang vào output register). Checker thêm luật `SPEC_LINK_FLITPEND`: FLITV phải có FLITPEND ở chu kỳ trước (B14.4). **RED bằng đột biến**: FLITPEND chỉ theo flit đang giữ thì TB đơn vị fail ở chu kỳ 3; `out_pend` bỏ phần flit đang vào thì mọi flit fabric → node của tb_CHI đều vi phạm. |

**Băng thông đo được** (`tb_chi_link_layer`, nguồn và đích luôn sẵn sàng, đơn vị flit/chu kỳ):

| Link | Round trip credit | Depth 1 | Depth 2 (IoT) | Depth ≥ 4 |
|---|---|---|---|---|
| Node → fabric (FIFO thường) | 3 chu kỳ | 0,33 | 0,67 | 1,0 |
| Fabric → node (fall-through) | 2 chu kỳ | 0,50 | 1,0 | 1,0 |

Ở profile IoT (`FABRIC_FIFO_DEPTH` = 2), chiều node → fabric bị giới hạn 0,67 flit/chu kỳ khi gửi liên tục. tb_CHI chỉ chậm 1,7%, nên chưa nâng độ sâu. Nếu cần băng thông đầy đủ thì có hai cách: nâng `FABRIC_FIFO_DEPTH` của IoT lên 3, hoặc cho `chi_link_lcrd_gen` trả LCRDV ngay trong chu kỳ pop (round trip còn 2).

**Kết quả sau 3.2**: regression 16/16; stress 24/24; tb_CHI T01..T56 ở chế độ mặc định và `CHI_SIM_REAL_ICG +CG_ALWAYS` (clock bị tắt 13 589 chu kỳ); 0 lỗi `SPEC_LINK_CREDIT` và `SPEC_LINK_FLITPEND` trên cả 8 nhóm link (719 REQ, 1060 RSP, 2767 DAT, 151 SNP flit mỗi chiều).

## 1. Bảng trạng thái tổng hợp

Ký hiệu: ✅ đã sửa · 🟢 đã đúng từ trước (không cần sửa) · 🟡 mới giảm thiểu hoặc sửa một phần · ❌ chưa sửa

### Giai đoạn 1: sửa tính đúng

| Mục | Trạng thái | Bằng chứng |
|---|---|---|
| **P0-1** Snoop filter ghi đè sharer | ✅ **Đã sửa** | Thêm cổng `update_merge` ([chi_hn_snoop_filter.v:34](../hn/chi_hn_snoop_filter.v#L34)). HN bật merge cho đọc kiểu Shared, read tracker có thêm `ack_shared`. Test **T40** fail trên RTL gốc và pass sau khi sửa. |
| **P0-2** LLC cũ sau khi ghi | ✅ Có test bảo vệ (`4760670`) | `llc_invalidate_valid = start_write`. T46 fail khi bỏ invalidate. Sau H1 (lệnh ghi không để lại sharer trong SF) đây là cơ chế duy nhất chống LLC cũ ở mọi cấu hình. |
| **N-2** read HN→SN không căn dòng | ✅ Đã sửa (Giai đoạn 4) | Xem bảng tiến độ Giai đoạn 4. |
| **N-3** deadlock POS `out1` | ✅ Đã sửa (Giai đoạn 4) | Xem bảng tiến độ Giai đoạn 4. |
| **N-4** đọc vượt lệnh ghi cùng dòng | ✅ Đã sửa (`7ad2028`) | `start_mem_read` chờ write tracker cùng dòng. T52. |
| **P0-3** Trộn beat ghi tại SN | ✅ Đã sửa (1.5 đầy đủ, `841be1a`) | SN có slot + line buffer theo DBID, WriteData khớp theo TxnID = DBID, WLAST từ bộ đếm của AXI engine. HN cho nhiều lệnh ghi outstanding (chỉ chặn cùng dòng), DBIDResp cho RN chờ DBID của SN. T53, T44. |
| **P0-4** Cache RN-F không phải cache thật | ✅ Đã sửa (A1, `3187ff1`) | Front end RN-F + cổng CPU nguyên tử của cache; đọc/store trúng phục vụ tại chỗ; ghi không cấp phát; WriteBack chỉ từ owner, non-owner thành WriteUnique; HN ghi dữ liệu dirty từ snoop về bộ nhớ và bỏ CopyBack cũ. T47..T51. |
| Timeout mang tính chức năng | ✅ Đã sửa (1.2) | `FUNCTIONAL_TIMEOUT=0` mặc định ([chi_rn_f.v:380](../rn/chi_rn_f.v#L380)). Timeout chỉ còn là watchdog → `ERR_STATUS[4]` + IRQ. T42. |
| TxnID riêng cho snoop | ✅ Đã sửa (1.3, trong `38200cf`) | TxnID snoop do home cấp theo (entry, RN đích); luật `SPEC_SNP_TXNID_HOME` sạch ở mọi TB. |
| TxnID riêng cho HN→SN | ✅ Đã sửa (1.4) | Tag lớp `2'b01` read ([chi_hn_f.v:3478](../hn/chi_hn_f.v#L3478)), `2'b10` write ([chi_hn_write_tracker.v:108](../hn/chi_hn_write_tracker.v#L108)), evict all-ones. T43 + checker ở SN. |
| P1: Clock gate | ✅ Đã sửa (1.7) | `chi_cg_en` OR `chi_busy` của mọi node và fabric ([chi_top.v:275](../chi_top.v#L275)). Chạy được với mô hình ICG thật. |
| P1: `fabric_clear` | ✅ Đã sửa (1.7) | Chỉ phát khi hệ rảnh; nếu đang bận thì từ chối và set `ERR_STATUS[5]` ([chi_top.v:285](../chi_top.v#L285)). T45. Tracker trong node vẫn không bị xóa bởi BIST init (không cần, vì chỉ cho phép khi rảnh). |
| **N-1** Timeout che lỗi liveness | ✅ Đã sửa (1.1) | T30 không còn dòng `transaction timeout`; tb_CHI fail khi có bất kỳ timeout nào ở RN. |

### Giai đoạn 2: tầng protocol (✅ 2.1–2.9)

| Mục | Trạng thái | Ghi chú |
|---|---|---|
| Giá trị opcode REQ/RSP/SNP/DAT | ✅ Đã đúng mã spec (từ trước phiên P0) | [chi_defs.vh:109-161](../common/chi_defs.vh#L109): ReadShared 0x01, ReadOnce 0x03, MakeUnique 0x0C, Evict 0x0D, WriteBackFull 0x1B, DVMOp 0x14; RSP 5 bit; SnpUnique 0x07, SnpMakeInvalid 0x0A, SnpDVMOp 0x0D. |
| Độ rộng opcode REQ | ✅ 2.6b (`5e3de57`) | REQ 7 bit, SNP 5 bit (`CHI_REQ_OPCODE_W`, `CHI_SNP_OPCODE_W`). |
| Format flit theo Table B13.x | ✅ 2.6a (`580451c`), 2.6c | DAT 128 bit; layout REQ/RSP/SNP/DAT đúng Table B13.6–B13.9, SNP bỏ Size và Addr[2:0], DAT dùng DataID; `$fatal` kiểm độ rộng lúc elaborate. |
| CompAck TxnID = DBID | ✅ 2.1 (`6eaba0c`) | RN gửi CompAck với DBID của CompData; HN khớp theo DBID. |
| WriteData TxnID = DBID | ✅ 2.1 (`6eaba0c`) | WDAT engine dùng DBID làm TxnID; write tracker khớp theo (DBID, nguồn). |
| Resp trong CompData | ✅ 2.2 (`a090b28`) | Mã spec; RN fill theo Resp. |
| SnpRespData thay cho SnpResp | ✅ 2.3 (`38200cf`) | Chỉ SnpRespData khi có dữ liệu; Resp = trạng thái cuối + PassDirty. |
| SnpRespFwded / SnpRespDataFwded | ✅ 2.9 | Resp/FwdState theo Table B4.58/B4.59/B13.37; không còn bản sao dữ liệu về home sau SnpRespFwded; Fwd snoop chỉ khi snoop đúng một RN-F (B4.8.3.4). Luật `SPEC_SNPRESP_FWD`; T36, T37, deep T9. |
| CopyBack nhận CompDBIDResp | ✅ 2.4 (`8a03450`) | |
| SN gửi DBIDResp trước dữ liệu | ✅ 2.4 (`8a03450`), 1.5 (`841be1a`) | Mỗi lệnh ghi một slot/DBID; nhiều lệnh ghi outstanding. |
| Luồng exclusive | ✅ 2.5 | LDREX → ReadShared(Excl); STREX → store tại chỗ nếu sở hữu, ngược lại CleanUnique(Excl) + merge + CompAck. Luật `SPEC_EXCL_OPCODE` sạch. T15–T17, T27, T54. |
| RetryAck / PCrdGrant | ✅ Đã có (từ trước) | Một pool PCrdType=0 duy nhất. T35 kiểm chứng. |
| DVM | ✅ 2.7 | DVMOp → DBIDResp → NonCopyBackWriteData (payload 8 byte) → SnpDVMOp 2 phần tới các RN khác → Comp. Sync theo DVMType; MN không tự chèn Sync, không snoop RN khởi tạo. Luật `SPEC_DVM`; T26, T55. |
| CompAck của CleanUnique/MakeUnique | ✅ 2.5, 2.8 | RN gửi CompAck (TxnID = DBID của Comp); HN giữ dòng ở `HN_ST_WAIT_ACK` tới khi nhận. Luật `SPEC_MKUNIQUE_COMPACK`; T15, T54, T56. |

### Giai đoạn 3: link layer: ✅ xong 3.0–3.5

- ✅ Credit thật trên mọi link giữa node và fabric, cả hai chiều (3.1a, 3.1b). Không còn tín hiệu ready ở ranh giới link: FLITV chỉ lên khi bên gửi có L-Credit, và bên nhận trả LCRDV khi buffer được giải phóng.
- ✅ FLITPEND đi trước FLITV một chu kỳ trên mọi link (3.2).
- ✅ Luật checker `SPEC_LINK_CREDIT` và `SPEC_LINK_FLITPEND`, TB đơn vị `tb_chi_link_layer` (3.0, 3.5).
- ✅ LINKACTIVEREQ/ACK trên mọi link (3.3). Mỗi node có hai link (phát và nhận), mỗi link một cặp REQ/ACK cho mọi kênh. Flit và credit chỉ đi ở RUN. Khi DEACTIVATE, bên phát trả từng credit bằng flit LCrdReturn, và bên nhận chỉ hạ ACK khi mọi credit đã về. Clock của fabric chỉ tắt khi mọi link ở STOP. Luật checker `SPEC_LINK_ACTIVE`.
- ✅ TX/RXSACTIVE của mọi node và SYSCOREQ/SYSCOACK của mọi RN (3.4). TXSACTIVE là cờ busy của node; RXSACTIVE là hoạt động phía interconnect. Mỗi RN vào/ra coherency domain qua CSR `SYSCO_CTRL`: muốn rời thì RN tự flush cache rồi mới hạ SYSCOREQ, HN và MN không snoop RN ngoài domain, và SYSCOACK chỉ hạ khi snoop filter đã xóa RN đó. Luật checker `SPEC_SACTIVE` và `SPEC_SYSCO`; test T57.

### Giai đoạn 4: kiểm chứng: ✅ 4.1–4.3 và mở rộng stress; 🟡 4.4 còn mở

- **Đã có:**
  - Checker giao thức bind vào mọi `chi_top` (4.2). Lúc đầu có 7 luật spec; Giai đoạn 2 thêm `EXCL_OPCODE` (2.5), `DVM` (2.7), `MKUNIQUE_COMPACK` (2.8), `SNPRESP_FWD` (2.9), tổng cộng 11, đều bật trong regression.
  - Scoreboard coherence (4.1) trong 3 TB có cache RN nội bộ.
  - TB stress ngẫu nhiên 2/3 RN (4.3), có trong regression.
  - Test có chủ đích T40..T45; chế độ ICG thật.
- **CoreMark (4.4):** từ 2026-10-07 là bước cuối của `run_regression.ps1` (`-SkipCoreMark` để bỏ qua).
- **Chưa có:** Scoreboard L1 ngoài đã có nhưng hai SoC TB gần như không có fill L1 thật (chỉ dòng seed bằng backdoor, được miễn); cần gắn vào TB CoreMark dual-core (file đang được phiên khác sửa) để có độ phủ thật.

### Tối ưu 1–3 (song song): ✅ 2 (trong 2.6a); ❌ 1 và 3

| # | Trạng thái |
|---|---|
| 1. Băng thông fabric | ❌ `chi_flit_reg_slice` vẫn là half-buffer (`in_ready = !valid_q`, [chi_flit_reg_slice.v:25](../common/chi_flit_reg_slice.v#L25)). Profile IoT mặc định dùng `OUTPUT_FIFO_DEPTH=1` ([chi_defs.vh:55](../common/chi_defs.vh#L55)), nên mỗi cổng chỉ đạt 1 flit / 2 chu kỳ. |
| 2. DATA_W 32→128 | ✅ 2.6a (`580451c`): kênh DAT của CHI 128 bit (4 beat/dòng); CPU và AXI vẫn 32 bit. |
| 3. HN tuần tự hóa khi LLC hit | ❌ FSM chính vẫn giữ `HN_ST_SEND_DAT`/`HN_ST_WAIT_ACK` ([chi_hn_f.v:188-189](../hn/chi_hn_f.v#L188)). |

## 2. Những gì đã sửa (chi tiết)

Chi tiết các bước 1.1, 1.2, 1.4, 1.5 và 1.7 nằm trong bảng tiến độ ở trên và trong commit message tương ứng. Mục này ghi phần trước khi có git.

### 2.1 RTL: P0-1 snoop filter merge

- **Nguyên nhân:** khi snoop trả lời sạch, tracker chuyển sang replay. Bước hoàn tất (CompAck của đường LLC-hit, hoặc ack của read tracker) ghi snoop filter với **chỉ requestor**, đè mất sharer cũ.
- **Sửa:**
  - `chi_hn_snoop_filter.v`: thêm cổng `update_merge`. Khi bật và entry đang hit, sharer mới được OR với sharer cũ.
  - `chi_hn_f.v`: chỉ bật merge cho đọc kiểu Shared. Read tracker có thêm output `ack_shared`. ReadUnique, ghi và upgrade vẫn ghi đè như cũ.
- **Kiểm chứng:** T40 fail trên RTL gốc (RN0 vẫn giữ SC sau khi RN1 ReadUnique) và pass sau khi sửa.

### 2.2 Testbench: lỗi của testbench, không phải của RTL

| Test | Nguyên nhân | Sửa |
|---|---|---|
| T31 | `base_mem_pattern` tính theo địa chỉ có byte offset, trong khi mô hình AXI khởi tạo theo dòng đã căn. | Căn địa chỉ về đầu dòng. |
| T27, T36, T37 | Việc ghi lại victim dirty chạy nền (hành vi RTL đúng) rơi vào cửa sổ đếm AXI của test. | Thêm `wait_axi_write_quiet` và gọi nó trong các helper ghi/STREX ở chế độ đếm nghiêm ngặt. |
| T20 (1.7) | Sau lệnh đọc đánh thức, writeback victim của RN chạy nền. Enable cũ bỏ qua việc này nên test pass một cách vô tình. | Chờ `wait_axi_write_quiet(64)` rồi mới kiểm idle. Thêm `cg_busy_dump` in cờ busy nào đang giữ clock khi fail. |
| `tb_chi_soc_cluster_ip_deep` T4/T6 | Geometry backdoor cũ (DCACHE 1K, SF 64). | Suy ra từ tham số, `$fatal` nếu lệch (`d4d4eae`). |
| `tb_riscv_l1_axi_to_chi_bridge_mmio` T03 | TB lái word response thay vì line response. | Lái line response, thêm watchdog (`4d65fd8`). |

Plusarg hỗ trợ debug: `P0_ONLY`, `T31_ONLY`, `TRACE_WDAT`, `WDOG_ONLY` (T42), `SNTXN_ONLY` (T43), `EVW_ONLY` (T44), `BIST_ONLY` (T45), `CG_ALWAYS`.

---

## 3. Kế hoạch cho các lỗi còn lại

Nguyên tắc chung cho mọi bước:

1. **Viết test tái hiện trước** (phải fail trên RTL hiện tại), rồi mới sửa.
2. Mỗi bước phải giữ `scripts/run_regression.ps1` sạch. Bước nào chạm HN-F/RN-F thì chạy thêm tb_CHI ở chế độ `CHI_SIM_REAL_ICG +CG_ALWAYS`.
3. Mỗi bước là một commit riêng.

Kích thước: **S** ≈ < 1 ngày, **M** ≈ 1–3 ngày, **L** ≈ > 3 ngày.

### Bước 0 và Giai đoạn 1: đã xong, trừ các mục dưới đây

0.1–0.3, 1.1, 1.2, 1.4, 1.5 (tối thiểu) và 1.7 đã xong (xem bảng tiến độ). Còn lại:

| # | Việc | File chính | Test mới / tiêu chí | KT |
|---|---|---|---|---|
| 1.3 | ✅ Xong trong 2.3 (`38200cf`). | | | |
| 1.5 đầy đủ | ✅ Xong (`841be1a`, `4e7dba0`). | | | |
| 1.6 | ✅ Xong (A1, `3187ff1`). | | | |

### Giai đoạn 2: tầng protocol

Làm từ thay đổi cục bộ đến thay đổi lớn. Việc viết lại format flit gộp chung với DATA_W=128 (tối ưu 2), vì cả hai đều đụng mọi module.

| # | Việc | File chính | Tiêu chí | KT |
|---|---|---|---|---|
| 2.1 | ✅ **CompAck và WriteData dùng TxnID = DBID** nhận được. HN match CompAck/WriteData theo DBID mình cấp, không theo TxnID của RN. | `rn/chi_rn_f.v:930, 980`, `rn/chi_rn_wdat_engine.v:100`, phía nhận trong `hn/chi_hn_f.v` và write tracker | Assertion: `CompAck.TxnID == CompData.DBID` và `WriteData.TxnID == DBIDResp.DBID`. | M |
| 2.2 | ✅ **Resp đúng mã spec** (I/SC/UC/UD_PD/SD_PD, Table B13.35) trong CompData. RN dùng Resp để chọn trạng thái thay vì tự suy từ opcode. | `hn/chi_hn_f.v:1408, 3015, 3596`, `rn/chi_rn_dat_rx.v`, `rn/chi_rn_f.v:419` | Scoreboard so trạng thái cache RN với Resp đã nhận. | S |
| 2.3 | ✅ **Snoop có dữ liệu → chỉ SnpRespData** (bỏ flit SnpResp thừa). Resp theo mã spec (I, SC, UC, SD, _PD). Snoop không có dữ liệu → SnpResp với Resp đúng. Gộp TxnID snoop (1.3). | `rn/chi_rn_snoop_handler.v:211, 314`, phía nhận trong snoop tracker của HN | T25/T36/T37 vẫn pass. Assertion: không có SnpResp nào sau SnpRespData cho cùng snoop. | M |
| 2.4 | ✅ (phần buffer theo DBID ở SN còn mở) **CopyBack nhận CompDBIDResp; SN gửi DBIDResp.** HN trả CompDBIDResp cho WriteBack*/WriteEvict. SN cấp DBID trước khi nhận WriteData, có buffer theo DBID (gộp với 1.5 đầy đủ). | `hn/chi_hn_resp_engine.v:64`, `sn/chi_sn_axi_bridge.v:199`, `sn/chi_sn_wdata_buf.v` | Luồng B2.3.2.3 đúng trên waveform. T23/T41/T44 pass. | M |
| 2.5 | ✅ **Exclusive theo B6.3**: LDREX → ReadShared/ReadClean (Excl), STREX → CleanUnique (Excl) rồi ghi cục bộ, hoặc WriteNoSnp(Excl) cho vùng non-snoopable. Monitor ở HN theo spec. | `rn/chi_rn_req_engine.v:57-78`, `rn/chi_exclusive_monitor.v`, phần exclusive trong `hn/chi_hn_f.v` | T15, T16, T17, T18, T27 pass với opcode mới. | M |
| 2.6 | ✅ (2.6a/b/c) **Opcode REQ 7 bit + format flit theo Table B13.6+**: gom định nghĩa field vào một include duy nhất (`chi_flit_pkg.vh`/`struct`), SNP bỏ Size và 3 bit Addr thấp, **DATA_W=128** (4 beat/dòng). | `common/chi_defs.vh`, toàn bộ module có encode/decode flit | Toàn bộ regression và SoC pass với DATA_W=128. Kiểm tổng độ rộng flit với bảng spec bằng `$fatal` lúc elaborate. | L |
| 2.7 | ✅ **DVM theo B8**: DVMOp + DBIDResp + NonCopyBackWriteData chứa payload; SnpDVMOp 2 flit; MN không tự chèn Sync sau mỗi DVMOp và không snoop RN khởi tạo. | `mn/chi_mn_dvm.v`, `mn/chi_mn_dvm_tracker.v`, `rn/chi_rn_snoop_handler.v` | T26 pass theo luồng mới. | M |

### Giai đoạn 3: link layer (kế hoạch chi tiết 2026-10-01)

**Hiện trạng đo được trong RTL:**
- `chi_link_layer.v` có bộ đếm credit, nhưng `tx_out_lcrdv` do `chi_top` nối bằng `src_valid && src_ready` của fabric (ví dụ `rn_tx_req_lcrdv`, [chi_top.v:375](../chi_top.v#L375)). Credit bị trừ rồi cộng lại ngay trong cùng chu kỳ, nên thực chất vẫn là valid/ready.
- Phía RX, `rx_in_lcrdv = rx_in_valid && skid_ready` báo lúc **nhận** flit chứ không phải lúc **giải phóng** buffer, và mọi `rx_*_lcrdv` đều để `_unused`.
- Fabric đã có `*_in_pop_pulse` (input buffer vừa pop một entry), đúng là điểm cần trả LCRDV.
- `chi_defs.vh` chỉ có `CHI_RSP_RESP_LCRD_RETURN`. Còn thiếu `ReqLCrdReturn`, `SnpLCrdReturn`, `DataLCrdReturn` (đều là opcode 0).
- Credit mặc định: IoT `INIT_CRD`=2 với FIFO 2, FULL 8/8.

**Phạm vi:** credit thật trên **mọi link giữa node và fabric**, theo cả hai chiều. Nhờ vậy RN/HN/SN/MN nội bộ cũng chạy đúng link layer của spec. Cổng CHI ngoài (boundary adapter) dùng chung module link.

| # | Việc | Test / tiêu chí | KT |
|---|---|---|---|
| 3.0 | **Chuẩn bị + RED.** Nhánh `work/p30-link`, worktree `CHI_p25`. Luật checker mới `SPEC_LINK_CREDIT` (bật qua `CHK_SPEC_ALL`): mỗi kênh của mỗi link có bộ đếm credit riêng; FLITV khi credit = 0 là lỗi; LCRDV làm credit vượt 15 hoặc vượt số buffer là lỗi; credit nhận ở chu kỳ t chỉ dùng được từ t+1. Thêm opcode LCrdReturn cho REQ/SNP/DAT. | Trên RTL hiện tại luật phải báo lỗi (flit và LCRDV trùng chu kỳ). | S |
| 3.1a | **TX node → fabric.** `chi_link_layer`: `tx_out_valid` là FLITV thuần (không có ready); chỉ gửi khi có credit. `chi_top` nối `tx_*_lcrdv` với `*_in_pop_pulse` của fabric. Credit ban đầu = độ sâu input buffer của fabric (≤ 15). `$fatal`/assert: fabric không bao giờ phải từ chối flit đã có credit (`in_ready` phải bằng 1 khi FLITV). | Regression 14/14, stress 24/24, tb_CHI ICG. `SPEC_LINK_CREDIT` sạch trên chiều TX. | M |
| 3.1b | **RX fabric → node.** Output của fabric (`chi_output_reg`/arbiter) có bộ đếm credit theo từng đích; arbiter chỉ grant khi đích còn credit. RX của node dùng FIFO sâu `INIT_CRD` (thay skid) và trả LCRDV khi **pop**, không phải khi nhận. Nối `rx_*_lcrdv` (bỏ `_unused`). | Như 3.1a, cộng assert FIFO RX không bao giờ tràn. Đo băng thông: nếu `INIT_CRD`=2 không phủ được round-trip credit thì throughput tụt; ghi số liệu, có thể nâng IoT lên 3–4. | M–L |
| 3.2 | **FLITPEND.** TX đưa FLITPEND lên trước FLITV một chu kỳ (hoặc giữ liên tục khi đang có flit chờ). Luật checker: FLITV phải có FLITPEND ở chu kỳ trước. | Checker sạch; không đổi hành vi. | S |
| 3.3 | ✅ **LINKACTIVE (B14.5.1).** FSM TX STOP → ACTIVATE → RUN → DEACTIVATE, RX trả LINKACTIVEACK. Chỉ gửi flit/LCRDV ở RUN. Khi DEACTIVATE, TX trả hết credit bằng flit LCrdReturn và RX đếm lại đủ credit mới về STOP. Nối với clock gate (1.7): trước khi tắt clock thì deactivate các link, còn wake thì activate. | TB đơn vị (3.5) chạy nhiều vòng activate/deactivate ngẫu nhiên; tb_CHI ICG chạy với deactivate thật. | M |
| 3.4 | ✅ **TXSACTIVE/RXSACTIVE, SYSCOREQ/SYSCOACK.** SACTIVE lấy từ cờ busy theo từng node (1.7). SYSCO theo từng RN: RN chưa ở trong coherency domain thì HN không snoop (mask ở snoop generator). RN chỉ được ra khỏi domain khi cache đã flush và SF không còn liệt kê nó. | Test mới: RN0 ra khỏi domain (flush trước), RN1 đọc/ghi mà không có snoop tới RN0; checker báo lỗi nếu có snoop tới RN ngoài domain. | S–M |
| 3.5 | **TB đơn vị link layer** (`tb_chi_link_layer`, làm **song song với 3.0**, trước khi đụng `chi_top`): BFM hai phía với độ trễ LCRDV ngẫu nhiên, pop ngẫu nhiên, activate/deactivate ngẫu nhiên. Kiểm không mất/lặp flit, giữ thứ tự, credit bảo toàn. | Đưa vào `run_regression.ps1`. | M |

**Thứ tự:** ✅ 3.0 + 3.5 → ✅ 3.1a → ✅ 3.1b → ✅ 3.2 → ✅ 3.3 → ✅ 3.4. Mỗi bước một commit, giữ regression 16/16, stress 24/24 và tb_CHI ICG sạch như Giai đoạn 2.

**Khác so với kế hoạch (đã làm):**
- Credit không cấp sẵn theo tham số: bên gửi bắt đầu với 0 credit, bên nhận cấp qua LCRDV sau reset. Nhờ vậy hai phía không phải khớp tham số, và 3.3 chỉ cần chặn việc cấp credit khi link chưa ở RUN (`grant_en` của `chi_link_lcrd_gen`).
- 3.1b không sửa arbiter: bộ đếm credit đứng sau output register của fabric, trong `chi_top`.
- Buffer RX của node nằm ở ranh giới node trong `chi_top` (`chi_link_rx`), không nằm trong module node; các cổng `rx_*_lcrdv` cũ của node (= valid && ready) không còn dùng.

**3.3 như đã làm** (2026-10-05):
- Hai FSM: `chi_link_active_tx` giữ LINKACTIVEREQ (STOP → ACTIVATE → RUN → DEACTIVATE), `chi_link_active_rx` giữ LINKACTIVEACK. Mỗi node có một FSM TX cho link phát của nó (cổng mới `link_want`, `tx_linkactivereq`, `tx_linkactiveack`). Phía fabric của hai link và FSM RX của node nằm trong `chi_top` (`gen_link_active`), cùng chỗ với `chi_link_rx`.
- Credit và trạng thái link của bên phát nằm trong `chi_link_tx_crd`, dùng chung cho `chi_link_tx` (trong node) và output của fabric (thay `chi_credit_counter`). Ở DEACTIVATE nó phát flit LCrdReturn (opcode 0, cả flit bằng 0) cho từng credit đang giữ, kể cả credit tới muộn.
- Bên nhận nhận ra LCrdReturn bằng opcode 0. `chi_link_rx` không lưu và không đưa nó lên node. Ở chiều node → fabric, `chi_top` chặn nó trước fabric: `*_flitv` là FLITV đầy đủ, `*_valid` là FLITV đã bỏ LCrdReturn. `chi_link_lcrd_gen` đếm thêm số credit đã cấp chưa dùng (`home` = 0 credit ở ngoài), nên ACK chỉ hạ khi mọi kênh của link đã `home`.
- Clock gate: `link_wake` là điều kiện bật clock cũ (busy hoặc nguồn wake). Link bật khi `link_wake` và hạ sau `LINK_IDLE_CYCLES` (mặc định 4) chu kỳ rảnh; `chi_cg_en = link_want || !links_stopped`, nên clock chạy tới khi deactivate xong. Khi `cfg_cg_enable` = 0 link không bao giờ hạ.
- `busy` của node dùng `tx_pending` (có flit protocol đang giữ hoặc đang chào) thay cho FLITPEND. Nếu không, FLITPEND của flit LCrdReturn sẽ giữ `chi_busy` và bật link lại ngay.
- MN không có kênh DAT phát, nên link DAT vào fabric của MN không được cấp credit (nếu cấp thì không ai trả).
- Hai monitor B5 từng coi LCrdReturn là flit protocol: `tx_fire_pulse` của `chi_link_layer` giờ chỉ tính flit ở RUN, và bind `chi_snpresp_window_formal` dùng `tx_snp_valid && tx_link_run`.
- Kiểm RED trên `tb_chi_link_layer` (bản sao, 4 đột biến): hạ ACK không chờ credit, không lọc LCrdReturn ở bên nhận, không trả credit, cấp credit ngoài RUN. Kết quả ghi ở mục 5.
- Giới hạn: mọi link bật/tắt cùng lúc theo `link_want` chung của `chi_top`, chưa có chính sách riêng cho từng node. Cổng CHI ngoài (boundary adapter) chưa có LINKACTIVE.

**3.4 như đã làm** (2026-10-07):
- **SACTIVE.** `chi_top` có `node_txsactive` (cờ `busy` của từng node) và `node_rxsactive` (fabric, buffer nhận hoặc node khác đang bận); `chi_busy` tính từ `node_txsactive`. Cờ `busy` của RN tính thêm lúc chuyển trạng thái SYSCO (B15.2.1). Hành vi clock gate không đổi.
- **Điều khiển.** CSR `SYSCO_CTRL` (0x58, mỗi RN một bit, reset = 1 nên mọi RN tự vào domain) và `SYSCO_STATUS` (0x60, chỉ đọc: [15:0] SYSCOREQ, [31:16] SYSCOACK). Không thêm cổng cho `chi_top`. Hai địa chỉ 0x48/0x50 để dành cho `ERR_MASK`/`ERR_INJECT` như các tài liệu tham chiếu đã ghi.
- **RN** (`chi_rn_f`, cổng mới `sysco_connect`, `syscoreq`, `syscoack`): chỉ nhận lệnh CPU ở Coherency Enabled. Khi `sysco_connect` hạ: ngừng nhận lệnh, chờ hết giao dịch, flush cache, chờ các WriteBack xong, rồi hạ SYSCOREQ; vẫn trả snoop tới khi SYSCOACK thấp. `chi_rn_cache` có bộ quét flush (`flush_valid`/`flush_done`, trạng thái `ST_FLUSH_READ`): mỗi lượt một way, dòng bẩn vào hàng victim sẵn có (WriteBackFull), dòng sạch bị bỏ.
- **HN** (`chi_hn_f`, cổng mới `rn_in_domain`, `sysco_quiet`): `chi_hn_snoop_filter` che RN ngoài domain ở cả lúc đọc (lookup, back-invalidate, kể cả kết quả đã giữ lại) lẫn lúc ghi (update), nên snoop generator không bao giờ thấy RN đó. Khi một RN rời, SF quét mọi set để xóa bit của nó (`scrub_pending`). `sysco_quiet[k]` = không còn tracker snoop nào nhắm RN k và SF đã quét xong.
- **MN** (`chi_mn_dvm`): không gửi SnpDVMOp tới RN ngoài domain (B15: coherency gồm cả DVM); `sysco_quiet` = không còn SnpDVMOp mở.
- **SYSCOACK** (trong `chi_top`): lên ngay khi SYSCOREQ lên; hạ khi SYSCOREQ thấp và mọi HN, MN đều `sysco_quiet`.
- **Checker.** File mới `chi_sysco_checker.sv` (bind vào mọi `chi_top`): `SPEC_SACTIVE` (node gửi flit protocol khi TXSACTIVE thấp, node nhận flit khi RXSACTIVE thấp, RN đang chuyển trạng thái SYSCO mà TXSACTIVE thấp) và `SPEC_SYSCO` (bắt tay 4 pha; snoop tới RN ở Coherency Disabled). Luật `SPEC_DVM` của `chi_protocol_checker` giờ miễn cho RN ngoài domain (cổng mới `rn_in_domain`).
- **Test T57** (`SYSCO_ONLY`): RN0 giữ một dòng bẩn, một dòng sạch và một dòng chung với RN1, rồi rời domain. Kiểm: cache RN0 rỗng, SF không còn liệt kê RN0 đúng lúc SYSCOACK hạ, RN0 không nhận lệnh CPU, RN1 đọc được dữ liệu bẩn của RN0 và đọc/ghi/DVMOp trên các dòng cũ mà không có snoop nào tới RN0. Sau đó RN0 vào lại, đọc được dữ liệu RN1 đã ghi và bị snoop trở lại.
- Kiểm RED của T57 (đột biến trên bản sao, kết quả ghi ở mục 5).
- Giới hạn: chế độ L1 ngoài không rời domain được; RN ngoài domain không chạy giao dịch nào; stress ngẫu nhiên chưa bật/tắt SYSCO.

**Rủi ro cần để ý:**
- 3.1b đụng arbiter của fabric (QoS/aging), nên phải chạy `tb_chi_fabric_qos_xbar3`/`tb_chi_rn_f_qos_xbar4` kỹ.
- Deadlock: credit chỉ quay về khi bên nhận pop, nên phụ thuộc giữa các kênh giữ nguyên như valid/ready hiện tại. Riêng DAT sink chung của HN (xem 1.5) phải kiểm lại.
- Các TB đang `force` `tx_*_link_valid/ready` (T53, T56) phải chuyển sang giữ credit, vì không còn tín hiệu ready.

Kết quả với ba rủi ro trên: arbiter không bị đụng tới; không thấy deadlock ở DAT sink của HN (stress 24/24, liveness của checker sạch); T53 và T56 không phải sửa vì chúng ép ở phía protocol, trước link. Các test phải sửa là T01/T13 và hai test HN slot, vì chúng ép `dat_node_in_ready` của fabric.

### Giai đoạn 4: kiểm chứng (làm trước Giai đoạn 2)

| # | Việc | KT |
|---|---|---|
| 4.1 | ✅ Scoreboard coherence, kể cả bản cho L1 ngoài (`chi_l1_coherence_scoreboard.svh`). Còn lại: gắn vào TB có traffic L1 thật (CoreMark). | (M) |
| 4.2 | ✅ Checker giao thức. Mỗi bước Giai đoạn 2 bật luật `+CHK_SPEC_*` của nó trong regression và phải giữ sạch. Các checker rời trong tb_CHI (TxnID ở SN, WLAST) vẫn giữ vì chúng kiểm ở phía AXI. | — |
| 4.3 | ✅ TB stress ngẫu nhiên, WriteBackFull mặc định bật, `run_stress_seeds.ps1` cho nhiều seed. Barrier giờ là tùy chọn `+BARRIER=<n>` (mặc định tắt); `run_stress_seeds.ps1` chạy rn2/rn3/icg có barrier và rn2nb/rn3nb không barrier. Còn lại: lên lịch chạy định kỳ. | S |
| 4.4 | Chạy SoC + CoreMark trong regression định kỳ, sau khi sửa lỗi CoreMark có sẵn. | S |

### Tối ưu song song (sau Giai đoạn 1)

| # | Việc | KT |
|---|---|---|
| O1 | Thay `chi_flit_reg_slice` half-buffer bằng skid buffer 2 entry (đã có `chi_skid_buffer.v`) khi `OUTPUT_FIFO_DEPTH<=1`. Ước tính băng thông mỗi cổng tăng khoảng 2×. | S |
| O2 | ✅ DATA_W 32→128: xong trong 2.6a. | (trong 2.6) |
| O3 | Đưa đường LLC-hit vào read tracker như đường miss, để FSM chính không bị giữ qua SEND_DAT/WAIT_ACK. Cho phép snoop chồng lấn, nên làm cùng 1.3. | M |

## 4. Thứ tự đề xuất

```
✅ 0.1 → 0.2 → 0.3 → 1.1 → 1.2 → 1.4 → 1.5 tối thiểu → 1.7
✅ 4.2 → 4.1 → 4.3 (+ N-2, N-3)
✅ P0-2 (T46) → P0-4/1.6 (A1) → N-4 → 2.1 → 2.2 → 2.3 (+1.3) → 2.4 (tối thiểu)
✅ 1.5 đầy đủ (buffer theo DBID ở SN, nhiều lệnh ghi outstanding) → 2.5 (exclusive B6.3)
✅ 2.6a (DAT 128, +O2) → 2.6b (opcode 7/5 bit) → 2.6c (layout B13.6–B13.9)
✅ 2.7 (DVM B8) → 2.8 (CompAck cho MakeUnique) → 2.9 (SnpRespFwded/SnpRespDataFwded, Fwd snoop một RN-F)
  → (UCE, để sau)
✅ 3.0 + 3.5 (checker credit, TB đơn vị link) → 3.1a (credit node → fabric) → 3.1b (credit fabric → node) → 3.2 (FLITPEND) → 3.3 (LINKACTIVE) → 3.4 (SACTIVE, SYSCO)
O1, O3: xen vào khi regression đã ổn định.
Song song: sửa lỗi CoreMark dual-core có sẵn (task riêng), rồi gắn scoreboard L1 vào TB CoreMark.
```

**Việc nên làm tiếp ngay:** Giai đoạn 3 đã xong. Lên lịch `run_stress_seeds.ps1` chạy định kỳ (một lượt 24 seed chỉ mất vài phút). Bài học 2.9: stress rn3 là cấu hình duy nhất có hai sharer cùng lúc, nên phải chạy đủ 24 seed trước khi commit.

## 5. Bàn giao cho phiên tiếp theo

**Trạng thái git**
- `main` = `e9aa824` (baseline).
- `fix/phase1-correctness` = Giai đoạn 1, Giai đoạn 4, 1.5, 2.1–2.9, re-sync core RISC-V + RV32A (`4329555`), `export_github.sh`, Giai đoạn 3 (3.0–3.5), check out ở `D:\Github\CHI_Interconnect`. Working tree chính giờ sạch. Repo **chưa có remote**, nên chưa push được.
- Worktree `D:\Github\CHI_p25`: nhánh `work/p30-link`, đã gộp vào `fix/phase1-correctness` (2026-10-05). Vì `fix/phase1-correctness` có thêm hai commit `export_github.sh` sau khi tách nhánh, lần gộp dùng merge commit `f852bcb` (gộp `fix/phase1-correctness` vào `work/p30-link`, chạy lại regression, rồi fast-forward), nên các hash `4596ffd`, `5dbca06`, `4856529`, `b155a73` giữ nguyên. 3.3, bản sửa TB CoreMark (`796aea9`) và 3.4 cũng làm trên nhánh này rồi fast-forward.
- Worktree `D:\Github\CHI_verify`: detached HEAD ở `fix/phase1-correctness`, dùng làm worktree mô phỏng thứ hai.
- Các nhánh `work/p02`…`work/p29` đã gộp và đã xóa (2026-10-01). Còn `verif/4.1-4.2-checkers`, `fix/phase1-p03`, `fix/phase1-snoop-txnid` (đều đã gộp) và hai nhánh `claude/*` có worktree riêng.

**Regression với core RISC-V mới** (2026-10-01): 15/15, gồm `tb_riscv_core_amo`. TB này mới chạy với seed mặc định; `run_tb_chi_xsim.ps1` chưa có tùy chọn `--sv_seed`.

**Cách chạy**
- Một TB: `scripts/run_tb_chi_xsim.ps1 -Top <tb> -Tag <dir> [-PlusArgs "A B=1"] [-Defines "X Y=3"] [-SkipCompile]`. Log ở `reports/<Tag>/xsim.log`. Checker giao thức tự được bind vào mọi `chi_top`.
- Toàn bộ: `scripts/run_regression.ps1 -Prefix <p>` (khoảng 20 phút, mặc định `CHK_SPEC_ALL`). Bước cuối là CoreMark dual-core (`coremark_dual_core`, thêm khoảng 3 phút; `-SkipCoreMark` để bỏ; không chạy khi truyền `-Tops` hoặc ở repo phẳng). Trong worktree mới phải chép `CHI_Interconnect.sim/sim_1/behav/xsim/glbl.v` từ checkout chính.
- CoreMark riêng: `scripts/run_coremark_dual_core_xsim.ps1 -SplitImages 1 -StartMask 3 -TimeoutCycles 3000000`. Mặc định `SplitImages 0` nạp sai image và sẽ timeout; đó là lỗi cấu hình, không phải lỗi RTL.
- Stress nhiều seed: `scripts/run_stress_seeds.ps1 [-Seeds 1,2,3] [-Configs rn2,rn3,icg,rn2nb,rn3nb] [-Prefix p]` (mặc định 8 seed × 5 cấu hình = 40 lượt, khoảng 10 phút). rn2/rn3/icg dùng `+BARRIER=25`: mọi RN dừng lại mỗi 25 thao tác, nhờ đó scoreboard kiểm trạng thái 13–26 lần mỗi lượt và clock gate có khoảng nghỉ. rn2nb/rn3nb không barrier: tải liên tục, nhưng scoreboard chỉ kiểm trạng thái 2–6 lần.
- Stress đơn: `-Top tb_chi_random_stress -PlusArgs "SEED=n OPS=n [CG] [NO_WBFULL] CHK_SPEC_ALL" [-Defines "STRESS_NUM_RN=3 CHI_SIM_REAL_ICG"]`.
- Lần vết một dòng: thêm `TRACE_LINE=<hex addr>` vào PlusArgs.
- Plusarg debug của tb_CHI: `P0_ONLY`, `T31_ONLY`, `WDOG_ONLY`, `SNTXN_ONLY`, `EVW_ONLY`, `BIST_ONLY`, `LLC_ONLY` (T46), `A1_ONLY` (T47..T51), `VIC_ONLY` (T51), `RAW_ONLY` (T52), `MW_ONLY` (T53, thêm `MW_TRACE` để in beat tới SN), `XR_ONLY` (T54), `DVM_ONLY` (T26, T55), `MU_ONLY` (T56), `SYSCO_ONLY` (T57), `CG_ALWAYS`, `TRACE_WDAT`.

**Lưu ý kỹ thuật**
- xsim 2024.1 crash kernel khi truyền `cond ? "A" : "B"` (chuỗi literal) vào task, nên dùng if/else. Nó cũng không nhận `void'($urandom(seed))`. Trong vòng `for` trên queue struct, so sánh part-select của field (`q[i].addr[31:6] == x[31:6]`) có thể luôn ra false mà không báo lỗi: chép phần tử ra biến cục bộ rồi so sánh (xem `SPEC_MKUNIQUE_COMPACK` trong checker).
- `xsim.bat`/`xvlog.bat` cắt tham số tại `=`; script đã tự quote `NAME=VALUE`.
- Trong PowerShell, `[IO.File]` dùng thư mục hiện hành của .NET, không phải `Set-Location`: luôn dùng đường dẫn tuyệt đối khi đột biến file để chạy thử.
- Mô hình AXI của tb_CHI tuần tự hóa AR sau lệnh ghi đang mở ở SN, nên muốn tái hiện hazard đọc/ghi phải giữ dữ liệu ở phía RN (xem T52).
- TB nào backdoor LLC/bộ nhớ phải gọi `sb_forget_line(addr)`; TB SoC nào seed L1 bằng backdoor phải gọi `sbl1_exempt_line(addr)`.
- Khi ép (`force`) một cổng handshake, phải ép cả valid lẫn ready ở cùng một phía, nếu không flit sẽ bị lặp. Đừng ép `tx_in_ready` của `chi_link_layer` (monitor B5 báo `tx_fire while !ready`); giữ WriteData ở ranh giới engine→link (`wdat_engine_ready` + `tx_dat_link_valid`), như T53.
- Mỗi lần gọi `run_tb_chi_xsim.ps1`, `run_regression.ps1` hay `run_stress_seeds.ps1` phải là một lệnh PowerShell riêng: script `exit` sẽ cắt các lệnh nối sau nó. `run_tb_chi_xsim.ps1` còn `Set-Location` vào `reports/<Tag>`, nên khi gọi nhiều lần trong một lệnh phải dùng đường dẫn tuyệt đối tới script.
- Link layer (từ 3.1): cổng TX của node là FLITV/LCRDV, không có ready. Monitor trong TB coi mỗi chu kỳ `tx_*_valid` = 1 là một flit. Muốn chặn một node gửi thì ép ở phía protocol trước link (ví dụ `dat_arb_valid` và `dat_arb_ready` trong `chi_hn_f`), đừng ép `*_in_ready` của fabric: flit đã có credit sẽ gặp FIFO đầy và `chi_top` `$stop`.
- `tb_CHI.sv` include `formal/chi_formal_binds.v`, nên đổi cổng hay tham số của module bị bind (ví dụ `chi_link_layer`) phải sửa cả file đó. MN trong `chi_top` đi qua wrapper `chi_hn_i_mn`: thêm cổng cho `chi_mn_dvm` thì thêm cả ở wrapper.
- File RTL mới phải thêm vào `CHI_Interconnect.xpr` (file này dùng CRLF, giữ nguyên khi sửa) và `scripts/coremark_dual_core_xsim.prj`; `run_tb_chi_xsim.ps1` thì tự lấy mọi `*.v` trong `rtl/`.
- Đừng sửa RTL trong worktree đang chạy regression/stress: mỗi TB/seed compile lại từ mã nguồn hiện tại.
- LINKACTIVE (từ 3.3): `tx_*_valid` của node là FLITV, tính cả flit LCrdReturn (opcode 0) gửi ở DEACTIVATE. Monitor nào đếm flit protocol phải lọc: trong node dùng `tx_*_valid && tx_link_run`, trong `chi_top` dùng `*_valid` (đã bỏ LCrdReturn) thay vì `*_flitv`. TB gọi thẳng một node phải lái `link_want` và trả `tx_linkactiveack` (xem `tb_chi_rn_f_qos_xbar4`), và chỉ cấp credit khi link đã ở RUN.
- Khi tự chạy tb_CHI ngoài `run_regression.ps1` (ví dụ lượt ICG), hãy xét log bằng đúng mẫu lỗi của script (`TEST FAIL|FAIL:|\bFAIL\b|Fatal|FATAL|ERROR:|transaction timeout|timeout txn|WALL TIMEOUT|$stop`). Monitor B5 in `[B5 FATAL]` mà không dừng mô phỏng, nên chỉ đếm `TEST PASS` sẽ bỏ sót.
- Kết quả kiểm RED của 3.3 (đột biến trên bản sao, `tb_chi_link_layer +CHK_SPEC_ALL`): hạ ACK không chờ credit → TB báo link ở STOP mà TX còn credit, checker báo `SPEC_LINK_ACTIVE` (link stopped with L-Credits not returned); không lọc LCrdReturn → scoreboard báo flit 0x0 sai thứ tự/lặp; không trả credit → link không bao giờ về STOP, TB timeout; cấp credit ngoài RUN → `SPEC_LINK_ACTIVE` (LCRDV in STOP). RTL đúng: 21/21 case, 0 lỗi.

- SYSCO (từ 3.4): TB gọi thẳng `chi_rn_f` phải lái `sysco_connect` và trả `syscoack` (xem `tb_chi_rn_f_qos_xbar4`); sau reset RN mất vài chu kỳ bắt tay rồi mới nhận lệnh CPU. TB nào ép `rn_syscoreq` hay bỏ bit trong `SYSCO_CTRL` thì RN đó ngừng nhận lệnh cho tới khi vào lại. Module nào thêm nguồn snoop mới phải che theo `rn_in_domain` và góp vào `sysco_quiet`.
- xsim 2024.1 phình bộ nhớ tới khoảng 5 GB rồi sập ("FATAL_ERROR: Vivado Simulator kernel has discovered an exceptional condition") khi một khối clocked gọi `.first()`/`.next()` của mảng kết hợp ở mỗi chu kỳ. Dùng `if (a.num() != 0) foreach (a[k])`. Lượt chạy ngắn không lộ ra, nên sau khi sửa checker hãy chạy một seed stress trước khi chạy cả regression.
- Kết quả kiểm RED của 3.4 (đột biến trên bản sao, `tb_CHI +SYSCO_ONLY +CHK_SPEC_ALL`): HN không che và không quét SF → T57 báo SF còn liệt kê RN0 khi SYSCOACK hạ; cùng đột biến đó nhưng bỏ phép kiểm SF của TB → `SPEC_SYSCO` báo RN0 bị snoop ngoài domain (2 lần) và T57 báo 2 snoop tới RN0; RN hạ SYSCOREQ không flush → scoreboard báo `SB_SF_SUPERSET` (RN0 còn giữ dòng mà SF không liệt kê) và T57 fail; SYSCOACK hạ không chờ `sysco_quiet` → T57 báo SF còn 2 entry liệt kê RN0 lúc SYSCOACK hạ; RN ngoài domain vẫn nhận lệnh CPU → T57 fail; MN không che SnpDVMOp → `SPEC_SYSCO` và T57 báo 2 snoop tới RN0. RTL đúng: T57 PASS, 0 lỗi.
- Kiểm phần còn lại của 3.3 (2026-10-07): Vivado 2024.1 mở `CHI_Interconnect.xpr` (chỉ đọc, batch) thấy 75 file, không thiếu file nào, có đủ ba file `chi_link_active_tx.v`, `chi_link_active_rx.v`, `chi_link_tx_crd.v`; `check_syntax` không chạy được ở chế độ chỉ đọc. Project CoreMark compile sạch các file đó.

**Việc tiếp theo, theo thứ tự**
1. Giai đoạn 3 đã xong. UCE ở RN để sau. Sau mỗi bước đưa lên GitHub: chạy `bash scripts/export_github.sh`, chạy regression trong repo phẳng (9 testbench), rồi commit và push.
2. (Layout flit giờ theo B13.9: offset field lấy từ macro `CHI_*_LSB(NID)` trong `chi_defs.vh`, đừng hardcode; module mới dựng/tách flit phải gọi `CHI_FLIT_PARAM_CHECK`.)
3. Lên lịch `run_stress_seeds.ps1` chạy định kỳ (barrier đã thành tùy chọn, xong 2026-10-07).
4. Gắn `chi_l1_coherence_scoreboard.svh` vào TB CoreMark (CoreMark đã PASS và đã vào regression).
5. Core RISC-V: mỗi lần re-sync từ repo MCU phải giữ bản vá thứ 7 `.id_ex_jal(id_ex_jal | id_ex_jalr)` ở instance `EX_MEM` của `riscv_pipeline.v`. Core MCU gốc cũng thiếu đường này (mọi `jalr` có `rd ≠ x0` ghi sai `rd`); nên sửa ở repo MCU.
6. Hiệu năng: CoreMark = 433,35 ở đầu nhánh so với 595,50 ở `16c219b` (core cũ, chưa có link layer). Chưa tách phần do core mới (thêm một nhịp mỗi lần đổi hướng) và phần do link layer.
