`default_nettype none

module axis_skid_tb ();

  int checks = 0;
  int errors = 0;

  localparam int Width = 8;
  localparam int PktLen = 4;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic s_tvalid = 1'b0;
  logic s_tready;
  logic [Width-1:0] s_tdata;
  logic s_tlast = 1'b0;
  logic m_tvalid;
  logic m_tready = 1'b0;
  logic [Width-1:0] m_tdata;
  logic m_tlast;

  logic send_en = 1'b0;
  logic gap_en = 1'b0;
  logic stall_en = 1'b0;
  logic tput_en = 1'b0;
  logic s_taken = 1'b0;
  int beat = 0;
  int sent = 0;
  int rcvd = 0;
  logic [Width-1:0] data_q[$];
  logic last_q[$];
  logic reg_m_tvalid;
  logic [Width-1:0] reg_m_tdata;
  logic reg_m_tlast;
  logic reg_m_xfer;

  always #5 clk = ~clk;

  axis_skid #(
      .WIDTH(Width)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .s_tvalid(s_tvalid),
      .s_tready(s_tready),
      .s_tdata(s_tdata),
      .s_tlast(s_tlast),
      .m_tvalid(m_tvalid),
      .m_tready(m_tready),
      .m_tdata(m_tdata),
      .m_tlast(m_tlast)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    s_tvalid = 1'b0;
    s_tlast = 1'b0;
    m_tready = 1'b0;
    send_en = 1'b0;
    gap_en = 1'b0;
    stall_en = 1'b0;
    tput_en = 1'b0;
    beat = 0;
    sent = 0;
    rcvd = 0;
    data_q = {};
    last_q = {};
    @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
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

  task automatic check_bit(input string name, input logic got, input logic exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%b exp=%b", $time, name, got, exp);
    end
  endtask  // Automatic

  task automatic check_int(input string name, input int got, input int exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%0d exp=%0d", $time, name, got, exp);
    end
  endtask  // Automatic

  task automatic check_data(input string name, input logic [Width-1:0] got,
                            input logic [Width-1:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%h exp=%h", $time, name, got, exp);
    end
  endtask  // Automatic

  task automatic idle(input int cycles);
    repeat (cycles) @(posedge clk);
  endtask  // Automatic

  // Holds the offered beat until DUT takes it
  always @(posedge clk) begin
    if (!rst_n) begin
      s_tvalid = 1'b0;
      s_tdata  = '0;
      s_tlast  = 1'b0;
    end else begin
      #1;
      if (!s_tvalid || s_taken) begin
        if (send_en && (!gap_en || 1'($urandom))) begin
          s_tvalid = 1'b1;
          s_tdata = (Width)'($urandom);
          s_tlast = (beat == PktLen - 1);
          beat = s_tlast ? 0 : beat + 1;
        end else begin
          s_tvalid = 1'b0;
        end
      end
    end
  end

  always @(posedge clk) begin
    if (!rst_n) m_tready = 1'b0;
    else #1 m_tready = stall_en ? 1'($urandom) : 1'b1;
  end

  always @(posedge clk) begin
    s_taken <= rst_n && s_tvalid && s_tready;
    if (rst_n && s_tvalid && s_tready) begin
      data_q.push_back(s_tdata);
      last_q.push_back(s_tlast);
      sent++;
    end
  end

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, axis_skid_tb);
    do_reset();

    // Prime, then demand beat every cycle
    send_en = 1'b1;
    idle(4);
    tput_en = 1'b1;
    idle(50);
    tput_en  = 1'b0;

    // Random backpressure
    stall_en = 1'b1;
    idle(200);

    // Random gaps from the source
    stall_en = 1'b0;
    gap_en   = 1'b1;
    idle(200);

    // Both sides irregular
    stall_en = 1'b1;
    idle(400);

    // Drain
    send_en  = 1'b0;
    gap_en   = 1'b0;
    stall_en = 1'b0;
    idle(20);

    check_int("beats out", rcvd, sent);
    check_int("queue drained", data_q.size(), 0);

    do_verdict();
  end

  // Watchdog
  initial begin
    #200_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

  // Reference model
  always @(posedge clk) begin
    if (!rst_n) begin
      reg_m_tvalid <= 1'b0;
      reg_m_tdata  <= '0;
      reg_m_tlast  <= 1'b0;
      reg_m_xfer   <= 1'b0;
    end else begin
      reg_m_tvalid <= m_tvalid;
      reg_m_tdata  <= m_tdata;
      reg_m_tlast  <= m_tlast;
      reg_m_xfer   <= m_tvalid && m_tready;
    end
  end

  // Compare against DUT
  always @(negedge clk) begin
    if (rst_n && m_tvalid && m_tready) begin
      if (data_q.size() == 0) begin
        checks++;
        errors++;
        $error("t=%0t beat with nothing sent", $time);
      end else begin
        check_data("m_tdata", m_tdata, data_q.pop_front());
        check_bit("m_tlast", m_tlast, last_q.pop_front());
      end
      rcvd++;
    end
  end

  always @(negedge clk) begin
    if (reg_m_tvalid && !reg_m_xfer) begin
      check_bit("m_tvalid stable", m_tvalid, 1'b1);
      check_data("m_tdata stable", m_tdata, reg_m_tdata);
      check_bit("m_tlast stable", m_tlast, reg_m_tlast);
    end
  end

  always @(negedge clk) begin
    if (rst_n && tput_en) check_bit("no bubble", m_tvalid && m_tready, 1'b1);
  end

endmodule

`default_nettype wire
