`default_nettype none

module frame_gen #(
    parameter logic [47:0] DEST_MAC = 48'h02_00_00_00_00_00,
    parameter logic [47:0] SRC_MAC  = 48'h02_00_00_00_00_01,
    parameter logic [15:0] ETHERTYPE = 16'h88B5
) (
    input logic clk,
    input logic rst_n,

    // Host commands
    input logic        start,
    input logic [10:0] frame_bytes,
    input logic [31:0] frame_count,
    input logic [ 7:0] gap_bytes,

    // Stream out
    output logic [7:0] m_tdata,
    output logic       m_tvalid,
    output logic       m_tlast,
    output logic       m_tuser,

    // Status
    output logic        busy,
    output logic [31:0] sent_count
);

  typedef enum logic [1:0] {
    IDLE,
    SEND,
    GAP
  } state_t;

  state_t state;

  logic [10:0] byte_idx;
  logic [31:0] frames_left;
  logic [ 7:0] gap_left;
  logic [31:0] seq;
  logic [10:0] size_q;
  logic [ 7:0] gap_q;

  logic start_q;
  logic start_pulse;

  always_ff @(posedge clk) begin
    if (!rst_n) start_q <= 1'b0;
    else start_q <= start;
  end

  assign start_pulse = start && !start_q;

  // Header then padding
  always_comb begin
    case (byte_idx)
      11'd0: m_tdata = DEST_MAC[47:40];
      11'd1: m_tdata = DEST_MAC[39:32];
      11'd2: m_tdata = DEST_MAC[31:24];
      11'd3: m_tdata = DEST_MAC[23:16];
      11'd4: m_tdata = DEST_MAC[15:8];
      11'd5: m_tdata = DEST_MAC[7:0];
      11'd6: m_tdata = SRC_MAC[47:40];
      11'd7: m_tdata = SRC_MAC[39:32];
      11'd8: m_tdata = SRC_MAC[31:24];
      11'd9: m_tdata = SRC_MAC[23:16];
      11'd10: m_tdata = SRC_MAC[15:8];
      11'd11: m_tdata = SRC_MAC[7:0];
      11'd12: m_tdata = ETHERTYPE[15:8];
      11'd13: m_tdata = ETHERTYPE[7:0];
      11'd14: m_tdata = seq[31:24];
      11'd15: m_tdata = seq[23:16];
      11'd16: m_tdata = seq[15:8];
      11'd17: m_tdata = seq[7:0];
      default: m_tdata = 8'd0;
    endcase
  end

  assign m_tvalid = (state == SEND);
  assign m_tlast = (state == SEND) && (byte_idx == size_q - 11'd1);
  assign m_tuser = 1'b0;
  assign busy = (state != IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state       <= IDLE;
      byte_idx    <= 11'd0;
      frames_left <= 32'd0;
      gap_left    <= 8'd0;
      seq         <= 32'd0;
      size_q      <= 11'd0;
      gap_q       <= 8'd0;
      sent_count  <= 32'd0;
    end else begin
      case (state)
        IDLE: begin
          if (start_pulse && frame_count != 32'd0 && frame_bytes >= 11'd18) begin
            size_q      <= frame_bytes;
            gap_q       <= gap_bytes;
            frames_left <= frame_count;
            byte_idx    <= 11'd0;
            seq         <= 32'd0;
            sent_count  <= 32'd0;
            state       <= SEND;
          end
        end

        SEND: begin
          byte_idx <= byte_idx + 11'd1;
          if (byte_idx == size_q - 11'd1) begin
            sent_count  <= sent_count + 32'd1;
            seq         <= seq + 32'd1;
            frames_left <= frames_left - 32'd1;
            byte_idx    <= 11'd0;
            gap_left    <= gap_q - 8'd1;
            if (frames_left == 32'd1) state <= IDLE;
            else state <= GAP;
          end
        end

        GAP: begin
          if (gap_left == 8'd0) state <= SEND;
          else gap_left <= gap_left - 8'd1;
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
