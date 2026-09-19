`default_nettype none

module voq #(
    parameter int WIDTH     = 9,
    parameter int N_OUT     = 2,
    parameter int DEST_W    = $clog2(N_OUT),
    parameter int DEPTH     = 2048,
    parameter int MAX_FRAME = 1518,
    parameter int QW        = WIDTH + 1
) (
    input  logic                         clk,
    input  logic                         rst_n,
    // Slave
    input  logic                         s_tvalid,
    output logic                         s_tready,
    input  logic [ WIDTH-1:0]            s_tdata,
    input  logic                         s_tlast,
    input  logic [DEST_W-1:0]            s_tdest,
    // Master
    output logic [ N_OUT-1:0]            m_tvalid,
    input  logic [ N_OUT-1:0]            m_tready,
    output logic [ N_OUT-1:0][WIDTH-1:0] m_tdata,
    output logic [ N_OUT-1:0]            m_tlast,
    // Status
    output logic [ N_OUT-1:0][     31:0] drop_cnt
);

  localparam int RoomMark = DEPTH - MAX_FRAME;
  localparam int CountW = $clog2(DEPTH + 1);

  logic [N_OUT-1:0]             q_wr_en;
  logic [N_OUT-1:0][    QW-1:0] q_wr_data;
  logic [N_OUT-1:0]             q_rd_en;
  logic [N_OUT-1:0][    QW-1:0] q_rd_data;
  logic [N_OUT-1:0]             q_full;
  logic [N_OUT-1:0]             q_empty;
  logic [N_OUT-1:0]             q_out_valid;
  logic [N_OUT-1:0][CountW-1:0] q_count;

  logic                         sof;
  logic                         room;
  logic                         refusing;
  logic                         dropping;

  // Queue per destination
  for (genvar d = 0; d < N_OUT; d++) begin : g_queue
    sync_fifo #(
        .WIDTH(QW),
        .DEPTH(DEPTH)
    ) u_fifo (
        .count(q_count[d]),
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(q_wr_en[d]),
        .wr_data(q_wr_data[d]),
        .rd_en(q_rd_en[d]),
        .rd_data(q_rd_data[d]),
        .full(q_full[d]),
        .empty(q_empty[d])
    );

    // Registered read
    assign q_rd_en[d] = !q_empty[d] && (!q_out_valid[d] || m_tready[d]);

    always_ff @(posedge clk) begin
      if (!rst_n) q_out_valid[d] <= 1'b0;
      else if (q_rd_en[d]) q_out_valid[d] <= 1'b1;
      else if (m_tready[d]) q_out_valid[d] <= 1'b0;
    end

    assign m_tvalid[d] = q_out_valid[d];
    assign {m_tlast[d], m_tdata[d]} = q_rd_data[d];
  end

  // Drops never stalls
  assign s_tready = 1'b1;

  // Whole frame fits
  assign room     = int'(q_count[s_tdest]) <= RoomMark;

  // Decided at start
  assign dropping = sof ? !room : refusing;

  // Frame boundary
  always_ff @(posedge clk) begin
    if (!rst_n) sof <= 1'b1;
    else if (s_tvalid) sof <= s_tlast;
  end

  // Refusal holds
  always_ff @(posedge clk) begin
    if (!rst_n) refusing <= 1'b0;
    else if (s_tvalid && sof) refusing <= !room;
  end

  // Destination decode
  always_comb begin
    q_wr_en = '0;
    if (s_tvalid && !dropping) q_wr_en[s_tdest] = 1'b1;
    for (int d = 0; d < N_OUT; d++) q_wr_data[d] = {s_tlast, s_tdata};
  end

  // Counted at tlast
  always_ff @(posedge clk) begin
    if (!rst_n) drop_cnt <= '0;
    else if (s_tvalid && s_tlast && dropping) drop_cnt[s_tdest] <= drop_cnt[s_tdest] + 1'b1;
  end

`ifdef FORMAL

  logic f_past_valid = 1'b0;

  always_ff @(posedge clk) f_past_valid <= 1'b1;

  localparam int BeatW = $clog2(MAX_FRAME + 1);

  logic [BeatW-1:0] f_beats;
  logic [DEST_W-1:0] f_pkt_dest;

  initial assume (!rst_n);

  always_ff @(posedge clk) begin
    if (!rst_n) f_beats <= '0;
    else if (s_tvalid) begin
      f_beats <= s_tlast ? '0 : f_beats + 1'b1;
      if (sof) f_pkt_dest <= s_tdest;
    end
  end

  // Source contract
  always @(posedge clk) begin
    if (!rst_n) assume (!s_tvalid);
    if (rst_n) begin
      assume (int'(f_beats) < MAX_FRAME);
      if (!sof && s_tvalid) assume (s_tdest == f_pkt_dest);
    end
    if (f_past_valid && !$past(rst_n)) assume (!s_tvalid);
    if (f_past_valid && $past(rst_n) && rst_n && $past(s_tvalid && !s_tready)) begin
      assume (s_tvalid);
      assume (s_tdata == $past(s_tdata));
      assume (s_tlast == $past(s_tlast));
      assume (s_tdest == $past(s_tdest));
    end
  end

  // Reservation holds
  for (genvar d = 0; d < N_OUT; d++) begin : g_fq
    always @(posedge clk) if (rst_n) assert (!(q_wr_en[d] && q_full[d]));
  end

  // NEXT property list

`endif

endmodule

`default_nettype wire
