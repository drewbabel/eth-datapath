`default_nettype none

module uart_axil_tb ();

  int checks = 0;
  int errors = 0;

  localparam int ClkFreqHz = 18_432_000;
  localparam int BaudRate = 115_200;
  localparam int AddrWidth = 5;
  localparam int DataWidth = 32;

  // Clock period ten
  localparam int BitTime = 10 * ((ClkFreqHz + BaudRate / 2) / BaudRate);

  localparam int NumRegs = 2 ** (AddrWidth - 2);
  localparam int NumRw = NumRegs / 2;

  logic clk = 1'b0;
  logic rst_n = 1'b1;

  logic host_tx = 1'b1;
  logic dut_tx;

  logic                 awvalid;
  logic                 awready;
  logic [AddrWidth-1:0] awaddr;
  logic [          2:0] awprot;
  logic                 wvalid;
  logic                 wready;
  logic [DataWidth-1:0] wdata;
  logic [          3:0] wstrb;
  logic                 bvalid;
  logic                 bready;
  logic [          1:0] bresp;
  logic                 arvalid;
  logic                 arready;
  logic [AddrWidth-1:0] araddr;
  logic [          2:0] arprot;
  logic                 rvalid;
  logic                 rready;
  logic [DataWidth-1:0] rdata;
  logic [          1:0] rresp;

  logic [NumRw-1:0][DataWidth-1:0] status;

  logic [DataWidth-1:0] ref_regs[NumRw];

  logic [7:0] rx_q[$];

  always #5 clk = ~clk;

  // Sample mid bit
  initial begin
    logic [7:0] b;
    forever begin
      @(negedge dut_tx);
      #(BitTime + BitTime / 2);
      for (int i = 0; i < 8; i++) begin
        b[i] = dut_tx;
        #(BitTime);
      end
      rx_q.push_back(b);
    end
  end

  uart_axil #(
      .CLK_FREQ_HZ(ClkFreqHz),
      .BAUD_RATE  (BaudRate),
      .ADDR_WIDTH (AddrWidth),
      .DATA_WIDTH (DataWidth)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .rx_serial(host_tx),
      .tx_serial(dut_tx),
      .m_axi_awvalid(awvalid),
      .m_axi_awready(awready),
      .m_axi_awaddr(awaddr),
      .m_axi_awprot(awprot),
      .m_axi_wvalid(wvalid),
      .m_axi_wready(wready),
      .m_axi_wdata(wdata),
      .m_axi_wstrb(wstrb),
      .m_axi_bvalid(bvalid),
      .m_axi_bready(bready),
      .m_axi_arvalid(arvalid),
      .m_axi_arready(arready),
      .m_axi_araddr(araddr),
      .m_axi_arprot(arprot),
      .m_axi_rvalid(rvalid),
      .m_axi_rready(rready),
      .m_axi_rdata(rdata)
  );

  axil_csr #(
      .ADDR_WIDTH(AddrWidth),
      .DATA_WIDTH(DataWidth)
  ) slave (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_awvalid(awvalid),
      .s_axi_awready(awready),
      .s_axi_awaddr(awaddr),
      .s_axi_awprot(awprot),
      .s_axi_wvalid(wvalid),
      .s_axi_wready(wready),
      .s_axi_wdata(wdata),
      .s_axi_wstrb(wstrb),
      .s_axi_bvalid(bvalid),
      .s_axi_bready(bready),
      .s_axi_bresp(bresp),
      .s_axi_arvalid(arvalid),
      .s_axi_arready(arready),
      .s_axi_araddr(araddr),
      .s_axi_arprot(arprot),
      .s_axi_rvalid(rvalid),
      .s_axi_rready(rready),
      .s_axi_rdata(rdata),
      .s_axi_rresp(rresp),
      .status(status)
  );

  task automatic do_reset();
    rst_n   = 1'b0;
    host_tx = 1'b1;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    repeat (4) @(posedge clk);
  endtask  // Automatic

  task automatic check_word(input string name, input logic [DataWidth-1:0] got,
                            input logic [DataWidth-1:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%08h exp=%08h", $time, name, got, exp);
    end
  endtask  // Automatic

  // Start eight stop
  task automatic serial_send(input logic [7:0] value);
    host_tx = 1'b0;
    #(BitTime);
    for (int i = 0; i < 8; i++) begin
      host_tx = value[i];
      #(BitTime);
    end
    host_tx = 1'b1;
    #(BitTime);
  endtask  // Automatic

  task automatic serial_recv(output logic [7:0] value);
    while (rx_q.size() == 0) @(posedge clk);
    value = rx_q.pop_front();
  endtask  // Automatic

  task automatic bus_write(input logic [7:0] addr, input logic [DataWidth-1:0] value);
    logic [7:0] ack;
    serial_send(8'h57);
    serial_send(addr);
    for (int i = 0; i < DataWidth / 8; i++) serial_send(value[i*8+:8]);
    serial_recv(ack);
    checks++;
    if (ack !== 8'h4B) begin
      errors++;
      $error("t=%0t write ack mismatch: got=%02h exp=4B", $time, ack);
    end
  endtask  // Automatic

  task automatic bus_read(input logic [7:0] addr, output logic [DataWidth-1:0] value);
    logic [7:0] rx;
    serial_send(8'h52);
    serial_send(addr);
    for (int i = 0; i < DataWidth / 8; i++) begin
      serial_recv(rx);
      value[i*8+:8] = rx;
    end
  endtask  // Automatic

  task automatic write_and_check(input int index, input logic [DataWidth-1:0] value);
    logic [DataWidth-1:0] got;
    bus_write(8'(index * 4), value);
    ref_regs[index] = value;
    bus_read(8'(index * 4), got);
    check_word($sformatf("reg%0d", index), got, value);
  endtask  // Automatic

  task automatic read_status(input int index);
    logic [DataWidth-1:0] got;
    bus_read(8'((NumRw + index) * 4), got);
    check_word($sformatf("status%0d", index), got, status[index]);
  endtask  // Automatic

  task automatic send_stray(input logic [7:0] value);
    serial_send(value);
  endtask  // Automatic

  task automatic do_verdict();
    @(posedge clk);
    if (errors == 0) begin
      $display("PASS: %0d checks, %0d mismatches", checks, errors);
    end else begin
      $fatal(1, "FAIL: %0d mismatches, %0d checks", errors, checks);
    end
    $finish;
  endtask  // Automatic

  initial begin
    logic [DataWidth-1:0] got;

    $dumpfile("tb.vcd");
    $dumpvars(0, uart_axil_tb);

    status = {32'hC0DE_0003, 32'hC0DE_0002, 32'hC0DE_0001, 32'hC0DE_0000};
    for (int i = 0; i < NumRw; i++) ref_regs[i] = '0;

    do_reset();

    // Each register once
    write_and_check(0, 32'hDEAD_BEEF);
    write_and_check(1, 32'h0000_0001);
    write_and_check(2, 32'hFFFF_FFFF);
    write_and_check(3, 32'h1234_5678);

    // Every status word
    for (int i = 0; i < NumRw; i++) read_status(i);

    // Stray bytes ignored
    send_stray(8'h00);
    send_stray(8'hAA);
    send_stray(8'hFF);
    bus_read(8'h00, got);
    check_word("after stray", got, ref_regs[0]);

    // Randomized writes
    for (int i = 0; i < 8; i++) begin
      int idx;
      idx = $urandom_range(0, NumRw - 1);
      write_and_check(idx, $urandom);
    end
    for (int i = 0; i < NumRw; i++) begin
      bus_read(8'(i * 4), got);
      check_word($sformatf("final reg%0d", i), got, ref_regs[i]);
    end

    // Status still readable
    read_status(0);
    read_status(NumRw - 1);

    do_verdict();
  end

  // Watchdog
  initial begin
    #500_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

endmodule

`default_nettype wire
