# RSI 主线与机器人方向：第一轮文献调研

调研日期：2026-10-13。RSI 指 Recursive Self-Improvement（递归自我改进）。本文基于仓库 `papers/Dream-RSI.pdf`、实时访问的 arXiv 摘要/版本记录，以及部分论文 HTML 正文。数值均为作者报告，未在本机复现；这是一轮选题与阅读导航，不是系统性文献综述。近期预印本的结论、代码发布状态可能继续变化。

## 1. 先明确研究边界

RSI 的核心问题是：**系统能否利用自身运行的证据，持续改进下一轮解决问题和实施改进的能力？**

建议用三个层次读文献，这是本调研的分析框架，不是领域统一定义：

1. **任务层自改进**：改答案、策略、奖励、技能、记忆或工具。下一轮任务表现更好，但改进程序可以一直固定。
2. **机制层递归改进**：不仅改任务系统，还改分析失败、提出修复、分配预算、选择搜索分支的机制。系统改进“如何改进”。
3. **更强的开放式 RSI**：跨任务持续积累、改进能力可迁移、效率或能力随多轮提升。有限任务上的多轮上涨不足以证明无限自加速。

因此，自训练、自博弈、持续学习、test-time adaptation、反思重试都与 RSI 有交集，却不能直接等同于机制层 RSI。模型权重冻结也不意味着没有系统级自改进：代码、harness、技能和搜索策略都可能是可变对象。不同作者采用的 RSI 定义宽窄不同，例如 STOP 自己就明确说明其冻结 LM 的设置不是 full RSI。

阅读时始终问：**改什么？谁来改？反馈从哪里来？改动是否跨 episode 保留？改进器本身是否可变？如何证明改善不是评测过拟合？**

## 2. Dream-RSI 在主线中的位置

本地文章的闭环是：在线探索 → 保存发现树 → 构造 replay simulator → 离线评估和改进探索策略 → 重新上线 → 扩充历史。

- 改进对象是探索控制器，而底层 coding agent 保持不变。
- 关键是把昂贵、延迟的“搜索策略好不好”反馈，转为历史搜索空间上的廉价回放反馈。
- 它的 simulator 是发现历史上的回放器，不是机器人动力学仿真器，也不等同于可预测任意动作后果的 learned world model。
- 本地文章展示算法工程、数学优化和 GPU kernel 工程；不能据此声称已验证机器人 RSI。
- 迁移到机器人时，值得研究的是搜索预算、修复候选选择和技能探索调度；历史回放无法直接证明未执行动作在真实物理世界中的效果。

[论文及当前版本](https://arxiv.org/abs/2609.14858) · [代码链接（本地 PDF 提供）](https://github.com/zhengkid/Dream-RSI)。在线 v2 摘要写作“9 tasks in 4 domains”，与本地摘要表述不同；后续精读需先固定版本，本文对本地内容与在线信息分别表述。

## 3. RSI 主线：优先推荐

年份按首次公开年份或表中注明的会议年份理解，避免将预印本年份与会议年份混用。

| 优先级 | 工作 | 改进对象与机制 | 推荐理由和证据边界 |
|---|---|---|---|
| P0 | [STOP: Self-Taught Optimizer](https://arxiv.org/abs/2310.02304)，2023 / COLM 2024 | 一个调用 LM 改程序的 improver，进一步用自己改进自己 | 最清晰的递归起点：看“改进器优化改进器”；实验任务规模有限，LM 本身不变 |
| P0 | [Darwin Gödel Machine（DGM）](https://arxiv.org/abs/2505.22954)，2025 | agent 修改自身代码；保留多样 agent archive，以经验评测接受变化 | 现代可执行自改进主线；重点读自修改、档案和开放式探索，主要证据来自 coding benchmark |
| P0 | [Hyperagents](https://arxiv.org/abs/2603.19461)，2026 | task agent 与 meta agent 组成可编辑程序，meta-level 修改程序也可编辑 | 明确解决“改进器固定”的问题；包括机器人奖励设计实验，是通用 RSI 与机器人之间的重要桥梁，非真机闭环证据 |
| P0 | [EvoX: Meta-Evolution for Automated Discovery](https://arxiv.org/abs/2602.23413)，2026 | 候选解和生成候选解的搜索策略共同演化 | Dream-RSI 的直接近邻；重点对比在线策略演化与历史回放评估的成本和反馈偏差 |
| 已有 / P0 | [Dream-RSI](https://arxiv.org/abs/2609.14858)，2026 | 历史发现树驱动探索策略回放优化 | 研究如何低成本改进改进机制；需关注已实现搜索空间对回放评估的限制 |
| P1 | [Meta-Harness](https://arxiv.org/abs/2603.28052)，2026 | outer-loop 搜索 harness 代码，访问过去候选的代码、得分和执行轨迹 | 适合了解无需改权重的系统优化；优化 harness 不自动等于改进器本身递归变化 |
| P1 | [MetaSkill-Evolve](https://arxiv.org/abs/2607.05297)，2026 | task skill 快循环，分析/检索/分配/提案/演化的 meta-skill 慢循环 | 技能路线的机制层 RSI；ALFWorld 是交互任务环境，不是真实机械臂证据 |
| P1 | [Meta^n: Recursive Self-Improvement through Emergent Depth](https://arxiv.org/abs/2608.24735)，2026 | 固定 meta-operation，对不断增加的 solver stack 与轨迹递归应用，形成更深层次 | 与“直接修改 meta agent”形成有用对照；应区分层次增长和改进程序本身变化 |
| P1 | [AlphaEvolve](https://arxiv.org/abs/2506.13131)，2025 | LLM 提案、程序评测、进化数据库迭代改进算法 | 理解 discovery loop 的基础；改进目标算法及计算设施，不等于完整自改进机制都可变 |

补充背景：

- [Gödel Machines](https://arxiv.org/abs/cs/0309048)，2003 起：通过证明自修改有益再改代码，是理论起点。先了解动机和证明前提，不必作为第一篇实现论文。
- [A Survey of Agentic Reasoning for Large Language Models: Towards Recursively Self-Improving and Collective Agents](https://arxiv.org/abs/2601.12538)，2026，arXiv 注明 accepted by TMLR：提供 agentic reasoning、自演化和多 agent 的大图景，并非只讲 RSI。
- [Recursive Harness Self-Improvement](https://arxiv.org/abs/2607.15524)，2026：通过版本历史的成对反馈修订 prompt-level harness。含机器人主题的合成 ML 研究任务，但不能当作实体机器人实验。
- Dream-RSI 引用的 *The Path to Recursive Self-Improving Agents: Foundation, Framework, and Future Directions*，[DOI](https://doi.org/10.20944/preprints202608.0051.v1) 本次访问返回 403；尚未核实正文，不作为核心推荐依据。

## 4. 机器人方向：最值得优先读的工作

这些工作的成功率来自不同任务、种子、训练预算和聚合方式，不应横向排序。

| 优先级 | 工作 | 自改进闭环 / 改进对象 | 实验证据与阅读重点 |
|---|---|---|---|
| P0 | [RHO: Your Coding Agent is Secretly a Roboticist](https://arxiv.org/abs/2606.16458)，2026-06 | coding agent 在开发阶段搜索整个多文件 policy repository，利用 reward、traceback 和视觉反馈修订代码 | LIBERO-Pro、Robosuite、RAI/O3DE；正文明确全部 benchmark 为仿真。看 Repositories-as-Policies 如何把测试时调试移到开发阶段；它首先是策略仓优化，不必强称 meta-level RSI |
| P0 | [ASPIRE: Agentic /Skills Discovery for Robotics](https://arxiv.org/abs/2607.00272)，2026-06 首次提交 | 执行 → 多模态失败诊断 → 程序修复 → 验证 → 将修复沉淀为技能；进化搜索探索任务序列和程序 | LIBERO-Pro、Robosuite、BEHAVIOR-1K，以及选定技能的 sim-to-real。看能力如何跨任务积累；正文承认尚非完全自主的真机终身学习系统，底层 API 仍限制表达能力 |
| P0 | [ENPIRE: Agentic Robot Policy Self-Improvement in the Real World](https://arxiv.org/abs/2606.19980)，2026-06 / CoRL 2026 | 自动重置与验证、策略训练、物理 rollout、coding agent 修改训练基础设施及算法组成闭环 | 直接真机证据，涵盖灵巧操作和多机器人并行。优先看如何让物理实验可重复，而不只看摘要的 99%；自动重置/验证设施是关键工程前提 |
| P0 | [PhysEvo: Astra Can Act, Let It](https://arxiv.org/abs/2610.08995)，2026-10 | 冻结模型，task agent 执行；meta agent 修改工具和技能，也可修改自己的诊断工具 | 42 个 RoboDojo 任务；另有 AgileX PiPER 5 项真机任务、25 次 trial，报告 84% success。最贴近机制层 physical RSI；真机样本有限，且仿真版本按任务保留，不能当成一个统一通用策略 |
| P0 | [What Stops Recursive Self-Improvement in Robotics? Lessons from 123 Rounds of Agentic Skill Discovery](https://arxiv.org/abs/2609.31760)，2026-09，technical report | 失败驱动技能代码修订、外部模型发现与安装，在仿真中验证变化 | 123 轮后目标长任务仍未成功。必读反面证据：关系感知不足、早期失败遮蔽后续技能、评测和记忆误导优化；“修改通过测试”不代表端到端能力累积 |
| P1 | [EmbodiRSI: Recursive Self-Improvement for Data-Efficient Robot Adaptation](https://arxiv.org/abs/2609.38905)，2026-09 | real-to-sim-to-real；失败状态的纠错续接轨迹 + 针对弱点的自适应示范收集 → 策略更新 → 再评测 | 3 个桌面场景、14 个子任务，2 次 RSI 更新；作者报告仿真 50.4%→83.5%，真机 83.1%。看采集分布如何响应策略弱点；正文将 held-out workspace 与更长改进运行列为未来工作 |
| P1 | [Embodied Turing Machines: Stateful Code for Robot Recursive Self-Improvement](https://arxiv.org/abs/2610.12369)，2026-10，technical report | Code-Only-as-Policy（COAP），显式状态与共享代码库由 coding agent 闭环开发；执行时无 VLM/VLA 决策调用 | 42 项 RoboDojo 双臂任务，报告 70.24%。正文明确仅仿真，感知利用 benchmark 公共配置和资产；重点看代码库复用、状态表示、分支开发和回归 |
| P1 | [EmbodiedSmith](https://arxiv.org/abs/2610.07969)，2026-10 | 资产、场景和任务生成；场景与任务相互反馈修订，生成仿真训练数据 | 适合研究可演化环境和机器人数据基础设施。闭环主要改生成场景/任务，不宜直接理解成机器人控制器改进自身改进器 |
| P2 | [EndoRSI](https://arxiv.org/abs/2610.13376)，2026-10 | coding agent 用真实内窥镜机器人失败证据修订策略；物理执行在人类授权下运行 | 插入任务报告 2/21→17/21，并评测离体猪组织。值得研究离线指标被物理反馈推翻的过程；非临床验证，非无人监督的通用机器人 RSI |
| P2 | [RegenHarness](https://arxiv.org/abs/2609.27612)，2026-09 | 执行证据触发 context、模板、路由、恢复策略修订，通过回归与发布流程接受配置 | 真机四足任务案例；重点是可靠完成判定与版本管理。案例展示和 RSI 协议不能等同于大规模、受控的多轮能力提升实验 |

项目入口（未做安装与运行验证）：[RHO](https://rho-robotics.github.io/) · [ASPIRE](https://research.nvidia.com/labs/gear/aspire/)。其余工作后续需要单独核查官方代码、许可证、模型依赖及复现成本，不能由“有论文”推断“可复现”。

## 5. 机器人相关基础：有帮助，但不要全归为严格 RSI

| 工作 | 为什么值得补读 | 与机制层 RSI 的区别 |
|---|---|---|
| [Eureka](https://arxiv.org/abs/2310.12931)，2023 / ICLR 2024 | LLM 根据 RL 训练反馈进化奖励代码，连接程序搜索与低层技能学习 | 主要改奖励；搜索/反思机制未必自演化。也可与 Hyperagents 的机器人 reward design 对照 |
| [RoboCat](https://arxiv.org/abs/2306.11706)，2023 / TMLR | 当前模型生成后续训练数据，使通用操作策略更容易适应新任务 | 训练数据和策略的自改进循环，非直接的改进器代码自修改 |
| [SOAR: Autonomous Improvement of Instruction Following Skills via Foundation Models](https://arxiv.org/abs/2407.20635)，2024 / CoRL | VLM 提任务和评估，机器人自主采集，hindsight goal-conditioned learning 利用非最优数据；开放 30.5K 轨迹 | 固定学习算法下的自主经验采集与策略改善，不自动证明 meta-level RSI |
| [Harness VLA](https://arxiv.org/abs/2607.08448)，2026 | 冻结 VLA 作为可重试的接触操作 primitive，记忆与 agent 学习如何组合和重新 staging | 当前摘要明确技能库固定，主要学习 primitive 的适用范围；适合作为 VLA+harness 路线对照。[代码](https://github.com/RLinf/RPent) |

## 6. 推荐阅读顺序

如果第一批只选六篇，建议：

1. **STOP**：建立“改进器也可以成为被改对象”的直觉。
2. **DGM**：理解可执行 agent、自修改与档案式探索。
3. **Hyperagents**：理解任务 agent 和 meta agent 的共同演化，并看机器人奖励设计这一桥梁。
4. **EvoX**：再回读已有 Dream-RSI，明确在线搜索策略演化和离线历史回放的区别。
5. **ASPIRE**：看机器人失败修复如何积累成可迁移技能。
6. **ENPIRE**：看真实物理实验如何成为 coding agent 可操作的科研闭环。

下一批优先 **PhysEvo + 123 Rounds 失败报告 + RHO**，分别补齐改进机制自修改、闭环失效原因和多文件策略仓优化。

若关注 VLA 适应与数据效率：**RoboCat / SOAR → EmbodiRSI → ENPIRE**。若关注冻结模型与代码 agent：**DGM → Hyperagents → RHO → ASPIRE → PhysEvo / COAP**。若关注仿真、重建与生成：**Dream-RSI → EmbodiRSI → EmbodiedSmith**，但要始终区分历史回放、动力学仿真与数据生成。

## 7. 对后续研究选题的判断

机器人 RSI 的困难往往不在“能不能写出下一版代码”，而在**能否产生可信、可重复、覆盖失败模式的物理反馈，并把改进积累成稳定能力**。建议优先考虑三条问题线：

- **失败证据驱动的技能/策略仓演化**：基于 RHO、ASPIRE，加入修复前后对照、旧技能回归和跨任务迁移，检验能力是否累积。
- **改进机制自身演化**：基于 Hyperagents、PhysEvo、MetaSkill-Evolve，研究诊断工具、实验选择、探索预算是否能改得更好。这比只让 agent 修任务代码更接近机制层 RSI。
- **廉价评估与真实反馈之间的差距**：借鉴 Dream-RSI，但回放只用于筛选提案/调度；最终仍需未见布局或真机实验验证，研究回放排序对真实改善的预测能力。

最值得比较的不是不同论文摘要中的最高成功率，而是：固定预算下每轮提升、旧任务回归、未见任务/布局迁移、实际机器人试验次数、token/GPU/墙钟成本、人工介入和重置成本，以及修改 meta-level 后是否真的提高后续修复效率。

## 8. 本轮完成与未完成

- 已完成：核对本地 Dream-RSI 的研究对象；检索 RSI 主线及机器人文章；按改进对象和证据类型整理推荐；阅读 Hyperagents、EvoX、RHO、ASPIRE、ENPIRE、PhysEvo、COAP、EmbodiRSI、EmbodiedSmith、EndoRSI、RegenHarness 和失败报告的相关 HTML 正文段落。
- 未完成：逐篇完整精读、官方仓库与环境审计、实验复现、基于固定版本的数值表格复核、论文 PDF 批量下载。本轮没有修改已有 PDF，也没有安装或运行相关方法。

后续文献记录建议统一填写：paper/version、改进对象、改进器是否可变、反馈来源、持久化产物、训练/测试划分、仿真/真机、交互与算力预算、跨轮曲线、回归与迁移、人工边界、官方代码及本机验证状态。
