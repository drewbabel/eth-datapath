`default_nettype none

module credit_link #(
    parameter int WIDTH   = 8,
    parameter int DEPTH   = 16,
    parameter int FWD_LAT = 2,
    parameter int RET_LAT = 2
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
  logic [          WIDTH-1:0] rx_data;
  logic                       credit_drain;
  logic                       credit_return;

  logic [          FWD_LAT:0] fwd_valid;
  logic [          RET_LAT:0] ret_credit;
  logic [          WIDTH-1:0] fwd_data      [FWD_LAT+1];

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

  logic [CntW-1:0] cnt_credits;
  logic [CntW-1:0] cnt_bytes;
  logic [CntW-1:0] cnt_beats;
  logic [CntW-1:0] cnt_returns;
  logic [CntW-1:0] cnt_total;

  assign cnt_credits = CntW'(f_credits);
  assign cnt_bytes   = CntW'(f_occupancy);
  assign cnt_beats   = CntW'($countones(fwd_valid));
  assign cnt_returns = CntW'($countones(ret_credit));
  assign cnt_total   = cnt_credits + cnt_bytes + cnt_beats + cnt_returns;

  always @(posedge clk) if (rst_n) assert (cnt_total == ($bits(cnt_total))'(DEPTH));

  always @(posedge clk) begin
    if (rst_n) begin
      cover (cnt_credits == 0);
      cover (cnt_bytes == DEPTH);
      cover (dst_valid && dst_ready);
      cover (fwd_valid[FWD_LAT] && ret_credit[RET_LAT]);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fwd_valid  <= '0;
      ret_credit <= '0;
      for (int i = 0; i <= FWD_LAT; i++) fwd_data[i] <= '0;
    end else begin
      fwd_valid[0]  <= tx_valid;
      fwd_data[0]   <= tx_data;
      ret_credit[0] <= credit_drain;

      // Shift registers
      for (int i = 1; i <= FWD_LAT; i++) begin
        fwd_valid[i] <= fwd_valid[i-1];
        fwd_data[i]  <= fwd_data[i-1];
      end
      for (int i = 1; i <= RET_LAT; i++) begin
        ret_credit[i] <= ret_credit[i-1];
      end
    end
  end

  assign rx_valid = fwd_valid[FWD_LAT];
  assign rx_data = fwd_data[FWD_LAT];
  assign credit_return = ret_credit[RET_LAT];

endmodule

`default_nettype wire
