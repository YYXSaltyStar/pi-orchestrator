# pi-orchestrator

一个 pi 包：把 pi 会话变成**只规划、不执行的编排者**，所有实际工作交给隔离子智能体。

## 它做了什么

| 组件 | 作用 |
|---|---|
| `extensions/subagent/` | 注册 `subagent` 工具，把任务派给独立进程的子智能体 |
| `extensions/orchestrator/` | `PI_ORCHESTRATOR=1` 时注入编排者身份 + 软剥夺写工具 |
| `extensions/guard/` | `PI_LEAK_GUARD=1` 时检测工具投递失败，打 `pi-guard: FAIL` 标记 |
| `prompts/orchestrator.md` | 编排者系统提示词 |
| `agents/*.md` | 三个子智能体角色：`doc-worker` / `doc-verifier` / `report-writer` |

## 安装

包本身已装好（`pi list` 可见）。角色定义需要放到 pi 的 agent 目录：

```powershell
mkdir -Force "$env:USERPROFILE\.pi\agent\agents" | Out-Null
copy pi-orchestrator\agents\*.md "$env:USERPROFILE\.pi\agent\agents\"
```

## 使用

### 方式一：入口命令（推荐）

```powershell
pi-orchestrator
```

开一个编排者窗口，直接对话。

```powershell
pi-orchestrator "把 sections 下四份文件的结构整理成 reports/FINAL.md"
```

**注意**：带中文参数时，命令要写在 `.ps1` 文件里执行，不要在交互式 cmd 里手打——
`.cmd` shim 是 ANSI 的，中文字面量会被破坏。

### 方式二：原始命令

```powershell
cd agent-lab
.\orchestrate.ps1              # 交互
.\orchestrate.ps1 -Task "..."  # 一次性
```

### 方式三：普通 pi + 手动派活

```powershell
pi
```

然后自然语言：

```
派一个 doc-worker 分析 sections/sec1.md，写到 reports/worker-sec1.json
```

## 两种剥夺强度的区别（重要）

| | 装配期硬剥夺 | 运行期软剥夺 |
|---|---|---|
| 怎么触发 | 启动加 `--tools read,grep,find,ls,subagent` | `PI_ORCHESTRATOR=1` |
| 强度 | **强**：工具定义从未进入上下文 | **弱**：工具定义可能已进过上下文 |
| 用在哪 | `orchestrate.ps1`（推荐） | 普通启动后想进编排模式 |

讲义第七节的立场是**装配期剥夺才可靠**。所以正式使用走 `orchestrate.ps1`，
`PI_ORCHESTRATOR=1` 只作为"已经开着的会话想切进编排模式"的补救。

## 输入的写法要点

派活时，任务描述要**自包含**，因为子智能体看不到你的上下文：

```
好：派一个 doc-worker 分析 C:\...\sections\sec1.md，
    把 JSON 报告写到 C:\...\reports\worker-sec1.json

差：分析刚才说的那个文件        ← 子智能体不知道"刚才那个"是哪个
```

任务描述里写清三件事：**做什么、产出到哪、什么格式**。

## 已知限制

1. **guard 只保护母进程**。子智能体撞上工具投递故障时只打标记，没有外层重试。
   子智能体越多，整链失败概率越高。
2. **verifier 不可靠**。实测中 `doc-verifier` 会与 `doc-worker` 犯同样的口径错误，
   误报和漏报都出现过。同源的两个模型不构成独立校验——真要独立，得用确定性脚本。
3. **工具投递故障是间歇性的**，未定性。靠 `orchestrate.ps1` 的重试兜底。
