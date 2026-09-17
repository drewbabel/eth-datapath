`default_nettype none

module uart_axil #(
    parameter int CLK_FREQ_HZ = 125_000_000,
    parameter int BAUD_RATE   = 115_200,
    parameter int ADDR_WIDTH  = 5,
    parameter int DATA_WIDTH  = 32
) (
    input logic clk,
    input logic rst_n,

    // Serial pins
    input  logic rx_serial,
    output logic tx_serial,

    // Write address
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,
    output logic [  ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [             2:0] m_axi_awprot,
    // Write data
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,
    output logic [  DATA_WIDTH-1:0] m_axi_wdata,
    output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
    // Write response
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,
    // Read address
    output logic                    m_axi_arvalid,
    input  logic                    m_axi_arready,
    output logic [  ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [             2:0] m_axi_arprot,
    // Read data
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready,
    input  logic [  DATA_WIDTH-1:0] m_axi_rdata
);

  localparam int NumBytes = DATA_WIDTH / 8;
  localparam logic [7:0] CmdRead = 8'h52;  // Letter R
  localparam logic [7:0] CmdWrite = 8'h57;  // Letter W
  localparam logic [7:0] WriteAck = 8'h4B;  // Letter K

  logic [7:0] rx_byte;
  logic       rx_valid;
  logic [7:0] tx_byte;
  logic       tx_valid;
  logic       tx_ready;

  uart #(
      .CLK_FREQ_HZ(CLK_FREQ_HZ),
      .BAUD_RATE  (BAUD_RATE)
  ) u_uart (
      .clk(clk),
      .rst_n(rst_n),
      .tx_data(tx_byte),
      .tx_valid(tx_valid),
      .tx_ready(tx_ready),
      .tx_serial(tx_serial),
      .rx_serial(rx_serial),
      .rx_data(rx_byte),
      .rx_valid(rx_valid),
      .rx_error()
  );

  typedef enum logic [2:0] {
    GET_CMD,
    GET_ADDR,
    GET_DATA,
    DO_WRITE,
    DO_READ,
    SEND
  } state_t;

  state_t state;

  logic                  is_read;
  logic [ADDR_WIDTH-1:0] addr;
  logic [DATA_WIDTH-1:0] shift;
  logic [           2:0] count;
  logic [           2:0] send_len;

  assign m_axi_awaddr = addr;
  assign m_axi_awprot = 3'b000;
  assign m_axi_wdata  = shift;
  assign m_axi_wstrb  = '1;
  assign m_axi_bready = 1'b1;
  assign m_axi_araddr = addr;
  assign m_axi_arprot = 3'b000;
  assign m_axi_rready = 1'b1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= GET_CMD;
      m_axi_awvalid <= 1'b0;
      m_axi_wvalid <= 1'b0;
      m_axi_arvalid <= 1'b0;
      tx_valid <= 1'b0;
      count <= '0;
      send_len <= '0;
      is_read <= 1'b0;
      addr <= '0;
      shift <= '0;
      tx_byte <= '0;
    end else begin
      case (state)
        GET_CMD: begin
          count <= '0;
          if (rx_valid && rx_byte == CmdRead) begin
            is_read <= 1'b1;
            state   <= GET_ADDR;
          end else if (rx_valid && rx_byte == CmdWrite) begin
            is_read <= 1'b0;
            state   <= GET_ADDR;
          end
        end

        GET_ADDR: begin
          if (rx_valid) begin
            addr <= rx_byte[ADDR_WIDTH-1:0];
            if (is_read) begin
              m_axi_arvalid <= 1'b1;
              state <= DO_READ;
            end else begin
              state <= GET_DATA;
            end
          end
        end

        // Least byte first
        GET_DATA: begin
          if (rx_valid) begin
            shift <= {rx_byte, shift[DATA_WIDTH-1:8]};
            count <= count + 3'd1;
            if (count == 3'(NumBytes - 1)) begin
              m_axi_awvalid <= 1'b1;
              m_axi_wvalid  <= 1'b1;
              state         <= DO_WRITE;
            end
          end
        end

        DO_WRITE: begin
          if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 1'b0;
          if (m_axi_wvalid && m_axi_wready) m_axi_wvalid <= 1'b0;
          if (m_axi_bvalid) begin
            shift    <= {{(DATA_WIDTH - 8) {1'b0}}, WriteAck};
            send_len <= 3'd1;
            count    <= '0;
            state    <= SEND;
          end
        end

        DO_READ: begin
          if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 1'b0;
          if (m_axi_rvalid) begin
            shift    <= m_axi_rdata;
            send_len <= 3'(NumBytes);
            count    <= '0;
            state    <= SEND;
          end
        end

        SEND: begin
          if (!tx_valid && tx_ready) begin
            tx_valid <= 1'b1;
            tx_byte  <= shift[7:0];
          end else if (tx_valid && tx_ready) begin
            tx_valid <= 1'b0;
            shift    <= {8'h00, shift[DATA_WIDTH-1:8]};
            count    <= count + 3'd1;
            if (count == send_len - 3'd1) state <= GET_CMD;
          end
        end

        default: state <= GET_CMD;
      endcase
    end
  end

endmodule

`default_nettype wire
