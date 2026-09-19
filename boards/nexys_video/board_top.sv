`default_nettype none

module board_top (
    input  logic       clk,
    input  logic       reset_n,
    output logic [7:0] led,

    // RGMII pins
    input  logic       phy_rx_clk,
    input  logic [3:0] phy_rxd,
    input  logic       phy_rx_ctl,
    output logic       phy_tx_clk,
    output logic [3:0] phy_txd,
    output logic       phy_tx_ctl,
    output logic       phy_reset_n,

    // Serial pins
    input  logic uart_rxd,
    output logic uart_txd
);

  logic clk_ibufg;
  logic clk_mmcm_out;
  logic clk90_mmcm_out;
  logic clk200_mmcm_out;
  logic mmcm_clkfb;
  logic mmcm_locked;
  logic clk125;
  logic clk125_90;
  logic clk200;

  IBUFG clk_ibufg_inst (
      .I(clk),
      .O(clk_ibufg)
  );

  // Vco one thousand
  MMCME2_BASE #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKIN1_PERIOD(10.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(10),
      .CLKOUT0_DIVIDE_F(8),
      .CLKOUT1_DIVIDE(8),
      .CLKOUT1_PHASE(90.0),
      .CLKOUT2_DIVIDE(5),
      .REF_JITTER1(0.010),
      .STARTUP_WAIT("FALSE")
  ) clk_mmcm_inst (
      .CLKIN1(clk_ibufg),
      .CLKFBIN(mmcm_clkfb),
      .CLKFBOUT(mmcm_clkfb),
      .CLKFBOUTB(),
      .CLKOUT0(clk_mmcm_out),
      .CLKOUT0B(),
      .CLKOUT1(clk90_mmcm_out),
      .CLKOUT1B(),
      .CLKOUT2(clk200_mmcm_out),
      .CLKOUT2B(),
      .CLKOUT3(),
      .CLKOUT3B(),
      .CLKOUT4(),
      .CLKOUT5(),
      .CLKOUT6(),
      .LOCKED(mmcm_locked),
      .PWRDWN(1'b0),
      .RST(!reset_n)
  );

  BUFG clk_bufg_inst (
      .I(clk_mmcm_out),
      .O(clk125)
  );

  BUFG clk90_bufg_inst (
      .I(clk90_mmcm_out),
      .O(clk125_90)
  );

  BUFG clk200_bufg_inst (
      .I(clk200_mmcm_out),
      .O(clk200)
  );

  // Four flop stretch
  logic [3:0] rst_sync = 4'hF;
  logic       rst_n;

  always_ff @(posedge clk125) rst_sync <= {rst_sync[2:0], !mmcm_locked};

  assign rst_n = !rst_sync[3];
  assign phy_reset_n = rst_n;

  logic [3:0] phy_rxd_delay;
  logic       phy_rx_ctl_delay;

  IDELAYCTRL idelayctrl_inst (
      .REFCLK(clk200),
      .RST(!rst_n),
      .RDY()
  );

  for (genvar i = 0; i < 4; i++) begin : g_rxd_delay
    IDELAYE2 #(
        .IDELAY_TYPE("FIXED"),
        .IDELAY_VALUE(0),
        .REFCLK_FREQUENCY(200.0)
    ) phy_rxd_idelay (
        .IDATAIN(phy_rxd[i]),
        .DATAOUT(phy_rxd_delay[i]),
        .DATAIN(1'b0),
        .C(1'b0),
        .CE(1'b0),
        .INC(1'b0),
        .CINVCTRL(1'b0),
        .CNTVALUEIN(5'd0),
        .CNTVALUEOUT(),
        .LD(1'b0),
        .LDPIPEEN(1'b0),
        .REGRST(1'b0)
    );
  end

  IDELAYE2 #(
      .IDELAY_TYPE("FIXED"),
      .IDELAY_VALUE(0),
      .REFCLK_FREQUENCY(200.0)
  ) phy_rx_ctl_idelay (
      .IDATAIN(phy_rx_ctl),
      .DATAOUT(phy_rx_ctl_delay),
      .DATAIN(1'b0),
      .C(1'b0),
      .CE(1'b0),
      .INC(1'b0),
      .CINVCTRL(1'b0),
      .CNTVALUEIN(5'd0),
      .CNTVALUEOUT(),
      .LD(1'b0),
      .LDPIPEEN(1'b0),
      .REGRST(1'b0)
  );

  localparam int NPorts = 2;
  localparam int PhyPorts = 1;

  logic [NPorts-1:0]      rgmii_rx_clk;
  logic [NPorts-1:0][3:0] rgmii_rxd;
  logic [NPorts-1:0]      rgmii_rx_ctl;
  logic [NPorts-1:0]      rgmii_tx_clk;
  logic [NPorts-1:0][3:0] rgmii_txd;
  logic [NPorts-1:0]      rgmii_tx_ctl;

  assign rgmii_rx_clk[0] = phy_rx_clk;
  assign rgmii_rxd[0] = phy_rxd_delay;
  assign rgmii_rx_ctl[0] = phy_rx_ctl_delay;
  assign phy_tx_clk = rgmii_tx_clk[0];
  assign phy_txd = rgmii_txd[0];
  assign phy_tx_ctl = rgmii_tx_ctl[0];

  // Connectors absent
  for (genvar i = PhyPorts; i < NPorts; i++) begin : g_no_connector
    assign rgmii_rx_clk[i] = 1'b0;
    assign rgmii_rxd[i] = 4'd0;
    assign rgmii_rx_ctl[i] = 1'b0;
  end

  logic        awvalid;
  logic        awready;
  logic [ 6:0] awaddr;
  logic [ 2:0] awprot;
  logic        wvalid;
  logic        wready;
  logic [31:0] wdata;
  logic [ 3:0] wstrb;
  logic        bvalid;
  logic        bready;
  logic [ 1:0] bresp;
  logic        arvalid;
  logic        arready;
  logic [ 6:0] araddr;
  logic [ 2:0] arprot;
  logic        rvalid;
  logic        rready;
  logic [31:0] rdata;
  logic [ 1:0] rresp;

  uart_axil #(
      .CLK_FREQ_HZ(125_000_000),
      .BAUD_RATE  (115_200),
      .ADDR_WIDTH (7),
      .DATA_WIDTH (32)
  ) u_bridge (
      .clk(clk125),
      .rst_n(rst_n),
      .rx_serial(uart_rxd),
      .tx_serial(uart_txd),
      .m_axi_awvalid(awvalid),
      .m_axi_awready(awready),
      .m_axi_awaddr(awaddr),
      .m_axi_awprot(awprot),
      .m_axi_wvalid(wvalid),
      .m_axi_wready(wready),
      .m_axi_wdata(wdata),
      .m_axi_wstrb(wstrb),
      .m_axi_bvalid(bvalid),
      .m_axi_bready(bready),
      .m_axi_arvalid(arvalid),
      .m_axi_arready(arready),
      .m_axi_araddr(araddr),
      .m_axi_arprot(arprot),
      .m_axi_rvalid(rvalid),
      .m_axi_rready(rready),
      .m_axi_rdata(rdata)
  );

  datapath_top #(
      .TARGET("XILINX"),
      .N_PORTS(NPorts),
      .PHY_PORTS(PhyPorts)
  ) u_datapath (
      .clk(clk125),
      .clk90(clk125_90),
      .rst_n(rst_n),
      .rgmii_rx_clk(rgmii_rx_clk),
      .rgmii_rxd(rgmii_rxd),
      .rgmii_rx_ctl(rgmii_rx_ctl),
      .rgmii_tx_clk(rgmii_tx_clk),
      .rgmii_txd(rgmii_txd),
      .rgmii_tx_ctl(rgmii_tx_ctl),
      .s_axi_awvalid(awvalid),
      .s_axi_awready(awready),
      .s_axi_awaddr(awaddr),
      .s_axi_awprot(awprot),
      .s_axi_wvalid(wvalid),
      .s_axi_wready(wready),
      .s_axi_wdata(wdata),
      .s_axi_wstrb(wstrb),
      .s_axi_bvalid(bvalid),
      .s_axi_bready(bready),
      .s_axi_bresp(bresp),
      .s_axi_arvalid(arvalid),
      .s_axi_arready(arready),
      .s_axi_araddr(araddr),
      .s_axi_arprot(arprot),
      .s_axi_rvalid(rvalid),
      .s_axi_rready(rready),
      .s_axi_rdata(rdata),
      .s_axi_rresp(rresp)
  );

  assign led[0] = phy_reset_n;
  assign led[1] = mmcm_locked;
  assign led[2] = phy_rx_ctl;
  assign led[3] = rst_n;
  assign led[7:4] = 4'd0;

endmodule

`default_nettype wire
