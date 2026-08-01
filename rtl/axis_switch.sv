`default_nettype none

module axis_switch #(
    parameter int WIDTH  = 8,
    parameter int N_IN   = 2,
    parameter int N_OUT  = 2,
    parameter int DEST_W = $clog2(N_OUT)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    // Slave
    input  logic [ N_IN-1:0]             s_tvalid,
    output logic [ N_IN-1:0]             s_tready,
    input  logic [ N_IN-1:0][ WIDTH-1:0] s_tdata,
    input  logic [ N_IN-1:0]             s_tlast,
    input  logic [ N_IN-1:0][DEST_W-1:0] s_tdest,
    // Master
    output logic [N_OUT-1:0]             m_tvalid,
    input  logic [N_OUT-1:0]             m_tready,
    output logic [N_OUT-1:0][ WIDTH-1:0] m_tdata,
    output logic [N_OUT-1:0]             m_tlast
);

  logic [N_OUT-1:0][ N_IN-1:0] req;
  logic [N_OUT-1:0][ N_IN-1:0] grant;
  logic [N_OUT-1:0]            grant_valid;
  logic [N_OUT-1:0]            hold;

  logic [N_OUT-1:0]            sk_tvalid;
  logic [N_OUT-1:0]            sk_tready;
  logic [N_OUT-1:0][WIDTH-1:0] sk_tdata;
  logic [N_OUT-1:0]            sk_tlast;

  for (genvar i = 0; i < N_OUT; i++) begin : g_out
    rr_arbiter #(
        .N(N_IN)
    ) u_arb (
        .clk(clk),
        .rst_n(rst_n),
        .req(req[i]),
        .hold(hold[i]),
        .grant(grant[i]),
        .grant_valid(grant_valid[i])
    );

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

    for (genvar j = 0; j < N_IN; j++) begin : g_in
      assign req[i][j] = s_tvalid[j] && (s_tdest[j] == i);
    end

    assign hold[i] = grant_valid[i] && !(sk_tvalid[i] && sk_tready[i] && sk_tlast[i]);

    always_comb begin
      sk_tvalid[i] = 1'b0;
      sk_tdata[i]  = '0;
      sk_tlast[i]  = 1'b0;
      for (int j = 0; j < N_IN; j++) begin
        sk_tvalid[i] |= grant[i][j] && s_tvalid[j];
        sk_tdata[i] |= {WIDTH{grant[i][j]}} & s_tdata[j];
        sk_tlast[i] |= grant[i][j] && s_tlast[j];
      end
    end
  end

  always_comb begin
    s_tready = '0;
    for (int i = 0; i < N_OUT; i++) begin
      s_tready |= grant[i] & {N_IN{sk_tready[i]}};
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

  logic [ N_IN-1:0] f_in_pkt = '0;
  logic [N_OUT-1:0] f_out_pkt = '0;

  initial assume (!rst_n);

  // Slave port contract
  for (genvar j = 0; j < N_IN; j++) begin : g_fin
    // Yosys mis-slices past
    logic [ WIDTH-1:0] f_data_in;
    logic [DEST_W-1:0] f_dest_in;
    logic [DEST_W-1:0] f_pkt_dest;
    logic [ BeatW-1:0] f_beats;
    logic [  GapW-1:0] f_src_gap;

    assign f_data_in = s_tdata[j];
    assign f_dest_in = s_tdest[j];

    // Packet in flight
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        f_in_pkt[j] <= 1'b0;
        f_beats <= '0;
      end else if (s_tvalid[j] && s_tready[j]) begin
        f_in_pkt[j] <= !s_tlast[j];
        f_beats <= s_tlast[j] ? '0 : f_beats + 1;
        if (!f_in_pkt[j]) f_pkt_dest <= f_dest_in;
      end
    end

    // Source idle run
    always_ff @(posedge clk) begin
      if (!rst_n || s_tvalid[j]) f_src_gap <= '0;
      else if (f_in_pkt[j]) f_src_gap <= f_src_gap + 1;
    end

    always @(posedge clk) begin
      if (!rst_n) assume (!s_tvalid[j]);
      if (rst_n) begin
        assume (int'(f_beats) < MaxPktBeats);  // Packets end
        assume (int'(f_src_gap) < MaxSrcGap);  // Sources resume
        if (f_in_pkt[j] && s_tvalid[j]) assume (f_dest_in == f_pkt_dest);
      end
      if (f_past_valid) begin
        if (!$past(rst_n)) assume (!s_tvalid[j]);
        if ($past(rst_n) && rst_n && $past(s_tvalid[j] && !s_tready[j])) begin
          assume (s_tvalid[j]);
          assume (f_data_in == $past(f_data_in));
          assume (s_tlast[j] == $past(s_tlast[j]));
          assume (f_dest_in == $past(f_dest_in));
        end
      end
    end
  end

  // Master port contract
  for (genvar i = 0; i < N_OUT; i++) begin : g_fout
    logic [WIDTH-1:0] f_data_out;
    logic [ N_IN-1:0] f_grant;
    logic [ GapW-1:0] f_ready_gap;
    logic [WaitW-1:0] f_wait;

    assign f_data_out = m_tdata[i];
    assign f_grant = grant[i];

    // Packet in flight
    always_ff @(posedge clk) begin
      if (!rst_n) f_out_pkt[i] <= 1'b0;
      else if (sk_tvalid[i] && sk_tready[i]) f_out_pkt[i] <= !sk_tlast[i];
    end

    // Sink stall run
    always_ff @(posedge clk) begin
      if (!rst_n || !(m_tvalid[i] && !m_tready[i])) f_ready_gap <= '0;
      else f_ready_gap <= f_ready_gap + 1;
    end

    // Output starvation
    always_ff @(posedge clk) begin
      if (!rst_n || (sk_tvalid[i] && sk_tready[i])) f_wait <= '0;
      else if (|req[i] && int'(f_wait) < MaxOutWait) f_wait <= f_wait + 1;
    end

    always @(posedge clk) begin
      if (rst_n) begin
        assume (int'(f_ready_gap) < MaxReadyGap);  // Sinks accept
        assert ($onehot0(f_grant));  // One source
        assert (int'(f_wait) < MaxOutWait);  // Bounded wait
      end
      if (f_past_valid && $past(rst_n) && rst_n) begin
        if ($past(m_tvalid[i] && !m_tready[i])) begin
          assert (m_tvalid[i]);
          assert (f_data_out == $past(f_data_out));
          assert (m_tlast[i] == $past(m_tlast[i]));
        end
        if (f_out_pkt[i]) assert (f_grant == $past(f_grant));  // Winner holds
      end
      if (f_past_valid && !$past(rst_n)) assert (!m_tvalid[i]);
    end

    // Mux and routing
    for (genvar j = 0; j < N_IN; j++) begin : g_froute
      logic [DEST_W-1:0] f_route_dest;
      logic [ WIDTH-1:0] f_route_data;
      logic [ WIDTH-1:0] f_buf_byte;

      assign f_route_dest = s_tdest[j];
      assign f_route_data = s_tdata[j];
      assign f_buf_byte   = sk_tdata[i];

      always @(posedge clk) begin
        if (rst_n && sk_tvalid[i] && f_grant[j]) begin
          assert (int'(f_route_dest) == i);
          assert (f_buf_byte == f_route_data);
          assert (sk_tlast[i] == s_tlast[j]);
        end
      end
    end

    always @(posedge clk) begin
      if (rst_n) begin
        cover (&req[i]);  // Contention
        cover (m_tvalid[i] && m_tready[i] && m_tlast[i]);  // Packet completes
      end
      if (f_past_valid && $past(rst_n) && rst_n) begin
        cover (|f_grant && |$past(f_grant) && f_grant != $past(f_grant));  // Handover
      end
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cover (&(m_tvalid & m_tready));  // Both outputs move
      cover (m_tvalid[0] && m_tready[0] && m_tvalid[1] && !m_tready[1]);  // One stalled
    end
  end

  localparam int MaxBeats = 8;
  localparam int CntW = $clog2(MaxBeats + 1);

  (* anyconst *) logic [$clog2(N_IN)-1:0] f_src;
  (* anyconst *) logic [$clog2(N_OUT)-1:0] f_dst;
  (* anyconst *) logic [$clog2(MaxBeats)-1:0] f_idx;

  logic [CntW-1:0] f_in_pos;
  logic [CntW-1:0] f_out_pos;
  logic [WIDTH-1:0] f_data;
  logic [WIDTH-1:0] f_byte;
  logic f_last;
  logic f_tagged;

  logic [WIDTH-1:0] f_src_data;
  logic [WIDTH-1:0] f_buf_data;
  logic [WIDTH-1:0] f_out_byte;
  logic f_from_src;
  logic f_in_xfer;
  logic f_out_xfer;

  assign f_src_data = s_tdata[f_src];
  assign f_buf_data = sk_tdata[f_dst];
  assign f_out_byte = m_tdata[f_dst];
  assign f_from_src = grant[f_dst][f_src];
  assign f_in_xfer  = sk_tvalid[f_dst] && sk_tready[f_dst];
  assign f_out_xfer = m_tvalid[f_dst] && m_tready[f_dst];

  // Log chosen beat
  always_ff @(posedge clk) begin
    if (!rst_n) f_in_pos <= '0;
    else if (f_in_xfer) begin
      if (int'(f_in_pos) < MaxBeats) f_in_pos <= f_in_pos + 1;
      if (f_in_pos == (CntW)'(f_idx)) begin
        f_data   <= f_buf_data;
        f_last   <= sk_tlast[f_dst];
        f_tagged <= f_from_src;
        f_byte   <= f_src_data;
      end
    end
  end

  // Check chosen beat
  always_ff @(posedge clk) begin
    if (!rst_n) f_out_pos <= '0;
    else if (f_out_xfer) begin
      if (int'(f_out_pos) < MaxBeats) f_out_pos <= f_out_pos + 1;
      if (f_out_pos == (CntW)'(f_idx)) begin
        assert (f_out_byte == f_data);
        assert (m_tlast[f_dst] == f_last);
        if (f_tagged) assert (f_out_byte == f_byte);
      end
    end
  end

`endif

endmodule

`default_nettype wire
