# Fankit 1.0.2：AI 调度设计

## 目标

让用户利用一段真实的 System 调度运行数据，请自己信任的 AI 给出一条温度—风扇曲线；Fankit 只负责采集、生成引导词、验证 AI 返回值和执行经过安全约束的曲线。

核心原则：

- Fankit 不内置 AI 服务，也不上传用户数据。
- AI 只能返回曲线数据，不能返回代码、SMC key、shell 命令或任意 RPM 指令。
- 粘贴 AI 返回值后先解析、校验、预览，用户确认后才启用。
- 记录和生成提示词期间始终保持 System 调度，不接管风扇。
- AI 调度沿用现有的温度滤波、升降速限制、2°C 回差和 100°C 紧急最大风速保护。

## 用户流程

### 1. 开始采集

用户从菜单栏的「AI 调度」进入引导页。页面明确显示：

> 当前为 System 调度。Fankit 只记录温度和风扇转速，不会修改风扇控制。

采集内容包括：

- 时间戳；
- CPU、GPU、Memory、Battery、Airflow、System 各温区的最高温度；
- 每个风扇的当前 RPM、最小 RPM 和最大 RPM；
- 采集间隔、开始时间、结束时间和中断/睡眠间隔。

推荐每 10 秒保存一个观测点。现有监控刷新仍可保持 2 秒，但不把每次刷新全部写入磁盘。一次采集最长 24 小时，达到上限自动结束；用户也可以随时点击「结束采集」。

首次进入时允许用户选择「本次开始」或开启「启动 Fankit 时自动开始采集」。不建议未经确认在每次启动时静默产生 24 小时记录。

### 2. 查看并生成提示词

结束后进入数据摘要页：

- 记录时长和有效采样数；
- 是否存在睡眠或数据缺失；
- CPU/GPU/Memory 的最低、平均、P95、最高温度；
- 风扇 RPM 的最低、平均、最高值；
- 一张只读的温度与风扇速度时间图；
- 采集是否足够生成建议（建议至少 10 分钟有效数据）。

「复制给 AI 的引导词」按钮生成完整文本。提示词只包含传感器数值和设备运行上下文，不包含用户名、文件路径、AppleSMC 原始 key、控制 helper 信息或任何凭据。

时间序列使用 5 分钟桶进行压缩，保留每桶的平均值、最高温度和风扇 RPM 均值，避免 24 小时数据生成过大的粘贴文本。用户可以重新生成，但同一采集会保留固定摘要，便于复现。

### 3. 粘贴 AI 返回值

引导页提供一个大的文本框和明确说明：

> 请让 AI 只返回下方格式的 JSON。不要执行 AI 返回的命令，也不要把设备控制权限交给 AI。

支持直接粘贴 JSON，也可以接受一个 `json` Markdown 代码块。除此之外不做“智能修复”，解析失败时显示具体原因。

解析成功后先展示：

- AI 建议名称和摘要；
- 曲线图；
- 每个温度点对应的风扇百分比；
- Fankit 将要应用的固定安全规则；
- 如果校验器做了排序、去重或边界修正，显示修正前后的差异。

用户点击「保存为 AI 调度」后才会创建本地预设；点击「启用 AI 调度」才会接管风扇。

### 4. 运行 AI 调度

启用后菜单栏显示「AI 调度」和当前 AI 预设名称。主窗口显示：

- 当前 AI 预设；
- 只读曲线；
- 当前控制温度和风扇需求；
- 数据来源采集时间；
- 「停用并恢复 System」和「重新导入 AI 结果」。

粘贴、保存和预览都不会自动启用。helper 不可用、传感器失效、AI 曲线执行失败或温度达到紧急阈值时，统一恢复 System 或 Max 的现有安全路径。

## AI 返回协议 v1

提示词要求 AI 只返回一个 JSON 对象：

```json
{
  "format": "fankit-ai-schedule",
  "version": 1,
  "name": "Balanced sustained work",
  "summary": "Earlier cooling during sustained CPU and GPU load.",
  "points": [
    { "temperature_c": 52, "fan_percent": 15 },
    { "temperature_c": 64, "fan_percent": 30 },
    { "temperature_c": 74, "fan_percent": 55 },
    { "temperature_c": 84, "fan_percent": 82 },
    { "temperature_c": 92, "fan_percent": 100 }
  ]
}
```

只接受以下字段：`format`、`version`、`name`、`summary`、`points`。执行层忽略 AI 返回的其它字段，不支持 `command`、`script`、`smc_key`、`rpm`、`hysteresis` 或自定义执行逻辑。

校验规则：

- `format` 必须为 `fankit-ai-schedule`，`version` 必须为 `1`；
- 名称限制为 1–48 个字符，摘要限制长度；
- 点数为 2–8 个；温度范围 35–100°C；
- 风扇百分比范围 0–100%；
- 温度必须严格递增，距离过近的点拒绝或在预览中明确合并；
- 风扇需求随温度升高不得下降；
- 百分比转换为现有 `ThermalCurveProfile` 的 `fanFraction`，最终 RPM 仍根据硬件回报的最小/最大范围计算；
- 运行时继续使用现有的升速 900 RPM、降速 350 RPM 限制、2°C 回差和 100°C 紧急最大风速。

## 技术拆分

建议不要把所有逻辑继续堆进 `FanControlStore`，拆成四个独立组件：

1. `AICaptureSession` / `AICaptureSample`：Codable 的采集模型，负责 24 小时上限和 session 状态。
2. `AIObservationRecorder`：独立 actor，按 10 秒追加写入 Application Support，避免阻塞主线程；恢复启动时未完成且未超过 24 小时的 session。
3. `AIPromptBuilder`：把采集文件聚合成统计信息和 5 分钟时间桶，并生成可复制提示词。
4. `AIScheduleParser` / `AIScheduleValidator`：严格 JSON 解码、边界校验、转换为 `ThermalCurveProfile`，不执行任意文本。

建议的持久化位置：

```text
~/Library/Application Support/Fankit/AI/sessions/<session-id>.jsonl
~/Library/Application Support/Fankit/AI/plans/<plan-id>.json
```

`UserDefaults` 只保存当前 session ID、当前 AI plan ID 和用户是否开启启动时采集；不要把 24 小时序列塞进 `UserDefaults`。

现有调度模型的改造方向：

- 为 `ThermalCurveProfile` 增加可向后兼容的来源标记：内置、用户自定义、AI；
- 增加真正的 `aiScheduling` 控制模式，不再把 AI 预设伪装成 Custom Scheduling；
- AI 模式复用现有曲线执行器，只替换经过验证的曲线数据；
- 无 AI plan 时菜单项进入引导页，有 AI plan 后才允许选择和启用；
- 记录期间强制保持 System 调度，结束或应用失败时不改变用户当前安全状态。

## 1.0.2 验收标准

- 采集自动在 24 小时到达时结束，手动结束不会丢失最后一个样本；
- 应用重启后可以恢复未结束且未过期的采集；睡眠造成的时间空洞可见；
- 24 小时数据生成的提示词大小可控，复制后可直接粘贴给常见 AI；
- 合法 JSON 能生成预览曲线，非法 JSON、越界点、下降曲线和任意命令全部被拒绝；
- 粘贴 AI 返回值不会直接改变风扇速度；
- AI 调度只产生现有安全边界内的目标 RPM；
- helper、传感器或执行过程出错时回到 System，并给出可理解的错误；
- 自定义调度、System 调度和旧版本保存的曲线继续可用；
- 不新增网络请求，不上传采集记录。
