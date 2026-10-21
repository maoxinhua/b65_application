# Workflows

These are **ComfyUI API-format** graphs (not the UI-format `nodes/links` files). The renderer posts them
to `POST /prompt`.

## Files

| File | Profile | Purpose |
|---|---|---|
| `wan22_ti2v_5b.api.json` | draft | Wan2.2 TI2V 5B, 704×480, 49 frames, 20 steps |
| `wan22_i2v_14b.api.json` | final | Wan2.2 I2V 14B + 4-step Lightning LoRA, 1280×720, 81 frames |

## Node map

`config/profiles/video.*.json` patches these node IDs:

### draft (`wan22_ti2v_5b.api.json`)

| Key | Node | Input |
|---|---|---|
| positive | 6 | text |
| negative | 7 | text |
| image | 52 | image |
| width/height/frames | 55 | width/height/length |
| steps/cfg/seed | 3 | steps/cfg/seed |

### final (`wan22_i2v_14b.api.json`)

| Key | Node | Input |
|---|---|---|
| positive | 6 | text |
| negative | 7 | text |
| image | 97 | image |
| width/height/frames | 98 | width/height/length |
| steps/cfg/seed | 3 | steps/cfg/seed |
| endSteps/endCfg/endSeed | 13 | steps/cfg/noise_seed |

## If validation fails

ComfyUI changes node signatures between versions. The workbench validates every node against
`/object_info` before submitting:

```powershell
.\b65.ps1 test-workflow -Profile draft
```

If it reports an unknown class or input:

1. Open ComfyUI → Template Browser → the matching Wan2.2 template;
2. **Workflow → Export (API)**;
3. Save as `workflows\my-<name>.api.json`;
4. Update the profile's `workflow` path and `map` node IDs;
5. Validate again.

Official UI templates:

- 5B: https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_wan2_2_5B_ti2v.json
- 14B I2V: https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_wan2_2_14B_i2v.json
- 14B T2V: https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_wan2_2_14B_t2v.json

## Model names

The graphs expect:

```
models/comfyui/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors
models/comfyui/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors
models/comfyui/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors
models/comfyui/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors
models/comfyui/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors
models/comfyui/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors
models/comfyui/vae/wan_2.1_vae.safetensors
models/comfyui/vae/wan2.2_vae.safetensors
```

They are mapped into ComfyUI by `apps/ComfyUI_windows_portable/ComfyUI/extra_model_paths.yaml`.

## 1080p

`final` uses FFmpeg lanczos + unsharp after the 720p render (`config/profiles/video.final.json → upscale`).
For AI super-resolution, install the HunyuanVideo 1.5 SR model and add a separate workflow; the current
`Invoke-Render.ps1` only implements `mode: ffmpeg`.
