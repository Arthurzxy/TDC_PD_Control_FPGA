//==============================================================================
// cdc_cfg_update.v
//------------------------------------------------------------------------------
// Module: Clock Domain Crossing for Configuration Data
//
// Purpose:
//   Safely transfers multi-bit configuration data from one clock domain to
//   another using a request/acknowledge handshake protocol. Prevents torn
//   (inconsistent) data during cross-domain updates.
//
// Architecture:
//   - Toggle-based request/acknowledge handshake
//   - 3-stage synchronizers for metastability protection
//   - Data sampled on source clock, held stable during transfer
//   - Destination domain signals valid when data ready
//
// Handshake Protocol:
//   1. Source domain: src_valid + src_ready => capture data, toggle req
//   2. Destination domain: detect req toggle => capture data, toggle ack
//   3. Source domain: detect ack toggle => ready for next transfer
//
// Timing:
//   - Latency: 2-3 destination clock cycles from src_valid to dst_valid
//   - Backpressure: src_ready deasserted during transfer
//
// Parameters:
//   - WIDTH: Data width (default: 1 bit)
//
// Clock Domains:
//   - src_clk: Source clock domain
//   - dst_clk: Destination clock domain (asynchronous to src_clk)
//
// Interfaces:
//   - src_clk/src_rst: Source clock and reset
//   - src_valid/src_ready/src_data: Source handshake
//   - dst_clk/dst_rst/dst_valid/dst_data: Destination handshake
//
// Related Documents:
//   - PROJECT_STAGE_SUMMARY_2026-04-04.md Section 6.8
//
// Author: [Original Author]
// Modified: 2026-04-04 (added detailed comments)
//==============================================================================

`timescale 1ns/1ps

module cdc_cfg_update #(
    parameter integer WIDTH = 1      // Data width in bits
)(
    //==========================================================================
    // Source Clock Domain
    //==========================================================================
    input  wire             src_clk,       // Source clock
    input  wire             src_rst,       // Source reset (active high)
    input  wire             src_valid,     // Source data valid
    input  wire [WIDTH-1:0] src_data,      // Source data input
    output wire             src_ready,     // Source ready (can accept new data)

    //==========================================================================
    // Destination Clock Domain
    //==========================================================================
    input  wire             dst_clk,       // Destination clock
    input  wire             dst_rst,       // Destination reset (active high)
    output reg              dst_valid,     // Destination data valid
    output reg  [WIDTH-1:0] dst_data      // Destination data output
);

    //==========================================================================
    // Source Domain State
    //==========================================================================
    reg [WIDTH-1:0] src_buf;                 // Data buffer (stable during transfer)
    reg             src_req_toggle;          // Request toggle bit
    (* ASYNC_REG = "TRUE" *) reg ack_sync1;  // Acknowledge synchronizer stage 1
    (* ASYNC_REG = "TRUE" *) reg ack_sync2;  // Acknowledge synchronizer stage 2

    //==========================================================================
    // Destination Domain State
    //==========================================================================
    (* ASYNC_REG = "TRUE" *) reg req_sync1;              // Request synchronizer stage 1
    (* ASYNC_REG = "TRUE" *) reg req_sync2;              // Request synchronizer stage 2
    reg                      req_sync3;                  // Request synchronizer stage 3
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] data_sync1; // Data synchronizer stage 1
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] data_sync2; // Data synchronizer stage 2
    reg                      dst_pending;                // Data pending flag
    reg                      dst_ack_toggle;             // Acknowledge toggle bit

    //--------------------------------------------------------------------------
    // Source Ready Signal
    //--------------------------------------------------------------------------
    // Ready when synchronized ack matches our request (transfer complete)
    assign src_ready = (ack_sync2 == src_req_toggle);

    //==========================================================================
    // Source Domain Logic
    //==========================================================================
    // Captures data when valid+ready, toggles request to signal transfer.
    //==========================================================================
    always @(posedge src_clk) begin
        // Keep the returning acknowledge in a plain 2-FF synchronizer with no
        // explicit reset so Vivado can recognize the CDC structure cleanly.
        ack_sync1 <= dst_ack_toggle;
        ack_sync2 <= ack_sync1;

        if (src_rst) begin
            src_buf        <= {WIDTH{1'b0}};
            src_req_toggle <= 1'b0;
        end else begin
            // Capture data and start transfer on valid+ready handshake
            if (src_valid && src_ready) begin
                src_buf        <= src_data;        // Capture stable data
                src_req_toggle <= ~src_req_toggle; // Signal new data available
            end
        end
    end

    //==========================================================================
    // Destination Domain Logic
    //==========================================================================
    // Detects request toggle, captures synchronized data, outputs valid pulse.
    //==========================================================================
    always @(posedge dst_clk) begin
        // Keep the synchronizer stages free of explicit reset so Vivado can
        // pack/place them as a recognized CDC chain.
        req_sync1  <= src_req_toggle;
        req_sync2  <= req_sync1;
        data_sync1 <= src_buf;
        data_sync2 <= data_sync1;

        if (dst_rst) begin
            req_sync3      <= 1'b0;
            dst_pending    <= 1'b0;
            dst_ack_toggle <= 1'b0;
            dst_valid      <= 1'b0;
            dst_data       <= {WIDTH{1'b0}};
        end else begin
            req_sync3  <= req_sync2;

            // Default: no valid output
            dst_valid  <= 1'b0;

            // Output pending data if available
            if (dst_pending) begin
                dst_valid   <= 1'b1;         // Signal valid data
                dst_pending <= 1'b0;        // Clear pending flag
            end

            // Detect request toggle (new data available)
            if (req_sync2 != req_sync3) begin
                dst_data       <= data_sync2;    // Capture synchronized data
                dst_pending    <= 1'b1;          // Mark data as pending
                dst_ack_toggle <= req_sync2;     // Acknowledge receipt
            end
        end
    end

endmodule
