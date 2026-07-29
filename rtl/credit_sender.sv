`default_nettype none

module credit_sender #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             src_valid,
    input  logic [WIDTH-1:0] src_data,
    output logic             src_ready,
    output logic             tx_valid,
    output logic [WIDTH-1:0] tx_data,
    input  logic             credit_return
`ifdef FORMAL
    ,
    output logic [$clog2(DEPTH+1)-1:0] f_credits
`endif
);

  localparam int CW = $clog2(DEPTH + 1);  // Credit width

  logic [CW-1:0] credits;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      credits <= ($bits(credits))'(DEPTH);
    end else begin
      // Simultaneous events net zero
      if (src_valid && src_ready) begin
        if (!credit_return) credits <= credits - 1;
      end else if (credit_return) credits <= credits + 1;
    end
  end

  assign src_ready = (credits != 0);
  assign tx_valid  = (src_valid && src_ready);
  assign tx_data   = src_data;

`ifdef FORMAL

  assign f_credits = credits;

  always @(posedge clk) if (rst_n) assert (credits <= DEPTH);

`endif

endmodule

`default_nettype wire
