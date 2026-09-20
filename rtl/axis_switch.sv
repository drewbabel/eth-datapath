`default_nettype none

module axis_switch #(
    parameter int WIDTH = 8,
    parameter int N_IN  = 2,
    parameter int N_OUT = 2,
    parameter int SEL_W = $clog2(N_OUT)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    // Slave
    input  logic [ N_IN-1:0]             s_tvalid,
    output logic [ N_IN-1:0]             s_tready,
    input  logic [ N_IN-1:0][WIDTH-1:0]  s_tdata,
    input  logic [ N_IN-1:0]             s_tlast,
    input  logic [ N_IN-1:0][N_OUT-1:0]  s_navail,
    output logic [ N_IN-1:0][SEL_W-1:0]  s_sel,
    output logic [ N_IN-1:0]             s_sel_valid,
    // Master
    output logic [N_OUT-1:0]             m_tvalid,
    input  logic [N_OUT-1:0]             m_tready,
    output logic [N_OUT-1:0][WIDTH-1:0]  m_tdata,
`ifdef FORMAL
    output logic [ N_IN-1:0]             f_in_busy,
    output logic [ N_IN-1:0][SEL_W-1:0]  f_in_out,
`endif
    output logic [N_OUT-1:0]             m_tlast
);

`ifdef FORMAL
  assign f_in_busy = in_busy;
  assign f_in_out  = in_out;
`endif

  logic [N_OUT-1:0][ N_IN-1:0] req;
  logic [N_OUT-1:0][ N_IN-1:0] gnt;
  logic [N_OUT-1:0]            gnt_valid;
  logic [N_OUT-1:0]            gnt_won;

  logic [ N_IN-1:0][N_OUT-1:0] gnt_in;
  logic [ N_IN-1:0][N_OUT-1:0] acc;
  logic [ N_IN-1:0]            acc_valid;
  logic [ N_IN-1:0][SEL_W-1:0] acc_sel;

  logic [ N_IN-1:0]            in_busy;
  logic [ N_IN-1:0][SEL_W-1:0] in_out;
  logic [N_OUT-1:0]            out_busy;
  logic [N_OUT-1:0][ N_IN-1:0] out_src;
  logic [ N_IN-1:0]            xfer_last;

  logic [N_OUT-1:0]            sk_tvalid;
  logic [N_OUT-1:0]            sk_tready;
  logic [N_OUT-1:0][WIDTH-1:0] sk_tdata;
  logic [N_OUT-1:0]            sk_tlast;

  // Pairing in force
  for (genvar i = 0; i < N_OUT; i++) begin : g_busy
    for (genvar j = 0; j < N_IN; j++) begin : g_src
      assign out_src[i][j] = in_busy[j] && (in_out[j] == SEL_W'(i));
    end
    assign out_busy[i] = |out_src[i];
  end

  // Unmatched only
  for (genvar i = 0; i < N_OUT; i++) begin : g_req
    for (genvar j = 0; j < N_IN; j++) begin : g_bit
      assign req[i][j] = s_navail[j][i] && !in_busy[j] && !out_busy[i];
    end
  end

  // Grant stage
  for (genvar i = 0; i < N_OUT; i++) begin : g_grant
    rr_arbiter #(
        .N(N_IN)
    ) u_arb (
        .clk(clk),
        .rst_n(rst_n),
        .req(req[i]),
        .hold(1'b0),
        .won(gnt_won[i]),
        .grant(gnt[i]),
        .grant_valid(gnt_valid[i])
    );

    logic [N_IN-1:0] acc_col;
    for (genvar j = 0; j < N_IN; j++) begin : g_col
      assign acc_col[j] = acc[j][i];
    end
    assign gnt_won[i] = |(gnt[i] & acc_col);
  end

  // Accept stage
  for (genvar j = 0; j < N_IN; j++) begin : g_accept
    for (genvar i = 0; i < N_OUT; i++) begin : g_row
      assign gnt_in[j][i] = gnt[i][j];
    end

    rr_arbiter #(
        .N(N_OUT)
    ) u_arb (
        .clk(clk),
        .rst_n(rst_n),
        .req(gnt_in[j]),
        .hold(1'b0),
        .won(1'b1),
        .grant(acc[j]),
        .grant_valid(acc_valid[j])
    );

    always_comb begin
      acc_sel[j] = '0;
      for (int i = 0; i < N_OUT; i++) if (acc[j][i]) acc_sel[j] = SEL_W'(i);
    end
  end

  // Pairing held
  for (genvar j = 0; j < N_IN; j++) begin : g_match
    assign xfer_last[j] = s_tvalid[j] && s_tready[j] && s_tlast[j];

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        in_busy[j] <= 1'b0;
        in_out[j]  <= '0;
      end else if (in_busy[j]) begin
        if (xfer_last[j]) in_busy[j] <= 1'b0;
      end else if (acc_valid[j]) begin
        in_busy[j] <= 1'b1;
        in_out[j]  <= acc_sel[j];
      end
    end

    assign s_sel[j] = in_out[j];
    assign s_sel_valid[j] = in_busy[j];
    assign s_tready[j] = in_busy[j] && sk_tready[in_out[j]];
  end

  // Exit per output
  for (genvar i = 0; i < N_OUT; i++) begin : g_out
    axis_skid #(
        .WIDTH(WIDTH)
    ) u_skid (
        .clk(clk),
        .rst_n(rst_n),
        .s_tvalid(sk_tvalid[i]),
        .s_tready(sk_tready[i]),
        .s_tdata(sk_tdata[i]),
        .s_tlast(sk_tlast[i]),
        .m_tvalid(m_tvalid[i]),
        .m_tready(m_tready[i]),
        .m_tdata(m_tdata[i]),
        .m_tlast(m_tlast[i])
    );

    always_comb begin
      sk_tvalid[i] = 1'b0;
      sk_tdata[i]  = '0;
      sk_tlast[i]  = 1'b0;
      for (int j = 0; j < N_IN; j++) begin
        sk_tvalid[i] |= out_src[i][j] && s_tvalid[j];
        sk_tdata[i] |= {WIDTH{out_src[i][j]}} & s_tdata[j];
        sk_tlast[i] |= out_src[i][j] && s_tlast[j];
      end
    end
  end

`ifdef FORMAL

  logic f_past_valid = 1'b0;

  always_ff @(posedge clk) f_past_valid <= 1'b1;

  // Environment bounds
  localparam int MaxPktBeats = 4;
  localparam int MaxSrcGap = 2;
  localparam int MaxReadyGap = 2;
  localparam int MaxOutWait = N_IN * MaxPktBeats * (MaxSrcGap + MaxReadyGap + 1);

  localparam int BeatW = $clog2(MaxPktBeats + 1);
  localparam int GapW = $clog2(MaxSrcGap + MaxReadyGap + 2);
  localparam int WaitW = $clog2(MaxOutWait + 1);

  initial assume (!rst_n);

  // Slave port contract
  for (genvar j = 0; j < N_IN; j++) begin : g_fin
    logic [WIDTH-1:0] f_data_in;
    logic [BeatW-1:0] f_beats;
    logic [ GapW-1:0] f_src_gap;

    assign f_data_in = s_tdata[j];

    always_ff @(posedge clk) begin
      if (!rst_n) f_beats <= '0;
      else if (s_tvalid[j] && s_tready[j]) f_beats <= s_tlast[j] ? '0 : f_beats + 1;
    end

    always_ff @(posedge clk) begin
      if (!rst_n || s_tvalid[j] || !in_busy[j]) f_src_gap <= '0;
      else f_src_gap <= f_src_gap + 1;
    end

    always @(posedge clk) begin
      if (!rst_n) assume (!s_tvalid[j]);
      if (rst_n) begin
        assume (!s_tvalid[j] || s_sel_valid[j]);
        assume (int'(f_beats) < MaxPktBeats);
        assume (int'(f_src_gap) < MaxSrcGap);
        assume (!s_sel_valid[j] || s_navail[j][s_sel[j]]);
      end
      if (f_past_valid) begin
        if (!$past(rst_n)) assume (!s_tvalid[j]);
        if ($past(rst_n) && rst_n && $past(s_tvalid[j] && !s_tready[j])) begin
          assume (s_tvalid[j]);
          assume (f_data_in == $past(f_data_in));
          assume (s_tlast[j] == $past(s_tlast[j]));
        end
      end
    end
  end

  // Master port contract
  for (genvar i = 0; i < N_OUT; i++) begin : g_fout
    logic [ GapW-1:0] f_ready_gap;
    logic [WaitW-1:0] f_wait;

    always_ff @(posedge clk) begin
      if (!rst_n || !(m_tvalid[i] && !m_tready[i])) f_ready_gap <= '0;
      else f_ready_gap <= f_ready_gap + 1;
    end

    always_ff @(posedge clk) begin
      if (!rst_n || (sk_tvalid[i] && sk_tready[i])) f_wait <= '0;
      else if (|req[i] && int'(f_wait) < MaxOutWait) f_wait <= f_wait + 1;
    end

    always @(posedge clk) begin
      if (rst_n) assume (int'(f_ready_gap) < MaxReadyGap);
    end
  end

  // Every pairing seen
  logic [N_IN-1:0][N_OUT-1:0] f_paired;

  always_ff @(posedge clk) begin
    if (!rst_n) f_paired <= '0;
    else f_paired <= f_paired | acc;
  end

  for (genvar i = 0; i < N_OUT; i++) begin : g_fsafe
    // Yosys mis-slices past
    logic [N_IN-1:0] f_req;
    logic [N_IN-1:0] f_gnt;
    logic            f_stick;

    assign f_req   = req[i];
    assign f_gnt   = gnt[i];
    assign f_stick = gnt_valid[i] && !gnt_won[i];

    always @(posedge clk) begin
      if (rst_n) begin
        assert ($onehot0(gnt[i]));
        assert ((gnt[i] & ~req[i]) == '0);
        assert ($onehot0(out_src[i]));
        assert (gnt_valid[i] == |gnt[i]);
      end
      if (f_past_valid && $past(rst_n) && rst_n) begin
        if ($past(f_stick) && (f_req == $past(f_req))) assert (f_gnt == $past(f_gnt));
      end
    end
  end

  for (genvar j = 0; j < N_IN; j++) begin : g_fmatch
    // Yosys mis-slices past
    logic [SEL_W-1:0] f_out;
    logic             f_hold;

    assign f_out  = in_out[j];
    assign f_hold = in_busy[j] && !xfer_last[j];

    always @(posedge clk) begin
      if (rst_n) begin
        assert ($onehot0(acc[j]));
        assert ((acc[j] & ~gnt_in[j]) == '0);
        assert (!acc_valid[j] || !in_busy[j]);
        assert (!s_tready[j] || in_busy[j]);
      end
      if (f_past_valid && $past(rst_n) && rst_n) begin
        if ($past(f_hold)) begin
          assert (in_busy[j]);
          assert (f_out == $past(f_out));
        end
      end
    end
  end

  for (genvar i = 0; i < N_OUT; i++) begin : g_fcov
    for (genvar j = 0; j < N_IN; j++) begin : g_pair
      always @(posedge clk) if (rst_n) cover (acc[j][i]);
    end
  end

  always @(posedge clk) if (rst_n) cover (f_paired == '1);

  // Requests hold until served
  localparam int MaxMatchWait = N_IN * N_OUT * MaxPktBeats * (MaxSrcGap + MaxReadyGap + 2);
  localparam int MatchW = $clog2(MaxMatchWait + 1);

  for (genvar j = 0; j < N_IN; j++) begin : g_fwait
    for (genvar i = 0; i < N_OUT; i++) begin : g_fav
      // Yosys mis-slices past
      logic f_av;
      logic f_done;

      assign f_av   = s_navail[j][i];
      assign f_done = xfer_last[j] && (in_out[j] == SEL_W'(i));

      always @(posedge clk) begin
        if (f_past_valid && $past(rst_n) && rst_n) begin
          if ($past(f_av) && !$past(f_done)) assume (f_av);
        end
      end
    end

    logic [MatchW-1:0] f_match_wait;
    logic              f_asking;

    assign f_asking = |s_navail[j] && !in_busy[j];

    always_ff @(posedge clk) begin
      if (!rst_n || acc_valid[j] || !f_asking) f_match_wait <= '0;
      else if (int'(f_match_wait) < MaxMatchWait) f_match_wait <= f_match_wait + 1;
    end

    always @(posedge clk) if (rst_n) assert (int'(f_match_wait) < MaxMatchWait);

    // Pairing ends
    logic [MatchW-1:0] f_pair_life;

    always_ff @(posedge clk) begin
      if (!rst_n || !in_busy[j]) f_pair_life <= '0;
      else if (int'(f_pair_life) < MaxMatchWait) f_pair_life <= f_pair_life + 1;
    end

    always @(posedge clk) if (rst_n) assert (int'(f_pair_life) < MaxMatchWait);
  end

`endif

endmodule

`default_nettype wire
