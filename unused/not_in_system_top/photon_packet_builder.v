`timescale 1ns/1ps

module photon_packet_builder #(
    parameter integer DATA_WIDTH = 32,
    parameter integer EVENTS_PER_PKT = 16,
    parameter integer COLLECT_TIMEOUT_CYC = 1024
)(
    input  wire clk,
    input  wire rst,

    input  wire                  event_valid,
    output wire                  event_ready,
    input  wire [DATA_WIDTH-1:0] event_data,
    input  wire                  event_last,

    input  wire                  status_valid,
    input  wire [15:0]           status_flags,
    input  wire [31:0]           uptime_seconds,
    input  wire [15:0]           temp_avg,
    input  wire [31:0]           counter_1s,
    input  wire [31:0]           tdc_drop_count,
    input  wire [31:0]           usb_drop_count,

    output reg  [DATA_WIDTH-1:0] tx_data,
    output reg  [3:0]            tx_be,
    output reg                   tx_valid,
    input  wire                  tx_ready
);

    localparam [7:0] SYNC_BYTE  = 8'hA5;
    localparam [7:0] PROTO_VER  = 8'h01;
    localparam [7:0] HDR_WORDS  = 8'd4;
    localparam [7:0] PKT_STATUS = 8'h02;
    localparam [7:0] PKT_PHOTON = 8'h04;

    localparam integer MAX_WORDS = EVENTS_PER_PKT * 5;

    localparam ST_IDLE        = 4'd0;
    localparam ST_COLLECT     = 4'd1;
    localparam ST_PH_HDR0     = 4'd2;
    localparam ST_PH_HDR1     = 4'd3;
    localparam ST_PH_HDR2     = 4'd4;
    localparam ST_PH_HDR3     = 4'd5;
    localparam ST_PH_PAYLOAD  = 4'd6;
    localparam ST_ST_HDR0     = 4'd7;
    localparam ST_ST_HDR1     = 4'd8;
    localparam ST_ST_HDR2     = 4'd9;
    localparam ST_ST_HDR3     = 4'd10;
    localparam ST_ST_PAYLOAD  = 4'd11;

    reg [3:0] state;
    reg [31:0] us_counter;
    reg [15:0] pkt_seq;
    reg [15:0] payload_words;
    reg [15:0] item_count;
    reg [15:0] pkt_flags;
    reg [31:0] pkt_timestamp_us;
    reg [15:0] collect_timeout;
    reg [15:0] wr_count;
    reg [15:0] tx_idx;
    reg [2:0] status_idx;

    reg [31:0] mem [0:MAX_WORDS-1];

    reg status_pending;
    reg [15:0] status_flags_lat;
    reg [31:0] uptime_seconds_lat;
    reg [15:0] temp_avg_lat;
    reg [31:0] counter_1s_lat;
    reg [31:0] tdc_drop_count_lat;
    reg [31:0] usb_drop_count_lat;

    wire tx_fire = tx_valid && tx_ready;
    wire collecting = (state == ST_IDLE) || (state == ST_COLLECT);
    assign event_ready = collecting && !status_pending && (wr_count < MAX_WORDS);

    always @(posedge clk) begin
        if (rst) begin
            state              <= ST_IDLE;
            tx_data            <= 32'd0;
            tx_be              <= 4'hF;
            tx_valid           <= 1'b0;
            us_counter         <= 32'd0;
            pkt_seq            <= 16'd0;
            payload_words      <= 16'd0;
            item_count         <= 16'd0;
            pkt_flags          <= 16'd0;
            pkt_timestamp_us   <= 32'd0;
            collect_timeout    <= 16'd0;
            wr_count           <= 16'd0;
            tx_idx             <= 16'd0;
            status_idx         <= 3'd0;
            status_pending     <= 1'b0;
            status_flags_lat   <= 16'd0;
            uptime_seconds_lat <= 32'd0;
            temp_avg_lat       <= 16'd0;
            counter_1s_lat     <= 32'd0;
            tdc_drop_count_lat <= 32'd0;
            usb_drop_count_lat <= 32'd0;
        end else begin
            tx_be      <= 4'hF;
            us_counter <= us_counter + 1'b1;

            if (status_valid) begin
                status_pending     <= 1'b1;
                status_flags_lat   <= status_flags;
                uptime_seconds_lat <= uptime_seconds;
                temp_avg_lat       <= temp_avg;
                counter_1s_lat     <= counter_1s;
                tdc_drop_count_lat <= tdc_drop_count;
                usb_drop_count_lat <= usb_drop_count;
            end

            if (tx_fire)
                tx_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    wr_count        <= 16'd0;
                    collect_timeout <= 16'd0;
                    if (status_pending) begin
                        pkt_seq          <= pkt_seq + 1'b1;
                        pkt_timestamp_us <= us_counter;
                        payload_words    <= 16'd6;
                        item_count       <= 16'd6;
                        pkt_flags        <= 16'd0;
                        status_idx       <= 3'd0;
                        status_pending   <= 1'b0;
                        state            <= ST_ST_HDR0;
                    end else if (event_valid && event_ready) begin
                        mem[0]           <= event_data;
                        wr_count         <= 16'd1;
                        pkt_timestamp_us <= us_counter;
                        state            <= ST_COLLECT;
                    end
                end

                ST_COLLECT: begin
                    if (event_valid && event_ready) begin
                        mem[wr_count] <= event_data;
                        wr_count      <= wr_count + 1'b1;
                    end

                    if ((event_valid && event_ready && event_last && (wr_count + 1 >= MAX_WORDS)) ||
                        ((collect_timeout >= COLLECT_TIMEOUT_CYC) && (wr_count != 16'd0) && ((wr_count % 5) == 0))) begin
                        pkt_seq       <= pkt_seq + 1'b1;
                        payload_words <= event_valid && event_ready ? (wr_count + 1'b1) : wr_count;
                        item_count    <= (event_valid && event_ready ? (wr_count + 1'b1) : wr_count) / 5;
                        pkt_flags     <= 16'd0;
                        tx_idx        <= 16'd0;
                        state         <= ST_PH_HDR0;
                    end else begin
                        collect_timeout <= collect_timeout + 1'b1;
                    end
                end

                ST_PH_HDR0: if (!tx_valid || tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= {SYNC_BYTE, PKT_PHOTON, PROTO_VER, HDR_WORDS};
                    state    <= ST_PH_HDR1;
                end
                ST_PH_HDR1: if (!tx_valid || tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= {pkt_seq, payload_words};
                    state    <= ST_PH_HDR2;
                end
                ST_PH_HDR2: if (!tx_valid || tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= {item_count, pkt_flags};
                    state    <= ST_PH_HDR3;
                end
                ST_PH_HDR3: if (!tx_valid || tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= pkt_timestamp_us;
                    tx_idx   <= 16'd0;
                    state    <= ST_PH_PAYLOAD;
                end
                ST_PH_PAYLOAD: if (!tx_valid || tx_ready) begin
                    if (tx_idx < payload_words) begin
                        tx_valid <= 1'b1;
                        tx_data  <= mem[tx_idx];
                        tx_idx   <= tx_idx + 1'b1;
                    end else begin
                        wr_count <= 16'd0;
                        state    <= ST_IDLE;
                    end
                end

                ST_ST_HDR0: if (!tx_valid || tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= {SYNC_BYTE, PKT_STATUS, PROTO_VER, HDR_WORDS};
                    state    <= ST_ST_HDR1;
                end
                ST_ST_HDR1: if (!tx_valid || tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= {pkt_seq, payload_words};
                    state    <= ST_ST_HDR2;
                end
                ST_ST_HDR2: if (!tx_valid || tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= {item_count, pkt_flags};
                    state    <= ST_ST_HDR3;
                end
                ST_ST_HDR3: if (!tx_valid || tx_ready) begin
                    tx_valid <= 1'b1;
                    tx_data  <= pkt_timestamp_us;
                    status_idx <= 3'd0;
                    state    <= ST_ST_PAYLOAD;
                end
                ST_ST_PAYLOAD: if (!tx_valid || tx_ready) begin
                    if (status_idx < 3'd6) begin
                        tx_valid <= 1'b1;
                        case (status_idx)
                            3'd0: tx_data <= {16'd0, status_flags_lat};
                            3'd1: tx_data <= uptime_seconds_lat;
                            3'd2: tx_data <= {16'd0, temp_avg_lat};
                            3'd3: tx_data <= counter_1s_lat;
                            3'd4: tx_data <= tdc_drop_count_lat;
                            default: tx_data <= usb_drop_count_lat;
                        endcase
                        status_idx <= status_idx + 1'b1;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
