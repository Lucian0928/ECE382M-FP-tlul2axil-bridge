# TL-UL → AXI4-Lite Bridge（ECE382M-7 Final Project, Group 13）

## 檔案
| 檔案 | 說明 |
|---|---|
| `rtl/tlul2axil.v` | 可合成的 bridge RTL（Verilog-2005，baseline：一次處理一筆交易） |
| `tb/axil_slave_model.v` | AXI4-Lite slave 行為模型（記憶體、隨機 ready/延遲、錯誤區段） |
| `tb/tb_tlul2axil.v` | 自我檢查 testbench：directed T1–T11 + 隨機測試 + protocol monitors + coverage |
| `Makefile` | `make sim` / `make regress` / `make wave` / `make nc` |

## 執行
```bash
make sim                      # Icarus, seed=1, 5000 筆隨機
make sim SEED=7 NTRANS=20000
make regress                  # seed 1..10
make wave                     # 產生 tb_tlul2axil.vcd
make nc                       # 課程伺服器上的 NC-Verilog
```

## 設計重點
- FSM：`IDLE → RD | WR → RESP → IDLE`；非法請求 `IDLE → RESP`（d_error=1，不送 AXI）。
- `a_ready = (state==IDLE)`；`d_*` 和所有 AXI `*valid` 都由暫存器 / state 產生，ready 到 valid 沒有組合路徑（spec §4.1）。
- 寫入：`aw_done`、`w_done` 分開追蹤，兩者都完成才拉高 `bready`；收到 B 才回 AccessAck（§5.5）。
- `d_error = resp[1]`（SLVERR / DECERR）；出錯時 opcode 不變（Get → AccessAckData）。
- 本地檢查：opcode ∉ {0,1,4}、a_param≠0、a_size>log2(DW/8)、位址未對齊、mask 超出 active lanes、Get/PutFull mask 不完整。
- PutPartialData 的 mask 全 0 視為合法，會轉成 WSTRB=0 的 AXI 寫入（不改記憶體）。
- `awprot/arprot = 0`，`d_param = 0`，`d_sink = 0`；`a_address` 原樣送到 AXI。

## Testbench 檢查項目
- Scoreboard：參考記憶體 + 每個 source 的預期回應（opcode/size/source/error/讀回資料，只比 active lanes）。
- 每筆請求剛好一個回應；結束時沒有遺漏；AXI AW/W/B/AR/R 次數 = 轉送的請求數。
- AXI 五個通道中的 AW/W/AR：VALID 在 handshake 前不可放下、payload 不可改變；TL D 同樣。
- AXI 位址 / 資料 / WSTRB 必須等於接收到的 TL 請求。
- reset ≥ 100 cycles（§3.2.2），reset 期間輸出檢查；交易進行中 reset（T11）。
- Host 隨機放棄未被接受的請求（TL 允許）、有上限的 d_ready stall（§4.3）。
- Slave 隨機切換 AW 先 / W 先 / 同 cycle、隨機 ready 與 B/R 延遲、SLVERR/DECERR 區段（位址最高 nibble = 8 / F）。

## 驗證結果（Icarus Verilog 13，本機）
- seed 1–40，每個 seed 約 6000 筆交易：全部 PASS。
- Mutation test（故意改壞 RTL，確認 TB 會抓到）：8/8 被抓到
  - 忽略 BRESP 錯誤、B 回來前就回 ack、AW 重送、d_source 錯、拿掉 mask 檢查、錯誤時 Get 回 AccessAck、讀資料錯、d_valid 未等 d_ready 就放下。

## 尚未完成
- 合成（DC/Genus + gscl45nm）、gate-level sim、Innovus APR、PrimeTime STA。
- Stretch：讀寫各一筆同時進行 + D 通道 arbiter。
