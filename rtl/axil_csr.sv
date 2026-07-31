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


endmodule

`default_nettype wire
