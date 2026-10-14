# SUSFS LKM AutoLoader (Auto-Build)

自动追踪上游 [inforcqb/susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm) 的 release，
把其中的 `susfs_guard_lkm-*.ko`（全部内核变体）与 `susfs_insmod` 加载器重新封装成可直接
刷入 **KernelSU / APatch** 的模块 ZIP。

- 模块 id：`susfs_lkm_autoloader`（单变体 `..._<kmi>`，无校验包再加 `_nocheck`）
- 上游为 **GPL-2.0**，每个模块包内都带 `LICENSE`（全文）与 `provenance.json`（溯源）
- 加载时机：**`late_start`（`service.sh`）**，用上游自带的 `susfs_insmod`，非 `ksud insmod`

> 本项目（打包脚本、模块脚本与本文档）由 AI（TraeCode）协作生成与维护。
> 涉及内核级操作，请在可救砖的设备上自行审阅、测试。

## 致谢 / Credits

| 角色 | 作者 |
| --- | --- |
| LKM 本体（`susfs_guard_lkm-*.ko`、`susfs_insmod`） | [@inforcqb](https://github.com/inforcqb) — [inforcqb/susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm)（GPL-2.0） |
| 加载方案参考（`late_start` 加载、`susfs_insmod` 用法） | [@matsuzaka-yuki](https://github.com/matsuzaka-yuki) |
| 封装 / 打包 / 文档 | [@Odda2632](https://github.com/Odda2632) & TraeCode |

本仓库只做上游 release 资产的自动拉取与重新封装，不改动任何内核代码。

## 快速使用

1. **确认内核**：`uname -r`，看内核串里的 KMI（形如 `android12-5.10`）。
   - 带 `-androidNN-` → 刷**与该 KMI 完全对应的单变体包**（如 `...-android12-5.10.zip`）。
   - **不带** `-androidNN-`（魔改/厂商内核，如 `5.10.x-moon-xxxx`）→ 刷 **`-nocheck`** 包。
2. 在管理器里刷入后重启（加载在 `late_start` 进行）。
3. 打开模块卡片看状态（脚本把结果写回 `module.prop` 描述，如
   `||STATUS: 已加载 susfs_guard_lkm-android12-5.10.ko @ 10-12 20:30`）。

**最安全的测试方式**：点模块的 **操作 / Action** 按钮 —— 立即手动加载一次并回显结果，
不重启、无砖风险（成功后守卫自动清除）。

> 只装**一个**包。同时装通用包与 `-nocheck` 包会互相干扰（详见下方守卫一节）。

## 工作原理

```
GitHub Actions（每天 03:00 UTC / 手动 / 改动 build.sh|template|LICENSE 时）
   └─ build.sh
        ├─ 查上游 release（latest 或指定 tag）并取该 tag 的 commit
        ├─ 下载 susfs_guard_lkm-*.ko + susfs_insmod（逐个比对 API 给出的 sha256）
        ├─ 用 template/ 生成 module.prop 与开机脚本，附上 LICENSE 与 provenance.json
        ├─ 出厂自检：文件齐备 / sh 语法 / 回归判据，不通过则拒绝出包
        └─ 打 通用包 + 每个 KMI 的单变体包 + 无校验包
   └─ 上传 Artifact + 创建/更新本仓库 Release（上游新版本额外开 Issue 通知）
```

设备侧（`service.sh`，`late_start`）：

1. 安装时 `customize.sh` 给 `susfs_insmod` 与脚本加可执行位，并清掉上次的防砖标记。
2. 读真实内核串 `/proc/sys/kernel/osrelease`（`uname` 可能被其它 SUSFS 实现伪造）。
3. **叠加保护**：若检测到已有 SUSFS → 不加载（两个叠加会 panic）。
4. 选 `.ko`：通用包按内核串里的 `androidNN` + 主.次 匹配；单变体包用它内置的那份。
5. `susfs_insmod <ko> expose_proc=1` 加载（参数不被接受则退回无参）。
6. 结果写回模块描述；开机完成后 `boot-completed.sh` 清除守卫。

## 为什么是 `late_start`，以及它的局限

这个 `.ko` 在加载时要读取 KernelSU 自身状态（例如 `kernel-umount` 的应答）。
**开机早期（`post-fs-data`）KernelSU 还没准备好，此时加载会把设备卡在第一屏**；
等到 `late_start`（系统已起到 Zygote 之后）再加载即可正常——这也正是管理器里手动点
"操作"按钮能成功的时点。同理，脚本统一用上游自带的 `susfs_insmod`，不用 `ksud insmod`。

**局限（加载晚 = 隐藏也晚）**：SUSFS 的隐藏只在加载**之后**才生效，所以

- 开机早期（内核 → Zygote 之前）已运行的检查、已枚举过的挂载表，不受隐藏保护；
- 在 `late_start` 之前完成的挂载，不会被 `sus_mount` 隐藏。

这是"加载越早越易被检测、越晚越不容易卡屏"的两难；本项目选择晚，优先保证能开机。

## 目录与包结构

```
.
├── .github/workflows/build.yml   # 定时/手动/改动触发 → 打包并发布或更新 Release
├── build.sh                      # 打包脚本（本地也能直接跑）
├── LICENSE                       # GPL-2.0 全文（会打进每个模块包）
├── template/
│   ├── module.prop               # 元信息模板（__ID__ / __VERSION__ / __AUTHOR__ …）
│   ├── _lib.sh                   # 共享库：叠加探测 / 守卫 / 取内核串 / 调加载器
│   ├── service.sh                # 通用包：按 KMI 匹配并加载
│   ├── service-variant.sh        # 单变体：先校验内核串再加载
│   ├── service-variant-nocheck.sh# 单变体：跳过内核校验
│   ├── boot-completed.sh         # 开机完成 → 清除守卫
│   ├── action.sh                 # "操作"按钮 → 手动加载并回显
│   └── customize.sh              # 安装时授权 + 清标记
└── README.md
```

打包后的模块 ZIP（以 `android12-5.10-nocheck` 为例）：

```
module.prop   LICENSE   provenance.json   skip_mount
service.sh    boot-completed.sh   action.sh   customize.sh   _lib.sh
loader/susfs_insmod
loader/susfs_guard_lkm-android12-5.10.ko
```

## 关键实现点

### `_lib.sh`（三个 service 脚本共用）

- **叠加探测 `susfs_present`**：优先看 `/sys/module/susfs_guard_lkm`（`hide_modules`
  无法从 `/sys/module` 抹掉自己），再看一批 `/proc/susfs*` 控制节点，最后才查
  `/proc/modules`。早期版本只看 `/proc/susfs` / `/proc/susfs_mnt_id`，而上游 v2.3.0
  这两个节点都不建 → 每次开机都误判"没有 SUSFS" → 重复加载 → panic。
- **防砖守卫**：`guard_begin` 把 **(boot_id, 时间)** 写入 `/data/adb/susfs_lkm.guard`，
  由 `boot-completed.sh` 清除；下次开机的 boot_id 不同 = 上次确实没起来 → 自动禁用
  （`/data/adb/susfs_lkm.disabled`），最多只卡一次、不会无限重启。同一 boot_id 则说明
  是"同一台机器上另一个包刚写过守卫" → 本包让位、不加载（避免叠加），且不误禁用自己。

### `service.sh` / 两个变体

流程同上。变体包把复制的模板里的 `__KO_NAME__` 换成内置 `.ko`，并（带校验版）要求内核串
同时含 `__AND__`（如 `android12`）与 `__MM__`（如 `5.10`）；`-nocheck` 版不校验内核串，
只保留叠加保护。通用包若匹配不到精确 KMI、且包内只有**一个** `.ko`，就用那一份；
否则拒绝猜测。

### `kmi.force`（手工强制指定内核变体）

在内核串识别不准时可覆盖自动匹配：在模块目录放一个 `kmi.force`，写一行 KMI 即可。

```bash
adb shell su -c 'echo android12-5.10 > /data/adb/modules/susfs_lkm_autoloader/kmi.force'
```

若 `kmi.force` 指定的 `.ko` 不在包内，脚本拒绝加载（不会退化成猜测）。

### `action.sh` / `customize.sh`

- Action：`SUSFS_FORCE=1` → 清禁用标记 → 立即加载一次 → 回显结果与日志尾部。
- 安装：`set_perm_recursive` + `set_perm` 补可执行位（KSU 解压非脚本文件只给 `0644`），
  并删除 `/data/adb/susfs_lkm.{guard,disabled}`，使每次重刷都重新尝试。

### 打包侧校验

`build.sh` 下载时用上游 API 的 `.digest` 逐个比对 sha256；出包前自检每个 zip 必须含
`module.prop` / `service.sh` / `_lib.sh` / `LICENSE` / `loader/susfs_insmod` 等，且各脚本
`sh -n` 语法通过、不再出现已废弃的 `/proc/susfs` 判据，否则**拒绝产出 Release**。

## 配置项

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `UPSTREAM_REPO` | `inforcqb/susfs4ksu-lkm` | 上游仓库 `owner/repo` |
| `AUTHOR` | `Odda2632 & TraeCode` | 写入 `module.prop`；脚本自动追加 `(LKM by <上游 owner>)` |
| `NOCHECK_VARIANTS` | `android12-5.10` | 额外产出的无校验变体，空格分隔 |
| `GITHUB_TOKEN` / `GH_TOKEN` | 空 | 走认证请求，避免 API 限流 |

```bash
chmod +x build.sh
./build.sh                 # 取上游最新 release
./build.sh v2.3.0-r18.1    # 指定 tag
```

`out/` 会得到：通用包、各 KMI 单变体包、`-nocheck` 包、`provenance-<tag>.json`、`SHA256SUMS`。

## 许可与溯源

上游与本仓库同为 **GPL-2.0**（全文见 [LICENSE](file:///workspace/susfs-lkm-loader/LICENSE)，
每个模块包内同样附带）。`provenance.json` 记录上游 仓库 / tag / commit 与本包内每个
二进制的 sha256：

```json
{
  "schema": 1,
  "generator": "build.sh (Odda2632 & TraeCode, AI-assisted)",
  "module":   { "id": "susfs_lkm_autoloader_android12_5_10_nocheck",
                "version": "v2.3.0-r18.1", "versionCode": 203001801 },
  "upstream": { "repo": "inforcqb/susfs4ksu-lkm", "tag": "v2.3.0-r18.1",
                "commit": "4636014b…", "license": "GPL-2.0",
                "url": "https://github.com/inforcqb/susfs4ksu-lkm/tree/v2.3.0-r18.1" },
  "artifacts": [ { "name": "susfs_guard_lkm-android12-5.10.ko", "sha256": "291982…" },
                 { "name": "susfs_insmod", "sha256": "2c23e2…" } ]
}
```

```bash
cat  /data/adb/modules/susfs_lkm_autoloader/provenance.json
sha256sum /data/adb/modules/susfs_lkm_autoloader/loader/*
```

## 出问题怎么救

- **先别急**：有守卫在，正常只会卡一次就自动禁用，多等一次开机即可。
- **ADB**：重启用 `rm -f /data/adb/susfs_lkm.disabled /data/adb/susfs_lkm.guard`；
  暂停用 `touch /data/adb/susfs_lkm.disabled`；停模块用
  `ksud module disable susfs_lkm_autoloader_android12_5_10`。
- **recovery**：挂 `/data` 后 `rm -f /data/adb/susfs_lkm.guard /data/adb/susfs_lkm.disabled`，
  必要时 `rm -rf /data/adb/modules/susfs_lkm_autoloader*`。
- **查原因**：`cat /data/adb/susfs_lkm.log`、`ls /proc/susfs_*`、`dmesg | grep -i susfs`、
  `/sys/fs/pstore/console-ramoops*`。

## 免责声明

本项目仅做上游 release 的自动拉取与重新封装，不改动任何内核代码。SUSFS LKM 属内核级
修改，存在风险，请仅在可救砖的设备上做技术研究，后果自负。许可：**GPL-2.0**。
