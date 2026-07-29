module credit_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             rx_valid,
    input  logic [WIDTH-1:0] rx_data,
    input  logic             dst_ready,
    output logic             dst_valid,
    output logic [WIDTH-1:0] dst_data,
    output logic             credit_return
);

  logic             rd_en;
  logic [WIDTH-1:0] rd_data;
  logic             full;
  logic             empty;
  logic             out_valid;

  sync_fifo #(
      .WIDTH(WIDTH),
      .DEPTH(DEPTH)
  ) u_fifo (
      .clk(clk),
      .rst_n(rst_n),
      .wr_en(rx_valid),
      .rd_en(rd_en),
      .wr_data(rx_data),
      .rd_data(rd_data),
      .full(full),
      .empty(empty)
  );

  // Registered read to same cycle valid
  assign rd_en = !empty && (!out_valid || dst_ready);

  always_ff @(posedge clk) begin
    if (!rst_n) out_valid <= 1'b0;
    else if (rd_en) out_valid <= 1'b1;
    else if (dst_ready) out_valid <= 1'b0;
  end

  assign dst_valid = out_valid;
  assign dst_data = rd_data;
  assign credit_return = dst_valid && dst_ready;

endmodule
