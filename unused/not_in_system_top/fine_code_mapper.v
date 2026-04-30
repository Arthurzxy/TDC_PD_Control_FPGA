//==============================================================================
// fine_code_mapper.v
// Map 500ps fine substep codes to ODELAYE2 tap values.
//==============================================================================

`timescale 1ns/1ps

module fine_code_mapper (
    input  wire [2:0] fine_sel,
    output reg  [4:0] tap_code
);
    always @(*) begin
        case (fine_sel)
            3'd0: tap_code = 5'd0;
            3'd1: tap_code = 5'd6;
            3'd2: tap_code = 5'd13;
            3'd3: tap_code = 5'd19;
            3'd4: tap_code = 5'd26;
            default: tap_code = 5'd26;
        endcase
    end
endmodule
