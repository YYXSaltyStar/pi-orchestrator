# pi(Windows) → QE(WSL) 跨环境方案设计

> 状态：**方案，未实施**。已在你的机器上实测验证关键环节。
> 环境实测：Ubuntu-24.04 / WSL2 / ext4、QE 7.5（MPI+OpenMP）、24 核、**7.6 GiB 内存**、RTX 4060 8 GB
> 关联文档：`pi-子智能体架构设计.md`（路线 A、flash、verifier 已定）

---

## 一、实测到的环境事实（不是假设）

| 项 | 实测值 | 影响 |
|---|---|---|
| WSL 发行版 | Ubuntu-24.04，WSL2，`6.18.33.2-microsoft-standard-WSL2` | — |
| QE | `/usr/local/bin/`，**v7.5**（MPI & OpenMP） | 够用 |
| QE 源码 | `/home/mhl/src/qe-7.5`、`/opt/qe-7.5`、`/home/mhl/qe` | 伪势有多份，要定权威路径 |
| 伪势 | `/usr/share/espresso/pseudo/`（Debian 6.7 数据包）、`/home/mhl/Si/pseudo/`、`/home/mhl/GaAs/pseudo/` | 混用有版本风险 |
| **CPU** | 24 核 | 可并行，但受内存限制 |
| **内存** | **7.6 GiB，QE 报 "5654 MiB available"** | ⚠️ **这是真正的约束** |
| GPU | RTX 4060 Laptop 8 GB | QE 非 GPU 版本，用不上 |
| 根文件系统 | `/dev/sdd ext4`，1007 G，可用 950 G | 计算必须落这里 |
| `/mnt/c` | **`9p` 类型**，301 G | ⚠️ 跨边界慢，不能放计算 |
| MPI | Open MPI 4.1.6 | 可 `mpirun` |
| Python | 3.12.3，**无 ase、无 pymatgen** | 后处理要自己写或先装 |
| **sshd** | **未安装，22 端口未监听** | ⚠️ **SSH 路线不可用** |
| `.wslconfig` | 只有 experimental 段，**未设内存上限** | 7.6 GiB 是物理总量 |

**现成参考算例**（很有价值，第一个实验可以直接对照）：

```
/home/mhl/Si/
├── pseudo/Si.pbe-n-kjpaw_psl.1.0.0.UPF
├── Si_scf/  si.scf.in  si.scf.out   ← ibrav=0, ecutwfc=30, ecutrho=240, 4×4×4 k 网格
├── Si_band/ si.band.in  bands.in  si.band  si.band.gnu  plot_band.py  ← 完整能带流程
├── Si_dos/  si.dos.nscf.in  dos.in
└── Si_计算实验报告.md  report_band.png
```

---

## 二、真正的问题不是"能不能调用"，而是"数据往哪放"

先排除两个看似可行、实则不可行的路线：

**❌ 路线 1：`\\wsl$\Ubuntu-24.04\...` 让 pi 直接读写 WSL 文件**

技术上 Windows 能通过 UNC 路径访问 WSL 的 ext4。但 pi 的 `read`/`write`/`edit`/`grep`/`find`/`ls` 工具走 Node 的 `fs`，对 UNC 路径的可靠性和性能都不适合高频 I/O，而且**计算目录一旦暴露成 Windows 路径，就很容易被误当成普通目录去跑 QE**。

**❌ 路线 2：把计算目录放在 `/mnt/c`**

`/mnt/c` 是 **9p 协议**挂载，不是本地文件系统。QE 的 SCF/能带计算要反复读写波函数文件（`wfc*.dat`、`charge-density.dat`），体积从几十 MB 到几 GB。走 9p 会有数量级的性能损失，而且大文件 I/O 容易出诡异问题。

> 官方也印证了这点：`containerization.md` 明确讲「工具级隔离不约束宿主 Pi 进程，也不约束那些不使用隔离后端的扩展工具」。同理，**文件工具的能力边界在 Windows 侧，它够不到 ext4 的性能**。

**✅ 所以真正的约束是：重 I/O 必须留在 ext4，只有"输入"和"提取后的结果"过边界。**

SSH 路线本来是最干净的（`ssh_exec` 工具现成），但 **WSL 里没有 sshd**，要装要配密钥要处理 WSL IP 变动，收益不大。

**结论：走 `wsl.exe` 作为唯一通道。**

---

## 三、实测验证的通道（已跑通）

### 3.1 退出码能正确传递

```powershell
wsl.exe -d Ubuntu-24.04 -- bash -c "exit 42"; $LASTEXITCODE   # → 42 ✅
```

### 3.2 一个真实的 QE SCF 跑通

用现成的 `/home/mhl/Si/Si_scf` 结构：

```
[t3] rc=0  elapsed=4s
!    total energy              =     -93.43988201 Ry
     convergence has been achieved in   7 iterations
   JOB DONE.
```

**4 秒**，退出码 WSL→PowerShell 一路正确。

### 3.3 两个踩到的坑（方案必须吸收）

**坑 1：`$` 和管道被 PowerShell 抢先解释。**

```powershell
wsl.exe -d Ubuntu-24.04 -- bash -c "... | grep ...; echo $?"   # ❌ PowerShell 先吃掉 $? 和 |
```

报错 `convergence: command not found`、`JOB: command not found`——因为 `pw.x` 那段的 `|` 被 PowerShell 当成了自己的管道。

**解法：脚本走文件，不走 `-c` 字符串。** 把 bash 脚本写到 Windows 临时目录，用 `/mnt/c/...` 路径让 WSL 执行：

```powershell
wsl.exe -d Ubuntu-24.04 bash /mnt/c/Users/MHL/AppData/Local/Temp/job.sh
```

这条已验证可行（3.2 就是这么跑的）。它同时解决了引号、转义、多行、`$` 全部问题。

**坑 2：伪势相对路径 + `cp -r` 摊平目录。**

`si.scf.in` 里写的是 `pseudo_dir='../pseudo'`。第一次测试我用 `cp -r /home/mhl/Si/pseudo .`，**把目录内容摊平成了 `./pseudo` 但 `../pseudo` 找不到**，QE 报：

```
Error in routine readpp (1):
file ../pseudo/Si.pbe-n-kjpaw_psl.1.0.0.UPF not found
```

**解法：作业目录的层级必须让 `../pseudo` 成立。** 用符号链接：

```
<workdir>/
├── pseudo/                  → 软链到权威伪势目录
└── <job>/                   # cd 到这里跑，../pseudo 成立
```

这条也已验证（3.2 用的就是这个结构）。

---

## 四、推荐方案：`qe` 子智能体 + 单一 `qe_run` 工具

### 4.1 核心设计

给子智能体**不是** `powershell` 工具去手敲 `wsl.exe`，而是**一个专门的 `qe_run` 工具**。理由：

1. 子智能体（flash）不该自己拼 `wsl.exe` 命令行——实测证明引号/转义/退出码很容易错。
2. 结构化入参出参，才能把**重 I/O 挡在边界内**、只把提取结果带回上下文。
3. 装配层可控，符合讲义第七节的思路。

### 4.2 角色与工具（在既定架构上的修订）

| 角色 | 工具集 | 变更 |
|---|---|---|
| 母 orchestrator | `read grep find ls delegate` | 不变 |
| **qe-worker** | `read write qe_run` | **新增角色，不叫通用 worker** |
| **qe-verifier** | `qe_run`（只读模式）、`read` | 新增 |
| 通用 worker | `read grep find ls` | 用于非计算类子任务 |

**关键：qe-worker 不给 `powershell`。** 它只能通过 `qe_run` 触达 WSL——这是硬剥夺的又一层应用。

### 4.3 `qe_run` 工具接口

```typescript
// 入参
{
  action: "run" | "status" | "collect",
  job_id: string,                    // 例 "si-band-01"
  calc: "scf" | "nscf" | "bands" | "dos",   // 决定用哪个 .x 与后处理
  input_deck: string,                // 完整 QE 输入卡文本
  pseudo: string[],                  // 需要的伪势文件名，如 ["Si.pbe-n-kjpaw_psl.1.0.0.UPF"]
  timeout_s?: number,                // 默认按 calc 类型取
}

// 出参（结构化，这是唯一过边界的东西）
{
  status: "done" | "running" | "failed",
  job_id: string,
  exit_code: number,
  elapsed_s: number,
  outdir_rel: string,                // WSL 侧相对路径
  extracted: {                       // 只提取关键量，不回传整个 .out
    total_energy_ry?: number,
    fermi_ev?: number,
    converged?: boolean,
    iterations?: number,
    band_gap_ev?: number,
    highest_occupied_ev?: number,
    lowest_unoccupied_ev?: number,
    n_errors?: number,
  },
  tail: string,                      // 最后 ≤40 行，用于排错，限长
  artifacts_wsl: string[],           // WSL 侧产物路径清单
}
```

**`extracted` 是设计重点**：QE 的 `.out` 动辄几百 KB 到几 MB，**绝不能整份读进 flash 的上下文**（费用 + 上下文窗口）。工具在 WSL 侧用 `grep`/`awk` 提取关键量，只回传数值。

### 4.4 目录布局

```
Windows 侧（母与子智能体的文件工具活动区）
<项目根>/
├── agents/qe-worker.system.md
├── briefs/<job>.md
├── reports/<job>.json
└── out/<job>/                     ← 最终交付物（图、报告），小文件

WSL 侧 ext4（重 I/O 全在这里）
/home/mhl/qe-runs/
├── pseudo/                        ← 唯一权威伪势目录（软链或实拷）
├── _scripts/                      ← qe_run 落地的 bash 脚本
└── <job_id>/
    ├── <job_id>.in                ← 输入卡
    ├── tmp/                       ← outdir，波函数/电荷密度在这
    ├── <job_id>.out               ← 完整输出（大，不过边界）
    └── <job_id>.json              ← 提取结果（小，过边界）
```

**只有 `.json` 和最终图回 Windows 侧。** `.out` 和 `tmp/` 永远留在 ext4。

### 4.5 执行流程（`action: "run"`）

```
1. 校验入参：calc 类型、input_deck 语法粗查、伪势文件存在性
2. 在 /home/mhl/qe-runs/<job_id>/ 建目录
3. 写 <job_id>.in
4. 把所需 .UPF 从权威 pseudo 目录软链/拷进作业的 pseudo/
5. 生成 bash 脚本 → /home/mhl/qe-runs/_scripts/<job_id>.sh
6. wsl.exe -d Ubuntu-24.04 bash /mnt/c/.../_scripts/<job_id>.sh
   （脚本内部：cd 作业目录，跑 pw.x / bands.x，提取，写 <job_id>.json）
7. 读回 <job_id>.json（走 \\wsl$ 或 wsl.exe cat），返回结构化结果
```

第 6 步脚本内容形如：

```bash
#!/usr/bin/env bash
set -u
JOB="si-band-01"; CALC="scf"
cd /home/mhl/qe-runs/"$JOB" || exit 90
export OMP_NUM_THREADS=1
t0=$(date +%s)
pw.x -in "$JOB.in" > "$JOB.out" 2>&1
rc=$?
t1=$(date +%s)
E=$(grep -E '^! +total energy' "$JOB.out" | tail -1 | awk '{print $5}')
CONV=$(grep -c 'convergence has been achieved' "$JOB.out")
FERMI=$(grep -E 'the Fermi energy is' "$JOB.out" | tail -1 | awk '{print $5}')
JOB_DONE=$(grep -c 'JOB DONE' "$JOB.out")
printf '{"exit_code":%d,"elapsed_s":%d,"total_energy_ry":%s,"fermi_ev":%s,"converged":%s,"job_done":%d}\n' \
  "$rc" "$((t1-t0))" "${E:-null}" "${FERMI:-null}" "$([ "$CONV" -gt 0 ] && echo true || echo false)" "$JOB_DONE" \
  > "$JOB.json"
tail -40 "$JOB.out" > "$JOB.tail"
exit $rc
```

> 注意这里**没有 PowerShell 参与**——所有逻辑都在 bash 脚本里，规避了 3.3 的坑 1。

### 4.6 资源限制（针对 7.6 GiB 内存）

**这是最容易翻车的地方。** 实测 QE 默认行为：

```
Parallel version (MPI & OpenMP), running on      24 processor cores
Number of MPI processes:                 1
Threads/MPI process:                    24
5654 MiB available memory on the printing compute node
```

**默认开 24 个 OpenMP 线程**，而可用内存只有 5.6 GiB。如果同时跑几个作业、或每个都开满 24 线程，会 OOM。

建议固定：

| 场景 | 配置 | 理由 |
|---|---|---|
| Si 这类小体系 | `OMP_NUM_THREADS=1`，1 MPI rank | 实测 4 秒，够快 |
| 中等体系 | `OMP_NUM_THREADS=1`，`mpirun -np 4`（`-nk 4`） | 4 个 rank 内存可控 |
| **并发上限** | **同时最多 2 个 QE 作业** | 7.6 GiB ÷ 2 留余量 |
| 上限保护 | `ulimit -v` 或显式 `-nk`，避免单作业吃光内存 | — |

**并把 `OMP_NUM_THREADS=1` 写死在脚本里**，不依赖环境。

### 4.7 超时策略

实测到 pi 的两个关键事实：

- **`bash`/`powershell` 工具的 `timeout` 参数是「可选，无默认超时」**（源码：`Timeout in seconds (optional, no default timeout)`），最大可设 `MAX_TIMEOUT_SECONDS2 = 2147483647/1000` 秒（约 24.8 天）。
- 所以**简单体系可以同步跑**（Si SCF 只要 4 秒）。

但能带计算链（SCF → NSCF → bands）可能要几分钟到几十分钟。**策略分两档：**

| 预估耗时 | 策略 |
|---|---|
| < 3 分钟 | **同步**。`qe_run` 一次调用跑完返回，最简单 |
| ≥ 3 分钟 | **异步**。脚本用 `nohup ... &` 后台跑并记 PID；`qe_run` 立即返回 `status: "running"`；子智能体用 `action: "status"` 轮询 |

异步档的脚本骨架：

```bash
nohup bash -c 'cd /home/mhl/qe-runs/'"$JOB"' && OMP_NUM_THREADS=1 pw.x -in '"$JOB"'.in > '"$JOB"'.out 2>&1; echo $? > '"$JOB"'.rc' \
  > /dev/null 2>&1 &
echo $! > "$JOB.pid"
```

`status` 动作检查 `$JOB.rc` 是否存在、`JOB DONE` 是否出现。

**异步档还解决了另一个问题**：pi 的 `powershell` 工具调用如果中途被用户 `Esc` 中止，同步跑的长作业会被杀掉；后台跑则能活下来。

### 4.8 伪势策略（必须定权威路径）

现在有至少三份伪势，**混用会得到静默错误的物理结果**（不同赝势的总能量不可比，能带形状可能不同）。建议：

1. **确定唯一权威目录**：建议 `/home/mhl/qe-runs/pseudo/`，从 `/home/mhl/Si/pseudo/`（即参考算例用的那份）起底。
2. 作业目录用**软链**指向它，不实拷（省空间、避免分叉）。
3. `qe_run` 在跑之前**校验伪势文件存在**，不存在直接返回错误——**不要让 QE 跑到一半才报 `readpp` 错误**（这正是我实测踩到的坑）。
4. 记录每个作业用了哪个伪势文件，写进报告的 `provenance`。

---

## 五、和既定架构的衔接

这次边界问题**暴露了原方案一个没考虑到的地方**：原方案假设子智能体的工作目录就是它的世界。现在子智能体有了两个世界——Windows（文件工具）和 WSL（计算）。

修订后的 qe-worker 契约：

```json
{
  "status": "done",
  "summary": "完成 Si 能带计算，间接带隙 0.62 eV",
  "artifacts": [
    { "path": "out/si-band-01/band.png", "action": "created", "bytes": 216311 }
  ],
  "provenance": {
    "qe_version": "7.5",
    "pseudo": ["Si.pbe-n-kjpaw_psl.1.0.0.UPF"],
    "calc": "scf→nscf→bands",
    "params": { "ecutwfc": 30, "ecutrho": 240, "k_grid": "4 4 4" },
    "wsl_job_dir": "/home/mhl/qe-runs/si-band-01"
  },
  "evidence": [
    { "claim": "SCF 收敛", "source": "si-band-01.out: 'convergence has been achieved in 7 iterations'" }
  ],
  "decisions": [
    { "question": "k 点路径", "choice": "Γ-X-W-L-Γ-K", "why": "与参考算例一致，便于对照" }
  ],
  "open_questions": [],
  "usage": { "input": 0, "output": 0 }
}
```

`provenance` 是新增字段，**对计算类任务必需**——没有它，结果不可复现、不可比。

**verifier 的职责也随之具体化**：它重跑一遍 `qe_run` 的 `collect`/`status`，独立核对 `total_energy`、收敛性、带隙数值，**并与参考算例 `/home/mhl/Si` 对照**。它不信任 worker 的转述。

---

## 六、第一个实验任务的具体形态

任务：**用 QE 计算 Si 的能带结构**，以 `/home/mhl/Si` 为对照基准。

拆解为子任务（母智能体分派）：

| # | 子任务 | 执行者 | 工具 | 预期 |
|---|---|---|---|---|
| 1 | 环境体检：QE 版本、伪势可用性、内存 | qe-verifier | `qe_run(action:"doctor")` | 确认 7.5、伪势存在 |
| 2 | SCF | qe-worker | `qe_run` | 总能量 ≈ −93.44 Ry，7 步收敛 |
| 3 | NSCF（能带路径 k 点） | qe-worker | `qe_run` | 生成 `si.band` |
| 4 | bands.x 后处理 | qe-worker | `qe_run` | 带隙数值 |
| 5 | 绘图 + 报告 | qe-worker | `write` | `report_band.png` + md |
| 6 | 独立校验 | qe-verifier | `qe_run` | 与参考算例对照，判定 |

**验收基线**（有客观对照，这是选这个任务的最大好处）：

- SCF 总能量应接近 **−93.43988201 Ry**（实测值）
- 若用同一伪势与参数，能带结果应与 `/home/mhl/Si/report_band.png` 一致
- Si 是**间接带隙**半导体，实验带隙 1.12 eV，PBE 会低估到约 0.6 eV——**这是正常现象，verifier 必须知道，不能判为错误**

> 最后一条很重要：如果 verifier 不知道 PBE 低估带隙，它会把正确结果判成失败。**判定标准要写进 verifier 的系统提示词**。

---

## 七、待确认

1. **伪势权威目录**定在哪？我建议 `/home/mhl/qe-runs/pseudo/`，从 `/home/mhl/Si/pseudo/` 起底。
2. **同步还是异步**为首选？我建议 <3 分钟同步、其余异步，阈值可调。
3. **并发上限 2** 是否接受？（受 7.6 GiB 内存约束，我建议保守）
4. 第一个任务**是复现 `/home/mhl/Si` 的能带，还是换一个体系**？复现的好处是有客观对照，便于验证架构本身；换体系更接近真实科研。
