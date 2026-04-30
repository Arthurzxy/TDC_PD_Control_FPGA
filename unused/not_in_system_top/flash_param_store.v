`timescale 1ns/1ps

module flash_param_store #(
    parameter integer PARAM_BITS          = 148,
    parameter [23:0] PARAM_SECTOR_ADDR    = 24'hFFF000,
    parameter integer STARTUP_WAIT_CYCLES = 100_000,
    parameter integer POLL_TIMEOUT_CYCLES = 5_000_000
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  save_req,
    input  wire                  load_req,
    input  wire [PARAM_BITS-1:0] params_in,
    output reg                   load_valid,
    output reg  [PARAM_BITS-1:0] params_out,
    output reg                   busy,
    output reg                   error,

    output reg                   flash_cs_n,
    output reg                   flash_d0,
    input  wire                  flash_d1
);

    localparam [7:0] CMD_WREN = 8'h06;
    localparam [7:0] CMD_RDSR = 8'h05;
    localparam [7:0] CMD_READ = 8'h03;
    localparam [7:0] CMD_PP   = 8'h02;
    localparam [7:0] CMD_SE   = 8'h20;

    localparam [31:0] PARAM_MAGIC   = 32'h5041_524D;
    localparam [31:0] PARAM_VERSION = 32'h0001_0001;
    localparam integer PARAM_WORDS  = 9;
    localparam integer PARAM_BYTES  = PARAM_WORDS * 4;

    localparam [5:0] ST_BOOT_WAIT  = 6'd0;
    localparam [5:0] ST_IDLE       = 6'd1;
    localparam [5:0] ST_WREN_CS    = 6'd2;
    localparam [5:0] ST_WREN_CMD   = 6'd3;
    localparam [5:0] ST_WREN_DONE  = 6'd4;
    localparam [5:0] ST_ERASE_CS   = 6'd5;
    localparam [5:0] ST_ERASE_CMD  = 6'd6;
    localparam [5:0] ST_ERASE_A2   = 6'd7;
    localparam [5:0] ST_ERASE_A1   = 6'd8;
    localparam [5:0] ST_ERASE_A0   = 6'd9;
    localparam [5:0] ST_ERASE_DONE = 6'd10;
    localparam [5:0] ST_POLL_CS    = 6'd11;
    localparam [5:0] ST_POLL_CMD   = 6'd12;
    localparam [5:0] ST_POLL_DATA  = 6'd13;
    localparam [5:0] ST_POLL_DONE  = 6'd14;
    localparam [5:0] ST_PP_CS      = 6'd15;
    localparam [5:0] ST_PP_CMD     = 6'd16;
    localparam [5:0] ST_PP_A2      = 6'd17;
    localparam [5:0] ST_PP_A1      = 6'd18;
    localparam [5:0] ST_PP_A0      = 6'd19;
    localparam [5:0] ST_PP_DATA    = 6'd20;
    localparam [5:0] ST_PP_DONE    = 6'd21;
    localparam [5:0] ST_READ_CS    = 6'd22;
    localparam [5:0] ST_READ_CMD   = 6'd23;
    localparam [5:0] ST_READ_A2    = 6'd24;
    localparam [5:0] ST_READ_A1    = 6'd25;
    localparam [5:0] ST_READ_A0    = 6'd26;
    localparam [5:0] ST_READ_DATA  = 6'd27;
    localparam [5:0] ST_READ_DONE  = 6'd28;
    localparam [5:0] ST_ERROR      = 6'd29;

    reg  [5:0]              state;
    reg  [5:0]              next_after_poll;
    reg  [31:0]             startup_cnt;
    reg  [22:0]             poll_timeout_cnt;
    reg  [PARAM_BITS-1:0]   params_latched;
    reg  [31:0]             read_words [0:PARAM_WORDS-1];
    reg  [5:0]              data_byte_idx;
    reg  [7:0]              spi_tx_byte;
    reg  [7:0]              spi_rx_byte;
    reg                     spi_byte_start;
    reg                     auto_load_done;
    reg                     spi_sck_int;
    reg                     spi_active;
    reg  [1:0]              spi_phase;
    reg  [2:0]              spi_bit_cnt;
    reg  [7:0]              spi_tx_shift;
    reg  [7:0]              spi_rx_shift;
    reg                     spi_byte_done;
    integer                 i;

    wire [31:0] crc_expect;

    function [31:0] calc_crc;
        input [PARAM_BITS-1:0] params;
        reg [48:0] gate_cfg;
        begin
            gate_cfg = params[147:99];
            calc_crc = PARAM_VERSION ^
                       params[63:32] ^
                       params[31:0] ^
                       {13'd0, params[82:64]} ^
                       {16'd0, params[98:83]} ^
                       gate_cfg[48:17] ^
                       {15'd0, gate_cfg[16:0]};
        end
    endfunction

    function [31:0] pack_word;
        input [3:0] idx;
        input [PARAM_BITS-1:0] params;
        reg [48:0] gate_cfg;
        begin
            gate_cfg = params[147:99];
            case (idx)
                4'd0: pack_word = PARAM_MAGIC;
                4'd1: pack_word = PARAM_VERSION;
                4'd2: pack_word = params[63:32];
                4'd3: pack_word = params[31:0];
                4'd4: pack_word = {13'd0, params[82:64]};
                4'd5: pack_word = {16'd0, params[98:83]};
                4'd6: pack_word = gate_cfg[48:17];
                4'd7: pack_word = {15'd0, gate_cfg[16:0]};
                default: pack_word = calc_crc(params);
            endcase
        end
    endfunction

    function [7:0] pack_byte;
        input [5:0] idx;
        input [PARAM_BITS-1:0] params;
        reg [31:0] word_sel;
        begin
            word_sel = pack_word(idx[5:2], params);
            case (idx[1:0])
                2'd0: pack_byte = word_sel[31:24];
                2'd1: pack_byte = word_sel[23:16];
                2'd2: pack_byte = word_sel[15:8];
                default: pack_byte = word_sel[7:0];
            endcase
        end
    endfunction

    assign crc_expect = read_words[1] ^ read_words[2] ^ read_words[3] ^ read_words[4] ^
                        read_words[5] ^ read_words[6] ^ read_words[7];

    always @(posedge clk) begin
        spi_byte_done  <= 1'b0;

        if (rst) begin
            spi_active   <= 1'b0;
            spi_phase    <= 2'd0;
            spi_bit_cnt  <= 3'd0;
            spi_tx_shift <= 8'd0;
            spi_rx_shift <= 8'd0;
            spi_rx_byte  <= 8'd0;
            flash_d0     <= 1'b0;
            spi_sck_int  <= 1'b0;
        end else begin
            if (spi_active) begin
                case (spi_phase)
                    2'd0: begin
                        spi_sck_int <= 1'b0;
                        flash_d0    <= spi_tx_shift[7];
                        spi_phase   <= 2'd1;
                    end

                    2'd1: begin
                        spi_sck_int <= 1'b1;
                        spi_phase   <= 2'd2;
                    end

                    2'd2: begin
                        spi_rx_shift <= {spi_rx_shift[6:0], flash_d1};
                        spi_phase    <= 2'd3;
                    end

                    default: begin
                        spi_sck_int <= 1'b0;
                        if (spi_bit_cnt == 3'd0) begin
                            spi_active   <= 1'b0;
                            spi_byte_done <= 1'b1;
                            spi_rx_byte  <= {spi_rx_shift[6:0], flash_d1};
                        end else begin
                            spi_bit_cnt  <= spi_bit_cnt - 1'b1;
                            spi_tx_shift <= {spi_tx_shift[6:0], 1'b0};
                            spi_phase    <= 2'd0;
                        end
                    end
                endcase
            end else if (spi_byte_start) begin
                spi_active   <= 1'b1;
                spi_phase    <= 2'd0;
                spi_bit_cnt  <= 3'd7;
                spi_tx_shift <= spi_tx_byte;
                spi_rx_shift <= 8'd0;
            end
        end
    end

`ifndef SYNTHESIS
    wire unused_cfgclk;
    wire unused_cfgmclk;
    wire unused_eos;
    wire unused_preq;
`endif

    STARTUPE2 u_startupe2 (
        .CFGCLK    (),
        .CFGMCLK   (),
        .EOS       (),
        .PREQ      (),
        .CLK       (1'b0),
        .GSR       (1'b0),
        .GTS       (1'b0),
        .KEYCLEARB (1'b1),
        .PACK      (1'b0),
        .USRCCLKO  (spi_sck_int),
        .USRCCLKTS (1'b0),
        .USRDONEO  (1'b1),
        .USRDONETS (1'b1)
    );

    always @(posedge clk) begin
        if (rst) begin
            state            <= ST_BOOT_WAIT;
            next_after_poll  <= ST_IDLE;
            startup_cnt      <= 32'd0;
            poll_timeout_cnt <= 23'd0;
            params_latched   <= {PARAM_BITS{1'b0}};
            params_out       <= {PARAM_BITS{1'b0}};
            load_valid       <= 1'b0;
            busy             <= 1'b0;
            error            <= 1'b0;
            flash_cs_n       <= 1'b1;
            data_byte_idx    <= 6'd0;
            auto_load_done   <= 1'b0;
            for (i = 0; i < PARAM_WORDS; i = i + 1)
                read_words[i] <= 32'd0;
        end else begin
            spi_byte_start <= 1'b0;
            load_valid <= 1'b0;

            case (state)
                ST_BOOT_WAIT: begin
                    flash_cs_n <= 1'b1;
                    busy       <= 1'b0;
                    if (startup_cnt == STARTUP_WAIT_CYCLES - 1) begin
                        startup_cnt    <= 32'd0;
                        auto_load_done <= 1'b1;
                        busy           <= 1'b1;
                        error          <= 1'b0;
                        data_byte_idx  <= 6'd0;
                        for (i = 0; i < PARAM_WORDS; i = i + 1)
                            read_words[i] <= 32'd0;
                        state <= ST_READ_CS;
                    end else begin
                        startup_cnt <= startup_cnt + 1'b1;
                    end
                end

                ST_IDLE: begin
                    flash_cs_n <= 1'b1;
                    busy       <= 1'b0;
                    if (save_req) begin
                        params_latched <= params_in;
                        poll_timeout_cnt <= 23'd0;
                        busy          <= 1'b1;
                        error         <= 1'b0;
                        state         <= ST_WREN_CS;
                    end else if (load_req) begin
                        data_byte_idx <= 6'd0;
                        busy          <= 1'b1;
                        error         <= 1'b0;
                        for (i = 0; i < PARAM_WORDS; i = i + 1)
                            read_words[i] <= 32'd0;
                        state <= ST_READ_CS;
                    end
                end

                ST_WREN_CS: begin
                    flash_cs_n <= 1'b0;
                    state      <= ST_WREN_CMD;
                end

                ST_WREN_CMD: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= CMD_WREN;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_WREN_DONE;
                end

                ST_WREN_DONE: begin
                    flash_cs_n <= 1'b1;
                    state      <= ST_ERASE_CS;
                end

                ST_ERASE_CS: begin
                    flash_cs_n <= 1'b0;
                    state      <= ST_ERASE_CMD;
                end

                ST_ERASE_CMD: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= CMD_SE;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_ERASE_A2;
                end

                ST_ERASE_A2: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[23:16];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_ERASE_A1;
                end

                ST_ERASE_A1: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[15:8];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_ERASE_A0;
                end

                ST_ERASE_A0: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[7:0];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_ERASE_DONE;
                end

                ST_ERASE_DONE: begin
                    flash_cs_n       <= 1'b1;
                    poll_timeout_cnt <= 23'd0;
                    next_after_poll  <= ST_PP_CS;
                    state            <= ST_POLL_CS;
                end

                ST_POLL_CS: begin
                    flash_cs_n <= 1'b0;
                    state      <= ST_POLL_CMD;
                end

                ST_POLL_CMD: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= CMD_RDSR;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_POLL_DATA;
                end

                ST_POLL_DATA: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= 8'h00;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_POLL_DONE;
                end

                ST_POLL_DONE: begin
                    flash_cs_n <= 1'b1;
                    if (!spi_rx_byte[0]) begin
                        state <= next_after_poll;
                    end else if (poll_timeout_cnt == POLL_TIMEOUT_CYCLES - 1) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end else begin
                        poll_timeout_cnt <= poll_timeout_cnt + 1'b1;
                        state            <= ST_POLL_CS;
                    end
                end

                ST_PP_CS: begin
                    flash_cs_n    <= 1'b0;
                    data_byte_idx <= 6'd0;
                    state         <= ST_PP_CMD;
                end

                ST_PP_CMD: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= CMD_PP;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_PP_A2;
                end

                ST_PP_A2: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[23:16];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_PP_A1;
                end

                ST_PP_A1: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[15:8];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_PP_A0;
                end

                ST_PP_A0: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[7:0];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_PP_DATA;
                end

                ST_PP_DATA: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= pack_byte(data_byte_idx, params_latched);
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done) begin
                        if (data_byte_idx == PARAM_BYTES - 1)
                            state <= ST_PP_DONE;
                        else
                            data_byte_idx <= data_byte_idx + 1'b1;
                    end
                end

                ST_PP_DONE: begin
                    flash_cs_n       <= 1'b1;
                    poll_timeout_cnt <= 23'd0;
                    next_after_poll  <= ST_IDLE;
                    state            <= ST_POLL_CS;
                end

                ST_READ_CS: begin
                    flash_cs_n <= 1'b0;
                    state      <= ST_READ_CMD;
                end

                ST_READ_CMD: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= CMD_READ;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_READ_A2;
                end

                ST_READ_A2: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[23:16];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_READ_A1;
                end

                ST_READ_A1: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[15:8];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_READ_A0;
                end

                ST_READ_A0: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= PARAM_SECTOR_ADDR[7:0];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done) begin
                        data_byte_idx <= 6'd0;
                        state         <= ST_READ_DATA;
                    end
                end

                ST_READ_DATA: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte   <= 8'h00;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done) begin
                        read_words[data_byte_idx[5:2]] <= {
                            read_words[data_byte_idx[5:2]][23:0],
                            spi_rx_byte
                        };

                        if (data_byte_idx == PARAM_BYTES - 1)
                            state <= ST_READ_DONE;
                        else
                            data_byte_idx <= data_byte_idx + 1'b1;
                    end
                end

                ST_READ_DONE: begin
                    flash_cs_n <= 1'b1;
                    busy       <= 1'b0;
                    if ((read_words[0] == PARAM_MAGIC) &&
                        (read_words[1] == PARAM_VERSION) &&
                        (read_words[8] == crc_expect)) begin
                        params_out <= {
                            read_words[6][31:0],
                            read_words[7][16:0],
                            read_words[5][15:0],
                            read_words[4][18:0],
                            read_words[2][31:0],
                            read_words[3][31:0]
                        };
                        load_valid <= 1'b1;
                        state      <= ST_IDLE;
                    end else begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end
                end

                ST_ERROR: begin
                    flash_cs_n <= 1'b1;
                    busy       <= 1'b0;
                    state      <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
