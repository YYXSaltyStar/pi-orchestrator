# agent-lab — pi 子智能体架构验证

用最小规模验证「母智能体 + 隔离子智能体」架构是否跑得通。**已验证跑通。**

## 结论

| 架构主张 | 验证结果 |
|---|---|
| 母智能体无执行能力（装配期硬剥夺） | ✅ 母进程工具集为 `read,grep,find,ls,subagent`，无 `write`/`edit`/`bash`/`powershell` |
| 母智能体必须委派才能产出文件 | ✅ 全部产物由子智能体写出，母进程未也无法直接写 |
| 子智能体上下文与母隔离 | ✅ 母只收到一句 `WROTE <path>`，看不到子智能体的完整过程 |
| 子智能体可自行决策 | ✅ worker `anomalies` 字段主动报告了行数口径歧义 |
| 独立校验发现分歧 | ✅ 4 组 worker/verifier 中至少 1 组判定 mismatch |

## 用法

```powershell
cd agent-lab

# 交互模式（自己跟母智能体对话）
.\orchestrate.ps1

# 一次性任务
.\orchestrate.ps1 -Task "派一个 doc-worker 分析 sections\sec1.md，写到 reports\worker-sec1.json"
```

`orchestrate.ps1` 做两件事：**硬剥夺启动**（`--tools read,grep,find,ls,subagent`）+ **失败重试**
（guard 报 `pi-guard: FAIL ...` 就换新进程重跑，最多 3 次）。

## 组成

| 位置 | 内容 |
|---|---|
| `~/.pi/agent/extensions/subagent/` | 委派能力，注册 `subagent` 工具（pi 官方 examples 原样移植） |
| `~/.pi/agent/extensions/guard/` | 只检测不修复：工具投递失败时向 stderr 打 `pi-guard: FAIL ...` 标记 |
| `~/.pi/agent/agents/*.md` | 三个角色：`doc-worker` / `doc-verifier` / `report-writer`，均用 `deepseek-flash` |
| `orchestrator.prompt.md` | 母智能体的编排者身份与汇报纪律 |
| `sections/` | 测试输入：讲义前四节 |
| `reports/` | 子智能体产物 |
| `_ground_truth.json` / `_prepare.ps1` | 客观基准与重算脚本 |

## 已知问题（按严重程度）

### 1. verifier 不可靠 —— 它会和 worker 犯同样的错

**实测**：sec1 的 worker 是对的，verifier **误报 mismatch**；sec2 与 sec4 的 worker
表格行数算错，verifier **漏报 match**。

**根因**：verifier 与 worker 使用同一套判断口径。当口径本身有歧义（例如"表格数据行"
是否包含表头行），两个模型会**系统性地犯同一个错**——独立复算并不能纠正口径偏差。

**启示**：讲义第七节讲隔离解决的是"它做得到什么"。这里暴露的是另一个问题——
**同源的两个智能体不构成独立校验**。真正的独立校验需要不同的口径来源，或者确定性
的检查程序（脚本）而不是另一个模型。

### 2. guard 只保护母进程

guard 检测到失败只写标记、不修复；修复靠 `orchestrate.ps1` 的重试循环。
但子智能体进程**没有外层重试**——它们继承 guard，撞上工具投递故障时只会打标记。
因此子智能体数量越多，整链失败概率越高（9 个子智能体时尤其明显）。

**未修的取舍**：今天实测能跑通，概率可接受。等真用起来觉得疼再修（例如给子进程也
加重试，或在子进程里禁用 guard 以免噪音）。

### 3. 工具投递故障是间歇性的，未定性

`deepseek` + pi 的组合下，模型偶尔拿不到工具集：要么把工具调用写成文本，要么直接
说"我没有工具"。**已排除**：模型选择、提示词长度、任务复杂度、工具数量、特定工具组合。
失败时 `pi.getActiveTools()` 返回空数组，是工具真的没送到。

**处置**：不追根因（不在可修层），靠重试兜底。

### 4. 行数口径

`read` 工具报的行数与脚本 `ReadAllLines` 可能差 1（尾行/混合行尾）。基准以
`read` 工具口径为准。文件 `sections/*.md` 是 CRLF/LF 混合，这也是最初基准算错的原因。
