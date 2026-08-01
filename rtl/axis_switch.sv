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
endmodule

`default_nettype wire
