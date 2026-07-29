module credit_sender_tb ();

  int checks = 0;
  int errors = 0;

  localparam int Width = 8;
  localparam int Depth = 16;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic src_valid = 1'b0;
  logic [Width-1:0] src_data;
  logic src_ready;
  logic tx_valid;
  logic [Width-1:0] tx_data;
  logic credit_return = 1'b0;

  logic return_en = 1'b0;
  int in_flight = 0;

  always #5 clk = ~clk;

  credit_sender #(
      .WIDTH(Width),
      .DEPTH(Depth)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .src_valid(src_valid),
      .src_data(src_data),
      .src_ready(src_ready),
      .tx_valid(tx_valid),
      .tx_data(tx_data),
      .credit_return(credit_return)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    src_valid = 1'b0;
    credit_return = 1'b0;
    return_en = 1'b0;
    in_flight = 0;
    @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
  endtask  // Automatic

  task automatic do_verdict();
    @(posedge clk);
    if (errors == 0) begin
      $display("PASSED: %0d checks", checks);
    end else begin
      $display("FAILED: %0d checks, %0d errors", checks, errors);
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

  // Holds src_valid until the beat is accepted
  task automatic send_byte(input logic [Width-1:0] data);
    #1 src_valid = 1'b1;
    src_data = data;
    @(posedge clk);
    while (!src_ready) @(posedge clk);
    #1 src_valid = 1'b0;
  endtask  // Automatic

  task automatic idle(input int cycles);
    repeat (cycles) @(posedge clk);
  endtask  // Automatic

  always @(posedge clk) begin
    if (!rst_n) in_flight = 0;
    else begin
      if (tx_valid) in_flight++;
      if (credit_return) in_flight--;
    end
  end

  always @(negedge clk) begin
    if (!rst_n) credit_return = 1'b0;
    else credit_return = return_en && (in_flight > 0) && 1'($urandom);
  end

  always @(negedge clk) begin
    checks++;
    if (in_flight > Depth) begin
      errors++;
      $error("t=%0t in_flight > Depth: in_flight=%0d, Depth=%0d", $time, in_flight, Depth);
    end else if (!src_ready && (in_flight !== Depth)) begin
      errors++;
      $error("t=%0t src_ready mismatch: got=%b, exp=%b", $time, src_ready, 1'b1);
    end
  end

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, credit_sender_tb);
    do_reset();

    // Spend every credit
    repeat (Depth) send_byte((Width)'($urandom));
    idle(5);

    // Unblock the stalled source
    return_en = 1'b1;
    repeat (4 * Depth) send_byte((Width)'($urandom));
    idle(4 * Depth);

    // Dense returns against back to back sends
    repeat (8 * Depth) send_byte((Width)'($urandom));

    // Drain, then refill
    return_en = 1'b0;
    idle(4 * Depth);
    return_en = 1'b1;
    idle(4 * Depth);
    return_en = 1'b0;
    repeat (Depth) send_byte((Width)'($urandom));

    // Gaps between sends
    return_en = 1'b1;
    repeat (4 * Depth) begin
      send_byte((Width)'($urandom));
      idle($urandom % 4);
    end
    idle(4 * Depth);

    do_verdict();
  end

  // Watchdog
  initial begin
    #200_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

endmodule
