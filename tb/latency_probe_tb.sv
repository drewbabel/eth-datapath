`timescale 1ns / 1ps
`default_nettype none

module latency_probe_tb;

  localparam int Depth = 8;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic rx_ctl = 1'b0;
  logic rx_last = 1'b0;
  logic tx_ctl = 1'b0;
  logic verdict_valid = 1'b0;
  logic verdict_drop = 1'b0;
  logic clear = 1'b0;
  logic snapshot = 1'b0;

  logic [31:0] stat_min;
  logic [31:0] stat_max;
  logic [31:0] stat_count;
  logic [31:0] stat_sum_lo;
  logic [31:0] stat_sum_hi;
  logic [31:0] stat_error;

  int pass_count = 0;
  int fail_count = 0;
  int cyc = 0;
  int exp_q[$];

  always #5 clk = ~clk;

  always_ff @(posedge clk) cyc <= cyc + 1;

  latency_probe #(
      .DEPTH(Depth)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .rx_ctl(rx_ctl),
      .rx_last(rx_last),
      .tx_ctl(tx_ctl),
      .verdict_valid(verdict_valid),
      .verdict_drop(verdict_drop),
      .clear(clear),
      .snapshot(snapshot),
      .stat_min(stat_min),
      .stat_max(stat_max),
      .stat_count(stat_count),
      .stat_sum_lo(stat_sum_lo),
      .stat_sum_hi(stat_sum_hi),
      .stat_error(stat_error)
  );

  task automatic check(input string name, input logic [31:0] got, input logic [31:0] want);
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

  task automatic do_clear();
    @(negedge clk);
    clear = 1'b1;
    @(negedge clk);
    clear = 1'b0;
    @(negedge clk);
    exp_q.delete();
  endtask  // Automatic

  task automatic do_snapshot();
    repeat (4) @(negedge clk);
    snapshot = 1'b1;
    @(negedge clk);
    snapshot = 1'b0;
    repeat (2) @(negedge clk);
  endtask  // Automatic

  // Drives one frame
  task automatic pair(input int lat);
    int t0;
    @(negedge clk);
    rx_ctl = 1'b1;
    t0 = cyc;
    repeat (4) @(negedge clk);
    rx_ctl = 1'b0;
    tx_ctl = 1'b1;
    verdict_valid = 1'b1;
    verdict_drop = 1'b0;
    @(negedge clk);
    verdict_valid = 1'b0;
    repeat (lat - 1) @(negedge clk);
    tx_ctl = 1'b0;
    exp_q.push_back(cyc - t0);
    repeat (4) @(negedge clk);
  endtask  // Automatic

  // Arrival only
  task automatic rx_only();
    @(negedge clk);
    rx_ctl = 1'b1;
    repeat (4) @(negedge clk);
    rx_ctl = 1'b0;
    repeat (4) @(negedge clk);
  endtask  // Automatic

  // Departure only
  task automatic tx_only();
    @(negedge clk);
    tx_ctl = 1'b1;
    repeat (4) @(negedge clk);
    tx_ctl = 1'b0;
    repeat (4) @(negedge clk);
  endtask  // Automatic

  task automatic check_wide(input string name, input logic [63:0] got, input logic [63:0] want);
    if (got === want) begin
      pass_count = pass_count + 1;
    end else begin
      fail_count = fail_count + 1;
      $display("FAIL %s got=%0d exp=%0d", name, got, want);
    end
  endtask  // Automatic

  task automatic do_discard();
    @(negedge clk);
    verdict_valid = 1'b1;
    verdict_drop = 1'b1;
    @(negedge clk);
    verdict_valid = 1'b0;
    verdict_drop = 1'b0;
    repeat (4) @(negedge clk);
  endtask  // Automatic

  task automatic check_stats(input string tag);
    logic [63:0] sum;
    logic [31:0] want_min;
    logic [31:0] want_max;
    logic [63:0] got_sum;
    sum = 0;
    want_min = 32'hFFFF_FFFF;
    want_max = 0;
    for (int i = 0; i < exp_q.size(); i++) begin
      sum = sum + 64'(exp_q[i]);
      if (32'(exp_q[i]) < want_min) want_min = 32'(exp_q[i]);
      if (32'(exp_q[i]) > want_max) want_max = 32'(exp_q[i]);
    end
    got_sum = {stat_sum_hi, stat_sum_lo};
    check({tag, " count"}, stat_count, 32'(exp_q.size()));
    check({tag, " min"}, stat_min, want_min);
    check({tag, " max"}, stat_max, want_max);
    check_wide({tag, " sum"}, got_sum, sum);
  endtask  // Automatic

  task automatic run_basic();
    do_clear();
    pair(20);
    do_snapshot();
    check_stats("one frame");
  endtask  // Automatic

  task automatic run_spread();
    do_clear();
    pair(12);
    pair(40);
    pair(25);
    pair(9);
    do_snapshot();
    check_stats("four frames");
    check("no errors", stat_error, 32'd0);
  endtask  // Automatic

  task automatic run_random();
    int lat;
    do_clear();
    for (int i = 0; i < 30; i++) begin
      lat = 5 + ($urandom_range(0, 200));
      pair(lat);
    end
    do_snapshot();
    check_stats("random frames");
    check("random clean", stat_error, 32'd0);
  endtask  // Automatic

  task automatic run_unpaired();
    do_clear();
    tx_only();
    tx_only();
    pair(15);
    do_snapshot();
    check("unpaired count", stat_count, 32'd1);
    check("unpaired errors", 32'(stat_error[31:16]), 32'd2);
    check("no overflow", 32'(stat_error[15:0]), 32'd0);
  endtask  // Automatic

  task automatic run_overflow();
    do_clear();
    for (int i = 0; i < Depth + 3; i++) rx_only();
    do_snapshot();
    check("overflow flagged", 32'(stat_error[15:0]), 32'd3);
    check("overflow no count", stat_count, 32'd0);
  endtask  // Automatic

  task automatic run_discard();
    do_clear();
    rx_only();
    do_discard();
    pair(25);
    do_snapshot();
    check_stats("after discard");
    check("discard clean", stat_error, 32'd0);
  endtask  // Automatic

  task automatic run_discard_burst();
    do_clear();
    rx_only();
    rx_only();
    rx_only();
    do_discard();
    do_discard();
    do_discard();
    pair(18);
    pair(31);
    do_snapshot();
    check_stats("burst discard");
  endtask  // Automatic

  task automatic run_inflight_discard();
    int t0;
    do_clear();
    @(negedge clk);
    rx_ctl = 1'b1;
    t0 = cyc;
    repeat (4) @(negedge clk);
    rx_ctl = 1'b0;
    verdict_valid = 1'b1;
    verdict_drop = 1'b0;
    @(negedge clk);
    verdict_valid = 1'b0;
    repeat (3) @(negedge clk);
    rx_ctl = 1'b1;
    repeat (4) @(negedge clk);
    rx_ctl = 1'b0;
    @(negedge clk);
    verdict_valid = 1'b1;
    verdict_drop = 1'b1;
    @(negedge clk);
    verdict_valid = 1'b0;
    verdict_drop = 1'b0;
    repeat (4) @(negedge clk);
    tx_ctl = 1'b1;
    repeat (6) @(negedge clk);
    tx_ctl = 1'b0;
    exp_q.push_back(cyc - t0);
    repeat (8) @(negedge clk);
    do_snapshot();
    check_stats("in-flight discard");
  endtask  // Automatic

  task automatic run_back_to_back();
    int t0;
    int t1;
    do_clear();
    @(negedge clk);
    rx_ctl = 1'b1;
    t0 = cyc;
    repeat (2) @(negedge clk);
    rx_last = 1'b1;
    @(negedge clk);
    rx_last = 1'b0;
    t1 = cyc;
    verdict_valid = 1'b1;
    verdict_drop = 1'b0;
    @(negedge clk);
    verdict_valid = 1'b0;
    repeat (2) @(negedge clk);
    rx_last = 1'b1;
    @(negedge clk);
    rx_ctl = 1'b0;
    rx_last = 1'b0;
    verdict_valid = 1'b1;
    verdict_drop = 1'b0;
    @(negedge clk);
    verdict_valid = 1'b0;
    tx_ctl = 1'b1;
    repeat (5) @(negedge clk);
    tx_ctl = 1'b0;
    exp_q.push_back(cyc - t0);
    repeat (4) @(negedge clk);
    tx_ctl = 1'b1;
    repeat (5) @(negedge clk);
    tx_ctl = 1'b0;
    exp_q.push_back(cyc - t1);
    repeat (6) @(negedge clk);
    do_snapshot();
    check_stats("back to back");
  endtask  // Automatic

  task automatic run_collision(input int off);
    int t0;
    do_clear();
    @(negedge clk);
    rx_ctl = 1'b1;
    t0 = cyc;
    repeat (4) @(negedge clk);
    rx_ctl = 1'b0;
    tx_ctl = 1'b1;
    verdict_valid = 1'b1;
    verdict_drop = 1'b0;
    @(negedge clk);
    verdict_valid = 1'b0;
    repeat (3) @(negedge clk);
    rx_ctl = 1'b1;
    repeat (4) @(negedge clk);
    rx_ctl = 1'b0;
    repeat (8) @(negedge clk);
    tx_ctl = 1'b0;
    exp_q.push_back(cyc - t0);
    repeat (off) @(negedge clk);
    verdict_valid = 1'b1;
    verdict_drop = 1'b1;
    @(negedge clk);
    verdict_valid = 1'b0;
    verdict_drop = 1'b0;
    repeat (8) @(negedge clk);
    pair(30);
    do_snapshot();
    check_stats($sformatf("collision %0d", off));
  endtask  // Automatic

  task automatic run_snapshot_held();
    do_clear();
    pair(30);
    @(negedge clk);
    snapshot = 1'b1;
    pair(44);
    pair(44);
    repeat (10) @(negedge clk);
    check("held snapshot count", stat_count, 32'd1);
    check("held snapshot max", stat_max, 32'(exp_q[0]));
    @(negedge clk);
    snapshot = 1'b0;
    repeat (2) @(negedge clk);
  endtask  // Automatic

  task automatic run_snapshot_holds();
    logic [31:0] frozen;
    do_clear();
    pair(30);
    do_snapshot();
    frozen = stat_count;
    pair(30);
    pair(30);
    repeat (10) @(negedge clk);
    check("snapshot frozen", stat_count, frozen);
    do_snapshot();
    check("snapshot moves", stat_count, 32'd3);
  endtask  // Automatic

  initial begin
    $dumpfile("latency_probe_tb.vcd");
    $dumpvars(0, latency_probe_tb);

    // Bring up
    do_reset();

    // Single frame
    run_basic();

    // Spread latencies
    run_spread();

    // Random latencies
    run_random();

    // Unpaired departures
    run_unpaired();

    // Queue overrun
    run_overflow();

    // Cancel one stamp
    run_discard();

    // Cancel three stamps
    run_discard_burst();

    // Same cycle collision
    run_inflight_discard();

    run_back_to_back();

    run_collision(1);
    run_collision(2);
    run_collision(3);

    // Held high
    run_snapshot_held();

    // Frozen readout
    run_snapshot_holds();

    $display("checks passed %0d failed %0d", pass_count, fail_count);
    if (fail_count == 0) $display("PASS");
    else $fatal(1, "FAIL");
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "FAIL timeout");
  end

endmodule

`default_nettype wire
