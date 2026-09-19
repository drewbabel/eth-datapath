`default_nettype none

module voq_tb ();

  int checks = 0;
  int errors = 0;

  localparam int Width = 9;
  localparam int NOut = 2;
  localparam int DestW = 1;
  localparam int Depth = 64;
  localparam int MaxFrame = 32;

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic s_tvalid = 1'b0;
  logic s_tready;
  logic [Width-1:0] s_tdata = '0;
  logic s_tlast = 1'b0;
  logic [DestW-1:0] s_tdest = '0;

  logic [NOut-1:0] m_tvalid;
  logic [NOut-1:0] m_tready = '1;
  logic [NOut-1:0][Width-1:0] m_tdata;
  logic [NOut-1:0] m_tlast;
  logic [NOut-1:0][31:0] drop_cnt;

  localparam int NOut4 = 4;
  localparam int DestW4 = 2;

  logic d4_tvalid = 1'b0;
  logic [Width-1:0] d4_tdata = '0;
  logic d4_tlast = 1'b0;
  logic [DestW4-1:0] d4_tdest = '0;
  logic [NOut4-1:0] d4_m_tvalid;
  logic [NOut4-1:0][Width-1:0] d4_m_tdata;
  logic [NOut4-1:0] d4_m_tlast;
  logic [NOut4-1:0][31:0] d4_drop;
  int d4_beats[NOut4];

  // Contract model
  logic [Width-1:0] sent0[$];
  logic [Width-1:0] sent1[$];
  int sent_len0[$];
  int sent_len1[$];
  logic [Width-1:0] obs0[$];
  logic [Width-1:0] obs1[$];
  int exp_drop0 = 0;
  int exp_drop1 = 0;
  int out_frames0 = 0;
  int out_frames1 = 0;
  logic ready_low_seen = 1'b0;
  logic both_moved_seen = 1'b0;
  logic stall_en = 1'b0;
  int max_seen0 = 0;
  int max_seen1 = 0;

  always #5 clk = ~clk;

  voq #(
      .WIDTH(Width),
      .N_OUT(NOut),
      .DEST_W(DestW),
      .DEPTH(Depth),
      .MAX_FRAME(MaxFrame)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .s_tvalid(s_tvalid),
      .s_tready(s_tready),
      .s_tdata(s_tdata),
      .s_tlast(s_tlast),
      .s_tdest(s_tdest),
      .m_tvalid(m_tvalid),
      .m_tready(m_tready),
      .m_tdata(m_tdata),
      .m_tlast(m_tlast),
      .drop_cnt(drop_cnt)
  );

  voq #(
      .WIDTH(Width),
      .N_OUT(NOut4),
      .DEST_W(DestW4),
      .DEPTH(Depth),
      .MAX_FRAME(MaxFrame)
  ) dut4 (
      .clk(clk),
      .rst_n(rst_n),
      .s_tvalid(d4_tvalid),
      .s_tready(),
      .s_tdata(d4_tdata),
      .s_tlast(d4_tlast),
      .s_tdest(d4_tdest),
      .m_tvalid(d4_m_tvalid),
      .m_tready('1),
      .m_tdata(d4_m_tdata),
      .m_tlast(d4_m_tlast),
      .drop_cnt(d4_drop)
  );

  always @(negedge clk) begin
    if (rst_n) for (int d = 0; d < NOut4; d++) if (d4_m_tvalid[d]) d4_beats[d]++;
  end

  task automatic check_bit(string name, logic got, logic exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("FAIL %s: got %b exp %b at %0t", name, got, exp, $time);
    end
  endtask

  task automatic check_int(string name, int got, int exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("FAIL %s: got %0d exp %0d at %0t", name, got, exp, $time);
    end
  endtask

  // Never backpressures
  always @(negedge clk) begin
    if (rst_n && !s_tready) ready_low_seen <= 1'b1;
    if (rst_n && m_tvalid[0] && m_tready[0] && m_tvalid[1] && m_tready[1])
      both_moved_seen <= 1'b1;
  end

  // Frame driver
  task automatic send_frame(logic [DestW-1:0] dest, int len);
    logic [Width-1:0] b;
    for (int i = 0; i < len; i++) begin
      b = Width'($urandom);
      @(posedge clk);
      s_tvalid <= 1'b1;
      s_tdata  <= b;
      s_tlast  <= (i == len - 1);
      s_tdest  <= dest;
      if (dest == 1'b0) sent0.push_back(b);
      else sent1.push_back(b);
    end
    if (dest == 1'b0) sent_len0.push_back(len);
    else sent_len1.push_back(len);
    @(posedge clk);
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
  endtask

  task automatic drain(int cycles);
    repeat (cycles) @(posedge clk);
  endtask

  // Match or drop
  task automatic match_frame0();
    int len;
    logic same;
    logic [Width-1:0] want;
    forever begin
      if (sent_len0.size() == 0) begin
        checks++;
        errors++;
        $display("FAIL dest0 output with nothing sent at %0t", $time);
        obs0.delete();
        return;
      end
      len  = sent_len0[0];
      same = (len == obs0.size());
      if (same) begin
        for (int i = 0; i < len; i++) if (sent0[i] !== obs0[i]) same = 1'b0;
      end
      void'(sent_len0.pop_front());
      for (int i = 0; i < len; i++) void'(sent0.pop_front());
      if (same) begin
        checks++;
        out_frames0++;
        if (len > max_seen0) max_seen0 = len;
        obs0.delete();
        return;
      end
      exp_drop0++;
    end
  endtask

  task automatic match_frame1();
    int len;
    logic same;
    forever begin
      if (sent_len1.size() == 0) begin
        checks++;
        errors++;
        $display("FAIL dest1 output with nothing sent at %0t", $time);
        obs1.delete();
        return;
      end
      len  = sent_len1[0];
      same = (len == obs1.size());
      if (same) begin
        for (int i = 0; i < len; i++) if (sent1[i] !== obs1[i]) same = 1'b0;
      end
      void'(sent_len1.pop_front());
      for (int i = 0; i < len; i++) void'(sent1.pop_front());
      if (same) begin
        checks++;
        out_frames1++;
        if (len > max_seen1) max_seen1 = len;
        obs1.delete();
        return;
      end
      exp_drop1++;
    end
  endtask

  // Output monitors
  always @(negedge clk) begin
    if (rst_n && m_tvalid[0] && m_tready[0]) begin
      obs0.push_back(m_tdata[0]);
      if (m_tlast[0]) match_frame0();
    end
  end

  always @(negedge clk) begin
    if (rst_n && m_tvalid[1] && m_tready[1]) begin
      obs1.push_back(m_tdata[1]);
      if (m_tlast[1]) match_frame1();
    end
  end

  task automatic tail_drops();
    while (sent_len0.size() != 0) begin
      for (int i = 0; i < sent_len0[0]; i++) void'(sent0.pop_front());
      void'(sent_len0.pop_front());
      exp_drop0++;
    end
    while (sent_len1.size() != 0) begin
      for (int i = 0; i < sent_len1[0]; i++) void'(sent1.pop_front());
      void'(sent_len1.pop_front());
      exp_drop1++;
    end
  endtask

  task automatic four_dest_sweep();
    for (int d = 0; d < NOut4; d++) begin
      for (int i = 0; i < d + 4; i++) begin
        @(posedge clk);
        d4_tvalid <= 1'b1;
        d4_tdata  <= Width'($urandom);
        d4_tlast  <= (i == d + 3);
        d4_tdest  <= ($bits(d4_tdest))'(d);
      end
      @(posedge clk);
      d4_tvalid <= 1'b0;
      d4_tlast  <= 1'b0;
      drain(40);
    end
    drain(80);
  endtask

  task automatic random_traffic(int count);
    for (int f = 0; f < count; f++) begin
      send_frame(($bits(s_tdest))'($urandom), $urandom_range(1, MaxFrame));
      drain($urandom_range(0, 4));
    end
  endtask

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, voq_tb);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    check_int("drop counters clear", int'(drop_cnt[0]) + int'(drop_cnt[1]), 0);

    // Directed both
    send_frame(1'b0, 8);
    drain(30);
    send_frame(1'b1, 8);
    drain(30);
    check_int("no drops yet", int'(drop_cnt[0]) + int'(drop_cnt[1]), 0);

    // Back to back
    send_frame(1'b0, 12);
    send_frame(1'b1, 12);
    send_frame(1'b0, 12);
    drain(120);
    tail_drops();
    check_int("dest0 drops", int'(drop_cnt[0]), exp_drop0);
    check_int("dest1 drops", int'(drop_cnt[1]), exp_drop1);

    // Head of line
    m_tready[0] = 1'b0;
    out_frames1 = 0;
    for (int f = 0; f < 6; f++) begin
      send_frame(1'b0, MaxFrame);
      send_frame(1'b1, 4);
      drain(20);
    end
    drain(200);
    check_int("dest1 crossed a blocked dest0", out_frames1, 6);
    m_tready[0] = 1'b1;
    drain(400);
    tail_drops();
    check_int("dest0 drops after block", int'(drop_cnt[0]), exp_drop0);
    check_int("dest1 drops after block", int'(drop_cnt[1]), exp_drop1);

    // Randomized stalls
    stall_en = 1'b1;
    fork
      random_traffic(60);
      begin
        forever begin
          @(posedge clk);
          if (stall_en) m_tready <= ($bits(m_tready))'($urandom);
          else m_tready <= '1;
        end
      end
    join_any
    stall_en = 1'b0;
    m_tready = '1;
    drain(1500);
    tail_drops();
    check_int("dest0 drops randomized", int'(drop_cnt[0]), exp_drop0);
    check_int("dest1 drops randomized", int'(drop_cnt[1]), exp_drop1);

    check_bit("input never stalled", ready_low_seen, 1'b0);
    check_bit("both outputs moved together", both_moved_seen, 1'b1);

    checks++;
    if (max_seen0 > MaxFrame || max_seen1 > MaxFrame) begin
      errors++;
      $display("FAIL frame longer than MAX_FRAME emitted");
    end

    // Four destinations
    four_dest_sweep();
    for (int d = 0; d < NOut4; d++) begin
      check_int($sformatf("dest %0d beats", d), d4_beats[d], d + 4);
      check_int($sformatf("dest %0d drops", d), int'(d4_drop[d]), 0);
    end

    checks++;
    if (out_frames0 + out_frames1 == 0) begin
      errors++;
      $display("FAIL no frames forwarded");
    end

    checks++;
    if (int'(drop_cnt[0]) + int'(drop_cnt[1]) == 0) begin
      errors++;
      $display("FAIL never exercised a drop");
    end

    if (errors == 0) $display("PASS voq_tb: %0d checks", checks);
    else begin
      $display("FAIL voq_tb: %0d errors of %0d checks", errors, checks);
      $fatal(1);
    end
    $finish;
  end

endmodule

`default_nettype wire
