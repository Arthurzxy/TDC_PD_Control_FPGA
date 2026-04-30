`timescale 1ns/1ps

module event_merger #(
    parameter integer DETECTOR_WAIT_CYCLES = 8
)(
    input  wire clk,
    input  wire rst,

    input  wire        ch0_valid,
    input  wire [127:0] ch0_data,
    output wire        ch0_ready,
    input  wire        ch1_valid,
    input  wire [127:0] ch1_data,
    output wire        ch1_ready,
    input  wire        ch2_valid,
    input  wire [127:0] ch2_data,
    output wire        ch2_ready,
    input  wire        ch3_valid,
    input  wire [127:0] ch3_data,
    output wire        ch3_ready,

    output reg         out_valid,
    output reg [127:0] out_data,
    input  wire        out_ready
);

    wire [63:0] ts0 = ch0_data[125:62];
    wire [63:0] ts1 = ch1_data[125:62];
    wire [63:0] ts2 = ch2_data[125:62];
    wire [63:0] ts3 = ch3_data[125:62];

    reg [1:0] sel;
    reg sel_valid;
    reg [31:0] det_wait_cnt;

    wire det_is_oldest =
        ch0_valid &&
        (!ch1_valid || (ts0 < ts1) || (ts0 == ts1)) &&
        (!ch2_valid || (ts0 < ts2) || (ts0 == ts2)) &&
        (!ch3_valid || (ts0 < ts3) || (ts0 == ts3));

    wire hold_detector =
        det_is_oldest &&
        (!(ch1_valid || ch2_valid || ch3_valid)) &&
        (det_wait_cnt < DETECTOR_WAIT_CYCLES);

    assign ch0_ready = out_ready && sel_valid && (sel == 2'd0);
    assign ch1_ready = out_ready && sel_valid && (sel == 2'd1);
    assign ch2_ready = out_ready && sel_valid && (sel == 2'd2);
    assign ch3_ready = out_ready && sel_valid && (sel == 2'd3);

    always @(*) begin
        sel_valid = 1'b0;
        sel       = 2'd0;
        out_valid = 1'b0;
        out_data  = 128'd0;

        if (!rst && !hold_detector) begin
            if (ch1_valid &&
                (!ch2_valid || (ts1 < ts2) || ((ts1 == ts2))) &&
                (!ch3_valid || (ts1 < ts3) || ((ts1 == ts3))) &&
                (!ch0_valid || (ts1 < ts0) || ((ts1 == ts0)))) begin
                sel_valid = 1'b1;
                sel = 2'd1;
            end else if (ch2_valid &&
                (!ch3_valid || (ts2 < ts3) || ((ts2 == ts3))) &&
                (!ch0_valid || (ts2 < ts0) || ((ts2 == ts0)))) begin
                sel_valid = 1'b1;
                sel = 2'd2;
            end else if (ch3_valid &&
                (!ch0_valid || (ts3 < ts0) || ((ts3 == ts0)))) begin
                sel_valid = 1'b1;
                sel = 2'd3;
            end else if (ch0_valid) begin
                sel_valid = 1'b1;
                sel = 2'd0;
            end
        end

        if (!rst) begin
            out_valid = sel_valid;
            case (sel)
                2'd0: out_data = ch0_data;
                2'd1: out_data = ch1_data;
                2'd2: out_data = ch2_data;
                default: out_data = ch3_data;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            det_wait_cnt <= 32'd0;
        end else begin
            if (det_is_oldest && !sel_valid)
                det_wait_cnt <= det_wait_cnt + 1'b1;
            else if (sel_valid && (sel == 2'd0) && out_ready)
                det_wait_cnt <= 32'd0;
            else if (!det_is_oldest)
                det_wait_cnt <= 32'd0;
        end
    end

endmodule
