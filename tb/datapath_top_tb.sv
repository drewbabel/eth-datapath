`timescale 1ns / 1ps
`default_nettype none

module datapath_top_tb ();

  int checks = 0;
  int errors = 0;

  localparam logic [47:0] Mac0 = 48'h02_00_00_00_00_00;
  localparam logic [47:0] Mac1 = 48'h02_00_00_00_00_01;
  localparam logic [47:0] MacX = 48'h02_00_00_00_00_07;
  localparam logic [31:0] CrcResidue = 32'hDEBB_20E3;
  localparam int GapBytes = 12;

  logic clk = 1'b0;
  logic clk90 = 1'b0;
  logic rst_n = 1'b0;

  logic [1:0] rgmii_rx_clk = '0;
  logic [1:0][3:0] rgmii_rxd = '0;
  logic [1:0] rgmii_rx_ctl = '0;
  logic [1:0] rgmii_tx_clk;
  logic [1:0][3:0] rgmii_txd;
  logic [1:0] rgmii_tx_ctl;

  logic s_axi_awvalid = 1'b0;
  logic s_axi_awready;
  logic [4:0] s_axi_awaddr = '0;
  logic s_axi_wvalid = 1'b0;
  logic s_axi_wready;
  logic [31:0] s_axi_wdata = '0;
  logic s_axi_bvalid;
  logic s_axi_bready = 1'b0;
  logic [1:0] s_axi_bresp;
  logic s_axi_arvalid = 1'b0;
  logic s_axi_arready;
  logic [4:0] s_axi_araddr = '0;
  logic s_axi_rvalid;
  logic s_axi_rready = 1'b0;
  logic [31:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;

  // Reference model
  logic [50:0] exp_q[$];
  int exp_drops[2] = '{0, 0};

  always #4 clk = ~clk;
  initial begin
    #2;
    forever #4 clk90 = ~clk90;
  end
  always @(clk) rgmii_rx_clk = {clk, clk};

  datapath_top #(
      .MATCH_MAC ({Mac1, Mac0}),
      .MATCH_DEST(2'b10)
  ) dut (
      .clk(clk),
      .clk90(clk90),
      .rst_n(rst_n),
      .rgmii_rx_clk(rgmii_rx_clk),
      .rgmii_rxd(rgmii_rxd),
      .rgmii_rx_ctl(rgmii_rx_ctl),
      .rgmii_tx_clk(rgmii_tx_clk),
      .rgmii_txd(rgmii_txd),
      .rgmii_tx_ctl(rgmii_tx_ctl),
      .s_axi_awvalid(s_axi_awvalid),
      .s_axi_awready(s_axi_awready),
      .s_axi_awaddr(s_axi_awaddr),
      .s_axi_awprot(3'b000),
      .s_axi_wvalid(s_axi_wvalid),
      .s_axi_wready(s_axi_wready),
      .s_axi_wdata(s_axi_wdata),
      .s_axi_wstrb(4'hF),
      .s_axi_bvalid(s_axi_bvalid),
      .s_axi_bready(s_axi_bready),
      .s_axi_bresp(s_axi_bresp),
      .s_axi_arvalid(s_axi_arvalid),
      .s_axi_arready(s_axi_arready),
      .s_axi_araddr(s_axi_araddr),
      .s_axi_arprot(3'b000),
      .s_axi_rvalid(s_axi_rvalid),
      .s_axi_rready(s_axi_rready),
      .s_axi_rdata(s_axi_rdata),
      .s_axi_rresp(s_axi_rresp)
  );

  function automatic logic [31:0] crc_byte(input logic [31:0] crc, input logic [7:0] b);
    crc = crc ^ {24'h0, b};
    for (int k = 0; k < 8; k++) crc = crc[0] ? (crc >> 1) ^ 32'hEDB8_8320 : crc >> 1;
    return crc;
  endfunction

  function automatic int find_head(input int egress, input int ingress);
    logic [50:0] e;
    for (int i = 0; i < exp_q.size(); i++) begin
      e = exp_q[i];
      if (e[50] == egress[0] && e[49] == ingress[0]) return i;
    end
    return -1;
  endfunction

  task automatic check(input string name, input logic ok);
    checks++;
    if (!ok) begin
      errors++;
      $error("t=%0t %s", $time, name);
    end
  endtask

  task automatic do_reset();
    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
    repeat (200) @(posedge clk);
  endtask

  task automatic drain(input int cycles);
    repeat (cycles) @(posedge clk);
  endtask

  // Receive pin driver
  task automatic rgmii_byte(input int port, input logic [7:0] b, input logic en);
    @(negedge clk);
    #2 rgmii_rxd[port] = b[3:0];
    rgmii_rx_ctl[port] = en;
    @(posedge clk);
    #2 rgmii_rxd[port] = b[7:4];
    rgmii_rx_ctl[port] = en;
  endtask

  // One frame in
  task automatic send_frame(input int port, input logic [47:0] dest, input int payload,
                            input logic bad);
    logic [7:0] content[$];
    logic [31:0] crc;
    logic [15:0] len;
    for (int i = 5; i >= 0; i--) content.push_back(dest[i*8+:8]);
    for (int i = 5; i >= 0; i--) content.push_back(i == 0 ? 8'(port) + 8'h10 : 8'h02 >> (i * 2));
    content.push_back(8'h08);
    content.push_back(8'h00);
    for (int i = 0; i < payload; i++) content.push_back(($bits(content[0]))'($urandom));

    crc = '1;
    for (int i = 0; i < content.size(); i++) crc = crc_byte(crc, content[i]);
    len = ($bits(len))'(content.size());

    if (dest == Mac0 || dest == Mac1) begin
      exp_q.push_back({dest == Mac1, port[0], bad, len, ~crc});
    end else begin
      exp_drops[port]++;
    end

    repeat (7) rgmii_byte(port, 8'h55, 1'b1);
    rgmii_byte(port, 8'hD5, 1'b1);
    for (int i = 0; i < content.size(); i++) rgmii_byte(port, content[i], 1'b1);
    crc = ~crc;
    if (bad) crc[0] = ~crc[0];
    for (int i = 0; i < 4; i++) rgmii_byte(port, crc[i*8+:8], 1'b1);
    repeat (GapBytes) rgmii_byte(port, 8'h00, 1'b0);
  endtask

  // One frame out
  task automatic check_frame(input int egress, input int count, input logic [31:0] content_crc,
                             input logic fcs_ok, input logic er);
    logic [50:0] e;
    int idx;
    logic matched;
    check($sformatf("port %0d frame check sequence", egress), fcs_ok);
    matched = 1'b0;
    for (int ingress = 0; ingress < 2 && !matched; ingress++) begin
      idx = find_head(egress, ingress);
      if (idx >= 0) begin
        e = exp_q[idx];
        if (e[47:32] == 16'(count - 4) && e[31:0] == ~content_crc && e[48] == er) begin
          exp_q.delete(idx);
          matched = 1'b1;
        end
      end
    end
    check($sformatf("port %0d frame of %0d bytes expected", egress, count - 4), matched);
  endtask

  // Transmit pin decoder
  for (genvar p = 0; p < 2; p++) begin : g_rx
    logic [3:0] lo;
    logic en = 1'b0;
    logic seen_sfd = 1'b0;
    logic er_seen = 1'b0;
    int count = 0;
    logic [31:0] crc;
    logic [31:0] hist[4];

    always @(posedge rgmii_tx_clk[p]) begin
      lo = rgmii_txd[p];
      en = rgmii_tx_ctl[p];
      if (!en && seen_sfd) begin
        check_frame(p, count, hist[3], crc == CrcResidue, er_seen);
        seen_sfd = 1'b0;
      end
    end

    always @(negedge rgmii_tx_clk[p]) begin
      logic [7:0] b;
      b = {rgmii_txd[p], lo};
      if (en && !seen_sfd && b == 8'hD5) begin
        seen_sfd = 1'b1;
        er_seen  = 1'b0;
        count    = 0;
        crc      = '1;
      end else if (en && seen_sfd) begin
        if (en ^ rgmii_tx_ctl[p]) er_seen = 1'b1;
        hist[3] = hist[2];
        hist[2] = hist[1];
        hist[1] = hist[0];
        hist[0] = crc;
        crc = crc_byte(crc, b);
        count++;
      end
    end
  end

  task automatic random_traffic(input int port, input int frames);
    int pick;
    int payload;
    for (int f = 0; f < frames; f++) begin
      pick    = $urandom_range(0, 4);
      payload = $urandom_range(46, 400);
      send_frame(port, pick < 2 ? Mac0 : pick < 4 ? Mac1 : MacX, payload,
                 $urandom_range(0, 7) == 0);
      repeat (payload) rgmii_byte(port, 8'h00, 1'b0);
    end
  endtask

  task automatic wait_empty();
    for (int i = 0; i < 200_000 && exp_q.size() != 0; i++) @(posedge clk);
    drain(200);
  endtask

  task automatic axil_write(input logic [4:0] addr, input logic [31:0] data);
    @(posedge clk);
    #1 s_axi_awaddr = addr;
    s_axi_wdata   = data;
    s_axi_awvalid = 1'b1;
    s_axi_wvalid  = 1'b1;
    do @(posedge clk); while (!(s_axi_awready && s_axi_wready));
    #1 s_axi_awvalid = 1'b0;
    s_axi_wvalid = 1'b0;
    s_axi_bready = 1'b1;
    do @(posedge clk); while (!s_axi_bvalid);
    #1 s_axi_bready = 1'b0;
  endtask

  task automatic axil_read(input logic [4:0] addr, output logic [31:0] data);
    @(posedge clk);
    #1 s_axi_araddr = addr;
    s_axi_arvalid = 1'b1;
    do @(posedge clk); while (!s_axi_arready);
    #1 s_axi_arvalid = 1'b0;
    s_axi_rready = 1'b1;
    do @(posedge clk); while (!s_axi_rvalid);
    data = s_axi_rdata;
    #1 s_axi_rready = 1'b0;
  endtask

  task automatic check_counters();
    logic [31:0] v;
    axil_read(5'h10, v);
    check($sformatf("port 0 overflow count %0d", v), v == 0);
    axil_read(5'h14, v);
    check($sformatf("port 0 drop count %0d of %0d", v, exp_drops[0]), v == 32'(exp_drops[0]));
    axil_read(5'h18, v);
    check($sformatf("port 1 overflow count %0d", v), v == 0);
    axil_read(5'h1C, v);
    check($sformatf("port 1 drop count %0d of %0d", v, exp_drops[1]), v == 32'(exp_drops[1]));
  endtask

  task automatic check_scratch();
    logic [31:0] v;
    axil_write(5'h04, 32'hA5A5_0104);
    axil_read(5'h04, v);
    check("writable register readback", v == 32'hA5A5_0104);
  endtask

  task automatic do_verdict();
    check($sformatf("%0d expected frames never arrived", exp_q.size()), exp_q.size() == 0);
    if (errors == 0) $display("PASS datapath_top_tb: %0d checks", checks);
    else begin
      $display("FAIL datapath_top_tb: %0d errors of %0d checks", errors, checks);
      $fatal(1);
    end
    $finish;
  endtask

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, datapath_top_tb);
    do_reset();

    // Each route once
    send_frame(0, Mac1, 46, 1'b0);
    send_frame(0, Mac0, 46, 1'b0);
    send_frame(1, Mac0, 46, 1'b0);
    send_frame(1, Mac1, 46, 1'b0);
    wait_empty();

    // Miss and bad
    send_frame(0, MacX, 46, 1'b0);
    send_frame(1, Mac0, 100, 1'b1);
    wait_empty();

    // Largest frames contended
    fork
      send_frame(0, Mac1, 1500, 1'b0);
      send_frame(1, Mac1, 1500, 1'b0);
    join
    wait_empty();

    // Randomized traffic
    fork
      random_traffic(0, 40);
      random_traffic(1, 40);
    join
    wait_empty();

    // Register bus
    check_counters();
    check_scratch();

    do_verdict();
  end

  // Watchdog
  initial begin
    #500_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

endmodule

`default_nettype wire
