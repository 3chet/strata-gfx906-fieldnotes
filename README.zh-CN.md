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

---

## 一句话结论

| 候选 | 裁决 | 一句话理由 |
|---|---|---|
| `--lookup-chain 3` | ❌ 否决 | prose 上每请求多提 3.5 个草稿，接受率 82.1% → 79.6%，吞吐只 +0.08 tok/s |
| `--suffix-draft 0` | ❌ 否决 | echo 上 −6.7%，是噪声底的 1.7 倍。**默认值 3 在做正功** |
| `--mtp-q4 all` | ❌ 否决 | draft 层显存 **912 → 949 MiB 反向增加**。Q4 是额外加载，不是替换 |
| `--prefill-head-alias` | 🚫 不可用 | 源码硬拒绝：layer split、`--batch`、`short_read` 三条违例 |
| `--pool-workers` | 🚫 无余量 | 6 物理核，5 worker + host 已全部占满 |
| `--prefill` chunk > 16384 | ❌ 否决 | 需双倍 prompt 缓冲；测出的“收益”是样本构成的假象 |
| `--max-context 163840 → 131072` | ✅ **采纳** | +557 专家槽（+4.7%），+192 覆盖对，decode 不变 |
| `--batch 3` | ❌ 否决 | 生产峰值并发只有 2；提到 3 占 0.69 GiB、反而少 123 个槽 |
| rocBLAS 补表 | ❌ 否决 | `default` 行是标定器的判决，不是待补的空行 |

完整证据见 [`docs/04-what-not-to-tune.md`](docs/04-what-not-to-tune.md)。

---

## 最该先读的一节

如果你只看一节，看 **[`docs/02-methodology.md`](docs/02-methodology.md)**。

> **这类硬件上的 decode 吞吐，每次重启后、以及每换一个工作负载后，都有一段约 5 个请求的
> 冷启动斜坡。**
> 从第 1 个样本开始测，得到的数字会偏低 30–40%；更糟的是，**各臂的偏差还不一样**，
> 于是建立在它之上的 A/B 会给出自信的错误结论。

我第一次 A/B 得出“无差别”，但**理由完全是错的**：臂内散布（32–44%）比要测的效应还大。
是器具太钝，不是设置中性。把这个修好之后，裁决才变得可信。

---

## 硬件与基线

| | |
|---|---|
| 显卡 | 2× AMD Radeon Pro VII 16 GB（gfx906，`sramecc-`、`xnack-`） |
| CPU | AMD Ryzen 5 2600——**6 物理核 / 12 线程**，无 AVX-512（只有 AVX2） |
| 内存 | 48 GB |
| 模型 | Qwen3.8-Flash-Next **IQ3_XXS**，约 47 GB，`--mmap-experts` |
| 引擎 | Strata 0.1.44.1，`build-714`，跑在 Docker 里 |
| 切分 | `--layer-split auto` 跨双卡，`--batch 2` |

这台机器上的稳态实测值：

| 指标 | 数值 |
|---|---|
| decode（短回答） | 49–52 tok/s（count）、56–60（echo）、42.8–43.6（prose） |
| **prefill（真实工作量）** | **中位 485 tok/s**（零复用且 prompt ≥4K，n=416）；长 prompt 548–620 |
| 专家缓存槽 | 163840 时 11,820 → 131072 时 **12,377** |
| 覆盖率 | 13,900 / 24,576 专家对（**91.3%**） |

> ⚠️ **别拿“已复用请求的读取速度”当 prefill 能力。**
> 引擎报的是 `新读 token / 读取毫秒`。一个复用了 99% 前缀的请求只读 50 个 token、耗时 1350 ms，
> 报出来是 37 tok/s——那是**活太少**，不是 prefill 慢。反过来，把 21,434 tok/s 这种数字
> 当成“prefill 速度”也是错的。两种都不是容量测量。

---

## 仓库结构

```
docs/
  01-hardware-and-baseline.md   这台机器是什么，应该产出什么数字
  02-methodology.md             ★ 斜坡、A/B 协议、怎么算出你自己的分辨力
  03-readings.md                支撑每一个裁决的全部实测数据
  04-what-not-to-tune.md        ★ 9 项否决，逐条附反面证据
  05-restart-runbook.md         ★ 以及 systemctl restart 是怎么把我的服务搞挂的
  06-reproduce.md               怎么在任何一台机器上复现
scripts/
  measure_steady.sh             预热 + 稳态采样，用命中率验证是否真的到了平台
  apply_config_safely.sh        改配置 → 断言 → 停 → 排空 → 启动 → 三道门，带自动回滚
  audit-redaction.ps1           脱敏审计器（提交前跑，也可被别人复核你的脱敏）
results/
  README.md                     各列含义，以及怎么重算出文档里的每一张表
  r17-lookup-chain-8arms.csv          312 行 · --lookup-chain 3 vs 默认 · 8 臂
  r18-suffix-draft-mtp-q4-8arms.csv   312 行 · --suffix-draft 0 × --mtp-q4 all · 2×2 · 8 臂
```

---

## 哪些是 gfx906 专属，哪些是通用的

**本卡 / 本构建专属**（不要假设可以照搬）：

- `--mtp-q4` 的“Q4 是额外加载”行为，取决于这个构建的加载器。
- `--prefill-head-alias` 被拒，是**这个配置**（split + batch + short-read）的组合，不是卡的属性。
- 绝对的 tok/s 数字。

**任何 Strata 机器、以及任何在线服务的 A/B 都通用：**

- 冷启动斜坡与预热的必要性（docs/02）。
- 「臂内散布 ≥ 臂间差 ⇒ 噪声」这条判读规则。
- 用**两个同配置臂实测出的零假设**，而不是从方差估出来的零假设。
- 重启陷阱：`ExecStop` 可能杀不掉引擎子进程（docs/05）。
- GPU 显存是**异步回收**的——进程退出后要轮询等它真正落地。

---

## 致谢与许可

Strata 是 [Niko1221/Strata](https://github.com/Niko1221/Strata)，MIT。
模型是 [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)，由 ISTA-DASLab 量化。
本仓库与 Strata 维护者无隶属或背书关系，仅为单个用户的实测记录。

本仓库：MIT（见 [LICENSE](LICENSE)）。
如果这里有哪个数字是错的，`results/` 里的逐请求 CSV 才是基准——请开 issue。
