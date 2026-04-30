# FPGA 使用说明与原理说明

## 1. 文档目的

本文档用于说明当前 `xc7k325t` FPGA 工程的用途、整体架构、各模块原理、上位机命令格式、数据上传格式、上电与联调顺序，以及当前实现状态。目标是让硬件、FPGA、上位机三侧都能基于同一份文档理解系统工作方式。

当前工程主入口文件为 [system_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v)。

## 2. 系统目标

本项目面向一块集成了 `GPX2 TDC`、`FT601 USB3.0`、`AD5686`、`DAC8881`、`ADS8370`、`NB6L295`、`IS25LP256`、`Gate 信号发生器`、`TEC 温控` 等器件的多功能 PCB。

FPGA 需要完成的核心目标如下：

1. 统一控制整板外设，形成单一主控入口。
2. 稳定采集 GPX2 的 4 路时间数据，并通过 FT601 上传到上位机。
3. 提供 DAC、温控、延时芯片、Gate 发生器等外设的配置接口。
4. 支持参数长期保存，上电后自动从共享 Flash 恢复默认配置。
5. 保证跨时钟域安全、USB 传输稳定、后续便于扩展和维护。

## 3. 当前工程状态

截至当前版本，工程已经完成以下关键工作：

1. `system_top` 顶层已经统一了 GPX2、FT601、Gate、温控、Flash 等主路径。
2. `GPX2 -> 异步 FIFO -> packet_builder -> FT601` 的高速上传链已经接通。
3. 上传协议已经统一为“公共包头 + 原始事件/状态/ACK”格式。
4. `cmd_dispatcher` 已支持下行命令解析、长度检查、下游 `ready` 配合和 ACK 上传。
5. `Counter` 已改成异步输入同步后再计数，避免旧实现的漏计问题。
6. `Flash` 已支持保存板级默认参数，以及保存/恢复 `pixel_param_ram` 镜像。
7. `Gate` 已并回主工程，沿用已验证的 `1 ns` 架构。
8. 本地 `Vivado 2024.2` 实现已经通过时序。

当前最新本地报告：

- [codex_impl_timing.rpt](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/codex_impl_timing.rpt)
- [codex_report_cdc.rpt](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/codex_report_cdc.rpt)

当前状态可以概括为：

- RTL 主功能链已经闭环。
- CDC 主路径已经安全。
- 时序实现已通过。
- 外部板级 `input/output delay` 仍然是联调阶段模型，不是最终实测签核值。

## 4. 顶层整体架构

### 4.1 顶层模块

顶层模块为 [system_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v)。

它主要完成四件事：

1. 实例化所有外设控制模块。
2. 管理多个时钟域之间的数据和配置流。
3. 组织“上位机命令下发”和“板上数据上传”两条链。
4. 负责默认参数保存/恢复、状态整合与周期性上传。

### 4.2 时钟域划分

当前工程采用分域设计，避免所有逻辑堆在同一个时钟域中。

1. `sys_clk` 域  
用途：主控逻辑、高速管理、GPX2 配置、Flash 参数控制、状态汇总。

2. `ft_clk` 域  
用途：FT601 同步 FIFO 接口、命令接收、上传打包发送。  
说明：`ft_clk` 由 FT601 芯片提供，不是 FPGA 内部生成。

3. `clk_20m` 域  
用途：ADC 采样、温度预处理、TEC PID、DAC8881 输出等慢速模拟控制。

4. `gate_clk_div` 域  
用途：Gate 发生器核心、像素参数 RAM 写入、Gate 相关配置实际落地。

5. `gpx2_lclk` 域  
用途：GPX2 LVDS 数据接收。该域由 GPX2 的 `LCLKOUT` 恢复而来，用于 DDR 数据采样。

### 4.3 数据上传链

当前推荐的数据处理架构是：

```text
GPX2 LVDS
  -> gpx2_top
  -> sys/ft 异步 FIFO
  -> packet_builder
  -> tx_fifo_36b
  -> ft601_fifo_if
  -> FT601
  -> 上位机
```

其中：

- FPGA 负责稳定采集、打包、上传。
- 上位机负责根据 `ch3/ch4` 语义做换行、换像素、直方图重建。

这样做的原因是：

1. 第一阶段更容易把数据链路本身调通。
2. 直方图、像素划分规则后续仍可能变化，上位机更灵活。
3. 当前 FT601 带宽足以支持原始事件上传方案。

### 4.4 命令下发链

当前命令路径为：

```text
FT601 RX
  -> cmd_dispatcher
  -> cdc_cfg_update 等跨域握手
  -> 对应目标模块
```

命令从 `ft_clk` 域进入，不直接把多位配置裸跨域，而是通过原子握手机制送到目标时钟域。

## 5. 上位机命令格式

### 5.1 下发帧格式

当前下行命令帧保持兼容旧方案，格式如下：

```text
[SYNC][CMD_ID][PAYLOAD_LEN][PAYLOAD...]
```

字段说明：

- `SYNC = 0xBB`
- `CMD_ID`：命令编号
- `PAYLOAD_LEN`：后续负载的 32 位字数
- `PAYLOAD`：按 32 位字拼接

对应实现文件：

- [cmd_dispatcher.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v)

### 5.2 已实现命令表

| CMD_ID | 名称 | Payload 长度 | 功能 |
|---|---|---:|---|
| `0x01` | `CMD_AD5686` | 2 | 配置 4 路 AD5686 输出 |
| `0x02` | `CMD_GATE` | 1 | 配置 `gate_hold_off_time` |
| `0x03` | `CMD_NB6L295` | 1 | 配置 NB6L295 延时与使能 |
| `0x04` | `CMD_TEC_PID` | 1 | 设置 TEC 温控目标值 |
| `0x10` | `CMD_GPX2_CFG` | 0 | 触发 GPX2 SPI 配置 |
| `0x20` | `CMD_GATE_DIV` | 1 | 配置 Gate 分频 |
| `0x21` | `CMD_GATE_SIG2` | 1 | 配置 Gate 信号 2 延时和脉宽 |
| `0x22` | `CMD_GATE_SIG3` | 1 | 配置 Gate 信号 3 延时和脉宽 |
| `0x23` | `CMD_GATE_ENABLE` | 1 | 使能信号 2/3，切换 pixel mode |
| `0x24` | `CMD_GATE_PIXEL` | 1 | 触发像素参数重装 |
| `0x25` | `CMD_GATE_RAM` | 2 | 写入像素参数 RAM |
| `0x30` | `CMD_FLASH_SAVE` | 0 | 保存当前默认参数到 Flash |
| `0x31` | `CMD_FLASH_LOAD` | 0 | 从 Flash 重新装载默认参数 |

### 5.3 关键命令参数说明

#### `CMD_AD5686`

负载共 2 个 32 位字，内部拼成 64 位。

- `data1 = payload[63:48]`
- `data2 = payload[47:32]`
- `data3 = payload[31:16]`
- `data4 = payload[15:0]`

#### `CMD_NB6L295`

单字负载位段：

- `delay_a = payload[8:0]`
- `delay_b = payload[17:9]`
- `enable = payload[18]`

#### `CMD_TEC_PID`

- `temp_set = payload[15:0]`

#### `CMD_GATE_SIG2` / `CMD_GATE_SIG3`

单字负载位段：

- `delay_coarse = payload[3:0]`
- `delay_fine = payload[8:4]`
- `width_coarse = payload[11:9]`
- `width_fine = payload[16:12]`

#### `CMD_GATE_ENABLE`

- `bit0`: `sig2_enable`
- `bit1`: `sig3_enable`
- `bit2`: `pixel_mode`

#### `CMD_GATE_PIXEL`

- `payload[0] = 1` 时，触发一次像素参数重装
- `payload[0] = 0` 时，仅返回 ACK，不执行重装

#### `CMD_GATE_RAM`

共 2 个 32 位字，内部拼接后：

- `gate_ram_wr_addr = payload[49:36]`
- `gate_ram_wr_data = payload[35:0]`

#### `CMD_FLASH_SAVE` / `CMD_FLASH_LOAD`

- `CMD_FLASH_SAVE`：保存当前寄存器类默认参数和像素参数镜像到共享 Flash
- `CMD_FLASH_LOAD`：从 Flash 读取并重新回放到系统配置链中

### 5.4 ACK 机制

命令执行成功后，系统会通过上传链返回 ACK 包，而不是只在本地打一拍完成。

当前 ACK 状态码：

- `0x00`：执行成功
- `0x01`：长度错误
- `0x02`：未知命令

这意味着上位机可以把 ACK 作为“命令真正落地”的确认，而不是只认为 FT601 已经收到了字节流。

## 6. 上传数据格式

上传协议由 [packet_builder.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v) 负责。

### 6.1 公共包头

所有上传包都使用固定 4 个 32 位字的包头：

| Word | 位段 | 含义 |
|---|---|---|
| `W0` | `[31:24]` | `0xA5` 同步字 |
| `W0` | `[23:16]` | `pkt_type` |
| `W0` | `[15:8]` | `proto_ver = 0x01` |
| `W0` | `[7:0]` | `hdr_words = 4` |
| `W1` | `[31:16]` | `pkt_seq` |
| `W1` | `[15:0]` | `payload_words` |
| `W2` | `[31:16]` | `item_count` |
| `W2` | `[15:0]` | `flags` |
| `W3` | `[31:0]` | `timestamp_us` |

### 6.2 包类型

| `pkt_type` | 名称 | 含义 |
|---|---|---|
| `0x01` | `TDC_RAW` | 原始 GPX2 事件流 |
| `0x02` | `STATUS` | 慢速状态包 |
| `0x03` | `ACK` | 命令执行返回 |

### 6.3 `TDC_RAW` 事件格式

每个事件固定 64 位：

```text
{rec_type[3:0], ch[1:0], event_class[1:0], refid[23:0], tstop[19:0], reserved[11:0]}
```

字段说明：

- `rec_type = 4'h0`
- `ch`：通道号
- `event_class`
  - `00`：普通时间事件
  - `01`：特殊标记类事件 1
  - `10`：特殊标记类事件 2
- `refid`：参考计数
- `tstop`：停止时间细分值

当前实现中：

- `ch == 2` 时 `event_class = 01`
- `ch == 3` 时 `event_class = 10`
- 其它通道为 `00`

### 6.4 `STATUS` 包

当前状态包主要包含：

1. 板级状态标志
2. 运行时间
3. 平均温度
4. 1 秒计数值
5. TDC 丢包计数
6. USB 背压丢包计数

### 6.5 `ACK` 包

ACK 负载包含：

1. `cmd_id`
2. `status_code`
3. `return_data`

## 7. Flash 参数保存与恢复

Flash 访问由 [flash_board_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_board_store.v) 实现。

### 7.1 基本策略

当前工程复用了配置 Flash `IS25LP256`，不额外占用独立存储器。

接口方式：

- `D0`：FPGA 输出
- `D1`：FPGA 输入
- `CS#`：普通 IO 控制
- `CCLK_0(B10)`：通过 `STARTUPE2.USRCCLKO` 在 FPGA 内部驱动

即当前使用的是 `x1 SPI` 访问模式，没有使用 `D2/D3`。

### 7.2 存储内容

Flash 分两块主要区域：

1. 参数区 `0xFFF000`
2. 像素镜像区 `0xFDF000`

参数区保存：

- `AD5686`
- `NB6L295`
- `TEC setpoint`
- `Gate cfg`

像素区保存：

- `pixel_param_ram` 镜像

### 7.3 工作流程

保存流程：

1. 擦除目标扇区
2. 写参数区
3. 逐页读取 pixel shadow RAM
4. 把像素镜像逐页写入 Flash

加载流程：

1. 上电后自动尝试读参数区
2. 若 `magic/version/check` 合法，则导出参数
3. 继续读取像素镜像区
4. 通过现有 `gate_ram_wr_*` 接口逐条回放

## 8. 关键模块作用与原理

### 8.1 `system_top`

文件：

- [system_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v)

作用：

1. 工程唯一整板顶层
2. 实例化全部主功能模块
3. 管理跨域配置、上传链、慢速状态、默认参数恢复

### 8.2 `gpx2_top`

文件：

- [gpx2_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_top.v)

作用：

1. 配置 GPX2
2. 接收 4 路 LVDS 数据
3. 把每个事件整理成 `channel + refid + tstop`
4. 通过 `valid/ready` 输出给后级

原理：

- 使用 `LCLKOUT` 相关时钟做 DDR 接收
- 利用 `IDELAY` 和 GPX2 `LVDS_DATA_VALID_ADJUST` 增加接收窗口裕量
- 每通道设置小深度 pending 队列，降低同通道连续命中造成的丢数概率

### 8.3 `gpx2_spi_cfg`

文件：

- [gpx2_spi_cfg.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_spi_cfg.v)

作用：

1. 上电或命令触发时初始化 GPX2 寄存器
2. 固定输出格式为当前工程所需的 `24-bit refid + 20-bit tstop + DDR`

配置重点：

1. 4 通道独立
2. 高分辨率模式
3. `LVDS_DATA_VALID_ADJUST = 2'b11`
4. `REFCLK_DIVISIONS` 需要和板上实际参考时钟匹配

### 8.4 `ft601_fifo_if`

文件：

- [ft601_fifo_if.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/ft601_fifo_if.v)

作用：

1. 完成 FPGA 与 FT601 的同步 FIFO 时序适配
2. 同时支持上行发送和下行接收

说明：

- 该模块只负责“接口时序”，不负责协议解释
- 上传优先级高于下载，因为当前系统以上传为主
- FT601 自身带内部 FIFO RAM，不需要在 FPGA 里额外打开隐藏开关

### 8.5 `cmd_dispatcher`

文件：

- [cmd_dispatcher.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v)

作用：

1. 解析上位机下发命令
2. 做长度校验
3. 在目标模块 `ready` 时才真正发起控制
4. 生成 ACK 信息供上传链发送

### 8.6 `packet_builder`

文件：

- [packet_builder.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v)

作用：

1. 统一构造上传包
2. 支持 `TDC_RAW`、`STATUS`、`ACK`
3. 把高速和低速信息整合到一个上传协议里

### 8.7 `flash_board_store`

文件：

- [flash_board_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_board_store.v)

作用：

1. 共享配置 Flash 的用户态访问
2. 保存板级默认参数
3. 保存像素参数镜像
4. 上电自动恢复默认参数

### 8.8 `Counter`

文件：

- [Counter.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/Counter.v)

作用：

1. 统计 SPAD avalanche 事件每秒计数
2. 把计数结果作为慢速状态的一部分上传

### 8.9 `Temp_control`

文件：

- [Temp_control.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/Temp_control.v)

作用：

1. 周期性启动 ADC
2. 延迟固定时长后取温度值
3. 做滑动平均
4. 周期性触发 TEC PID 计算

### 8.10 `TEC_PID`

文件：

- [TEC_PID.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/TEC_PID.v)

作用：

1. 根据目标温度和当前温度计算 DAC 控制值
2. 驱动 `DAC8881`

### 8.11 `AD5686` / `DAC8881` / `ADC_Ctrl`

作用：

1. `AD5686`：多路 DAC 输出，适合板上偏置或慢速控制量
2. `DAC8881`：TEC 驱动 DAC
3. `ADC_Ctrl`：采集温度相关模拟量

### 8.12 `NB6L295`

作用：

1. 细调 Gate 延时
2. 与 `Gate_gen_top` 配合，实现微小时间偏移

### 8.13 `Gate_gen_top` 与 `pixel_param_ram`

作用：

1. Gate 发生器是整板信号时序输出核心
2. `pixel_param_ram` 为不同像素保存对应的延时、脉宽等参数

原则：

- `Gate_gen_top` 已经独立仿真验证完成，因此当前不改其核心逻辑
- 新增功能都尽量在外围适配，例如 flash 镜像、命令对接、顶层回放

## 9. 推荐使用流程

### 9.1 上电默认流程

1. FPGA 上电配置完成
2. `flash_board_store` 尝试读取默认参数区
3. 若参数合法，则恢复寄存器类默认配置
4. 若像素镜像存在，则逐条回放到 Gate 像素参数 RAM
5. 系统进入待命状态

### 9.2 建议联调顺序

1. 先确认 `FT601` 枚举和基础收发
2. 下发简单命令并观察 ACK
3. 测试 `CMD_FLASH_SAVE` / `CMD_FLASH_LOAD`
4. 验证 AD5686 / NB6L295 / 温控 / Gate 单项功能
5. 触发 `CMD_GPX2_CFG`
6. 观察 `STATUS` 和 `TDC_RAW`
7. 最后再做高数据率压力测试

### 9.3 FT601 建议

当前推荐：

1. 联板初期先跑 `66.67 MHz`
2. 等稳定后再尝试 `100 MHz`
3. 上位机尽量按长 burst 读取，不要碎片化拉取

### 9.4 GPX2 建议

当前 FPGA 侧已经针对接收窗口做了以下处理：

1. `LVDS_DATA_VALID_ADJUST`
2. 输入侧 `IDELAY`
3. 接收域队列和仲裁优化

但最终板级最佳窗口仍建议以上板实测为准，再微调 XDC 的输入延时模型。

## 10. 当前仍需继续完成的点

1. 根据实板波形，把 GPX2 输入延时约束改成最终签核值。
2. 给关键外设口补上更完整的板级 `input/output delay`。
3. 增加 `flash_board_store` 的独立 testbench。
4. 完善上位机联调脚本和异常处理流程。
5. 若后续需要节省 USB 带宽，可考虑增加 FPGA 端直方图模式，但建议作为第二阶段。

## 11. 关键文件清单

顶层与系统集成：

- [system_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_top.v)

高速采集与上传：

- [gpx2_top.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_top.v)
- [gpx2_spi_cfg.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/gpx2_spi_cfg.v)
- [packet_builder.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/packet_builder.v)
- [ft601_fifo_if.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/ft601_fifo_if.v)
- [cmd_dispatcher.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/cmd_dispatcher.v)

参数保存与恢复：

- [flash_board_store.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/flash_board_store.v)

慢速控制链：

- [Temp_control.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/Temp_control.v)
- [TEC_PID.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/TEC_PID.v)
- [Counter.v](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/Counter.v)

约束与报告：

- [system_constraints.xdc](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/TDC_PC_Ver2.0.srcs/sources_1/system_constraints.xdc)
- [codex_impl_timing.rpt](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/codex_impl_timing.rpt)
- [codex_report_cdc.rpt](/D:/Z_d/USTC_Research/EE-PCB/FPGA/TDC_PD_Ver2.0/codex_report_cdc.rpt)

## 12. 一句话总结

当前工程已经从“多套版本并存、接口不完全一致”的状态，整理成了“顶层统一、命令链闭环、上传链闭环、Flash 可保存默认参数、实现时序通过”的可联板版本。下一阶段重点不再是大改架构，而是基于这套稳定骨架做实板联调和最终参数收敛。
