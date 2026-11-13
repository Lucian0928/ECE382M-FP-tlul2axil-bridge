# ECE382M-7 Final Project 實作計畫：TL-UL → AXI4-Lite Bridge（Group 13）

依據：`FP.pdf`（proposal）、TileLink Spec 1.7.1（SiFive）、OpenTitan TL-UL 文件（含 Protocol Checker 頁）、Chipyard TileLink/Diplomacy Reference（Node Types、Widgets）、課程 lab2（NC-Verilog → Innovus → PrimeTime，gscl45nm 45nm 標準元件庫）。

---

## 1. 從規格讀出來、會直接影響 RTL 的規則

### 1.1 TL-UL 訊號（spec 1.7.1 Table 3.5 / 3.8）
| 通道 | 訊號 | 寬度 | Bridge 的處理 |
|---|---|---|---|
| A (host→bridge) | a_valid / a_ready | 1 | handshake |
| | a_opcode | 3 | Get=4, PutFullData=0, PutPartialData=1（其他都非法） |
| | a_param | 3 | 必須為 0（可當錯誤檢查） |
| | a_size | z（DW=32 時 2 bit） | log2(bytes)，TL-UL 不可大於匯流排寬度 → 只允許 0/1/2 |
| | a_source | o | 存起來，原樣回到 d_source |
| | a_address | 32 | 必須對齊 a_size |
| | a_mask | 4 | → AXI WSTRB |
| | a_data | 32 | → AXI WDATA（Get 時忽略） |
| D (bridge→host) | d_valid / d_ready | 1 | handshake |
| | d_opcode | 3 | Get → AccessAckData=1；Put → AccessAck=0 |
| | d_param | 2 | 固定 0 |
| | d_size | z | = 對應請求的 a_size |
| | d_source | o | = 對應請求的 a_source |
| | d_sink | i | 可任意，固定 0 |
| | d_data | 32 | 讀：RDATA；寫：忽略（送 0） |
| | d_error | 1 | AXI RRESP/BRESP 為 SLVERR(2'b10)/DECERR(2'b11) 時 =1 |

> 注意：1.7.1 版 D 通道確實叫 `d_error`（1.8 版之後才拆成 d_denied/d_corrupt），所以 proposal 寫 d_error 是對的。
> OpenTitan 預設寬度：TL_AW=32, TL_DW=32, TL_DBW=4, TL_SZW=2, TL_AIW=8, TL_DIW=1。它另外有 a_user/d_user（integrity），我們的 bridge 不需要，可以不做。

### 1.2 Mask / size / address（spec §4.6、§6.2）
- 一定成立：`(a_address & ((1<<a_size)-1)) == 0`。
- 非 active byte lane 的 mask 必須為 0。
- Get、PutFullData：active lanes 的 mask 全為 1，必須連續且自然對齊。
- PutPartialData：mask 只要落在 a_size 對齊範圍內即可，可不連續。
- TL-UL 每個訊息都是單一 beat，沒有 burst。
- 錯誤時 **不改 opcode**：Get 出錯仍回 AccessAckData（d_error=1），Put 出錯仍回 AccessAck（d_error=1）（OpenTitan checker 規則）。

### 1.3 Handshake 與 forward progress（spec §4.1、§4.2.2、§4.3）
- valid 絕不能依賴 ready；**ready → valid／控制／資料訊號之間不可有組合路徑**。→ d_* 全部從暫存器輸出。
- ready 可以依賴 valid（允許，但建議獨立）。
- TL 的 sender 在 valid 且未被接受時，可以撤掉 valid 或換內容（TL 比 AXI 寬鬆）。**但 AXI 不行**：AXI 的 VALID 一旦拉高，在 handshake 前不可放下，payload 也不可變。所以 bridge 一定要先把 A 通道請求「抓進暫存器」再送到 AXI。
- receiver 拉低 ready 只有 4 種合法理由。對 bridge 而言能用的是：
  - 規則 2：D 回應被 host 卡住（d_ready=0）時，可以一直把 a_ready 拉低。
  - 規則 4：轉送出去（AXI）的請求還沒收到回應時，可以把 a_ready 拉低。
  → 「一次只處理一筆，忙碌時 a_ready=0」是合法的設計。
- 回應最早可以在請求被接受的同一個 cycle 出現；我們的 D 是暫存器輸出，最早是下一個 cycle，沒有問題。
- Host 端不可以為了延遲回應而拉低 d_ready（§4.3），所以測試平台的 host 只能做「有界」的隨機 d_ready stall。

### 1.4 Ordering / source ID（spec §5.4、§5.5；OpenTitan）
- 每個 source ID 同時只能有一筆 in-flight 請求；回應可以亂序（靠 d_source 配對）。
- Slave 必須在操作的效果真正完成後才回 ack → 寫入一定要等 AXI B 回來才回 AccessAck（proposal 已這樣寫，正確）。
- AXI4-Lite 沒有 ID，所以 bridge 必須自己存 a_source / a_size / opcode。

### 1.5 Reset（spec §3.2.2）
- reset 期間 valid 要拉低；**spec 要求 reset 至少維持 100 cycles**。測試平台 reset ≥ 100 cycles。
- Bridge 在 reset 時把 d_valid、awvalid、wvalid、arvalid 清 0。

### 1.6 Chipyard 頁面給的參考
- Rocket-chip 的做法是 `TLToAXI4` 後面接 `AXI4UserYanker`、`AXI4Deinterleaver`、`AXI4Fragmenter`（給 AXI-Lite 用）。我們的 TL-UL 只有單 beat，AXI-Lite 也沒有 burst/ID，所以這些 widget 的功能都可以省略。它們只是「概念參考」，我們手寫 Verilog，不用 Chisel。
- `AXI4RAM` 只支援 AXI4-Lite、full-width 存取 → 我們自己的 AXI slave model 要支援 WSTRB 部分寫入。

---

## 2. 架構建議

### 2.1 版本規劃
- **Baseline（一定要做完）**：一次只處理 1 筆交易（single outstanding）。面積小、容易驗證、完全合規。讀寫路徑用兩個獨立的 controller（符合 proposal 的描述），但由同一個請求暫存器驅動。
- **Stretch（時間夠再做）**：讀、寫各允許 1 筆同時 in-flight（各自存 source/size），D 通道加固定優先或 round-robin arbiter。前提是 host 對兩筆請求用不同的 source（TL 本來就這樣要求）。做這版時要額外驗證兩筆回應同時到達的情況。

### 2.2 方塊圖（Baseline）
```
 TL-UL host                               AXI4-Lite slave
 ──A──► [Request capture + decode/check] ─┬─► Write ctrl ─► AW, W ; ◄─ B
                                          └─► Read ctrl  ─► AR    ; ◄─ R
 ◄─D─── [Response register (d_*)] ◄──────── B/R 結果 or 本地錯誤
```

### 2.3 頂層介面（建議參數：AW=32, DW=32, SZW=2, SRCW=8）
```verilog
module tlul2axil #(parameter AW=32, DW=32, SZW=2, SRCW=8, SINKW=1) (
  input  clk, rst_n,
  // TL-UL A
  input  a_valid, output a_ready,
  input  [2:0] a_opcode, input [2:0] a_param, input [SZW-1:0] a_size,
  input  [SRCW-1:0] a_source, input [AW-1:0] a_address,
  input  [DW/8-1:0] a_mask, input [DW-1:0] a_data,
  // TL-UL D
  output reg d_valid, input d_ready,
  output reg [2:0] d_opcode, output [1:0] d_param, output reg [SZW-1:0] d_size,
  output reg [SRCW-1:0] d_source, output [SINKW-1:0] d_sink,
  output reg [DW-1:0] d_data, output reg d_error,
  // AXI4-Lite master
  output [AW-1:0] m_awaddr, output [2:0] m_awprot, output m_awvalid, input m_awready,
  output [DW-1:0] m_wdata, output [DW/8-1:0] m_wstrb, output m_wvalid, input m_wready,
  input  [1:0] m_bresp, input m_bvalid, output m_bready,
  output [AW-1:0] m_araddr, output [2:0] m_arprot, output m_arvalid, input m_arready,
  input  [DW-1:0] m_rdata, input [1:0] m_rresp, input m_rvalid, output m_rready
);
```

### 2.4 狀態機（Baseline）
| 狀態 | 動作 | 離開條件 |
|---|---|---|
| IDLE | a_ready=1；a_valid&&a_ready 時把 opcode/size/source/address/mask/data 存入暫存器 | 請求非法 → RESP（d_error=1，不送 AXI）；Get → RD；Put → WR |
| RD | arvalid=1 直到 arready；之後 rready=1 | rvalid&&rready：存 rdata、err=rresp[1] → RESP |
| WR | awvalid=!aw_done、wvalid=!w_done（兩者**獨立**完成，順序不限，也可同一 cycle）；aw_done&&w_done 後 bready=1 | bvalid&&bready：err=bresp[1] → RESP |
| RESP | d_valid=1，d_* 保持不變 | d_ready → IDLE |

小技巧：
- a_ready 只在 IDLE 為 1（暫存器輸出，不依賴 a_valid），完全沒有組合路徑問題。
- 吞吐量最佳化（選做）：RESP 狀態在 d_ready=1 的同一 cycle 允許接受新請求（a_ready = idle | (d_valid & d_ready)）。這會產生 d_ready→a_ready 的組合路徑，spec 允許（ready 可依賴其他訊號），但要確認不會跟 host 形成組合迴圈。Baseline 先不要做。
- 也可以把 RD/WR 的 xREADY 一直拉高（rready=1、bready=1），只要 RESP 暫存器空著就能收。

### 2.5 寫入路徑核心（AW/W 獨立追蹤）
```verilog
reg aw_done, w_done;
assign m_awvalid = (state==WR) && !aw_done;
assign m_wvalid  = (state==WR) && !w_done;
assign m_bready  = (state==WR) && aw_done && w_done;
always @(posedge clk or negedge rst_n)
  if (!rst_n) begin aw_done<=0; w_done<=0; end
  else if (state==IDLE) begin aw_done<=0; w_done<=0; end
  else begin
    if (m_awvalid && m_awready) aw_done <= 1'b1;
    if (m_wvalid  && m_wready)  w_done  <= 1'b1;
  end
```
（AXI 規定 slave 在 AW 和 W 都完成前不能送 B；bready 等兩者都完成再拉高是保險做法。）

### 2.6 欄位對應
| AXI | 來源 |
|---|---|
| awaddr / araddr | 存下的 a_address（可直接送；若 slave 需要 word 對齊，送 `{addr[AW-1:2],2'b00}`） |
| wdata | a_data（TL 與 AXI 都是 little-endian、自然對齊 byte lane，直接接） |
| wstrb | a_mask |
| awprot / arprot | 3'b000 |
| d_data（讀） | rdata 整個 word（host 只看 active lanes） |
| d_error | `resp[1]`（OKAY=00、EXOKAY=01 視為成功；SLVERR=10、DECERR=11 → 錯誤） |

### 2.7 本地錯誤檢查（建議加，很便宜，報告也加分）
請求符合下列任一條就**不送 AXI**，直接回 d_error=1（opcode 仍依 Get/Put 決定；非法 opcode 回 AccessAck）：
- opcode 不是 0/1/4；a_param≠0；a_size>2；位址沒對齊 a_size；
- mask 在 active lanes 外有 1；Get/PutFull 的 active lanes 沒全為 1；PutPartial mask 全 0（行為要自己定義，建議當錯誤或當成 no-op 寫入，報告寫清楚）。

---

## 3. 驗證計畫（對應 proposal 第 2、3 節）

### 3.1 Testbench 元件
1. **TL-UL host driver**：可以發 Get/PutFull/PutPartial；a_valid 隨機延遲；d_ready 隨機（但有上限）stall；每個 source 同時只有一筆。
2. **AXI4-Lite slave model**：內含記憶體陣列（依 WSTRB 寫 byte）；awready/wready/arready 隨機延遲；**AW 先、W 先、同時**三種情況都要能產生；bvalid/rvalid 隨機延遲；某些位址範圍回 SLVERR / DECERR。
3. **Scoreboard / reference model**：TB 裡另一份記憶體；每筆 Get 比對資料；檢查每筆請求「剛好一個」回應，且 d_opcode/d_size/d_source/d_error 正確。
4. **Protocol monitors**（Verilog always 區塊或 SVA，看課程模擬器支援哪種）：
   - AXI：VALID 拉高後在 handshake 前不可放下，payload 不可改變（5 個通道都檢查）。
   - TL D：d_valid 拉高後在 d_ready 前不可放下、d_* 不可改變（proposal 的 design goal b）。
   - 不可有 X；d_param=0；沒有多餘回應；sim 結束時沒有遺漏的交易。

### 3.2 Directed tests
| # | 測項 |
|---|---|
| T1 | reset（≥100 cycles，期間 valid=0；reset 解除後輸出正確） |
| T2 | 單筆 Get / PutFullData（size=2） |
| T3 | PutPartialData：byte、halfword、不連續 mask（如 4'b1010） |
| T4 | Sub-word Get（size=0/1），檢查 active lanes |
| T5 | AW 先於 W、W 先於 AW、同時 handshake |
| T6 | 延遲的 B / R 回應 |
| T7 | D 通道 backpressure（d_ready=0 好幾個 cycle），確認 d_* 保持不變 |
| T8 | AXI SLVERR / DECERR → d_error=1，opcode 正確 |
| T9 | 非法請求（壞 opcode、未對齊、size>2、壞 mask）→ 本地錯誤、AXI 端沒有任何交易 |
| T10 | 背靠背交易（write→read 同位址，確認讀到新值） |

### 3.3 隨機測試
- 數千到上萬筆隨機交易、多個 seed；所有 ready/valid 都隨機 stall。
- 簡單的 coverage counter：各 opcode × 各 size × 錯誤/正常 × AW/W 順序 都至少出現過一次，報告列出數字。

---

## 4. 實體實作流程（對應 design goal c）

課程 lab2 的流程是 NC-Verilog（功能）→ Innovus（APR，gscl45nm.lef + apr45nm.v）→ PrimeTime（STA，gscl45nm.db）。這次多一步 **RTL 合成**：

1. **Synthesis**：用課程伺服器上的 Synopsys Design Compiler（`dc_shell`）或 Cadence Genus，target library 用 gscl45nm（lab2 已有 `gscl45nm.db`）。寫成 script（read RTL → SDC 約束 → compile → report_area/report_timing → write netlist）。⚠️ 我沒有在 lab 資料裡看到合成工具的說明，請向 TA 確認可用的工具與 .lib/.db 路徑。
2. **SDC**：create_clock（先用寬鬆週期，例如 2 ns，再往下壓找 timing 收斂點）、input/output delay（例如 20–30% 週期）、set_load、set_driving_cell。
3. **Gate-level sim**：用合成後 netlist 重跑同一套 testbench（含隨機測試），確認行為一致。
4. **APR（Innovus）**：沿用 lab2 流程：import → floorplan（aspect ratio 1、調整 utilization）→ power ring/stripes → placement → CTS（這次有時脈，lab2 沒有，要加）→ routing → verify geometry/connectivity → 匯出 netlist/SPEF/DEF。
5. **Post-APR STA（PrimeTime）**：用 APR 後 netlist + SPEF，報 setup/hold、critical path。
6. **可重現性**：所有步驟寫成 script + Makefile（`make sim`、`make syn`、`make apr`、`make sta`），報告附上 area、timing、power 報表與 layout 截圖。

---

## 5. 分工（4 人）
| 成員 | 主要負責 |
|---|---|
| A | RTL：request capture/decode/錯誤檢查、FSM、D 回應暫存器 |
| B | RTL：AXI 讀/寫 controller；後期負責 stretch 版本 |
| C | 驗證：TB、AXI slave model、TL host driver、scoreboard、monitor、隨機測試 |
| D | 合成 / APR / STA scripts、報告整合 |
（RTL 介面先由全組一起凍結，C 和 D 可以同時開始。）

## 6. 時程建議
| 週 | 里程碑 |
|---|---|
| 1 | 凍結介面與參數、FSM 圖、TB 骨架、AXI slave model |
| 2 | Baseline RTL + T1–T10 directed tests 全過 |
| 3 | 隨機測試、protocol monitors、合成 + gate-level sim |
| 4 | APR + post-APR STA、（選做）stretch 版本、報告與簡報 |

## 7. 常見陷阱
1. d_* 或 AXI xVALID 用組合邏輯從 ready 產生 → 違反 spec §4.1。全部用暫存器。
2. AXI VALID 在 handshake 前放下或 payload 改變 → AXI 違規；請求一定要先存進暫存器。
3. 寫入時假設 AW 和 W 同時被接受 → 要分開追蹤（aw_done/w_done）。
4. 在 B 回來前就回 AccessAck → 違反 spec §5.5。
5. 錯誤時把 Get 回成 AccessAck → 錯，必須仍是 AccessAckData + d_error=1。
6. d_size / d_source 沒有存下來（AXI 沒有 ID，回應時已經拿不到 a_*）。
7. TB 的 host 用 d_ready=0 無限期卡住 → host 本身不合規（spec §4.3），隨機 stall 要有上限。
8. Reset 少於 100 cycles（spec §3.2.2）。
