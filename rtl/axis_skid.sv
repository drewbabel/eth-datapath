`default_nettype none

module axis_skid #(
    parameter int WIDTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,
    // Slave
    input  logic             s_tvalid,
    output logic             s_tready,
    input  logic [WIDTH-1:0] s_tdata,
    input  logic             s_tlast,
    // Master
    output logic             m_tvalid,
    input  logic             m_tready,
    output logic [WIDTH-1:0] m_tdata,
    output logic             m_tlast
);

  logic             skid_valid;
  logic [WIDTH-1:0] skid_data;
  logic             skid_last;
  logic             s_xfer;
  logic             out_free;

  assign s_tready = !skid_valid;
  assign s_xfer   = s_tvalid && s_tready;
  assign out_free = !m_tvalid || m_tready;

  always_ff @(posedge clk) begin
    if (!rst_n) skid_valid <= 1'b0;
    else if (s_xfer && !out_free) begin
      skid_valid <= 1'b1;
      skid_data  <= s_tdata;
      skid_last  <= s_tlast;
    end else if (out_free) skid_valid <= 1'b0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) m_tvalid <= 1'b0;
    else if (out_free) begin
      m_tvalid <= skid_valid || s_tvalid;
      m_tdata  <= skid_valid ? skid_data : s_tdata;
      m_tlast  <= skid_valid ? skid_last : s_tlast;
    end
  end

endmodule

`default_nettype wire
