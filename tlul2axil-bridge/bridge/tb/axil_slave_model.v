// ============================================================================
// axil_slave_model.v : behavioral AXI4-Lite slave for verification (not synthesizable)
//
// * Memory of 2^MEMW words, WSTRB byte writes.
// * Address region (top nibble) selects the response:
//     4'h8 -> SLVERR (2'b10), 4'hF -> DECERR (2'b11), otherwise OKAY.
//   Writes to error regions do not change memory; error reads return 32'hDEADBEEF.
// * Knobs (set hierarchically from the testbench):
//     wr_mode   : 0 random AW/W acceptance, 1 AW before W, 2 W before AW,
//                 3 AW and W accepted in the same cycle (if the mode changes
//                 after one of them was taken, the other is accepted alone)
//     ready_pct : % chance per cycle that a free channel is ready
//     dly_min / dly_max : cycles between request acceptance and B / R valid
//     seed      : random seed
// ============================================================================
`timescale 1ns/1ps
module axil_slave_model #(
  parameter AW   = 32,
  parameter DW   = 32,
  parameter MEMW = 10
)(
  input                 clk,
  input                 rst_n,

  input  [AW-1:0]       awaddr,
  input  [2:0]          awprot,
  input                 awvalid,
  output                awready,

  input  [DW-1:0]       wdata,
  input  [DW/8-1:0]     wstrb,
  input                 wvalid,
  output                wready,

  output reg [1:0]      bresp,
  output reg            bvalid,
  input                 bready,

  input  [AW-1:0]       araddr,
  input  [2:0]          arprot,
  input                 arvalid,
  output                arready,

  output reg [DW-1:0]   rdata,
  output reg [1:0]      rresp,
  output reg            rvalid,
  input                 rready
);
  localparam DBW  = DW/8;
  localparam OFFW = $clog2(DBW);

  integer wr_mode;
  integer ready_pct;
  integer dly_min;
  integer dly_max;
  integer seed;

  reg [DW-1:0] mem [0:(1<<MEMW)-1];

  reg          aw_go, w_go, ar_go;
  reg          have_aw, have_w, have_ar;
  reg [AW-1:0] aw_addr_q, ar_addr_q;
  reg [DW-1:0] w_data_q;
  reg [DBW-1:0] w_strb_q;
  integer      b_cnt, r_cnt;     // -1 = delay not started

  integer i;
  initial begin
    wr_mode   = 0;
    ready_pct = 70;
    dly_min   = 0;
    dly_max   = 3;
    seed      = 1;
    for (i = 0; i < (1<<MEMW); i = i + 1)
      mem[i] = (i * 32'h9E3779B1) ^ 32'h5A5A5A5A;
  end

  function [1:0] region_resp;
    input [AW-1:0] a;
    begin
      case (a[AW-1:AW-4])
        4'h8:    region_resp = 2'b10;   // SLVERR
        4'hF:    region_resp = 2'b11;   // DECERR
        default: region_resp = 2'b00;   // OKAY
      endcase
    end
  endfunction

  function [DW-1:0] merge;
    input [DW-1:0]  old;
    input [DW-1:0]  data;
    input [DBW-1:0] strb;
    integer k;
    begin
      merge = old;
      for (k = 0; k < DBW; k = k + 1)
        if (strb[k]) merge[8*k +: 8] = data[8*k +: 8];
    end
  endfunction

  function rnd_go;
    input integer dummy;
    begin
      rnd_go = ({$random(seed)} % 100) < ready_pct;
    end
  endfunction

  function integer rnd_dly;
    input integer dummy;
    begin
      rnd_dly = dly_min + ({$random(seed)} % (dly_max - dly_min + 1));
    end
  endfunction

  // ---------------- ready generation ----------------
  wire aw_free = !have_aw && !bvalid;
  wire w_free  = !have_w  && !bvalid;

  assign awready = aw_free && (
                     (wr_mode == 3) ? (((awvalid && wvalid && w_free) || have_w) && aw_go) :
                     (wr_mode == 2) ? (have_w && aw_go) :
                                      aw_go);
  assign wready  = w_free && (
                     (wr_mode == 3) ? (((awvalid && wvalid && aw_free) || have_aw) && aw_go) :
                     (wr_mode == 1) ? (have_aw && w_go) :
                                      w_go);
  assign arready = !have_ar && !rvalid && ar_go;

  wire [MEMW-1:0] aw_idx = aw_addr_q[OFFW+MEMW-1:OFFW];
  wire [MEMW-1:0] ar_idx = ar_addr_q[OFFW+MEMW-1:OFFW];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_go <= 1'b0; w_go <= 1'b0; ar_go <= 1'b0;
      have_aw <= 1'b0; have_w <= 1'b0; have_ar <= 1'b0;
      bvalid <= 1'b0; bresp <= 2'b00;
      rvalid <= 1'b0; rresp <= 2'b00; rdata <= {DW{1'b0}};
      b_cnt <= -1; r_cnt <= -1;
    end else begin
      aw_go <= rnd_go(0);
      w_go  <= rnd_go(0);
      ar_go <= rnd_go(0);

      // ---------------- write ----------------
      if (awvalid && awready) begin have_aw <= 1'b1; aw_addr_q <= awaddr; end
      if (wvalid  && wready)  begin have_w  <= 1'b1; w_data_q <= wdata; w_strb_q <= wstrb; end

      if (have_aw && have_w && !bvalid) begin
        if (b_cnt < 0)
          b_cnt <= rnd_dly(0);
        else if (b_cnt == 0) begin
          bresp <= region_resp(aw_addr_q);
          if (region_resp(aw_addr_q) == 2'b00)
            mem[aw_idx] <= merge(mem[aw_idx], w_data_q, w_strb_q);
          bvalid  <= 1'b1;
          have_aw <= 1'b0;
          have_w  <= 1'b0;
          b_cnt   <= -1;
        end else
          b_cnt <= b_cnt - 1;
      end
      if (bvalid && bready) bvalid <= 1'b0;

      // ---------------- read ----------------
      if (arvalid && arready) begin have_ar <= 1'b1; ar_addr_q <= araddr; end

      if (have_ar && !rvalid) begin
        if (r_cnt < 0)
          r_cnt <= rnd_dly(0);
        else if (r_cnt == 0) begin
          rresp   <= region_resp(ar_addr_q);
          rdata   <= (region_resp(ar_addr_q) == 2'b00) ? mem[ar_idx] : 32'hDEADBEEF;
          rvalid  <= 1'b1;
          have_ar <= 1'b0;
          r_cnt   <= -1;
        end else
          r_cnt <= r_cnt - 1;
      end
      if (rvalid && rready) rvalid <= 1'b0;
    end
  end

endmodule
