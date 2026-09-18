`timescale 1ns / 1ps
`default_nettype none

module frame_gen_tb;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic start = 1'b0;
  logic [10:0] frame_bytes = 11'd64;
  logic [31:0] frame_count = 32'd4;
  logic [ 7:0] gap_bytes = 8'd12;

  logic [7:0] m_tdata;
  logic       m_tvalid;
  logic       m_tlast;
  logic       m_tuser;
  logic       busy;
  logic [31:0] sent_count;

  int pass_count = 0;
  int fail_count = 0;

  int    beat_count = 0;
  int    frame_len[$];
  logic [7:0] frame_body[$];
  logic [7:0] captured[$];

  always #5 clk = ~clk;

  frame_gen dut (
      .clk(clk),
      .rst_n(rst_n),
      .start(start),
      .frame_bytes(frame_bytes),
      .frame_count(frame_count),
      .gap_bytes(gap_bytes),
      .m_tdata(m_tdata),
      .m_tvalid(m_tvalid),
      .m_tlast(m_tlast),
      .m_tuser(m_tuser),
      .busy(busy),
      .sent_count(sent_count)
  );

  // Collects every beat
  always @(posedge clk) begin
    if (rst_n && m_tvalid) begin
      captured.push_back(m_tdata);
      beat_count <= beat_count + 1;
      if (m_tlast) begin
        frame_len.push_back(captured.size());
        while (captured.size() > 0) frame_body.push_back(captured.pop_front());
      end
    end
  end

  task automatic check(input string name, input longint got, input longint want);
    if (got === want) begin
      pass_count = pass_count + 1;
    end else begin
      fail_count = fail_count + 1;
      $display("FAIL %s got=%0d exp=%0d", name, got, want);
    end
  endtask  // Automatic

  task automatic do_reset();
    rst_n = 1'b0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
  endtask  // Automatic

  task automatic run_burst(input int size, input int count, input int gap);
    int base;
    frame_bytes = 11'(size);
    frame_count = 32'(count);
    gap_bytes   = 8'(gap);
    frame_len.delete();
    frame_body.delete();
    captured.delete();
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    while (busy) @(negedge clk);
    repeat (4) @(negedge clk);

    check("frame count", 32'(frame_len.size()), 32'(count));
    check("sent count", sent_count, 32'(count));
    for (int f = 0; f < frame_len.size(); f++) begin
      check("frame length", 32'(frame_len[f]), 32'(size));
    end
    for (int f = 0; f < count; f++) begin
      base = f * size;
      check("dest high", 32'(frame_body[base]), 32'h02);
      check("dest low", 32'(frame_body[base+5]), 32'h00);
      check("src low", 32'(frame_body[base+11]), 32'h01);
      check("type high", 32'(frame_body[base+12]), 32'h88);
      check("type low", 32'(frame_body[base+13]), 32'hB5);
      check("seq byte", 32'(frame_body[base+17]), 32'(f));
      check("pad byte", 32'(frame_body[base+size-1]), 32'd0);
    end
  endtask  // Automatic

  task automatic run_gap();
    int gap_beats;
    frame_bytes = 11'd64;
    frame_count = 32'd2;
    gap_bytes   = 8'd20;
    beat_count  = 0;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    gap_beats = 0;
    while (busy) begin
      @(negedge clk);
      if (!m_tvalid) gap_beats = gap_beats + 1;
    end
    check("gap length", 32'(gap_beats), 32'd21);
  endtask  // Automatic

  task automatic run_period(input int size, input int gap);
    int   cyc;
    int   last;
    int   seen;
    int   period;
    frame_bytes = 11'(size);
    frame_count = 32'd4;
    gap_bytes   = 8'(gap);
    cyc         = 0;
    last        = 0;
    seen        = 0;
    period      = 0;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    while (busy) begin
      @(negedge clk);
      cyc = cyc + 1;
      if (m_tvalid && m_tlast) begin
        if (seen > 0) period = cyc - last;
        last = cyc;
        seen = seen + 1;
      end
    end
    check("frame period", 32'(period), 32'(size + gap));
  endtask  // Automatic

  task automatic run_held_start();
    frame_bytes = 11'd64;
    frame_count = 32'd3;
    gap_bytes   = 8'd12;
    @(negedge clk);
    start = 1'b1;
    repeat (600) @(negedge clk);
    start = 1'b0;
    repeat (8) @(negedge clk);
    check("held start done", 32'(busy), 32'd0);
    check("held start count", sent_count, 32'd3);
  endtask  // Automatic

  task automatic run_rejects();
    frame_bytes = 11'd8;
    frame_count = 32'd4;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    repeat (8) @(negedge clk);
    check("short rejected", 32'(busy), 32'd0);

    frame_bytes = 11'd64;
    frame_count = 32'd0;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    repeat (8) @(negedge clk);
    check("zero rejected", 32'(busy), 32'd0);
  endtask  // Automatic

  initial begin
    $dumpfile("frame_gen_tb.vcd");
    $dumpvars(0, frame_gen_tb);

    // Bring up
    do_reset();

    // Minimum frames
    run_burst(64, 4, 12);

    // Full frames
    run_burst(1514, 3, 12);

    // No gap
    run_burst(64, 5, 0);

    // Gap length
    run_gap();

    // Frame period
    run_period(64, 0);
    run_period(64, 12);
    run_period(1514, 1);

    // Start held high
    run_held_start();

    // Bad commands
    run_rejects();

    $display("checks passed %0d failed %0d", pass_count, fail_count);
    if (fail_count == 0) $display("PASS");
    else $display("FAIL");
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL timeout");
    $finish;
  end

endmodule

`default_nettype wire
