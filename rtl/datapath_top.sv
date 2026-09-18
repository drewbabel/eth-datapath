`default_nettype none

module datapath_top #(
    parameter string TARGET = "GENERIC",
    parameter int N_ENTRIES = 2,
    parameter logic [N_ENTRIES*48-1:0] MATCH_MAC = {48'h02_00_00_00_00_01, 48'h02_00_00_00_00_00},
    parameter logic [N_ENTRIES-1:0] MATCH_DEST = 2'b10,
    parameter int CREDIT_DEPTH = 16,
    parameter int PHY_PORTS = 2,
    parameter int PROBE_DEPTH = 16,
    parameter int ADDR_WIDTH = 7
) (
    input logic clk,
    input logic clk90,
    input logic rst_n,

    // RGMII pins
    input  logic [1:0]      rgmii_rx_clk,
    input  logic [1:0][3:0] rgmii_rxd,
    input  logic [1:0]      rgmii_rx_ctl,
    output logic [1:0]      rgmii_tx_clk,
    output logic [1:0][3:0] rgmii_txd,
    output logic [1:0]      rgmii_tx_ctl,

    // Control plane
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [ 2:0] s_axi_awprot,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    input  logic [31:0] s_axi_wdata,
    input  logic [ 3:0] s_axi_wstrb,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    output logic [ 1:0] s_axi_bresp,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [ 2:0] s_axi_arprot,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,
    output logic [31:0] s_axi_rdata,
    output logic [ 1:0] s_axi_rresp
);

  localparam int NPorts = 2;
  localparam int DestW = 1;
  localparam int NumCsr = 2 ** (ADDR_WIDTH - 3);

  // Port counters
  logic [NPorts-1:0][     31:0] overflow_cnt;
  logic [NPorts-1:0][     31:0] drop_cnt;

  // Switch ingress
  logic [NPorts-1:0]            sw_s_tvalid;
  logic [NPorts-1:0]            sw_s_tready;
  logic [NPorts-1:0][      8:0] sw_s_tdata;
  logic [NPorts-1:0]            sw_s_tlast;
  logic [NPorts-1:0][DestW-1:0] sw_s_tdest;

  // Switch egress
  logic       gen_tvalid;
  logic [7:0] gen_tdata;
  logic       gen_tlast;
  logic       gen_busy;
  logic [31:0] gen_sent;

  logic [NPorts-1:0] drop_evt;
  logic [NPorts-1:0] lost_evt;
  logic [NPorts-1:0] mon_rx_dv;
  logic [NPorts-1:0] mon_tx_en;

  logic [NPorts-1:0]            sw_m_tvalid;
  logic [NPorts-1:0]            sw_m_tready;
  logic [NPorts-1:0][      8:0] sw_m_tdata;
  logic [NPorts-1:0]            sw_m_tlast;

  for (genvar i = 0; i < NPorts; i++) begin : g_port
    // Controller streams
    logic [7:0] rx_tdata;
    logic       rx_tvalid;
    logic       rx_tlast;
    logic       rx_tuser;
    logic [7:0] tx_tdata;
    logic       tx_tvalid;
    logic       tx_tready;
    logic       tx_tlast;
    logic       tx_tuser;

    // Credit link
    logic       link_valid;
    logic [9:0] link_data;
    logic       credit_return;
    logic       q_valid;
    logic       q_ready;
    logic [9:0] q_data;

    if (i < PHY_PORTS) begin : g_phy
      eth_mac_1g_rgmii_fifo #(
          .TARGET(TARGET),
          .IODDR_STYLE("IODDR"),
          .CLOCK_INPUT_STYLE("BUFR"),
          .USE_CLK90("TRUE"),
          .TX_FIFO_DEPTH(64),
          .TX_FRAME_FIFO(0),
          .RX_FIFO_DEPTH(64),
          .RX_FRAME_FIFO(0)
      ) u_mac (
          .gtx_clk(clk),
          .gtx_clk90(clk90),
          .gtx_rst(!rst_n),
          .logic_clk(clk),
          .logic_rst(!rst_n),
          .tx_axis_tdata(tx_tdata),
          .tx_axis_tkeep(1'b1),
          .tx_axis_tvalid(tx_tvalid),
          .tx_axis_tready(tx_tready),
          .tx_axis_tlast(tx_tlast),
          .tx_axis_tuser(tx_tuser),
          .rx_axis_tdata(rx_tdata),
          .rx_axis_tkeep(),
          .rx_axis_tvalid(rx_tvalid),
          .rx_axis_tready(1'b1),
          .rx_axis_tlast(rx_tlast),
          .rx_axis_tuser(rx_tuser),
          .rgmii_rx_clk(rgmii_rx_clk[i]),
          .rgmii_rxd(rgmii_rxd[i]),
          .rgmii_rx_ctl(rgmii_rx_ctl[i]),
          .rgmii_tx_clk(rgmii_tx_clk[i]),
          .rgmii_txd(rgmii_txd[i]),
          .rgmii_tx_ctl(rgmii_tx_ctl[i]),
          .tx_error_underflow(),
          .tx_fifo_overflow(),
          .tx_fifo_bad_frame(),
          .tx_fifo_good_frame(),
          .rx_error_bad_frame(),
          .rx_error_bad_fcs(),
          .rx_fifo_overflow(),
          .rx_fifo_bad_frame(),
          .rx_fifo_good_frame(),
          .speed(),
          .cfg_ifg(8'd12),
          .cfg_tx_enable(1'b1),
          .cfg_rx_enable(1'b1),
          .mon_rx_dv(mon_rx_dv[i]),
          .mon_tx_en(mon_tx_en[i])
      );

    end else begin : g_no_phy
      assign rx_tdata = 8'd0;
      assign rx_tvalid = 1'b0;
      assign rx_tlast = 1'b0;
      assign rx_tuser = 1'b0;
      assign tx_tready = 1'b1;
      assign rgmii_tx_clk[i] = 1'b0;
      assign rgmii_txd[i] = 4'd0;
      assign rgmii_tx_ctl[i] = 1'b0;
      assign mon_rx_dv[i] = 1'b0;
      assign mon_tx_en[i] = 1'b0;
    end

    logic       sh_tvalid;
    logic [7:0] sh_tdata;
    logic       sh_tlast;
    logic       sh_tuser;

    if (i == 0) begin : g_inject
      assign sh_tvalid = gen_busy ? gen_tvalid : rx_tvalid;
      assign sh_tdata  = gen_busy ? gen_tdata : rx_tdata;
      assign sh_tlast  = gen_busy ? gen_tlast : rx_tlast;
      assign sh_tuser  = gen_busy ? 1'b0 : rx_tuser;
    end else begin : g_direct
      assign sh_tvalid = rx_tvalid;
      assign sh_tdata  = rx_tdata;
      assign sh_tlast  = rx_tlast;
      assign sh_tuser  = rx_tuser;
    end

    rx_shim #(
        .N_ENTRIES(N_ENTRIES),
        .DEST_W(DestW),
        .MATCH_MAC(MATCH_MAC),
        .MATCH_DEST(MATCH_DEST)
    ) u_rx_shim (
        .clk(clk),
        .rst_n(rst_n),
        .rx_axis_tvalid(sh_tvalid),
        .rx_axis_tdata(sh_tdata),
        .rx_axis_tlast(sh_tlast),
        .rx_axis_tuser(sh_tuser),
        .m_tvalid(sw_s_tvalid[i]),
        .m_tready(sw_s_tready[i]),
        .m_tdata(sw_s_tdata[i]),
        .m_tlast(sw_s_tlast[i]),
        .m_tdest(sw_s_tdest[i]),
        .overflow_cnt(overflow_cnt[i]),
        .drop_cnt(drop_cnt[i]),
        .drop_evt(drop_evt[i]),
        .lost_evt(lost_evt[i])
    );

    // Last rides data
    credit_sender #(
        .WIDTH(10),
        .DEPTH(CREDIT_DEPTH)
    ) u_sender (
        .clk(clk),
        .rst_n(rst_n),
        .src_valid(sw_m_tvalid[i]),
        .src_data({sw_m_tlast[i], sw_m_tdata[i]}),
        .src_ready(sw_m_tready[i]),
        .tx_valid(link_valid),
        .tx_data(link_data),
        .credit_return(credit_return)
    );

    credit_fifo #(
        .WIDTH(10),
        .DEPTH(CREDIT_DEPTH)
    ) u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .rx_valid(link_valid),
        .rx_data(link_data),
        .dst_ready(q_ready),
        .dst_valid(q_valid),
        .dst_data(q_data),
        .credit_return(credit_return)
    );

    tx_shim u_tx_shim (
        .s_tvalid(q_valid),
        .s_tready(q_ready),
        .s_tdata(q_data[8:0]),
        .s_tlast(q_data[9]),
        .tx_axis_tdata(tx_tdata),
        .tx_axis_tvalid(tx_tvalid),
        .tx_axis_tready(tx_tready),
        .tx_axis_tlast(tx_tlast),
        .tx_axis_tuser(tx_tuser)
    );
  end

  axis_switch #(
      .WIDTH (9),
      .N_IN  (NPorts),
      .N_OUT (NPorts),
      .DEST_W(DestW)
  ) u_switch (
      .clk(clk),
      .rst_n(rst_n),
      .s_tvalid(sw_s_tvalid),
      .s_tready(sw_s_tready),
      .s_tdata(sw_s_tdata),
      .s_tlast(sw_s_tlast),
      .s_tdest(sw_s_tdest),
      .m_tvalid(sw_m_tvalid),
      .m_tready(sw_m_tready),
      .m_tdata(sw_m_tdata),
      .m_tlast(sw_m_tlast)
  );

  logic [NumCsr-1:0][31:0] status_w;
  logic [NumCsr-1:0][31:0] control_w;

  logic [31:0] probe_min;
  logic [31:0] probe_max;
  logic [31:0] probe_count;
  logic [31:0] probe_sum_lo;
  logic [31:0] probe_sum_hi;
  logic [31:0] probe_error;

  frame_gen u_gen (
      .clk(clk),
      .rst_n(rst_n),
      .start(control_w[0][2]),
      .frame_bytes(control_w[1][10:0]),
      .frame_count(control_w[2]),
      .gap_bytes(control_w[1][23:16]),
      .m_tdata(gen_tdata),
      .m_tvalid(gen_tvalid),
      .m_tlast(gen_tlast),
      .m_tuser(),
      .busy(gen_busy),
      .sent_count(gen_sent)
  );

  latency_probe #(
      .DEPTH(PROBE_DEPTH)
  ) u_probe (
      .clk(clk),
      .rst_n(rst_n),
      .rx_ctl(gen_busy ? gen_tvalid : mon_rx_dv[0]),
      .tx_ctl(mon_tx_en[0]),
      .discard(drop_evt[0] || lost_evt[0]),
      .clear(control_w[0][0]),
      .snapshot(control_w[0][1]),
      .stat_min(probe_min),
      .stat_max(probe_max),
      .stat_count(probe_count),
      .stat_sum_lo(probe_sum_lo),
      .stat_sum_hi(probe_sum_hi),
      .stat_error(probe_error)
  );

  assign status_w[0] = overflow_cnt[0];
  assign status_w[1] = drop_cnt[0];
  assign status_w[2] = overflow_cnt[1];
  assign status_w[3] = drop_cnt[1];
  assign status_w[4] = probe_min;
  assign status_w[5] = probe_max;
  assign status_w[6] = probe_count;
  assign status_w[7] = probe_sum_lo;
  assign status_w[8] = probe_sum_hi;
  assign status_w[9] = probe_error;
  assign status_w[10] = gen_sent;

  for (genvar i = 11; i < NumCsr; i++) begin : g_spare
    assign status_w[i] = 32'd0;
  end

  axil_csr #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(32)
  ) u_csr (
      .clk(clk),
      .rst_n(rst_n),
      .s_axi_awvalid(s_axi_awvalid),
      .s_axi_awready(s_axi_awready),
      .s_axi_awaddr(s_axi_awaddr),
      .s_axi_awprot(s_axi_awprot),
      .s_axi_wvalid(s_axi_wvalid),
      .s_axi_wready(s_axi_wready),
      .s_axi_wdata(s_axi_wdata),
      .s_axi_wstrb(s_axi_wstrb),
      .s_axi_bvalid(s_axi_bvalid),
      .s_axi_bready(s_axi_bready),
      .s_axi_bresp(s_axi_bresp),
      .s_axi_arvalid(s_axi_arvalid),
      .s_axi_arready(s_axi_arready),
      .s_axi_araddr(s_axi_araddr),
      .s_axi_arprot(s_axi_arprot),
      .s_axi_rvalid(s_axi_rvalid),
      .s_axi_rready(s_axi_rready),
      .s_axi_rdata(s_axi_rdata),
      .s_axi_rresp(s_axi_rresp),
      .status(status_w),
      .control(control_w)
  );

endmodule

`default_nettype wire
