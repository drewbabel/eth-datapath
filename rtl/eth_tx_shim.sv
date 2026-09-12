`default_nettype none

module eth_tx_shim (
    // Switch master
    input  logic       s_tvalid,
    output logic       s_tready,
    input  logic [8:0] s_tdata,
    input  logic       s_tlast,
    // Controller transmit
    output logic [7:0] tx_axis_tdata,
    output logic       tx_axis_tvalid,
    input  logic       tx_axis_tready,
    output logic       tx_axis_tlast,
    output logic       tx_axis_tuser
);

  assign tx_axis_tdata  = s_tdata[7:0];
  assign tx_axis_tvalid = s_tvalid;
  assign tx_axis_tlast  = s_tlast;

  // Sampled at tlast
  assign tx_axis_tuser  = s_tdata[8] && s_tlast;

  assign s_tready       = tx_axis_tready;

endmodule

`default_nettype wire
