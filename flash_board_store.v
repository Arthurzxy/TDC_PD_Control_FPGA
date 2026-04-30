`timescale 1ns/1ps

//==============================================================================
// flash_board_store.v
// 共享配置 Flash 的板级参数存储模块。
// - 小参数区保存 DAC / TEC / NB6 / Gate 默认配置
// - 像素镜像区保存整幅 pixel_param_ram
// 像素表使用 8 字节对齐记录，保证每个 256B page 恰好写 32 个像素参数，
// 这样页写/页读的状态机更简单，也更容易定位异常。
//==============================================================================

module flash_board_store #(
    parameter integer PARAM_BITS            = 148,
    parameter integer PIXEL_ADDR_BITS       = 14,
    parameter [23:0] PARAM_SECTOR_ADDR      = 24'hFFF000,
    parameter [23:0] PIXEL_IMAGE_BASE_ADDR  = 24'hFDF000,
    parameter integer STARTUP_WAIT_CYCLES   = 100_000,
    parameter integer POLL_TIMEOUT_CYCLES   = 5_000_000
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         save_req,
    input  wire                         load_req,
    input  wire [PARAM_BITS-1:0]        params_in,
    output reg                          load_valid,
    output reg  [PARAM_BITS-1:0]        params_out,
    output reg                          pixel_load_valid,
    output reg  [PIXEL_ADDR_BITS-1:0]   pixel_load_addr,
    output reg  [35:0]                  pixel_load_data,
    input  wire                         pixel_load_ready,
    output reg  [PIXEL_ADDR_BITS-1:0]   pixel_rd_addr,
    input  wire [35:0]                  pixel_rd_data,
    output reg                          pixel_wr_en,
    output reg  [PIXEL_ADDR_BITS-1:0]   pixel_wr_addr,
    output reg  [35:0]                  pixel_wr_data,
    output reg                          busy,
    output reg                          error,
    output reg                          flash_cs_n,
    output reg                          flash_d0,
    input  wire                         flash_d1
);

    // SPI Flash 基本指令集：写使能、读状态、普通读、页写、4KB 擦除。
    localparam [7:0] CMD_WREN = 8'h06;
    localparam [7:0] CMD_RDSR = 8'h05;
    localparam [7:0] CMD_READ = 8'h03;
    localparam [7:0] CMD_PP   = 8'h02;
    localparam [7:0] CMD_SE   = 8'h20;

    // 头标识和版本号用于上电校验，避免把随机数据误当成默认参数。
    localparam [31:0] PARAM_MAGIC       = 32'h5041_524D;
    localparam [31:0] PARAM_VERSION_NEW = 32'h0001_0002;
    localparam [31:0] PARAM_VERSION_OLD = 32'h0001_0001;
    localparam [31:0] PIXEL_MAGIC       = 32'h5049_584C;

    localparam integer PARAM_WORDS            = 11;
    localparam integer PARAM_BYTES            = PARAM_WORDS * 4;
    localparam integer PIXEL_WORD_COUNT       = (1 << PIXEL_ADDR_BITS);
    localparam integer PIXEL_RECORD_BYTES     = 8;
    localparam integer PIXEL_PAGE_BYTES       = 256;
    localparam integer PIXEL_WORDS_PER_PAGE   = PIXEL_PAGE_BYTES / PIXEL_RECORD_BYTES;
    localparam integer PIXEL_TOTAL_BYTES      = PIXEL_WORD_COUNT * PIXEL_RECORD_BYTES;
    localparam integer PIXEL_PAGE_COUNT       = PIXEL_TOTAL_BYTES / PIXEL_PAGE_BYTES;
    localparam integer PIXEL_SECTOR_BYTES     = 4096;
    localparam integer PIXEL_SECTOR_COUNT     = PIXEL_TOTAL_BYTES / PIXEL_SECTOR_BYTES;
    localparam [31:0] PIXEL_META              = {8'd1, PIXEL_RECORD_BYTES[7:0], PIXEL_WORD_COUNT[15:0]};

    localparam [2:0] CTX_NONE       = 3'd0;
    localparam [2:0] CTX_PARAM_PP   = 3'd1;
    localparam [2:0] CTX_PARAM_READ = 3'd2;
    localparam [2:0] CTX_STATUS     = 3'd3;
    localparam [2:0] CTX_PIXEL_PP   = 3'd4;
    localparam [2:0] CTX_PIXEL_READ = 3'd5;

    localparam [5:0] ST_BOOT_WAIT            = 6'd0;
    localparam [5:0] ST_IDLE                 = 6'd1;
    localparam [5:0] ST_START_PARAM_READ     = 6'd2;
    localparam [5:0] ST_FINISH_PARAM_READ    = 6'd3;
    localparam [5:0] ST_START_PIXEL_READ     = 6'd4;
    localparam [5:0] ST_APPLY_PIXEL_READ     = 6'd5;
    localparam [5:0] ST_START_PARAM_WREN_ER  = 6'd6;
    localparam [5:0] ST_START_PARAM_ERASE    = 6'd7;
    localparam [5:0] ST_START_PARAM_WREN_PP  = 6'd8;
    localparam [5:0] ST_START_PARAM_PP       = 6'd9;
    localparam [5:0] ST_START_PIXEL_ER_INIT  = 6'd10;
    localparam [5:0] ST_START_PIXEL_WREN_ER  = 6'd11;
    localparam [5:0] ST_START_PIXEL_ERASE    = 6'd12;
    localparam [5:0] ST_FINISH_PIXEL_ERASE   = 6'd13;
    localparam [5:0] ST_FILL_PAGE_SET_ADDR   = 6'd14;
    localparam [5:0] ST_FILL_PAGE_WAIT       = 6'd15;
    localparam [5:0] ST_FILL_PAGE_STORE      = 6'd16;
    localparam [5:0] ST_START_PIXEL_WREN_PP  = 6'd17;
    localparam [5:0] ST_START_PIXEL_PP       = 6'd18;
    localparam [5:0] ST_FINISH_PIXEL_PAGE    = 6'd19;
    localparam [5:0] ST_START_POLL           = 6'd20;
    localparam [5:0] ST_FINISH_POLL          = 6'd21;
    localparam [5:0] ST_CMD_CS               = 6'd22;
    localparam [5:0] ST_CMD_OPCODE           = 6'd23;
    localparam [5:0] ST_CMD_ADDR2            = 6'd24;
    localparam [5:0] ST_CMD_ADDR1            = 6'd25;
    localparam [5:0] ST_CMD_ADDR0            = 6'd26;
    localparam [5:0] ST_CMD_TX_DATA          = 6'd27;
    localparam [5:0] ST_CMD_RX_DATA          = 6'd28;
    localparam [5:0] ST_CMD_DEASSERT         = 6'd29;
    localparam [5:0] ST_ERROR                = 6'd30;

    reg  [5:0]                    state;
    reg  [5:0]                    post_cmd_state;
    reg  [5:0]                    post_poll_state;
    reg                           boot_load;
    reg  [31:0]                   startup_cnt;
    reg  [31:0]                   poll_timeout_cnt;
    reg  [PARAM_BITS-1:0]         params_latched;
    reg  [31:0]                   read_words [0:PARAM_WORDS-1];
    reg  [7:0]                    pixel_entry_buf [0:PIXEL_RECORD_BYTES-1];
    reg  [7:0]                    page_buf [0:PIXEL_PAGE_BYTES-1];
    reg  [PIXEL_ADDR_BITS-1:0]    pixel_index;
    reg  [8:0]                    page_index;
    reg  [5:0]                    sector_index;
    reg  [5:0]                    page_word_index;
    reg  [7:0]                    status_byte;
    reg  [7:0]                    spi_tx_byte;
    reg  [7:0]                    spi_rx_byte;
    reg                           spi_byte_start;
    reg                           spi_sck_int;
    reg                           spi_active;
    reg  [1:0]                    spi_phase;
    reg  [2:0]                    spi_bit_cnt;
    reg  [7:0]                    spi_tx_shift;
    reg  [7:0]                    spi_rx_shift;
    reg                           spi_byte_done;
    reg  [7:0]                    cmd_opcode;
    reg                           cmd_has_addr;
    reg  [23:0]                   cmd_addr;
    reg  [8:0]                    cmd_tx_len;
    reg  [8:0]                    cmd_rx_len;
    reg  [8:0]                    cmd_byte_index;
    reg  [2:0]                    cmd_context;
    reg  [7:0]                    cmd_tx_data_byte;
    integer                       i;

    wire [31:0]                   param_crc_expect;
    wire                          param_valid;
    wire                          pixel_meta_valid;
    wire [35:0]                   pixel_entry_word;
    wire [8:0]                    page_byte_base;
    wire [PIXEL_ADDR_BITS-1:0]    page_word_addr;
    wire [23:0]                   pixel_page_flash_addr;
    wire [23:0]                   pixel_sector_flash_addr;
    wire [23:0]                   pixel_entry_flash_addr;

    // 这里使用轻量级异或校验，不追求强纠错，只用于快速检测参数区是否有效。
    function [31:0] calc_crc;
        input [PARAM_BITS-1:0] params;
        reg [48:0] gate_cfg;
        begin
            gate_cfg = params[147:99];
            calc_crc = PARAM_VERSION_NEW ^
                       params[63:32] ^
                       params[31:0] ^
                       {13'd0, params[82:64]} ^
                       {16'd0, params[98:83]} ^
                       gate_cfg[48:17] ^
                       {15'd0, gate_cfg[16:0]};
        end
    endfunction

    function [31:0] param_word;
        input [3:0] idx;
        input [PARAM_BITS-1:0] params;
        reg [48:0] gate_cfg;
        begin
            gate_cfg = params[147:99];
            case (idx)
                4'd0: param_word = PARAM_MAGIC;
                4'd1: param_word = PARAM_VERSION_NEW;
                4'd2: param_word = params[63:32];
                4'd3: param_word = params[31:0];
                4'd4: param_word = {13'd0, params[82:64]};
                4'd5: param_word = {16'd0, params[98:83]};
                4'd6: param_word = gate_cfg[48:17];
                4'd7: param_word = {15'd0, gate_cfg[16:0]};
                4'd8: param_word = calc_crc(params);
                4'd9: param_word = PIXEL_MAGIC;
                default: param_word = PIXEL_META;
            endcase
        end
    endfunction

    function [7:0] param_tx_byte;
        input [5:0] idx;
        input [PARAM_BITS-1:0] params;
        reg [31:0] word_sel;
        begin
            word_sel = param_word(idx[5:2], params);
            case (idx[1:0])
                2'd0: param_tx_byte = word_sel[31:24];
                2'd1: param_tx_byte = word_sel[23:16];
                2'd2: param_tx_byte = word_sel[15:8];
                default: param_tx_byte = word_sel[7:0];
            endcase
        end
    endfunction

    // 把一条 SPI 命令统一装载到状态机上下文，后续时序全部复用同一套 bit-bang 流程。
    task start_cmd;
        input [7:0] opcode_in;
        input       has_addr_in;
        input [23:0] addr_in;
        input [8:0] tx_len_in;
        input [8:0] rx_len_in;
        input [2:0] context_in;
        input [5:0] post_state_in;
        begin
            cmd_opcode     <= opcode_in;
            cmd_has_addr   <= has_addr_in;
            cmd_addr       <= addr_in;
            cmd_tx_len     <= tx_len_in;
            cmd_rx_len     <= rx_len_in;
            cmd_context    <= context_in;
            cmd_byte_index <= 9'd0;
            post_cmd_state <= post_state_in;
            state          <= ST_CMD_CS;
        end
    endtask

    // 读回参数区后，先做头校验，再决定是否把默认配置回灌到各模块。
    assign param_crc_expect = read_words[1] ^ read_words[2] ^ read_words[3] ^
                              read_words[4] ^ read_words[5] ^ read_words[6] ^
                              read_words[7];
    assign param_valid = (read_words[0] == PARAM_MAGIC) &&
                         ((read_words[1] == PARAM_VERSION_NEW) ||
                          (read_words[1] == PARAM_VERSION_OLD)) &&
                         (read_words[8] == param_crc_expect);
    assign pixel_meta_valid = (read_words[9] == PIXEL_MAGIC) &&
                              (read_words[10] == PIXEL_META);
    assign pixel_entry_word = {pixel_entry_buf[0][3:0], pixel_entry_buf[1], pixel_entry_buf[2],
                               pixel_entry_buf[3], pixel_entry_buf[4]};
    assign page_byte_base = {page_word_index, 3'b000};
    assign page_word_addr = ({page_index, 5'b000}) + page_word_index;
    assign pixel_page_flash_addr = PIXEL_IMAGE_BASE_ADDR + {page_index, 8'd0};
    assign pixel_sector_flash_addr = PIXEL_IMAGE_BASE_ADDR + {sector_index, 12'd0};
    assign pixel_entry_flash_addr = PIXEL_IMAGE_BASE_ADDR + {pixel_index, 3'b000};

    always @* begin
        cmd_tx_data_byte = 8'h00;
        case (cmd_context)
            CTX_PARAM_PP: cmd_tx_data_byte = param_tx_byte(cmd_byte_index[5:0], params_latched);
            CTX_PIXEL_PP: cmd_tx_data_byte = page_buf[cmd_byte_index[7:0]];
            default:      cmd_tx_data_byte = 8'h00;
        endcase
    end

    // SPI 位级状态机。这里不依赖专用 SPI IP，而是直接在 sys_clk 域串行移位，
    // 目的是和 STARTUPE2/CCLK_0 共用配置 Flash 时保持完全可控。
    always @(posedge clk) begin
        spi_byte_done <= 1'b0;

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
                            spi_active    <= 1'b0;
                            spi_byte_done <= 1'b1;
                            spi_rx_byte   <= {spi_rx_shift[6:0], flash_d1};
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

    // CCLK_0 是专用配置引脚，普通 OBUF 不能直接驱动，因此通过 STARTUPE2 把
    // 用户态时钟送到配置 Flash 的时钟线上。
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
            post_cmd_state   <= ST_IDLE;
            post_poll_state  <= ST_IDLE;
            boot_load        <= 1'b0;
            startup_cnt      <= 32'd0;
            poll_timeout_cnt <= 32'd0;
            params_latched   <= {PARAM_BITS{1'b0}};
            params_out       <= {PARAM_BITS{1'b0}};
            load_valid       <= 1'b0;
            pixel_load_valid <= 1'b0;
            pixel_load_addr  <= {PIXEL_ADDR_BITS{1'b0}};
            pixel_load_data  <= 36'd0;
            pixel_rd_addr    <= {PIXEL_ADDR_BITS{1'b0}};
            pixel_wr_en      <= 1'b0;
            pixel_wr_addr    <= {PIXEL_ADDR_BITS{1'b0}};
            pixel_wr_data    <= 36'd0;
            pixel_index      <= {PIXEL_ADDR_BITS{1'b0}};
            page_index       <= 9'd0;
            sector_index     <= 6'd0;
            page_word_index  <= 6'd0;
            status_byte      <= 8'd0;
            spi_tx_byte      <= 8'd0;
            spi_byte_start   <= 1'b0;
            busy             <= 1'b0;
            error            <= 1'b0;
            flash_cs_n       <= 1'b1;
            for (i = 0; i < PARAM_WORDS; i = i + 1)
                read_words[i] <= 32'd0;
            for (i = 0; i < PIXEL_RECORD_BYTES; i = i + 1)
                pixel_entry_buf[i] <= 8'd0;
        end else begin
            spi_byte_start   <= 1'b0;
            load_valid       <= 1'b0;
            pixel_load_valid <= 1'b0;
            pixel_wr_en      <= 1'b0;

            case (state)
                ST_BOOT_WAIT: begin
                    flash_cs_n <= 1'b1;
                    busy       <= 1'b0;
                    if (startup_cnt == STARTUP_WAIT_CYCLES - 1) begin
                        startup_cnt <= 32'd0;
                        boot_load   <= 1'b1;
                        busy        <= 1'b1;
                        error       <= 1'b0;
                        state       <= ST_START_PARAM_READ;
                    end else begin
                        startup_cnt <= startup_cnt + 1'b1;
                    end
                end

                ST_IDLE: begin
                    flash_cs_n <= 1'b1;
                    busy       <= 1'b0;
                    if (save_req) begin
                        params_latched <= params_in;
                        busy           <= 1'b1;
                        error          <= 1'b0;
                        state          <= ST_START_PARAM_WREN_ER;
                    end else if (load_req) begin
                        busy      <= 1'b1;
                        error     <= 1'b0;
                        boot_load <= 1'b0;
                        state     <= ST_START_PARAM_READ;
                    end
                end

                ST_START_PARAM_READ: begin
                    for (i = 0; i < PARAM_WORDS; i = i + 1)
                        read_words[i] <= 32'd0;
                    start_cmd(CMD_READ, 1'b1, PARAM_SECTOR_ADDR, 9'd0, PARAM_BYTES[8:0],
                              CTX_PARAM_READ, ST_FINISH_PARAM_READ);
                end

                ST_FINISH_PARAM_READ: begin
                    if (param_valid) begin
                        params_out <= {
                            read_words[6][31:0],
                            read_words[7][16:0],
                            read_words[5][15:0],
                            read_words[4][18:0],
                            read_words[2][31:0],
                            read_words[3][31:0]
                        };
                        load_valid <= 1'b1;
                        if (pixel_meta_valid) begin
                            pixel_index <= {PIXEL_ADDR_BITS{1'b0}};
                            state       <= ST_START_PIXEL_READ;
                        end else begin
                            busy      <= 1'b0;
                            boot_load <= 1'b0;
                            state     <= ST_IDLE;
                        end
                    end else begin
                        busy <= 1'b0;
                        if (!boot_load)
                            error <= 1'b1;
                        boot_load <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                ST_START_PIXEL_READ: begin
                    start_cmd(CMD_READ, 1'b1, pixel_entry_flash_addr, 9'd0,
                              PIXEL_RECORD_BYTES[8:0], CTX_PIXEL_READ, ST_APPLY_PIXEL_READ);
                end

                ST_APPLY_PIXEL_READ: begin
                    if (pixel_load_ready) begin
                        pixel_wr_en      <= 1'b1;
                        pixel_wr_addr    <= pixel_index;
                        pixel_wr_data    <= pixel_entry_word;
                        pixel_load_valid <= 1'b1;
                        pixel_load_addr  <= pixel_index;
                        pixel_load_data  <= pixel_entry_word;
                        if (pixel_index == PIXEL_WORD_COUNT - 1) begin
                            busy      <= 1'b0;
                            boot_load <= 1'b0;
                            state     <= ST_IDLE;
                        end else begin
                            pixel_index <= pixel_index + 1'b1;
                            state       <= ST_START_PIXEL_READ;
                        end
                    end
                end

                ST_START_PARAM_WREN_ER: begin
                    start_cmd(CMD_WREN, 1'b0, 24'd0, 9'd0, 9'd0, CTX_NONE, ST_START_PARAM_ERASE);
                end

                ST_START_PARAM_ERASE: begin
                    start_cmd(CMD_SE, 1'b1, PARAM_SECTOR_ADDR, 9'd0, 9'd0, CTX_NONE, ST_START_POLL);
                    post_poll_state  <= ST_START_PARAM_WREN_PP;
                    poll_timeout_cnt <= 32'd0;
                end

                ST_START_PARAM_WREN_PP: begin
                    start_cmd(CMD_WREN, 1'b0, 24'd0, 9'd0, 9'd0, CTX_NONE, ST_START_PARAM_PP);
                end

                ST_START_PARAM_PP: begin
                    start_cmd(CMD_PP, 1'b1, PARAM_SECTOR_ADDR, PARAM_BYTES[8:0], 9'd0,
                              CTX_PARAM_PP, ST_START_POLL);
                    post_poll_state  <= ST_START_PIXEL_ER_INIT;
                    poll_timeout_cnt <= 32'd0;
                end

                ST_START_PIXEL_ER_INIT: begin
                    sector_index <= 6'd0;
                    state        <= ST_START_PIXEL_WREN_ER;
                end

                ST_START_PIXEL_WREN_ER: begin
                    start_cmd(CMD_WREN, 1'b0, 24'd0, 9'd0, 9'd0, CTX_NONE, ST_START_PIXEL_ERASE);
                end

                ST_START_PIXEL_ERASE: begin
                    start_cmd(CMD_SE, 1'b1, pixel_sector_flash_addr, 9'd0, 9'd0,
                              CTX_NONE, ST_START_POLL);
                    post_poll_state  <= ST_FINISH_PIXEL_ERASE;
                    poll_timeout_cnt <= 32'd0;
                end

                ST_FINISH_PIXEL_ERASE: begin
                    if (sector_index == PIXEL_SECTOR_COUNT - 1) begin
                        page_index      <= 9'd0;
                        page_word_index <= 6'd0;
                        state           <= ST_FILL_PAGE_SET_ADDR;
                    end else begin
                        sector_index <= sector_index + 1'b1;
                        state        <= ST_START_PIXEL_WREN_ER;
                    end
                end

                ST_FILL_PAGE_SET_ADDR: begin
                    pixel_rd_addr <= page_word_addr;
                    state         <= ST_FILL_PAGE_WAIT;
                end

                ST_FILL_PAGE_WAIT: begin
                    state <= ST_FILL_PAGE_STORE;
                end

                ST_FILL_PAGE_STORE: begin
                    page_buf[page_byte_base + 0] <= {4'd0, pixel_rd_data[35:32]};
                    page_buf[page_byte_base + 1] <= pixel_rd_data[31:24];
                    page_buf[page_byte_base + 2] <= pixel_rd_data[23:16];
                    page_buf[page_byte_base + 3] <= pixel_rd_data[15:8];
                    page_buf[page_byte_base + 4] <= pixel_rd_data[7:0];
                    page_buf[page_byte_base + 5] <= 8'd0;
                    page_buf[page_byte_base + 6] <= 8'd0;
                    page_buf[page_byte_base + 7] <= 8'd0;
                    if (page_word_index == PIXEL_WORDS_PER_PAGE - 1) begin
                        state <= ST_START_PIXEL_WREN_PP;
                    end else begin
                        page_word_index <= page_word_index + 1'b1;
                        state           <= ST_FILL_PAGE_SET_ADDR;
                    end
                end

                ST_START_PIXEL_WREN_PP: begin
                    start_cmd(CMD_WREN, 1'b0, 24'd0, 9'd0, 9'd0, CTX_NONE, ST_START_PIXEL_PP);
                end

                ST_START_PIXEL_PP: begin
                    start_cmd(CMD_PP, 1'b1, pixel_page_flash_addr, PIXEL_PAGE_BYTES[8:0], 9'd0,
                              CTX_PIXEL_PP, ST_START_POLL);
                    post_poll_state  <= ST_FINISH_PIXEL_PAGE;
                    poll_timeout_cnt <= 32'd0;
                end

                ST_FINISH_PIXEL_PAGE: begin
                    if (page_index == PIXEL_PAGE_COUNT - 1) begin
                        busy  <= 1'b0;
                        state <= ST_IDLE;
                    end else begin
                        page_index      <= page_index + 1'b1;
                        page_word_index <= 6'd0;
                        state           <= ST_FILL_PAGE_SET_ADDR;
                    end
                end

                ST_START_POLL: begin
                    start_cmd(CMD_RDSR, 1'b0, 24'd0, 9'd0, 9'd1, CTX_STATUS, ST_FINISH_POLL);
                end

                ST_FINISH_POLL: begin
                    if (!status_byte[0]) begin
                        state <= post_poll_state;
                    end else if (poll_timeout_cnt == POLL_TIMEOUT_CYCLES - 1) begin
                        error <= 1'b1;
                        busy  <= 1'b0;
                        state <= ST_ERROR;
                    end else begin
                        poll_timeout_cnt <= poll_timeout_cnt + 1'b1;
                        state            <= ST_START_POLL;
                    end
                end

                ST_CMD_CS: begin
                    flash_cs_n     <= 1'b0;
                    cmd_byte_index <= 9'd0;
                    state          <= ST_CMD_OPCODE;
                end

                ST_CMD_OPCODE: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte    <= cmd_opcode;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done) begin
                        if (cmd_has_addr)
                            state <= ST_CMD_ADDR2;
                        else if (cmd_tx_len != 9'd0)
                            state <= ST_CMD_TX_DATA;
                        else if (cmd_rx_len != 9'd0)
                            state <= ST_CMD_RX_DATA;
                        else
                            state <= ST_CMD_DEASSERT;
                    end
                end

                ST_CMD_ADDR2: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte    <= cmd_addr[23:16];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_CMD_ADDR1;
                end

                ST_CMD_ADDR1: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte    <= cmd_addr[15:8];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done)
                        state <= ST_CMD_ADDR0;
                end

                ST_CMD_ADDR0: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte    <= cmd_addr[7:0];
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done) begin
                        cmd_byte_index <= 9'd0;
                        if (cmd_tx_len != 9'd0)
                            state <= ST_CMD_TX_DATA;
                        else if (cmd_rx_len != 9'd0)
                            state <= ST_CMD_RX_DATA;
                        else
                            state <= ST_CMD_DEASSERT;
                    end
                end

                ST_CMD_TX_DATA: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte    <= cmd_tx_data_byte;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done) begin
                        if (cmd_byte_index == cmd_tx_len - 1'b1) begin
                            cmd_byte_index <= 9'd0;
                            if (cmd_rx_len != 9'd0)
                                state <= ST_CMD_RX_DATA;
                            else
                                state <= ST_CMD_DEASSERT;
                        end else begin
                            cmd_byte_index <= cmd_byte_index + 1'b1;
                        end
                    end
                end

                ST_CMD_RX_DATA: begin
                    if (!spi_active && !spi_byte_done) begin
                        spi_tx_byte    <= 8'h00;
                        spi_byte_start <= 1'b1;
                    end
                    if (spi_byte_done) begin
                        case (cmd_context)
                            CTX_PARAM_READ: begin
                                read_words[cmd_byte_index[8:2]] <= {
                                    read_words[cmd_byte_index[8:2]][23:0],
                                    spi_rx_byte
                                };
                            end

                            CTX_STATUS: begin
                                status_byte <= spi_rx_byte;
                            end

                            CTX_PIXEL_READ: begin
                                pixel_entry_buf[cmd_byte_index[2:0]] <= spi_rx_byte;
                            end

                            default: begin
                            end
                        endcase

                        if (cmd_byte_index == cmd_rx_len - 1'b1)
                            state <= ST_CMD_DEASSERT;
                        else
                            cmd_byte_index <= cmd_byte_index + 1'b1;
                    end
                end

                ST_CMD_DEASSERT: begin
                    flash_cs_n <= 1'b1;
                    state      <= post_cmd_state;
                end

                ST_ERROR: begin
                    flash_cs_n <= 1'b1;
                    state      <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
