# 10 · Qwen3.8-27B 质量引擎（B65 / llama.cpp SYCL）

> 2026-11-01。目标：在 B65 32 GB 上建立**质量优先、稳定**的 27B 本机模型，并接入 Windows 工作台。
> 量化选择：**UD-Q6_K_XL**（25.3 GB）+ Q4_0 MTP；Q8_0 29 GB 加 MTP/KV 放不下，Q6_K_XL 是 32 GB 上可稳定运行的最高档。

## 1. 文件与运行时

| 项目 | 路径 |
|---|---|
| 权重 | `models\llm\Qwen3.8-27B\Qwen3.8-27B-UD-Q6_K_XL.gguf`（25,299,061,664 B） |
| MTP draft | `models\llm\Qwen3.8-27B\mtp-Qwen3.8-27B-Q4_0.gguf`（1.37 GB） |
| 引擎 | `tools\llama-b12024\llama-server.exe`（Windows SYCL，b12024） |
| 配置 | `config\llm27b.json` |
| 启动器 | `scripts\Llama27B.ps1` |
| 端口 | **8096** |
| 上下文 | **65536**（32K 也验证过） |
| API | OpenAI 兼容 `/v1`，`--api-key` |

启动参数要点：

```text
--device SYCL0 --split-mode none --n-gpu-layers 999 --flash-attn on
--cache-type-k q8_0 --cache-type-v q8_0
--spec-type draft-mtp --spec-draft-model mtp... --spec-draft-ngl 99
--spec-draft-n-max 3 --spec-draft-p-min 0.1 --fit off
```

## 2. 实测结果

### 32K / 64K 加载

| 上下文 | 结果 | 显存 | RAM 空闲 |
|---:|---|---:|---:|
| 32,768 | 通过 | ~29.7 GB（26.2 + 3.4 shared） | 13.4 GB |
| 65,536 | 通过 | ~30.8 GB（27.6 + 3.2 shared） | 15.2 GB |

### 质量测试（32K，3 轮）

| 测试 | 结果 |
|---|---|
| math 17×23 | 391，全部通过 |
| 中文 5G RedCap | 全部通过，内容完整 |
| JSON | 全部通过，可解析 |
| PowerShell Get-Square | 全部通过，语法正确 |
| 严格 5 行输出 | 全部通过 |

### token 速率

| 测试 | decode |
|---|---:|
| math（32K 暖机） | 39.8–51.2 tok/s |
| 中文 | 37.9–38.6 tok/s |
| JSON | 44.5–49.3 tok/s |
| 代码 | 40.3–49.3 tok/s |
| 指令 | 49.2–53.8 tok/s |
| 24K prompt（64K） | prefill **175.9 tok/s**，decode **37.5 tok/s**，内容 `7391` 正确 |

24K 长文首次 prefill 约 2 分 30 秒；同一前缀第二次请求命中 prefix cache，**5.9 秒**完成。

## 3. 使用

```powershell
.\b65.ps1 llm27b start
.\b65.ps1 llm27b status
.\b65.ps1 llm27b endpoint
.\b65.ps1 llm27b stop
```

面板 LLM 页提供 **“27B 开/停”** 按钮；启动 27B 会先停 XeStrata/ComfyUI，启动 XeStrata 会先停 27B，保持单 GPU 独占。

## 4. DSH 路由

WSL2（mirrored）：

```yaml
qwen38-27b-local:
  displayName: 13900_Qwen3.8-27B_UD-Q6_K_XL
  apiKeyEnv: QWEN38_27B_API_KEY
  api: openai-completions
  baseURL: http://127.0.0.1:8096/v1
  models:
    - id: qwen3.8-27b-ud-q6kxl
      name: 13900_Qwen3.8-27B_UD-Q6_K_XL
      contextWindow: 65536
      maxTokens: 8192
      input: [text]
```

Windows 用 `http://10.88.115.60:8096/v1`；key 已写入各自 `.credentials.yaml` 的 `QWEN38_27B_API_KEY`。

## 5. 边界

- 64K 已加载并跑过 24K prompt；没有填满 64K，也没有试 128K（显存会超）。
- 32K/64K 各跑过质量测试，无崩溃；27B 的加载约 0.5–1.5 分钟。
- 质量优先不代表一定优于 125B IQ3_XXS；两者定位不同：27B 是稠密/混合注意力质量档，IQ3_XXS 是长上下文 128K 的 MoE 档。
- 与 XeStrata 互斥；切换会自动停另一侧。
