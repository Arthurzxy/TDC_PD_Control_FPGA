//==============================================================================
// ft601_fifo_if.v
//------------------------------------------------------------------------------
// FT601 synchronous FIFO pin interface.
//
// This implementation follows the structure of FTDI's master FIFO examples:
// the FT601 pin timing layer is isolated from user logic by small local
// buffers. Host-to-FPGA data is drained as soon as RXF_N allows it, and
// FPGA-to-host data is prefetched and held stable before WR_N is asserted.
//==============================================================================

`timescale 1ns/1ps

module ft601_fifo_if #(
    parameter integer DATA_WIDTH = 32,
    parameter integer BE_WIDTH   = 4
)(
    input  wire                  ft_clk,
    input  wire                  sys_clk,
    input  wire                  rst,

    inout  wire [DATA_WIDTH-1:0] ft_data,
    inout  wire [BE_WIDTH-1:0]   ft_be,
    input  wire                  ft_txe_n,
    input  wire                  ft_rxf_n,
    output reg                   ft_wr_n,
    output reg                   ft_rd_n,
    output reg                   ft_oe_n,
    output wire                  ft_siwu_n,

    input  wire [DATA_WIDTH-1:0] tx_data,
    input  wire [BE_WIDTH-1:0]   tx_be,
    input  wire                  tx_valid,
    output wire                  tx_ready,

    output wire [DATA_WIDTH-1:0] rx_data,
    output wire [BE_WIDTH-1:0]   rx_be,
    output wire                  rx_valid,
    input  wire                  rx_ready,

    output wire [2:0]            dbg_state
);
    localparam integer RX_FIFO_DEPTH = 16;
    localparam integer RX_FIFO_AW    = 4;
    localparam [RX_FIFO_AW:0] RX_FIFO_DEPTH_COUNT = RX_FIFO_DEPTH;

    localparam ST_IDLE       = 3'd0;
    localparam ST_TX_PREP    = 3'd1;
    localparam ST_TX_STROBE  = 3'd2;
    localparam ST_RX_OE      = 3'd3;
    localparam ST_RX_STROBE  = 3'd4;
    localparam ST_RX_CAPTURE = 3'd5;

    assign ft_siwu_n = 1'b1;

    reg                  data_oe;
    reg                  be_oe;
    reg [DATA_WIDTH-1:0] data_out_reg;
    reg [BE_WIDTH-1:0]   be_out_reg;

    assign ft_data = data_oe ? data_out_reg : {DATA_WIDTH{1'bz}};
    assign ft_be   = be_oe   ? be_out_reg   : {BE_WIDTH{1'bz}};

    reg [DATA_WIDTH-1:0] rx_fifo_data [0:RX_FIFO_DEPTH-1];
    reg [BE_WIDTH-1:0]   rx_fifo_be   [0:RX_FIFO_DEPTH-1];
    reg [RX_FIFO_AW-1:0] rx_wr_ptr;
    reg [RX_FIFO_AW-1:0] rx_rd_ptr;
    reg [RX_FIFO_AW:0]   rx_count;

    wire rx_fifo_empty       = (rx_count == {RX_FIFO_AW+1{1'b0}});
    wire rx_fifo_full        = (rx_count == RX_FIFO_DEPTH_COUNT);
    wire rx_fifo_almost_full = (rx_count >= (RX_FIFO_DEPTH-1));

    reg [DATA_WIDTH-1:0] rx_out_data;
    reg [BE_WIDTH-1:0]   rx_out_be;
    reg                  rx_out_valid;

    assign rx_data  = rx_out_data;
    assign rx_be    = rx_out_be;
    assign rx_valid = rx_out_valid;

    reg                  tx_buf_valid;
    reg [DATA_WIDTH-1:0] tx_buf_data;
    reg [BE_WIDTH-1:0]   tx_buf_be;

    assign tx_ready = !tx_buf_valid;

    (* fsm_encoding = "none" *) reg [2:0] state;
    assign dbg_state = state;

    wire rx_push = (state == ST_RX_CAPTURE) && !ft_rxf_n && !rx_fifo_full;

    ila_ft601 usb3_ila (
        .clk(ft_clk),
        .probe0(state),
        // Probe fabric-side registered buses. Probing the top-level inout IO
        // nets directly adds illegal loads to the IOBUF IO pins during place.
        .probe1(data_out_reg),
        .probe2(be_out_reg),
        .probe3(ft_wr_n),
        .probe4(ft_rd_n),
        .probe5(ft_oe_n),
        .probe6(rx_valid),
        .probe7(ft_siwu_n),
        .probe8(rx_data),
        .probe9(rx_be),
        .probe10(rx_ready),
        .probe11(rx_valid),
        .probe12(rx_out_data),
        .probe13(rx_out_be),
        .probe14(rx_out_valid),
        .probe15(tx_ready)
    );

    initial begin
        state        = ST_IDLE;
        ft_wr_n      = 1'b1;
        ft_rd_n      = 1'b1;
        ft_oe_n      = 1'b1;
        data_oe      = 1'b0;
        be_oe        = 1'b0;
        data_out_reg = {DATA_WIDTH{1'b0}};
        be_out_reg   = {BE_WIDTH{1'b0}};
        rx_wr_ptr    = {RX_FIFO_AW{1'b0}};
        rx_rd_ptr    = {RX_FIFO_AW{1'b0}};
        rx_count     = {RX_FIFO_AW+1{1'b0}};
        rx_out_data  = {DATA_WIDTH{1'b0}};
        rx_out_be    = {BE_WIDTH{1'b1}};
        rx_out_valid = 1'b0;
        tx_buf_valid = 1'b0;
        tx_buf_data  = {DATA_WIDTH{1'b0}};
        tx_buf_be    = {BE_WIDTH{1'b1}};
    end

    always @(posedge ft_clk) begin
        if (rst) begin
            state        <= ST_IDLE;
            ft_wr_n      <= 1'b1;
            ft_rd_n      <= 1'b1;
            ft_oe_n      <= 1'b1;
            data_oe      <= 1'b0;
            be_oe        <= 1'b0;
            data_out_reg <= {DATA_WIDTH{1'b0}};
            be_out_reg   <= {BE_WIDTH{1'b0}};
            rx_wr_ptr    <= {RX_FIFO_AW{1'b0}};
            rx_rd_ptr    <= {RX_FIFO_AW{1'b0}};
            rx_count     <= {RX_FIFO_AW+1{1'b0}};
            rx_out_data  <= {DATA_WIDTH{1'b0}};
            rx_out_be    <= {BE_WIDTH{1'b1}};
            rx_out_valid <= 1'b0;
            tx_buf_valid <= 1'b0;
            tx_buf_data  <= {DATA_WIDTH{1'b0}};
            tx_buf_be    <= {BE_WIDTH{1'b1}};
        end else begin
            ft_wr_n <= 1'b1;
            ft_rd_n <= 1'b1;
            ft_oe_n <= 1'b1;
            data_oe <= 1'b0;
            be_oe   <= 1'b0;

            if (tx_valid && tx_ready) begin
                tx_buf_valid <= 1'b1;
                tx_buf_data  <= tx_data;
                tx_buf_be    <= tx_be;
            end

            if (rx_ready && rx_out_valid)
                rx_out_valid <= 1'b0;

            if ((rx_ready || !rx_out_valid) && !rx_fifo_empty) begin
                rx_out_data  <= rx_fifo_data[rx_rd_ptr];
                rx_out_be    <= rx_fifo_be[rx_rd_ptr];
                rx_out_valid <= 1'b1;
                rx_rd_ptr    <= rx_rd_ptr + 1'b1;
                if (!rx_push)
                    rx_count <= rx_count - 1'b1;
            end

            if (rx_push) begin
                if ((rx_ready || !rx_out_valid) && rx_fifo_empty) begin
                    rx_out_data  <= ft_data;
                    rx_out_be    <= ft_be;
                    rx_out_valid <= 1'b1;
                end else begin
                    rx_fifo_data[rx_wr_ptr] <= ft_data;
                    rx_fifo_be[rx_wr_ptr]   <= ft_be;
                    rx_wr_ptr               <= rx_wr_ptr + 1'b1;
                    if (!((rx_ready || !rx_out_valid) && !rx_fifo_empty))
                        rx_count <= rx_count + 1'b1;
                end
            end

            case (state)
                ST_IDLE: begin
                    // Give host writes priority. This prevents PC WritePipe
                    // timeouts while the command parser is briefly busy.
                    if (!ft_rxf_n && !rx_fifo_almost_full) begin
                        ft_oe_n <= 1'b0;
                        state   <= ST_RX_OE;
                    end else if (tx_buf_valid && !ft_txe_n) begin
                        data_out_reg <= tx_buf_data;
                        be_out_reg   <= tx_buf_be;
                        data_oe      <= 1'b1;
                        be_oe        <= 1'b1;
                        state        <= ST_TX_PREP;
                    end
                end

                ST_TX_PREP: begin
                    data_oe <= 1'b1;
                    be_oe   <= 1'b1;
                    if (!ft_txe_n)
                        state <= ST_TX_STROBE;
                    else
                        state <= ST_TX_PREP;
                end

                ST_TX_STROBE: begin
                    data_oe      <= 1'b1;
                    be_oe        <= 1'b1;
                    if (!ft_txe_n) begin
                        ft_wr_n      <= 1'b0;
                        tx_buf_valid <= 1'b0;
                        state        <= ST_IDLE;
                    end else begin
                        state        <= ST_TX_PREP;
                    end
                end

                ST_RX_OE: begin
                    if (ft_rxf_n || rx_fifo_almost_full) begin
                        state <= ST_IDLE;
                    end else begin
                        ft_oe_n <= 1'b0;
                        ft_rd_n <= 1'b0;
                        state   <= ST_RX_CAPTURE;
                    end
                end

                ST_RX_CAPTURE: begin
                    if (!ft_rxf_n && !rx_fifo_almost_full) begin
                        // Keep OE_N and RD_N low for a continuous FT601 read
                        // transaction. The FT601 advances data on clock edges
                        // during RD_N low; pulsing RD_N/OE_N per word can leave
                        // the external bus parked on the same FIFO-front word.
                        ft_oe_n <= 1'b0;
                        ft_rd_n <= 1'b0;
                        state   <= ST_RX_CAPTURE;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
