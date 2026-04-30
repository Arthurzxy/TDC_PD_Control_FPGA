//==============================================================================
// pixel_param_ram.v
// 36-bit pixel parameter RAM model for behavioral simulation.
//==============================================================================

`timescale 1ns/1ps

module pixel_param_ram_36b (
    input  wire        clka,
    input  wire        wea,
    input  wire [13:0] addra,
    input  wire [35:0] dina,
    output wire [35:0] douta,
    input  wire        clkb,
    input  wire        enb,
    input  wire        web,
    input  wire [13:0] addrb,
    input  wire [35:0] dinb,
    output reg  [35:0] doutb
);

    reg [35:0] mem [0:16383];
    integer i;

    initial begin
        for (i = 0; i < 16384; i = i + 1)
            mem[i] = 36'd0;
    end

    always @(posedge clka) begin
        if (wea)
            mem[addra] <= dina;
    end

    assign douta = 36'd0;

    always @(posedge clkb) begin
        if (enb) begin
            if (web)
                mem[addrb] <= dinb;
            doutb <= mem[addrb];
        end
    end

endmodule
