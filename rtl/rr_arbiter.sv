`default_nettype none

module rr_arbiter #(
    parameter int N = 4
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [N-1:0] req,         // Request
    input  logic         hold,
    output logic [N-1:0] grant,
    output logic         grant_valid
);

  logic [N-1:0] mask;  // Everyone "above" the last winner
  logic [N-1:0] masked_req;
  logic [N-1:0] grant_masked;
  logic [N-1:0] grant_unmasked;
  logic [N-1:0] held_grant;
  logic [N-1:0] rr_grant;
  logic         holding;

  assign masked_req = req & mask;
  assign grant_masked = masked_req & (~masked_req + 1);  // Twos complement trick to get lowest bit
  assign grant_unmasked = req & (~req + 1);

  // Round robin rotation
  always_comb begin
    if (masked_req == '0) rr_grant = grant_unmasked;  // Overflow
    else rr_grant = grant_masked;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mask <= '1;  // See full request set
      holding <= 1'b0;
    end else begin
      if (|grant) mask <= ~(grant | (grant - 1));

      if (grant_valid) holding <= hold;
      if (!holding) held_grant <= rr_grant;
    end
  end

  // Grant result
  always_comb begin
    if (holding) grant = held_grant;
    else grant = rr_grant;
  end

  assign grant_valid = |grant;

`ifdef FORMAL

  localparam int MaxBurst = 8;
  localparam int MaxWait = N * MaxBurst;

  (* anyconst *) logic [$clog2(N)-1:0] f_port;
  logic [$clog2(MaxWait+1)-1:0] f_wait;
  logic [$clog2(MaxBurst+1)-1:0] f_burst;
  logic [N-1:0] completed;
  logic [N-1:0] f_released;
  logic f_past_valid = 1'b0;

  assign f_released = grant & {N{!hold}};

  always_ff @(posedge clk) f_past_valid <= 1'b1;

  initial assume (!rst_n);
  initial assume (f_wait == 0);
  initial assume (f_burst == 0);
  initial assume (completed == '0);

  // req waiting counter
  always_ff @(posedge clk) begin
    if (!rst_n || grant[f_port]) begin
      f_wait <= '0;
    end else if (req[f_port] && int'(f_wait) < MaxWait) begin
      f_wait <= f_wait + 1;
    end
  end

  // hold counter
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      f_burst <= '0;
    end else begin
      f_burst <= (hold && grant_valid) ? f_burst + 1 : '0;
    end
  end

  // Ensure all ports have won
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      completed <= '0;
    end else begin
      completed <= completed | grant;
    end
  end

  always_ff @(posedge clk) begin
    assume (int'(f_burst) < MaxBurst);

    // Requesters hold req until granted and released
    if (f_past_valid && $past(rst_n) && rst_n) begin
      assume ((($past(req) & ~$past(f_released)) & ~req) == '0);
    end
  end

  always_ff @(posedge clk) begin
    assert (int'(f_wait) < MaxWait);

    if (f_past_valid && $past(rst_n) && rst_n) begin
      // Held grant is stable
      if ($past(grant_valid) && $past(hold)) assert (grant == $past(grant));

      // Position survives idle cycles
      if (!$past(grant_valid)) assert (mask == $past(mask));
    end

    if (rst_n) begin
      assert ($onehot0(grant));
      assert ((grant & ~req) == '0);
      assert (grant_valid == |grant);
      assert ((~mask & (~mask + 1'b1)) == '0);  // Mask stays top aligned
      if (holding) assert (held_grant != '0);
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      cover (holding && (grant != rr_grant));
      cover ((masked_req == '0) && (rr_grant == grant_unmasked) && grant_valid);
      cover (completed == '1);
    end
  end

`endif

endmodule

`default_nettype wire
