# 03 · 视频工具链

目标：**无人工镜头**的物联网模组培训/推广视频。产品图、参数卡、AI 运镜、配音、剪辑全部本地完成。

## 两条 profile

| Profile | 模型 | 分辨率 | 帧数 | 步数 | 单条预期（B65） | 用途 |
|---|---|---|---|---|---|---|
| `draft` | Wan2.2 TI2V **5B** | 704×480 | 49（2 s） | 20 | 1–3 min | 试镜、构图、运镜 |
| `final` | Wan2.2 I2V **14B** + 4-step LoRA | 1280×720 | 81（3.4 s） | 4 | 5–10 min（估算） | 终稿 |
| `final` + 1080p | 上一步 + FFmpeg lanczos | 1920×1080 | 同上 | — | +10–30 s | 交付 |

> 1080p 默认用 FFmpeg 放大（稳定、零显存）。如果装了 HunyuanVideo 1.5 的 1080p SR 模型，可在
> ComfyUI 里手动跑 SR 工作流，或后续把 `upscale.mode` 扩展为 `workflow`。

## 模型清单

由 `config\models.json` 管理：

| 文件 | 大小 | 用途 |
|---|---|---|
| `wan2.2_ti2v_5B_fp16.safetensors` | ~9.3 GB | draft |
| `wan2.2_i2v_high/low_noise_14B_fp8_scaled.safetensors` | 各 ~13.3 GB | final |
| `wan2.2_i2v_lightx2v_4steps_lora_v1_high/low_noise.safetensors` | 各 ~1.1 GB | final 4 步加速 |
| `umt5_xxl_fp8_e4m3fn_scaled.safetensors` | ~6.3 GB | 文本编码器 |
| `wan_2.1_vae.safetensors` / `wan2.2_vae.safetensors` | 0.2 / 1.3 GB | 14B / 5B |
| `hunyuanvideo1.5_1080p_sr_distilled_fp16.safetensors` | ~2 GB | 可选 AI 超分 |

下载：

```powershell
.\b65.ps1 models -Profile draft
.\b65.ps1 models -Profile final
```

## 工作流

`workflows\*.api.json` 是 ComfyUI **API 格式**，由本仓库维护，节点 ID 与 `config\profiles\video.*.json`
的 `map` 对应。首次使用先校验：

```powershell
.\b65.ps1 video start
.\b65.ps1 test-workflow -Profile draft
```

如果提示 `unknown class_type` 或 `unknown input`，说明你的 ComfyUI 版本节点有差异：

1. 在 ComfyUI 里打开官方模板（Template Browser → Wan2.2 5B / 14B I2V）；
2. 菜单 **Workflow → Export (API)**，保存为 `workflows\my-*.api.json`；
3. 对照 `config\profiles\video.draft.json` 的 `map`，把 node id / input 名改成新文件的；
4. 再跑 `test-workflow -Profile draft -File workflows\my-*.api.json`。

官方 UI 模板（用于手动对照）：

- `https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_wan2_2_5B_ti2v.json`
- `https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_wan2_2_14B_i2v.json`

## 渲染

```powershell
.\b65.ps1 render -Profile draft -Image .\assets\products\module.png `
  -Prompt "slow dolly-in, soft rim light, shallow depth of field, no people"
```

- 会自动启动 ComfyUI（如果没开），并把图片复制到 `ComfyUI\input`；
- 输出到 `output\shots\<profile>-<时间>.mp4`，同名 `.json` 记录参数；
- `final` 默认追加 `_1080p.mp4`；
- 参数可覆盖：`-Width -Height -Frames -Steps -Cfg -Seed -TimeoutSec`。

提示词建议只写**摄影机/光线/材质**，不要写产品规格：

```
slow dolly-in, 35mm, soft rim light, dark studio, shallow depth of field, no people, no text
```

负面词已在工作流里预置（模糊、文字、水印、人手、人物、快速运动、闪烁）。

## 参数卡（最可靠的字幕/卖点方式）

模型生成中文文字几乎必错。所有规格、型号、卖点都用 HTML 卡片渲染：

```powershell
.\b65.ps1 card -Data .\config\cards\example.json
```

数据格式见 `config\cards\example.json`：`kicker/title/subtitle/bullets/specs/footer/accent/logo/background/output`。
模板在 `assets\cards\spec-card.html`，改 CSS 即可换品牌风格。

## 组装成片

`projects\iot-demo\manifest.json`：

```json
{
  "width": 1920, "height": 1080, "fps": 30,
  "scenes": [
    { "type": "card",  "data": "projects/iot-demo/cards/intro.json", "duration": 5 },
    { "type": "image", "path": "assets/products/module.png", "duration": 5, "effect": "kenburns" },
    { "type": "clip",  "path": "output/shots/draft-xxxx.mp4", "duration": 5 },
    { "type": "card",  "data": "projects/iot-demo/cards/specs.json", "duration": 6 }
  ],
  "audio": { "voice": "", "music": "", "musicVolume": 0.12 },
  "output": "output/iot-demo.mp4"
}
```

```powershell
.\b65.ps1 build -Manifest .\projects\iot-demo\manifest.json
```

- 每个场景统一转 1920×1080 / 30 fps / H.264；
- 图片/卡片支持 Ken Burns 推拉；
- 音轨支持配音 + 背景音乐混音；
- 先跑 `-DryRun` 看命令，再正式执行。

## 无人工镜头的 IoT 视频配方

| 段落 | 画面 | 做法 |
|---|---|---|
| 开场 0–5 s | 品牌/主题卡 | `card`（HTML） |
| 5–12 s | 产品特写 | 实拍/渲染图 → `image` Ken Burns，或 `draft` I2V 缓慢运镜 |
| 12–25 s | 场景/应用 | AI 生成的机柜、产线、城市背景（不含人）→ `clip` |
| 25–40 s | 规格/接口 | 2–3 张 `card`，配旁白 |
| 40–60 s | 总结/CTA | `card` + 音乐收尾 |

配音：本地 TTS（IndexTTS 2 / VoxCPM）或真人录音；音乐用版权库。字幕用剪映/达芬奇统一加。

## 许可

- **Wan2.2：Apache 2.0**，可商用、可改、可闭源分发；
- **HunyuanVideo 1.5**：腾讯社区许可，排除欧盟/英国/韩国，MAU 上限 1 亿；
- **MiniMax H3**：排除欧盟/英/韩/美，年营收 >2000 万美元需书面授权；
- **LTX-2**：营收 >1000 万美元需付费，且禁止竞争性产品。

公司广告只建议用 **Wan2.2**；其他模型先走法务。
