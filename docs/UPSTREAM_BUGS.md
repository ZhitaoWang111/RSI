# 上游代码问题记录

记录在复现过程中发现的、**属于上游代码本身**（不是我们环境适配引入）的问题。每条都给出证据位置、影响范围，以及我们的处置方式。

---

## BUG-1：dev 与 held-out seed 划分在数据层面不成立

**发现时间**：2026-10-20
**严重性**：高（影响实验结果的可解释性，不影响能否跑通）
**状态**：上游未修；我们改用不相交划分绕开

### 作者的设计意图

`.claude/libero/fix-loop/QUICKSTART.md`：

```
DEVELOPMENT_SEEDS=51-65
HELD_OUT_SEEDS=1-50
```

`.claude/libero/fix-loop/INSTRUCTIONS.md` 与 `main-agent-prompt.md` 多处强调两者必须严格分离：Stage 1 的 worker 只用 51–65 调试、不得读取验收结果；Stage 2 由 coordinator 在 1–50 上验收，且 "Only Stage 1 evidence may drive skill edits"。

这是标准的 train/test 分离设计：用 15 个场景调代码，用 50 个没见过的场景验证泛化。

### 实际实现

`cap/envs/simulators/libero.py:155-172`：

```python
def reset(self, *, seed=None, options=None):
    ...
    if self.handle.init_states is not None and len(self.handle.init_states) > 0:
        if seed is not None:
            # Assuming seed is the trial number (1-based)
            state_idx = (seed - 1) % len(self.handle.init_states)
            self.handle.env.set_init_state(self.handle.init_states[state_idx])
```

trial 号直接当 seed 传入（`cap/envs/trial.py:658`）：

```python
obs, _ = env.reset(options={"trial": trial}, seed=trial)
```

### 数据规模

`libero_goal_swap` 每个 task 的 `.pruned_init` 文件含 **50** 个 init states（实测：`open_the_middle_drawer_of_the_cabinet.pruned_init -> 50`）。其余 LIBERO suite 同为 50。

### 后果

取模 50 导致：

| trial 区间 | 实际 init state |
|---|---|
| 1–50 | 0–49，各一次 |
| **51–65** | **0–14** |
| 66–80 | 15–29（回绕继续） |

**开发集 51–65 对应的正是验收集 1–50 的前 15 个**。作者要求的"严格分离"在数据层面完全不存在。

所以按 runbook 跑完得到的 "held-out 成功率"，实际是在开发时已经反复看过的 15 个场景上测的。**这个数字不具备泛化意义**。

### 附带问题：`resume_idx` + `total_trials` 的空集

`cap/envs/runner.py:153-154`：

```python
trial_ids = list(range(1, config["total_trials"] + 1))
if config.get("resume_idx") is not None:
    trial_ids = list(range(config["resume_idx"], config["total_trials"] + 1))
```

`resume_idx` 是**绝对上界**语义，不是"要跑多少个"。配置文件 `franka_libero_baseline_debug.yaml` 写 `resume_idx: 51`，若再传 `--total-trials 1`：

```python
range(51, 2)   # 空列表
```

一个 trial 都不跑。而 `_run_headless_trials` 在空集时仍会写 `aaa_done_flag` 并打印 "Batch execution completed successfully"——外层无法区分"跑完了"和"什么都没跑"。

**另外**：`run_libero_batch.py:118-122` 会用 init states 数量覆盖 `config["trials"]`（通常为 50），所以 YAML 里的 `trials: 100` 在 batch 路径下不生效；同一段代码还把 `max_steps` 改为 8000、`enable_render` 改为 True，均覆盖 YAML 中的值。

### 我们的处置：改用不相交划分

在现有 50 个 init state 内做出真正分离的划分：

| 用途 | trial / seed | init state |
|---|---|---|
| 开发（Stage 1 调试） | **1–15** | 0–14 |
| 验收（Stage 2 held-out） | **16–50** | 15–49 |

两组完全不重叠，且都在合法范围内，**无需改代码**，只改运行参数：

- 开发：`resume_idx: 1` + `--total-trials 15`
- 验收：`resume_idx: 16` + `--total-trials 50`

代价：与上游 runbook 的 seed 编号不一致（上游写 51–65 / 1–50）。复现报告里必须标注这一点，否则会被误认为遵循了原协议。

### 如果要真正复现作者的意图

需要扩展 init state 数据集到至少 65 个（或让 51–65 指向独立的 15 个场景），然后修正取模逻辑。这超出"把方法跑起来"的范围，未做。

---

## 其他（非 bug，但影响复现）

- `cap/llm/client.py:256-265` 的重试循环没有次数上限，`retry` 变量只用于打印。网关持续返回 5xx 时会每 2 分钟无限重试。
- `TRIAL_TIMEOUT_SECONDS = 1000` 的超时用 `cancel.wait()` 实现，杀不掉正在执行的 C 扩展；代码注释自承 "real wall-clock duration can exceed timeout_s"。
- `num_workers: 8` 的默认配置假设多卡拓扑，单卡下 8 个 worker 共享同一套感知服务会线性劣化。
