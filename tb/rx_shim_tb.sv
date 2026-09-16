`default_nettype none

module rx_shim_tb ();

  int checks = 0;
  int errors = 0;

  localparam int NEntries = 2;
  localparam int DestW = 1;
  localparam logic [47:0] Mac0 = 48'h00_11_22_33_44_55;
  localparam logic [47:0] Mac1 = 48'h66_77_88_99_aa_bb;
  localparam logic [47:0] MacX = 48'hde_ad_be_ef_00_01;
  localparam logic [NEntries*48-1:0] MatchMac = {Mac1, Mac0};
  localparam logic [NEntries*DestW-1:0] MatchDest = {1'b1, 1'b0};

  logic clk = 1'b0;
  logic rst_n = 1'b0;

  logic rx_axis_tvalid = 1'b0;
  logic [7:0] rx_axis_tdata = '0;
  logic rx_axis_tlast = 1'b0;
  logic rx_axis_tuser = 1'b0;

  logic m_tvalid;
  logic m_tready = 1'b0;
  logic [8:0] m_tdata;
  logic m_tlast;
  logic [DestW-1:0] m_tdest;
  logic [31:0] overflow_cnt;
  logic [31:0] drop_cnt;

  // Reference model
  logic [7:0] exp_data_q[$];
  logic exp_last_q[$];
  logic [DestW-1:0] exp_dest_q[$];
  logic exp_user_q[$];
  int exp_drops = 0;
  logic stress = 1'b0;
  logic sm_capture = 1'b0;
  logic sm_check = 1'b0;
  logic [7:0] sm_exp_q[$];

  always #5 clk = ~clk;

  rx_shim #(
      .N_ENTRIES(NEntries),
      .DEST_W(DestW),
      .MATCH_MAC(MatchMac),
      .MATCH_DEST(MatchDest)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .rx_axis_tvalid(rx_axis_tvalid),
      .rx_axis_tdata(rx_axis_tdata),
      .rx_axis_tlast(rx_axis_tlast),
      .rx_axis_tuser(rx_axis_tuser),
      .m_tvalid(m_tvalid),
      .m_tready(m_tready),
      .m_tdata(m_tdata),
      .m_tlast(m_tlast),
      .m_tdest(m_tdest),
      .overflow_cnt(overflow_cnt),
      .drop_cnt(drop_cnt)
  );


  // Undersized stress copy
  localparam int SmallBuf = 64;
  localparam int SmallVerdict = 2;

  logic sm_m_tvalid;
  logic sm_m_tready = 1'b1;
  logic [8:0] sm_m_tdata;
  logic sm_m_tlast;
  logic [DestW-1:0] sm_m_tdest;
  logic [31:0] sm_overflow_cnt;
  logic [31:0] sm_drop_cnt;
  int sm_beats = 0;
  logic v_full_seen = 1'b0;
  logic v_absent_seen = 1'b0;

  rx_shim #(
      .N_ENTRIES(NEntries),
      .DEST_W(DestW),
      .MATCH_MAC(MatchMac),
      .MATCH_DEST(MatchDest),
      .BUF_DEPTH(SmallBuf),
      .VERDICT_DEPTH(SmallVerdict)
  ) dut_small (
      .clk(clk),
      .rst_n(rst_n),
      .rx_axis_tvalid(rx_axis_tvalid),
      .rx_axis_tdata(rx_axis_tdata),
      .rx_axis_tlast(rx_axis_tlast),
      .rx_axis_tuser(rx_axis_tuser),
      .m_tvalid(sm_m_tvalid),
      .m_tready(sm_m_tready),
      .m_tdata(sm_m_tdata),
      .m_tlast(sm_m_tlast),
      .m_tdest(sm_m_tdest),
      .overflow_cnt(sm_overflow_cnt),
      .drop_cnt(sm_drop_cnt)
  );

  always @(negedge clk) begin
    if (rst_n && sm_m_tvalid && sm_m_tready) begin
      sm_beats++;
      if (sm_check && sm_exp_q.size() != 0) begin
        check_data("undersized prefix", sm_m_tdata[7:0], sm_exp_q.pop_front());
      end
    end
  end


  always @(negedge clk) begin
    if (rst_n) begin
      if (dut.v_full || dut_small.v_full) v_full_seen <= 1'b1;
      if (m_tvalid && m_tready && m_tlast && dut.v_empty) v_absent_seen <= 1'b1;
    end
  end

  task automatic check_bit(string name, logic got, logic exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("FAIL %s: got %b exp %b at %0t", name, got, exp, $time);
    end
  endtask

  task automatic check_data(string name, logic [7:0] got, logic [7:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("FAIL %s: got %02h exp %02h at %0t", name, got, exp, $time);
    end
  endtask

  // Output checker
  always @(negedge clk) begin
    if (rst_n && !stress && m_tvalid && m_tready) begin
      if (exp_data_q.size() == 0) begin
        checks++;
        errors++;
        $display("FAIL unexpected output beat at %0t", $time);
      end else begin
        check_data("byte forwarded", m_tdata[7:0], exp_data_q.pop_front());
        check_bit("tlast aligned", m_tlast, exp_last_q.pop_front());
        check_bit("tdest correct", m_tdest[0], exp_dest_q.pop_front());
        if (m_tlast) check_bit("verdict at tlast", m_tdata[8], exp_user_q.pop_front());
        else void'(exp_user_q.pop_front());
      end
    end
  end

  // Frame driver
  task automatic send_frame(logic [47:0] dst, int payload, logic bad);
    logic [7:0] b;
    logic hit;
    logic [DestW-1:0] dest;
    int len;
    len  = 6 + payload;
    hit  = (dst == Mac0) || (dst == Mac1);
    dest = (dst == Mac1) ? 1'b1 : 1'b0;
    if (!hit && !stress) exp_drops++;
    for (int i = 0; i < len; i++) begin
      b = (i < 6) ? dst[47-i*8-:8] : 8'($urandom);
      @(posedge clk);
      rx_axis_tvalid <= 1'b1;
      rx_axis_tdata  <= b;
      rx_axis_tlast  <= (i == len - 1);
      rx_axis_tuser  <= (i == len - 1) ? bad : 1'b0;
      if (sm_capture) sm_exp_q.push_back(b);
      if (hit && !stress) begin
        exp_data_q.push_back(b);
        exp_last_q.push_back(i == len - 1);
        exp_dest_q.push_back(dest);
        exp_user_q.push_back(bad);
      end
    end
    @(posedge clk);
    rx_axis_tvalid <= 1'b0;
    rx_axis_tlast  <= 1'b0;
    rx_axis_tuser  <= 1'b0;
  endtask

  task automatic drain(int cycles);
    repeat (cycles) @(posedge clk);
  endtask

  task automatic random_frames(int count);
    int   pick;
    int   payload;
    logic bad;
    for (int f = 0; f < count; f++) begin
      pick    = $urandom_range(0, 2);
      payload = $urandom_range(4, 30);
      bad     = ($bits(bad))'($urandom);
      if (pick == 0) send_frame(Mac0, payload, bad);
      else if (pick == 1) send_frame(Mac1, payload, bad);
      else send_frame(MacX, payload, bad);
      drain($urandom_range(0, 6));
    end
  endtask

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, rx_shim_tb);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    m_tready = 1'b1;
    repeat (2) @(posedge clk);

    // Directed
    send_frame(Mac0, 20, 1'b0);
    drain(40);
    send_frame(Mac1, 20, 1'b1);
    drain(40);
    send_frame(MacX, 20, 1'b0);
    drain(40);
    send_frame(Mac0, 20, 1'b1);
    drain(40);

    // Back to back
    send_frame(Mac0, 10, 1'b1);
    send_frame(Mac1, 10, 1'b0);
    send_frame(MacX, 10, 1'b1);
    send_frame(Mac0, 10, 1'b0);
    drain(200);

    // Randomized stalls
    fork
      random_frames(24);
      begin
        forever begin
          @(posedge clk);
          m_tready <= ($bits(m_tready))'($urandom);
        end
      end
    join_any

    m_tready = 1'b1;
    drain(600);


    checks++;
    if (exp_data_q.size() != 0) begin
      errors++;
      $display("FAIL %0d beats never arrived", exp_data_q.size());
    end

    checks++;
    if (overflow_cnt != 0) begin
      errors++;
      $display("FAIL overflow_cnt %0d", overflow_cnt);
    end

    checks++;
    if (drop_cnt != 32'(exp_drops)) begin
      errors++;
      $display("FAIL drop_cnt got %0d exp %0d", drop_cnt, exp_drops);
    end

    // Overflow stress
    stress      = 1'b1;
    rst_n       = 1'b0;
    sm_m_tready = 1'b0;
    m_tready    = 1'b1;
    drain(4);
    rst_n = 1'b1;
    drain(2);

    sm_capture = 1'b1;
    send_frame(Mac0, 30, 1'b0);
    sm_capture = 1'b0;
    for (int f = 0; f < 6; f++) send_frame(Mac0, 30, 1'b0);
    drain(50);

    checks++;
    if (sm_overflow_cnt == 0) begin
      errors++;
      $display("FAIL undersized buffer never overflowed");
    end

    sm_check    = 1'b1;
    sm_m_tready = 1'b1;
    drain(400);
    sm_check = 1'b0;

    checks++;
    if (sm_beats == 0) begin
      errors++;
      $display("FAIL undersized copy forwarded nothing");
    end

    checks++;
    if (sm_exp_q.size() != 0) begin
      errors++;
      $display("FAIL undersized prefix lost, %0d bytes short", sm_exp_q.size());
    end

    // Runt burst
    for (int f = 0; f < 12; f++) send_frame(Mac1, 0, ($bits(stress))'($urandom));
    drain(300);

    checks++;
    if (v_full_seen) begin
      errors++;
      $display("FAIL verdict queue reached full");
    end

    checks++;
    if (v_absent_seen) begin
      errors++;
      $display("FAIL verdict absent at an output tlast");
    end

    if (errors == 0) $display("PASS rx_shim_tb: %0d checks", checks);
    else begin
      $display("FAIL rx_shim_tb: %0d errors of %0d checks", errors, checks);
      $fatal(1);
    end
    $finish;
  end

endmodule

`default_nettype wire
