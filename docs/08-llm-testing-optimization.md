# 08 · IQ3 模型测试与 Windows 优化

适用：Windows 11 + Arc Pro B65 32 GB + 64 GB DDR5-4000 + i9-13900。  
目标：在不把机器拖死的前提下，验证 IQ3_XXS / IQ3_S 的质量、速度和稳定性，并给出可复现的配置。

## 0. 先分清两个 DSH

| 场景 | 位置 | 关闭 WSL2 后 |
|---|---|---|
| **Windows DSH** | `C:\Users\eddy\.dsh`，Windows 进程 | **不受影响**，继续可用 |
| **WSL DSH** | Ubuntu-20.04 里的 `dsh` | 会被 `wsl --shutdown` 停掉 |

你目前是在 **Windows DSH** 里测试，因此：

- `wsl --shutdown` 只会停掉 WSL 里的 opencode / hermes / celery 等进程；
- Windows DSH、B65 面板、`b65.ps1` 都不受影响；
- 关闭后 Windows 可多出约 **6–8 GB** 空闲内存（实测 `vmmemWSL` Private ≈ 8.4 GB）。

如果哪天 `dsh` 是从 Ubuntu 终端启动的，就不能关 WSL。

## 1. 五分钟自检

```powershell
cd E:\dsh_project\B65_graphic

.\b65.ps1 status          # 模式、RAM/VRAM、端口、实际模型 id
.\b65.ps1 llm list        # 三档是否安装、体积、内存需求、默认档
.\b65.ps1 llm endpoint    # baseURL / localURL / model / apiKey 的 JSON
```

正常状态示例（IQ3_XXS + mmap）：

```text
Mode : llm
RAM  : 9–20 GB free（随专家缓存变化）
VRAM : ~33 GB
LLM  : RUNNING  port=63844  model=qwen3.8-flash-next-iq3_xxs  ctx=32768
```

## 2. 自动化测试（推荐）

脚本已经放在 `scripts/Test-Llm.ps1`，直接对运行中的 API 做五类检查：

| 测试 | 检查内容 |
|---|---|
| `health` | `/health` 返回 ok，模型 id |
| `models` | `/v1/models` 带 Key 可访问，id 与当前模型一致 |
| `math` | `17 × 23` 最终答案包含 `391` |
| `chinese` | 中文回答非空、长度合理 |
| `json` | 只输出 JSON，且能被 `ConvertFrom-Json` 解析 |

运行：

```powershell
.\b65.ps1 test-llm -Runs 1
# 更稳的 3 次取平均
.\b65.ps1 test-llm -Runs 3 -MaxTokens 1200
```

输出：

```text
output\llm-tests\llm-test-<时间>.md
output\llm-tests\llm-test-<时间>.json
output\llm-tests\llm-test-<时间>.csv
```

本机实测（IQ3_XXS，`lowRam=mmap`，32K，WSL 开着）：

| 测试 | decode tok/s | prompt tok/s | 结果 |
|---|---:|---:|---|
| math | 45.3 | 84.7 | `391` |
| chinese | 44.4 | 88.5 | 正常中文 |
| json | 51.7 | 98.1 | `{"model":"RM500Q","5g":true,"redcap":true}` |

测试后空闲内存约 **9.6 GB**，显存约 **33.7 GB**，watchdog `action=none`。

> `test-llm` 的请求体按 UTF-8 字节发送、响应按 UTF-8 解码；PowerShell 5.1 直接传字符串会在中文/`×` 上出错，脚本已经处理。

## 3. 自定义选项（IQ3_XXS）

运行选项集中在 `config\llm.json`：

```json
{
  "model": "IQ3_XXS",
  "context": 32768,
  "contextPresets": [32768, 65536, 131072, 262144],
  "lowRam": "mmap",
  "kv": "int8",
  "noWarmup": true,
  "maxOutputTokens": 8192,
  "temperature": 0.7,
  "topP": 0.95,
  "vramReserveMiB": 1024,
  "parallel": 1
}
```

| 选项 | 作用 |
|---|---|
| `context` | 启动时的上下文长度；改完要重启 |
| `contextPresets` | 面板/脚本可选档位，仅作 UI 提示 |
| `lowRam` | `mmap`（省内存） / `on`（更快） / `auto` |
| `kv` | `int8` / `q4_0` / `k8v4`；默认 int8 |
| `noWarmup` | **true 时固定绑 8095**，跳过随机 warm-up 端口 |
| `maxOutputTokens` | 给 DSH/客户端的默认输出上限 |
| `temperature` / `topP` | 客户端默认采样参数 |
| `vramReserveMiB` | 给桌面留的显存 |
| `parallel` | 并发请求数，单用户 1 |

命令行覆盖：

```powershell
.\b65.ps1 llm use    -Model IQ3_XXS -Context 65536 -LowRam mmap -Kv int8
.\b65.ps1 llm switch -Model IQ3_XXS -Context 65536 -LowRam mmap -Kv int8
.\b65.ps1 llm endpoint
```

面板 LLM 页底部“**选项...**”直接打开 `llm.json`；改完点“应用并重启”。

### noWarmup 与端口

XeStrata 的 warm-up 会临时绑一个随机端口，之前导致 DSH 的 `baseURL` 每次都要改。设置：

```json
"noWarmup": true
```

重启后实测稳定在：

```text
http://10.88.115.60:8095/v1
```

代价是第一次请求可能要编译 GPU 代码（几十秒），之后走缓存。

## 3.1 最大上下文实测（WSL2 保持开启）

测试条件：IQ3_XXS、`lowRam=mmap`、`kv=int8`、`noWarmup=true`、64 GB RAM、WSL2 运行中。

| context | 能否加载 | 长输入实测 | 短请求 decode | 请求后空闲 RAM |
|---:|---|---|---:|---:|
| 32,768 | ✅ | **31,068 token**，prefill 1,291 tok/s，答案正确 | 30–55 tok/s | 23.5 GB |
| 40,960 | ✅ | 未填满 | — | 23.5 GB |
| 49,152 | ✅ | 未填满 | — | 23.6 GB |
| 65,536 | ✅ | 未填满 | 24–38 tok/s | 22.1 GB |
| 98,304 | ✅ | 未填满 | — | 21.7 GB |
| 131,072 | ✅ | 未填满 | — | 22.5 GB |
| 262,144 | ✅ | 未填满 | 26–32 tok/s | 27.3 GB |

结论：

- **模型原生最大上下文是 262,144（256K）**；
- `--context 262144` 能加载，`/health` 返回 `max_context=262144`；
- **32K 已经用 31,068 token 的真实输入验证**（不是只看配置）；
- 64K/128K/256K 只验证了“能加载”，没有把上下文填满；填满 256K 需要约 25 万 token 的 prompt，耗时长且可能触发换页/变慢；
- 日常建议 **32K 或 64K**；更大上下文会降低短请求速度，并增加内存压力。

## 3. 手工 API 验证

```powershell
$ep = (.\b65.ps1 llm endpoint | ConvertFrom-Json)
$ep.baseURL
$ep.model

# 健康检查（不需要 Key）
Invoke-RestMethod "$($ep.baseURL.Replace('/v1',''))/health" | ConvertTo-Json

# 模型列表（需要 Key）
Invoke-RestMethod "$($ep.baseURL)/models" -Headers @{ Authorization = "Bearer $($ep.apiKey)" } |
  ConvertTo-Json -Depth 5
```

聊天请求注意 **UTF-8 字节**：

```powershell
$body = @{
  model = $ep.model
  messages = @(@{ role = 'user'; content = '只回答：17 × 23 = ?' })
  max_tokens = 600
  temperature = 0.2
} | ConvertTo-Json -Depth 8 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
Invoke-RestMethod "$($ep.baseURL)/chat/completions" `
  -Method Post -Headers @{ Authorization = "Bearer $($ep.apiKey)" } `
  -ContentType 'application/json; charset=utf-8' -Body $bytes
```

或者用 `curl`（避免 PowerShell 编码问题）：

```bash
curl -s http://127.0.0.1:<port>/v1/chat/completions \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"model":"qwen3.8-flash-next-iq3_xxs","messages":[{"role":"user","content":"只回答：17*23=?"}],"max_tokens":600}'
```

## 4. 质量测试题集

固定题集、相同参数、每个模型跑 3 次，记录 `timings` 和答案是否正确：

| 类型 | 提示 | 判定 |
|---|---|---|
| 算术 | 只回答最终答案：17 × 23 | 包含 `391` |
| 中文技术 | 三句话说明 5G RedCap 对 IoT 模组价值 + 场景 | 非空、无重复、术语正确 |
| JSON | 只输出 JSON：model=RM500Q, 5g=true, redcap=true | 可 `ConvertFrom-Json` |
| 工具调用 | 让模型调用 `get_weather(Beijing)` | 返回 `tool_calls[0].function.name = get_weather` |
| 长文/代码 | 200 行 PowerShell 或 C 代码 | 人工检查编译/逻辑 |

切换模型后重新跑：

```powershell
.\b65.ps1 llm switch -Model IQ3_XXS
.\b65.ps1 test-llm -Runs 3

.\b65.ps1 llm switch -Model IQ3_S
.\b65.ps1 test-llm -Runs 3
```

> 推理模型会先输出 `reasoning_content`；`max_tokens` 太小会只剩 reasoning、没有最终 content。测试脚本默认 1500，手工请求建议 ≥1200。

工具调用建议在 **Windows DSH** 里测：DSH 是 coding agent，真实工具往返比单次 curl 更能说明问题。

## 5. 性能测试

每次请求的 `timings` 里取：

- `prompt_per_second`：prefill；
- `predicted_per_second`：decode（主要指标）；
- `draft_n_accepted / draft_n`：投机解码接受率。

方法：

1. 第一次请求是冷启动/编译，丢弃；
2. 连续跑 3 次同样 prompt，取平均；
3. 记录当时的 `lowRam`、WSL 是否运行、空闲 RAM；
4. 同时看 `runtime\health.json` 的 `freeGB` / `pageFileUsedMB`。

本机参考：

| 配置 | decode | 请求后空闲 RAM |
|---|---:|---:|
| IQ2_XS + `auto` | ~50–53 tok/s | ~16 GB |
| IQ3_XXS + `mmap` | ~40–52 tok/s | 9–20 GB |
| IQ3_XXS + `on` | ~48 tok/s | ~5 GB（WSL 开） |
| IQ3_XXS + `on` + WSL 关 | ~48 tok/s | ~12 GB |
| IQ3_S + `mmap` | 预计 25–35 tok/s | 更紧，未正式测 |

## 6. 稳定性/内存测试

- 连续对话 30–60 分钟，或批量跑 20 个请求；
- 每 10 分钟记录：`status` 的 RAM/VRAM、`runtime\health.json` 的 page file；
- 观察是否出现 `low-ram`、watchdog 停止、页面文件持续上涨；
- 重点比较 **WSL 开/关** 两种状态。

`config\settings.json` 的 watchdog：

```json
"watchdog": {
  "reserveRamGB": 12,
  "warnRamGB": 8,
  "stopRamGB": 4,
  "stopAfterSamples": 6,
  "graceSeconds": 180
}
```

- 日常（mmap，空闲 9–20 GB）：保持默认；
- 质量模式（`on`，空闲 5 GB）：建议 `stopRamGB=2`，避免一次请求就被误杀；
- 专用跑分：可 `stopRamGB=1`，但要接受系统卡顿。

## 7. 配置优化

### 7.1 模型档位

| 档位 | 下载 | `--check` 内存 | 质量 | 默认 `lowRam` |
|---|---:|---:|---|---|
| IQ2_XS | 68 GB | ~48 GB | 基线 | `auto` |
| **IQ3_XXS** | 76 GB | ~60 GB | 推荐 | `mmap` |
| IQ3_S | 84 GB | ~62 GB | 最高 | `mmap` |

```powershell
.\b65.ps1 llm list
.\b65.ps1 llm use    -Model IQ3_XXS   # 只改配置
.\b65.ps1 llm switch -Model IQ3_XXS   # 改配置并重启
```

### 7.2 lowRam 三种模式

| 模式 | 行为 | 适用 |
|---|---|---|
| `auto` | 引擎默认 | IQ2_XS |
| `mmap` | 专家按需映射，内存占用低 | IQ3_XXS / IQ3_S 日常 |
| `on` | 更快，但把专家拉进 RAM | WSL 关闭、专用跑分 |

配置在 `config\llm.json`：

```json
{
  "model": "IQ3_XXS",
  "lowRam": "mmap",
  "residentBudgetGiB": 0,
  "context": 32768,
  "vramReserveMiB": 1024,
  "parallel": 1
}
```

> **不要设 `residentBudgetGiB`。** 在 IQ3_XXS 上设 48 会导致 `strata` 启动时 `SIGSEGV`；保持 0。

### 7.3 其他参数

- `context=32768`：32K 是稳定档；再大 KV 挤占专家缓存。
- `vramReserveMiB=1024`：给桌面/浏览器留余量；4K 桌面可到 2048。
- `parallel=1`：单用户最快；多用户再考虑 2。
- `--kv int8`：默认，够用。
- 页面文件保持 24 GB；IQ3_XXS mmap 会用到 4–10 GB。

## 8. WSL2 与内存

当前 `.wslconfig`（`C:\Users\eddy\.wslconfig`）：

```ini
[wsl2]
memory=40GB
swap=16GB

[experimental]
autoMemoryReclaim=gradual
```

- WSL 实际 used 约 5.9 GB，`vmmemWSL` private 约 8.4 GB；
- `wsl --shutdown` 可立即还回 **6–8 GB**；
- 想更积极回收，可把 `autoMemoryReclaim` 改 `dropcache`，再 `wsl --shutdown` 重启；
- 不建议把 `memory=40GB` 调小来“省当前内存”——它只是上限，当前只用 6 GB。

推荐：

| 需求 | 做法 |
|---|---|
| Windows DSH + IQ3_XXS 日常 | WSL 可开，`lowRam=mmap` |
| 要 45–48 tok/s 且系统不卡 | `wsl --shutdown` + `lowRam=on` |
| 要在 WSL 里跑 DSH | 不能关 WSL，用 `mmap` |
| 要 IQ3_S | 关 WSL/浏览器，`mmap`，接受 25–35 tok/s |

## 9. Windows DSH 配置

DSH 的模型路由在：

```text
C:\Users\eddy\.dsh\cordis.patch.yml
```

每次 XeStrata 重启，端口可能变化（实测 55354、52072、63844、59643）。用：

```powershell
.\b65.ps1 llm endpoint
```

拿到：

```json
{
  "baseURL": "http://10.88.115.60:8095/v1",
  "model": "qwen3.8-flash-next-iq3_xxs",
  "apiKey": "...."
}
```

更新 DSH 路由：

```yaml
qwen38-flash-next:
  apiKeyEnv: QWEN38_FLASH_NEXT_API_KEY
  baseURL: http://10.88.115.60:8095/v1
  models:
    - id: qwen3.8-flash-next-iq3_xxs
      contextWindow: 32768
      maxTokens: 8192
      input: [text]
```

然后重启 Windows DSH（home patch 文件新建时不会热加载）。

> 因为默认 `noWarmup=true`，XeStrata 现在稳定绑 **8095**，DSH 的 `baseURL` 不用每次改。若你关掉 `noWarmup`，端口会变，必须重新跑 `llm endpoint`。

## 10. 推荐日常方案

| 场景 | 模型 | lowRam | WSL | 预期 |
|---|---|---|---:|---|
| 日常 Windows DSH | IQ3_XXS | `mmap` | 开 | 40–52 tok/s，9–20 GB 空闲 |
| 追求速度 | IQ3_XXS | `on` | 关 | 45–48 tok/s，~12 GB 空闲 |
| 最高质量 | IQ3_S | `mmap` | 关 | 25–35 tok/s，内存很紧 |
| 快速回退 | IQ2_XS | `auto` | 开 | 50–53 tok/s，~16 GB 空闲 |

## 11. 已知问题

1. **端口随机**：XeStrata 可能不绑 8095；`llm endpoint` / 面板 / `status` 是唯一可信来源。
2. **`residentBudgetGiB` 崩溃**：IQ3_XXS 上设 48 会 `SIGSEGV`，保持 0。
3. **PowerShell 5.1 中文**：请求体用 UTF-8 字节，响应用 UTF-8 解码；`Test-Llm.ps1` 已处理。
4. **推理模型空 content**：`max_tokens` 太小会只返回 reasoning；测试用 ≥1200。
5. **WSL 内存**：`wsl --shutdown` 会停掉 WSL 内所有任务，先保存工作。

## 12. 命令速查

```powershell
# 状态 / 模型 / 端点
.\b65.ps1 status
.\b65.ps1 llm list
.\b65.ps1 llm endpoint

# 切换 / 重启
.\b65.ps1 llm switch -Model IQ3_XXS
.\b65.ps1 llm restart
.\b65.ps1 llm stop

# 自动化测试
.\b65.ps1 test-llm -Runs 3 -MaxTokens 1200

# 释放 WSL 内存（会停 WSL 任务）
wsl --shutdown

# 看内存/显存
Get-CimInstance Win32_OperatingSystem |
  Select-Object @{n='FreeGB';e={[math]::Round($_.FreePhysicalMemory/1MB,1)}}
```
