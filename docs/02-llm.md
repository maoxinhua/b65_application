# 02 · LLM 运行手册

## 为什么是 IQ2_XS + 32K

| 项 | 选择 | 原因 |
|---|---|---|
| 模型 | Qwen3.8-Flash-Next IQ2_XS | 125B-A6B，48 GB 内存可全驻留；IQ3_S 要 62 GB，64 GB Windows 会 paging |
| 上下文 | 32768 | KV 不挤占专家缓存；稳定后再试 64K/128K |
| 引擎 | XeStrata | 官方 Strata 没有 Windows 版 Intel 引擎 |
| 后端 | Level Zero / SYCL，AOT `bmg-g31` | B65 与 B70 同核心 |

预期（DDR5-4000，估算）：**decode 45–60 tok/s，prefill 1,200–1,600 tok/s**。
实际以 `--bench` 为准。

## 配置

`config\llm.json`：

```json
{
  "model": "IQ2_XS",
  "context": 32768,
  "vision": false,
  "host": "0.0.0.0",
  "port": 8095,
  "vramReserveMiB": 1024,
  "parallel": 1,
  "source": "modelscope",
  "dataDir": "runtime/xestrata",
  "modelsDir": "models/llm",
  "optionalArgs": true
}
```

- `dataDir` / `modelsDir` 让模型和配置落在工作路径下（约 68 GB）；留空则用 `%LOCALAPPDATA%\xestrata`。
- `source = modelscope` 国内下载更快；可改 `huggingface` 或 `auto`。
- `vramReserveMiB = 1024` 给 WDDM 桌面/浏览器留余量。
- `vision = false` → 传 `--vision no`；要读图再改 true。
- `optionalArgs = false` 可在引擎不认 `--vram-reserve-mib` 时退回最小参数集。
- XeStrata **没有** `--memory-limit-mib`；`--resident-budget-gib` 只适用于 UD-IQ4_XS / UD-Q4_K_XL 等预算型量化，对 IQ2_XS 不生效。IQ2_XS 本身就要 48 GB，限太多会拖慢。

`xestrata-cli.exe --check` 在本机的输出（实测）：

```
GPU 0: Intel(R) Arc(TM) Pro B65 Graphics, 31 GB VRAM
RAM: 64 GB
CPU: 13th Gen Intel(R) Core(TM) i9-13900 (AVX2)
Q2_0 / IQ2_XS -> 48 GB: fits
IQ3_XXS -> 60 GB: fits
IQ3_S -> 62 GB: fits
```

工具会推荐 IQ3_XXS（60 GB），但 Windows 自身要占 4–6 GB，**IQ2_XS 才是 64 GB 机器的稳档**。

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
3. 启动 `xestrata-cli.exe`，等 8095 端口；
4. 探测 `/v1/models`；
5. 启动 watchdog（后台 PowerShell）；
6. 打印本机/LAN 地址和 Key。

## 局域网 API

```text
OpenAI 兼容 : http://<LAN-IP>:8095/v1
Anthropic   : http://<LAN-IP>:8095/v1/messages
API Key     : 见 llm start / status 输出
```

示例：

```powershell
$key = "你的key"
$body = @{
  model = "qwen3.8-flash-next"
  messages = @(@{ role = "user"; content = "用三句话介绍 5G 模组" })
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri "http://127.0.0.1:8095/v1/chat/completions" `
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
| 局域网连不上 | 检查防火墙 8095、`host` 是否为 `0.0.0.0`、是否同一网段 |
