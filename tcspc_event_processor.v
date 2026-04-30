`timescale 1ns/1ps

module tcspc_event_processor #(
    parameter integer DT_MIN = 0,
    parameter integer DT_MAX = 12500,
    parameter integer BIN_SHIFT = 3
)(
    input  wire clk,
    input  wire rst,

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [127:0] in_event,

    output reg         photon_valid,
    input  wire        photon_ready,
    output reg [127:0] photon_event,

    output reg [31:0] laser_count,
    output reg [31:0] detector_count,
    output reg [31:0] photon_valid_count,
    output reg [31:0] dt_overflow_count,
    output reg [31:0] no_laser_count,
    output reg [31:0] line_count,
    output reg [31:0] pixel_count
);

    localparam [1:0] CH_DETECTOR = 2'd0;
    localparam [1:0] CH_LASER    = 2'd1;
    localparam [1:0] CH_LINE     = 2'd2;
    localparam [1:0] CH_PIXEL    = 2'd3;

    wire photon_slot_ready = !photon_valid || photon_ready;

    wire [1:0]  ch = in_event[127:126];
    wire [63:0] timestamp = in_event[125:62];

    localparam [63:0] DT_MIN_TICKS = DT_MIN;
    localparam [63:0] DT_MAX_TICKS = DT_MAX;

    reg [63:0] last_laser_timestamp;
    reg        last_laser_valid;
    reg [15:0] line_id;
    reg [15:0] pixel_id;
    reg [7:0]  frame_id;

    reg        det_pending;
    reg        det_laser_valid;
    reg        det_time_before_laser;
    reg [63:0] det_dt_8ps_wide;
    reg [63:0] det_timestamp;
    reg [15:0] det_line_id;
    reg [15:0] det_pixel_id;
    reg [7:0]  det_frame_id;

    wire [31:0] det_dt_8ps = det_dt_8ps_wide[31:0];
    wire [15:0] det_bin_index = (det_dt_8ps_wide - DT_MIN_TICKS) >> BIN_SHIFT;

    assign in_ready = !det_pending && photon_slot_ready;

    always @(posedge clk) begin
        if (rst) begin
            photon_valid         <= 1'b0;
            photon_event         <= 128'd0;
            last_laser_timestamp <= 64'd0;
            last_laser_valid     <= 1'b0;
            line_id              <= 16'd0;
            pixel_id             <= 16'd0;
            frame_id             <= 8'd0;
            det_pending          <= 1'b0;
            det_laser_valid      <= 1'b0;
            det_time_before_laser <= 1'b0;
            det_dt_8ps_wide      <= 64'd0;
            det_timestamp        <= 64'd0;
            det_line_id          <= 16'd0;
            det_pixel_id         <= 16'd0;
            det_frame_id         <= 8'd0;
            laser_count          <= 32'd0;
            detector_count       <= 32'd0;
            photon_valid_count   <= 32'd0;
            dt_overflow_count    <= 32'd0;
            no_laser_count       <= 32'd0;
            line_count           <= 32'd0;
            pixel_count          <= 32'd0;
        end else begin
            if (photon_valid && photon_ready)
                photon_valid <= 1'b0;

            if (det_pending && photon_slot_ready) begin
                det_pending <= 1'b0;
                if (!det_laser_valid) begin
                    no_laser_count <= no_laser_count + 1'b1;
                end else if (det_time_before_laser ||
                             (det_dt_8ps_wide < DT_MIN_TICKS) ||
                             (det_dt_8ps_wide >= DT_MAX_TICKS)) begin
                    dt_overflow_count <= dt_overflow_count + 1'b1;
                end else begin
                    photon_event <= {
                        8'h01,
                        det_frame_id,
                        det_line_id,
                        det_pixel_id,
                        det_bin_index,
                        det_dt_8ps,
                        det_timestamp[31:0]
                    };
                    photon_valid       <= 1'b1;
                    photon_valid_count <= photon_valid_count + 1'b1;
                end
            end

            if (in_valid && in_ready) begin
                case (ch)
                    CH_LASER: begin
                        last_laser_timestamp <= timestamp;
                        last_laser_valid     <= 1'b1;
                        laser_count          <= laser_count + 1'b1;
                    end

                    CH_LINE: begin
                        line_id    <= line_id + 1'b1;
                        pixel_id   <= 16'd0;
                        line_count <= line_count + 1'b1;
                    end

                    CH_PIXEL: begin
                        pixel_id    <= pixel_id + 1'b1;
                        pixel_count <= pixel_count + 1'b1;
                    end

                    default: begin
                        detector_count <= detector_count + 1'b1;
                        det_pending           <= 1'b1;
                        det_laser_valid       <= last_laser_valid;
                        det_time_before_laser <= timestamp < last_laser_timestamp;
                        det_dt_8ps_wide       <= timestamp - last_laser_timestamp;
                        det_timestamp         <= timestamp;
                        det_line_id           <= line_id;
                        det_pixel_id          <= pixel_id;
                        det_frame_id          <= frame_id;
                    end
                endcase
            end
        end
    end

endmodule
