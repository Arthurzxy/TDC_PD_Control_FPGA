//==============================================================================
// cmd_dispatcher.v
//------------------------------------------------------------------------------
// Module: Host Command Decoder with Downstream Ready/ACK Handshakes
// 模块说明：上位机命令解析与下游 ready/ACK 握手模块
//
// Purpose:
// 中文说明：
//   在 ft_clk 域解析 FT601 收到的命令帧，检查长度和下游 ready，
//   然后把配置请求发往各子模块，并返回 ACK 包给上位机。
//   Parses incoming commands from the FT601 USB interface and dispatches
//   them to appropriate peripheral modules. Handles command framing,
//   payload assembly, and generates acknowledgment packets.
//
// Architecture:
//   - FSM-based command parsing with sync byte detection
//   - Downstream ready checking before command execution
//   - ACK packet generation for host feedback
//
// Command Framing:
//   - Sync byte (0xBB) identifies start of command
//   - Format: [SYNC][CMD_ID][PAYLOAD_LEN][PAYLOAD...]
//   - Each payload word is 32 bits
//
// Supported Commands:
//   - 0x01 CMD_AD5686:     DAC configuration (4 x 16-bit values)
//   - 0x02 CMD_GATE:       Gate hold-off time (24-bit)
//   - 0x03 CMD_NB6L295:    Delay chip configuration
//   - 0x04 CMD_TEC_PID:    TEC temperature setpoint
//   - 0x10 CMD_GPX2_CFG:   Trigger GPX2 configuration sequence
//   - 0x20 CMD_GATE_DIV:   Gate divider ratio
//   - 0x21 CMD_GATE_SIG2:   Signal 2 delay/width settings
//   - 0x22 CMD_GATE_SIG3:   Signal 3 delay/width settings
//   - 0x23 CMD_GATE_ENABLE: Signal enables
//   - 0x24 CMD_GATE_PIXEL: Pixel mode control
//   - 0x25 CMD_GATE_RAM:   Gate RAM write
//   - 0x30 CMD_FLASH_SAVE: Save config to flash
//   - 0x31 CMD_FLASH_LOAD: Load config from flash
//
// Clock Domain:
//   - clk (typically ft_clk domain from FT601)
//
// Related Documents:
//   - PROJECT_STAGE_SUMMARY_2026-04-04.md Section 6.7
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module cmd_dispatcher #(
    parameter SYNC_BYTE = 8'hBB      // Command framing sync byte
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] rx_data,
    input  wire        rx_valid,
    output wire        rx_ready,

    input  wire        ad5686_ready,
    input  wire        nb6l295_ready,
    input  wire        tec_temp_ready,
    input  wire        gpx2_cfg_ready,
    input  wire        gate_cfg_ready,
    input  wire        gate_pixel_ready,
    input  wire        gate_ram_ready,
    input  wire        flash_ready,
    // Temporary bring-up mode: ACK path kept only for interface compatibility.
    input  wire        ack_ready,

    output reg         ad5686_start,
    output reg  [15:0] ad5686_data1,
    output reg  [15:0] ad5686_data2,
    output reg  [15:0] ad5686_data3,
    output reg  [15:0] ad5686_data4,
    output reg  [23:0] gate_hold_off_time,
    output reg         nb6l295_start,
    output reg  [8:0]  nb6l295_delay_a,
    output reg  [8:0]  nb6l295_delay_b,
    output reg         nb6l295_enable,
    output reg  [15:0] tec_temp_set,
    output reg         tec_temp_set_valid,
    output reg         gpx2_start_cfg,
    output reg  [11:0] gate_div_ratio,
    output reg         gate_sig2_enable,
    output reg         gate_sig3_enable,
    output reg  [3:0]  gate_sig2_delay_coarse,
    output reg  [4:0]  gate_sig2_delay_fine,
    output reg  [2:0]  gate_sig2_width_coarse,
    output reg  [4:0]  gate_sig2_width_fine,
    output reg  [3:0]  gate_sig3_delay_coarse,
    output reg  [4:0]  gate_sig3_delay_fine,
    output reg  [2:0]  gate_sig3_width_coarse,
    output reg  [4:0]  gate_sig3_width_fine,
    output reg         gate_pixel_mode,
    output reg         gate_cfg_valid,
    output reg         gate_pixel_reset,
    output reg         gate_ram_wr_en,
    output reg  [13:0] gate_ram_wr_addr,
    output reg  [35:0] gate_ram_wr_data,
    output reg         flash_save_req,
    output reg         flash_load_req,

    output reg         ack_valid,
    output reg  [7:0]  ack_cmd_id,
    output reg  [7:0]  ack_status,
    output reg  [31:0] ack_data,

    output wire [1:0]  dbg_state,
    output wire [7:0]  dbg_cmd_id,
    output wire [3:0]  dbg_payload_len,
    output wire [3:0]  dbg_payload_idx
);

    localparam CMD_AD5686      = 8'h01;
    localparam CMD_GATE        = 8'h02;
    localparam CMD_NB6L295     = 8'h03;
    localparam CMD_TEC_PID     = 8'h04;
    localparam CMD_GPX2_CFG    = 8'h10;
    localparam CMD_GATE_DIV    = 8'h20;
    localparam CMD_GATE_SIG2   = 8'h21;
    localparam CMD_GATE_SIG3   = 8'h22;
    localparam CMD_GATE_ENABLE = 8'h23;
    localparam CMD_GATE_PIXEL  = 8'h24;
    localparam CMD_GATE_RAM    = 8'h25;
    localparam CMD_FLASH_SAVE  = 8'h30;
    localparam CMD_FLASH_LOAD  = 8'h31;

    localparam ST_IDLE       = 2'd0;
    localparam ST_RX_PAYLOAD = 2'd1;
    localparam ST_EXECUTE    = 2'd2;

    (* fsm_encoding = "none" *) reg [1:0]   state;
    reg [7:0]   cmd_id;
    reg [3:0]   payload_len;
    reg [3:0]   payload_idx;
    reg [127:0] payload_buf;

    assign dbg_state       = state;
    assign dbg_cmd_id      = cmd_id;
    assign dbg_payload_len = payload_len;
    assign dbg_payload_idx = payload_idx;
    wire _unused_ack_ready = ack_ready;

    // Drive ready from the current parser state, not from a registered copy.
    // This prevents a stale ready value from accepting the same FT601 word
    // once as the header and again as the first payload word.
    assign rx_ready = (state == ST_IDLE) || (state == ST_RX_PAYLOAD);

    // 每条命令的 payload 长度在这里集中定义，便于上位机协议和 RTL 对齐。
    function [3:0] expected_len;
        input [7:0] cmd_id_in;
        begin
            case (cmd_id_in)
                CMD_AD5686:      expected_len = 4'd2;
                CMD_GATE:        expected_len = 4'd1;
                CMD_NB6L295:     expected_len = 4'd1;
                CMD_TEC_PID:     expected_len = 4'd1;
                CMD_GPX2_CFG:    expected_len = 4'd0;
                CMD_GATE_DIV:    expected_len = 4'd1;
                CMD_GATE_SIG2:   expected_len = 4'd1;
                CMD_GATE_SIG3:   expected_len = 4'd1;
                CMD_GATE_ENABLE: expected_len = 4'd1;
                CMD_GATE_PIXEL:  expected_len = 4'd1;
                CMD_GATE_RAM:    expected_len = 4'd2;
                CMD_FLASH_SAVE:  expected_len = 4'd0;
                CMD_FLASH_LOAD:  expected_len = 4'd0;
                default:         expected_len = 4'd0;
            endcase
        end
    endfunction

    function is_known_cmd;
        input [7:0] cmd_id_in;
        begin
            case (cmd_id_in)
                CMD_AD5686,
                CMD_GATE,
                CMD_NB6L295,
                CMD_TEC_PID,
                CMD_GPX2_CFG,
                CMD_GATE_DIV,
                CMD_GATE_SIG2,
                CMD_GATE_SIG3,
                CMD_GATE_ENABLE,
                CMD_GATE_PIXEL,
                CMD_GATE_RAM,
                CMD_FLASH_SAVE,
                CMD_FLASH_LOAD: is_known_cmd = 1'b1;
                default:        is_known_cmd = 1'b0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state                  <= ST_IDLE;
            cmd_id                 <= 8'd0;
            payload_len            <= 4'd0;
            payload_idx            <= 4'd0;
            payload_buf            <= 128'd0;
            ad5686_start           <= 1'b0;
            ad5686_data1           <= 16'd0;
            ad5686_data2           <= 16'd0;
            ad5686_data3           <= 16'd0;
            ad5686_data4           <= 16'd0;
            gate_hold_off_time     <= 24'd0;
            nb6l295_start          <= 1'b0;
            nb6l295_delay_a        <= 9'd0;
            nb6l295_delay_b        <= 9'd0;
            nb6l295_enable         <= 1'b0;
            tec_temp_set           <= 16'd0;
            tec_temp_set_valid     <= 1'b0;
            gpx2_start_cfg         <= 1'b0;
            gate_div_ratio         <= 12'd1;
            gate_sig2_enable       <= 1'b0;
            gate_sig3_enable       <= 1'b0;
            gate_sig2_delay_coarse <= 4'd0;
            gate_sig2_delay_fine   <= 5'd0;
            gate_sig2_width_coarse <= 3'd0;
            gate_sig2_width_fine   <= 5'd10;
            gate_sig3_delay_coarse <= 4'd0;
            gate_sig3_delay_fine   <= 5'd0;
            gate_sig3_width_coarse <= 3'd0;
            gate_sig3_width_fine   <= 5'd10;
            gate_pixel_mode        <= 1'b0;
            gate_cfg_valid         <= 1'b0;
            gate_pixel_reset       <= 1'b0;
            gate_ram_wr_en         <= 1'b0;
            gate_ram_wr_addr       <= 14'd0;
            gate_ram_wr_data       <= 36'd0;
            flash_save_req         <= 1'b0;
            flash_load_req         <= 1'b0;
            ack_valid              <= 1'b0;
            ack_cmd_id             <= 8'd0;
            ack_status             <= 8'd0;
            ack_data               <= 32'd0;
        end else begin
            ad5686_start       <= 1'b0;
            nb6l295_start      <= 1'b0;
            tec_temp_set_valid <= 1'b0;
            gpx2_start_cfg     <= 1'b0;
            gate_cfg_valid     <= 1'b0;
            gate_pixel_reset   <= 1'b0;
            gate_ram_wr_en     <= 1'b0;
            flash_save_req     <= 1'b0;
            flash_load_req     <= 1'b0;
            ack_valid          <= 1'b0;

            case (state)
                ST_IDLE: begin
                    // 空闲态等待 0xBB 同步字，只有识别到合法帧头才继续收 payload。
                    if (rx_valid && rx_ready &&
                        (rx_data[31:24] == SYNC_BYTE) &&
                        is_known_cmd(rx_data[23:16]) &&
                        (rx_data[3:0] == expected_len(rx_data[23:16]))) begin
                        cmd_id      <= rx_data[23:16];
                        payload_len <= rx_data[3:0];
                        payload_idx <= 4'd0;
                        payload_buf <= 128'd0;
                        if (rx_data[3:0] == 4'd0)
                            state <= ST_EXECUTE;
                        else
                            state <= ST_RX_PAYLOAD;
                    end
                end

                ST_RX_PAYLOAD: begin
                    // payload 统一按 32 位字拼接，后续执行阶段再按命令类型拆字段。
                    if (rx_valid && rx_ready) begin
                        // Re-sync on a legal header while payload is incomplete.
                        // This prevents a repeated frame header from being
                        // dispatched as AD5686/NB6/etc. payload data.
                        if ((rx_data[31:24] == SYNC_BYTE) &&
                            is_known_cmd(rx_data[23:16]) &&
                            (rx_data[3:0] == expected_len(rx_data[23:16]))) begin
                            cmd_id      <= rx_data[23:16];
                            payload_len <= rx_data[3:0];
                            payload_idx <= 4'd0;
                            payload_buf <= 128'd0;
                            if (rx_data[3:0] == 4'd0)
                                state <= ST_EXECUTE;
                            else
                                state <= ST_RX_PAYLOAD;
                        end else begin
                            payload_buf <= {payload_buf[95:0], rx_data};
                            payload_idx <= payload_idx + 1'b1;
                            if (payload_idx + 1'b1 >= payload_len)
                                state <= ST_EXECUTE;
                        end
                    end
                end

                ST_EXECUTE: begin
                    // 临时关闭 ACK 机制，执行阶段只受目标模块 ready 约束，
                    // 避免 TX/ACK 回压把命令解析链路卡死。
                    case (cmd_id)
                        CMD_AD5686: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (ad5686_ready) begin
                                ad5686_data1 <= payload_buf[63:48];
                                ad5686_data2 <= payload_buf[47:32];
                                ad5686_data3 <= payload_buf[31:16];
                                ad5686_data4 <= payload_buf[15:0];
                                ad5686_start <= 1'b1;
                                state        <= ST_IDLE;
                            end
                        end

                        CMD_GATE: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else begin
                                gate_hold_off_time <= payload_buf[23:0];
                                state              <= ST_IDLE;
                            end
                        end

                        CMD_NB6L295: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (nb6l295_ready) begin
                                nb6l295_delay_a <= payload_buf[8:0];
                                nb6l295_delay_b <= payload_buf[17:9];
                                nb6l295_enable  <= payload_buf[18];
                                nb6l295_start   <= 1'b1;
                                state           <= ST_IDLE;
                            end
                        end

                        CMD_TEC_PID: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (tec_temp_ready) begin
                                tec_temp_set       <= payload_buf[15:0];
                                tec_temp_set_valid <= 1'b1;
                                state              <= ST_IDLE;
                            end
                        end

                        CMD_GPX2_CFG: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (gpx2_cfg_ready) begin
                                gpx2_start_cfg <= 1'b1;
                                state          <= ST_IDLE;
                            end
                        end

                        CMD_GATE_DIV: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (gate_cfg_ready) begin
                                gate_div_ratio <= payload_buf[11:0];
                                gate_cfg_valid <= 1'b1;
                                state          <= ST_IDLE;
                            end
                        end

                        CMD_GATE_SIG2: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (gate_cfg_ready) begin
                                gate_sig2_delay_coarse <= payload_buf[3:0];
                                gate_sig2_delay_fine   <= payload_buf[8:4];
                                gate_sig2_width_coarse <= payload_buf[11:9];
                                gate_sig2_width_fine   <= payload_buf[16:12];
                                gate_cfg_valid         <= 1'b1;
                                state                  <= ST_IDLE;
                            end
                        end

                        CMD_GATE_SIG3: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (gate_cfg_ready) begin
                                gate_sig3_delay_coarse <= payload_buf[3:0];
                                gate_sig3_delay_fine   <= payload_buf[8:4];
                                gate_sig3_width_coarse <= payload_buf[11:9];
                                gate_sig3_width_fine   <= payload_buf[16:12];
                                gate_cfg_valid         <= 1'b1;
                                state                  <= ST_IDLE;
                            end
                        end

                        CMD_GATE_ENABLE: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (gate_cfg_ready) begin
                                gate_sig2_enable <= payload_buf[0];
                                gate_sig3_enable <= payload_buf[1];
                                gate_pixel_mode  <= payload_buf[2];
                                gate_cfg_valid   <= 1'b1;
                                state            <= ST_IDLE;
                            end
                        end

                        CMD_GATE_PIXEL: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (!payload_buf[0]) begin
                                state <= ST_IDLE;
                            end else if (gate_pixel_ready) begin
                                gate_pixel_reset <= 1'b1;
                                state            <= ST_IDLE;
                            end
                        end

                        CMD_GATE_RAM: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (gate_ram_ready) begin
                                gate_ram_wr_addr <= payload_buf[49:36];
                                gate_ram_wr_data <= payload_buf[35:0];
                                gate_ram_wr_en   <= 1'b1;
                                state            <= ST_IDLE;
                            end
                        end

                        CMD_FLASH_SAVE: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (flash_ready) begin
                                flash_save_req <= 1'b1;
                                state          <= ST_IDLE;
                            end
                        end

                        CMD_FLASH_LOAD: begin
                            if (payload_len != expected_len(cmd_id)) begin
                                state <= ST_IDLE;
                            end else if (flash_ready) begin
                                flash_load_req <= 1'b1;
                                state          <= ST_IDLE;
                            end
                        end

                        default: begin
                            state <= ST_IDLE;
                        end
                    endcase
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
