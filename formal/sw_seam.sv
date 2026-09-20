`default_nettype none

module sw_seam #(
    parameter int WIDTH     = 3,
    parameter int NPORT     = 2,
    parameter int DEST_W    = 1,
    parameter int DEPTH     = 8,
    parameter int MAX_FRAME = 4
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic [NPORT-1:0]              s_tvalid,
    input  logic [NPORT-1:0][WIDTH-1:0]   s_tdata,
    input  logic [NPORT-1:0]              s_tlast,
    input  logic [NPORT-1:0][DEST_W-1:0]  s_tdest,
    input  logic [NPORT-1:0]              m_tready,
    output logic [NPORT-1:0]              m_tvalid,
    output logic [NPORT-1:0][WIDTH-1:0]   m_tdata,
    output logic [NPORT-1:0]              m_tlast
);

  logic [NPORT-1:0]                   q_tvalid;
  logic [NPORT-1:0]                   q_tready;
  logic [NPORT-1:0][ WIDTH-1:0]       q_tdata;
  logic [NPORT-1:0]                   q_tlast;
  logic [NPORT-1:0][ NPORT-1:0]       q_navail;
  logic [NPORT-1:0][DEST_W-1:0]       q_sel;
  logic [NPORT-1:0]                   q_sel_valid;
  logic [NPORT-1:0][ NPORT-1:0][31:0] q_drop;
`ifdef FORMAL
  logic [NPORT-1:0][DEST_W-1:0]       q_out_sel;
  logic [NPORT-1:0]                   sw_in_busy;
  logic [NPORT-1:0][DEST_W-1:0]       sw_in_out;
`endif

  for (genvar j = 0; j < NPORT; j++) begin : g_q
    voq #(
        .WIDTH(WIDTH),
        .N_OUT(NPORT),
        .DEST_W(DEST_W),
        .DEPTH(DEPTH),
        .MAX_FRAME(MAX_FRAME)
    ) u_voq (
        .clk(clk),
        .rst_n(rst_n),
        .s_tvalid(s_tvalid[j]),
        .s_tready(),
        .s_tdata(s_tdata[j]),
        .s_tlast(s_tlast[j]),
        .s_tdest(s_tdest[j]),
        .navail(q_navail[j]),
        .sel(q_sel[j]),
        .sel_valid(q_sel_valid[j]),
        .m_tvalid(q_tvalid[j]),
        .m_tready(q_tready[j]),
        .m_tdata(q_tdata[j]),
`ifdef FORMAL
        .f_out_sel(q_out_sel[j]),
`endif
        .m_tlast(q_tlast[j]),
        .drop_cnt(q_drop[j])
    );
  end

  axis_switch #(
      .WIDTH(WIDTH),
      .N_IN (NPORT),
      .N_OUT(NPORT),
      .SEL_W(DEST_W)
  ) u_sw (
      .clk(clk),
      .rst_n(rst_n),
      .s_tvalid(q_tvalid),
      .s_tready(q_tready),
      .s_tdata(q_tdata),
      .s_tlast(q_tlast),
      .s_navail(q_navail),
      .s_sel(q_sel),
      .s_sel_valid(q_sel_valid),
      .m_tvalid(m_tvalid),
      .m_tready(m_tready),
      .m_tdata(m_tdata),
`ifdef FORMAL
      .f_in_busy(sw_in_busy),
      .f_in_out(sw_in_out),
`endif
      .m_tlast(m_tlast)
  );

`ifdef FORMAL

  logic f_past_valid = 1'b0;

  always_ff @(posedge clk) f_past_valid <= 1'b1;

  localparam int BeatW = $clog2(MAX_FRAME + 1);

  initial assume (!rst_n);

  // Ingress contract
  for (genvar j = 0; j < NPORT; j++) begin : g_fin
    logic [ BeatW-1:0] f_beats;
    logic [DEST_W-1:0] f_dest;
    logic              f_sof;

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        f_beats <= '0;
        f_sof   <= 1'b1;
      end else if (s_tvalid[j]) begin
        f_beats <= s_tlast[j] ? '0 : f_beats + 1'b1;
        f_sof   <= s_tlast[j];
        if (f_sof) f_dest <= s_tdest[j];
      end
    end

    always @(posedge clk) begin
      if (!rst_n) assume (!s_tvalid[j]);
      if (rst_n) begin
        assume (int'(f_beats) < MAX_FRAME);
        if (!f_sof && s_tvalid[j]) assume (s_tdest[j] == f_dest);
      end
      if (f_past_valid && !$past(rst_n)) assume (!s_tvalid[j]);
    end
  end

  // Seam contract
  for (genvar j = 0; j < NPORT; j++) begin : g_fseam
    logic              f_qv;
    logic              f_busy;
    logic [DEST_W-1:0] f_out;
    logic [DEST_W-1:0] f_src;

    assign f_qv   = q_tvalid[j];
    assign f_busy = sw_in_busy[j];
    assign f_out  = sw_in_out[j];
    assign f_src  = q_out_sel[j];

    always @(posedge clk) begin
      if (rst_n) begin
        assert (!f_qv || f_busy);
        assert (!f_qv || (f_src == f_out));
      end
    end
  end

`endif

endmodule

`default_nettype wire
