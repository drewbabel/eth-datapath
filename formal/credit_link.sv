`default_nettype none

module credit_link #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             src_valid,
    input  logic [WIDTH-1:0] src_data,
    input  logic             dst_ready,
    output logic             src_ready,
    output logic             dst_valid,
    output logic [WIDTH-1:0] dst_data
);

  logic                       tx_valid;
  logic [          WIDTH-1:0] tx_data;
  logic                       rx_valid;
  logic                       credit_drain;
  logic                       credit_return;

  logic [$clog2(DEPTH+1)-1:0] f_credits;
  logic [  $clog2(DEPTH+1):0] f_occupancy;

  initial assume (!rst_n);

  credit_sender #(
      .WIDTH(WIDTH),
      .DEPTH(DEPTH)
  ) u_sender (
      .clk(clk),
      .rst_n(rst_n),
      .src_valid(src_valid),
      .src_data(src_data),
      .src_ready(src_ready),
      .tx_valid(tx_valid),
      .tx_data(tx_data),
      .credit_return(credit_return),
      .f_credits(f_credits)
  );

  credit_fifo #(
      .WIDTH(WIDTH),
      .DEPTH(DEPTH)
  ) u_fifo (
      .clk(clk),
      .rst_n(rst_n),
      .rx_valid(rx_valid),
      .rx_data(rx_data),
      .dst_ready(dst_ready),
      .dst_valid(dst_valid),
      .dst_data(dst_data),
      .credit_return(credit_drain),
      .f_occupancy(f_occupancy)
  );

  localparam int CntW = $clog2(DEPTH + 1) + 2;  // Headroom prevents wrap

  logic [CntW-1:0] fwd_inflight;
  logic [CntW-1:0] ret_inflight;

  (* anyseq *) logic fwd_deliver;
  (* anyseq *) logic ret_deliver;
  (* anyseq *) logic [WIDTH-1:0] rx_data;

  logic [CntW-1:0] cnt_credits;
  logic [CntW-1:0] cnt_bytes;
  logic [CntW-1:0] cnt_beats;
  logic [CntW-1:0] cnt_returns;
  logic [CntW-1:0] cnt_total;

  assign cnt_credits = CntW'(f_credits);
  assign cnt_bytes   = CntW'(f_occupancy);
  assign cnt_total   = cnt_credits + cnt_bytes + cnt_beats + cnt_returns;

  always @(posedge clk) if (rst_n) assert (cnt_total == ($bits(cnt_total))'(DEPTH));

  always @(posedge clk) begin
    if (rst_n) begin
      cover (cnt_credits == 0);
      cover (cnt_bytes == ($bits(cnt_bytes))'(DEPTH));
      cover (dst_valid && dst_ready);
    end
  end

  // Fwd Pipe
  always @(posedge clk) begin
    if (!rst_n) begin
      fwd_inflight <= 0;
    end else begin
      if (tx_valid) begin
        if (!rx_valid) fwd_inflight <= fwd_inflight + 1;
      end else if (rx_valid) fwd_inflight <= fwd_inflight - 1;
    end
  end

  // Return Pipe
  always @(posedge clk) begin
    if (!rst_n) begin
      ret_inflight <= 0;
    end else begin
      if (credit_drain) begin
        if (!credit_return) ret_inflight <= ret_inflight + 1;
      end else if (credit_return) ret_inflight <= ret_inflight - 1;
    end
  end

  assign cnt_beats = CntW'(fwd_inflight);
  assign rx_valid = fwd_deliver && !(fwd_inflight == 0);

  assign cnt_returns = CntW'(ret_inflight);
  assign credit_return = ret_deliver && !(ret_inflight == 0);

endmodule

`default_nettype wire
