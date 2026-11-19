# AGENTS.md — FaultTrail 维护说明

面向后续接手本仓库的编码代理。只写与本仓库有关的事实，不复制其他项目的模板。

## 目录

| 路径 | 职责 |
| --- | --- |
| `version/` | 线性提交序列：顺序、唯一性、绑定摘要（FNV-1a 64，非加密） |
| `engine/` | 判定引擎：证据分类、边界、候选集合、确定性选点、预算 |
| `session/` | 会话模型：追加式事件日志、快照、恢复与重放 |
| `sessionfile/` | 磁盘格式：编码、逐项校验、应用级上限（无 IO） |
| `gitimport/` | 区间规划：first-parent 列表与起止端点的校验（无 IO、无 Git 调用） |
| `cmd/faulttrail/` | 命令行：参数、退出码、临时文件 + 替换、陈旧 revision 检测 |
| `reference/` | 独立的穷举参考模型，只用于对照，不得被产品代码调用 |
| `crosscheck/` | 白盒对照测试：穷举、随机、场景、预算、重放 |
| `examples/first_parent/` | 可运行示例 + 真实 `git log --first-parent` 夹具 |

产品代码不得依赖 `reference/`；参考模型不得调用 `engine/` 的候选收缩或选点函数。

## 命令

```bash
moon check --target js -d     # 零警告
moon test  --target js
moon test  --target wasm
moon info && moon fmt         # 提交前
moon run --target js examples/first_parent
moon run --target js cmd/faulttrail -- help
```

工具链基线：`moon 0.1.20261028` / `moonc 0.10.18+6c83a7f62`。`moon run` 单文件
`.mbtx` 在该基线上因核心包 `gzip` 别名冲突无法求解，故验证入口是包与测试，
不要为了绕过它去改工具链或其他项目的配置文件。本机无 MSVC，native 后端未验证。

## 不得破坏的契约

1. `Probe → Verdict` 的映射只在 `engine/types.mbt` 一处；`BuildFailed`/`TimedOut`
   永远不能变成 `Bad`。
2. skip / unknown 不得改变候选集合；只有 good / bad 约束边界。
3. 冲突必须返回记录引用，不得用后写记录覆盖，也不得多数投票。
4. 候选集合之外的位置不得被推荐；已 settled 或超出 `attempt_limit` 的位置不得
   被重复推荐。
5. 任何预算超限返回未完成状态，不得返回 `Located`。一次 `outcome()` 全阶段共享
   一个计量器；"一步"= 检查一个位置或一条记录（详见 README「预算与终止」）。
6. 快照必须校验语义版本、提交条数与摘要；恢复失败要给出具体原因。
7. 修正只能通过 `retract` 事件；原始记录必须留在日志中。

## 封装

`Sequence`、`Engine`、`Session`、`Snapshot` 的字段一律 `priv`（本工具链里
`pub struct` 不等于字段私有）。会话不得把内部引擎交出去，只提供
`candidate_span` / `observations` / `is_active` / `events` 这类返回副本或标量的
查询。改封装后要在临时探针包里重跑编译期负向证明（`seq.ids[0] = ...`、
`s.engine()`、`snap.events` 必须编译失败），保留输出并删除探针包；这类记录不入库。

公开的 `replay_observation` / `Session::replay` 只接受规范日志：id 稠密递增、
attempt 等于 `1 + 活动记录数`、位置合法、`Retracted` 目标存在且未撤销。放宽任何
一条都等于允许伪造证据，不是兼容性改进。

## 命令行与会话文件

- 会话文件是不可信输入：必须走 `sessionfile.decode`，不要在命令层手写解析或"修好"
  一个坏文件。版本不符直接拒绝，**不允许**把旧语义版本重标为当前版本。
- 保存先写本次独占创建的同目录唯一临时文件再 rename；不得先清空或截断目标文件。
  rename 失败要保留原文件，且只清理本次创建的临时文件。
- 保存前重新读取磁盘 `revision`，与本次加载的值不一致就报错。这只是拒绝已观察到
  的变化，不是原子比较交换，也不是并发锁。
- 临时文件必须独占创建（唯一名 + `wx`），不得使用固定 `<path>.tmp`，也不得先删除
  已有同名文件；失败只清理本次创建的那个。
- 文件里不存自由备注；命令层不提供备注参数。要加备注必须先设计显式字段与
  导出时删除的开关。
- 退出码是对外契约（0/1/2/3/4/5/6），改动会破坏脚本调用方；新增状态要同时改
  README、`CLI与会话格式-2026-11-17.md` 与测试。
- 命令包声明 `supported_targets = "js"`；不要因为核心在 Wasm 通过就宣称 CLI 可在
  Wasm 运行。

## Git 导入

- 只允许 `git rev-parse --verify` 与 `git rev-list --first-parent`；以参数向量调用
  （`execFileSync`），不经过 shell，仓库路径可以含空格。
- 只取提交标识与顺序。不得加 `--format` 读取作者、邮箱、提交正文，也不得运行仓库
  内的钩子、别名或脚本。
- 端点语义：两端都进入序列（位置 0 与最后一位）；起点必须在终点的 first-parent
  链上；合并提交按一个位置处理；两端相同直接拒绝。
- 所有导入失败必须发生在 `create` 之前，不写出会话文件；会话文件不记录仓库路径。

## 测试要求

参考模型 `reference/` 只因**契约改变**或**发现自身错误**才修改；产品实现变化时
不能顺手同步参考逻辑，否则对照就失去意义。改判定逻辑时先确认契约，再决定参考
模型是否该动，并跑穷举对照。新增场景优先写成 `crosscheck/` 下的白盒测试，不引入
外部脚本框架。

真值走查必须断言最终状态与真实 `k`：`Conflict`、`Budget` 或"循环跑完"都不是通过。

## 隐私

仓库、示例、日志与提交信息不得出现真实姓名、私人邮箱、手机号、主机名、私人 IP、
本机绝对路径或凭据。夹具仓库使用 `FaultTrail Fixture` 与
`fixture@faulttrail.invalid` 这类合成身份，且只在该夹具仓库内设置。
