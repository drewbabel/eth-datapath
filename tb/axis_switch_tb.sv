`default_nettype none

module axis_switch_harness #(
    parameter int WIDTH   = 8,
    parameter int NIN     = 2,
    parameter int NOUT    = 2,
    parameter int PKT_LEN = 4,
    parameter int FRAMES  = 8,
    parameter int QDEPTH  = 256,
    parameter int FLOOR   = 700
) (
    input  logic clk,
    input  logic rst_n,
    input  logic stall_en,
    output int   checks,
    output int   errors,
    output logic done
);

  localparam int SelW = $clog2(NOUT);

  logic [  NIN-1:0]             s_tvalid;
  logic [  NIN-1:0]             s_tready;
  logic [  NIN-1:0][WIDTH-1:0]  s_tdata;
  logic [  NIN-1:0]             s_tlast;
  logic [  NIN-1:0][ NOUT-1:0]  s_navail;
  logic [  NIN-1:0][ SelW-1:0]  s_sel;
  logic [  NIN-1:0]             s_sel_valid;
  logic [ NOUT-1:0]             m_tvalid;
  logic [ NOUT-1:0]             m_tready;
  logic [ NOUT-1:0][WIDTH-1:0]  m_tdata;
  logic [ NOUT-1:0]             m_tlast;

  // Source rings
  logic [WIDTH-1:0] q_data[NIN][NOUT][QDEPTH];
  logic             q_last[NIN][NOUT][QDEPTH];
  int               q_head[NIN][NOUT];
  int               q_tail[NIN][NOUT];

  int  sent_frames[NIN][NOUT];
  int  got_frames[NIN][NOUT];
  int  exp_seq[NIN][NOUT];
  int  mark[NIN][NOUT];
  int  beats_in[NOUT];
  int  src_in[NOUT];
  logic pkt_open[NOUT];
  logic [NOUT-1:0] ready_drv;
  int  total_sent = 0;
  int  total_got = 0;
  int  sel_i;
  logic stall_on = 1'b0;
  logic meas_on = 1'b0;
  int   meas_beats = 0;
  int   meas_cycles = 0;
  int   meas_add;
  logic [WIDTH-1:0] beat;
  int  src;
  int  dst;
  int  seq;

  assign m_tready = ready_drv;

  axis_switch #(
      .WIDTH(WIDTH),
      .N_IN (NIN),
      .N_OUT(NOUT),
      .SEL_W(SelW)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .s_tvalid(s_tvalid),
      .s_tready(s_tready),
      .s_tdata(s_tdata),
      .s_tlast(s_tlast),
      .s_navail(s_navail),
      .s_sel(s_sel),
      .s_sel_valid(s_sel_valid),
      .m_tvalid(m_tvalid),
      .m_tready(m_tready),
      .m_tdata(m_tdata),
      .m_tlast(m_tlast)
  );

  // Queue non empty
  for (genvar j = 0; j < NIN; j++) begin : g_avail
    for (genvar i = 0; i < NOUT; i++) begin : g_bit
      assign s_navail[j][i] = (q_head[j][i] != q_tail[j][i]);
    end
  end

  // Paired queue serves
  always_comb begin
    for (int j = 0; j < NIN; j++) begin
      sel_i = int'(s_sel[j]);
      s_tvalid[j] = s_sel_valid[j] && (q_head[j][sel_i] != q_tail[j][sel_i]);
      s_tdata[j]  = q_data[j][sel_i][q_head[j][sel_i]];
      s_tlast[j]  = q_last[j][sel_i][q_head[j][sel_i]];
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      for (int j = 0; j < NIN; j++) begin
        if (s_tvalid[j] && s_tready[j])
          q_head[j][int'(s_sel[j])] <= (q_head[j][int'(s_sel[j])] + 1) % QDEPTH;
      end
    end
  end

  // Backpressure driver
  always @(posedge clk) begin
    if (!rst_n) ready_drv <= '1;
    else if (stall_en || stall_on) ready_drv <= NOUT'($urandom);
    else ready_drv <= '1;
  end

  task automatic push_frame(int j, int i, int seq);
    for (int b = 0; b < PKT_LEN; b++) begin
      q_data[j][i][q_tail[j][i]] = WIDTH'((j << 6) | (i << 4) | (seq % 16));
      q_last[j][i][q_tail[j][i]] = (b == PKT_LEN - 1);
      q_tail[j][i] = (q_tail[j][i] + 1) % QDEPTH;
    end
    sent_frames[j][i]++;
    total_sent++;
  endtask

  task automatic load_all(int count);
    for (int j = 0; j < NIN; j++)
      for (int i = 0; i < NOUT; i++)
        for (int f = 0; f < count; f++) push_frame(j, i, sent_frames[j][i]);
  endtask

  task automatic fail(string msg);
    errors++;
    $display("FAIL %0dx%0d %s at %0t", NIN, NOUT, msg, $time);
  endtask

  // Output monitor
  always @(negedge clk) begin
    if (rst_n) begin
      for (int i = 0; i < NOUT; i++) begin
        if (m_tvalid[i] && m_tready[i]) begin
          beat = m_tdata[i];
          src  = int'(beat[7:6]);
          dst  = int'(beat[5:4]);
          seq  = int'(beat[3:0]);
          checks++;
          if (dst != i) fail($sformatf("beat routed to %0d wanted %0d", i, dst));
          if (!pkt_open[i]) begin
            pkt_open[i] = 1'b1;
            src_in[i]   = src;
            beats_in[i] = 0;
          end
          checks++;
          if (src != src_in[i]) fail($sformatf("output %0d mixed sources", i));
          checks++;
          if (seq != (exp_seq[src][i] % 16)) fail($sformatf("flow %0d to %0d out of order", src, i));
          beats_in[i]++;
          if (m_tlast[i]) begin
            checks++;
            if (beats_in[i] != PKT_LEN) fail($sformatf("output %0d frame length %0d", i, beats_in[i]));
            exp_seq[src][i]++;
            got_frames[src][i]++;
            total_got++;
            pkt_open[i] = 1'b0;
          end
        end
      end
    end
  end

  // Throughput window
  always @(posedge clk) begin
    if (rst_n && meas_on) begin
      meas_add = 0;
      for (int i = 0; i < NOUT; i++) if (m_tvalid[i] && m_tready[i]) meas_add = meas_add + 1;
      meas_beats  <= meas_beats + meas_add;
      meas_cycles <= meas_cycles + 1;
    end
  end

  task automatic mark_progress();
    for (int j = 0; j < NIN; j++) for (int i = 0; i < NOUT; i++) mark[j][i] = got_frames[j][i];
  endtask

  task automatic check_progress(string name);
    for (int j = 0; j < NIN; j++) begin
      for (int i = 0; i < NOUT; i++) begin
        checks++;
        if (got_frames[j][i] == mark[j][i]) fail($sformatf("%s flow %0d to %0d starved", name, j, i));
      end
    end
  endtask

  task automatic run_until_drained(int limit);
    int spent;
    spent = 0;
    while (total_got < total_sent && spent < limit) begin
      @(posedge clk);
      spent++;
    end
    checks++;
    if (total_got != total_sent)
      fail($sformatf("drained %0d of %0d frames", total_got, total_sent));
  endtask

  initial begin
    checks = 0;
    errors = 0;
    done   = 1'b0;
    for (int j = 0; j < NIN; j++) begin
      for (int i = 0; i < NOUT; i++) begin
        q_head[j][i] = 0;
        q_tail[j][i] = 0;
        sent_frames[j][i] = 0;
        got_frames[j][i] = 0;
        exp_seq[j][i] = 0;
        mark[j][i] = 0;
      end
    end
    for (int i = 0; i < NOUT; i++) pkt_open[i] = 1'b0;

    wait (rst_n);
    repeat (4) @(posedge clk);

    load_all(FRAMES);
    mark_progress();
    repeat (10 * NIN * NOUT * PKT_LEN) @(posedge clk);
    check_progress("full load");
    run_until_drained(200 * NIN * NOUT * PKT_LEN * FRAMES);

    load_all(40);
    meas_on = 1'b1;
    repeat (400) @(posedge clk);
    meas_on = 1'b0;
    $display("THROUGHPUT %0dx%0d %0d beats in %0d cycles per output %0d permille", NIN, NOUT,
             meas_beats, meas_cycles, (1000 * meas_beats) / (meas_cycles * NOUT));
    checks++;
    if ((1000 * meas_beats) / (meas_cycles * NOUT) < FLOOR)
      fail($sformatf("throughput %0d permille per output", (1000*meas_beats)/(meas_cycles*NOUT)));
    run_until_drained(400 * NIN * NOUT * PKT_LEN * 40);

    stall_on = 1'b1;
    load_all(FRAMES);
    mark_progress();
    repeat (40 * NIN * NOUT * PKT_LEN) @(posedge clk);
    check_progress("under backpressure");
    run_until_drained(400 * NIN * NOUT * PKT_LEN * FRAMES);
    stall_on = 1'b0;

    done = 1'b1;
  end

endmodule

module axis_switch_tb ();

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic stall_en = 1'b0;

  int   checks2;
  int   errors2;
  logic done2;
  int   checks4;
  int   errors4;
  logic done4;
  int   checks1;
  int   errors1;
  logic done1;

  always #5 clk = ~clk;

  axis_switch_harness #(
      .WIDTH(8),
      .NIN  (2),
      .NOUT (2)
  ) h2 (
      .clk(clk),
      .rst_n(rst_n),
      .stall_en(stall_en),
      .checks(checks2),
      .errors(errors2),
      .done(done2)
  );

  axis_switch_harness #(
      .WIDTH(8),
      .NIN  (4),
      .NOUT (4)
  ) h4 (
      .clk(clk),
      .rst_n(rst_n),
      .stall_en(stall_en),
      .checks(checks4),
      .errors(errors4),
      .done(done4)
  );

  axis_switch_harness #(
      .WIDTH(8),
      .NIN  (4),
      .NOUT (4),
      .PKT_LEN(1),
      .FLOOR(390)
  ) h1 (
      .clk(clk),
      .rst_n(rst_n),
      .stall_en(stall_en),
      .checks(checks1),
      .errors(errors1),
      .done(done1)
  );

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, axis_switch_tb.h2.dut);
    $dumpvars(0, axis_switch_tb.h4.dut);
    $dumpvars(0, axis_switch_tb.h1.dut);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    wait (done2 && done4 && done1);

    stall_en = 1'b1;
    repeat (2000) @(posedge clk);
    stall_en = 1'b0;
    repeat (2000) @(posedge clk);

    if (errors2 == 0 && errors4 == 0 && errors1 == 0)
      $display("PASS axis_switch_tb: %0d checks", checks2 + checks4 + checks1);
    else begin
      $display("FAIL axis_switch_tb: %0d errors of %0d checks", errors2 + errors4 + errors1,
               checks2 + checks4 + checks1);
      $fatal(1);
    end
    $finish;
  end

endmodule

`default_nettype wire
