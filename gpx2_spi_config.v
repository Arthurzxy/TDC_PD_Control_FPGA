`timescale 1ns/1ps

module gpx2_spi_config #(
    parameter integer SPI_DIV = 4,
    parameter integer SYS_CLK_HZ = 100_000_000,
    parameter integer POST_INIT_WAIT_US = 200
)(
    input  wire clk,
    input  wire rst,

    input  wire start,
    output reg  config_done,
    output reg  config_error,
    output reg  busy,

    output reg  ssn,
    output reg  sck,
    output reg  mosi,
    input  wire miso
);

    localparam [7:0] OPC_POWER = 8'h30;
    localparam [7:0] OPC_INIT  = 8'h18;
    localparam [7:0] OPC_WCFG0 = 8'h80;
    localparam [7:0] OPC_RCFG0 = 8'h40;

    localparam integer CFG_BYTES = 17;
    localparam integer WAIT_CYCLES = (SYS_CLK_HZ / 1_000_000) * POST_INIT_WAIT_US;

    localparam ST_IDLE       = 5'd0;
    localparam ST_POWER_LOAD = 5'd1;
    localparam ST_POWER_WAIT = 5'd2;
    localparam ST_WOPC_LOAD  = 5'd3;
    localparam ST_WOPC_WAIT  = 5'd4;
    localparam ST_WDATA_LOAD = 5'd5;
    localparam ST_WDATA_WAIT = 5'd6;
    localparam ST_ROPC_LOAD  = 5'd7;
    localparam ST_ROPC_WAIT  = 5'd8;
    localparam ST_RDATA_LOAD = 5'd9;
    localparam ST_RDATA_WAIT = 5'd10;
    localparam ST_INIT_LOAD  = 5'd11;
    localparam ST_INIT_WAIT  = 5'd12;
    localparam ST_POST_WAIT  = 5'd13;
    localparam ST_DONE       = 5'd14;

    reg [4:0] state;
    reg [7:0] tx_byte;
    reg [7:0] active_tx_byte;
    reg [7:0] rx_byte;
    reg [2:0] bit_idx;
    reg [15:0] div_cnt;
    reg spi_active;
    reg byte_done;
    reg [$clog2(CFG_BYTES+1)-1:0] cfg_idx;
    reg [31:0] wait_cnt;

    function [7:0] cfg_byte;
        input integer idx;
        begin
            case (idx)
                0:  cfg_byte = 8'h3F;
                1:  cfg_byte = 8'h4F;
                2:  cfg_byte = 8'h24;
                3:  cfg_byte = 8'hD4;
                4:  cfg_byte = 8'h30;
                5:  cfg_byte = 8'h00;
                6:  cfg_byte = 8'hC0;
                7:  cfg_byte = 8'h53;
                8:  cfg_byte = 8'hA1;
                9:  cfg_byte = 8'h13;
                10: cfg_byte = 8'h00;
                11: cfg_byte = 8'h0A;
                12: cfg_byte = 8'hCC;
                13: cfg_byte = 8'hCC;
                14: cfg_byte = 8'hF1;
                15: cfg_byte = 8'h7D;
                default: cfg_byte = 8'h00;
            endcase
        end
    endfunction

    wire load_byte =
        (state == ST_POWER_LOAD) ||
        (state == ST_WOPC_LOAD)  ||
        (state == ST_WDATA_LOAD) ||
        (state == ST_ROPC_LOAD)  ||
        (state == ST_RDATA_LOAD) ||
        (state == ST_INIT_LOAD);

    wire [7:0] load_tx_byte =
        (state == ST_POWER_LOAD) ? OPC_POWER :
        (state == ST_WOPC_LOAD)  ? OPC_WCFG0 :
        (state == ST_WDATA_LOAD) ? cfg_byte(cfg_idx) :
        (state == ST_ROPC_LOAD)  ? OPC_RCFG0 :
        (state == ST_INIT_LOAD)  ? OPC_INIT  :
                                   8'h00;

    always @(posedge clk) begin
        if (rst) begin
            sck        <= 1'b0;
            mosi       <= 1'b0;
            active_tx_byte <= 8'd0;
            div_cnt    <= 16'd0;
            bit_idx    <= 3'd7;
            rx_byte    <= 8'd0;
            byte_done  <= 1'b0;
            spi_active <= 1'b0;
        end else begin
            byte_done <= 1'b0;

            if (load_byte) begin
                spi_active <= 1'b1;
                div_cnt    <= 16'd0;
                bit_idx    <= 3'd7;
                sck        <= 1'b0;
                active_tx_byte <= load_tx_byte;
                mosi       <= load_tx_byte[7];
                rx_byte    <= 8'd0;
            end else if (spi_active) begin
                if (div_cnt == SPI_DIV-1) begin
                    div_cnt <= 16'd0;

                    if (sck == 1'b0) begin
                        sck <= 1'b1;
                        rx_byte[bit_idx] <= miso;
                    end else begin
                        sck <= 1'b0;
                        if (bit_idx == 3'd0) begin
                            spi_active <= 1'b0;
                            byte_done  <= 1'b1;
                        end else begin
                            bit_idx <= bit_idx - 1'b1;
                            mosi    <= active_tx_byte[bit_idx-1];
                        end
                    end
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end else begin
                div_cnt <= 16'd0;
                sck     <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_IDLE;
            ssn          <= 1'b1;
            tx_byte      <= 8'd0;
            cfg_idx      <= 0;
            wait_cnt     <= 32'd0;
            busy         <= 1'b0;
            config_done  <= 1'b0;
            config_error <= 1'b0;
        end else begin
            config_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    ssn     <= 1'b1;
                    busy    <= 1'b0;
                    cfg_idx <= 0;
                    if (start) begin
                        busy         <= 1'b1;
                        config_error <= 1'b0;
                        state        <= ST_POWER_LOAD;
                    end
                end

                ST_POWER_LOAD: begin
                    ssn     <= 1'b0;
                    tx_byte <= OPC_POWER;
                    state   <= ST_POWER_WAIT;
                end
                ST_POWER_WAIT: if (byte_done) begin
                    ssn   <= 1'b1;
                    state <= ST_WOPC_LOAD;
                end

                ST_WOPC_LOAD: begin
                    ssn     <= 1'b0;
                    tx_byte <= OPC_WCFG0;
                    cfg_idx <= 0;
                    state   <= ST_WOPC_WAIT;
                end
                ST_WOPC_WAIT: if (byte_done)
                    state <= ST_WDATA_LOAD;

                ST_WDATA_LOAD: begin
                    tx_byte <= cfg_byte(cfg_idx);
                    state   <= ST_WDATA_WAIT;
                end
                ST_WDATA_WAIT: if (byte_done) begin
                    if (cfg_idx == CFG_BYTES-1) begin
                        ssn   <= 1'b1;
                        state <= ST_ROPC_LOAD;
                    end else begin
                        cfg_idx <= cfg_idx + 1'b1;
                        state   <= ST_WDATA_LOAD;
                    end
                end

                ST_ROPC_LOAD: begin
                    ssn     <= 1'b0;
                    tx_byte <= OPC_RCFG0;
                    cfg_idx <= 0;
                    state   <= ST_ROPC_WAIT;
                end
                ST_ROPC_WAIT: if (byte_done)
                    state <= ST_RDATA_LOAD;

                ST_RDATA_LOAD: begin
                    tx_byte <= 8'h00;
                    state   <= ST_RDATA_WAIT;
                end
                ST_RDATA_WAIT: if (byte_done) begin
                    if (rx_byte != cfg_byte(cfg_idx))
                        config_error <= 1'b1;
                    if (cfg_idx == CFG_BYTES-1) begin
                        ssn   <= 1'b1;
                        state <= ST_INIT_LOAD;
                    end else begin
                        cfg_idx <= cfg_idx + 1'b1;
                        state   <= ST_RDATA_LOAD;
                    end
                end

                ST_INIT_LOAD: begin
                    ssn     <= 1'b0;
                    tx_byte <= OPC_INIT;
                    state   <= ST_INIT_WAIT;
                end
                ST_INIT_WAIT: if (byte_done) begin
                    ssn      <= 1'b1;
                    wait_cnt <= 32'd0;
                    state    <= ST_POST_WAIT;
                end

                ST_POST_WAIT: begin
                    if (wait_cnt >= WAIT_CYCLES[31:0])
                        state <= ST_DONE;
                    else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                ST_DONE: begin
                    busy        <= 1'b0;
                    config_done <= ~config_error;
                    state       <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
