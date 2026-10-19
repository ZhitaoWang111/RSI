# RSI — 递归自我改进（Recursive Self-Improvement）调研与复现

本仓库用于 RSI 方向的文献调研与开源方法复现。**只包含笔记、论文和重建脚本**；所有第三方代码通过脚本从上游仓库拉取，不 vendored 进本仓库。

## 目录结构

```
docs/          调研笔记
papers/        论文 PDF（原创与中文版）
patches/       对上游代码的必要补丁
scripts/       环境重建脚本
Submodule/     （gitignored）上游仓库，由脚本拉取
```

## 为什么 Submodule 不进仓库

`Submodule/` 下是四个上游仓库的独立 clone，总计约 16G（含虚拟环境）。它们各有自己的 remote、许可证和分发限制：

| 仓库 | 上游 | 许可证 |
|---|---|---|
| ASPIRE | [NVlabs/ASPIRE](https://github.com/NVlabs/ASPIRE) | Apache-2.0（含第三方限制，见下） |
| ENPIRE | [NVlabs/ENPIRE](https://github.com/NVlabs/ENPIRE) | Apache-2.0 |
| Dream-RSI | [zhengkid/Dream-RSI](https://github.com/zhengkid/Dream-RSI) | 仅项目页，无代码 |
| EmbodiedEvo | [Einsia/EmbodiedEvo](https://github.com/Einsia/EmbodiedEvo) | 见仓库 LICENSE |

**重要**：ASPIRE 的 `NOTICE` 声明其 `b1k` 子模块含 Pixar 资产，**禁止未经书面授权再分发**；SAM3、cuRobo、Contact-GraspNet 也各有自定义许可。因此本仓库不包含任何上游源码或其子模块内容，请通过官方渠道获取。

## 快速开始

```bash
# 1. 拉取上游仓库并固定在已验证的 commit
bash scripts/setup_third_party.sh

# 2. 应用必要补丁
bash scripts/apply_patches.sh

# 3.（国内环境，可选但强烈推荐）把 uv.lock 指向镜像源
bash scripts/use_mirror.sh              # 或 bash scripts/use_mirror.sh tuna

# 4. 搭建 ASPIRE 环境并验证
bash scripts/setup_aspire_env.sh

# 5.（仅 Blackwell 显卡 sm_120）切换到 cu128 torch
bash scripts/switch_cu128_blackwell.sh
```

第 4 步会自动探测可用的离屏渲染后端（EGL 或 OSMesa）并跑冒烟测试。

## Blackwell（sm_120）必须切 cu128

**症状**：`torch.cuda.is_available()` 返回 `True`，设备名和架构都识别正确，但第一次真正的内核执行就失败：

```
CUDA error: no kernel image is available for execution on the device
```

**原因**：ASPIRE 的 `uv.lock` 钉死 `torch 2.12.1+cu126`。从 `libtorch_cuda.so` 里提取的实际内核架构是：

```
sm_50 sm_60 sm_70 sm_75 sm_80 sm_86 sm_89 sm_90 sm_100
```

**没有 sm_120**。sm_100 是数据中心 Blackwell，与工作站/消费级 Blackwell（sm_120）**指令集不通用**，CUDA 二进制不能跨架构复用。

**修法**：`bash scripts/switch_cu128_blackwell.sh`

| 组件 | 切换前 | 切换后 |
|---|---|---|
| torch | 2.12.1+cu126 | **2.11.0+cu128** |
| torchvision | 0.27.1+cu126 | **0.26.0+cu128** |
| triton | 3.7.1 | **3.6.0** |
| CUDA 组件 | 12.6.x | **12.8.1**（`cuda-toolkit` 元包） |

三个必须知道的细节：

1. **`2.12.1+cu128` 不存在** —— cu128 分支最高到 `2.11.0`（镜像 404、官方 403）。这是**降级**换 GPU 可用性。
2. **uv 无法从 `download.pytorch.org` 解析** —— 那不是标准 PEP 503 索引。脚本用 `curl` 下轮子再本地安装。
3. **CUDA 12.8 组件不是可选项** —— torch 的 reduction 内核走**运行时 nvrtc JIT**，nvrtc 12.6 不认识 `-arch=sm_120`，会报：
   ```
   nvrtc: error: invalid value for --gpu-architecture (-arch)
   ```
   这个错误**只在推理时才暴露**（`import torch` 和简单 matmul 都正常），表现为 SAM3 分割返回 HTTP 500。注意包版本号不等于 CUDA 版本（`cufft 11.3.x`、`curand 10.3.x` 都是 12.8 构建），所以要装 `cuda-toolkit` 元包让它解析整套。

**警告**：`uv sync --frozen` 会把 torch 装回 cu126，**撤销这个切换**。每次 sync 之后都要重跑一次。

## SAM3 权重：用本地文件，别走 HuggingFace

`facebook/sam3` 是 gated 模型。上游 `launch_sam3_server.py` 调用 `build_sam3_image_model(enable_inst_interactivity=True)`，内部走 `load_from_HF=True`，会尝试下载。

`patches/aspire-sam3-local-checkpoint.patch` 加了本地权重支持，优先级：

```
--checkpoint-path  >  $SAM3_CHECKPOINT  >  HuggingFace 下载（上游行为）
```

```bash
export SAM3_CHECKPOINT=/path/to/sam3.pt
bash scripts/common/start_perception_servers.sh --gpu-sam3 0 --gpu-graspnet 0 --no-molmo
```

**只需要权重文件**，不需要 `config.json`：`_load_checkpoint` 只做 `torch.load` 并筛选 `detector.` / `tracker.` 前缀的键，模型架构由代码构造。BPE tokenizer 已打包在 `sam3/assets/` 里。

**SAM 3.0 与 3.1 不通用**：3.1 的 Object Multiplex 是**视频**特性，`build_sam3_image_model` 没有 `version` 参数（硬编码 `version="sam3"`）。两者 detector 键集也不同（共有 1130，各独有 26 / 36，3.1 多出 `backbone.vision_backbone.interactive_convs.*`）。用 3.1 的权重喂图像路径不会报错（`strict=False`），但会静默跳过对不上的键。

## 单卡也能跑感知栈

ASPIRE 的参考拓扑是 8 卡（0=SAM3、1=GraspNet、2=PyRoKi、3–7=任务槽），但这只是**并发上限**，不是硬性要求。单卡共享可行：

```bash
bash scripts/common/start_perception_servers.sh --gpu-sam3 0 --gpu-graspnet 0 --no-molmo
```

实测占用：SAM3 3.9 GB + GraspNet 380 MB，72 GB 卡上余量充足。

## 镜像加速（国内环境）

实测（阿里云 DSW，804MB 的 torch cu126 轮子）：

| 来源 | 耗时 | 速度 |
|---|---|---|
| PyPI | ~23 分钟 | 0.58 MB/s |
| mirrors.aliyun.com | **42.7 秒** | **19.7 MB/s** |

镜像文件与 PyPI 字节相同（已验证 sha256 一致），所以改写 URL 后 `uv.lock` 的完整性校验依然通过。

`scripts/use_mirror.sh` 会改写 `uv.lock` 中的**三类** URL：

1. wheel/sdist 文件 URL（`files.pythonhosted.org`）
2. PyTorch CUDA 索引（`download.pytorch.org`、`download-r2.pytorch.org`）
3. **registry 声明**（`pypi.org/simple`）—— 容易漏，漏了 uv 仍会去 PyPI 查索引

原文件备份为 `uv.lock.orig`，`bash scripts/use_mirror.sh restore` 可还原。

**已知缺口**：构建时依赖（如 `egl-probe` 需要的 `cmake`）是运行时解析的，**不走 `uv.lock`**。脚本通过 `UV_DEFAULT_INDEX` 覆盖，需要时手动导出：

```bash
export UV_DEFAULT_INDEX=https://mirrors.aliyun.com/pypi/simple/
export UV_INDEX_STRATEGY=unsafe-best-match
```

## 离屏渲染：EGL 与 OSMesa

MuJoCo 需要无头 GL 后端。ASPIRE 默认用 EGL（走 GPU，快），但**很多容器镜像不支持**——典型报错：

```
ImportError: Cannot initialize a EGL device display. This likely means that your
EGL driver does not support the PLATFORM_DEVICE extension...
```

已确认的一个例子是阿里云 DSW 容器：NVIDIA 设备节点（`/dev/nvidia0` 等）齐全，但 `/usr/share/glvnd/egl_vendor.d/` 目录**整个不存在**，且**缺 `/dev/dri`**，导致 EGL 无法枚举设备。

**OSMesa 兜底**：纯 CPU 软件渲染，装 `libosmesa6` 即可用，兼容性极好，代价是速度。`setup_aspire_env.sh` 会先测 EGL，失败则自动切 OSMesa 并报告结果。

```bash
MUJOCO_GL=osmesa bash scripts/setup_aspire_env.sh   # 强制走软件渲染
```

**注意**：OSMesa 做小规模调试没问题，但大量渲染（如 LIBERO-Pro 完整评测）性能会明显受限。要上 GPU 渲染需要用带完整 EGL 配置的镜像。

## 环境要求（已验证配置）

ASPIRE 的 CUDA 路径要求比 ENPIRE 严格，两者取并集：

| 项 | 要求 | 说明 |
|---|---|---|
| 系统 | Ubuntu 22.04 | glibc 2.35，兼容性最保守 |
| CUDA toolkit | **12.8**（必须有 nvcc） | cuRobo v0.7.8 编译必需；仅装驱动不够 |
| 驱动 | ≥ 570（580 已验证） | 支持 CUDA 12.8+ |
| Python | 3.10 / 3.12（ASPIRE）、3.11（ENPIRE） | 由 `uv` 管理，无需系统预装 |
| GPU | 支持 sm_120 的 Blackwell 卡 | RTX PRO 5000 72G 已验证 |
| 磁盘 | ≥ 100G 可用 | 子模块 3.7G + venv 约 8-20G + uv 缓存 |

**注意**：不要安装 `cuda` 或 `cuda-drivers` 元包，只装 `cuda-toolkit-12-8`——否则会尝试替换显卡驱动。

### 与 ENPIRE 的差异

两个仓库的 cuRobo 版本不同，对 CUDA 的要求也不同：

| | ASPIRE | ENPIRE |
|---|---|---|
| cuRobo | v0.7.8 | v0.8.0 |
| 工具链来源 | torch `CUDAExtension` → 需 `CUDA_HOME` | wheel 内含 `nvidia-cuda-nvcc-cu12` |
| 系统 CUDA toolkit | **必需** | 不需要（仅需驱动） |
| torch 索引 | `pytorch-cu126` | `pytorch-cu128` |

CUDA 12.8 对两者都兼容。

## 已知坑（脚本已处理）

1. **7 个子模块必须全部拉取** —— `uv` 在解析阶段即评估整个 workspace，任一子模块为空则**所有** `uv` 命令失败，与 extras 无关，`--no-install-package` 也无效。
2. **cuRobo 版本号** —— 上游用 setuptools-scm 从 git tag 推导版本，浅克隆丢 tag，且 `uv` 隔离构建环境看不到 `.git`，导致版本对不上 `uv.lock`。见 `patches/`。
3. **`std::lerp` 冲突** —— cuRobo 的 `helper_math.h` 定义全局 `lerp`，与 gcc 13 在 C++20 下的 `std::lerp` 冲突（gcc 11 不受影响）。见 `patches/`。
4. **用 `--frozen` 而非 `--locked`** —— 补丁改变元数据后 `uv.lock` 校验会失败；`--frozen` 直接采用锁文件中的版本。
5. **nvidia 库半损坏** —— `uv sync` 后个别 `nvidia-*-cu12` 包可能出现「dist-info 存在但 `.so` 缺失」，需 `--force-reinstall` 补装。
6. **LIBERO 首次运行交互提示** —— 会询问数据集路径并写 `~/.libero/config.yaml`，在非交互环境（CI/pytest）下需预先用 `echo N | python3 -c "import libero"` 生成。
7. **容器内 EGL 不可用** —— 见下节；脚本会自动退回 OSMesa。
8. **`uv.lock` 的 registry 声明容易被漏改** —— 只改 wheel 的 URL 不够，uv 仍会去 PyPI 查索引，表现为卡住不动。

## 状态

| 项目 | 环境 | 冒烟测试 | 渲染后端 | GPU |
|---|---|---|---|---|
| ASPIRE（本地，Ubuntu 24.04 + RTX 5070 Ti） | ✅ | ✅ | EGL | ✅ sm_120 |
| ASPIRE（阿里云 DSW，Ubuntu 22.04 + RTX PRO 5000） | ✅ | ✅ | OSMesa | ✅ sm_120（cu128） |
| ENPIRE | ⏳ 未开始 | — | — | — |
| Dream-RSI | — | — | — | 上游无代码可复现 |

已验证的服务器组件（阿里云 DSW，单卡 RTX PRO 5000 72GB）：

| 组件 | 状态 |
|---|---|
| torch 2.11.0+cu128 / CUDA 12.8.1 | ✅ |
| cuRobo 0.7.8（sm_120 编译） | ✅ |
| SAM3 服务（本地权重） | ✅ 推理通过，3.9 GB 显存 |
| GraspNet 服务 | ✅ UP，380 MB 显存 |
| PyRoKi 服务 | ✅ UP（CPU） |
| LLM Gateway | ✅ 已验证，尚未接入 ASPIRE |

## 参考

调研笔记见 [`docs/RSI_RESEARCH.md`](docs/RSI_RESEARCH.md)。
