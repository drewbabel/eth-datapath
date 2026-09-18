`default_nettype none

module rx_shim #(
    parameter int N_ENTRIES = 2,
    parameter int DEST_W = 1,
    parameter logic [N_ENTRIES*48-1:0] MATCH_MAC = '0,
    parameter logic [N_ENTRIES*DEST_W-1:0] MATCH_DEST = '0,
    parameter int BUF_DEPTH = 2048,
    parameter int VERDICT_DEPTH = 16
) (
    input logic clk,
    input logic rst_n,
    // Controller receive
    input logic       rx_axis_tvalid,
    input logic [7:0] rx_axis_tdata,
    input logic       rx_axis_tlast,
    input logic       rx_axis_tuser,
    // Switch slave
    output logic              m_tvalid,
    input  logic              m_tready,
    output logic [       8:0] m_tdata,
    output logic              m_tlast,
    output logic [DEST_W-1:0] m_tdest,
    // Status
    output logic [      31:0] overflow_cnt,
    output logic [      31:0] drop_cnt,
    output logic              retire_valid,
    output logic              retire_drop
);

  localparam int BAw = $clog2(BUF_DEPTH);
  localparam int VAw = $clog2(VERDICT_DEPTH);

  // Elastic buffer
  logic [       9:0] buf_mem      [BUF_DEPTH];
  logic [     BAw:0] buf_wr_ptr;
  logic [     BAw:0] buf_rd_ptr;
  logic              buf_wr_en;
  logic              buf_rd_en;
  logic [       9:0] buf_wr_data;
  logic [       9:0] buf_rd_data;
  logic              buf_full;
  logic              buf_empty;
  logic              buf_out_valid;

  // Verdict queue
  logic              v_mem        [VERDICT_DEPTH];
  logic [     VAw:0] v_wr_ptr;
  logic [     VAw:0] v_rd_ptr;
  logic              v_wr_en;
  logic              v_wr_data;
  logic              v_head;
  logic              v_pop;
  logic              v_full;
  logic              v_empty;
  logic [     VAw:0] v_pend;

  // Classifier stream
  logic              c_s_tvalid;
  logic              c_s_tready;
  logic [       7:0] c_s_tdata;
  logic              c_s_tlast;
  logic              c_s_tuser;
  logic              c_s_xfer;

  logic              c_m_tvalid;
  logic              c_m_tready;
  logic [       7:0] c_m_tdata;
  logic              c_m_tlast;
  logic [DEST_W-1:0] c_m_tdest;

  logic              drop_q_valid;
  logic [      31:0] c_drop_cnt;
  logic [      31:0] c_drop_cnt_q;
  logic              drop_pulse;
  logic              frame_done;

  // Controller never stalls
  assign buf_wr_en   = rx_axis_tvalid && !buf_full;
  assign buf_wr_data = {rx_axis_tuser, rx_axis_tlast, rx_axis_tdata};
  assign buf_empty   = buf_wr_ptr == buf_rd_ptr;
  assign buf_full    = (buf_wr_ptr[BAw] != buf_rd_ptr[BAw]) &&
      (buf_wr_ptr[BAw-1:0] == buf_rd_ptr[BAw-1:0]);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      buf_wr_ptr  <= '0;
      buf_rd_ptr  <= '0;
      buf_rd_data <= '0;
    end else begin
      if (buf_wr_en) begin
        buf_mem[buf_wr_ptr[BAw-1:0]] <= buf_wr_data;
        buf_wr_ptr <= buf_wr_ptr + 1'b1;
      end
      if (buf_rd_en) begin
        buf_rd_data <= buf_mem[buf_rd_ptr[BAw-1:0]];
        buf_rd_ptr  <= buf_rd_ptr + 1'b1;
      end
    end
  end

  // Registered read
  assign buf_rd_en = !buf_empty && (!buf_out_valid || c_s_tready);

  always_ff @(posedge clk) begin
    if (!rst_n) buf_out_valid <= 1'b0;
    else if (buf_rd_en) buf_out_valid <= 1'b1;
    else if (c_s_tready) buf_out_valid <= 1'b0;
  end

  assign c_s_tvalid = buf_out_valid;
  assign {c_s_tuser, c_s_tlast, c_s_tdata} = buf_rd_data;
  assign c_s_xfer = c_s_tvalid && c_s_tready;

  classifier #(
      .N_ENTRIES(N_ENTRIES),
      .DEST_W(DEST_W),
      .MATCH_MAC(MATCH_MAC),
      .MATCH_DEST(MATCH_DEST)
  ) u_classifier (
      .clk(clk),
      .rst_n(rst_n),
      .s_tvalid(c_s_tvalid),
      .s_tready(c_s_tready),
      .s_tdata(c_s_tdata),
      .s_tlast(c_s_tlast),
      .m_tvalid(c_m_tvalid),
      .m_tready(c_m_tready),
      .m_tdata(c_m_tdata),
      .m_tlast(c_m_tlast),
      .m_tdest(c_m_tdest),
      .drop_cnt(c_drop_cnt)
  );

  // One per frame
  assign v_wr_en  = c_s_xfer && c_s_tlast;
  assign v_wr_data = c_s_tuser;
  assign v_empty  = v_wr_ptr == v_rd_ptr;
  assign v_full   = (v_wr_ptr[VAw] != v_rd_ptr[VAw]) && (v_wr_ptr[VAw-1:0] == v_rd_ptr[VAw-1:0]);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v_wr_ptr <= '0;
      v_rd_ptr <= '0;
    end else begin
      if (v_wr_en && !v_full) begin
        v_mem[v_wr_ptr[VAw-1:0]] <= v_wr_data;
        v_wr_ptr <= v_wr_ptr + 1'b1;
      end
      if (v_pop) v_rd_ptr <= v_rd_ptr + 1'b1;
    end
  end

  assign drop_pulse = drop_q_valid && (c_drop_cnt != c_drop_cnt_q);
  assign frame_done = (c_m_tvalid && c_m_tready && c_m_tlast) || drop_pulse;

  // Drop decided early
  assign v_pop      = !v_empty && (frame_done || v_pend != '0);

  always_ff @(posedge clk) begin
    if (!rst_n) v_pend <= '0;
    else if (frame_done && !v_pop) v_pend <= v_pend + 1'b1;
    else if (!frame_done && v_pop) v_pend <= v_pend - 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      c_drop_cnt_q <= '0;
      drop_q_valid <= 1'b0;
    end else begin
      c_drop_cnt_q <= c_drop_cnt;
      drop_q_valid <= 1'b1;
    end
  end

  // Oldest unretired frame
  assign v_head = !v_empty && v_mem[v_rd_ptr[VAw-1:0]];

  assign m_tvalid   = c_m_tvalid;
  assign c_m_tready = m_tready;
  assign m_tdata    = {v_head, c_m_tdata};
  assign m_tlast    = c_m_tlast;
  assign m_tdest    = c_m_tdest;
  assign drop_cnt   = c_drop_cnt;

  logic over_active;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      overflow_cnt <= '0;
      over_active  <= 1'b0;
    end else begin
      if (rx_axis_tvalid && buf_full) overflow_cnt <= overflow_cnt + 1;
      if (rx_axis_tvalid && buf_full) over_active <= 1'b1;
      else if (rx_axis_tvalid && rx_axis_tlast) over_active <= 1'b0;
    end
  end

  logic lost_pulse;

  assign lost_pulse = over_active && rx_axis_tvalid && rx_axis_tlast;

  assign retire_valid = frame_done || lost_pulse;
  assign retire_drop  = drop_pulse || lost_pulse;

endmodule

`default_nettype wire
