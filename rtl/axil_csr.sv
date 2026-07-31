`default_nettype none

module axil_csr #(
    parameter int ADDR_WIDTH = 4,
    parameter int DATA_WIDTH = 32
) (
    input  logic                    clk,
    input  logic                    rst_n,
    // Write address
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready = 1'b0,
    input  logic [  ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [             2:0] s_axi_awprot,          // Permission bit
    // Write data
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready = 1'b0,
    input  logic [  DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    // Write response
    output logic                    s_axi_bvalid = 1'b0,
    input  logic                    s_axi_bready,
    output logic [             1:0] s_axi_bresp,
    // Read address
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready = 1'b0,
    input  logic [  ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [             2:0] s_axi_arprot,          // Permission bit
    // Read data
    output logic                    s_axi_rvalid = 1'b0,
    input  logic                    s_axi_rready,
    output logic [  DATA_WIDTH-1:0] s_axi_rdata,
    output logic [             1:0] s_axi_rresp
);

  localparam int NumRegs = 4;
  localparam int Lsb = $clog2(DATA_WIDTH / 8);  // Byte lane bits
  localparam int IdxWidth = ADDR_WIDTH - Lsb;

  logic [DATA_WIDTH-1:0] regs     [NumRegs];

  logic [  IdxWidth-1:0] wr_index;
  logic [  IdxWidth-1:0] rd_index;

  logic                  wr_xfer;
  logic                  rd_xfer;

  assign wr_index = s_axi_awaddr[IdxWidth+Lsb-1:Lsb];
  assign rd_index = s_axi_araddr[IdxWidth+Lsb-1:Lsb];

  assign s_axi_bresp = 2'b00;
  assign s_axi_rresp = 2'b00;

  assign wr_xfer = s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid;
  assign rd_xfer = s_axi_arready && s_axi_arvalid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;
    end else begin
      s_axi_awready <= !s_axi_awready && s_axi_awvalid && s_axi_wvalid
          && (!s_axi_bvalid || s_axi_bready);
      s_axi_wready <= !s_axi_wready && s_axi_awvalid && s_axi_wvalid
          && (!s_axi_bvalid || s_axi_bready);
      s_axi_arready <= !s_axi_arready && s_axi_arvalid && (!s_axi_rvalid || s_axi_rready);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axi_bvalid <= 1'b0;
      s_axi_rvalid <= 1'b0;
    end else begin
      if (wr_xfer) s_axi_bvalid <= 1'b1;
      else if (s_axi_bready) s_axi_bvalid <= 1'b0;

      if (rd_xfer) s_axi_rvalid <= 1'b1;
      else if (s_axi_rready) s_axi_rvalid <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (wr_xfer) begin
      for (int i = 0; i < $bits(s_axi_wstrb); i++) begin
        if (s_axi_wstrb[i]) regs[wr_index][(i*8)+:8] <= s_axi_wdata[(i*8)+:8];
      end
    end
    if (rd_xfer) s_axi_rdata <= regs[rd_index];
  end

`ifdef FORMAL

  localparam int LgDepth = 4;

  logic [LgDepth-1:0] f_axi_awr_outstanding;
  logic [LgDepth-1:0] f_axi_wr_outstanding;
  logic [LgDepth-1:0] f_axi_rd_outstanding;

  logic f_past_valid = 1'b0;
  logic wr_done;
  logic rd_done;

  assign wr_done = s_axi_bvalid && s_axi_bready;
  assign rd_done = s_axi_rvalid && s_axi_rready;

  always_ff @(posedge clk) f_past_valid <= 1'b1;

  initial begin
    assume (!rst_n);
    assume (s_axi_awvalid == 0);
    assume (s_axi_wvalid == 0);
    assume (s_axi_arvalid == 0);
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cover (wr_done);
      cover (rd_done);
      cover (wr_done && rd_done);  // Same cycle
      if (f_past_valid) begin
        cover (s_axi_rvalid && $past(rd_xfer) && $past(rd_index) == f_index);  // Tracked read
      end
    end
  end

  // Solver chosen register
  (* anyconst *) logic [IdxWidth-1:0] f_index;
  logic [DATA_WIDTH-1:0] f_shadow;

  always_ff @(posedge clk) begin
    if (wr_xfer && wr_index == f_index) begin
      for (int i = 0; i < $bits(s_axi_wstrb); i++) begin
        if (s_axi_wstrb[i]) f_shadow[(i*8)+:8] <= s_axi_wdata[(i*8)+:8];
      end
    end
  end

  initial assume (f_shadow == regs[f_index]);

  always @(posedge clk) begin
    assert (f_shadow == regs[f_index]);
    if (f_past_valid && s_axi_rvalid && $past(rd_xfer) && $past(rd_index) == f_index) begin
      assert (s_axi_rdata == $past(f_shadow));
    end
  end

  faxil_slave #(
      .C_AXI_ADDR_WIDTH(ADDR_WIDTH),
      .C_AXI_DATA_WIDTH(DATA_WIDTH),
      .F_LGDEPTH(LgDepth),
      .F_OPT_BRESP(1'b0),
      .F_OPT_RRESP(1'b0),
      .F_AXI_MAXWAIT(2),
      .F_AXI_MAXDELAY(1),
      .F_AXI_MAXRSTALL(0)
  ) u_faxil (
      .i_clk(clk),
      .i_axi_reset_n(rst_n),
      .i_axi_awvalid(s_axi_awvalid),
      .i_axi_awready(s_axi_awready),
      .i_axi_awaddr(s_axi_awaddr),
      .i_axi_awprot(s_axi_awprot),
      .i_axi_wvalid(s_axi_wvalid),
      .i_axi_wready(s_axi_wready),
      .i_axi_wdata(s_axi_wdata),
      .i_axi_wstrb(s_axi_wstrb),
      .i_axi_bvalid(s_axi_bvalid),
      .i_axi_bready(s_axi_bready),
      .i_axi_bresp(s_axi_bresp),
      .i_axi_arvalid(s_axi_arvalid),
      .i_axi_arready(s_axi_arready),
      .i_axi_araddr(s_axi_araddr),
      .i_axi_arprot(s_axi_arprot),
      .i_axi_rvalid(s_axi_rvalid),
      .i_axi_rready(s_axi_rready),
      .i_axi_rdata(s_axi_rdata),
      .i_axi_rresp(s_axi_rresp),
      .f_axi_awr_outstanding(f_axi_awr_outstanding),
      .f_axi_wr_outstanding(f_axi_wr_outstanding),
      .f_axi_rd_outstanding(f_axi_rd_outstanding)
  );

`endif

endmodule

`default_nettype wire
