`timescale 1ns/1ps
module tb_wave;
  reg clk=0, rst_n=0; always #5 clk=~clk;
  reg a_valid=0; wire a_ready; reg [2:0] a_opcode=0; reg [1:0] a_size=2; reg [7:0] a_source=0;
  reg [31:0] a_address=0; reg [3:0] a_mask=0; reg [31:0] a_data=0;
  wire d_valid; reg d_ready=1; wire [2:0] d_opcode; wire [1:0] d_param, d_size; wire [7:0] d_source; wire d_sink; wire [31:0] d_data; wire d_error;
  wire [31:0] awaddr, wdata, araddr, rdata; wire [3:0] wstrb; wire [2:0] awprot, arprot; wire [1:0] bresp, rresp;
  wire awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  tlul2axil dut(.clk(clk),.rst_n(rst_n),.a_valid(a_valid),.a_ready(a_ready),.a_opcode(a_opcode),.a_param(3'd0),
    .a_size(a_size),.a_source(a_source),.a_address(a_address),.a_mask(a_mask),.a_data(a_data),
    .d_valid(d_valid),.d_ready(d_ready),.d_opcode(d_opcode),.d_param(d_param),.d_size(d_size),.d_source(d_source),
    .d_sink(d_sink),.d_data(d_data),.d_error(d_error),
    .m_awaddr(awaddr),.m_awprot(awprot),.m_awvalid(awvalid),.m_awready(awready),.m_wdata(wdata),.m_wstrb(wstrb),
    .m_wvalid(wvalid),.m_wready(wready),.m_bresp(bresp),.m_bvalid(bvalid),.m_bready(bready),.m_araddr(araddr),
    .m_arprot(arprot),.m_arvalid(arvalid),.m_arready(arready),.m_rdata(rdata),.m_rresp(rresp),.m_rvalid(rvalid),.m_rready(rready));
  axil_slave_model slv(.clk(clk),.rst_n(rst_n),.awaddr(awaddr),.awprot(awprot),.awvalid(awvalid),.awready(awready),
    .wdata(wdata),.wstrb(wstrb),.wvalid(wvalid),.wready(wready),.bresp(bresp),.bvalid(bvalid),.bready(bready),
    .araddr(araddr),.arprot(arprot),.arvalid(arvalid),.arready(arready),.rdata(rdata),.rresp(rresp),.rvalid(rvalid),.rready(rready));
  integer cyc=0;
  always @(posedge clk) begin
    cyc <= cyc+1;
    if (rst_n) $display("W %0d %b %b %0d %b %b %b %b %b %b %b %b %b %b %b %b %b %0d %h %b %0d",
      cyc, a_valid, a_ready, a_opcode, awvalid, awready, wvalid, wready, bvalid, bready,
      arvalid, arready, rvalid, rready, d_valid, d_ready, d_error, d_opcode, d_data, d_valid&d_ready, dut.state);
  end
  initial begin
    slv.wr_mode=2; slv.ready_pct=100; slv.dly_min=1; slv.dly_max=1;
    repeat(3) @(posedge clk); #1 rst_n=1;
    @(posedge clk); #1;
    // PutFullData 0x40 <= 0x1234ABCD, source 3 (W accepted before AW)
    a_valid=1; a_opcode=0; a_size=2; a_source=3; a_address=32'h40; a_mask=4'hF; a_data=32'h1234ABCD;
    @(posedge clk); #1 a_valid=0;
    wait(d_valid); @(posedge clk); #1;
    // Get 0x40, source 5, D held off 2 cycles
    a_valid=1; a_opcode=4; a_source=5; a_data=0;
    @(posedge clk); #1 a_valid=0; d_ready=0;
    wait(d_valid); @(posedge clk); @(posedge clk); #1 d_ready=1;
    repeat(3) @(posedge clk);
    $finish;
  end
endmodule
