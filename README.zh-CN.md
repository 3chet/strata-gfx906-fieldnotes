<div align="right">

[English](README.md) · **简体中文**

</div>

# Strata 在双卡 Radeon Pro VII（gfx906）上的实测笔记

> **这不是安装教程。** 官方已经有了，而且写得比我好：
> [docs/INSTALL.md](https://github.com/Niko1221/Strata/blob/main/docs/INSTALL.md) 与
> [docs/OLDER_GPUS.md](https://github.com/Niko1221/Strata/blob/main/docs/OLDER_GPUS.md)
> 完整覆盖了 gfx906 的构建（`-DSTRATA_HIP_GFX906=ON`）。

这个仓库补的是官方文档里**没有的那部分**：**跑起来之后**——怎么测才不骗自己，以及哪些旋钮
**看着该调、其实别碰**。

全部数据来自一台机器上数天的 A/B 实测，**每一个被否决的配置都附反面证据**。我试过的设置里
大约 **80% 是负收益或没有收益**——这个比例本身才是有用的信息。

> ⚠️ **如果你是来抄配置的，先看 [`docs/07-corrections.md`](docs/07-corrections.md)。**
> 这里发布过的两条建议是错的：`--batch 2` 应该**删掉**，`--max-context 131072` **已经回退**。
> 前一条改对值 **13~16% 的专家缓存**；后一条意味着你在为一个已经不需要的槽位数量牺牲上下文。

---

## 一句话结论

| 候选 | 裁决 | 一句话理由 |
|---|---|---|
| **`--batch 2` → `parallel: 1`** | ✅ **采纳** | 生产里请求真正重叠只占 0.1~1.4%。删掉它换来 **+13~16% 专家槽**，零成本 |
| **`STRATA_PREFILL_RING=384`** | ✅ **采纳** | layer split 会把 ring 偷偷压成 96。恢复到 384 = **prefill +3.8%**，**不占常驻显存** |
| `--prefill auto:16384` | ✅ **保留** | 与 ring 384 配对。8192 与它打平；**20992 掉 25.4%**（t = −6.11） |
| `--max-context 131072` | ⚠️ **已回退** | 同一个 ctx 现在给 13,767 槽，131072 只有 12,377——删 batch 赚得比降 ctx 多 |
| `--pipeline-windows 2` | ❌ 否决 | prefill **−26.6%**，抖动放大 135 倍。而且 `--batch` 一直在静默关掉它 |
| `--conversation-cache-mib` | ⏸ **有效，但先别开** | 跨会话 55 s → 0.5 s；串行单会话每轮白付 0.5~1 s。有两路会话时才开 |
| `--lookup-chain 3` | ❌ 否决 | prose 上每请求多提 3.5 个草稿，接受率 82.1% → 79.6%，吞吐只 +0.08 tok/s |
| `--suffix-draft 0` | ❌ 否决 | echo 上 −6.7%，是噪声底的 1.7 倍。**默认值 3 在做正功** |
| `--mtp-q4 all` | ❌ 否决 | draft 层显存 **912 → 949 MiB 反向增加**。Q4 是额外加载，不是替换 |
| `--prefill-head-alias` | 🚫 不可用 | 源码硬拒绝：layer split 与 `short_read` 两条违例 |
| `--pool-workers` | 🚫 无余量 | 6 物理核，5 worker + host 已全部占满 |
| `--batch 3` | ❌ 否决 | 峰值并发只有 2；提到 3 占 0.69 GiB、少 123 个槽 |
| `--kv-grow` | 🚫 不可用 | 源码要求 `!multi_gpu`（`generate.cpp:4397`），双卡出局 |
| `--expert-cache-per-layer` | 🚫 已结案 | 本机已是 PROFILE 常驻、命中 98~99%；且它按 `slots = q·48` 改总量，不是干净的 A/B |
| `--calibrate` | 🚫 不适用 | 只标定 `pcie_frac`/`spec_min_p`/`pool_workers`/`adapt` 四项，都已定档，且不碰 prefill 管线 |
| `STRATA_EMB_REUSE_ACCOUNT=1` | 🚫 无机制 | 它仅有的两个出口都被本配置钉死（`--prefill auto:16384` 与 env ring） |
| rocBLAS 补表 | ❌ 否决 | `default` 行是标定器的判决，不是待补的空行 |

完整证据见 [`docs/04-what-not-to-tune.md`](docs/04-what-not-to-tune.md)。
两条正收益各有专文：[`docs/08`](docs/08-prefill-rings-and-chunks.md)（ring）与
[`docs/09`](docs/09-concurrency.md)（并发）。

---

## 已更正的结论（2026-10-19 复测）

这一节是这次更新的重点。旧的结论不是"有争议"，是**错了**，逐条列出：

| # | 原来写的 | 实际 | 为什么会错 |
|---|---|---|---|
| C1 | 保留 `--batch 2` | **必须删**，用 `parallel: 1` | 我自己在 §4.2 已经论证"一次一个时 batch N 白占显存"，还用 1.4%/0.1% 的重叠率证明了它——然后只用这个证据去否决 `batch 3`，没回头审 `batch 2` |
| C2 | `--max-context 131072` **已采纳** | **10-16 就回退到 163840**，本仓库 10-17 才发布 | 把"当时那次 A/B 的结论"写成了"现在的建议"，发布前没回头看生产。文档在发布当天就是过期的 |
| C3 | `auto:N` 钳在 `32768/16384/8192` | 顶档实际是 **20992**；写 `12288` 得到 `8192` | 按自己敲的参数推阶梯，没读启动横幅里的实际值 |
| C4 | 否决更大 chunk 是因为"要双倍 prompt 缓冲" | 是实测 **−25.4%**；机制是 ring 的**覆盖边界** | 把观测数据的 Simpson 悖论正确否掉了，却换上一个没测过的成本论据 |
| C5 | `--prefill-head-alias` 有 3 条违例 | 现在是 **2 条**（batch 已删），仍然拒绝 | 沿用旧配置计数 |
| C6 | 绝对值当成"当前值" | 全是 **0.1.44.1** 的数，机器已是 **0.1.45** | 升级引擎后没给数字打版本标签 |

另外四个**没写但会误导**的坑：

- **G1 进程年龄是变量**：同配置，跑了 40 h 的进程中位数只差 0.5%，但 **sd 从 7.7 涨到 20.6、跨度从 20.6 涨到 58.8**。跨重启比较前必须重启后重测基准臂。
- **G2 中文 token 不是 0.92/字**：是 **0.6 token/汉字**（53,000 字 ≈ 32K）。我按 0.92 备料，实际长度差 50%。无空格文本更离谱，能到 ~1.9/字。**别预测，读 `usage.prompt_tokens`。**
- **G3 `/metrics` 的 `spec` 不是 `--spec`**：配置 `--spec 4`，指标报 `6`（`--suffix-draft` 把验证窗口撑大了）。核对配置看 `argv`，核对行为看横幅与指标，别互相替代。
- **G4 ring 不占槽位**：96 → 384 时 `expert_slots`/`expert_cache`/`vram_free` **三项一字不差**。ring 是**请求期借槽**，所以那个 +3.8% 真的是免费的。

---

## 最该先读的一节

如果你只看一节，看 **[`docs/02-methodology.md`](docs/02-methodology.md)**；
如果再看一节，看 **[`docs/07-corrections.md`](docs/07-corrections.md)**——上面那些结论就是在那里被收回的。

> **这类硬件上的 decode 吞吐，每次重启后、以及每换一个工作负载后，都有一段约 5 个请求的
> 冷启动斜坡。**
> 从第 1 个样本开始测，得到的数字会偏低 30–40%；更糟的是，**各臂的偏差还不一样**，
> 于是建立在它之上的 A/B 会给出自信的错误结论。

我第一次 A/B 得出"无差别"，但**理由完全是错的**：臂内散布（32–44%）比要测的效应还大。
是器具太钝，不是设置中性。把这个修好之后，裁决才变得可信。

---

## 硬件与基线

| | |
|---|---|
| 显卡 | 2× AMD Radeon Pro VII 16 GB（gfx906，`sramecc-`、`xnack-`） |
| CPU | AMD Ryzen 5 2600——**6 物理核 / 12 线程**，无 AVX-512（只有 AVX2） |
| 内存 | 48 GB（4 条混插，8+16+8+16 @ 1866 MT/s） |
| 模型 | Qwen3.8-Flash-Next **IQ3_XXS**，约 47 GB，`--mmap-experts` |
| 引擎 | 现在是 **0.1.45**；下面的 r17/r18 A/B 跑在 **0.1.44.1**（`build-714`） |
| 切分 | `--layer-split auto` → 层 0–15 / 16–47，**`parallel: 1`**（无 `--batch`） |

> **版本纪律**：每个绝对值都带它来自哪个引擎版本。✓/✗ 的裁决讲的是机制，可以跨版本；
> tok/s 不行。见 [`docs/07 §C6`](docs/07-corrections.md#c6-version-labels-on-every-absolute)。

这台机器上的稳态实测值。**两列不要互相比**——负载与 prompt 长度都不同，分开列就是这意思。

| 指标 | 0.1.44.1，`--batch 2` | **0.1.45，`parallel: 1`** |
|---|---|---|
| decode（128–192 tok 负载） | 49–52（count）、56–60（echo）、42.8–43.6（prose） | 44.3–44.7（256-token 散文，负载不同） |
| prefill（≥4K，真实混合长度） | **中位 485 tok/s**（n=416） | 未重测 |
| prefill（**32K 固定语料**） | — | **中位 682.7 tok/s**（n=7，ring 384） |
| 专家槽 @ 163840 | 11,820 | **13,767** |
| 覆盖率 | 13,900 / 24,576（89.1%） | **13,952 / 24,576（91.9%）** |
| layer-split `K` | 20 | **16**（预测 57.0 ms/窗口） |

> ⚠️ **别拿"已复用请求的读取速度"当 prefill 能力。**
> 引擎报的是 `新读 token / 读取毫秒`。一个复用了 99% 前缀的请求只读 50 个 token、耗时 1350 ms，
> 报出来是 37 tok/s——那是**活太少**，不是 prefill 慢。反过来，把 21,434 tok/s 这种数字
> 当成"prefill 速度"也是错的。两种都不是容量测量。

---

## 仓库结构

```
docs/
  01-hardware-and-baseline.md   这台机器是什么，应该产出什么数字
  02-methodology.md             ★ 斜坡、A/B 协议、怎么算出你自己的分辨力
  03-readings.md                支撑每一个裁决的全部实测数据
  04-what-not-to-tune.md        ★ 逐条否决，附反面证据
  05-restart-runbook.md         ★ 以及 systemctl restart 是怎么把我的服务搞挂的
  06-reproduce.md               怎么在任何一台机器上复现
  07-corrections.md             ★ 我哪里错了，以及推翻它的证据
  08-prefill-rings-and-chunks.md  ★ layer split 后 ring 只剩 96；384 是白拿的 +3.8%
  09-concurrency.md             pipeline 窗口、`parallel: 1` 与 `2`、64 GB 到底买什么
  10-prefix-cache.md            复用要么 0.5 s 要么 55 s，从来没有"有时慢"
scripts/
  measure_steady.sh             decode：预热 + 采样，用命中率验证是否真到平台
  measure_prefill.py            prefill：每请求换 nonce、强制 `reused == 0`、数据取自 /metrics
  apply_config_safely.sh        改配置 → 断言 → 停 → 排空 → 启动 → 三道门，带自动回滚
results/
  README.md                     各列含义，以及怎么重算出文档里的每一张表
  r17-lookup-chain-8arms.csv          312 行 · --lookup-chain 3 vs 默认 · 8 臂
  r18-suffix-draft-mtp-q4-8arms.csv   312 行 · --suffix-draft 0 × --mtp-q4 all · 2×2 · 8 臂
  r19-prefill-chunk-4arms.csv         28 行 · chunk 16384 / 8192 / 20992，各 7 样本
  r20-prefix-reuse.csv                9 行 · 复用 0.48 s，被冲掉 55 s
  r21-checkpoint-eviction.csv         9 行 · 任何别的 prompt 都会丢弃 checkpoint
  r22-conversation-cache.csv          12 行 · 预算 768（失败）vs 1280（成功）
```

---

## 哪些是 gfx906 专属，哪些是通用的

**本卡 / 本构建专属**（不要假设可以照搬）：

- `--mtp-q4` 的"Q4 是额外加载"行为，取决于这个构建的加载器。
- `--prefill-head-alias` 被拒，是**这个配置**（layer split + `short_read`）的组合。
- 绝对的 tok/s 数字，以及布局搜索选出的 `K`（跨版本已经从 20 漂到 16）。
- ring 饱和的那个 chunk（本机 20992）——它由 `384 槽 × 层数` 决定，ring 或专家数一变，悬崖就挪位。

**任何 Strata 机器、以及任何在线服务的 A/B 都通用：**

- 冷启动斜坡与预热的必要性（docs/02）。
- **进程年龄是方差的输入，不是常量**——40 h 进程的散布是新进程的 2.7 倍，中位数却一样。
- 「臂内散布 ≥ 臂间差 ⇒ 噪声」这条判读规则。
- 用**两个同配置臂实测出的零假设**，而不是从方差估出来的零假设。
- **layer split 会静默把 prefill ring 压成 96**，一个环境变量就能恢复（docs/08）。
- **前缀缓存是全有或全无**——1,986 token 的小请求和 68K 的大请求一样，都会把 38K 的 checkpoint 清掉（docs/10）。
- **你的压测 prompt 本身就是那个"插进来的别的 prompt"**，会清掉生产会话的缓存。
- 重启陷阱：`ExecStop` 可能杀不掉引擎子进程（docs/05）。
- 显存是**异步回收**的——进程退出后要轮询等它真正落地。
- **一个开关可以被静默覆盖**——`--pipeline-windows` 被 `--batch` 置回 0，auto 路径连日志都不打。看横幅，别信你传的参数。

---

## 待办

- **64 GB 内存到位后实测**：目前只是从内存账（47,068 MB 物理、RssFile 40 GiB、free 348~844 MB、
  swap 1.8 GB、命中率 99.87%）**推断**它买的是稳定性而非并发。到货后要重跑会话缓存与崩溃计数才算数。
- 68K prompt 上复验 `16384 × 384` 拐点（现在只有方向，±15% 噪声）。

---

## 致谢与许可

Strata 是 [Niko1221/Strata](https://github.com/Niko1221/Strata)，MIT。
模型是 [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)，由 ISTA-DASLab 量化。
本仓库与 Strata 维护者无隶属或背书关系，仅为单个用户的实测记录。

本仓库：MIT（见 [LICENSE](LICENSE)）。
如果这里有哪个数字是错的，`results/` 里的逐请求 CSV 才是基准——请开 issue。
