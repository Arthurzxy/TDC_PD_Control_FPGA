# Flash Save/Load Host Validation Flow

## Purpose

This document defines the recommended host-side validation flow for the new
flash persistence path:

1. save current board defaults into shared flash
2. reload them back into live runtime state
3. verify both the small configuration bundle and the pixel parameter image
4. monitor busy/error state through the existing uplink packet stream

This flow is intended for board bring-up, not final production qualification.

---

## 1. Preconditions

Before running the flash validation:

1. Program the latest FPGA bitstream built from the current tree.
2. Configure FT601 on the board in `1-channel` mode and start at `66.67 MHz`.
3. Confirm the host can already:
   - receive `STATUS` packets
   - send at least one valid command and receive an `ACK`

Reference files:
- [cmd_dispatcher.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v)
- [packet_builder.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v)
- [flash_board_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_board_store.v)

---

## 2. Downlink Command Frame Format

The current host-to-FPGA command stream still uses the legacy single-word header:

- `Word0[31:24]` = sync byte `0xBB`
- `Word0[23:16]` = `cmd_id`
- `Word0[3:0]`   = payload word count
- following words = payload words

Examples:

```text
FLASH_SAVE : 0xBB300000
FLASH_LOAD : 0xBB310000
```

Command IDs relevant to this flow:

- `0x23` `CMD_GATE_ENABLE`
- `0x24` `CMD_GATE_PIXEL`
- `0x25` `CMD_GATE_RAM`
- `0x30` `CMD_FLASH_SAVE`
- `0x31` `CMD_FLASH_LOAD`

Expected payload lengths:

- `CMD_GATE_ENABLE` = `1` word
- `CMD_GATE_PIXEL`  = `1` word
- `CMD_GATE_RAM`    = `2` words
- `CMD_FLASH_SAVE`  = `0` words
- `CMD_FLASH_LOAD`  = `0` words

Reference:
- [cmd_dispatcher.v#L113](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v#L113)
- [cmd_dispatcher.v#L134](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v#L134)
- [cmd_dispatcher.v#L216](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v#L216)

---

## 3. Uplink ACK Packet Format

ACK packets are emitted with packet type `0x03`.

Packet header:

- `Word0 = [0xA5, 0x03, 0x01, 0x04]`
- `Word1 = [pkt_seq, payload_words]`
- `Word2 = [item_count, flags]`
- `Word3 = timestamp_us`

ACK payload is always `3` words:

1. `payload[0] = cmd_id`
2. `payload[1] = ack_status`
3. `payload[2] = ack_data`

Current ACK status codes:

- `0x00` = OK
- `0x01` = bad payload length
- `0x02` = unknown command

Reference:
- [packet_builder.v#L98](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v#L98)
- [packet_builder.v#L433](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v#L433)
- [packet_builder.v#L465](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v#L465)
- [cmd_dispatcher.v#L120](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v#L120)

---

## 4. STATUS Packet Fields Used For Flash Validation

Current `status_flags[7:0]` layout is:

- `bit7` = `flash_busy`
- `bit6` = `gpx2_lclk_locked`
- `bit5` = `gate_clk_locked`
- `bit4` = `flash_error`
- `bit3` = `usb_tx_backpressure`
- `bit2` = `gpx2_event_overflow`
- `bit1` = `gpx2_cfg_error`
- `bit0` = `gpx2_cfg_done`

During flash validation, the important bits are:

- `bit7`
  - `1`: flash controller is busy
  - `0`: flash controller is idle
- `bit4`
  - `1`: flash error latched
  - `0`: no flash error seen

Reference:
- [system_top.v#L1058](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v#L1058)
- [packet_builder.v#L413](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v#L413)

---

## 5. Recommended Validation Sequence

## 5.1 Step A: Baseline link check

1. Start FT601 streaming.
2. Confirm periodic `STATUS` packets are arriving.
3. Confirm:
   - `status_flags.bit7 == 0`
   - `status_flags.bit4 == 0`
   - `status_flags.bit5 == 1` after gate clock locks

If this fails, do not continue to flash save/load.

## 5.2 Step B: Program a known runtime configuration

Choose a simple, easy-to-recognize configuration:

1. Write one or more DAC / NB6 / gate settings.
2. Enable pixel mode if needed using `CMD_GATE_ENABLE`.
3. Write a small known pixel table pattern using `CMD_GATE_RAM`.

Recommended pixel-table smoke pattern:

- address `0x0000` -> non-zero gate parameters
- address `0x0001` -> different non-zero gate parameters
- address `0x0002` -> third recognizable pattern
- leave the rest at current defaults

The point is not full coverage yet. The point is to create a runtime state that
you can later distinguish from the reset defaults.

## 5.3 Step C: Trigger flash save

Send:

```text
0xBB300000
```

Expected immediate behavior:

1. Receive `ACK` for command `0x30`
2. `ack_status == 0x00`
3. `ack_data == 0x00000000`

Expected ongoing behavior:

1. `STATUS.flags.bit7` goes high
2. gate configuration commands are temporarily blocked while flash is busy
3. eventually `STATUS.flags.bit7` returns low
4. `STATUS.flags.bit4` must remain low

Important:

- save time is not short, because the current implementation stores both:
  - the small config bundle
  - the full pixel image
- do not use a fixed short timeout like a few milliseconds
- poll `STATUS.flags.bit7` until it clears

## 5.4 Step D: Disturb live runtime state

After save completes:

1. change at least one small config field again
2. overwrite the previously written pixel addresses with different values
3. optionally disable pixel mode and then re-enable it

The goal is to make the current live state intentionally different from the
saved flash image.

## 5.5 Step E: Trigger flash load

Send:

```text
0xBB310000
```

Expected immediate behavior:

1. receive `ACK` for command `0x31`
2. `ack_status == 0x00`
3. `ack_data == 0x00000000`

Expected ongoing behavior:

1. `STATUS.flags.bit7` goes high during load
2. after load completes, `STATUS.flags.bit7` returns low
3. `STATUS.flags.bit4` stays low

Internally, the load sequence does two things:

1. restores the small register bundle
2. replays the pixel image back through the normal `gate_gen_top` RAM write path

The last replay entry also forces a local pixel reload pulse, so the gate core
re-latches current pixel parameters without requiring a second manual command.

## 5.6 Step F: Verify restored state

Verify at least these points:

1. the live DAC / NB6 / gate configuration matches the pre-save state
2. the pixel RAM contents at the test addresses match the pre-save pattern
3. no flash error bit is set
4. repeated `STATUS` packets stay stable

If possible on your host side, add a direct readback abstraction for the values
you originally wrote, even if it is currently derived indirectly from behavior.

---

## 6. Minimal Host Test Cases

## 6.1 Positive test

1. write known runtime state
2. `FLASH_SAVE`
3. wait for `flash_busy -> 0`
4. overwrite live state
5. `FLASH_LOAD`
6. wait for `flash_busy -> 0`
7. verify saved state restored

## 6.2 Protocol error test

Send malformed `FLASH_SAVE` with non-zero payload length.

Expected:

1. ACK for `0x30`
2. `ack_status == 0x01`

## 6.3 Unknown command test

Send unsupported command ID.

Expected:

1. ACK returned
2. `ack_status == 0x02`

## 6.4 Busy exclusion test

1. start `FLASH_SAVE`
2. while `flash_busy == 1`, send `CMD_GATE_RAM`
3. confirm no command-side corruption or mixed replay behavior occurs

The top-level currently gates `gate_cfg/gate_pixel/gate_ram` command readiness
with `flash_busy` specifically to avoid this class of conflict.

---

## 7. Suggested Host-Side Logging Fields

For each transaction, log:

1. local wall-clock time
2. transmitted command words
3. received ACK packet words
4. current `status_flags`
5. elapsed time from `flash_busy=1` to `flash_busy=0`

This is enough to separate:

- protocol failure
- flash operation failure
- restore mismatch
- host parser mismatch

---

## 8. Practical Cautions

1. Treat flash save as a blocking maintenance operation, not as a frequent control command.
2. Do not assume save and load have the same latency.
3. Start all board-level validation at `FT601 66.67 MHz`, not `100 MHz`.
4. If `flash_error` ever asserts, capture the full command/ACK/status history before retrying.

