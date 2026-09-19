`default_nettype none

module axis_switch_tb ();

  int checks = 0;
  int errors = 0;

  localparam int Width = 8;
  localparam int NIn = 2;
  localparam int NOut = 2;
  localparam int PktLen = 4;
  localparam int QDepth = 1024;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic [NIn-1:0][NOut-1:0] s_tvalid;
  logic [NIn-1:0][NOut-1:0] s_tready;
  logic [NIn-1:0][NOut-1:0][Width-1:0] s_tdata;
  logic [NIn-1:0][NOut-1:0] s_tlast;
  logic [NOut-1:0] m_tvalid;
  logic [NOut-1:0] m_tready = '0;
  logic [NOut-1:0][Width-1:0] m_tdata;
  logic [NOut-1:0] m_tlast;

  // Stream drive shadows
  logic tv[NIn][NOut];
  logic tr[NIn][NOut];
  logic [Width-1:0] td[NIn][NOut];
  logic tl[NIn][NOut];

  logic gap_en = 1'b0;
  logic stall_en = 1'b0;
  logic send_mask[NIn][NOut];
  logic s_taken[NIn][NOut];
  int beat[NIn][NOut];
  int seq[NIn][NOut];
  int sent = 0;
  int rcvd = 0;

  // Per flow rings
  logic [Width-1:0] q_data[NIn][NOut][QDepth];
  logic q_last[NIn][NOut][QDepth];
  int q_head[NIn][NOut];
  int q_tail[NIn][NOut];
  int got[NIn][NOut];
  int mark[NIn][NOut];

  logic pkt_open[NOut];
  int cur_src[NOut];

  logic [NOut-1:0] reg_m_tvalid;
  logic [NOut-1:0][Width-1:0] reg_m_tdata;
  logic [NOut-1:0] reg_m_tlast;
  logic [NOut-1:0] reg_m_xfer;

  always #5 clk = ~clk;

  for (genvar j = 0; j < NIn; j++) begin : g_bind
    for (genvar i = 0; i < NOut; i++) begin : g_stream
      assign s_tvalid[j][i] = tv[j][i];
      assign s_tdata[j][i]  = td[j][i];
      assign s_tlast[j][i]  = tl[j][i];
      assign tr[j][i]       = s_tready[j][i];
    end
  end

  axis_switch #(
      .WIDTH(Width),
      .N_IN (NIn),
      .N_OUT(NOut)
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

  task automatic mark_progress();
    for (int j = 0; j < NIn; j++) for (int i = 0; i < NOut; i++) mark[j][i] = got[j][i];
  endtask  // Automatic

  task automatic check_progress(input string name);
    for (int j = 0; j < NIn; j++) begin
      for (int i = 0; i < NOut; i++) begin
        if (send_mask[j][i]) begin
          checks++;
          if (got[j][i] == mark[j][i]) begin
            errors++;
            $error("%s flow %0d to %0d stalled out", name, j, i);
          end
        end
      end
    end
  endtask  // Automatic

  task automatic set_mask(input logic all_on, input int only_dest);
    for (int j = 0; j < NIn; j++) begin
      for (int i = 0; i < NOut; i++) begin
        send_mask[j][i] = all_on || (i == only_dest);
      end
    end
  endtask  // Automatic

  task automatic do_reset();
    rst_n = 1'b0;
    m_tready = '0;
    gap_en = 1'b0;
    stall_en = 1'b0;
    sent = 0;
    rcvd = 0;
    for (int i = 0; i < NOut; i++) begin
      pkt_open[i] = 1'b0;
      cur_src[i]  = 0;
    end
    for (int j = 0; j < NIn; j++) begin
      for (int i = 0; i < NOut; i++) begin
        send_mask[j][i] = 1'b0;
        s_taken[j][i]   = 1'b0;
        tv[j][i]        = 1'b0;
        td[j][i]        = '0;
        tl[j][i]        = 1'b0;
        beat[j][i]      = 0;
        seq[j][i]       = 0;
        q_head[j][i]    = 0;
        q_tail[j][i]    = 0;
        got[j][i]       = 0;
      end
    end
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

  task automatic check_bit(input string name, input logic got_v, input logic exp);
    checks++;
    if (got_v !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%b exp=%b", $time, name, got_v, exp);
    end
  endtask  // Automatic

  task automatic check_int(input string name, input int got_v, input int exp);
    checks++;
    if (got_v !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%0d exp=%0d", $time, name, got_v, exp);
    end
  endtask  // Automatic

  task automatic check_data(input string name, input logic [Width-1:0] got_v,
                            input logic [Width-1:0] exp);
    checks++;
    if (got_v !== exp) begin
      errors++;
      $error("t=%0t %s mismatch: got=%h exp=%h", $time, name, got_v, exp);
    end
  endtask  // Automatic

  task automatic idle(input int cycles);
    repeat (cycles) @(posedge clk);
  endtask  // Automatic

  // Hold until taken
  always @(posedge clk) begin
    if (!rst_n) begin
      for (int j = 0; j < NIn; j++) begin
        for (int i = 0; i < NOut; i++) begin
          tv[j][i] = 1'b0;
          td[j][i] = '0;
          tl[j][i] = 1'b0;
        end
      end
    end else begin
      #1;
      for (int j = 0; j < NIn; j++) begin
        for (int i = 0; i < NOut; i++) begin
          if (!tv[j][i] || s_taken[j][i]) begin
            if (send_mask[j][i] && (!gap_en || 1'($urandom))) begin
              tv[j][i]   = 1'b1;
              td[j][i]   = {(1)'(j), (Width - 1)'(seq[j][i])};
              tl[j][i]   = (beat[j][i] == PktLen - 1);
              seq[j][i]  = seq[j][i] + 1;
              beat[j][i] = tl[j][i] ? 0 : beat[j][i] + 1;
            end else begin
              // Idle payload garbage
              tv[j][i] = 1'b0;
              td[j][i] = (Width)'($urandom);
              tl[j][i] = 1'($urandom);
            end
          end
        end
      end
    end
  end

  always @(posedge clk) begin
    if (!rst_n) m_tready = '0;
    else begin
      #1;
      for (int i = 0; i < NOut; i++) m_tready[i] = stall_en ? 1'($urandom) : 1'b1;
    end
  end

  // Enqueue per flow
  always @(posedge clk) begin
    for (int j = 0; j < NIn; j++) begin
      for (int i = 0; i < NOut; i++) begin
        s_taken[j][i] <= rst_n && tv[j][i] && tr[j][i];
        if (rst_n && tv[j][i] && tr[j][i]) begin
          q_data[j][i][q_tail[j][i]%QDepth] = td[j][i];
          q_last[j][i][q_tail[j][i]%QDepth] = tl[j][i];
          q_tail[j][i] = q_tail[j][i] + 1;
          sent = sent + 1;
        end
      end
    end
  end

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, axis_switch_tb);
    do_reset();

    // Free running
    set_mask(1'b1, 0);
    mark_progress();
    idle(100);
    check_progress("free");

    // Forced contention
    for (int d = 0; d < NOut; d++) begin
      set_mask(1'b0, d);
      mark_progress();
      idle(200);
      check_progress($sformatf("dest %0d only", d));
    end

    // Contention under backpressure
    stall_en = 1'b1;
    for (int d = 0; d < NOut; d++) begin
      set_mask(1'b0, d);
      mark_progress();
      idle(300);
      check_progress($sformatf("dest %0d stalled", d));
    end

    // Full grid
    set_mask(1'b1, 0);
    mark_progress();
    idle(400);
    check_progress("grid");

    // Source gaps
    gap_en = 1'b1;
    mark_progress();
    idle(400);
    check_progress("gaps");

    // Drain
    for (int j = 0; j < NIn; j++) for (int i = 0; i < NOut; i++) send_mask[j][i] = 1'b0;
    gap_en   = 1'b0;
    stall_en = 1'b0;
    idle(40);

    check_int("beats out", rcvd, sent);
    for (int j = 0; j < NIn; j++) begin
      for (int i = 0; i < NOut; i++) begin
        check_int($sformatf("flow %0d to %0d drained", j, i), q_tail[j][i] - q_head[j][i], 0);
        if (got[j][i] == 0) begin
          checks++;
          errors++;
          $error("flow %0d to %0d never carried a beat", j, i);
        end
      end
    end

    do_verdict();
  end

  // Watchdog
  initial begin
    #200_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

  // Reference model
  always @(posedge clk) begin
    if (!rst_n) begin
      reg_m_tvalid <= '0;
      reg_m_tdata  <= '0;
      reg_m_tlast  <= '0;
      reg_m_xfer   <= '0;
    end else begin
      reg_m_tvalid <= m_tvalid;
      reg_m_tdata  <= m_tdata;
      reg_m_tlast  <= m_tlast;
      for (int i = 0; i < NOut; i++) reg_m_xfer[i] <= m_tvalid[i] && m_tready[i];
    end
  end

  // Compare against DUT
  always @(negedge clk) begin
    int src;
    logic [Width-1:0] out_data;
    for (int i = 0; i < NOut; i++) begin
      if (rst_n && m_tvalid[i] && m_tready[i]) begin
        out_data = m_tdata[i];
        src = int'(out_data[Width-1]);
        if (q_head[src][i] == q_tail[src][i]) begin
          checks++;
          errors++;
          $error("t=%0t output %0d beat with nothing sent", $time, i);
        end else begin
          check_data($sformatf("out %0d tdata", i), m_tdata[i],
                     q_data[src][i][q_head[src][i]%QDepth]);
          check_bit($sformatf("out %0d tlast", i), m_tlast[i],
                    q_last[src][i][q_head[src][i]%QDepth]);
          q_head[src][i] = q_head[src][i] + 1;
        end
        if (pkt_open[i]) check_int($sformatf("out %0d packet source", i), src, cur_src[i]);
        else cur_src[i] = src;
        pkt_open[i] = !m_tlast[i];
        got[src][i] = got[src][i] + 1;
        rcvd = rcvd + 1;
      end
    end
  end

  always @(negedge clk) begin
    for (int i = 0; i < NOut; i++) begin
      if (reg_m_tvalid[i] && !reg_m_xfer[i]) begin
        check_bit($sformatf("out %0d tvalid stable", i), m_tvalid[i], 1'b1);
        check_data($sformatf("out %0d tdata stable", i), m_tdata[i], reg_m_tdata[i]);
        check_bit($sformatf("out %0d tlast stable", i), m_tlast[i], reg_m_tlast[i]);
      end
    end
  end

  // Input holds valid
  always @(negedge clk) begin
    for (int j = 0; j < NIn; j++) begin
      for (int i = 0; i < NOut; i++) begin
        if (rst_n && tv[j][i] && !tr[j][i]) begin
          check_bit($sformatf("in %0d to %0d holds valid", j, i), tv[j][i], 1'b1);
        end
      end
    end
  end

endmodule

`default_nettype wire
