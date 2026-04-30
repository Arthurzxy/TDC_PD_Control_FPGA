//==============================================================================
// packet_builder.v
//------------------------------------------------------------------------------
// Module: USB Upload Packet Builder
// 模块说明：USB 上传包构建器
//
// Purpose:
// 中文说明：
//   统一把原始 TDC 事件、状态遥测和命令 ACK 打包给上位机。
//   Formats event data, status telemetry, and command acknowledgments into
//   structured packets for transmission to the host PC via FT601 USB3.0.
//
// Architecture:
//   - Collects TDC events into batches (up to TDC_EVENTS_PER_PKT)
//   - Supports three packet types: TDC_RAW, STATUS, ACK
//   - Unified packet header format for easy host-side parsing
//   - Timeout-based packetization to ensure timely delivery
//
// Packet Format (all packets use 4-word header):
// 中文说明：
//   所有包都共用 4 个 32 位字的包头，方便上位机复用同一套解析框架。
//   Word 0: [SYNC[7:0], TYPE[7:0], VERSION[7:0], HDR_WORDS[7:0]]
//   Word 1: [SEQ[15:0], PAYLOAD_WORDS[15:0]]
//   Word 2: [ITEM_COUNT[15:0], FLAGS[15:0]]
//   Word 3: [TIMESTAMP_US[31:0]]
//   Payload: Variable length depending on packet type
//
// Packet Types:
//   - TDC_RAW (0x01): Raw TDC event records, 64-bit each (2 words)
//   - STATUS (0x02): System telemetry (flags, uptime, temp, counters)
//   - ACK (0x03): Command acknowledgment (cmd_id, status, data)
//
// Clock Domain:
//   - clk (system clock, typically ft_clk domain)
//
// Interfaces:
//   - TDC event input: event_valid/event_ready handshake
//   - Status input: status_valid strobe
//   - ACK input: ack_valid/ack_ready handshake
//   - TX output: tx_valid/tx_ready handshake
//
// Related Documents:
//   - PROJECT_STAGE_SUMMARY_2026-04-04.md Section 6.5
//
// Author: Xuanyi Zhang
// Modified: 2026-04-04
//==============================================================================

`timescale 1ns/1ps

module packet_builder #(
    parameter integer DATA_WIDTH          = 32,    // Data bus width (FT601 = 32-bit)
    parameter integer TDC_EVENTS_PER_PKT  = 64,    // Max events per TDC_RAW packet
    parameter integer COLLECT_TIMEOUT_CYC = 1024   // Max cycles to wait for full packet
)(
    //==========================================================================
    // Clock and Reset
    //==========================================================================
    input  wire                  clk,            // System clock
    input  wire                  rst,            // Active-high reset

    //==========================================================================
    // TDC Event Input Interface
    //==========================================================================
    input  wire                  event_valid,    // Event data valid
    output wire                  event_ready,    // Ready to accept event
    input  wire [1:0]            event_ch,       // Channel number [0..3]
    input  wire [23:0]           event_refid,   // Reference ID from GPX2
    input  wire [19:0]           event_tstop,   // Time-of-stop from GPX2

    //==========================================================================
    // Status Telemetry Input Interface
    //==========================================================================
    input  wire                  status_valid,   // Status data valid strobe
    input  wire [15:0]           status_flags,   // System status flags
    input  wire [31:0]           uptime_seconds, // System uptime counter
    input  wire [15:0]           temp_avg,      // Average temperature
    input  wire [31:0]           counter_1s,    // 1-second counter value
    input  wire [31:0]           tdc_drop_count, // TDC event drop counter
    input  wire [31:0]           usb_drop_count, // USB backpressure drop count

    //==========================================================================
    // Command Acknowledgment Input Interface
    //==========================================================================
    input  wire                  ack_valid,     // ACK data valid
    output wire                  ack_ready,      // Ready to accept ACK
    input  wire [7:0]            ack_cmd_id,    // Command ID being acknowledged
    input  wire [7:0]            ack_status,    // ACK status code (0=OK, etc.)
    input  wire [31:0]           ack_data,      // Optional response data

    //==========================================================================
    // TX Output Interface (to FT601)
    //==========================================================================
    output reg  [DATA_WIDTH-1:0] tx_data,       // Packet data output
    output reg  [3:0]            tx_be,         // Byte enable (always 0xF)
    output reg                   tx_valid,      // TX data valid
    input  wire                  tx_ready        // System ready for TX data
);

    //==========================================================================
    // Protocol Constants
    //==========================================================================
    localparam [7:0] SYNC_BYTE   = 8'hA5;      // Packet sync marker
    localparam [7:0] PROTO_VER   = 8'h01;      // Protocol version 1
    localparam [7:0] HDR_WORDS   = 8'd4;       // Header is 4 words (16 bytes)

    // Packet type codes
    localparam [7:0] PKT_TDC_RAW = 8'h01;      // Raw TDC event data
    localparam [7:0] PKT_STATUS  = 8'h02;      // System status telemetry
    localparam [7:0] PKT_ACK     = 8'h03;      // Command acknowledgment

    // Event record type (embedded in TDC_RAW payload)
    localparam [3:0] REC_TDC_RAW = 4'h0;       // TDC event record type

    //==========================================================================
    // FSM State Definitions
    //==========================================================================
    // TDC packet states: collect events, then emit header + payload
    localparam ST_IDLE        = 4'd0;          // Wait for event or status/ACK
    localparam ST_COLLECT     = 4'd1;          // Collecting TDC events
    localparam ST_TDC_HDR0    = 4'd2;          // Emit TDC header word 0
    localparam ST_TDC_HDR1    = 4'd3;          // Emit TDC header word 1
    localparam ST_TDC_HDR2    = 4'd4;          // Emit TDC header word 2
    localparam ST_TDC_HDR3    = 4'd5;          // Emit TDC header word 3
    localparam ST_TDC_PAYL    = 4'd6;          // Emit TDC payload (event records)
    // Status packet states
    localparam ST_STATUS_HDR0 = 4'd7;          // Emit status header word 0
    localparam ST_STATUS_HDR1 = 4'd8;          // Emit status header word 1
    localparam ST_STATUS_HDR2 = 4'd9;          // Emit status header word 2
    localparam ST_STATUS_HDR3 = 4'd10;         // Emit status header word 3
    localparam ST_STATUS_PAYL = 4'd11;         // Emit status payload
    // ACK packet states
    localparam ST_ACK_HDR0    = 4'd12;         // Emit ACK header word 0
    localparam ST_ACK_HDR1    = 4'd13;         // Emit ACK header word 1
    localparam ST_ACK_HDR2    = 4'd14;         // Emit ACK header word 2
    localparam ST_ACK_HDR3    = 4'd15;         // Emit ACK header word 3
    localparam ST_ACK_PAYL    = 5'd16;         // Emit ACK payload

    //==========================================================================
    // Internal State Variables
    //==========================================================================
    reg [4:0]  state;                          // Current FSM state
    reg [15:0] pkt_seq;                        // Packet sequence number
    reg [31:0] us_counter;                     // Microsecond counter (timestamp source)
    reg [6:0]  event_count;                    // Events collected in current batch
    reg [6:0]  tx_event_idx;                   // Event index during TX
    reg        tx_word_sel;                    // 0=low word, 1=high word of 64-bit event
    reg [15:0] collect_timeout;                // Timeout counter for collection
    reg [31:0] pkt_timestamp_us;               // Packet timestamp
    reg [15:0] pkt_flags;                      // Packet flags field
    reg [15:0] payload_words;                  // Payload length in words
    reg [15:0] item_count;                     // Number of items in packet
    reg [2:0]  status_word_idx;                // Status payload word index
    reg [1:0]  ack_word_idx;                   // ACK payload word index
    reg        status_pending;                 // Status packet queued
    reg        ack_pending;                     // ACK packet queued
    // Latched status/ACK data
    reg [15:0] status_flags_lat;
    reg [31:0] uptime_seconds_lat;
    reg [15:0] temp_avg_lat;
    reg [31:0] counter_1s_lat;
    reg [31:0] tdc_drop_count_lat;
    reg [31:0] usb_drop_count_lat;
    reg [7:0]  ack_cmd_id_lat;
    reg [7:0]  ack_status_lat;
    reg [31:0] ack_data_lat;
    // Event storage memory
    reg [63:0] event_mem [0:TDC_EVENTS_PER_PKT-1];
    integer i;                                 // Loop variable

    //==========================================================================
    // Combinational Signals
    //==========================================================================
    wire       accept_event;                   // Event accepted this cycle
    wire [1:0] event_class;                    // Event classification
    wire [63:0] event_record;                  // Formatted 64-bit event record

    //--------------------------------------------------------------------------
    // 只有在收集态、缓存未满、并且没有状态包/ACK 抢占时，才继续吸收 TDC 事件。
    //--------------------------------------------------------------------------
    assign event_ready  = ((state == ST_IDLE) || (state == ST_COLLECT)) &&
                          !status_pending && !ack_pending &&
                          (event_count < TDC_EVENTS_PER_PKT);
    assign accept_event = event_valid && event_ready;

    // ACK ready: can accept ACK when not already pending
    assign ack_ready    = ~ack_pending;

    //--------------------------------------------------------------------------
    // 用简化分类字段给不同通道打标记，便于上位机后续区分普通事件和特殊标记。
    //--------------------------------------------------------------------------
    assign event_class  = (event_ch == 2'd2) ? 2'b01 :
                          (event_ch == 2'd3) ? 2'b10 :
                          2'b00;

    //--------------------------------------------------------------------------
    // 注意：实际位拼接顺序以下面的 event_record 赋值为准：
    // {记录类型, 通道号, 事件分类, refid, tstop, 保留位}
    //--------------------------------------------------------------------------

    always @(posedge clk) begin
        if (rst) begin
            state              <= ST_IDLE;
            pkt_seq            <= 16'd0;
            tx_data            <= {DATA_WIDTH{1'b0}};
            tx_be              <= 4'hF;
            tx_valid           <= 1'b0;
            us_counter         <= 32'd0;
            event_count        <= 7'd0;
            tx_event_idx       <= 7'd0;
            tx_word_sel        <= 1'b0;
            collect_timeout    <= 16'd0;
            pkt_timestamp_us   <= 32'd0;
            pkt_flags          <= 16'd0;
            payload_words      <= 16'd0;
            item_count         <= 16'd0;
            status_word_idx    <= 3'd0;
            ack_word_idx       <= 2'd0;
            status_pending     <= 1'b0;
            ack_pending        <= 1'b0;
            status_flags_lat   <= 16'd0;
            uptime_seconds_lat <= 32'd0;
            temp_avg_lat       <= 16'd0;
            counter_1s_lat     <= 32'd0;
            tdc_drop_count_lat <= 32'd0;
            usb_drop_count_lat <= 32'd0;
            ack_cmd_id_lat     <= 8'd0;
            ack_status_lat     <= 8'd0;
            ack_data_lat       <= 32'd0;
        end else begin
            tx_be      <= 4'hF;
            us_counter <= us_counter + 1'b1;

            // 慢速状态和 ACK 先锁存，等当前发送机会到来时再插包，避免短脉冲丢失。
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

            if (tx_valid && tx_ready)
                tx_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    event_count     <= 7'd0;
                    collect_timeout <= 16'd0;

                    if (ack_pending) begin
                        pkt_timestamp_us <= us_counter;
                        pkt_flags        <= 16'd0;
                        payload_words    <= 16'd3;
                        item_count       <= 16'd3;
                        ack_word_idx     <= 2'd0;
                        pkt_seq          <= pkt_seq + 1'b1;
                        ack_pending      <= 1'b0;
                        state            <= ST_ACK_HDR0;
                    end else if (status_pending) begin
                        pkt_timestamp_us <= us_counter;
                        pkt_flags        <= status_flags_lat;
                        payload_words    <= 16'd6;
                        item_count       <= 16'd6;
                        status_word_idx  <= 3'd0;
                        pkt_seq          <= pkt_seq + 1'b1;
                        status_pending   <= 1'b0;
                        state            <= ST_STATUS_HDR0;
                    end else if (accept_event) begin
                        event_mem[0] <= event_record;
                        event_count  <= 7'd1;
                        state        <= ST_COLLECT;
                    end
                end

                ST_COLLECT: begin
                    if (accept_event) begin
                        event_mem[event_count] <= event_record;
                        collect_timeout        <= 16'd0;

                        if (event_count == TDC_EVENTS_PER_PKT - 1) begin
                            pkt_timestamp_us <= us_counter;
                            pkt_flags        <= 16'd0;
                            payload_words    <= TDC_EVENTS_PER_PKT * 2;
                            item_count       <= TDC_EVENTS_PER_PKT;
                            tx_event_idx     <= 7'd0;
                            tx_word_sel      <= 1'b0;
                            pkt_seq          <= pkt_seq + 1'b1;
                            state            <= ST_TDC_HDR0;
                        end else begin
                            event_count <= event_count + 1'b1;
                        end
                    end else if (ack_pending || status_pending || (collect_timeout == COLLECT_TIMEOUT_CYC - 1)) begin
                        pkt_timestamp_us <= us_counter;
                        pkt_flags        <= 16'd0;
                        payload_words    <= {9'd0, event_count} << 1;
                        item_count       <= {9'd0, event_count};
                        tx_event_idx     <= 7'd0;
                        tx_word_sel      <= 1'b0;
                        pkt_seq          <= pkt_seq + 1'b1;
                        state            <= ST_TDC_HDR0;
                    end else begin
                        collect_timeout <= collect_timeout + 1'b1;
                    end
                end

                ST_TDC_HDR0: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {SYNC_BYTE, PKT_TDC_RAW, PROTO_VER, HDR_WORDS};
                        tx_valid <= 1'b1;
                        state    <= ST_TDC_HDR1;
                    end
                end

                ST_TDC_HDR1: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {pkt_seq, payload_words};
                        tx_valid <= 1'b1;
                        state    <= ST_TDC_HDR2;
                    end
                end

                ST_TDC_HDR2: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {item_count, pkt_flags};
                        tx_valid <= 1'b1;
                        state    <= ST_TDC_HDR3;
                    end
                end

                ST_TDC_HDR3: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= pkt_timestamp_us;
                        tx_valid <= 1'b1;
                        state    <= ST_TDC_PAYL;
                    end
                end

                ST_TDC_PAYL: begin
                    if (!tx_valid || tx_ready) begin
                        if (!tx_word_sel) begin
                            tx_data     <= event_mem[tx_event_idx][31:0];
                            tx_valid    <= 1'b1;
                            tx_word_sel <= 1'b1;
                        end else begin
                            tx_data     <= event_mem[tx_event_idx][63:32];
                            tx_valid    <= 1'b1;
                            tx_word_sel <= 1'b0;

                            if (tx_event_idx == item_count - 1'b1) begin
                                state       <= ST_IDLE;
                                event_count <= 7'd0;
                            end else begin
                                tx_event_idx <= tx_event_idx + 1'b1;
                            end
                        end
                    end
                end

                ST_STATUS_HDR0: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {SYNC_BYTE, PKT_STATUS, PROTO_VER, HDR_WORDS};
                        tx_valid <= 1'b1;
                        state    <= ST_STATUS_HDR1;
                    end
                end

                ST_STATUS_HDR1: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {pkt_seq, payload_words};
                        tx_valid <= 1'b1;
                        state    <= ST_STATUS_HDR2;
                    end
                end

                ST_STATUS_HDR2: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {item_count, pkt_flags};
                        tx_valid <= 1'b1;
                        state    <= ST_STATUS_HDR3;
                    end
                end

                ST_STATUS_HDR3: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= pkt_timestamp_us;
                        tx_valid <= 1'b1;
                        state    <= ST_STATUS_PAYL;
                    end
                end

                ST_STATUS_PAYL: begin
                    if (!tx_valid || tx_ready) begin
                        case (status_word_idx)
                            3'd0: tx_data <= {16'd0, status_flags_lat};
                            3'd1: tx_data <= uptime_seconds_lat;
                            3'd2: tx_data <= {16'd0, temp_avg_lat};
                            3'd3: tx_data <= counter_1s_lat;
                            3'd4: tx_data <= tdc_drop_count_lat;
                            default: tx_data <= usb_drop_count_lat;
                        endcase
                        tx_valid <= 1'b1;

                        if (status_word_idx == 3'd5) begin
                            status_word_idx <= 3'd0;
                            state           <= ST_IDLE;
                        end else begin
                            status_word_idx <= status_word_idx + 1'b1;
                        end
                    end
                end

                ST_ACK_HDR0: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {SYNC_BYTE, PKT_ACK, PROTO_VER, HDR_WORDS};
                        tx_valid <= 1'b1;
                        state    <= ST_ACK_HDR1;
                    end
                end

                ST_ACK_HDR1: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {pkt_seq, payload_words};
                        tx_valid <= 1'b1;
                        state    <= ST_ACK_HDR2;
                    end
                end

                ST_ACK_HDR2: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= {item_count, pkt_flags};
                        tx_valid <= 1'b1;
                        state    <= ST_ACK_HDR3;
                    end
                end

                ST_ACK_HDR3: begin
                    if (!tx_valid || tx_ready) begin
                        tx_data  <= pkt_timestamp_us;
                        tx_valid <= 1'b1;
                        state    <= ST_ACK_PAYL;
                    end
                end

                ST_ACK_PAYL: begin
                    if (!tx_valid || tx_ready) begin
                        case (ack_word_idx)
                            2'd0: tx_data <= {24'd0, ack_cmd_id_lat};
                            2'd1: tx_data <= {24'd0, ack_status_lat};
                            default: tx_data <= ack_data_lat;
                        endcase
                        tx_valid <= 1'b1;

                        if (ack_word_idx == 2'd2) begin
                            ack_word_idx <= 2'd0;
                            state        <= ST_IDLE;
                        end else begin
                            ack_word_idx <= ack_word_idx + 1'b1;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
