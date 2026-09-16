`default_nettype none

module classifier_tb ();

  int checks = 0;
  int errors = 0;

  localparam int NEntries = 2;
  localparam int DestW = 1;
  localparam logic [47:0] Mac0 = 48'h00_11_22_33_44_55;
  localparam logic [47:0] Mac1 = 48'h66_77_88_99_aa_bb;
  localparam logic [NEntries*48-1:0] MatchMac = {Mac1, Mac0};
  localparam logic [NEntries*DestW-1:0] MatchDest = {1'b1, 1'b0};

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic s_tvalid = 1'b0;
  logic s_tready;
  logic [7:0] s_tdata = '0;
  logic s_tlast = 1'b0;
  logic m_tvalid;
  logic m_tready = 1'b0;
  logic [7:0] m_tdata;
  logic m_tlast;
  logic [DestW-1:0] m_tdest;
  logic [31:0] drop_cnt;

  logic gap_en = 1'b0;
  logic stall_en = 1'b0;
  logic t1_en = 1'b0;
  logic t2_en = 1'b0;
  logic s_taken = 1'b0;

  int rcvd = 0;
  int exp_beats = 0;
  int exp_drops = 0;
  int cyc = 0;
  int in_idx = 0;
  int hdr_cyc = -1;
  logic out_open = 1'b0;

  logic [7:0] tx_data_q[$];
  logic tx_last_q[$];
  logic [7:0] exp_data_q[$];
  logic exp_last_q[$];
  logic [DestW-1:0] exp_dest_q[$];

  logic reg_m_tvalid;
  logic [7:0] reg_m_tdata;
  logic reg_m_tlast;
  logic [DestW-1:0] reg_m_tdest;
  logic reg_m_xfer;

  always #5 clk = ~clk;

  classifier #(
      .N_ENTRIES(NEntries),
      .DEST_W(DestW),
      .MATCH_MAC(MatchMac),
      .MATCH_DEST(MatchDest)
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
      .m_tlast(m_tlast),
      .m_tdest(m_tdest),
      .drop_cnt(drop_cnt)
  );

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

  task automatic check_data(input string name, input logic [7:0] got, input logic [7:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%h exp=%h", $time, name, got, exp);
    end
  endtask  // Automatic

  task automatic check_dest(input string name, input logic [DestW-1:0] got,
                            input logic [DestW-1:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%0d exp=%0d", $time, name, got, exp);
    end
  endtask  // Automatic

  task automatic check_le(input string name, input int got, input int lim);
    checks++;
    if (got > lim) begin
      errors++;
      $error("t=%0t %s: took %0d cycles, limit %0d", $time, name, got, lim);
    end
  endtask  // Automatic

  task automatic do_reset();
    rst_n = 1'b0;
    s_tvalid = 1'b0;
    s_tdata = '0;
    s_tlast = 1'b0;
    m_tready = 1'b0;
    gap_en = 1'b0;
    stall_en = 1'b0;
    t1_en = 1'b0;
    t2_en = 1'b0;
    rcvd = 0;
    exp_beats = 0;
    exp_drops = 0;
    in_idx = 0;
    hdr_cyc = -1;
    tx_data_q = {};
    tx_last_q = {};
    exp_data_q = {};
    exp_last_q = {};
    exp_dest_q = {};
    @(posedge clk);
    @(posedge clk);
    #1;
    check_bit("m_tvalid low in reset", m_tvalid, 1'b0);
    check_bit("s_tready low in reset", s_tready, 1'b0);
    check_int("drop_cnt zero in reset", int'(drop_cnt), 0);
    rst_n = 1'b1;
    @(posedge clk);
  endtask  // Automatic

  task automatic do_verdict();
    @(posedge clk);
    if (errors == 0) begin
      $display("PASS: %0d checks, %0d mismatches", checks, errors);
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d mismatches, %0d checks", errors, checks);
    end
  endtask  // Automatic

  task automatic idle(input int cycles);
    repeat (cycles) @(posedge clk);
  endtask  // Automatic

  function automatic int match_index(input logic [47:0] mac);
    for (int i = 0; i < NEntries; i++) begin
      if (mac == MatchMac[i*48+:48]) return i;
    end
    return -1;
  endfunction

  // Queue one frame
  task automatic send_frame(input logic [47:0] dst, input int len);
    logic [7:0] b;
    logic [7:0] frame[$];
    logic [DestW-1:0] dest;
    int idx;
    frame = {};
    for (int i = 0; i < len; i++) begin
      if (i < 6) b = dst[47-8*i-:8];
      else b = (8)'($urandom);
      frame.push_back(b);
    end
    for (int i = 0; i < len; i++) begin
      tx_data_q.push_back(frame[i]);
      tx_last_q.push_back(i == len - 1);
    end
    idx = (len >= 6) ? match_index(dst) : -1;
    if (idx < 0) begin
      exp_drops = exp_drops + 1;
    end else begin
      dest = (DestW)'(MatchDest[idx*DestW+:DestW]);
      exp_beats = exp_beats + len;
      for (int i = 0; i < len; i++) begin
        exp_data_q.push_back(frame[i]);
        exp_last_q.push_back(i == len - 1);
        exp_dest_q.push_back(dest);
      end
    end
  endtask  // Automatic

  task automatic drain();
    int guard = 0;
    while ((tx_data_q.size() > 0 || exp_data_q.size() > 0 || m_tvalid
            || int'(drop_cnt) != exp_drops) && guard < 40000) begin
      @(posedge clk);
      guard++;
    end
    repeat (8) @(posedge clk);
  endtask  // Automatic

  // Holds until taken
  always @(posedge clk) begin
    if (!rst_n) begin
      s_tvalid = 1'b0;
      s_tdata  = '0;
      s_tlast  = 1'b0;
    end else begin
      #1;
      if (!s_tvalid || s_taken) begin
        if (tx_data_q.size() > 0 && (!gap_en || 1'($urandom))) begin
          s_tvalid = 1'b1;
          s_tdata  = tx_data_q.pop_front();
          s_tlast  = tx_last_q.pop_front();
        end else begin
          s_tvalid = 1'b0;
        end
      end
    end
  end

  always @(posedge clk) s_taken <= rst_n && s_tvalid && s_tready;

  always @(posedge clk) begin
    if (!rst_n) m_tready = 1'b0;
    else #1 m_tready = stall_en ? 1'($urandom) : 1'b1;
  end

  always @(posedge clk) begin
    if (!rst_n) cyc <= 0;
    else cyc <= cyc + 1;
  end

  always @(posedge clk) begin
    if (!rst_n) out_open <= 1'b0;
    else if (m_tvalid && m_tready) out_open <= !m_tlast;
  end

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, classifier_tb);
    do_reset();

    // Directed frames
    send_frame(Mac0, 60);
    send_frame(Mac1, 60);
    send_frame(48'hde_ad_be_ef_00_01, 60);
    send_frame(Mac0, 3);
    send_frame(Mac1, 1);
    drain();
    check_int("frames drained after directed", exp_data_q.size(), 0);
    check_int("drop count after directed", int'(drop_cnt), exp_drops);

    // Back to back
    for (int i = 0; i < 8; i++) send_frame(i[0] ? Mac1 : Mac0, 60);
    drain();
    check_int("frames drained after back to back", exp_data_q.size(), 0);

    // Shortest matchable frame
    send_frame(Mac0, 6);
    send_frame(Mac1, 6);
    drain();
    check_int("frames drained after six byte", exp_data_q.size(), 0);

    // Decision latency
    t1_en = 1'b1;
    for (int i = 0; i < 6; i++) begin
      send_frame(i[0] ? Mac1 : Mac0, 40);
      drain();
    end
    t1_en = 1'b0;

    // Sustained throughput
    send_frame(Mac0, 400);
    idle(20);
    t2_en = 1'b1;
    drain();
    t2_en = 1'b0;

    // Random under stress
    gap_en = 1'b1;
    stall_en = 1'b1;
    for (int i = 0; i < 200; i++) begin
      int len;
      logic [47:0] dst;
      len = 1 + ($urandom % 70);
      case ($urandom % 4)
        0: dst = Mac0;
        1: dst = Mac1;
        2: dst = {(32)'($urandom), (16)'($urandom)};
        default: dst = Mac0 ^ (48'h1 << ($urandom % 48));
      endcase
      send_frame(dst, len);
    end
    drain();
    gap_en   = 1'b0;
    stall_en = 1'b0;
    drain();
    check_int("frames drained after random", exp_data_q.size(), 0);
    check_int("drop count after random", int'(drop_cnt), exp_drops);
    check_int("beats out", rcvd, exp_beats);

    // Mid frame reset
    send_frame(Mac1, 60);
    idle(3);
    do_reset();
    send_frame(Mac0, 60);
    drain();
    check_int("frames drained after reset", exp_data_q.size(), 0);
    check_int("drop count after reset", int'(drop_cnt), exp_drops);
    check_int("beats out after reset", rcvd, exp_beats);

    do_verdict();
  end

  // Watchdog
  initial begin
    #500_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

  // Reference model
  always @(posedge clk) begin
    if (!rst_n) begin
      reg_m_tvalid <= 1'b0;
      reg_m_tdata  <= '0;
      reg_m_tlast  <= 1'b0;
      reg_m_tdest  <= '0;
      reg_m_xfer   <= 1'b0;
    end else begin
      reg_m_tvalid <= m_tvalid;
      reg_m_tdata  <= m_tdata;
      reg_m_tlast  <= m_tlast;
      reg_m_tdest  <= m_tdest;
      reg_m_xfer   <= m_tvalid && m_tready;
    end
  end

  // Compare against DUT
  always @(negedge clk) begin
    if (rst_n && m_tvalid && m_tready) begin
      if (exp_data_q.size() == 0) begin
        checks++;
        errors++;
        $error("t=%0t forwarded a beat of a frame that had to be dropped", $time);
      end else begin
        check_data("forwarded byte", m_tdata, exp_data_q.pop_front());
        check_bit("tlast on the frame final byte", m_tlast, exp_last_q.pop_front());
        check_dest("tdest from the matched entry", m_tdest, exp_dest_q.pop_front());
      end
      rcvd++;
    end
  end

  always @(negedge clk) begin
    if (reg_m_tvalid && !reg_m_xfer) begin
      check_bit("m_tvalid held while stalled", m_tvalid, 1'b1);
      check_data("m_tdata held while stalled", m_tdata, reg_m_tdata);
      check_bit("m_tlast held while stalled", m_tlast, reg_m_tlast);
      check_dest("m_tdest held while stalled", m_tdest, reg_m_tdest);
    end
  end

  // Decision latency
  always @(negedge clk) begin
    if (!rst_n) in_idx = 0;
    else begin
      if (t1_en) begin
        if (s_tvalid && s_tready && in_idx == 5) hdr_cyc = cyc;
        if (m_tvalid && m_tready && hdr_cyc >= 0) begin
          check_le("first output beat after the sixth byte", cyc - hdr_cyc, 2);
          hdr_cyc = -1;
        end
      end
      if (s_tvalid && s_tready) in_idx = s_tlast ? 0 : in_idx + 1;
    end
  end

  // No output bubble
  always @(negedge clk) begin
    if (rst_n && t2_en && out_open) check_bit("output sustained mid frame", m_tvalid, 1'b1);
  end

endmodule

`default_nettype wire
