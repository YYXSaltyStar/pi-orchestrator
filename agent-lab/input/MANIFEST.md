# 待分析章节清单

本目录的上级 `sections/` 里是四个待分析的 Markdown 章节文件。

| 文件路径 | 章节 |
|---|---|
| `sections/sec1.md` | 一、调用是无状态的 |
| `sections/sec2.md` | 二、上下文的构成 |
| `sections/sec3.md` | 三、三部分上下文没有地位差别 |
| `sections/sec4.md` | 四、装配层——harness |

这些文件来自《构建智能体——材料智能设计的准备工作》讲义的前四节。

## 本次任务

1. 对**每一个**章节文件，用 `doc-worker` 角色做结构分析，各自产出一份 JSON 报告。
2. 对**每一份** worker 报告，用 `doc-verifier` 角色独立复算并校验，各自产出一份判定。
3. 最后用 `report-writer` 角色把全部报告汇总成一份 Markdown 报告。

所有产物统一写入本目录的 `reports/`。
