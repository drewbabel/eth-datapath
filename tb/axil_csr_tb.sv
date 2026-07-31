`default_nettype none

module axil_csr_tb ();

  int checks = 0;
  int errors = 0;

  localparam int AddrWidth = 4;
  localparam int DataWidth = 32;
  localparam int StrbWidth = DataWidth / 8;
  localparam int NumRegs = 4;
  localparam int Lsb = 2;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic s_axi_awvalid = 1'b0;
  logic s_axi_awready;
  logic [AddrWidth-1:0] s_axi_awaddr = '0;
  logic [2:0] s_axi_awprot = 3'b000;
  logic s_axi_wvalid = 1'b0;
  logic s_axi_wready;
  logic [DataWidth-1:0] s_axi_wdata = '0;
  logic [StrbWidth-1:0] s_axi_wstrb = '0;
  logic s_axi_bvalid;
  logic s_axi_bready = 1'b0;
  logic [1:0] s_axi_bresp;
  logic s_axi_arvalid = 1'b0;
  logic s_axi_arready;
  logic [AddrWidth-1:0] s_axi_araddr = '0;
  logic [2:0] s_axi_arprot = 3'b000;
  logic s_axi_rvalid;
  logic s_axi_rready = 1'b0;
  logic [DataWidth-1:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;

  logic [DataWidth-1:0] ref_regs[NumRegs];
  int stall = 0;

  always #5 clk = ~clk;

  axil_csr #(
      .ADDR_WIDTH(AddrWidth),
      .DATA_WIDTH(DataWidth)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_awvalid(s_axi_awvalid),
      .s_axi_awready(s_axi_awready),
      .s_axi_awaddr(s_axi_awaddr),
      .s_axi_awprot(s_axi_awprot),
      .s_axi_wvalid(s_axi_wvalid),
      .s_axi_wready(s_axi_wready),
      .s_axi_wdata(s_axi_wdata),
      .s_axi_wstrb(s_axi_wstrb),
      .s_axi_bvalid(s_axi_bvalid),
      .s_axi_bready(s_axi_bready),
      .s_axi_bresp(s_axi_bresp),
      .s_axi_arvalid(s_axi_arvalid),
      .s_axi_arready(s_axi_arready),
      .s_axi_araddr(s_axi_araddr),
      .s_axi_arprot(s_axi_arprot),
      .s_axi_rvalid(s_axi_rvalid),
      .s_axi_rready(s_axi_rready),
      .s_axi_rdata(s_axi_rdata),
      .s_axi_rresp(s_axi_rresp)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    s_axi_awvalid = 1'b0;
    s_axi_wvalid = 1'b0;
    s_axi_bready = 1'b0;
    s_axi_arvalid = 1'b0;
    s_axi_rready = 1'b0;
    stall = 0;
    @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
  endtask  // Automatic

  task automatic do_verdict();
    @(posedge clk);
    if (errors == 0) begin
      $display("PASSED: %0d checks", checks);
    end else begin
      $display("FAILED: %0d checks, %0d errors", checks, errors);
    end
    $finish;
  endtask  // Automatic

  task automatic check_data(input string name, input logic [DataWidth-1:0] got,
                            input logic [DataWidth-1:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%h exp=%h", $time, name, got, exp);
    end
  endtask  // Automatic

  task automatic check_resp(input string name, input logic [1:0] got);
    checks++;
    if (got !== 2'b00) begin
      errors++;
      $error("t=%0t %s not OKAY: got=%b", $time, name, got);
    end
  endtask  // Automatic

  task automatic idle(input int cycles);
    repeat (cycles) @(posedge clk);
  endtask  // Automatic

  // Write transaction
  task automatic axi_write(input int index, input logic [DataWidth-1:0] data,
                           input logic [StrbWidth-1:0] strb);
    #1;
    s_axi_awaddr  = (AddrWidth)'(index << Lsb);
    s_axi_awvalid = 1'b1;
    s_axi_wdata   = data;
    s_axi_wstrb   = strb;
    s_axi_wvalid  = 1'b1;
    do @(posedge clk); while (!(s_axi_awready && s_axi_wready));
    #1 s_axi_awvalid = 1'b0;
    s_axi_wvalid = 1'b0;

    for (int i = 0; i < StrbWidth; i++) begin
      if (strb[i]) ref_regs[index][(i*8)+:8] = data[(i*8)+:8];
    end

    idle(stall);
    #1 s_axi_bready = 1'b1;
    do @(posedge clk); while (!s_axi_bvalid);
    check_resp("bresp", s_axi_bresp);
    #1 s_axi_bready = 1'b0;
  endtask  // Automatic

  task automatic axi_read(input int index, output logic [DataWidth-1:0] data);
    #1;
    s_axi_araddr  = (AddrWidth)'(index << Lsb);
    s_axi_arvalid = 1'b1;
    do @(posedge clk); while (!s_axi_arready);
    #1 s_axi_arvalid = 1'b0;

    idle(stall);
    #1 s_axi_rready = 1'b1;
    do @(posedge clk); while (!s_axi_rvalid);
    data = s_axi_rdata;
    check_resp("rresp", s_axi_rresp);
    #1 s_axi_rready = 1'b0;
  endtask  // Automatic

  task automatic read_check(input int index);
    logic [DataWidth-1:0] got;
    axi_read(index, got);
    check_data($sformatf("reg%0d", index), got, ref_regs[index]);
  endtask  // Automatic

  // Read during write
  task automatic read_during_write(input int index);
    logic [DataWidth-1:0] prev;
    prev = ref_regs[index];
    #1;
    s_axi_araddr  = (AddrWidth)'(index << Lsb);
    s_axi_arvalid = 1'b1;
    do @(posedge clk); while (!s_axi_arready);
    #1 s_axi_arvalid = 1'b0;
    do @(posedge clk); while (!s_axi_rvalid);

    axi_write(index, ~prev, '1);
    check_data("rdata held", s_axi_rdata, prev);

    #1 s_axi_rready = 1'b1;
    @(posedge clk);
    check_data("rdata delivered", s_axi_rdata, prev);
    check_resp("rresp", s_axi_rresp);
    #1 s_axi_rready = 1'b0;
    read_check(index);
  endtask  // Automatic

  task automatic write_all(input logic [DataWidth-1:0] data, input logic [StrbWidth-1:0] strb);
    for (int i = 0; i < NumRegs; i++) axi_write(i, data, strb);
  endtask  // Automatic

  initial begin
    logic [DataWidth-1:0] data;
    logic [StrbWidth-1:0] strb;
    int index;

    $dumpfile("tb.vcd");
    $dumpvars(0, axil_csr_tb);
    do_reset();

    // Write then read
    write_all(32'h0000_0000, '1);
    for (int i = 0; i < NumRegs; i++) begin
      axi_write(i, 32'hA5A5_0000 + (DataWidth)'(i), '1);
      read_check(i);
    end

    // Register independence
    write_all(32'hFFFF_FFFF, '1);
    axi_write(2, 32'h0000_0000, '1);
    for (int i = 0; i < NumRegs; i++) read_check(i);

    // Single byte lanes
    write_all(32'hFFFF_FFFF, '1);
    for (int i = 0; i < StrbWidth; i++) begin
      axi_write(1, 32'h1122_3344, (StrbWidth)'(1 << i));
      read_check(1);
    end

    // No strobes
    axi_write(3, 32'hDEAD_BEEF, '0);
    read_check(3);

    // Read during write
    write_all(32'h1357_9BDF, '1);
    for (int i = 0; i < NumRegs; i++) read_during_write(i);

    // Random then stalled
    for (int pass = 0; pass < 2; pass++) begin
      stall = pass;
      repeat (200) begin
        index = $urandom % NumRegs;
        data  = (DataWidth)'($urandom);
        strb  = (StrbWidth)'($urandom);
        axi_write(index, data, strb);
        read_check(index);
      end
      for (int i = 0; i < NumRegs; i++) read_check(i);
    end

    // Consecutive writes
    stall = 0;
    repeat (20) begin
      index = $urandom % NumRegs;
      axi_write(index, (DataWidth)'($urandom), '1);
    end
    for (int i = 0; i < NumRegs; i++) read_check(i);

    do_verdict();
  end

  // Watchdog
  initial begin
    #200_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

  // Payload stability
  logic reg_bvalid;
  logic reg_rvalid;
  logic [DataWidth-1:0] reg_rdata;

  always @(posedge clk) begin
    reg_bvalid <= s_axi_bvalid;
    reg_rvalid <= s_axi_rvalid && !s_axi_rready;
    reg_rdata  <= s_axi_rdata;
  end

  always @(negedge clk) begin
    if (rst_n && reg_rvalid) begin
      check_data("rdata stable", s_axi_rdata, reg_rdata);
    end
  end

endmodule

`default_nettype wire
