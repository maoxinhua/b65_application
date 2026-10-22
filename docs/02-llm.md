# 02 · LLM 运行手册

> **端口可能不是 8095。** XeStrata 的 `setup.py` 有时会把 `server.py` 绑到另一个端口（例如 59643），
> `--port 8095` 只记录在配置里。以 `.\b65.ps1 status`、面板 LLM 页的 Base URL，或
> `curl http://127.0.0.1:<port>/health` 的实际结果为准；API Key 也必须带
> `Authorization: Bearer <key>`，否则 401。

> API 的 `model` 字段随档位变化，例如 `qwen3.8-flash-next-iq3_xxs`、`qwen3.8-flash-next-iq3_s`、
> `qwen3.8-flash-next-iq2_xs`。用 `curl http://127.0.0.1:<实际端口>/v1/models` 确认，不要写死。

## 模型档位

| 档位 | 下载 | 内存 | 质量 / 用途 |
|---|---:|---:|---|
| **IQ3_XXS** | 76 GB | ~60 GB | 默认；64 GB 机器的最佳平衡 |
| **IQ3_S** | 84 GB | ~62 GB | 最高质量；关闭其他程序再跑 |
| **IQ2_XS** | 68 GB | ~48 GB | 快速回退 |

XeStrata `--check` 的保守估计是 IQ3_XXS ~60 GB、IQ3_S ~62 GB；setup 运行时的估算略低
（~43 / ~50 GB），但 Windows 自身还要占内存，**默认选 IQ3_XXS**，IQ3_S 只在高可用内存时用。

```powershell
# 下载（--no-start 不会在下载后抢占显存）
.\b65.ps1 install llm -Model IQ3_XXS -RunSetup -NoStart -SetDefault
.\b65.ps1 install llm -Model IQ3_S   -RunSetup -NoStart

# 只改配置 / 改配置并重启
.\b65.ps1 llm use    -Model IQ3_XXS
.\b65.ps1 llm switch -Model IQ3_XXS
```

## 配置

`config\llm.json`：

```json
{
  "model": "IQ3_XXS",
  "context": 32768,
  "vision": false,
  "host": "0.0.0.0",
  "port": 8095,
  "vramReserveMiB": 1024,
  "parallel": 1,
  "source": "modelscope",
  "dataDir": "runtime/xestrata",
  "modelsDir": "models/llm",
  "residentBudgetGiB": 0,
  "lowRam": "auto",
  "optionalArgs": true
}
```

- `dataDir` / `modelsDir` 让模型和配置落在工作路径下；每个档位在 `models\llm\<档位>`。
- `source = modelscope` 国内下载更快；可改 `huggingface` 或 `auto`。
- `vramReserveMiB = 1024` 给 WDDM 桌面/浏览器留余量。
- `vision = false` → 传 `--vision no`；要读图再改 true。
- `optionalArgs = false` 可在引擎不认 `--vram-reserve-mib` 时退回最小参数集。
- `residentBudgetGiB = 0` 表示交给引擎自动；只有确认 `--resident-budget-gib` 对该量化有效时才设。
- `lowRam = auto` 是引擎默认；需要强制 `on/off/resident/mmap` 时改这里。

## 性能预期

DDR5-4000、32K 上下文下的粗略估计（以 `xestrata-cli --bench` 实测为准）：

| 档位 | decode | 备注 |
|---|---:|---|
| IQ2_XS | 45–60 tok/s | 当前基线 |
| IQ3_XXS | 30–45 tok/s | 默认；质量/速度平衡 |
| IQ3_S | 25–40 tok/s | 最高质量；内存紧张时更慢 |

3-bit/3.5-bit 的 CPU 专家计算量更大，decode 会比 IQ2_XS 低；prefill 差异较小。

## 启停

```powershell
.\b65.ps1 llm start
.\b65.ps1 llm stop
.\b65.ps1 llm restart
.\b65.ps1 llm status
```

`start` 会：

1. 如果 ComfyUI 在跑，先停掉；
2. 生成/复用 40 位 API Key；
3. 启动 `xestrata-cli.exe`，等待引擎实际绑定的端口（可能是 8095，也可能是 59643 等）；
4. 探测 `/v1/models`；
5. 启动 watchdog（后台 PowerShell）；
6. 打印本机/LAN 地址和 Key。

## 局域网 API

```text
OpenAI 兼容 : http://<LAN-IP>:<实际端口>/v1
Anthropic   : http://<LAN-IP>:<实际端口>/v1/messages
API Key     : 见 llm start / status 输出
```

示例：

```powershell
$key = "你的key"
$body = @{
  model = "qwen3.8-flash-next-iq2_xs"
  messages = @(@{ role = "user"; content = "用三句话介绍 5G 模组" })
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri "http://127.0.0.1:<实际端口>/v1/chat/completions" `
  -Method Post -Headers @{ Authorization = "Bearer $key" } `
  -ContentType "application/json" -Body $body
```

## RAM 守卫

`config\settings.json`：

```json
"watchdog": {
  "sampleSeconds": 5,
  "reserveRamGB": 12,
  "warnRamGB": 8,
  "stopRamGB": 4,
  "stopAfterSamples": 6,
  "pageFileWarnPct": 70,
  "graceSeconds": 180
}
```

- 启动后 180 秒内不杀（加载期）；
- 空闲内存连续 6 次（30 秒）低于 4 GB → 自动停 LLM；
- 低于 8 GB 记 WARN；
- 页面文件 >70% 记 WARN；
- 数据写入 `runtime\health.json` 和 `runtime\logs\metrics.jsonl`。

调参建议：浏览器多、VS Code 插件多时，把 `stopRamGB` 提到 5–6，`reserveRamGB` 提到 14。

## 与视频互斥

同一块 32 GB 显卡不能同时装下 Strata 的专家缓存和 Wan2.2 的 20–26 GB。
用 `.\b65.ps1 mode video` / `mode llm`，或仪表盘的 “Mode” 按钮。

## 排错

| 现象 | 处理 |
|---|---|
| 端口没起来 | 看 `runtime\logs\llm.stderr.log`；多为参数不识别或模型未 setup |
| 报 `bmg-g21` / no engine | 装错包；换 `bmg-g31` 的 XeStrata 构建 |
| 启动后系统极慢 | 这个配置项不存在；关浏览器/编辑器、减少 `context`，watchdog 会在内存持续不足时停 LLM |
| API 401 | 用 `status` 里最新的 Key；重启后 Key 不变 |
| 局域网连不上 | 检查防火墙实际端口、`host` 是否为 `0.0.0.0`、是否同一网段 |
