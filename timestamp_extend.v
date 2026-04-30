`timescale 1ns/1ps

module timestamp_extend #(
    parameter integer REFCLK_DIVISIONS = 12500,
    parameter integer EXT_REF_BITS = 48
)(
    input  wire clk,
    input  wire rst,

    input  wire        raw_valid,
    output wire        raw_ready,
    input  wire [31:0] raw_event,

    output reg         ext_valid,
    input  wire        ext_ready,
    output reg [127:0] ext_event
);

    localparam [15:0] WRAP_NEG_THRESH = 16'hC000;
    localparam [15:0] WRAP_POS_THRESH = 16'h4000;

    reg [15:0] prev_ref [0:3];
    reg [EXT_REF_BITS-17:0] epoch [0:3];
    reg seen [0:3];

    wire accept = raw_valid && raw_ready;
    assign raw_ready = !ext_valid || ext_ready;

    wire [1:0]  ch          = raw_event[31:30];
    wire [15:0] ref_index   = raw_event[29:14];
    wire [13:0] stop_result = raw_event[13:0];

    reg [EXT_REF_BITS-1:0] ext_ref;
    reg [63:0] full_ts;
    reg [EXT_REF_BITS-17:0] next_epoch;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            ext_valid <= 1'b0;
            ext_event <= 128'd0;
            for (i = 0; i < 4; i = i + 1) begin
                prev_ref[i] <= 16'd0;
                epoch[i]    <= {EXT_REF_BITS-16{1'b0}};
                seen[i]     <= 1'b0;
            end
        end else begin
            if (ext_valid && ext_ready)
                ext_valid <= 1'b0;

            if (accept) begin
                next_epoch = epoch[ch];
                if (seen[ch]) begin
                    if ((prev_ref[ch] > WRAP_NEG_THRESH) && (ref_index < WRAP_POS_THRESH))
                        next_epoch = epoch[ch] + 1'b1;
                end

                prev_ref[ch] <= ref_index;
                epoch[ch]    <= next_epoch;
                seen[ch]     <= 1'b1;

                ext_ref = {next_epoch, ref_index};
                full_ts = (ext_ref * REFCLK_DIVISIONS) + stop_result;

                ext_event <= {
                    ch,
                    full_ts,
                    ref_index,
                    stop_result,
                    32'd0
                };
                ext_valid <= 1'b1;
            end
        end
    end

endmodule
