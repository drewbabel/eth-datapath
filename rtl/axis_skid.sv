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

`ifdef FORMAL

  localparam int MaxBeats = 8;

  (* anyconst *) logic [$clog2(MaxBeats)-1:0] f_idx;
  logic [$clog2(MaxBeats+1)-1:0] slave_xfer;
  logic [$clog2(MaxBeats+1)-1:0] master_xfer;
  logic [WIDTH-1:0] f_data;
  logic f_last;
  logic f_past_valid = 1'b0;

  always_ff @(posedge clk) f_past_valid <= 1'b1;

  // Covers
  always @(posedge clk) begin
    if (f_past_valid && $past(rst_n) && rst_n) begin
      cover (skid_valid);  // Slot occupied
      cover ($past(s_xfer && out_free) && m_tvalid);  // Beat bypasses the slot
      cover ($past(skid_valid) && !skid_valid && m_tvalid && m_tready);  // Slot drains on resume
      cover (m_tvalid && m_tready && $past(m_tvalid && m_tready));  // Back to back transfers
      cover (m_tvalid && m_tready && m_tlast);  // tlast transfers out
    end
  end

  initial assume (!rst_n);

  // Log skid buffer contents
  always @(posedge clk) begin
    if (!rst_n) begin
      slave_xfer <= 0;
    end else begin
      if (s_xfer) begin
        if (int'(slave_xfer) < MaxBeats) slave_xfer <= slave_xfer + 1;
        if (($bits(slave_xfer))'(f_idx) == slave_xfer) begin
          f_data <= s_tdata;
          f_last <= s_tlast;
        end
      end
    end
  end

  // Check skid buffer contents
  always @(posedge clk) begin
    if (!rst_n) begin
      master_xfer <= 0;
    end else begin
      if (m_tvalid && m_tready) begin
        if (int'(master_xfer) < MaxBeats) master_xfer <= master_xfer + 1;
        if (($bits(master_xfer))'(f_idx) == master_xfer) begin
          assert (m_tdata == f_data);
          assert (m_tlast == f_last);
        end
      end
    end
  end

  // Master contract on slave port
  always @(posedge clk) begin
    if (!rst_n) assume (!s_tvalid);
    if (f_past_valid && !$past(rst_n)) assume (!s_tvalid);
    if (f_past_valid && $past(rst_n) && rst_n) begin
      if ($past(s_tvalid && !s_tready)) assume (s_tvalid);
      if ($past(s_tvalid) && $past(!s_tready)) begin
        assume (s_tdata == $past(s_tdata));
        assume (s_tlast == $past(s_tlast));
      end
    end
  end

  // Slave contract on master port
  always @(posedge clk) begin
    if (f_past_valid && !$past(rst_n)) assert (!m_tvalid);
    if (f_past_valid && $past(rst_n) && rst_n) begin
      if ($past(m_tvalid) && $past(!m_tready)) begin
        assert (m_tvalid);
        assert (m_tdata == $past(m_tdata));
        assert (m_tlast == $past(m_tlast));
      end
    end
  end


`endif

endmodule

`default_nettype wire
