# 环境运维经验记录

记录时间：2026-10-19 / 2026-10-20。本文只记录**实际踩过的坑和验证过的处理办法**，不是操作手册。可复现的步骤在 `scripts/`，产品化的说明在 `README.md`；这里写的是那些"脚本没写、下次还会遇到"的东西。

验证环境：阿里云 DSW 容器，Ubuntu 22.04，gcc 11.4，CUDA 12.8，RTX PRO 5000 72GB（sm_120），Python 3.12。工作目录在 CPFS 网络存储 `/mnt/data/usr/wzt/`（与系统盘 `/mnt/workspace` 分属不同文件系统）。

---

## 1. CPFS 上大批小文件是灾难

### 现象

一次完整迁移（16G / 87,016 个文件，其中 57,426 个 <10KB，绝大部分是 venv）碰到三种症状：

| 操作 | 症状 |
|---|---|
| `tar` 管道复制 | 30 分钟后仍在跑，之后 `du`、`find` 开始超时 |
| 前台 `rsync` | **服务器根本没装 rsync**（`rsync: 未找到命令`），脚本静默继续 |
| `rm -rf` 目标目录 | 进程进入 **D 状态**（不可中断睡眠），持续 19 分钟，`kill -9` 无效 |

D 状态的两个 `rm` 持有目标目录的内核锁，导致该路径下所有操作挂起，但**同一 CPFS 的其他路径完全正常**——实测新建目录大文件写 479 MB/s，小文件 24ms/个。所以这不是存储故障，是特定目录上的客户端死锁。

### 处理

1. **换路径，不要等**。D 状态进程无法终止，只能等 I/O 自己完成或重启容器。当时改写到 `/mnt/data/usr/wzt/RSI_new`，几分钟内就能继续；等原目录解锁后再删。
2. **复制用 `tar` 管道**，跨文件系统也保权限/软链：
   ```bash
   cd "$SRC" && tar -cf - . | (cd "$DST" && tar -xpf -)
   ```
3. **不要在 CPFS 上反复 `du` / `find` 做进度探测**。查询本身会加重元数据压力，越查越慢。用 `pgrep` 判进程存活即可。
4. **venv 不要跨盘搬**。它可重建，且里面有写死的绝对路径（`pyvenv.cfg`、console script 的 shebang），搬过去也要修。只搬代码，venv 重建更省时间。

### 实测数字

| 项 | 数值 |
|---|---|
| 代码部分复制（排除 venv，5.9G） | **26.7 分钟** |
| 单文件 783MB 轮子写入 | 1.77s/GB 级顺序写（608 MB/s），但解压成小文件后极慢 |
| `uv pip` 装 torch 轮子（卸载+安装） | 2m20s + **15m33s** |

---

## 2. `uv sync` 被打断会留下半损坏的 torch

### 现象

两次 `uv sync --frozen` 被中途杀掉（一次被 `pkill` 自匹配误杀，一次前台超时）。之后：

```
site-packages/torch/          31M，只有 contrib/ include/ library.py，
                              没有 __init__.py、version.py
torch-2.12.1+cu126.dist-info/ 仍在
```

于是 `import torch` 不报 ModuleNotFoundError，而是拿到一个残缺模块：

```
AttributeError: module 'torch' has no attribute '__version__'
ModuleNotFoundError: No module named 'torch.utils'
```

**这个错误会伪装成别的问题**：cuRobo 构建时报 `No module named 'torch.utils'`，提示信息还建议"把 torch.utils 加进 build-system.requires"——完全误导。

### 处理

从 uv 的 wheel 缓存强制重装，不要走网络：

```bash
uv pip install --python "$V/bin/python3" --no-deps --force-reinstall \
  /root/.cache/uv/wheel-downloads/torch-2.11.0+cu128-cp312-cp312-manylinux_2_28_x86_64.whl \
  /root/.cache/uv/wheel-downloads/torchvision-0.26.0+cu128-cp312-cp312-manylinux_2_28_x86_64.whl
```

### 判断方法

发现"某个包 import 出奇怪的 AttributeError"，先看目录大小对不对：

```bash
du -sh $V/lib/python3.12/site-packages/torch    # 正常约 2.5G，31M 就是坏了
ls $V/lib/python3.12/site-packages/torch/__init__.py
```

---

## 3. cuRobo 与 torch 版本的 C++ 标准冲突

### 现象

`uv sync --extra curobo` 在隔离环境编译 cuRobo 时报：

```
torch/csrc/api/include/torch/all.h:5:2: error: #error C++20 or later compatible compiler is required to use PyTorch.
```

原因链：

- `uv.lock` 钉的是 **torch 2.12.1**，它要求 C++20 头文件
- `patches/curobo-0.7.8-build-fixes.patch` 把 cuRobo 压到 **`-std=c++17`**，因为 `helper_math.h` 定义了全局 `lerp`，与 gcc 13 在 C++20 下的 `std::lerp` 冲突
- venv 里实际是 **torch 2.11.0+cu128**，它只要求 **C++17**（`all.h` 里写的是 "C++17 or later"）

而 `uv sync` 的构建隔离环境总是按锁文件装 torch 2.12 —— 与运行时 venv 不一致。

### 处理

用 `--no-build-isolation`，让构建过程用 venv 里的 torch 2.11：

```bash
uv sync --frozen --active --extra libero --extra dev --extra curobo --no-build-isolation
```

但见下一节——这条路在这台机器上会挂。

### 补充观察

在 gcc 11.4 上实测 `std::lerp` **是可用的**（`g++ -std=c++20` 能编过 `std::lerp(0.0,1.0,0.5)`）。所以 `-std=c++17` 这个补丁主要是为 gcc 13 准备的；在 gcc 11 上保留它没有副作用，也正好满足 torch 2.11 的要求。如果将来换成 torch 2.12+，需要重新评估：要么去掉 c++17 补丁并解决 `lerp` 冲突，要么让 cuRobo 与锁文件解耦。

---

## 4. `uv sync --no-build-isolation` 会静默挂死

### 现象

```
uv sync --frozen --extra libero --extra dev --extra curobo --no-build-isolation
```

进程 18 分钟无 CPU 占用（0.2%）、无子进程、日志无输出。诊断：

```
State:  S (sleeping)
Threads: 18
wchan:  futex_wait_queue_me
```

不是在编译，是在等锁。原因未彻底确认（可能是 uv 解析与 CPFS 上的 `.pth`/editable 状态冲突）。

### 处理

别跟它耗。直接绕开 `uv sync`，分两步：

```bash
# 1. 只编译扩展，不注册包
cd cap/third_party/curobo
MAX_JOBS=8 "$V/bin/python" setup.py build_ext --inplace

# 2. 用 .pth 把源码目录加进 sys.path
echo "$SIM/cap/third_party/curobo/src" > "$V/lib/python3.12/site-packages/curobo_editable.pth"
```

`setup.py develop` 和 `uv pip install -e` 都会失败（前者内部调 `pip install -e . --use-pep517`，同样触发 C++ 标准问题），`.pth` 是最省事的路子。

### 前提

cuRobo 的编译依赖要单独装，venv 里可能没有 `ninja`：

```bash
uv pip install --python "$V/bin/python3" --index-url https://mirrors.aliyun.com/pypi/simple ninja
```

---

## 5. 装 torch 会把 nvrtc 拉回旧版本

### 现象

重装 torch 2.11.0+cu128 之后，`import curobo` 和 CUDA 扩展都正常，但第一次真正调 cuRobo（`RobotConfig.from_dict` → `normalize_quaternion`）就炸：

```
RuntimeError: nvrtc: error: invalid value for --gpu-architecture (-arch)
```

检查发现 `libnvrtc-builtins.so.12.6` —— torch 的依赖约束把 `nvidia-cuda-nvrtc-cu12` 覆盖回了 12.6，而 12.6 不认识 `sm_120`。

### 处理

重装 CUDA 12.8 组件（不要带 `torch`）：

```bash
uv pip install --python "$V/bin/python3" \
  --index-url https://mirrors.aliyun.com/pypi/simple --index-strategy unsafe-best-match \
  "cuda-toolkit[cublas,cudart,cufft,cufile,cupti,curand,cusolver,cusparse,nvjitlink,nvrtc,nvtx]==12.8.1" \
  "cuda-bindings<13,>=12.9.4"
```

装完应看到 `libnvrtc-builtins.so.12.8`。

### 要点

这个错**只在推理时暴露**。`import torch`、`torch.randn().sum()`、`matmul` 全都正常，唯独走 nvrtc JIT 的路径会挂。所以冒烟测试必须覆盖真实调用（如 cuRobo IK），不能只测 import。

---

## 6. cuRobo 不在 `libero` / `dev` extras 里

`pyproject.toml` 里 cuRobo 是独立 extra：

```toml
curobo = ["nvidia-curobo"]
nvidia-curobo = { path = "cap/third_party/curobo", editable = true }
```

`scripts/setup_aspire_env.sh` 只装 `--extra libero --extra dev`，所以跑完脚本后 `import curobo` 仍是 `ModuleNotFoundError`。这不是脚本 bug（感知栈和 LIBERO 冒烟都不需要 cuRobo），但如果要用运动规划就得补装。

---

## 7. 服务器上的 git

| 问题 | 处理 |
|---|---|
| `git@github.com: Permission denied (publickey)` | 服务器没配 GitHub SSH key；remote 换成 HTTPS |
| `fatal: 无法读取远程仓库` 但 `ls-remote` 成功 | 同样是 SSH key 问题，别被 "无法读取" 误导 |
| `dubious ownership` | `git config --global --add safe.directory <path>` |
| TLS 不稳定（`GnuTLS recv error (-110)`、`HTTP/2 stream was not closed cleanly`） | 隔一段时间重试；必要时从本地打包 `.git` 用 scp 覆盖 |

注意：`git fetch` 失败时如果接了管道（`git fetch | tail`），`$?` 拿到的是 `tail` 的返回码，会误判成功。用 `${PIPESTATUS[0]}`。

---

## 8. `pkill -f` / `pgrep -f` 会匹配到自己

### 现象

```bash
ssh server 'pkill -f "uv sync"'      # 连接被切断，exit 255
ssh server 'pgrep -f copy_new.sh >/dev/null && echo RUNNING'
```

后者在脚本明明已结束时仍打印 `RUNNING`——因为 `pgrep -f` 匹配到了 `ssh` 会话里那条**包含 `copy_new.sh` 字样的命令行**。

### 处理

- 杀进程用 **PID**，不用 pattern
- 判断存活时，让 pattern 不出现在自己的命令行里：`pgrep -f "[c]opy_new.sh"`，或直接 `ps -eo pid,stat,cmd | grep "[t]ar -c"`

---

## 9. 这份环境里 EGL 是可用的

早期在同一个容器里记录过 EGL 不可用（缺 `/usr/share/glvnd/egl_vendor.d` 和 `/dev/dri`），当时的结论是只能用 OSMesa。2026-10-19 重建环境后 `setup_aspire_env.sh` 自动探测**通过了 EGL**，LIBERO 冒烟 39.7s；此前 OSMesa 下同样的测试是 161.5s。

说明容器镜像/驱动配置有变化，或者当时探测的是不同节点。`setup_aspire_env.sh` 的自动探测逻辑是对的，**不要硬编码 `MUJOCO_GL`**。

---

## 10. 重建一次环境的实际耗时（供估算）

| 阶段 | 耗时 |
|---|---|
| `uv sync --frozen`（226 包装完） | 约 12 分钟（镜像解析只有 12s，其余是 CPFS 跨盘复制） |
| 切 cu128（torch 卸载 + 安装） | 约 20 分钟 |
| cuRobo 编译（`build_ext --inplace`，8 并行） | 约 10 分钟 |
| CUDA 12.8 组件补装 | 约 6 分钟 |
| 合计（不含代码复制） | **约 45-50 分钟** |

镜像加速确实有效：226 个包解析只用 12.27s；瓶颈全在 CPFS 的写入/删除，不在网络。

---

## 11. 一条硬约束（重复强调）

`uv sync --frozen` **每次都会**：

1. 把 torch 装回锁文件的 2.12.1+cu126 → sm_120 上 GPU 不可用
2. 把 nvrtc 拉回 12.6 → cuRobo/推理 JIT 失败
3. 可能把 cuRobo 的 `.so` 删掉

所以对这个 venv 而言，`uv sync` 不是幂等的「同步到干净状态」，而是「同步到不可用状态」。用完必须重跑 `switch_cu128_blackwell.sh` + CUDA 组件补装 + 必要时重编 cuRobo。

---

## 12. `~/.libero/config.yaml` 存的是绝对路径，搬目录后不会自动更新

### 现象

迁移到 `/mnt/data/usr/wzt/RSI` 之后跑 batch，日志里仍然出现旧路径：

```
[Warning]: datasets path /mnt/workspace/wzt/RSI/third_party/ASPIRE/... does not exist!
```

**而且不会报错**——因为旧目录还在，LIBERO 就从旧树里加载资产。这时新代码配旧资产，行为难以解释，且删掉旧目录后会突然失败。

### 原因

`setup_aspire_env.sh` 只在配置文件不存在时才生成它：

```bash
if [ -f "$HOME/.libero/config.yaml" ]; then
  echo "  already exists"
else
  echo "N" | "$VENV/bin/python3" -c "import libero" >/dev/null
fi
```

文件里存的是全绝对路径（`assets`、`bddl_files`、`benchmark_root`、`datasets`、`init_states`），换目录后必须手动改写。

### 处理

```bash
NEW=/mnt/data/usr/wzt/RSI/Submodule/ASPIRE/aspire/sim/cap/third_party/LIBERO-PRO/libero/libero
OLD=/mnt/workspace/wzt/RSI/third_party/ASPIRE/aspire/sim/cap/third_party/LIBERO-PRO/libero/libero
sed -i "s|$OLD|$NEW|g" ~/.libero/config.yaml
```

**迁移后应该直接删掉这个文件让它重新生成**，比改路径更稳妥。

### 附带确认

`datasets` 指向的目录本来就不存在（LIBERO 用它做演示数据增强），运行时会打印 warning，不影响 init states 加载——init states 来自 `init_files/`，这个目录是有的。
