// ============================================================================
// tb_tlul2axil.v : self-checking testbench for tlul2axil (Verilog-2005)
//
// Components
//   * TL-UL host driver (task tl_req) with random gaps and, in random mode,
//     abandoning a request that is not accepted (TL allows lowering a_valid).
//   * d_ready generator: always-ready / random with a bounded stall / forced low.
//   * AXI4-Lite slave model (axil_slave_model.v).
//   * Scoreboard: reference memory + per-source expected response.
//   * Protocol monitors: AXI VALID/payload stability, TL D stability, X checks,
//     exactly-one-response, AXI payload == captured TL request, AXI counts.
//
// Plusargs: +seed=<n>  +ntrans=<n>  +vcd
// ============================================================================
`timescale 1ns/1ps
module tb;
  parameter AW = 32, DW = 32, SZW = 2, SRCW = 8, MEMW = 10;
  localparam DBW  = DW/8;
  localparam NSRC = 1 << SRCW;

  // ---------------- clock / reset ----------------
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---------------- TL-UL ----------------
  reg              a_valid;
  wire             a_ready;
  reg  [2:0]       a_opcode, a_param;
  reg  [SZW-1:0]   a_size;
  reg  [SRCW-1:0]  a_source;
  reg  [AW-1:0]    a_address;
  reg  [DBW-1:0]   a_mask;
  reg  [DW-1:0]    a_data;

  wire             d_valid;
  reg              d_ready;
  wire [2:0]       d_opcode;
  wire [1:0]       d_param;
  wire [SZW-1:0]   d_size;
  wire [SRCW-1:0]  d_source;
  wire             d_sink;
  wire [DW-1:0]    d_data;
  wire             d_error;

  // ---------------- AXI4-Lite ----------------
  wire [AW-1:0]  awaddr;  wire [2:0] awprot; wire awvalid, awready;
  wire [DW-1:0]  wdata;   wire [DBW-1:0] wstrb; wire wvalid, wready;
  wire [1:0]     bresp;   wire bvalid, bready;
  wire [AW-1:0]  araddr;  wire [2:0] arprot; wire arvalid, arready;
  wire [DW-1:0]  rdata;   wire [1:0] rresp; wire rvalid, rready;

  tlul2axil #(.AW(AW), .DW(DW), .SZW(SZW), .SRCW(SRCW), .SINKW(1)) dut (
    .clk(clk), .rst_n(rst_n),
    .a_valid(a_valid), .a_ready(a_ready), .a_opcode(a_opcode), .a_param(a_param),
    .a_size(a_size), .a_source(a_source), .a_address(a_address), .a_mask(a_mask),
    .a_data(a_data),
    .d_valid(d_valid), .d_ready(d_ready), .d_opcode(d_opcode), .d_param(d_param),
    .d_size(d_size), .d_source(d_source), .d_sink(d_sink), .d_data(d_data),
    .d_error(d_error),
    .m_awaddr(awaddr), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
    .m_wdata(wdata), .m_wstrb(wstrb), .m_wvalid(wvalid), .m_wready(wready),
    .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
    .m_araddr(araddr), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
    .m_rdata(rdata), .m_rresp(rresp), .m_rvalid(rvalid), .m_rready(rready)
  );

  axil_slave_model #(.AW(AW), .DW(DW), .MEMW(MEMW)) slv (
    .clk(clk), .rst_n(rst_n),
    .awaddr(awaddr), .awprot(awprot), .awvalid(awvalid), .awready(awready),
    .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
    .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .araddr(araddr), .arprot(arprot), .arvalid(arvalid), .arready(arready),
    .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready)
  );

  // ==========================================================================
  // Bookkeeping
  // ==========================================================================
  integer seed, seed0;
  integer ntrans;
  integer n_err;
  integer cycle;

  reg [DW-1:0]   refmem  [0:(1<<MEMW)-1];
  reg            exp_vld [0:NSRC-1];
  reg [2:0]      exp_op  [0:NSRC-1];
  reg [SZW-1:0]  exp_sz  [0:NSRC-1];
  reg            exp_err [0:NSRC-1];
  reg [DW-1:0]   exp_dat [0:NSRC-1];
  reg [DBW-1:0]  exp_msk [0:NSRC-1];
  integer        outstanding;
  reg [SRCW-1:0] next_src;

  // currently forwarded request (bridge is single-outstanding)
  reg [AW-1:0]   fwd_addr;
  reg [DW-1:0]   fwd_data;
  reg [DBW-1:0]  fwd_mask;

  // counters
  integer n_acc, n_resp, n_fwd_wr, n_fwd_rd;
  integer n_aw, n_w, n_b, n_ar, n_r;
  integer cov_op_sz [0:2][0:2];          // [get,pf,pp][size]
  integer cov_lerr, cov_slverr, cov_decerr;
  integer cov_awfirst, cov_wfirst, cov_same;
  integer cov_dstall, cov_abandon, cov_busy;
  integer aw_t, w_t;

  // d_ready control: 0 always 1, 1 random (bounded), 2 forced 0
  integer dr_mode, dr_pct, dr_low;

  integer i, j;

  initial begin
    n_err = 0; cycle = 0; outstanding = 0; next_src = 0;
    n_acc = 0; n_resp = 0; n_fwd_wr = 0; n_fwd_rd = 0;
    n_aw = 0; n_w = 0; n_b = 0; n_ar = 0; n_r = 0;
    cov_lerr = 0; cov_slverr = 0; cov_decerr = 0;
    cov_awfirst = 0; cov_wfirst = 0; cov_same = 0;
    cov_dstall = 0; cov_abandon = 0; cov_busy = 0;
    aw_t = -1; w_t = -1;
    dr_mode = 0; dr_pct = 70; dr_low = 0;
    for (i = 0; i < 3; i = i + 1) for (j = 0; j < 3; j = j + 1) cov_op_sz[i][j] = 0;
    for (i = 0; i < NSRC; i = i + 1) exp_vld[i] = 1'b0;
  end

  always @(posedge clk) cycle <= cycle + 1;

  // ==========================================================================
  // Reference helpers
  // ==========================================================================
  function [DW-1:0] merge;
    input [DW-1:0] old; input [DW-1:0] data; input [DBW-1:0] strb;
    integer k;
    begin
      merge = old;
      for (k = 0; k < DBW; k = k + 1)
        if (strb[k]) merge[8*k +: 8] = data[8*k +: 8];
    end
  endfunction

  function [DW-1:0] bytemask;
    input [DBW-1:0] m;
    integer k;
    begin
      for (k = 0; k < DBW; k = k + 1) bytemask[8*k +: 8] = {8{m[k]}};
    end
  endfunction

  // independent re-implementation of the legality rules (spec §4.6 / §6.2)
  function ref_local_err;
    input [2:0] op; input [2:0] prm; input [SZW-1:0] sz;
    input [AW-1:0] addr; input [DBW-1:0] mask;
    integer nbytes, off;
    reg [DBW-1:0] act;
    begin
      ref_local_err = 1'b0;
      if (!(op == 3'd0 || op == 3'd1 || op == 3'd4)) ref_local_err = 1'b1;
      if (prm != 3'd0)                               ref_local_err = 1'b1;
      if (sz > 2)                                    ref_local_err = 1'b1;
      else begin
        nbytes = 1 << sz;
        off    = addr % DBW;
        if (off % nbytes != 0)                       ref_local_err = 1'b1;
        else begin
          act = ((1 << nbytes) - 1) << off;
          if ((mask & ~act) != 0)                    ref_local_err = 1'b1;
          if (op != 3'd1 && mask != act)             ref_local_err = 1'b1;
        end
      end
    end
  endfunction

  function region_err;
    input [AW-1:0] addr;
    begin
      region_err = (addr[AW-1:AW-4] == 4'h8) || (addr[AW-1:AW-4] == 4'hF);
    end
  endfunction

  // ==========================================================================
  // Scoreboard: request accepted
  // ==========================================================================
  reg lerr_t, rerr_t;
  integer opi;
  wire [MEMW-1:0] a_idx = a_address[MEMW+1:2];

  always @(posedge clk) if (rst_n && a_valid && a_ready) begin
    if (exp_vld[a_source]) begin
      $display("ERROR @%0t: TB reused in-flight source %0d", $time, a_source);
      n_err = n_err + 1;
    end
    lerr_t = ref_local_err(a_opcode, a_param, a_size, a_address, a_mask);
    rerr_t = !lerr_t && region_err(a_address);
    exp_vld[a_source] = 1'b1;
    exp_op [a_source] = (a_opcode == 3'd4) ? 3'd1 : 3'd0;
    exp_sz [a_source] = a_size;
    exp_err[a_source] = lerr_t | rerr_t;
    exp_dat[a_source] = refmem[a_idx];
    exp_msk[a_source] = a_mask;
    outstanding = outstanding + 1;
    n_acc = n_acc + 1;
    if (!lerr_t) begin
      fwd_addr = a_address; fwd_data = a_data; fwd_mask = a_mask;
      if (a_opcode == 3'd4) n_fwd_rd = n_fwd_rd + 1;
      else                  n_fwd_wr = n_fwd_wr + 1;
      if (!rerr_t && a_opcode != 3'd4)
        refmem[a_idx] = merge(refmem[a_idx], a_data, a_mask);
      opi = (a_opcode == 3'd4) ? 0 : (a_opcode == 3'd0) ? 1 : 2;
      cov_op_sz[opi][a_size] = cov_op_sz[opi][a_size] + 1;
      if (rerr_t) begin
        if (a_address[AW-1:AW-4] == 4'h8) cov_slverr = cov_slverr + 1;
        else                              cov_decerr = cov_decerr + 1;
      end
    end else
      cov_lerr = cov_lerr + 1;
  end

  // ==========================================================================
  // Scoreboard: response
  // ==========================================================================
  always @(posedge clk) if (rst_n && d_valid && d_ready) begin
    if (!exp_vld[d_source]) begin
      $display("ERROR @%0t: unexpected response, d_source=%0d", $time, d_source);
      n_err = n_err + 1;
    end else begin
      if (d_opcode !== exp_op[d_source] || d_size !== exp_sz[d_source] ||
          d_error  !== exp_err[d_source] || d_param !== 2'b00) begin
        $display("ERROR @%0t: src %0d got op=%0d sz=%0d err=%0d param=%0d, exp op=%0d sz=%0d err=%0d",
                 $time, d_source, d_opcode, d_size, d_error, d_param,
                 exp_op[d_source], exp_sz[d_source], exp_err[d_source]);
        n_err = n_err + 1;
      end
      if (d_opcode == 3'd1 && !exp_err[d_source] &&
          ((d_data ^ exp_dat[d_source]) & bytemask(exp_msk[d_source])) != 0) begin
        $display("ERROR @%0t: src %0d read data %h, exp %h (mask %b)",
                 $time, d_source, d_data, exp_dat[d_source], exp_msk[d_source]);
        n_err = n_err + 1;
      end
      exp_vld[d_source] = 1'b0;
      outstanding = outstanding - 1;
    end
    n_resp = n_resp + 1;
  end

  // ==========================================================================
  // Protocol monitors
  // ==========================================================================
  reg              p_d_stall, p_aw_stall, p_w_stall, p_ar_stall;
  reg [3+SZW+SRCW+DW:0] p_d_pay;
  reg [AW+2:0]     p_aw_pay, p_ar_pay;
  reg [DW+DBW-1:0] p_w_pay;
  wire [3+SZW+SRCW+DW:0] d_pay = {d_opcode, d_size, d_source, d_data, d_error};

  always @(posedge clk) begin
    if (!rst_n) begin
      p_d_stall <= 1'b0; p_aw_stall <= 1'b0; p_w_stall <= 1'b0; p_ar_stall <= 1'b0;
      if (cycle > 2 && (d_valid !== 1'b0 || awvalid !== 1'b0 || wvalid !== 1'b0 ||
                        arvalid !== 1'b0 || a_ready !== 1'b1)) begin
        $display("ERROR @%0t: outputs not in reset state during reset", $time);
        n_err = n_err + 1;
      end
    end else begin
      // X checks on handshake signals
      if (^{a_ready, d_valid, awvalid, wvalid, bready, arvalid, rready} === 1'bx) begin
        $display("ERROR @%0t: X on handshake signal", $time); n_err = n_err + 1;
      end
      // TL D channel: hold valid and payload while stalled (proposal goal b)
      if (p_d_stall && (d_valid !== 1'b1 || d_pay !== p_d_pay)) begin
        $display("ERROR @%0t: D changed while stalled", $time); n_err = n_err + 1;
      end
      // AXI: VALID must stay high and payload stable until handshake
      if (p_aw_stall && (awvalid !== 1'b1 || {awaddr, awprot} !== p_aw_pay)) begin
        $display("ERROR @%0t: AW changed while stalled", $time); n_err = n_err + 1;
      end
      if (p_w_stall && (wvalid !== 1'b1 || {wdata, wstrb} !== p_w_pay)) begin
        $display("ERROR @%0t: W changed while stalled", $time); n_err = n_err + 1;
      end
      if (p_ar_stall && (arvalid !== 1'b1 || {araddr, arprot} !== p_ar_pay)) begin
        $display("ERROR @%0t: AR changed while stalled", $time); n_err = n_err + 1;
      end
      p_d_stall  <= d_valid && !d_ready;  p_d_pay  <= d_pay;
      p_aw_stall <= awvalid && !awready;  p_aw_pay <= {awaddr, awprot};
      p_w_stall  <= wvalid  && !wready;   p_w_pay  <= {wdata, wstrb};
      p_ar_stall <= arvalid && !arready;  p_ar_pay <= {araddr, arprot};

      if (d_valid && !d_ready) cov_dstall = cov_dstall + 1;
      if (a_valid && !a_ready) cov_busy   = cov_busy + 1;

      // AXI payload must match the captured TL request
      if (awvalid && awready) begin
        n_aw = n_aw + 1; aw_t = cycle;
        if (awaddr !== fwd_addr || awprot !== 3'b000) begin
          $display("ERROR @%0t: AWADDR %h exp %h", $time, awaddr, fwd_addr); n_err = n_err + 1;
        end
      end
      if (wvalid && wready) begin
        n_w = n_w + 1; w_t = cycle;
        if (wstrb !== fwd_mask || ((wdata ^ fwd_data) & bytemask(wstrb)) != 0) begin
          $display("ERROR @%0t: W data/strb %h/%b exp %h/%b", $time, wdata, wstrb, fwd_data, fwd_mask);
          n_err = n_err + 1;
        end
      end
      if (bvalid && bready) begin
        n_b = n_b + 1;
        if      (aw_t <  w_t) cov_awfirst = cov_awfirst + 1;
        else if (aw_t >  w_t) cov_wfirst  = cov_wfirst + 1;
        else                  cov_same    = cov_same + 1;
      end
      if (arvalid && arready) begin
        n_ar = n_ar + 1;
        if (araddr !== fwd_addr || arprot !== 3'b000) begin
          $display("ERROR @%0t: ARADDR %h exp %h", $time, araddr, fwd_addr); n_err = n_err + 1;
        end
      end
      if (rvalid && rready) n_r = n_r + 1;

      // AXI traffic only for forwarded (legal) requests
      if (n_aw > n_fwd_wr || n_w > n_fwd_wr || n_ar > n_fwd_rd) begin
        $display("ERROR @%0t: AXI transaction without a forwarded TL request", $time);
        n_err = n_err + 1;
        n_fwd_wr = n_aw > n_w ? n_aw : n_w; n_fwd_rd = n_ar;   // avoid repeated messages
      end
    end
  end

  // ==========================================================================
  // d_ready generator (bounded random stall: host must not block D forever, §4.3)
  // ==========================================================================
  always @(posedge clk) begin
    #1;
    if (dr_mode == 0)      d_ready = 1'b1;
    else if (dr_mode == 2) d_ready = 1'b0;
    else begin
      if (dr_low >= 8) d_ready = 1'b1;
      else             d_ready = ({$random(seed)} % 100) < dr_pct;
      dr_low = d_ready ? 0 : dr_low + 1;
    end
  end

  // ==========================================================================
  // TL-UL host driver
  // ==========================================================================
  task tl_idle;
    begin
      a_valid = 1'b0; a_opcode = 3'd0; a_param = 3'd0; a_size = 0;
      a_source = 0; a_address = 0; a_mask = 0; a_data = 0;
    end
  endtask

  // Present one request; returns when accepted (or abandoned if may_abandon).
  // Call convention: called right after a posedge (+#1).
  task tl_req;
    input [2:0] op; input [2:0] prm; input [SZW-1:0] sz;
    input [AW-1:0] addr; input [DBW-1:0] mask; input [DW-1:0] data;
    input integer may_abandon;
    reg [SRCW-1:0] src;
    reg done;
    integer wait_cyc;
    begin
      src = next_src;
      while (exp_vld[src]) src = src + 1;
      next_src = src + 1;
      a_valid = 1'b1; a_opcode = op; a_param = prm; a_size = sz;
      a_source = src; a_address = addr; a_mask = mask; a_data = data;
      done = 1'b0; wait_cyc = 0;
      while (!done) begin
        @(posedge clk);
        if (a_ready) done = 1'b1;
        #1;
        if (done) a_valid = 1'b0;
        else if (may_abandon && ({$random(seed)} % 16 == 0)) begin
          a_valid = 1'b0; done = 1'b1; cov_abandon = cov_abandon + 1;
        end
        wait_cyc = wait_cyc + 1;
        if (wait_cyc > 2000) begin
          $display("ERROR @%0t: request never accepted", $time);
          n_err = n_err + 1; done = 1'b1; a_valid = 1'b0;
        end
      end
    end
  endtask

  task wait_idle;
    integer w;
    begin
      w = 0;
      while ((outstanding != 0 || !a_ready) && w < 5000) begin
        @(posedge clk); #1; w = w + 1;
      end
      if (w >= 5000) begin
        $display("ERROR @%0t: timeout waiting for %0d outstanding responses", $time, outstanding);
        $display("       dut.state=%0d aw_done=%b w_done=%b ar_done=%b d_valid=%b d_ready=%b",
                 dut.state, dut.aw_done, dut.w_done, dut.ar_done, d_valid, d_ready);
        $display("       slv have_aw=%b have_w=%b bvalid=%b have_ar=%b rvalid=%b wr_mode=%0d awvalid=%b wvalid=%b awready=%b wready=%b",
                 slv.have_aw, slv.have_w, bvalid, slv.have_ar, rvalid, slv.wr_mode, awvalid, wvalid, awready, wready);
        n_err = n_err + 1;
      end
    end
  endtask

  task cycles; input integer n; begin repeat (n) @(posedge clk); #1; end endtask

  task do_reset;
    input integer n;
    begin
      rst_n = 1'b0;
      tl_idle;
      cycles(n);                         // spec §3.2.2: >= 100 cycles
      for (i = 0; i < NSRC; i = i + 1) exp_vld[i] = 1'b0;
      outstanding = 0;
      n_fwd_wr = 0; n_fwd_rd = 0; n_aw = 0; n_w = 0; n_b = 0; n_ar = 0; n_r = 0;
      rst_n = 1'b1;
      cycles(2);
    end
  endtask

  task set_slave;
    input integer mode; input integer pct; input integer dmin; input integer dmax;
    begin
      slv.wr_mode = mode; slv.ready_pct = pct; slv.dly_min = dmin; slv.dly_max = dmax;
    end
  endtask

  // random legal request, with ~6% illegal injection
  task rand_req;
    output [2:0] op; output [2:0] prm; output [SZW-1:0] sz;
    output [AW-1:0] addr; output [DBW-1:0] mask; output [DW-1:0] data;
    integer r, nbytes, off, word, k;
    reg [AW-1:0] base;
    reg [DBW-1:0] act;
    begin
      r = {$random(seed)} % 3;
      op = (r == 0) ? 3'd4 : (r == 1) ? 3'd0 : 3'd1;
      prm = 3'd0;
      sz = {$random(seed)} % 3;
      nbytes = 1 << sz;
      r = {$random(seed)} % 100;
      base = (r < 80) ? 32'h0000_0000 : (r < 90) ? 32'h8000_0000 : 32'hF000_0000;
      word = {$random(seed)} % 64;
      off  = ({$random(seed)} % DBW) & ~(nbytes - 1);
      addr = base | (word << 2) | off;
      act  = ((1 << nbytes) - 1) << off;
      mask = (op == 3'd1) ? (act & $random(seed)) : act;
      data = $random(seed);
      if ({$random(seed)} % 100 < 6) begin
        case ({$random(seed)} % 6)
          0: begin k = {$random(seed)} % 5; op = (k==0)?3'd2:(k==1)?3'd3:(k==2)?3'd5:(k==3)?3'd6:3'd7; end
          1: prm = 1 + {$random(seed)} % 7;
          2: sz = 3;
          3: begin sz = 2; addr = base | (word << 2) | (1 + {$random(seed)} % 3); mask = 4'hF; end
          4: begin sz = 0; addr = base | (word << 2); mask = 4'b0011; end
          5: begin op = 3'd4; sz = 2; addr = base | (word << 2); mask = 4'b0111; end
        endcase
      end
    end
  endtask

  // ==========================================================================
  // Test sequence
  // ==========================================================================
  reg [2:0] r_op, r_prm; reg [SZW-1:0] r_sz; reg [AW-1:0] r_addr;
  reg [DBW-1:0] r_mask; reg [DW-1:0] r_data;
  integer t, gap, base_aw, base_ar, c0, c1, c2, acc0;

  task check;
    input cond; input [8*48-1:0] msg;
    begin
      if (!cond) begin $display("ERROR @%0t: %0s", $time, msg); n_err = n_err + 1; end
    end
  endtask

  initial begin
    if (!$value$plusargs("seed=%d", seed))     seed = 1;
    seed0 = seed;
    if (!$value$plusargs("ntrans=%d", ntrans)) ntrans = 5000;
    if ($test$plusargs("vcd")) begin $dumpfile("tb_tlul2axil.vcd"); $dumpvars(0, tb); end
    slv.seed = seed + 17;
    d_ready = 1'b1;
    $display("=== tb_tlul2axil  seed=%0d  ntrans=%0d ===", seed, ntrans);

    // ---------------- T1 reset (>= 100 cycles) ----------------
    do_reset(120);
    for (i = 0; i < (1<<MEMW); i = i + 1) refmem[i] = slv.mem[i];
    check(a_ready === 1'b1 && d_valid === 1'b0, "T1 idle after reset");

    // ---------------- T2 full-word Put / Get ----------------
    set_slave(0, 100, 0, 0);
    tl_req(3'd0, 0, 2, 32'h10, 4'hF, 32'hCAFE_F00D, 0);
    tl_req(3'd4, 0, 2, 32'h10, 4'hF, 0, 0);
    wait_idle;
    check(refmem[4] == 32'hCAFE_F00D, "T2 refmem");

    // ---------------- T3 PutPartialData ----------------
    tl_req(3'd1, 0, 0, 32'h21, 4'b0010, 32'h0000_AB00, 0);   // byte
    tl_req(3'd1, 0, 1, 32'h22, 4'b1100, 32'h1234_0000, 0);   // halfword
    tl_req(3'd1, 0, 2, 32'h24, 4'b1010, 32'h77AA_55BB, 0);   // non-contiguous
    tl_req(3'd1, 0, 2, 32'h28, 4'b0000, 32'hFFFF_FFFF, 0);   // empty mask (legal no-op)
    tl_req(3'd4, 0, 2, 32'h20, 4'hF, 0, 0);
    tl_req(3'd4, 0, 2, 32'h24, 4'hF, 0, 0);
    tl_req(3'd4, 0, 2, 32'h28, 4'hF, 0, 0);
    wait_idle;

    // ---------------- T4 sub-word Get ----------------
    tl_req(3'd4, 0, 0, 32'h23, 4'b1000, 0, 0);
    tl_req(3'd4, 0, 1, 32'h22, 4'b1100, 0, 0);
    tl_req(3'd4, 0, 1, 32'h20, 4'b0011, 0, 0);
    wait_idle;

    // ---------------- T5 AW/W acceptance order ----------------
    c0 = cov_awfirst; c1 = cov_wfirst; c2 = cov_same;
    set_slave(1, 100, 0, 0); tl_req(3'd0, 0, 2, 32'h30, 4'hF, 32'h1111_1111, 0); wait_idle;
    set_slave(2, 100, 0, 0); tl_req(3'd0, 0, 2, 32'h34, 4'hF, 32'h2222_2222, 0); wait_idle;
    set_slave(3, 100, 0, 0); tl_req(3'd0, 0, 2, 32'h38, 4'hF, 32'h3333_3333, 0); wait_idle;
    check(cov_awfirst == c0 + 1, "T5 AW-first not seen");
    check(cov_wfirst  == c1 + 1, "T5 W-first not seen");
    check(cov_same    == c2 + 1, "T5 same-cycle not seen");
    tl_req(3'd4, 0, 2, 32'h30, 4'hF, 0, 0);
    tl_req(3'd4, 0, 2, 32'h34, 4'hF, 0, 0);
    tl_req(3'd4, 0, 2, 32'h38, 4'hF, 0, 0);
    wait_idle;

    // ---------------- T6 delayed B / R, slow readies ----------------
    set_slave(0, 20, 12, 12);
    tl_req(3'd0, 0, 2, 32'h40, 4'hF, 32'hA5A5_0001, 0);
    tl_req(3'd4, 0, 2, 32'h40, 4'hF, 0, 0);
    wait_idle;

    // ---------------- T7 D-channel backpressure ----------------
    set_slave(0, 100, 0, 0);
    dr_mode = 2;
    tl_req(3'd4, 0, 2, 32'h40, 4'hF, 0, 0);
    acc0 = n_acc;
    fork
      tl_req(3'd0, 0, 2, 32'h44, 4'hF, 32'hBEEF_0002, 0);   // must wait (a_ready=0)
      begin
        cycles(15);
        check(d_valid === 1'b1, "T7 d_valid dropped while stalled");
        check(n_acc == acc0,    "T7 request accepted while D stalled");
        dr_mode = 0;
      end
    join
    wait_idle;

    // ---------------- T8 AXI error responses ----------------
    tl_req(3'd0, 0, 2, 32'h8000_0010, 4'hF, 32'h1, 0);   // SLVERR write
    tl_req(3'd4, 0, 2, 32'h8000_0010, 4'hF, 0, 0);       // SLVERR read
    tl_req(3'd1, 0, 0, 32'hF000_0011, 4'b0010, 32'h0, 0);// DECERR partial write
    tl_req(3'd4, 0, 1, 32'hF000_0012, 4'b1100, 0, 0);    // DECERR read
    wait_idle;

    // ---------------- T9 illegal requests (no AXI traffic) ----------------
    base_aw = n_aw; base_ar = n_ar;
    tl_req(3'd2, 0, 2, 32'h50, 4'hF, 0, 0);              // bad opcode
    tl_req(3'd7, 0, 2, 32'h50, 4'hF, 0, 0);              // bad opcode
    tl_req(3'd4, 3'd1, 2, 32'h50, 4'hF, 0, 0);           // a_param != 0
    tl_req(3'd4, 0, 3, 32'h50, 4'hF, 0, 0);              // size 3 > bus width
    tl_req(3'd0, 0, 2, 32'h52, 4'hF, 0, 0);              // misaligned
    tl_req(3'd4, 0, 1, 32'h51, 4'b0110, 0, 0);           // misaligned halfword
    tl_req(3'd0, 0, 0, 32'h50, 4'b0011, 0, 0);           // mask outside active lanes
    tl_req(3'd4, 0, 2, 32'h50, 4'b0111, 0, 0);           // Get with partial mask
    tl_req(3'd0, 0, 2, 32'h50, 4'b1011, 0, 0);           // PutFull with partial mask
    wait_idle;
    check(n_aw == base_aw && n_ar == base_ar, "T9 illegal request reached AXI");

    // ---------------- T10 back-to-back write -> read ----------------
    set_slave(0, 100, 0, 0);
    for (t = 0; t < 16; t = t + 1) begin
      tl_req(3'd0, 0, 2, 32'h60 + 4*(t%4), 4'hF, 32'h1000_0000 + t, 0);
      tl_req(3'd4, 0, 2, 32'h60 + 4*(t%4), 4'hF, 0, 0);
    end
    wait_idle;

    // ---------------- T11 reset during a transaction ----------------
    set_slave(0, 100, 20, 20);
    tl_req(3'd4, 0, 2, 32'h60, 4'hF, 0, 0);
    cycles(5);
    do_reset(110);
    set_slave(0, 100, 0, 0);
    tl_req(3'd4, 0, 2, 32'h60, 4'hF, 0, 0);
    wait_idle;

    $display("--- directed tests done, errors so far: %0d", n_err);

    // ---------------- Random: stalls everywhere ----------------
    set_slave(0, 60, 0, 4);
    dr_mode = 1; dr_pct = 70;
    for (t = 0; t < ntrans; t = t + 1) begin
      rand_req(r_op, r_prm, r_sz, r_addr, r_mask, r_data);
      tl_req(r_op, r_prm, r_sz, r_addr, r_mask, r_data, 1);
      gap = {$random(seed)} % 3;
      if (gap != 0) cycles(gap);
      if (t % 1000 == 999) slv.wr_mode = {$random(seed)} % 4;
    end
    wait_idle;

    // ---------------- Random: full throughput ----------------
    set_slave(0, 100, 0, 0);
    dr_mode = 0;
    for (t = 0; t < ntrans/5; t = t + 1) begin
      rand_req(r_op, r_prm, r_sz, r_addr, r_mask, r_data);
      tl_req(r_op, r_prm, r_sz, r_addr, r_mask, r_data, 0);
    end
    wait_idle;
    cycles(5);

    // ---------------- final checks & report ----------------
    check(outstanding == 0, "responses missing at end");
    check(n_aw == n_fwd_wr && n_w == n_fwd_wr && n_b == n_fwd_wr, "AXI write count mismatch");
    check(n_ar == n_fwd_rd && n_r == n_fwd_rd, "AXI read count mismatch");
    check(n_resp == n_acc - 1, "accepted vs responded (1 dropped by T11 reset)");

    $display("");
    $display("Coverage (seed %0d):", seed0);
    $display("  accepted %0d, responses %0d, abandoned %0d", n_acc, n_resp, cov_abandon);
    $display("  Get      size0/1/2 : %0d / %0d / %0d", cov_op_sz[0][0], cov_op_sz[0][1], cov_op_sz[0][2]);
    $display("  PutFull  size0/1/2 : %0d / %0d / %0d", cov_op_sz[1][0], cov_op_sz[1][1], cov_op_sz[1][2]);
    $display("  PutPart  size0/1/2 : %0d / %0d / %0d", cov_op_sz[2][0], cov_op_sz[2][1], cov_op_sz[2][2]);
    $display("  errors   local/SLVERR/DECERR : %0d / %0d / %0d", cov_lerr, cov_slverr, cov_decerr);
    $display("  AW/W     AW-first/W-first/same : %0d / %0d / %0d", cov_awfirst, cov_wfirst, cov_same);
    $display("  stalls   D-stall cycles %0d, A-busy cycles %0d", cov_dstall, cov_busy);
    $display("");
    if (n_err == 0) $display("*** PASS ***");
    else            $display("*** FAIL: %0d errors ***", n_err);
    $finish;
  end

  // fail fast
  always @(posedge clk) if (n_err >= 20) begin
    $display("*** FAIL: stopped after %0d errors ***", n_err); $finish;
  end

  initial begin
    #50_000_000;
    $display("ERROR: global timeout"); $display("*** FAIL ***"); $finish;
  end

endmodule
