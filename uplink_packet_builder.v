`timescale 1ns/1ps

module uplink_packet_builder #(
    parameter integer DATA_WIDTH = 32,
    parameter integer PHOTON_EVENTS_PER_PKT = 16,
    parameter integer COLLECT_TIMEOUT_CYC = 1024
)(
    input  wire                  clk,
    input  wire                  rst,

    input  wire                  photon_valid,
    output wire                  photon_ready,
    input  wire [DATA_WIDTH-1:0] photon_data,
    input  wire                  photon_last,

    input  wire                  status_valid,
    input  wire [15:0]           status_flags,
    input  wire [31:0]           uptime_seconds,
    input  wire [15:0]           temp_avg,
    input  wire [31:0]           counter_1s,
    input  wire [31:0]           tdc_drop_count,
    input  wire [31:0]           usb_drop_count,

    input  wire                  ack_valid,
    output wire                  ack_ready,
    input  wire [7:0]            ack_cmd_id,
    input  wire [7:0]            ack_status,
    input  wire [31:0]           ack_data,

    output reg  [DATA_WIDTH-1:0] tx_data,
    output reg  [3:0]            tx_be,
    output reg                   tx_valid,
    input  wire                  tx_ready
);

    localparam [7:0] SYNC_BYTE  = 8'hA5;
    localparam [7:0] PROTO_VER  = 8'h01;
    localparam [7:0] HDR_WORDS  = 8'd4;
    localparam [7:0] PKT_STATUS = 8'h02;
    localparam [7:0] PKT_ACK    = 8'h03;
    localparam [7:0] PKT_PHOTON = 8'h04;

    localparam integer PHOTON_WORDS_PER_EVENT = 5;
    localparam integer PHOTON_MAX_WORDS = PHOTON_EVENTS_PER_PKT * PHOTON_WORDS_PER_EVENT;

    localparam ST_IDLE        = 5'd0;
    localparam ST_PH_HDR0     = 5'd1;
    localparam ST_PH_HDR1     = 5'd2;
    localparam ST_PH_HDR2     = 5'd3;
    localparam ST_PH_HDR3     = 5'd4;
    localparam ST_PH_PAYLOAD  = 5'd5;
    localparam ST_ST_HDR0     = 5'd6;
    localparam ST_ST_HDR1     = 5'd7;
    localparam ST_ST_HDR2     = 5'd8;
    localparam ST_ST_HDR3     = 5'd9;
    localparam ST_ST_PAYLOAD  = 5'd10;
    localparam ST_ACK_HDR0    = 5'd11;
    localparam ST_ACK_HDR1    = 5'd12;
    localparam ST_ACK_HDR2    = 5'd13;
    localparam ST_ACK_HDR3    = 5'd14;
    localparam ST_ACK_PAYLOAD = 5'd15;

    reg [4:0] state;
    reg [31:0] us_counter;
    reg [15:0] pkt_seq;
    reg [15:0] payload_words;
    reg [15:0] item_count;
    reg [15:0] pkt_flags;
    reg [31:0] pkt_timestamp_us;

    reg [31:0] photon_mem0 [0:PHOTON_MAX_WORDS-1];
    reg [31:0] photon_mem1 [0:PHOTON_MAX_WORDS-1];
    reg        photon_wr_bank;
    reg        photon_rd_bank;
    reg [15:0] photon_wr_count0;
    reg [15:0] photon_wr_count1;
    reg [15:0] photon_tx_count;
    reg [15:0] tx_idx;
    reg [15:0] collect_timeout;
    reg        photon_ready0;
    reg        photon_ready1;
    reg [31:0] photon_ts0;
    reg [31:0] photon_ts1;

    reg status_pending;
    reg [15:0] status_flags_lat;
    reg [31:0] uptime_seconds_lat;
    reg [15:0] temp_avg_lat;
    reg [31:0] counter_1s_lat;
    reg [31:0] tdc_drop_count_lat;
    reg [31:0] usb_drop_count_lat;
    reg [2:0]  status_idx;

    reg ack_pending;
    reg [7:0]  ack_cmd_id_lat;
    reg [7:0]  ack_status_lat;
    reg [31:0] ack_data_lat;
    reg [1:0]  ack_idx;

    wire tx_fire = tx_valid && tx_ready;
    wire [15:0] active_wr_count = photon_wr_bank ? photon_wr_count1 : photon_wr_count0;
    wire active_wr_ready = photon_wr_bank ? photon_ready1 : photon_ready0;
    wire other_bank_free = photon_wr_bank ? (!photon_ready0 && (photon_wr_count0 == 16'd0)) :
                                           (!photon_ready1 && (photon_wr_count1 == 16'd0));
    wire photon_accept = photon_valid && photon_ready;
    wire photon_full_after_accept = photon_accept && ((active_wr_count + 1'b1) >= PHOTON_MAX_WORDS);
    wire photon_timeout_ready = (collect_timeout >= COLLECT_TIMEOUT_CYC) &&
                                (active_wr_count != 16'd0) &&
                                ((active_wr_count % PHOTON_WORDS_PER_EVENT) == 0);

    assign photon_ready = !active_wr_ready && (active_wr_count < PHOTON_MAX_WORDS);
    assign ack_ready = !ack_pending;

    task automatic drive_header;
        input [7:0] pkt_type;
        input [1:0] word_idx;
        begin
            tx_valid <= 1'b1;
            case (word_idx)
                2'd0: tx_data <= {SYNC_BYTE, pkt_type, PROTO_VER, HDR_WORDS};
                2'd1: tx_data <= {pkt_seq, payload_words};
                2'd2: tx_data <= {item_count, pkt_flags};
                default: tx_data <= pkt_timestamp_us;
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state              <= ST_IDLE;
            us_counter         <= 32'd0;
            pkt_seq            <= 16'd0;
            payload_words      <= 16'd0;
            item_count         <= 16'd0;
            pkt_flags          <= 16'd0;
            pkt_timestamp_us   <= 32'd0;
            photon_wr_bank     <= 1'b0;
            photon_rd_bank     <= 1'b0;
            photon_wr_count0   <= 16'd0;
            photon_wr_count1   <= 16'd0;
            photon_tx_count    <= 16'd0;
            tx_idx             <= 16'd0;
            collect_timeout    <= 16'd0;
            photon_ready0      <= 1'b0;
            photon_ready1      <= 1'b0;
            photon_ts0         <= 32'd0;
            photon_ts1         <= 32'd0;
            status_pending     <= 1'b0;
            status_flags_lat   <= 16'd0;
            uptime_seconds_lat <= 32'd0;
            temp_avg_lat       <= 16'd0;
            counter_1s_lat     <= 32'd0;
            tdc_drop_count_lat <= 32'd0;
            usb_drop_count_lat <= 32'd0;
            status_idx         <= 3'd0;
            ack_pending        <= 1'b0;
            ack_cmd_id_lat     <= 8'd0;
            ack_status_lat     <= 8'd0;
            ack_data_lat       <= 32'd0;
            ack_idx            <= 2'd0;
            tx_data            <= {DATA_WIDTH{1'b0}};
            tx_be              <= 4'hF;
            tx_valid           <= 1'b0;
        end else begin
            tx_be <= 4'hF;
            us_counter <= us_counter + 1'b1;

            if (tx_fire)
                tx_valid <= 1'b0;

            if (status_valid) begin
                status_pending     <= 1'b1;
                status_flags_lat   <= status_flags;
                uptime_seconds_lat <= uptime_seconds;
                temp_avg_lat       <= temp_avg;
                counter_1s_lat     <= counter_1s;
                tdc_drop_count_lat <= tdc_drop_count;
                usb_drop_count_lat <= usb_drop_count;
            end

            if (ack_valid && ack_ready) begin
                ack_pending    <= 1'b1;
                ack_cmd_id_lat <= ack_cmd_id;
                ack_status_lat <= ack_status;
                ack_data_lat   <= ack_data;
            end

            if (photon_accept) begin
                if (photon_wr_bank) begin
                    photon_mem1[photon_wr_count1] <= photon_data;
                    photon_wr_count1 <= photon_wr_count1 + 1'b1;
                    if (photon_wr_count1 == 16'd0)
                        photon_ts1 <= us_counter;
                end else begin
                    photon_mem0[photon_wr_count0] <= photon_data;
                    photon_wr_count0 <= photon_wr_count0 + 1'b1;
                    if (photon_wr_count0 == 16'd0)
                        photon_ts0 <= us_counter;
                end
            end

            if (active_wr_count == 16'd0 && !photon_accept)
                collect_timeout <= 16'd0;
            else if (!photon_accept)
                collect_timeout <= collect_timeout + 1'b1;

            if ((photon_full_after_accept || photon_timeout_ready) && !active_wr_ready) begin
                if (photon_wr_bank) begin
                    photon_ready1 <= 1'b1;
                end else begin
                    photon_ready0 <= 1'b1;
                end
                collect_timeout <= 16'd0;
                if (other_bank_free)
                    photon_wr_bank <= ~photon_wr_bank;
            end

            case (state)
                ST_IDLE: begin
                    if (photon_ready0 || photon_ready1) begin
                        photon_rd_bank <= photon_ready0 ? 1'b0 : 1'b1;
                        pkt_seq       <= pkt_seq + 1'b1;
                        photon_tx_count <= photon_ready0 ? photon_wr_count0 : photon_wr_count1;
                        payload_words <= photon_ready0 ? photon_wr_count0 : photon_wr_count1;
                        item_count    <= (photon_ready0 ? photon_wr_count0 : photon_wr_count1) / PHOTON_WORDS_PER_EVENT;
                        pkt_flags     <= 16'd0;
                        pkt_timestamp_us <= photon_ready0 ? photon_ts0 : photon_ts1;
                        tx_idx        <= 16'd0;
                        state         <= ST_PH_HDR0;
                    end else if (ack_pending) begin
                        pkt_seq          <= pkt_seq + 1'b1;
                        pkt_timestamp_us <= us_counter;
                        payload_words    <= 16'd3;
                        item_count       <= 16'd1;
                        pkt_flags        <= 16'd0;
                        ack_idx          <= 2'd0;
                        ack_pending      <= 1'b0;
                        state            <= ST_ACK_HDR0;
                    end else if (status_pending) begin
                        pkt_seq          <= pkt_seq + 1'b1;
                        pkt_timestamp_us <= us_counter;
                        payload_words    <= 16'd6;
                        item_count       <= 16'd1;
                        pkt_flags        <= 16'd0;
                        status_idx       <= 3'd0;
                        status_pending   <= 1'b0;
                        state            <= ST_ST_HDR0;
                    end
                end

                ST_PH_HDR0: if (!tx_valid || tx_ready) begin drive_header(PKT_PHOTON, 2'd0); state <= ST_PH_HDR1; end
                ST_PH_HDR1: if (!tx_valid || tx_ready) begin drive_header(PKT_PHOTON, 2'd1); state <= ST_PH_HDR2; end
                ST_PH_HDR2: if (!tx_valid || tx_ready) begin drive_header(PKT_PHOTON, 2'd2); state <= ST_PH_HDR3; end
                ST_PH_HDR3: if (!tx_valid || tx_ready) begin drive_header(PKT_PHOTON, 2'd3); state <= ST_PH_PAYLOAD; tx_idx <= 16'd0; end
                ST_PH_PAYLOAD: if (!tx_valid || tx_ready) begin
                    if (tx_idx < photon_tx_count) begin
                        tx_valid <= 1'b1;
                        tx_data  <= photon_rd_bank ? photon_mem1[tx_idx] : photon_mem0[tx_idx];
                        tx_idx   <= tx_idx + 1'b1;
                    end else begin
                        photon_tx_count <= 16'd0;
                        if (photon_rd_bank) begin
                            photon_ready1    <= 1'b0;
                            photon_wr_count1 <= 16'd0;
                            if (photon_wr_bank == 1'b1)
                                collect_timeout <= 16'd0;
                        end else begin
                            photon_ready0    <= 1'b0;
                            photon_wr_count0 <= 16'd0;
                            if (photon_wr_bank == 1'b0)
                                collect_timeout <= 16'd0;
                        end
                        state <= ST_IDLE;
                    end
                end

                ST_ST_HDR0: if (!tx_valid || tx_ready) begin drive_header(PKT_STATUS, 2'd0); state <= ST_ST_HDR1; end
                ST_ST_HDR1: if (!tx_valid || tx_ready) begin drive_header(PKT_STATUS, 2'd1); state <= ST_ST_HDR2; end
                ST_ST_HDR2: if (!tx_valid || tx_ready) begin drive_header(PKT_STATUS, 2'd2); state <= ST_ST_HDR3; end
                ST_ST_HDR3: if (!tx_valid || tx_ready) begin drive_header(PKT_STATUS, 2'd3); state <= ST_ST_PAYLOAD; status_idx <= 3'd0; end
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

                ST_ACK_HDR0: if (!tx_valid || tx_ready) begin drive_header(PKT_ACK, 2'd0); state <= ST_ACK_HDR1; end
                ST_ACK_HDR1: if (!tx_valid || tx_ready) begin drive_header(PKT_ACK, 2'd1); state <= ST_ACK_HDR2; end
                ST_ACK_HDR2: if (!tx_valid || tx_ready) begin drive_header(PKT_ACK, 2'd2); state <= ST_ACK_HDR3; end
                ST_ACK_HDR3: if (!tx_valid || tx_ready) begin drive_header(PKT_ACK, 2'd3); state <= ST_ACK_PAYLOAD; ack_idx <= 2'd0; end
                ST_ACK_PAYLOAD: if (!tx_valid || tx_ready) begin
                    if (ack_idx < 2'd3) begin
                        tx_valid <= 1'b1;
                        case (ack_idx)
                            2'd0: tx_data <= {16'd0, ack_cmd_id_lat, ack_status_lat};
                            2'd1: tx_data <= ack_data_lat;
                            default: tx_data <= 32'd0;
                        endcase
                        ack_idx <= ack_idx + 1'b1;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
