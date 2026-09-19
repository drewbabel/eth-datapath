`default_nettype none

module classifier #(
    parameter int N_ENTRIES = 2,
    parameter int DEST_W = 1,
    parameter logic [N_ENTRIES*48-1:0] MATCH_MAC = '0,
    parameter logic [N_ENTRIES*DEST_W-1:0] MATCH_DEST = '0
) (
    input  logic              clk,
    input  logic              rst_n,
    // Slave
    input  logic              s_tvalid,
    output logic              s_tready,
    input  logic [       7:0] s_tdata,
    input  logic              s_tlast,
    // Master
    output logic              m_tvalid,
    input  logic              m_tready,
    output logic [       7:0] m_tdata,
    output logic              m_tlast,
    output logic [DEST_W-1:0] m_tdest,
    // Status
    output logic [      31:0] drop_cnt
);

  localparam int MacBytes = 6;
  localparam int BufDepth = 16;
  localparam int MetaDepth = 16;
  localparam int CntW = $clog2(MacBytes);
  localparam int FillW = $clog2(BufDepth + 1);
  localparam logic [CntW-1:0] HdrLen = CntW'(MacBytes);

  // Handshakes
  logic                                 s_xfer;
  logic                                 m_xfer;
  logic                                 out_free;

  // Header capture
  logic [(MacBytes*$bits(s_tdata))-1:0] addr;
  logic [(MacBytes*$bits(s_tdata))-1:0] addr_cmp;
  logic [                     CntW-1:0] addr_cnt;
  logic                                 in_frame;
  logic                                 sof;
  logic                                 hdr_fill;
  logic                                 hdr_last;
  logic                                 addr_ok;
  logic                                 addr_ok_now;
  logic                                 frame_end_in;

  // Match
  logic                                 hit;
  logic [                   DEST_W-1:0] hit_dest;

  // Metadata queue
  logic                                 meta_wr_en;
  logic                                 meta_rd_en;
  logic                                 meta_full;
  logic                                 meta_empty;
  logic [                     DEST_W:0] meta_wr_data;
  logic [                     DEST_W:0] meta_rd_data;
  logic                                 meta_hit;
  logic [                   DEST_W-1:0] meta_dest;
  logic                                 pushed;
  logic                                 pushed_now;
  logic                                 meta_live;
  logic                                 meta_rd_q;
  logic                                 verdict_free;
  logic                                 bypass;
  logic                                 bypass_hit;
  logic [                   DEST_W-1:0] bypass_dest;
  logic                                 from_bypass;

  // Data buffer
  logic [                    FillW-1:0] fill;
  logic                                 full;
  logic                                 data_empty;
  logic                                 data_rd_en;
  logic                                 data_rd_q;
  logic                                 data_pop;

  // Output
  logic                                 last_out;
  logic                                 send_end;
  logic                                 drain_end;

  logic [$clog2(MetaDepth+1)-1:0] f_meta_count;
  logic [ $clog2(BufDepth+1)-1:0] f_data_count;

  assign s_xfer       = s_tvalid && s_tready;
  assign m_xfer       = m_tvalid && m_tready;
  assign out_free     = !m_tvalid || m_tready;

  // Header capture
  assign sof          = s_xfer && !in_frame;
  assign addr_ok_now  = !sof && addr_ok;  // Masks previous frame
  assign pushed_now   = !sof && pushed;
  assign hdr_fill     = s_xfer && !addr_ok_now;
  assign hdr_last     = s_xfer && !sof && (addr_cnt == HdrLen - 1);  // Sixth byte
  assign frame_end_in = s_xfer && s_tlast;
  // Includes arriving byte
  assign addr_cmp     = hdr_last ? {addr[$bits(addr)-1:8], s_tdata} : addr;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_frame <= 1'b0;
      addr_ok  <= 1'b0;
    end else begin
      if (s_xfer) in_frame <= !s_tlast;

      if (sof) begin
        addr[$bits(addr)-1-:8] <= s_tdata;  // Byte 0 top
        addr_ok <= 1'b0;
      end else if (hdr_fill) begin
        addr[$bits(addr)-addr_cnt*8-1-:8] <= s_tdata;
      end

      if (hdr_last) addr_ok <= 1'b1;
    end
  end

  // Match
  always_comb begin
    hit      = 1'b0;
    hit_dest = '0;
    for (int i = N_ENTRIES - 1; i >= 0; i--) begin  // Lowest entry wins
      if (addr_cmp == MATCH_MAC[i*48+:48]) begin
        hit      = 1'b1;
        hit_dest = MATCH_DEST[i*DEST_W+:DEST_W];
      end
    end
  end

  // Metadata queue
  assign meta_wr_en   = !pushed_now && (hdr_last || frame_end_in);  // Once per frame
  assign meta_wr_data = {hdr_last && hit, hit_dest};  // Runt never hits
  assign verdict_free = out_free && (!meta_live || last_out);
  assign meta_rd_en   = !meta_empty && verdict_free;
  assign bypass       = meta_empty && verdict_free && meta_wr_en;  // Skips queue
  assign meta_hit     = from_bypass ? bypass_hit : meta_rd_data[DEST_W];
  assign meta_dest    = from_bypass ? bypass_dest : meta_rd_data[DEST_W-1:0];
  assign m_tdest      = meta_dest;

  sync_fifo #(
      .WIDTH(DEST_W + 1),
      .DEPTH(MetaDepth)
  ) u_meta (
      .count(f_meta_count),
      .clk(clk),
      .rst_n(rst_n),
      .wr_en(meta_wr_en && !bypass),
      .rd_en(meta_rd_en),
      .wr_data(meta_wr_data),
      .rd_data(meta_rd_data),
      .full(meta_full),
      .empty(meta_empty)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pushed      <= 1'b0;
      meta_live   <= 1'b0;
      meta_rd_q   <= 1'b0;
      from_bypass <= 1'b0;
    end else begin
      if (sof) pushed <= 1'b0;
      if (meta_wr_en) pushed <= 1'b1;

      meta_rd_q <= meta_rd_en || bypass;

      if (bypass) begin
        bypass_hit  <= meta_wr_data[DEST_W];
        bypass_dest <= meta_wr_data[DEST_W-1:0];
        from_bypass <= 1'b1;
      end
      if (meta_rd_en) from_bypass <= 1'b0;

      if (send_end || drain_end) meta_live <= 1'b0;
      if (meta_rd_en || bypass) meta_live <= 1'b1;  // Pop wins tie
    end
  end

  // Data buffer
  assign data_pop   = data_rd_en && !data_empty;
  // Drain while idle
  assign data_rd_en = meta_live && !data_empty && !last_out && (meta_hit ? out_free : !m_tvalid);

  sync_fifo #(
      .WIDTH($bits(s_tdata) + $bits(s_tlast)),
      .DEPTH(BufDepth)
  ) u_data (
      .count(f_data_count),
      .clk(clk),
      .rst_n(rst_n),
      .wr_en(s_xfer),
      .rd_en(data_rd_en),
      .wr_data({s_tlast, s_tdata}),
      .rd_data({m_tlast, m_tdata}),
      .full(full),
      .empty(data_empty)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_tready  <= 1'b0;
      data_rd_q <= 1'b0;
    end else begin
      s_tready  <= (fill < FillW'(BufDepth - 1)) && !meta_full;  // One slot margin
      data_rd_q <= data_rd_en;
    end
  end

  // Output
  assign last_out  = m_tlast && (m_xfer || (data_rd_q && !meta_hit));  // Sent or discarded
  assign send_end  = meta_live && meta_hit && m_xfer && m_tlast;
  assign drain_end = meta_live && !meta_hit && data_rd_q && m_tlast;

  always_ff @(posedge clk) begin
    if (!rst_n) m_tvalid <= 1'b0;
    else if (out_free) m_tvalid <= data_rd_en && meta_hit;  // Miss never valid
  end

  // Counters
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      addr_cnt <= '0;
      fill     <= '0;
      drop_cnt <= '0;
    end else begin
      if (sof) addr_cnt <= CntW'(1);
      else if (hdr_fill) addr_cnt <= addr_cnt + 1;

      if (s_xfer && !data_pop) fill <= fill + 1;
      else if (!s_xfer && data_pop) fill <= fill - 1;

      if (meta_rd_q && !meta_hit) drop_cnt <= drop_cnt + 1;  // Miss entry popped
    end
  end

`ifdef FORMAL

  logic f_past_valid = 1'b0;

  always_ff @(posedge clk) f_past_valid <= 1'b1;

  initial assume (!rst_n);

  // IHI 0051B transmitter
  always @(posedge clk) begin
    if (!rst_n) assume (!s_tvalid);
    if (f_past_valid) begin
      if (!$past(rst_n)) assume (!s_tvalid);
      if ($past(rst_n) && rst_n && $past(s_tvalid && !s_tready)) begin
        assume (s_tvalid);
        assume (s_tdata == $past(s_tdata));
        assume (s_tlast == $past(s_tlast));
      end
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cover (s_xfer);
      cover (m_xfer);

      cover (m_xfer && m_tlast);  // Full completed frame

      cover ($past(drop_cnt) + 1 == drop_cnt);

      cover (meta_wr_en && hdr_last && !hit);  // Miss decided
      cover (meta_wr_en && !hdr_last);  // Runt decided
      cover (drain_end);  // Drop drained

      cover (full && s_tvalid && !s_tready);  // Buffer full
      cover (data_empty && m_tready && !m_tvalid);  // Buffer starved

      cover (meta_empty && !data_empty);  // Decision pending

      if (f_past_valid) begin
        cover (sof && $past(frame_end_in));  // Back to back
        cover (send_end && f_rst_after_xfer);  // Reset recovery
      end
    end
  end

  logic f_seen_xfer = 1'b0;
  logic f_rst_after_xfer = 1'b0;

  always_ff @(posedge clk) begin
    if (s_xfer) f_seen_xfer <= 1'b1;
    if (!rst_n && f_seen_xfer) f_rst_after_xfer <= 1'b1;
  end

  logic [31:0] f_drains;

  always_ff @(posedge clk) begin
    if (!rst_n) f_drains <= '0;
    else if (drain_end) f_drains <= f_drains + 1;
  end

  always_ff @(posedge clk) begin
    if (f_past_valid) begin
      if ($past(!rst_n)) begin
        assert (!m_tvalid);
        assert (!s_tready);
        assert (drop_cnt == '0);
      end else begin
        // Miss emits nothing
        if (meta_live && !meta_hit) assert (!m_tvalid);

        // Count tracks discards
        assert (drop_cnt == f_drains || drop_cnt == f_drains + 1);

        // If not accepted, info stays offered
        if ($past(m_tvalid) && $past(!m_tready)) begin
          assert (m_tvalid);
          assert (m_tdest == $past(m_tdest));
          assert (m_tdata == $past(m_tdata));
          assert (m_tlast == $past(m_tlast));
        end

        // Bytes from same packet have same destination
        if ($past(!m_tlast) && $past(m_xfer)) assert (m_tdest == $past(m_tdest));
      end
    end
  end

`endif

endmodule

`default_nettype wire
