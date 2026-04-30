# TDC Host V1 启动说明

## 1. 目标

这套上位机用于和当前 FPGA 工程联动，完成以下工作：

- FT601 USB3.0 通信
- 下发 FPGA 控制命令
- 接收 `ACK / STATUS / TDC_RAW`
- 录制原始数据 `.tdcpack`
- 在线恢复二维扫描下的每像素 histogram
- 导入导出像素延时阵列

## 2. 目录结构

主工程目录：

- `app/main.py`
- `app/default_config.json`
- `app/ui/`
- `app/services/`
- `app/transport/`
- `app/protocol/`
- `app/analysis/`
- `app/storage/`

## 3. 依赖安装

建议使用 Python 3.11。

安装依赖：

```powershell
python -m pip install -r requirements.txt
```

## 4. 运行前准备

需要先在 Windows 上安装 FTDI D3XX 驱动，并确保以下条件满足：

- 系统中可找到 `FTD3XX.dll`
- FT601 已正确连接并被 Windows 识别
- FPGA 端已经下载当前 bitstream

如果 `FTD3XX.dll` 不在系统搜索路径中，可以把 DLL 放到以下任意位置：

- Python 解释器所在目录
- 当前工作目录
- 系统 PATH 可搜索目录

## 5. 启动命令

在当前目录执行：

```powershell
python -m app.main
```

## 6. 默认配置文件

默认配置文件位于：

- `app/default_config.json`

其中保存了：

- 温度目标
- 三路阈值
- 偏压
- Gate 默认参数
- marker 映射
- histogram 分桶参数
- FT601 连接参数

如果你在 GUI 中点击“保存当前配置”，会覆盖这个文件。

## 7. 首次联板建议流程

### Step 1：连接设备

打开“设备连接”页：

- 点击“刷新设备”
- 选择正确的 FT60x 设备索引
- 检查 `读 Pipe` 和 `写 Pipe`
  - 默认：`0x82 / 0x02`
- 检查 `读块大小`
  - 默认：`262144`
- 点击“连接 FT601”

### Step 2：运行联板自检

连接成功后点击“运行联板自检”。

当前自检会做：

1. 等待一帧 `STATUS`
2. 下发 `CMD_GPX2_CFG`
3. 下发温度目标命令
4. 下发四路 AD5686 模拟量命令

如果 ACK 正常返回，说明：

- FT601 基础通信正常
- 下行命令链正常
- ACK 返回链正常

### Step 3：检查状态页

重点看：

- `gpx2_cfg_done`
- `gpx2_cfg_error`
- `gpx2_event_overflow`
- `usb_tx_backpressure`
- `temp_avg_raw`
- `counter_1s`

注意：

- 当前 FPGA 版本里 `tdc_drop_count` 可能固定为 `0`
- `usb_drop_count` 更适合作为上传拥塞告警参考

### Step 4：下发模拟量

在“FPGA控制”页中设置：

- 目标温度
- 激光同步阈值
- 像素同步阈值
- 雪崩阈值
- 偏压

点击对应按钮后，界面会显示：

- 最近 ACK
- 当前 raw code

## 8. 当前命令映射

### 温度

- 上位机输入：`°C`
- 下发命令：`CMD_TEC_PID (0x04)`
- 编码公式：

```text
temp_code = round(
    16497.62491
    - 664.96558*T
    + 10.82931*T^2
    + 0.02139*T^3
    - 0.00252*T^4
)
```

### 三路阈值 + 偏压

统一通过 `CMD_AD5686 (0x01)` 一次下发四路。

固定通道映射：

- `ch1`：激光同步阈值
- `ch2`：像素同步阈值
- `ch3`：雪崩阈值
- `ch4`：偏压 DAC

换算规则：

```text
threshold_code = round((threshold_mv / 2500.0) * 65535)
bias_code      = round(bias_v * 433)
```

## 9. 采集与录制

“实时采集”页提供：

- 开始采集并落盘
- 停止采集
- 当前像素 histogram
- 二维像素图投影

录制输出：

- 原始数据：`capture.tdcpack`
- Session 元数据：`session.json`
- 分析缓存：`analysis.npz`

默认保存在：

- `./sessions/<时间戳>_<session_name>/`

## 10. 像素阵列

“像素阵列”页支持：

- JSON 导入/导出
- CSV 导入/导出
- 单行写入
- 批量写入
- 触发 FPGA 重载像素参数

表字段：

- `addr`
- `value36`
- `version`
- `comment`

## 11. 离线分析

“离线分析”页支持打开 `session.json` 回放。

当前离线流程：

- 回放 `.tdcpack`
- 重建 marker 状态机
- 重建 histogram
- 显示 histogram 和二维图像

## 12. 当前已知限制

1. `D3XXDevice.enumerate_devices()` 目前采用最保守的索引探测方式，只保证能枚举“可打开”的设备索引，不读取完整设备描述符。
2. `tdc_drop_count` 在当前 FPGA 顶层里仍可能固定为 `0`。
3. 离线回放当前默认使用当前配置中的 marker 映射和 histogram 参数，后续可以继续增强为优先读取 session 内快照。
4. 这版先以 Windows + FTDI D3XX 为唯一正式支持环境。

## 13. 建议下一步

完成这轮 bring-up 后，建议继续补下面两项：

1. 增加更完整的 FT601 设备信息读取
2. 增加“协议诊断页”，显示原始 header、pkt_type、seq 和 ACK 明细
