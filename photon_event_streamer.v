`timescale 1ns/1ps

module photon_event_streamer (
    input  wire clk,
    input  wire rst,

    input  wire         photon_valid,
    output wire         photon_ready,
    input  wire [127:0] photon_event,

    output reg          out_valid,
    output reg  [31:0]  out_data,
    input  wire         out_ready,
    output reg          out_last
);

    localparam ST_IDLE = 1'b0;
    localparam ST_SEND = 1'b1;

    reg state;
    reg [2:0] word_idx;
    reg [127:0] event_lat;

    wire fire = out_valid && out_ready;
    assign photon_ready = (state == ST_IDLE);

    function [31:0] event_word;
        input [127:0] ev;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: event_word = 32'hA55A_F00D;
                3'd1: event_word = {ev[127:120], ev[119:112], ev[111:96]};
                3'd2: event_word = {ev[95:80], ev[79:64]};
                3'd3: event_word = ev[63:32];
                default: event_word = ev[31:0];
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state     <= ST_IDLE;
            word_idx  <= 3'd0;
            event_lat <= 128'd0;
            out_valid <= 1'b0;
            out_data  <= 32'd0;
            out_last  <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    out_valid <= 1'b0;
                    out_last  <= 1'b0;
                    word_idx  <= 3'd0;
                    if (photon_valid) begin
                        event_lat <= photon_event;
                        out_data  <= 32'hA55A_F00D;
                        out_valid <= 1'b1;
                        out_last  <= 1'b0;
                        state     <= ST_SEND;
                    end
                end

                ST_SEND: begin
                    if (fire) begin
                        if (word_idx == 3'd4) begin
                            out_valid <= 1'b0;
                            out_last  <= 1'b0;
                            state     <= ST_IDLE;
                        end else begin
                            word_idx  <= word_idx + 1'b1;
                            out_data  <= event_word(event_lat, word_idx + 1'b1);
                            out_last  <= (word_idx == 3'd3);
                            out_valid <= 1'b1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
