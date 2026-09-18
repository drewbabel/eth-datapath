`default_nettype none

module latency_probe #(
    parameter int DEPTH = 16
) (
    input logic clk,
    input logic rst_n,

    // Pin envelopes
    input logic rx_ctl,
    input logic tx_ctl,

    // Per frame verdict
    input logic verdict_valid,
    input logic verdict_drop,

    // Host commands
    input logic clear,
    input logic snapshot,

    // Frozen results
    output logic [31:0] stat_min,
    output logic [31:0] stat_max,
    output logic [31:0] stat_count,
    output logic [31:0] stat_sum_lo,
    output logic [31:0] stat_sum_hi,
    output logic [31:0] stat_error
);

  // Ticks forever
  logic [31:0] now;

  always_ff @(posedge clk) begin
    if (!rst_n) now <= 32'd0;
    else now <= now + 32'd1;
  end

  (* ASYNC_REG = "TRUE" *) logic [2:0] rx_sync;
  (* ASYNC_REG = "TRUE" *) logic [2:0] tx_sync;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_sync <= 3'd0;
      tx_sync <= 3'd0;
    end else begin
      rx_sync <= {rx_sync[1:0], rx_ctl};
      tx_sync <= {tx_sync[1:0], tx_ctl};
    end
  end

  // First bit in
  logic rx_start;
  // Last bit out
  logic tx_done;

  assign rx_start = rx_sync[1] && !rx_sync[2];
  assign tx_done  = !tx_sync[1] && tx_sync[2];

  logic clear_q;
  logic snapshot_q;
  logic clear_pulse;
  logic snapshot_pulse;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      clear_q    <= 1'b0;
      snapshot_q <= 1'b0;
    end else begin
      clear_q    <= clear;
      snapshot_q <= snapshot;
    end
  end

  assign clear_pulse    = clear && !clear_q;
  assign snapshot_pulse = snapshot && !snapshot_q;

  logic        fifo_full;
  logic        fifo_empty;
  logic [31:0] fifo_out;
  logic        fifo_rst_n;
  logic        push;
  logic        pop;

  assign fifo_rst_n = rst_n && !clear_pulse;
  assign push = rx_start;

  // Retires in order
  localparam int VAw = $clog2(DEPTH);

  logic          v_mem    [DEPTH];
  logic [VAw:0]  v_wr_ptr;
  logic [VAw:0]  v_rd_ptr;
  logic          v_empty;
  logic          v_full;
  logic          v_head;
  logic          drop_pop;

  assign v_empty = v_wr_ptr == v_rd_ptr;
  assign v_full = (v_wr_ptr[VAw] != v_rd_ptr[VAw]) && (v_wr_ptr[VAw-1:0] == v_rd_ptr[VAw-1:0]);
  assign v_head = v_mem[v_rd_ptr[VAw-1:0]];

  assign drop_pop = !v_empty && v_head && !fifo_empty;
  assign pop = !v_empty && !v_head && tx_done && !fifo_empty;

  always_ff @(posedge clk) begin
    if (!fifo_rst_n) begin
      v_wr_ptr <= '0;
      v_rd_ptr <= '0;
    end else begin
      if (verdict_valid && !v_full) begin
        v_mem[v_wr_ptr[VAw-1:0]] <= verdict_drop;
        v_wr_ptr <= v_wr_ptr + 1'b1;
      end
      if (pop || drop_pop) v_rd_ptr <= v_rd_ptr + 1'b1;
    end
  end

  sync_fifo #(
      .WIDTH(32),
      .DEPTH(DEPTH)
  ) u_stamps (
      .clk(clk),
      .rst_n(fifo_rst_n),
      .wr_en(push),
      .rd_en(pop || drop_pop),
      .wr_data(now),
      .rd_data(fifo_out),
      .full(fifo_full),
      .empty(fifo_empty)
  );

  // Read lands late
  logic        pop_q;
  logic [31:0] tx_stamp;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pop_q    <= 1'b0;
      tx_stamp <= 32'd0;
    end else begin
      pop_q <= pop;
      if (tx_done) tx_stamp <= now;
    end
  end

  logic [31:0] delta;
  assign delta = tx_stamp - fifo_out;

  logic [31:0] acc_min;
  logic [31:0] acc_max;
  logic [31:0] acc_count;
  logic [63:0] acc_sum;
  logic [15:0] err_over;
  logic [15:0] err_unpaired;

  always_ff @(posedge clk) begin
    if (!rst_n || clear_pulse) begin
      acc_min      <= 32'hFFFF_FFFF;
      acc_max      <= 32'd0;
      acc_count    <= 32'd0;
      acc_sum      <= 64'd0;
      err_over     <= 16'd0;
      err_unpaired <= 16'd0;
    end else begin
      if (rx_start && fifo_full && err_over != 16'hFFFF) err_over <= err_over + 16'd1;
      if (tx_done && !pop && err_unpaired != 16'hFFFF) err_unpaired <= err_unpaired + 16'd1;
      if (pop_q) begin
        acc_count <= acc_count + 32'd1;
        acc_sum   <= acc_sum + {32'd0, delta};
        if (delta < acc_min) acc_min <= delta;
        if (delta > acc_max) acc_max <= delta;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stat_min    <= 32'd0;
      stat_max    <= 32'd0;
      stat_count  <= 32'd0;
      stat_sum_lo <= 32'd0;
      stat_sum_hi <= 32'd0;
      stat_error  <= 32'd0;
    end else if (snapshot_pulse) begin
      stat_min    <= acc_min;
      stat_max    <= acc_max;
      stat_count  <= acc_count;
      stat_sum_lo <= acc_sum[31:0];
      stat_sum_hi <= acc_sum[63:32];
      stat_error  <= {err_unpaired, err_over};
    end
  end

endmodule

`default_nettype wire
