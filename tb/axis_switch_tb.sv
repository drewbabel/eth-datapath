`default_nettype none

module axis_switch_tb ();

  int checks = 0;
  int errors = 0;

  localparam int Width = 8;
  localparam int NIn = 2;
  localparam int NOut = 2;
  localparam int DestW = $clog2(NOut);
  localparam int PktLen = 4;
  localparam int QDepth = 1024;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic [NIn-1:0] s_tvalid = '0;
  logic [NIn-1:0] s_tready;
  logic [NIn-1:0][Width-1:0] s_tdata;
  logic [NIn-1:0] s_tlast = '0;
  logic [NIn-1:0][DestW-1:0] s_tdest;
  logic [NOut-1:0] m_tvalid;
  logic [NOut-1:0] m_tready = '0;
  logic [NOut-1:0][Width-1:0] m_tdata;
  logic [NOut-1:0] m_tlast;

  logic send_en = 1'b0;
  logic gap_en = 1'b0;
  logic stall_en = 1'b0;
  logic same_dest_en = 1'b0;
  logic [NIn-1:0] s_taken = '0;
  int beat[NIn];
  int seq[NIn];
  logic [DestW-1:0] dest_cur[NIn];
  int sent = 0;
  int rcvd = 0;

  // Per flow rings
  logic [Width-1:0] q_data[NIn][NOut][QDepth];
  logic q_last[NIn][NOut][QDepth];
  int q_head[NIn][NOut];
  int q_tail[NIn][NOut];
  int got[NIn][NOut];

  logic pkt_open[NOut];
  int cur_src[NOut];

  logic [NOut-1:0] reg_m_tvalid;
  logic [NOut-1:0][Width-1:0] reg_m_tdata;
  logic [NOut-1:0] reg_m_tlast;
  logic [NOut-1:0] reg_m_xfer;

  always #5 clk = ~clk;

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
      .s_tdest(s_tdest),
      .m_tvalid(m_tvalid),
      .m_tready(m_tready),
      .m_tdata(m_tdata),
      .m_tlast(m_tlast)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    s_tvalid = '0;
    s_tlast = '0;
    m_tready = '0;
    send_en = 1'b0;
    gap_en = 1'b0;
    stall_en = 1'b0;
    same_dest_en = 1'b0;
    sent = 0;
    rcvd = 0;
    for (int j = 0; j < NIn; j++) begin
      beat[j] = 0;
      seq[j]  = 0;
    end
    for (int i = 0; i < NOut; i++) begin
      pkt_open[i] = 1'b0;
      cur_src[i]  = 0;
    end
    for (int j = 0; j < NIn; j++) begin
      for (int i = 0; i < NOut; i++) begin
        q_head[j][i] = 0;
        q_tail[j][i] = 0;
        got[j][i]    = 0;
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
  for (genvar j = 0; j < NIn; j++) begin : g_src
    always @(posedge clk) begin
      if (!rst_n) begin
        s_tvalid[j] = 1'b0;
        s_tdata[j]  = '0;
        s_tlast[j]  = 1'b0;
        s_tdest[j]  = '0;
      end else begin
        #1;
        if (!s_tvalid[j] || s_taken[j]) begin
          if (send_en && (!gap_en || 1'($urandom))) begin
            if (beat[j] == 0) dest_cur[j] = same_dest_en ? '0 : (DestW)'($urandom);
            s_tvalid[j] = 1'b1;
            s_tdest[j]  = dest_cur[j];
            s_tdata[j]  = {(1)'(j), (Width - 1)'(seq[j])};
            s_tlast[j]  = (beat[j] == PktLen - 1);
            seq[j]      = seq[j] + 1;
            beat[j]     = s_tlast[j] ? 0 : beat[j] + 1;
          end else begin
            // Idle payload garbage
            s_tvalid[j] = 1'b0;
            s_tdata[j]  = (Width)'($urandom);
            s_tlast[j]  = 1'($urandom);
            s_tdest[j]  = (DestW)'($urandom);
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
    int d;
    for (int j = 0; j < NIn; j++) begin
      s_taken[j] <= rst_n && s_tvalid[j] && s_tready[j];
      if (rst_n && s_tvalid[j] && s_tready[j]) begin
        d = int'(s_tdest[j]);
        q_data[j][d][q_tail[j][d]%QDepth] = s_tdata[j];
        q_last[j][d][q_tail[j][d]%QDepth] = s_tlast[j];
        q_tail[j][d] = q_tail[j][d] + 1;
        sent = sent + 1;
      end
    end
  end

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, axis_switch_tb);
    do_reset();

    // Free running
    send_en = 1'b1;
    idle(100);

    // Forced contention
    same_dest_en = 1'b1;
    idle(200);

    // Contention under backpressure
    stall_en = 1'b1;
    idle(300);

    // Random destinations
    same_dest_en = 1'b0;
    idle(400);

    // Source gaps
    gap_en = 1'b1;
    idle(400);

    // Drain
    send_en  = 1'b0;
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
      if (rst_n && s_tvalid[j] && !s_tready[j]) begin
        check_bit($sformatf("in %0d holds valid", j), s_tvalid[j], 1'b1);
      end
    end
  end

endmodule

`default_nettype wire
