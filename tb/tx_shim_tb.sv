`default_nettype none

module tx_shim_tb ();

  int checks = 0;
  int errors = 0;

  logic clk = 1'b0;

  logic s_tvalid = 1'b0;
  logic s_tready;
  logic [8:0] s_tdata = '0;
  logic s_tlast = 1'b0;

  logic [7:0] tx_axis_tdata;
  logic tx_axis_tvalid;
  logic tx_axis_tready = 1'b0;
  logic tx_axis_tlast;
  logic tx_axis_tuser;

  // Reference model
  logic [7:0] ref_tdata;
  logic ref_tvalid;
  logic ref_tlast;
  logic ref_tuser;
  logic ref_s_tready;

  always #5 clk = ~clk;

  tx_shim dut (
      .s_tvalid(s_tvalid),
      .s_tready(s_tready),
      .s_tdata(s_tdata),
      .s_tlast(s_tlast),
      .tx_axis_tdata(tx_axis_tdata),
      .tx_axis_tvalid(tx_axis_tvalid),
      .tx_axis_tready(tx_axis_tready),
      .tx_axis_tlast(tx_axis_tlast),
      .tx_axis_tuser(tx_axis_tuser)
  );

  // Contract not mirrored
  assign ref_tdata    = s_tdata[7:0];
  assign ref_tvalid   = s_tvalid;
  assign ref_tlast    = s_tlast;
  assign ref_tuser    = s_tlast ? s_tdata[8] : 1'b0;
  assign ref_s_tready = tx_axis_tready;

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

  always @(negedge clk) begin
    check_data("tdata passthrough", tx_axis_tdata, ref_tdata);
    check_bit("tvalid passthrough", tx_axis_tvalid, ref_tvalid);
    check_bit("tlast passthrough", tx_axis_tlast, ref_tlast);
    check_bit("tuser at tlast only", tx_axis_tuser, ref_tuser);
    check_bit("tready backward", s_tready, ref_s_tready);
  end

  task automatic drive_frame(int len, logic verdict);
    logic last;
    logic top;
    logic [7:0] byte_v;
    for (int i = 0; i < len; i++) begin
      last   = (i == len - 1);
      top    = last ? verdict : ($bits(top))'($urandom);
      byte_v = 8'($urandom);
      @(posedge clk);
      s_tvalid <= 1'b1;
      s_tlast  <= last;
      s_tdata  <= {top, byte_v};
      @(negedge clk);
      while (!s_tready) @(negedge clk);
    end
    @(posedge clk);
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
  endtask

  task automatic random_frames(int count);
    int len;
    logic bad;
    for (int f = 0; f < count; f++) begin
      len = $urandom_range(1, 12);
      bad = ($bits(bad))'($urandom);
      drive_frame(len, bad);
      repeat (2'($urandom)) @(posedge clk);
    end
  endtask

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, tx_shim_tb);

    tx_axis_tready = 1'b1;
    repeat (2) @(posedge clk);

    // Directed
    drive_frame(8, 1'b0);
    repeat (2) @(posedge clk);
    drive_frame(8, 1'b1);
    repeat (2) @(posedge clk);
    drive_frame(1, 1'b1);
    repeat (2) @(posedge clk);

    // Randomized stalls
    fork
      random_frames(20);
      begin
        forever begin
          @(posedge clk);
          tx_axis_tready <= ($bits(tx_axis_tready))'($urandom);
        end
      end
    join_any

    repeat (4) @(posedge clk);

    if (errors == 0) $display("PASS tx_shim_tb: %0d checks", checks);
    else begin
      $display("FAIL tx_shim_tb: %0d errors of %0d checks", errors, checks);
      $fatal(1);
    end
    $finish;
  end

endmodule

`default_nettype wire
