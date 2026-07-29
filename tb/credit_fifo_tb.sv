module credit_fifo_tb ();

  int checks = 0;
  int errors = 0;

  localparam int Width = 8;
  localparam int Depth = 16;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic rx_valid = 1'b0;
  logic [Width-1:0] rx_data;
  logic dst_ready = 1'b0;
  logic dst_valid;
  logic [Width-1:0] dst_data;
  logic credit_return;

  logic stall_en = 1'b0;
  int outstanding = 0;
  logic [Width-1:0] byte_q[$];
  logic reg_dst_valid;
  logic [Width-1:0] reg_dst_data;
  logic reg_dst_ready;
  logic reg_xfer;
  int return_cnt = 0;
  int queue_cnt = 0;

  always #5 clk = ~clk;

  credit_fifo #(
      .WIDTH(Width),
      .DEPTH(Depth)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .rx_valid(rx_valid),
      .rx_data(rx_data),
      .dst_ready(dst_ready),
      .dst_valid(dst_valid),
      .dst_data(dst_data),
      .credit_return(credit_return)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    rx_valid = 1'b0;
    dst_ready = 1'b0;
    stall_en = 1'b0;
    outstanding = 0;
    byte_q = {};
    return_cnt = 0;
    queue_cnt = 0;
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

  // Stalls until a credit frees a slot
  task automatic send_byte(input logic [Width-1:0] data);
    while (outstanding >= Depth) @(posedge clk);
    rx_data = data;
    #1 rx_valid = 1'b1;
    byte_q.push_back(data);
    outstanding++;
    @(posedge clk);
    #1 rx_valid = 1'b0;
  endtask  // Automatic

  task automatic idle(input int cycles);
    repeat (cycles) @(posedge clk);
  endtask  // Automatic

  always @(posedge clk) begin
    if (rst_n && credit_return) outstanding--;
  end

  always @(posedge clk) begin
    if (!rst_n) dst_ready = 1'b0;
    else #1 dst_ready = stall_en ? 1'($urandom) : 1'b1;
  end

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, credit_fifo_tb);
    do_reset();

    // Drain path with no backpressure
    repeat (Depth + 5) send_byte((Width)'($urandom));
    idle(Depth + 5);

    // Same traffic against a stalling destination
    stall_en = 1'b1;
    repeat (4 * Depth) send_byte((Width)'($urandom));
    idle(4 * Depth);

    // Fill then drain
    stall_en = 1'b0;
    idle(2);
    stall_en = 1'b1;
    repeat (Depth) send_byte((Width)'($urandom));
    idle(4 * Depth);

    // Back to back writes with gaps
    repeat (2 * Depth) begin
      send_byte((Width)'($urandom));
      idle($urandom % 3);
    end
    idle(4 * Depth);

    check_int("credit return count", return_cnt, queue_cnt);

    do_verdict();
  end

  // Watchdog
  initial begin
    #200_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

  // Reference model
  always @(posedge clk) begin
    if (!rst_n) begin
      reg_dst_valid <= 1'b0;
      reg_dst_data  <= '0;
      reg_xfer      <= 1'b0;
    end else begin
      reg_dst_valid <= dst_valid;
      reg_dst_data  <= dst_data;
      reg_xfer      <= dst_valid && dst_ready;
    end
  end

  // Compare against DUT
  always @(negedge clk) begin
    if (rst_n && dst_valid && dst_ready) begin
      check_data("data", dst_data, byte_q.pop_front());
      queue_cnt++;
    end
    if (rst_n && credit_return) return_cnt++;
  end

  always @(negedge clk) begin
    if (reg_dst_valid && !reg_xfer) begin
      check_bit("dst_valid stable", dst_valid, 1'b1);
      check_data("dst_data stable", dst_data, reg_dst_data);
    end
  end

endmodule
