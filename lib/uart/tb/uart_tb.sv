module uart_tb ();

  localparam int ClkFreqHz = 100_000_000;
  localparam int BaudRate = 115_200;
  localparam int Oversample = 16;
  localparam int DataBits = 8;

  localparam int ClksPerBit = (ClkFreqHz + BaudRate / 2) / BaudRate;
  localparam int ClksPerOversample = (ClksPerBit + Oversample / 2) / Oversample;

  int checks = 0;
  int errors = 0;
  int frames_sent = 0;

  logic clk = 0;
  logic rst_n;

  logic [DataBits-1:0] tx_data;
  logic tx_valid;
  logic tx_ready;
  logic loop;
  logic [DataBits-1:0] rx_data;
  logic rx_valid;
  logic rx_error;

  always #5 clk = ~clk;

  uart #(
      .CLK_FREQ_HZ(ClkFreqHz),
      .BAUD_RATE  (BaudRate),
      .OVERSAMPLE (Oversample),
      .DATA_BITS  (DataBits)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .tx_data(tx_data),
      .tx_valid(tx_valid),
      .tx_ready(tx_ready),
      .tx_serial(loop),
      .rx_serial(loop),
      .rx_data(rx_data),
      .rx_valid(rx_valid),
      .rx_error(rx_error)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    tx_valid = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  endtask  // Automatic

  task automatic do_verdict();
    @(posedge clk);
    if (checks != frames_sent) begin
      $fatal(1, "TB UNDER-RAN: %0d checks, expected %0d", checks, frames_sent);
    end else if (errors == 0) begin
      $display("PASS: %0d checks, %0d mismatches", checks, errors);
    end else begin
      $fatal(1, "FAIL: %0d mismatches, %0d checks", errors, checks);
    end
    $finish;
  endtask  // Automatic

  task automatic send_byte(input logic [DataBits-1:0] data);
    @(posedge clk);
    tx_valid = 1'b1;
    tx_data  = data;
    frames_sent++;

    do @(posedge clk); while (!(tx_valid && tx_ready));  // The accept edge
    tx_valid <= 1'b0;

    @(posedge rx_valid, posedge rx_error);
    checks++;
    if (rx_valid) begin
      if (rx_data !== data) begin
        errors++;
        $error("t=%0t data mismatch: got=%b, exp=%b", $time, rx_data, data);
      end
    end else begin
      errors++;
      $error("t=%0t rx flags (valid) mismatch: got=%b, exp=%b", $time, rx_valid, data);
    end

  endtask  // Automatic

  // Watchdog
  initial begin
    #200_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, uart_tb);
    do_reset();

    send_byte(8'h00);
    send_byte(8'hFF);
    send_byte(8'hA5);
    send_byte(8'h5A);

    for (int i = 0; i < 100; i++) begin
      send_byte(8'($urandom));
    end

    do_verdict();
  end

endmodule
