module uart_tx_tb ();

  int checks = 0;
  int errors = 0;
  int frames_sent = 0;

  localparam int ClkFreqHz = 100_000_000;
  localparam int BaudRate = 115_200;
  localparam int DataBits = 8;
  localparam int ClksPerBit = (ClkFreqHz + BaudRate / 2) / BaudRate;

  logic clk = 0;
  logic rst_n;
  logic [DataBits-1:0] tx_data;
  logic tx_valid;
  logic tx_ready;
  logic tx_serial;

  logic [DataBits+1:0] byte_q[$];

  always #5 clk = ~clk;

  uart_tx #(
      .CLK_FREQ_HZ(ClkFreqHz),
      .BAUD_RATE  (BaudRate),
      .DATA_BITS  (DataBits)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .tx_data(tx_data),
      .tx_valid(tx_valid),
      .tx_ready(tx_ready),
      .tx_serial(tx_serial)
  );

  task automatic do_reset();
    rst_n = 1'b0;
    tx_valid = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  endtask  // Automatic

  task automatic do_verdict();
    @(posedge clk);
    while (byte_q.size() != 0) @(posedge clk);
    if (checks < frames_sent * 2) begin  // Check_data + data_ready each fire once per frame
      $fatal(1, "TB UNDER-RAN: %0d checks, expected at least %0d", checks, frames_sent * 2);
    end else if (errors == 0) begin
      $display("PASS: %0d checks, %0d mismatches", checks, errors);
    end else begin
      $fatal(1, "FAIL: %0d mismatches, %0d checks", errors, checks);
    end
    $finish;
  endtask  // Automatic

  task automatic check_serial(input logic exp_serial);
    checks++;
    #1
      if (tx_serial !== exp_serial) begin
        errors++;
        $error("t=%0t serial mismatch: got=%b, exp=%b", $time, tx_serial, exp_serial);
      end
  endtask  // Automatic

  task automatic check_ready(input logic exp_ready);
    checks++;
    #1
      if (tx_ready !== exp_ready) begin
        errors++;
        $error("t=%0t ready mismatch: got=%b, exp=%b", $time, tx_ready, exp_ready);
      end
  endtask  // Automatic

  // Ready = low for whole frame, = high when core can accept
  task automatic data_ready();
    int low_clks;
    low_clks = 0;
    while (tx_ready) @(posedge clk);  // Wait for ready to fall (frame in progress)
    while (!tx_ready) begin  // Count clocks ready holds low
      @(posedge clk);
      low_clks++;
    end
    checks++;
    if (low_clks != ClksPerBit * (DataBits + 2) - 1) begin
      errors++;
      $error("t=%0t ready low %0d clks, expected %0d", $time, low_clks,
             ClksPerBit * (DataBits + 2) - 1);
    end
  endtask  // Automatic

  // Spawned on the accept. Sample each bit at its center relative to the accept
  task automatic check_data();
    logic [DataBits+1:0] got;
    logic [DataBits+1:0] exp;
    repeat (ClksPerBit / 2) @(posedge clk);

    for (int i = 0; i < (DataBits + 2); i++) begin
      got[i] = tx_serial;
      repeat (ClksPerBit) @(posedge clk);
    end

    checks++;
    if (byte_q.size() == 0) begin
      errors++;
      $error("t=%0t byte_q is empty", $time);
    end else begin
      exp = byte_q.pop_front();
      if (got !== exp) begin
        errors++;
        $error("t=%0t data mismatch: got=%b, exp=%b", $time, got, exp);
      end
    end
  endtask  // Automatic

  task automatic send_data(input logic [DataBits-1:0] data, input logic back_to_back,
                           input logic check_latch);
    byte_q.push_back({1'b1, data, 1'b0});
    tx_data = data;

    wait (tx_ready);
    tx_valid = 1'b1;
    @(posedge clk);  // Accept: valid & ready both high here
    while (tx_ready) @(posedge clk);  // HOLD valid until ready falls: don't race the accept
    frames_sent++;

    if (check_latch) tx_data = 8'($urandom);

    if (!back_to_back) begin
      tx_valid = 1'b0;
      while (!tx_ready) @(posedge clk);  // Let  frame finish
    end
  endtask  // Automatic

  // Hold valid high and feed n bytes
  task automatic back_to_back_burst(input int n);
    logic [DataBits-1:0] b;
    wait (tx_ready);
    tx_valid = 1'b1;
    for (int k = 0; k < n; k++) begin
      b = 8'($urandom);
      tx_data = b;
      byte_q.push_back({1'b1, b, 1'b0});
      frames_sent++;
      while (!tx_ready) @(posedge clk);  // Wait for byte's accept window
      while (tx_ready) @(posedge clk);  // Wait for the frame to start
    end
    tx_valid = 1'b0;
  endtask  // Automatic

  // Every span between line transitions is a whole number of bit-periods
  task automatic check_timing();
    int   count;
    logic prev;

    do @(posedge clk); while (tx_serial);  // sample the start edge like any other edge
    prev  = 1'b0;
    count = 0;

    repeat (ClksPerBit * (DataBits + 2)) begin
      @(posedge clk);
      count++;
      if (tx_serial !== prev) begin
        checks++;
        if (count % ClksPerBit != 0) begin
          errors++;
          $error("t=%0t edge off the bit grid: %0d clks since last edge", $time,
                 count % ClksPerBit);
        end
        count = 0;
        prev  = tx_serial;
      end
    end
  endtask  // Automatic

  // Watchdog
  initial begin
    #200_000_000 $fatal(1, "TIMEOUT: sim exceeded max time");
  end

  // Stimulus
  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, uart_tx_tb);
    do_reset();

    #500;

    // Exhaustive value sweep (with and without latch scribble)
    for (int i = 0; i < 2; i++) begin
      for (int j = 0; j < (2 ** DataBits); j++) begin
        send_data(8'(j), 1'b0, 1'(i));
        repeat ($urandom_range(1, 20)) @(posedge clk);  // Randomized gap
      end
    end

    // No inter-frame idle
    back_to_back_burst(10);

    do_verdict();
  end

  always @(negedge clk) begin
    if (!rst_n) begin
      check_serial(1);
      check_ready(0);
    end
  end

  always @(posedge rst_n) begin
    check_ready(1);
  end

  // tx_serial idles high when no frame in progress
  always @(posedge clk)
    if (rst_n && tx_ready && !tx_valid) begin
      checks++;
      #1;
      if (tx_serial !== 1'b1) begin
        errors++;
        $error("t=%0t tx_serial not idle-high: %b", $time, tx_serial);
      end
    end

  // Spawn concurrent instance of each monitor per frame (allows overlapping frames)
  always @(posedge clk) begin
    if (rst_n && tx_valid && tx_ready) begin
      fork
        check_data();
        check_timing();
        data_ready();
      join_none
    end
  end

endmodule
