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
>
> **2026-10-23 还有一条更大的更正：decode 那个数一直是错的。** 这个仓库花了四天论证
> "更大的模型只跑 38 tok/s，所以升级亏了 14%"。38 出自一个把六个不相关题目轮流跑的脚本，
> **前缀是冷的、复用率 0%**。同一个引擎在同一会话里连续追问是 **44~48 tok/s**，最高 49。
> 用正确的尺子量，这次模型升级是净赚的。见 [`docs/12-multiturn-probe.md`](docs/12-multiturn-probe.md)。

---

## 2026-11-02 这次更新，五句话说清

| | |
|---|---|
| **最后一个旋钮** | `--aux-cpus auto` 值 **+1.26%**，已进生产。它不让 pool 变快——它让 host 线程不再和 8 个驱动线程挤一个核。`--pool-tasks 64` 与 `STRATA_POOL_SPIN_US=50000` 都**更慢** |
| **撤回一个立项** | 「把 CPU pool 与 GPU 做成两段式重叠，值 +18~27%」——**代码里早就做了**（`expert_source.cpp:3720`），而且上限只有 **+6~7%**，因为 CPU 那部分有 67% 结构性暴露。是撤销，不是延期 |
| **测量方法纠错** | 两个标准手段分辨不了 1~3%：跨重启的 decode A/B（爬坡值 **3.7 tok/s**，且是**十分钟**级不是五请求级）、以及窗口的**任何单项**分量。四分量求和、同进程测：可重现到 **0.19~0.57%** |
| **一个关于频率的负结果** | decode 有 56% 的采样时间停在 DPM **最低档**。强制 `high` 让显存锁满 1000 MHz、高频档时间近三倍——decode **46.75 → 46.10**。也不受频率限制 |
| **社区 kernel** | 公开 fork 的三个 gfx906 补丁：**锚点 0 命中**，因为机制本引擎已内建且更严格（`native_gdn.cu`、`native_mmvq.cu`）。唯一真缺口是没被使用的 `sdot4`/`v_dot2`，而它只在 Q4_0 上才划算 |

专文：[`docs/14`](docs/14-host-side-switches.md)（三个旋钮与两个说谎的仪器）·
[`docs/15`](docs/15-why-decode-stops.md)（天花板，以及四条不成立的解释）。

> 说明：10-23 到 11-02 之间还发生了若干变更（引擎 0.1.48 → **0.1.55**、量化 IQ3_XXS → **IQ3_S**、
> 内存 48 → **80 GB**、并发 `parallel: 1` → **`2`**、ctx → 204800），它们没有单独成文，
> 下面「硬件与基线」按**现状**更新，历史表保留原版本标注。

---

## 2026-10-23 这次更新，五句话说清

| | |
|---|---|
| **引擎** | 0.1.46 → **0.1.48.1**（上游 v0.2.1 → v0.2.3.1，428 提交）。decode 持平，prefill −2%；编译要补 **2 个上游漏掉的 HIP 符号** |
| **真正的收益** | 长会话被打断后再回来：**69.8 s → 3.2 s**。会话缓存终于能用了——旧的"22 MB/s，永远别开"量的是 0.1.45 |
| **尺子修好了** | decode 是 **44~48**，不是 38。六题轮转量的是冷前缀，真实用法复用 99% |
| **长上下文** | prefill **随长度上升**：32K 655、68K 680、**130K 715**。55K 会话里每次追问 **4 秒** |
| **DFlash2** | 这里用不了，而且不是你以为的原因：引擎硬限"单卡 + CLI"（不许 `--serve`／`--batch`／layer split） |

完整记录：[`docs/12`](docs/12-multiturn-probe.md) · [`docs/13`](docs/13-engine-0.1.48.md)。

---

## 一句话结论

| 候选 | 裁决 | 一句话理由 |
|---|---|---|
| **`--batch 2` → `parallel: 1`** | ✅ **采纳** | 生产里请求真正重叠只占 0.1~1.4%。删掉它换来 **+13~16% 专家槽**，零成本 |
| **`STRATA_PREFILL_RING=384`** | ✅ **采纳** | layer split 会把 ring 偷偷压成 96。恢复到 384 = **prefill +3.8%**，**不占常驻显存** |
| `--prefill auto:16384` | ✅ **保留** | 与 ring 384 配对。8192 与它打平；**20992 掉 25.4%**（t = −6.11） |
| `--max-context 131072` | ⚠️ **已回退** | 同一个 ctx 现在给 13,767 槽，131072 只有 12,377——删 batch 赚得比降 ctx 多 |
| `--pipeline-windows 2` | ❌ 否决 | prefill **−26.6%**，抖动放大 135 倍。而且 `--batch` 一直在静默关掉它 |
| `--conversation-cache-mib` | ⛔ **已作废** | 别再手配。0.1.45 上它 22 MB/s、必撞 60 s watchdog；**0.1.48 在启动时按空闲内存自定容量**，停泊 1.5~4.1 GB/s。默认就开着，4 个会话 |
| `--lookup-chain 3` | ❌ 否决 | prose 上每请求多提 3.5 个草稿，接受率 82.1% → 79.6%，吞吐只 +0.08 tok/s |
| `--suffix-draft 0` | ❌ 否决 | echo 上 −6.7%，是噪声底的 1.7 倍。**默认值 3 在做正功** |
| `--mtp-q4 all` | ❌ 否决 | draft 层显存 **912 → 949 MiB 反向增加**。Q4 是额外加载，不是替换 |
| `--prefill-head-alias` | 🚫 不可用 | 源码硬拒绝：layer split 与 `short_read` 两条违例 |
| `--pool-workers` | 🚫 无余量 | 6 物理核，5 worker + host 已全部占满。超过 5 之后多出来的 worker 拿到 `core = -1` 并**静默不绑核**——那不是实验，是抛硬币 |
| **`--aux-cpus auto`** | ✅ **采纳** | 四分量窗口总和 **−1.26%**，两次可重现。把 27 个驱动线程移出 host 核（绑定线程 9 → 1）；收益落在 `wait` 与 `commit`，**不在 `pool`** |
| `--pool-tasks 64` | ❌ 否决 | `pool + plan` **+8.2%**。task 的单位是**行**（每层约 26,880 行）不是专家，18 个已经只剩一个 task 的尾巴——调细只把原子争用放大 3.5 倍 |
| `STRATA_POOL_SPIN_US=50000` | ❌ 否决 | 叠加在 `--aux-cpus auto` 之上 **+0.62%**。worker 持续自旋会占住核；20 ms 默认值是对的 |
| `--batch 3` | ❌ 否决 | 峰值并发只有 2；提到 3 占 0.69 GiB、少 123 个槽 |
| `--kv-grow` | 🚫 不可用 | 源码要求 `!multi_gpu`（`generate.cpp:4397`），双卡出局 |
| `--kv-resident 40960` | ❌ 否决 | **+3.9% 槽换 −6.9% 解码**。长上下文每生成一个 token 要读约 3.3 GiB KV 走 PCIe ⇒ 掉到个位数 tok/s。（它还顺带产出了"KV 只有 0.47 GiB"这个错数，真值是 **8.44 GiB**，见 [`docs/07`](docs/07-corrections.md) C13） |
| `--expert-cache-per-layer` | 🚫 已结案 | 本机已是 PROFILE 常驻、命中 98~99%；且它按 `slots = q·48` 改总量，不是干净的 A/B |
| `--calibrate` | 🚫 不适用 | 只标定 `pcie_frac`/`spec_min_p`/`pool_workers`/`adapt` 四项，都已定档，且不碰 prefill 管线 |
| `--prefill-pipe 2` | ❌ 否决 | 32K prompt 从 46 s 变 **385 s**（prefill −88%），decode 无损。和 `--pipeline-windows` 同一族，R 必须标定不能猜 |
| `--spec-min-p 0.5` | ❌ 否决 | 接受率 **0.845 → 0.720**。调低让草稿窗口更宽，可纯 greedy 下被拒的草稿全是白算 |
| `--mtp-q4 proj` | ❌ 否决 | 槽位 **11,207 → 11,189**：省下来的显存不够跨过一个槽的粒度，量化误差还拉低草稿质量 |
| `STRATA_IO_PREFETCH=1` | ❌ 否决 | 两臂 decode 完全相同（38.15），槽还**少 33 个**——prefetch 缓冲是从专家池里扣的。只在 pack 不能全驻留时才对 |
| `STRATA_SPEC_COST=1` | 🚫 未检出 | 8K +2.4%、55K +1.5%，都在 ±4~8% 噪声底内，且两次都是"前两轮好看、第三轮回落"。不定档 |
| `--expert-cache 11240`（固定） | ✅ **采纳** | `auto` 每次重启自算（实测 11,049 / 11,189 / 11,240 三种），A/B 前必须钉死 N。注意 N 是**上限**：显存优先，某臂可能落在低 33 槽 |
| DFlash2 drafter | 🚫 **不可用** | `generate.cpp:5478` 硬限单卡 + CLI：`--serve`、`--batch`、layer split 任一成立即关闭。另外显存还差 330 MiB，它要的 hidden state 分布在两张卡上 |
| Q4_0 / IQ4_XS 量化档 | ⛔ **已结案** | IQ4_XS 实测 **−14~18%**。Q4_0：专家 blob ×1.83 ⇒ pack 约 **88.8 GB**，而可用页缓存只有约 **67 GB**，槽位 **−45%**、`pool + plan` 翻倍 ⇒ 预期 **25~32 tok/s**。这是质量换速度的交易，不是提速——见 [`docs/15 §5`](docs/15-why-decode-stops.md) |
| `STRATA_EMB_REUSE_ACCOUNT=1` | 🚫 无机制 | 它仅有的两个出口都被本配置钉死（`--prefill auto:16384` 与 env ring） |
| rocBLAS 补表 | ❌ 否决 | `default` 行是标定器的判决，不是待补的空行 |

完整证据见 [`docs/04-what-not-to-tune.md`](docs/04-what-not-to-tune.md)。
三条正收益各有专文：[`docs/08`](docs/08-prefill-rings-and-chunks.md)（ring）、
[`docs/09`](docs/09-concurrency.md)（并发）与 [`docs/10`](docs/10-prefix-cache.md)（会话缓存）。

---

## 已更正的结论（2026-10-20 复测 · 10-23 续三条）

这一节是这次更新的重点。旧的结论不是"有争议"，是**错了**，逐条列出：

| # | 原来写的 | 实际 | 为什么会错 |
|---|---|---|---|
| C1 | 保留 `--batch 2` | **必须删**，用 `parallel: 1` | 我自己在 §4.2 已经论证"一次一个时 batch N 白占显存"，还用 1.4%/0.1% 的重叠率证明了它——然后只用这个证据去否决 `batch 3`，没回头审 `batch 2` |
| C2 | `--max-context 131072` **已采纳** | **10-16 就回退到 163840**，本仓库 10-17 才发布 | 把"当时那次 A/B 的结论"写成了"现在的建议"，发布前没回头看生产。文档在发布当天就是过期的 |
| C3 | `auto:N` 钳在 `32768/16384/8192` | 顶档实际是 **20992**；写 `12288` 得到 `8192` | 按自己敲的参数推阶梯，没读启动横幅里的实际值 |
| C4 | 否决更大 chunk 是因为"要双倍 prompt 缓冲" | 是实测 **−25.4%**；机制是 ring 的**覆盖边界** | 把观测数据的 Simpson 悖论正确否掉了，却换上一个没测过的成本论据 |
| C5 | `--prefill-head-alias` 有 3 条违例 | 现在是 **2 条**（batch 已删），仍然拒绝 | 沿用旧配置计数 |
| C6 | 绝对值当成"当前值" | 全是 **0.1.44.1** 的数，机器已是 **0.1.45** | 升级引擎后没给数字打版本标签 |
| C7 | `--conversation-cache-mib` **保持关闭**，理由是"生产是串行单会话" | 客户端**确实是多会话**（这半条成立）：该前缀分组后恢复 53.4 s → **14.4 s（−73%）**。但开关上线一小时后被撤掉 | 把"`in_tokens` 只增"当成"只有一个会话"。多会话交错时，每个前缀自己也是单调增的——我按时间排序得出"串行"，从没按前缀分组 |
| C8 | KV 约 **3.87 GiB**，值得拿去换专家槽 | 先改成 **≈0.47 GiB**，10-23 再改成 **8.44 GiB**——两次都错，真值是 160K / `q4_0` / 48 层下的第二大显存占用 | 第一次拿 528 B/cell × 层 × 格硬推，高估 8 倍；第二次把"每 ~16K token 的那一片"当成了全量，低估 18 倍 |
| C11 | 会话缓存**永远不能开**：22 MB/s ⇒ 每次恢复都会撞穿 watchdog | 那是 **0.1.45** 的行为。**0.1.48 启动时按空闲内存预留**，停泊 1.5~4.1 GB/s，46K 会话被打断后恢复 **3.2 s**（原 69.8 s）。默认开启，别再手配 `-mib` | 用旧版本的失效模式给一个已经重写的功能下了永久判决；而且 0.1.46 的日志里**一条 conversation cache 都没有**，那功能当时根本没启用，22 MB/s 量的不是它 |
| C12 | decode 只有 38，大模型结构性慢 14%，追不回 | **38 是冷前缀的产物**：六题轮转 ⇒ 复用 0%、命中 0.88。同一会话连续追问 ⇒ 复用 99%、命中 0.96、decode **44~48**（8K 最高 49） | 把"比对参数的尺子"当成了"描述生产的尺子"。轮转法故意不让任何一臂享用别臂预热的前缀——这对 A/B 完全正确，对报速完全错误，偏差约 13% 且方向固定 |
| C13 | 因为 KV 只有 0.47 GiB，所以"没有东西可以拿去换槽位" | **8.44 GiB**，是第二大显存占用：专家池 20.62 + dense 1.43 + **KV 8.44** + 其他 0.56 = 31.05。兑换率 **每 10K ctx ≈ 0.53 GiB ≈ 280 槽** | 0.47 GiB 大约是"每 1.6 万 token"的一片，被当成了全量记下来。结论也跟着反了：确有 5.28 GiB 可交易——只是这笔交易不值得做（砍 60K 上下文换 +1,720 槽），但那是在**看得见分母**之后做的判断 |
| C9 | `reading the prompt: 103,976 of 103,983` 意为读了 103,976 个 token（≈3,800 tok/s） | 那个数是**已复用**数，实际只读 **7** 个；真实 103K 全量 prefill 是 **194 s、535 tok/s** | 把进度显示当测量读数，和 G3 同一类错。查一眼 `/metrics` 的 `reused` / `prompt_read` 就能否掉 |
| C10 | 23K 的 A/B 够用来定缓存预算（"~20.4 KB/token × 2 条 100K"） | **不够**：566 MB 停泊 6.7 s，2.24 GiB 要 **72 s**，撞穿 60 s watchdog，引擎死在 `parking` 阶段 | 只测了便宜的那一档就外推。停泊速率过 ~600 MB 后从 **84 掉到 22 MB/s**（内核开始回收专家页），成本不再线性；而"会话越长收益越大"和"会话越长越必死"是同一件事 |

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
| 内存 | **80 GB**（32+16+16+16 @ 2133 MT/s）。r17~r33 那时是 48 GB（8+16+8+16 @ 1866） |
| 模型 | Qwen3.8-Flash-Next **IQ3_S**，约 48.5 GB mmap。r17~r33 测的是 **IQ3_XXS**，约 47 GB |
| 引擎 | 现在是 **0.1.55**。r27~r33 跑 0.1.46/0.1.48；r17/r18 跑 0.1.44.1（`build-714`） |
| 切分 | `--layer-split auto` → 层 0–25 / 26–47，**`parallel: 2`**。r17~r33 是 `parallel: 1` |

**当前基线**（0.1.55，IQ3_S，`parallel: 2`，900-token 请求）：单流 **47.8 tok/s**（命中 0.975），
双流合计 **82~84 tok/s**（1.95×）。prefill：8K 485、16K 505~520、20K 570、33K 654、**74K 820~865**。
专家槽 11,958，`vram_free` 848 MiB。单流这个数**重启后要约 10 分钟**才能爬到位——见
[`docs/14 §1`](docs/14-host-side-switches.md)。

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
  11-long-context-and-verify-timeout.md  ★ 10 万 token 会话为什么死，以及那句会骗人的日志
  12-multiturn-probe.md         ★ decode 是 44~48 不是 38——旧脚本量的是冷前缀
  13-engine-0.1.48.md           ★ 升到 0.1.48.1：代价是什么，以及 70 s → 3 s 的收益
  14-host-side-switches.md      ★ 最后三个主机侧旋钮，以及两个在说谎的仪器
  15-why-decode-stops.md        ★ 天花板：四条不成立的解释，两条成立的
scripts/
  measure_steady.sh             decode：预热 + 采样，用命中率验证是否真到平台
  measure_prefill.py            prefill：每请求换 nonce、强制 `reused == 0`、数据取自 /metrics
  multiturn_probe.py            ★ 同前缀多轮探针：逐轮读 reused / 命中率 / decode
  apply_config_safely.sh        改配置 → 断言 → 停 → 排空 → 启动 → 三道门，带自动回滚
results/
  README.md                     各列含义，以及怎么重算出文档里的每一张表
  r17-lookup-chain-8arms.csv          312 行 · --lookup-chain 3 vs 默认 · 8 臂
  r18-suffix-draft-mtp-q4-8arms.csv   312 行 · --suffix-draft 0 × --mtp-q4 all · 2×2 · 8 臂
  r19-prefill-chunk-4arms.csv         28 行 · chunk 16384 / 8192 / 20992，各 7 样本
  r20-prefix-reuse.csv                9 行 · 复用 0.48 s，被冲掉 55 s
  r21-checkpoint-eviction.csv         9 行 · 任何别的 prompt 都会丢弃 checkpoint
  r22-conversation-cache.csv          12 行 · 预算 768（失败）vs 1280（成功）
  r23-conversation-cache-multiplexed.csv  12 行 · 4 臂 · 同一个开关在多会话客户端上的表现
  r24-kv-resident.csv                 2 行 · --kv-resident 40960：+3.9% 槽，−6.9% 解码
  r25-long-context-restore.csv        3 行 · 死在 104K 的那条请求，以及一条没死的
  r26-conversation-cache-rollback.csv 5 行 · 为什么 r23 的开关又关了：过 ~600 MB 后 84 → 22 MB/s
  r27-stage-tuning-arms.csv           10 臂 · 10-23 那轮：3 个采纳的旋钮 + 5 条否决
  r28-fixed-cache-io-prefetch.csv     2 臂 · STRATA_IO_PREFETCH：decode 一样，槽少 33
  r29-long-prefill.csv                4 行 · 66K 与 123K prompt：prefill 随长度上升（675 → 716）
  r30-multiturn-probe.csv             11 行 · 同前缀会话：8K → 47.6、55K → 44.8 tok/s
  r31-interleaved-session.csv         8 行 · 46K 会话被 3K 插话打断：69.8 s vs 3.2 s
  r32-v148-abba.csv                   6 行 · 0.1.46 vs 0.1.48（含 SPEC_COST 0/1），ABBA，每臂 3 轮
  r33-v148-prefill-68k.csv            4 行 · "prompt path 借用专家槽"那 −2% prefill 的代价
  r34-host-side-switches.csv          5 臂 · 最后三个旋钮，判据是四分量窗口总和
  r35-pool-tasks-and-plan.csv         2 臂 · --pool-tasks 64：目标分量 +8.2%
  r36-pool-exposure.csv               2 臂 · worker 5 → 2：CPU 专家份额有 67% 暴露在关键路径
  r37-gpu-clock.csv                   2 臂 × 110 采样 · DPM auto vs 强制 high：decode 无变化
```

---

## 哪些是 gfx906 专属，哪些是通用的

**本卡 / 本构建专属**（不要假设可以照搬）：

- `--mtp-q4` 的"Q4 是额外加载"行为，取决于这个构建的加载器。
- `--prefill-head-alias` 被拒，是**这个配置**（layer split + `short_read`）的组合。
- 绝对的 tok/s 数字，以及布局搜索选出的 `K`（跨版本已经从 20 漂到 16）。
- ring 饱和的那个 chunk（本机 20992）——它由 `384 槽 × 层数` 决定，ring 或专家数一变，悬崖就挪位。
- **DPM 把 decode 当成轻负载**——56% 的采样停在 `sclk` 最低档、43% 停在 `mclk` 最低档。
  强制 `high` 让高频档时间近三倍，decode 变化是 **−1.4%**。你的卡是否升频值得花 5 分钟查一次，
  两边都不要假设（`docs/15 §3`）。

**任何 Strata 机器、以及任何在线服务的 A/B 都通用：**

- 冷启动斜坡与预热的必要性（docs/02）。
- **进程年龄是方差的输入，不是常量**——40 h 进程的散布是新进程的 2.7 倍，中位数却一样。
- 「臂内散布 ≥ 臂间差 ⇒ 噪声」这条判读规则。
- 用**两个同配置臂实测出的零假设**，而不是从方差估出来的零假设。
- **重启会抹掉 3% 以下的效应，而"丢掉 5 个请求"救不回来**——本机的爬坡是**十分钟**级的进程效应、
  值 **3.7 tok/s**，不是五请求级的热身。能在同一进程里 A/B 就别重启；不能，见下一条（`docs/14 §1`）。
- **窗口分解是一个测量，不是四个**。pool 变快会让 GPU 更早开跑，于是 `wait` 上升把收益吃掉，
  所以任何单项都会随命中率漂：同一个开关先读出 **−5.1%**、再读出 **+3.0%**。
  要把 `wait + pool + plan + staging + commit` 加起来，并把**臂内散布写在臂间差旁边**（`docs/14 §2`）。
- **动手做重叠之前，先确认引擎是不是已经提前发布了**。只看调用点相邻的两行、不去追一层目录下的
  `pool` 实现，就会凭空造出一个「+18~27%」的立项——而那里有注释写着它已经做了，真实上限 +6~7%
  （`docs/07 §C14`）。
- **layer split 会静默把 prefill ring 压成 96**，一个环境变量就能恢复（docs/08）。
- **前缀缓存是全有或全无**——1,986 token 的小请求和 68K 的大请求一样，都会把 38K 的 checkpoint 清掉（docs/10）。
- **你的压测 prompt 本身就是那个"插进来的别的 prompt"**，会清掉生产会话的缓存。
- **`reading the prompt: N of M` 里的 N 是"已复用"，不是"已读取"**——103,976 of 103,983 意为只读了
  **7** 个 token。日志是进度显示，`/metrics` 才是测量（docs/11）。
- **`verify: timed out` 背后那个 5 秒硬编码，关掉比留着更糟**：该修的是 GPU 为什么慢，不是检查
  （docs/11）。
- **缓存的裁决是对"工作负载"的裁决，而负载会变**——"串行客户端，停泊白费"周一成立、周三就不成立，
  同一个二进制、同一份配置（docs/07 §C7）。裁决旁边必须写上当时的流量形状。
- 重启陷阱：`ExecStop` 可能杀不掉引擎子进程（docs/05）。
- 显存是**异步回收**的——进程退出后要轮询等它真正落地。
- **一个开关可以被静默覆盖**——`--pipeline-windows` 被 `--batch` 置回 0，auto 路径连日志都不打。看横幅，别信你传的参数。

---

## 待办

- **prefill 的 28 段从未拆开看过**。tg 那条线已经封死（见 `docs/15` §6），但官方源码自己写着
  「32K 时 `qsa attn` 占 prompt 的 21%、瓶颈是 instruction issue、只跑到 3.4 TFLOP/s」。
  跑一次 `STRATA_PREFILL_TIMING=1` 就能定：某段占比 **≥20% 才值得自研 kernel，<10% 直接放弃**。
  它只影响长 prompt 的首字等待，不影响 tg。
- **CPU 侧只剩一种解法，不是两种**：换同插槽更强的 CPU（+15~18%，1 天，可回滚；Zen3 同时去掉
  256-bit 拆分和跨 CCX，所以这个数大概率是下限）。**手写 AVX2 专家 kernel 已封案** ——
  见 [`docs/15` §7](docs/15-why-decode-stops.md)：旧的「24.5% of peak」是拿 int8 实测除 FP32 峰值，
  且 CPU 只占窗口 14.3%，而这套 ISA 上的软件杠杆已经全部拉满。
- **只有一个数能重开这个话题**：在本机测出 IQ2_S/Q2_0 的真实 GB/s（纯 CPU bench）。实测
  **1.19 GB/s/核**，而源码注释给 IQ 系的上限是 **~5 GB/s/核**。若这 4 倍为真，说明瓶颈全在指令集，
  那才值得花 2~3 周。
- 重新学一次 expert profile（预期 1~2%）：流量分布变了，旧的 `learned.bin` 就过时了。

---

## 致谢与许可

Strata 是 [Niko1221/Strata](https://github.com/Niko1221/Strata)，MIT。
模型是 [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)，由 ISTA-DASLab 量化。
本仓库与 Strata 维护者无隶属或背书关系，仅为单个用户的实测记录。

本仓库：MIT（见 [LICENSE](LICENSE)）。
如果这里有哪个数字是错的，`results/` 里的逐请求 CSV 才是基准——请开 issue。
