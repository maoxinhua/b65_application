# 06 · 核显（UHD 770）能不能并行帮忙？

结论先说：**能，但只能当“辅助卡”，不能当第二张计算卡。** 值得为它做的只有两件事：把显示器接过去、保留一个 QSV 测试脚本；不值得为它单独搭 LLM/视频工作流。

## 硬件事实

| 项 | UHD Graphics 770 | Arc Pro B65 |
|---|---|---|
| 架构 | Xe-LP，32 EU | Xe2，20 Xe 核 / 160 XMX |
| FP32 峰值 | ~0.8 TFLOPS | ~12.3 TFLOPS（FP16 ~99 TFLOPS） |
| 矩阵单元 | 无 XMX | 160 XMX |
| 显存 | **无专用显存**，共享 DDR5 | 32 GB GDDR6，608 GB/s |
| 内存带宽 | 与 CPU 共享 ~45 GB/s | 608 GB/s |
| 媒体引擎 | Quick Sync（AVC/HEVC/VP9 编解码，AV1 解码） | 双 MFX，AV1 编解码 |
| 当前用途 | **空闲** | 4K60 显示 + 全部计算 |

算力差距约 **100 倍**，带宽差距约 **13 倍**。这决定了它只能做轻活。

## 实测（本机，2026-10-21）

### 1. QSV 能分别选中两张卡

FFmpeg 的 `-qsv_device` 在本机把两张 Intel 卡区分得很清楚：

```
-qsv_device 0  ->  8086:e222  Intel(R) Arc(TM) Pro B65 Graphics
-qsv_device 1  ->  8086:a780  Intel(R) UHD Graphics 770
```

`h264_qsv`、`hevc_qsv`、`av1_qsv` 都能初始化（AV1 编码实际走的是 B65 的媒体引擎，UHD 770 只支持 AV1 解码）。

### 2. 编码速度：1080p 上 iGPU 不如 CPU

30 秒 1080p H.264（testsrc2，仅比较吞吐）：

| 路径 | 耗时 | 相对实时 |
|---|---:|---:|
| libx264 veryfast（CPU） | 1.60 s | 18.8× |
| h264_qsv（B65） | 1.94 s | 15.5× |
| h264_qsv（UHD 770） | 3.66 s | 8.2× |

5 秒 4K：

| 路径 | 耗时 |
|---|---:|
| libx264 veryfast | 1.33 s |
| h264_qsv（B65） | 2.24 s |
| h264_qsv（UHD 770） | 2.43 s |

**结论：1080p H.264 用 CPU 最快，QSV 反而更慢**（会话初始化 + 固定功能管线开销）。4K/HEVC 时 QSV 才有机会追平或省 CPU，但本项目的交付是 1080p H.264，所以默认继续用 libx264。

## 三个“能帮上忙”的角色

### A. 显示输出（最值得，立刻做）

当前 4K60 显示器接在 B65 上，桌面/浏览器占了约 **2.3 GB 专用显存**。把它接到主板的 HDMI/DP：

- 释放 ~2.3 GB VRAM ≈ **1,600 个专家缓存**（每 GB 约 700 个），命中率约 +6%，decode 可能 +2–5%；
- 桌面合成、视频播放不再和推理抢 B65 的调度；
- iGPU 跑 4K60 桌面只占 ~1–2 GB/s 共享内存带宽，对 45 GB/s 的 Strata 影响很小。

步骤：

1. BIOS：`Internal Graphics = Enabled`、`iGPU Multi-Monitor = Enabled`（不同主板叫法略有差异）；
2. 显示器线插到**主板**的 HDMI/DP，不要插 B65；
3. 进 Windows 确认桌面在 `Intel(R) UHD Graphics 770` 上；
4. 跑 `.\b65.ps1 doctor`，应看到 Arc 的专用显存占用明显下降；
5. 如有问题，BIOS 改回即可，不影响 B65。

### MSI B760（Click BIOS 5）具体路径

微星 B760 的菜单名在不同 BIOS 版本里略有差异，按下面顺序找：

1. 开机按 **Del** 进 BIOS，按 **F7** 切到 Advanced；
2. `Settings` → `Advanced` → **`Integrated Graphics Configuration`**；
3. 把 **`Initiate Graphic Adapter`** 改成 **`IGD`**（原值通常是 `PEG`）；
4. 把 **`IGD Multi-Monitor`** 改成 **`Enabled`**（不打开的话，插着独显时核显会被关掉）；
5. **`Integrated Graphics Share Memory`** 选 **128M**（4K 桌面更稳；只占 128 MB 系统内存）；
6. **F10** 保存退出，关机；
7. 把显示器线从 B65 拔下，插到**主板的 HDMI/DP**；
8. 开机进 Windows，`设置 → 系统 → 显示 → 高级显示` 应显示
   `Intel(R) UHD Graphics 770`；
9. 跑 `.65.ps1 doctor`，`Display` 行应变成 UHD 770，B65 的 `dedicated` 应明显下降。

如果找不到 `Integrated Graphics Configuration`，去这两个位置找：

- `Settings` → `Advanced` → **`Integrated Peripherals`** → `Initiate Graphic Adapter`；
- 或 BIOS 里直接搜 **`IGD`** / `Multi-Monitor`。

顺序上的坑：

- 如果先把 `Initiate Graphic Adapter` 改成 `IGD`、但显示器还插在 B65 上，可能黑屏；
  稳妥做法是**先开 `IGD Multi-Monitor` 并保存**，关机、换线，再进来把 primary 改成 `IGD`。
- 换线后如果无信号：把线插回 B65，进 BIOS 确认 `IGD Multi-Monitor=Enabled`；
  仍不行就清 CMOS（主板上的 JBAT1 短接）恢复默认。
- `Above 4G Decoding` / `Re-Size BAR` 不用动，继续给 B65 用。

Windows 侧没有“把桌面强制切到某张卡”的全局开关——**桌面跟着显示器所接的 GPU 走**。
换线后如果想给具体程序指定 B65：
`设置 → 系统 → 显示 → 图形 → 添加应用 → 选项 → 高性能`。

### B. QSV 编码/解码（可选，默认不开）

适用场景：

- 需要 **HEVC 4K** 或低 CPU 占用的批量转码；
- 需要一边用 CPU 做别的事（剪辑、打包），一边导出；
- 需要给长素材生成**低码率预览代理**。

不适用：1080p H.264 成片（实测更慢）。

脚本：`.\b65.ps1 test-qsv` 会打印两张卡的名字和三条路径的耗时，自己判断。
`Build-Video.ps1` 已支持 `-Encoder h264_qsv|hevc_qsv -QsvDevice 1`，但默认仍是 `libx264`。

### C. 轻量辅助推理（可选，优先级最低）

iGPU 可以跑 Whisper、OCR、embedding、TTS 这类小模型（OpenVINO 或 PyTorch XPU device 1）。但：

- 它没有 XMX，只适合 <1B 的模型；
- 和 Strata 抢同一块 DDR5 带宽，**LLM 推理期间跑会拖慢 token**；
- 视频渲染期间 B65 是算力瓶颈、CPU 反而空闲，这时用 CPU 跑 TTS/Whisper 更简单。

所以只有在“CPU 被占满、又必须同时转写/配音”时才值得，当前不建议为它建工作流。

## 三个“不要做”

| 想法 | 结论 |
|---|---|
| 让 Strata 用 iGPU 跑第二个模型 | ❌ 无 XMX、共享内存，速度个位数 tok/s，还抢带宽 |
| 让 ComfyUI 在 iGPU 上跑 Wan2.2 | ❌ 算力差 100 倍，5 秒片子要小时级 |
| LLM + 视频同时跑（B65 给两个引擎） | ❌ 32 GB 显存装不下两套工作集，仍要分时 |

## 并行时的带宽账

| 任务 | 内存流量 | 对 Strata 的影响 |
|---|---|---|
| 4K60 桌面 | ~1–2 GB/s | 可忽略 |
| QSV 1080p 编码 | ~0.15 GB/s | 可忽略 |
| QSV 4K 编码 | ~0.6 GB/s | 很小 |
| Whisper/embedding | 1–5 GB/s | 明显，decode 可能掉 5–15% |
| 第二个 LLM | 20–40 GB/s | 灾难 |

## 建议

1. **把显示器改接 iGPU**——这是唯一“零成本、确定收益”的动作；
2. 保留 `test-qsv` 作为工具，不改默认编码路径；
3. 不要为 iGPU 单独建 LLM/视频工作流；
4. 如果以后要做 4K HEVC 交付，再用 `-Encoder hevc_qsv -QsvDevice 1` 并实测质量/码率。
