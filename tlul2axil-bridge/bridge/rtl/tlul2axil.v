// ============================================================================
// tlul2axil.v : TileLink Uncached Lightweight (TL-UL) slave -> AXI4-Lite master
// ECE382M-7 Final Project, Group 13
//
// Baseline 架構：一次只處理一筆交易（single outstanding）。
//   IDLE : a_ready=1，接受 A 通道請求並存入暫存器，同時做本地合法性檢查
//   RD   : 送 AR，等 R
//   WR   : AW 與 W 各自獨立 handshake（順序不限、可同 cycle），兩者完成後等 B
//   RESP : d_valid=1，d_* 保持不變直到 d_ready
//
// 合規重點（TileLink spec 1.7.1）：
//   * §4.1  ready 到 valid / 控制 / 資料沒有組合路徑：d_* 與 m_*valid 全由暫存器
//           或 state 解碼產生。
//   * §4.2.2 忙碌時拉低 a_ready 屬於合法理由（等轉送回應 / D 回應被擋）。
//   * §5.5  寫入一定等 AXI B 回來後才回 AccessAck。
//   * 出錯時 opcode 不變：Get -> AccessAckData + d_error，Put -> AccessAck + d_error。
//   * AXI4-Lite 沒有 ID，所以 a_source / a_size 在接受時就存進 d_source / d_size。
// ============================================================================
`timescale 1ns/1ps
module tlul2axil #(
  parameter AW    = 32,   // address width
  parameter DW    = 32,   // data width (bits)
  parameter SZW   = 2,    // a_size / d_size width
  parameter SRCW  = 8,    // a_source / d_source width
  parameter SINKW = 1     // d_sink width
)(
  input                   clk,
  input                   rst_n,      // active-low asynchronous reset

  // ---------------- TL-UL channel A (host -> bridge) ----------------
  input                   a_valid,
  output                  a_ready,
  input      [2:0]        a_opcode,
  input      [2:0]        a_param,
  input      [SZW-1:0]    a_size,
  input      [SRCW-1:0]   a_source,
  input      [AW-1:0]     a_address,
  input      [DW/8-1:0]   a_mask,
  input      [DW-1:0]     a_data,

  // ---------------- TL-UL channel D (bridge -> host) ----------------
  output reg              d_valid,
  input                   d_ready,
  output reg [2:0]        d_opcode,
  output     [1:0]        d_param,
  output reg [SZW-1:0]    d_size,
  output reg [SRCW-1:0]   d_source,
  output     [SINKW-1:0]  d_sink,
  output reg [DW-1:0]     d_data,
  output reg              d_error,

  // ---------------- AXI4-Lite master ----------------
  output     [AW-1:0]     m_awaddr,
  output     [2:0]        m_awprot,
  output                  m_awvalid,
  input                   m_awready,

  output     [DW-1:0]     m_wdata,
  output     [DW/8-1:0]   m_wstrb,
  output                  m_wvalid,
  input                   m_wready,

  input      [1:0]        m_bresp,
  input                   m_bvalid,
  output                  m_bready,

  output     [AW-1:0]     m_araddr,
  output     [2:0]        m_arprot,
  output                  m_arvalid,
  input                   m_arready,

  input      [DW-1:0]     m_rdata,
  input      [1:0]        m_rresp,
  input                   m_rvalid,
  output                  m_rready
);

  localparam DBW  = DW/8;
  localparam OFFW = $clog2(DBW);          // byte-offset bits inside one beat

  // TL-UL opcodes (spec Table 6.1)
  localparam [2:0] OP_PUTFULL  = 3'd0;
  localparam [2:0] OP_PUTPART  = 3'd1;
  localparam [2:0] OP_GET      = 3'd4;
  localparam [2:0] OP_ACK      = 3'd0;    // AccessAck
  localparam [2:0] OP_ACKDATA  = 3'd1;    // AccessAckData

  localparam [1:0] S_IDLE = 2'd0;
  localparam [1:0] S_RD   = 2'd1;
  localparam [1:0] S_WR   = 2'd2;
  localparam [1:0] S_RESP = 2'd3;

  reg  [1:0]       state;

  // captured request (drives the AXI payload; stable for the whole transfer)
  reg  [AW-1:0]    addr_q;
  reg  [DW-1:0]    wdata_q;
  reg  [DBW-1:0]   wstrb_q;

  // per-channel handshake-done flags
  reg              ar_done;
  reg              aw_done;
  reg              w_done;

  // --------------------------------------------------------------------------
  // Request decode and legality check (spec §4.6, §6.2)
  // --------------------------------------------------------------------------
  // active_lanes: byte lanes i that fall inside the same 2^size-aligned block
  // as the address offset.
  function [DBW-1:0] active_lanes;
    input [SZW-1:0]  size;
    input [OFFW-1:0] off;
    integer i;
    begin
      for (i = 0; i < DBW; i = i + 1)
        active_lanes[i] = ((i >> size) == (off >> size));
    end
  endfunction

  wire [OFFW-1:0] a_off    = a_address[OFFW-1:0];
  wire [DBW-1:0]  a_act    = active_lanes(a_size, a_off);

  wire is_get     = (a_opcode == OP_GET);
  wire is_putfull = (a_opcode == OP_PUTFULL);
  wire is_putpart = (a_opcode == OP_PUTPART);

  wire op_ok      = is_get | is_putfull | is_putpart;
  wire param_ok   = (a_param == 3'd0);
  wire size_ok    = (a_size <= OFFW);                       // TL-UL: <= bus width
  wire align_ok   = (((a_off >> a_size) << a_size) == a_off); // addr aligned to size
  wire mask_in    = ~|(a_mask & ~a_act);                    // inactive lanes are 0
  wire mask_full  = (a_mask == a_act);                      // Get / PutFull: all active lanes 1
  wire mask_ok    = mask_in & (is_putpart | mask_full);     // PutPartial: any subset

  wire local_err  = ~(op_ok & param_ok & size_ok & align_ok & mask_ok);

  // --------------------------------------------------------------------------
  // Handshake outputs: decoded from registers only (no ready -> valid path)
  // --------------------------------------------------------------------------
  assign a_ready   = (state == S_IDLE);

  assign m_arvalid = (state == S_RD) & ~ar_done;
  assign m_rready  = (state == S_RD) &  ar_done;

  assign m_awvalid = (state == S_WR) & ~aw_done;
  assign m_wvalid  = (state == S_WR) & ~w_done;
  assign m_bready  = (state == S_WR) &  aw_done & w_done;

  assign m_araddr  = addr_q;
  assign m_awaddr  = addr_q;
  assign m_wdata   = wdata_q;
  assign m_wstrb   = wstrb_q;
  assign m_arprot  = 3'b000;   // unprivileged, secure, data access
  assign m_awprot  = 3'b000;

  assign d_param   = 2'b00;
  assign d_sink    = {SINKW{1'b0}};

  // --------------------------------------------------------------------------
  // Main FSM
  // --------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      addr_q   <= {AW{1'b0}};
      wdata_q  <= {DW{1'b0}};
      wstrb_q  <= {DBW{1'b0}};
      ar_done  <= 1'b0;
      aw_done  <= 1'b0;
      w_done   <= 1'b0;
      d_valid  <= 1'b0;
      d_opcode <= OP_ACK;
      d_size   <= {SZW{1'b0}};
      d_source <= {SRCW{1'b0}};
      d_data   <= {DW{1'b0}};
      d_error  <= 1'b0;
    end else begin
      case (state)
        // ------------------------------------------------------------------
        S_IDLE: begin
          if (a_valid) begin                 // a_ready == 1 in IDLE
            // response fields are known now; d_valid stays 0 until done
            d_opcode <= is_get ? OP_ACKDATA : OP_ACK;
            d_size   <= a_size;
            d_source <= a_source;
            d_data   <= {DW{1'b0}};
            d_error  <= local_err;
            // AXI payload
            addr_q   <= a_address;
            wdata_q  <= a_data;
            wstrb_q  <= a_mask;
            ar_done  <= 1'b0;
            aw_done  <= 1'b0;
            w_done   <= 1'b0;
            if (local_err) begin             // illegal request: answer locally
              d_valid <= 1'b1;
              state   <= S_RESP;
            end else if (is_get) begin
              state   <= S_RD;
            end else begin
              state   <= S_WR;
            end
          end
        end
        // ------------------------------------------------------------------
        S_RD: begin
          if (m_arvalid && m_arready) ar_done <= 1'b1;
          if (m_rvalid && m_rready) begin
            d_data  <= m_rdata;
            d_error <= m_rresp[1];           // SLVERR(10) / DECERR(11)
            d_valid <= 1'b1;
            state   <= S_RESP;
          end
        end
        // ------------------------------------------------------------------
        S_WR: begin
          if (m_awvalid && m_awready) aw_done <= 1'b1;
          if (m_wvalid  && m_wready)  w_done  <= 1'b1;
          if (m_bvalid  && m_bready) begin
            d_error <= m_bresp[1];
            d_valid <= 1'b1;
            state   <= S_RESP;
          end
        end
        // ------------------------------------------------------------------
        S_RESP: begin
          if (d_ready) begin
            d_valid <= 1'b0;
            state   <= S_IDLE;
          end
        end
      endcase
    end
  end

endmodule
