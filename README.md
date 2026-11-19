# FaultTrail

可重放的 Git 回归定位器。首轮只做一件可检查的事：**在一段线性提交序列上，用
显式证据推断"首次异常位置"的候选集合，并给出下一步建议；状态可保存、可重放。**

核心三个包（`version` / `engine` / `session`）不含文件 IO、不调用进程、不读取 Git
仓库、不执行测试命令；它们接收调用方给出的、按顺序排列且互不相同的提交标识。

真正读 Git 的是命令行：`start --repo ... --from ... --to ...` 会用只读的
`git rev-parse` / `git rev-list --first-parent` 取一段主线区间，再把标识交给核心。
也可以跳过 Git，用 `--sequence` 直接给列表。两种方式都只做人工判定，不执行目标
项目的测试命令。

## 为什么不是 `git bisect` 的包装

Git 的 bisect 已经具备自动执行（`git bisect run`）、`skip`（含 125 退出码）、
`git bisect log` 与 `git bisect replay`。这些能力在本项目里不被当作创新。

FaultTrail 的差异在证据模型，而不是命令转发：

- 记录的是**证据**而不是当前区间：good / bad 约束边界，skip / unknown 只表示
  "没有可靠判定"，不缩小候选集合。
- 同一提交的同类证据幂等；good 与 bad 冲突时**显式返回冲突并指向两条记录**，
  不做"最后写入覆盖"，也不做多数投票。
- 结果总是**候选集合**：唯一、需观察、歧义、冲突、信息不足、预算耗尽六种。
  信息不足时返回信息不足，不猜端点。
- 会话是**追加式事件日志**：修正必须是对某条记录的显式撤销事件，原始记录仍然
  留在日志里；快照绑定提交序列与语义版本，换序列恢复会被拒绝。

## 语义模型

序列 `v0 … v(n-1)` 从旧到新，`k` 为隐藏的首次异常位置：

```
v0 … v(k-1) 正常        vk … v(n-1) 异常        0 ≤ k ≤ n-1
```

- good(i) ⇒ `k > i`；bad(i) ⇒ `k ≤ i`。
- `G = max{good 位置}`，`B = min{bad 位置}`；相容集合为 `G < k ≤ B`。
- 缺少 good 或 bad 端点 ⇒ **信息不足**；`G ≥ B` ⇒ **冲突**（同一提交既 good 又
  bad 也走这条）。
- 候选集合为 1 ⇒ **唯一定位**；否则取候选区间内最靠近中点的可测提交 ⇒
  **需观察**；候选都在当前重试策略下不可再测 ⇒ **歧义**。

单调性前提是"目标性质只发生一次 good→bad 转变"。真实仓库的修好又坏不在首版
保证范围内；有限观察一致也不能证明全历史单调。

## 输入约束

- 提交标识限定为**可打印 ASCII**（`0x21..0x7e`），非空、不重复；`v0` 与完整哈希
  同样有效，不强制长度。超出范围的字符返回 `IdHasControl` / `IdNotAscii`，
  补充平面字符不会触发 panic。
- 长度、证据条数、计算步数都有可注入上限，超限返回未完成状态。

## 结果类型

| 构造子 | 含义 |
| --- | --- |
| `NeedObservation` | 建议某个尚可测试的位置，附候选区间与两个分支的收缩结果 |
| `Located` | 所有相容位置只剩一个 |
| `Ambiguous` | 仍有多个候选，且都不可再测，附每个候选被阻塞的原因 |
| `Conflict` | 返回导致矛盾的 good / bad 两条记录 |
| `Insufficient` | 缺少端点，不猜 |
| `Budget` | 达到注入的步数预算，未完成 |

非法输入不进入这一层：空序列、重复标识、非正预算、越界记录在构造或记录阶段就被
拒绝（`SeqError` / `InvalidReport` / `RecordError`），既不产生结果，也不留下部分
状态。

## 探测结果的分类

`Probe` 到 `Verdict` 的映射是显式的：`Passed → Good`、`Failed → Bad`，
`BuildFailed / TimedOut / Skipped → Skip`，`Undetermined → Unknown`。
**构建失败或超时的版本不会被判成目标功能 bad。**

## 快速开始

```bash
# 发布到 Mooncakes 之后（当前尚未发布）：
#   moon add WENwenZU/faulttrail@0.1.0
# 从源码运行需要 MoonBit 工具链（本仓库验证于 moon 0.1.20261028 / moonc 0.10.18）
moon check --target js
moon test  --target js
moon test  --target wasm
moon run --target js examples/first_parent
moon run --target js cmd/faulttrail -- help
```

`examples/first_parent` 读取一份真实的 `git log --first-parent --reverse
--format="%H %s"` 输出（合成仓库，8 个 first-parent 提交，含一个合并提交），
把顺序交给核心，走一遍调查并逐项自检。

## 公开复现

```bash
moon run --target js examples/git_import
```

它在 `examples/git_import/out/` 里现场创建一个合成仓库（9 个提交，其中 8 个在主线，
`v4` 是合并提交，另有 1 个旁支提交），导入 `main~7..main`，然后跑完端点记录、建议、
撤销、重记与重放，并检查缺失仓库、旁支起点、反序区间、单提交区间和含空格的路径。
输出为 PASS/FAIL 清单，全部通过时退出 0。

不需要预先准备仓库；合成身份只写在该临时仓库的本地配置里，仓库输出目录已被
`.gitignore` 忽略。

## 命令行会话

```bash
# 方式一：显式提交列表，每行一个标识，从旧到新排列。
moon run --target js cmd/faulttrail -- start --sequence ids.txt --session s.session

# 方式二：从本地 Git 仓库只读导入一段 first-parent 区间（两端都包含）。
# start 会打印两个端点的完整标识，可直接用于下面的 record。
moon run --target js cmd/faulttrail -- start \
  --repo ../some-repo --from v0 --to v7 --session s.session

# 记录端点、查询建议、跳过、撤销、查看、重放
moon run --target js cmd/faulttrail -- record  --session s.session --commit <start-id> --probe passed
moon run --target js cmd/faulttrail -- record  --session s.session --commit <end-id>   --probe failed
moon run --target js cmd/faulttrail -- next    --session s.session
moon run --target js cmd/faulttrail -- record  --session s.session --commit <id> --probe skipped
moon run --target js cmd/faulttrail -- retract --session s.session --observation 2
moon run --target js cmd/faulttrail -- explain --session s.session
moon run --target js cmd/faulttrail -- replay  --session s.session
```

- 提交列表由用户显式给出，一行一个，从旧到新；空行与 `#` 注释被忽略。
- Git 导入只读取提交标识与顺序：`--from` 必须位于 `--to` 的 first-parent 链上，
  两端都进入序列（位置 0 与最后一位）；合并提交按一个位置处理，因此结果可能落在
  合并提交上。不读作者、邮箱、提交正文，不运行仓库脚本或测试。
- 区间超长、端点不在主线上、版本无法解析或仓库不可读时直接报错，不创建会话文件。
- 命令不运行测试；`build-failed` 等只记录，不约束边界。
- 会话文件按行存序列、摘要、重试策略、预算与完整事件；格式版本与语义版本不匹配
  一律拒绝，不做静默迁移。
- 保存先写同目录的独占临时文件（唯一名 + `wx`）再替换；失败保留原文件，且不会
  覆盖无关的 `.tmp` 文件。保存前比较磁盘 revision，只能拒绝**已经观察到**的变化，
  不是并发锁；同会话多进程同时写入仍可能丢记录，本轮不支持并发合并。
- 退出码：0 完成、1 输入/IO、2 用法、3 信息不足、4 歧义、5 冲突、6 预算耗尽。
  `explain` 只读成功即 0，状态判断用 `next`。
- 命令包声明 `supported_targets = "js"`：磁盘行为只在 JS 后端验证，Wasm 只覆盖核心。

## 用法

```moonbit
let ids = ["v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7"]
let sequence = @version.Sequence::from_ids(ids).unwrap()
let session = @session.Session::start(sequence).unwrap()

let _ = session.observe(0, @engine.Passed)   // v0 正常
let _ = session.observe(7, @engine.Failed)   // v7 异常

match session.outcome() {
  @engine.NeedObservation(advice) =>
    println("test v\{advice.index}: good -> \{advice.index + 1}..\{advice.span.hi}")
  _ => ()
}
```

保存与恢复：

```moonbit
let snapshot = session.snapshot()
let resumed = @session.Session::restore(snapshot, sequence).unwrap()
// 候选、终态、下一建议与原会话一致；换一个序列恢复会返回 SequenceMismatch
```

会话只提供只读查询（`candidate_span` / `observations` / `is_active` / `events`），
不把内部引擎交出去；返回的数组都是副本。快照字段私有，只能通过访问器读取，
`restore` 会逐条校验事件日志是否是本引擎可能产生的规范日志。

## 预算与终止

- 序列长度：`Sequence::from_ids(..., max_commits=N)`，在建立索引前检查。
- 证据条数：`Limits::new(max_observations, max_steps)`，记录前检查。
- 计算步数：一次 `outcome()` 调用共享一个预算。"一步"= 检查一个提交位置，或检查
  一条记录（用于冲突引用定位）。边界扫描、候选扫描、歧义解释与冲突定位都计入；
  可测性判断是 O(1)（重试标记在记录/撤销时维护），不另行计数。超限立即返回
  `Budget`，并标明中断的阶段，不返回任何已完成的结论。
- `candidate_span()` 是 O(n) 的只读查询，不受步数预算约束，也不声称完成度。
- 每个提交的可测次数由 `attempt_limit` 决定（默认 1）：已被 skip 的位置不会
  被反复推荐。记录里保留每次尝试，不被覆盖。

预算机制只限制本库的分配与循环，不构成"宿主不会 OOM"的证明。

## 首轮不包含

一般 Git DAG 的归因、工作树执行器、网络抓取、自动修复、flaky 概率保证、
非单调回归识别、CI 发布链。first-parent 下的结果可能落在合并提交上，它不等于
分支内部最初引入问题的提交。

## 作者与 AI 使用

- 项目账号：`WENwenZU`（GitHub 与 Mooncakes）。
- 本轮代码与文档由 AI 编码代理在用户指令下编写，作者与贡献关系以账号为准，
  未构造虚假作者、提交时间或贡献记录。
- 仓库不包含真实姓名、私人邮箱、手机号、主机名、私人 IP、本机绝对路径或凭据；
  示例使用 `v0` 一类合成标识。

## 许可

Apache-2.0，见 `LICENSE`。
