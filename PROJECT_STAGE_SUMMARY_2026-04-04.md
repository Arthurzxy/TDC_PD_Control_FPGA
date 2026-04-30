# FPGA Project Stage Summary (2026-04-04)

## 1. Project Goals (Target End State)

This project targets a unified `xc7k325t` FPGA system for a multi-chip PCB platform, with these end goals:

1. Reliable chip control for GPX2 TDC, FT601 USB3.0, AD5686, DAC8881, ADS8370, NB6L295, TEC loop, and gate generator.
2. Stable high-throughput data path for GPX2 raw events and low-rate status/telemetry.
3. Cross-domain safe command and configuration updates (`ft_clk`, `sys_clk`, `clk_20m`, `gate_clk_div`, `gpx2_lclk`).
4. Gate generator integration using the validated 1 ns architecture without destructive redesign.
5. Parameter persistence in shared flash (`IS25LP256`), including default board parameters and pixel parameter table.
6. End-to-end build/debug flow in local Vivado, with simulation and timing closure.

---

## 2. What Was Changed Today

### 2.1 Flash persistence was extended from "small params only" to "board-level store"

- Added a new unified flash module:
  - [flash_board_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_board_store.v)
- It now handles:
  - small register bundle save/load (existing behavior preserved)
  - pixel table image save/load for `pixel_param_ram` via shadow mirror and replay
- Flash clock still uses `STARTUPE2 -> USRCCLKO` (driving `CCLK_0/B10` internally).

### 2.2 Top-level integration for pixel table persistence

- Replaced top-level instantiation path from `flash_param_store` to `flash_board_store`.
- Added pixel shadow RAM in top-level (non-invasive to gate core internals):
  - mirror normal `CMD_GATE_RAM` writes
  - provide read source for flash save
  - accept flash load writes
- Added replay mux so flash-loaded pixel records are written back through the existing `gate_gen_top` RAM write interface.
- Added reload pulse behavior on last replay word (to force gate core parameter latch refresh through existing logic).

Main integration points:
- [system_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v) (`flash_board_store`, shadow RAM, replay mux, ready gating)

### 2.3 FT601 notes and constraints were clarified

- Added explicit comments:
  - `ft_clk` is sourced by FT601, not generated in FPGA RTL.
  - board may run FT601 at `66.67 MHz` or `100 MHz` depending on FTDI-side config.
- Kept constraint at `100 MHz` as conservative worst-case timing target.

Files:
- [ft601_fifo_if.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/ft601_fifo_if.v)
- [system_constraints.xdc](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_constraints.xdc)

### 2.4 Build script updates

- Added `flash_board_store.v` into local synth/impl scripts:
  - [codex_vivado_synth.tcl](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/codex_vivado_synth.tcl)
  - [codex_vivado_impl.tcl](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/codex_vivado_impl.tcl)

---

## 3. Current Overall Architecture

## 3.1 Clock/Domain partition

1. `ft_clk` domain:
   - FT601 interface, command receive, packet transmit scheduling.
2. `sys_clk` domain:
   - Main control, GPX2 setup path, flash controller, status integration.
3. `clk_20m` domain:
   - ADC sampling schedule, temperature filter, TEC PID, DAC8881 output path.
4. `gate_clk_div` domain:
   - Gate core runtime, pixel RAM write path, pixel-parameter application.
5. `gpx2_lclk` / derived logic domain:
   - GPX2 LVDS capture and channel event buffering.

## 3.2 Data uplink path

`GPX2 LVDS -> gpx2_top -> async FIFO (sys->ft) -> packet_builder -> tx_fifo_36b -> ft601_fifo_if -> FT601`

Packet format is already aligned with the agreed raw-event architecture:
- common packet header
- `TDC_RAW` (64-bit event records)
- slow status
- ACK packet support

## 3.3 Command/download path

`FT601 RX -> cmd_dispatcher -> CDC handshakes -> target domains/modules`

Current command ingress remains compatible with existing host framing (`0xBB`), while uplink packet format has moved to the newer packetized schema.

## 3.4 Flash persistence strategy (current)

1. Small parameter bundle:
   - `AD5686 + NB6 + TEC setpoint + Gate cfg`
2. Pixel parameter image:
   - mirrored in top-level shadow RAM
   - saved to dedicated flash image area
   - reloaded and replayed through existing gate RAM write interface

This keeps `gate_gen_top` internals stable and avoids invasive redesign.

---

## 4. Build/Debug Status (Latest)

Reference report:
- [codex_impl_timing.rpt](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/codex_impl_timing.rpt)

Latest routed timing summary:
- Report date: `2026-04-04 18:59:45`
- `WNS = 0.402 ns`
- `WHS = 0.037 ns`
- `All user specified timing constraints are met`

Key methodology warnings still present (not new regressions):
- `TIMING-18` missing board-level I/O delay constraints
- `TIMING-9/10` CDC methodology warnings
- `HPDR-1`, `PDRC-190`, `LUTAR-1`, `SYNTH-6`

---

## 5. Remaining Work (Still Required)

1. Complete flash behavior verification:
   - add dedicated testbench for `flash_board_store` (SPI page program, sector erase, readback, version compatibility, timeout/error paths)
2. Board-level timing signoff:
   - add realistic `set_input_delay` / `set_output_delay` for critical external interfaces (especially FT601, GPX2 sideband/control paths as applicable)
3. CDC quality tightening:
   - close residual `TIMING-9/10` warnings with explicit synchronizer intent/constraints where appropriate
4. GPX2 high-rate stress validation:
   - sustained traffic tests at target rates, confirm no silent drop under host-side backpressure scenarios
5. Host protocol alignment cleanup:
   - eventually unify downlink command framing to the same protocol family as uplink packets (currently mixed mode by design for compatibility)
6. Hardware bring-up checklist:
   - validate FT601 at `66.67 MHz` first on your PCB, then step to `100 MHz` if SI margin allows

---

## 6. Detailed Module Notes (Role, Configuration, Principle)

The list below focuses on project-relevant modules in the current tree.

## 6.1 `system_top.v`
- File: [system_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v)
- Role:
  - Master integration layer for clocks, CDC bridges, command/data routing, peripheral control, and status uplink.
- Configuration:
  - `NUM_CH=4`, `REFID_BITS=24`, `TSTOP_BITS=20`, `FT_DATA_W=32`.
  - `FLASH_PARAM_W = GATE_CFG_W + 16 + NB6_CFG_W + AD5686_CFG_W`.
- Principle:
  - Strict domain partition + handshake-based CDC for multi-bit config updates.
  - Gate and flash pixel replay are muxed at top-level, keeping gate core reusable.

## 6.2 `gpx2_top.v`
- File: [gpx2_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_top.v)
- Role:
  - GPX2 receive/control top module, event extraction and forwarding.
- Configuration:
  - Uses `NUM_CH=4`, `REFID_BITS=24`, `TSTOP_BITS=20`.
  - Per-channel pending queue depth increased previously to reduce same-channel burst loss.
- Principle:
  - LVDS capture + framing + buffered arbitration + FIFOized export with ready/backpressure semantics.

## 6.3 `gpx2_lvds_rx.v`
- File: [gpx2_lvds_rx.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_lvds_rx.v)
- Role:
  - DDR LVDS reception and bit assembly for GPX2 stream words.
- Configuration:
  - `USE_DDR` path enabled in current design.
- Principle:
  - IDDR-based sampling synchronized to GPX2 lclk domain.

## 6.4 `gpx2_spi_cfg.v`
- File: [gpx2_spi_cfg.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_spi_cfg.v)
- Role:
  - SPI configuration sequencer for GPX2 setup.
- Configuration:
  - Triggered by command path (`gpx2_start_cfg`).
- Principle:
  - Deterministic command sequence writes registers and reports done/error.

## 6.5 `packet_builder.v`
- File: [packet_builder.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v)
- Role:
  - Upload packet formatter supporting high-rate TDC events and slow telemetry.
- Configuration:
  - Configurable collection timeout and packetization thresholds.
  - Supports `TDC_RAW`, `STATUS`, and `ACK` packet types.
- Principle:
  - Unified header + payload words, with sequence/count/status fields for host-side robust parsing.

## 6.6 `ft601_fifo_if.v`
- File: [ft601_fifo_if.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/ft601_fifo_if.v)
- Role:
  - FT601 synchronous FIFO pin-level read/write state machine.
- Configuration:
  - `DATA_WIDTH=32`, `BE_WIDTH=4`.
  - `ft_clk` external from FT601 chip.
- Principle:
  - Explicit state sequencing for TX strobe and RX capture/hold, preventing bus direction/read timing hazards.

## 6.7 `cmd_dispatcher.v`
- File: [cmd_dispatcher.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v)
- Role:
  - Host command parser and downlink dispatch hub.
- Configuration:
  - Current framing sync byte: `0xBB`.
  - Command set includes DAC/GATE/NB6/TEC/GPX2 and flash save/load (`0x30`, `0x31`).
- Principle:
  - Length check + downstream ready gating + ACK generation on successful command acceptance.

## 6.8 `cdc_cfg_update.v`
- File: [cdc_cfg_update.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cdc_cfg_update.v)
- Role:
  - Handshake-based multi-bit configuration CDC bridge.
- Configuration:
  - Width parameterized (`WIDTH`).
- Principle:
  - Toggle request/ack handshaking with source buffering, avoiding torn multi-bit updates.

## 6.9 `flash_board_store.v`
- File: [flash_board_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_board_store.v)
- Role:
  - Unified flash persistence controller for board config and pixel table.
- Configuration:
  - `PARAM_SECTOR_ADDR=0xFFF000`
  - `PIXEL_IMAGE_BASE_ADDR=0xFDF000`
  - `STARTUP_WAIT_CYCLES`, `POLL_TIMEOUT_CYCLES` tunable.
- Principle:
  - SPI byte engine + command FSM (`WREN`, `RDSR`, `READ`, `PP`, `SE`).
  - Small-parameter read/write with magic/version/crc.
  - Pixel image page-buffer write/read with deterministic record packing.
  - Uses `STARTUPE2` to drive `CCLK_0` safely for user-mode flash access.

## 6.10 `flash_param_store.v`
- File: [flash_param_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_param_store.v)
- Role:
  - Earlier small-parameter-only flash store module.
- Configuration:
  - Retained in tree for reference/compatibility.
- Principle:
  - Same SPI primitive approach but without pixel image support.

## 6.11 `pixel_param_ram.v`
- File: [pixel_param_ram.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/pixel_param_ram.v)
- Role:
  - 16K x 36-bit dual-port pixel parameter RAM model.
- Configuration:
  - Address width fixed at 14 bits in current implementation.
- Principle:
  - Port A write path for updates, port B read/write for alternate clock-side access.
  - Used both inside gate core and now as top-level shadow mirror RAM.

## 6.12 `gate_gen_top.v`
- File: [gate_gen_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gate_gen_top.v)
- Role:
  - Main gate generation core (validated 1 ns architecture).
- Configuration:
  - Pixel mode, per-signal delays/widths, divider ratio, pixel RAM write interface.
- Principle:
  - Pixel index tracking + parameter fetch/latch + waveform synthesis into `gate_word`.
  - RAM-backed per-pixel parameter application.

## 6.13 `gate_serdes_clkgen.v`
- File: [gate_serdes_clkgen.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gate_serdes_clkgen.v)
- Role:
  - Generate high-speed serial and divided clocks for gate output PHY.
- Configuration:
  - Derived from external gate reference clock.
- Principle:
  - MMCM/clock-buffer based clock domain generation and lock indication.

## 6.14 `gate_phy_lvds.v`
- File: [gate_phy_lvds.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gate_phy_lvds.v)
- Role:
  - Serialize parallel gate word and drive LVDS outputs.
- Configuration:
  - Consumes `clk_ser`, `clk_div`, and `par_word`.
- Principle:
  - OSERDES-based parallel-to-serial conversion with differential output buffers.

## 6.15 `Counter.v`
- File: [Counter.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/Counter.v)
- Role:
  - SPAD/count pulse counter.
- Configuration:
  - `CLK_FREQ_HZ` parameter for counter timing base.
- Principle:
  - Synchronized edge detect in system clock domain to reduce undercount from low-rate asynchronous sampling.

## 6.16 `ADC_Ctrl.vhd`
- File: [ADC_Ctrl.vhd](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/ADC_Ctrl.vhd)
- Role:
  - ADS8370 interface and sample acquisition.
- Configuration:
  - Driven in 20 MHz control domain.
- Principle:
  - Conversion trigger + serial read timing pipeline to produce sampled temperature/control data.

## 6.17 `Temp_control.v`
- File: [Temp_control.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/Temp_control.v)
- Role:
  - Temperature preprocessing and average filtering for PID.
- Configuration:
  - `ADC_PERIOD_CYCLES`, `PID_PERIOD_CYCLES`, `ADC_VALID_DELAY_CYCLES`, `AVG_DEPTH`.
- Principle:
  - Periodic ADC trigger and delayed sample capture aligned with ADC conversion latency; moving average output to PID.

## 6.18 `TEC_PID.v`
- File: [TEC_PID.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/TEC_PID.v)
- Role:
  - TEC closed-loop controller.
- Configuration:
  - Uses target setpoint from command/flash path and measured temperature from `Temp_control`.
- Principle:
  - Error computation + PID step update -> DAC command for TEC actuation.

## 6.19 `DAC8881.v`
- File: [DAC8881.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/DAC8881.v)
- Role:
  - DAC8881 serial output driver.
- Configuration:
  - Receives PID output data and start strobe.
- Principle:
  - SPI-like shift sequence to program analog output code.

## 6.20 `AD5686.v`
- File: [AD5686.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/AD5686.v)
- Role:
  - AD5686 DAC write sequencer.
- Configuration:
  - 4-channel 16-bit data words delivered through command/flash path.
- Principle:
  - Framed serial writes with per-command trigger.

## 6.21 `NB6L295_extend.v`
- File: [NB6L295_extend.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/NB6L295_extend.v)
- Role:
  - NB6L295 delay chip configuration driver.
- Configuration:
  - Enable + delay A/B words from command/flash.
- Principle:
  - Shift/program/latch sequence for fine delay configuration.

## 6.22 `system_constraints.xdc`
- File: [system_constraints.xdc](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_constraints.xdc)
- Role:
  - Unified project constraints (including merged gate constraints and flash IO pins).
- Configuration:
  - Flash pins:
    - `flash_spi_d0 -> P24`
    - `flash_spi_d1 -> R25`
    - `flash_spi_cs_n -> U19`
  - `ft_clk` constrained at 100 MHz.
- Principle:
  - Conservative timing basis + pin assignments matching current board.

## 6.23 `gate_test.xdc`
- File: [gate_test.xdc](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gate_test.xdc)
- Role:
  - Original gate project constraint source.
- Configuration:
  - Pin intent merged into `system_constraints.xdc` while preserving required pin mapping.
- Principle:
  - Keeps validated gate IO assignments consistent after integration.

## 6.24 `tb_packet_builder.v`
- File: [tb_packet_builder.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/tb_packet_builder.v)
- Role:
  - Unit-level packet format/sequence regression for packet builder.
- Configuration:
  - Checks header/type/length/fields for emitted packets.
- Principle:
  - Word-by-word expected-value comparison with fail-fast assertions.

## 6.25 `tb_temp_control.v`
- File: [tb_temp_control.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/tb_temp_control.v)
- Role:
  - Unit-level verification for delayed ADC sample capture behavior.
- Configuration:
  - Shortened test periods and explicit `ADC_VALID_DELAY_CYCLES` for deterministic checks.
- Principle:
  - Confirms sample memory updates only after valid delay, not on trigger edge.

---

## 7. Notes on FT601 Internal FIFO Question

Based on the current project and your datasheet path:
- [DS_FT600Q-FT601Q-IC-Datasheet.pdf](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/DS_FT600Q-FT601Q-IC-Datasheet.pdf)

Conclusion:
1. FT601 already has internal FIFO RAM architecture by design.
2. There is no separate FPGA-side "enable internal FIFO" switch in this RTL.
3. Effective throughput tuning is done by FT601 mode/channel/clock configuration and host transfer behavior.
4. For your board-risk scenario, practical bring-up sequence remains:
   - start at `66.67 MHz`
   - validate stability and error-free transfer
   - then move to `100 MHz` if signal integrity margin is sufficient.

---

# FPGA项目阶段总结（中文翻译）

## 1. 项目目标（目标终态）

本项目针对多芯片PCB平台设计统一的 `xc7k325t` FPGA系统，目标如下：

1. 为GPX2 TDC、FT601 USB3.0、AD5686、DAC8881、ADS8370、NB6L295、TEC温控环路和门发生器提供可靠的芯片控制。
2. 为GPX2原始事件和低速状态/遥测数据建立稳定的高吞吐量数据路径。
3. 实现跨时钟域安全的命令和配置更新（`ft_clk`、`sys_clk`、`clk_20m`、`gate_clk_div`、`gpx2_lclk`）。
4. 门发生器集成采用已验证的1ns架构，无需破坏性重新设计。
5. 在共享Flash（`IS25LP256`）中实现参数持久化，包括默认板级参数和像素参数表。
6. 在本地Vivado环境中完成端到端的构建/调试流程，包括仿真和时序收敛。

---

## 2. 今日更改内容

### 2.1 Flash持久化从"仅小参数"扩展到"板级存储"

- 新增统一Flash模块：
  - [flash_board_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_board_store.v)
- 现在可处理：
  - 小寄存器组的保存/加载（保留原有行为）
  - 通过影子镜像和回放机制实现 `pixel_param_ram` 的像素表镜像保存/加载
- Flash时钟仍使用 `STARTUPE2 -> USRCCLKO`（内部驱动 `CCLK_0/B10`）。

### 2.2 像素表持久化的顶层集成

- 顶层实例化路径从 `flash_param_store` 替换为 `flash_board_store`。
- 在顶层添加像素影子RAM（对门控核心内部逻辑无侵入）：
  - 镜像常规的 `CMD_GATE_RAM` 写操作
  - 为Flash保存提供读取源
  - 接受Flash加载的写入
- 添加回放多路复用器，使Flash加载的像素记录通过现有的 `gate_gen_top` RAM写接口回写。
- 在最后一个回放字时添加重载脉冲行为（通过现有逻辑强制刷新门控核心参数锁存）。

主要集成点：
- [system_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v)（`flash_board_store`、影子RAM、回放多路复用器、就绪门控）

### 2.3 FT601注释和约束说明

- 添加明确注释：
  - `ft_clk` 由FT601提供，不是FPGA RTL生成的。
  - 根据FTDI端配置，板级FT601可能运行在 `66.67 MHz` 或 `100 MHz`。
- 约束保持在 `100 MHz`，作为保守的最坏情况时序目标。

相关文件：
- [ft601_fifo_if.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/ft601_fifo_if.v)
- [system_constraints.xdc](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_constraints.xdc)

### 2.4 构建脚本更新

- 将 `flash_board_store.v` 添加到本地综合/实现脚本：
  - [codex_vivado_synth.tcl](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/codex_vivado_synth.tcl)
  - [codex_vivado_impl.tcl](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/codex_vivado_impl.tcl)

---

## 3. 当前整体架构

### 3.1 时钟/域划分

1. `ft_clk` 域：
   - FT601接口、命令接收、数据包发送调度。
2. `sys_clk` 域：
   - 主控制、GPX2配置路径、Flash控制器、状态集成。
3. `clk_20m` 域：
   - ADC采样调度、温度滤波、TEC PID、DAC8881输出路径。
4. `gate_clk_div` 域：
   - 门控核心运行时、像素RAM写路径、像素参数应用。
5. `gpx2_lclk` / 派生逻辑域：
   - GPX2 LVDS捕获和通道事件缓冲。

### 3.2 数据上行路径

`GPX2 LVDS -> gpx2_top -> 异步FIFO (sys->ft) -> packet_builder -> tx_fifo_36b -> ft601_fifo_if -> FT601`

数据包格式已与约定的原始事件架构对齐：
- 通用数据包头
- `TDC_RAW`（64位事件记录）
- 低速状态
- ACK数据包支持

### 3.3 命令/下行路径

`FT601 RX -> cmd_dispatcher -> CDC握手 -> 目标域/模块`

当前命令入口仍与现有主机帧格式（`0xBB`）兼容，而上行数据包格式已迁移到较新的分组架构。

### 3.4 Flash持久化策略（当前）

1. 小参数组：
   - `AD5686 + NB6 + TEC设定值 + 门控配置`
2. 像素参数镜像：
   - 在顶层影子RAM中镜像
   - 保存到专用Flash镜像区
   - 通过现有门控RAM写接口重新加载和回放

这保持了 `gate_gen_top` 内部逻辑的稳定性，避免了侵入性重新设计。

---

## 4. 构建/调试状态（最新）

参考报告：
- [codex_impl_timing.rpt](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/codex_impl_timing.rpt)

最新布线时序摘要：
- 报告日期：`2026-04-04 18:59:45`
- `WNS = 0.402 ns`
- `WHS = 0.037 ns`
- `所有用户指定的时序约束均已满足`

仍存在的关键方法学警告（非新引入的回归问题）：
- `TIMING-18` 缺少板级I/O延迟约束
- `TIMING-9/10` CDC方法学警告
- `HPDR-1`、`PDRC-190`、`LUTAR-1`、`SYNTH-6`

---

## 5. 剩余工作（仍需完成）

1. 完成Flash行为验证：
   - 为 `flash_board_store` 添加专用测试平台（SPI页编程、扇区擦除、回读、版本兼容性、超时/错误路径）
2. 板级时序签核：
   - 为关键外部接口添加实际的 `set_input_delay` / `set_output_delay`（特别是FT601、GPX2边带/控制路径）
3. CDC质量加强：
   - 通过显式同步器意图/约束解决残留的 `TIMING-9/10` 警告
4. GPX2高速压力验证：
   - 在目标速率下进行持续流量测试，确认在主机端背压场景下无静默丢包
5. 主机协议对齐清理：
   - 最终将下行命令帧格式统一到与上行数据包相同的协议族（目前设计上保持兼容的混合模式）
6. 硬件调试检查清单：
   - 在PCB上先验证 `66.67 MHz` 的FT601，如果信号完整性裕量允许，再升级到 `100 MHz`

---

## 6. 详细模块说明（角色、配置、原理）

以下列表重点关注当前树中与项目相关的模块。

### 6.1 `system_top.v`
- 文件：[system_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v)
- 角色：
  - 时钟、CDC桥接、命令/数据路由、外设控制和状态上传的主集成层。
- 配置：
  - `NUM_CH=4`、`REFID_BITS=24`、`TSTOP_BITS=20`、`FT_DATA_W=32`。
  - `FLASH_PARAM_W = GATE_CFG_W + 16 + NB6_CFG_W + AD5686_CFG_W`。
- 原理：
  - 严格的域划分 + 基于握手的多位配置CDC。
  - 门控和Flash像素回放在顶层多路复用，保持门控核心可复用。

### 6.2 `gpx2_top.v`
- 文件：[gpx2_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_top.v)
- 角色：
  - GPX2接收/控制顶层模块，事件提取和转发。
- 配置：
  - 使用 `NUM_CH=4`、`REFID_BITS=24`、`TSTOP_BITS=20`。
  - 每通道待处理队列深度此前已增加，以减少同通道突发丢失。
- 原理：
  - LVDS捕获 + 帧解析 + 缓冲仲裁 + FIFO化导出，带有就绪/背压语义。

### 6.3 `gpx2_lvds_rx.v`
- 文件：[gpx2_lvds_rx.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_lvds_rx.v)
- 角色：
  - GPX2流字DDR LVDS接收和位组装。
- 配置：
  - 当前设计中启用 `USE_DDR` 路径。
- 原理：
  - 基于IDDR的采样，同步到GPX2 lclk域。

### 6.4 `gpx2_spi_cfg.v`
- 文件：[gpx2_spi_cfg.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_spi_cfg.v)
- 角色：
  - GPX2配置的SPI配置序列器。
- 配置：
  - 由命令路径触发（`gpx2_start_cfg`）。
- 原理：
  - 确定性命令序列写入寄存器并报告完成/错误。

### 6.5 `packet_builder.v`
- 文件：[packet_builder.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v)
- 角色：
  - 上行数据包格式化器，支持高速TDC事件和低速遥测。
- 配置：
  - 可配置的收集超时和分包阈值。
  - 支持 `TDC_RAW`、`STATUS` 和 `ACK` 数据包类型。
- 原理：
  - 统一头 + 载荷字，带有序列号/计数/状态字段，用于主机端稳健解析。

### 6.6 `ft601_fifo_if.v`
- 文件：[ft601_fifo_if.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/ft601_fifo_if.v)
- 角色：
  - FT601同步FIFO引脚级读/写状态机。
- 配置：
  - `DATA_WIDTH=32`、`BE_WIDTH=4`。
  - `ft_clk` 来自FT601芯片外部。
- 原理：
  - 显式状态序列用于TX选通和RX捕获/保持，防止总线方向/读取时序风险。

### 6.7 `cmd_dispatcher.v`
- 文件：[cmd_dispatcher.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v)
- 角色：
  - 主机命令解析器和下行分发中心。
- 配置：
  - 当前帧同步字节：`0xBB`。
  - 命令集包括DAC/GATE/NB6/TEC/GPX2和Flash保存/加载（`0x30`、`0x31`）。
- 原理：
  - 长度检查 + 下游就绪门控 + 成功命令接受时生成ACK。

### 6.8 `cdc_cfg_update.v`
- 文件：[cdc_cfg_update.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cdc_cfg_update.v)
- 角色：
  - 基于握手的多位配置CDC桥接。
- 配置：
  - 宽度参数化（`WIDTH`）。
- 原理：
  - 切换请求/确认握手与源端缓冲，避免多位更新撕裂。

### 6.9 `flash_board_store.v`
- 文件：[flash_board_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_board_store.v)
- 角色：
  - 板级配置和像素表的统一Flash持久化控制器。
- 配置：
  - `PARAM_SECTOR_ADDR=0xFFF000`
  - `PIXEL_IMAGE_BASE_ADDR=0xFDF000`
  - `STARTUP_WAIT_CYCLES`、`POLL_TIMEOUT_CYCLES` 可调。
- 原理：
  - SPI字节引擎 + 命令FSM（`WREN`、`RDSR`、`READ`、`PP`、`SE`）。
  - 小参数读/写带有魔数/版本/CRC。
  - 像素镜像页缓冲写/读带有确定性记录打包。
  - 使用 `STARTUPE2` 安全驱动 `CCLK_0` 用于用户模式Flash访问。

### 6.10 `flash_param_store.v`
- 文件：[flash_param_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_param_store.v)
- 角色：
  - 早期仅支持小参数的Flash存储模块。
- 配置：
  - 保留在树中供参考/兼容。
- 原理：
  - 相同的SPI原语方法，但不支持像素镜像。

### 6.11 `pixel_param_ram.v`
- 文件：[pixel_param_ram.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/pixel_param_ram.v)
- 角色：
  - 16K x 36位双端口像素参数RAM模型。
- 配置：
  - 当前实现中地址宽度固定为14位。
- 原理：
  - A端口写路径用于更新，B端口读/写用于备用时钟侧访问。
  - 在门控核心内部和顶层影子RAM中使用。

### 6.12 `gate_gen_top.v`
- 文件：[gate_gen_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gate_gen_top.v)
- 角色：
  - 主门控生成核心（已验证的1ns架构）。
- 配置：
  - 像素模式、每信号延迟/宽度、分频比、像素RAM写接口。
- 原理：
  - 像素索引跟踪 + 参数获取/锁存 + 波形合成到 `gate_word`。
  - RAM支持的每像素参数应用。

### 6.13 `gate_serdes_clkgen.v`
- 文件：[gate_serdes_clkgen.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gate_serdes_clkgen.v)
- 角色：
  - 为门控输出PHY生成高速串行和分频时钟。
- 配置：
  - 派生自外部门控参考时钟。
- 原理：
  - 基于MMCM/时钟缓冲器的时钟域生成和锁定指示。

### 6.14 `gate_phy_lvds.v`
- 文件：[gate_phy_lvds.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gate_phy_lvds.v)
- 角色：
  - 并行门控字串行化并驱动LVDS输出。
- 配置：
  - 消费 `clk_ser`、`clk_div` 和 `par_word`。
- 原理：
  - 基于OSERDES的并转串转换，带差分输出缓冲。

### 6.15 `Counter.v`
- 文件：[Counter.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/Counter.v)
- 角色：
  - SPAD/计数脉冲计数器。
- 配置：
  - `CLK_FREQ_HZ` 参数用于计数器时基。
- 原理：
  - 在系统时钟域进行同步边沿检测，减少低速异步采样导致的计数不足。

### 6.16 `ADC_Ctrl.vhd`
- 文件：[ADC_Ctrl.vhd](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/ADC_Ctrl.vhd)
- 角色：
  - ADS8370接口和采样采集。
- 配置：
  - 在20MHz控制域驱动。
- 原理：
  - 转换触发 + 串行读取时序流水线，产生采样的温度/控制数据。

### 6.17 `Temp_control.v`
- 文件：[Temp_control.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/Temp_control.v)
- 角色：
  - 温度预处理和平均滤波，用于PID。
- 配置：
  - `ADC_PERIOD_CYCLES`、`PID_PERIOD_CYCLES`、`ADC_VALID_DELAY_CYCLES`、`AVG_DEPTH`。
- 原理：
  - 周期性ADC触发和与ADC转换延迟对齐的延迟采样捕获；移动平均输出到PID。

### 6.18 `TEC_PID.v`
- 文件：[TEC_PID.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/TEC_PID.v)
- 角色：
  - TEC闭环控制器。
- 配置：
  - 使用来自命令/Flash路径的目标设定值和来自 `Temp_control` 的测量温度。
- 原理：
  - 误差计算 + PID步进更新 -> DAC命令用于TEC驱动。

### 6.19 `DAC8881.v`
- 文件：[DAC8881.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/DAC8881.v)
- 角色：
  - DAC8881串行输出驱动器。
- 配置：
  - 接收PID输出数据和启动选通。
- 原理：
  - 类SPI移位序列编程模拟输出码。

### 6.20 `AD5686.v`
- 文件：[AD5686.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/AD5686.v)
- 角色：
  - AD5686 DAC写入序列器。
- 配置：
  - 4通道16位数据字通过命令/Flash路径传送。
- 原理：
  - 带每命令触发的帧化串行写入。

### 6.21 `NB6L295_extend.v`
- 文件：[NB6L295_extend.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/NB6L295_extend.v)
- 角色：
  - NB6L295延迟芯片配置驱动器。
- 配置：
  - 使能 + 延迟A/B字来自命令/Flash。
- 原理：
  - 精细延迟配置的移位/编程/锁存序列。

### 6.22 `system_constraints.xdc`
- 文件：[system_constraints.xdc](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_constraints.xdc)
- 角色：
  - 统一项目约束（包括合并的门控约束和Flash IO引脚）。
- 配置：
  - Flash引脚：
    - `flash_spi_d0 -> P24`
    - `flash_spi_d1 -> R25`
    - `flash_spi_cs_n -> U19`
  - `ft_clk` 约束在100MHz。
- 原理：
  - 保守的时序基础 + 与当前板匹配的引脚分配。

### 6.23 `gate_test.xdc`
- 文件：[gate_test.xdc](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gate_test.xdc)
- 角色：
  - 原始门控项目约束源。
- 配置：
  - 引脚意图合并到 `system_constraints.xdc`，同时保留所需的引脚映射。
- 原理：
  - 集成后保持已验证的门控IO分配一致。

### 6.24 `tb_packet_builder.v`
- 文件：[tb_packet_builder.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/tb_packet_builder.v)
- 角色：
  - 数据包构建器的单元级数据包格式/序列回归测试。
- 配置：
  - 检查发出数据包的头/类型/长度/字段。
- 原理：
  - 逐字期望值比较，带有快速失败断言。

### 6.25 `tb_temp_control.v`
- 文件：[tb_temp_control.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/tb_temp_control.v)
- 角色：
  - 延迟ADC采样捕获行为的单元级验证。
- 配置：
  - 缩短的测试周期和显式的 `ADC_VALID_DELAY_CYCLES` 用于确定性检查。
- 原理：
  - 确认采样存储仅在有效延迟后更新，而不是在触发边沿。

---

## 7. FT601内部FIFO问题说明

根据当前项目和您的数据手册路径：
- [DS_FT600Q-FT601Q-IC-Datasheet.pdf](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/DS_FT600Q-FT601Q-IC-Datasheet.pdf)

结论：
1. FT601设计上已内置FIFO RAM架构。
2. 此RTL中没有单独的FPGA端"使能内部FIFO"开关。
3. 有效吞吐量调优通过FT601模式/通道/时钟配置和主机传输行为完成。
4. 对于您的板级风险场景，实际的调试顺序仍然是：
   - 从 `66.67 MHz` 开始
   - 验证稳定性和无错误传输
   - 如果信号完整性裕量允许，再升级到 `100 MHz`。
