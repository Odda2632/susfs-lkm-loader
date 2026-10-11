# SUSFS LKM Loader (Auto-Build)

自动追踪上游 [inforcqb/susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm) 的最新 release，
把其中的 `susfs_guard_lkm-*.ko`（全部内核变体）与 `susfs_insmod` 加载器重新封装成一个
可直接刷入 **KernelSU / APatch** 的模块 ZIP。

> 本项目（含打包脚本、模块脚本与本文档）由 AI（TraeCode）协作生成与维护。
> 涉及内核级操作，请在可救砖的设备上自行审阅、测试。

## 致谢 / Credits

| 角色 | 作者 |
| --- | --- |
| SUSFS LKM 本体（`susfs_guard_lkm-*.ko`、`susfs_insmod`） | [@inforcqb](https://github.com/inforcqb) — [inforcqb/susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm) |
| 加载方案参考（`late_start` 加载 + 不进 post-fs-data、`susfs_insmod` 用法、`susfs_probe` 思路） | [@matsuzaka-yuki](https://github.com/matsuzaka-yuki)（社区 `susfs-lkm-module`） |
| 封装 / 打包 / 文档 | [@Odda2632](https://github.com/Odda2632) & TraeCode |

上游许可：**GPL-2.0**。本仓库只做 release 资产的自动拉取与重新封装，不改动任何内核代码。

## 工作原理

```
GitHub Actions（每天 03:00 UTC / 手动触发 / 改动 build.sh|template 时）
   └─ build.sh
        ├─ 向上游 API 查询 release（latest 或指定 tag）
        ├─ 下载 susfs_guard_lkm-*.ko + susfs_insmod 到 loader/
        ├─ 用 template/ 生成 module.prop 与开机脚本
        ├─ 打通用包 susfs-lkm-loader-<tag>.zip（含全部内核变体）
        ├─ 为每个内核变体各打一份单变体包 susfs-lkm-loader-<tag>-<kmi>.zip
        └─ 额外打一份无校验包 ...-<kmi>-nocheck.zip
   └─ 上传 Artifact + 创建/更新本仓库 Release
   └─ 若是上游新版本：额外创建一个 @你 的通知 Issue
```

设备侧流程（**关键：加载发生在 `late_start`，不是开机早期**）：

1. 安装时 `customize.sh` 授予 `susfs_insmod` 可执行位，并清掉上次的防砖标记。
2. 开机进入 `late_start` 后由 `service.sh` 执行：
   - 读真实内核串 `/proc/sys/kernel/osrelease`（`uname` 可能被其它 SUSFS 实现伪造）；
   - 通用包按 KMI 从 `loader/` 选 `.ko`，单变体包直接用它内置的那份；
   - 用自带的 `susfs_insmod <ko> expose_proc=1` 加载（参数不被接受则退回无参）；
   - 结果写回 `module.prop` 描述，管理器模块卡片上直接可见。
3. 开机完成后 `boot-completed.sh` 清除防砖守卫。

## 为什么是 `late_start` 而不是 `post-fs-data`

这个 `.ko` 在加载时要读取 KernelSU 自身状态（例如 `kernel-umount` 的应答），
**开机早期（`post-fs-data`）KernelSU 还没准备好，此时加载会把设备卡在第一屏**；
等到 `late_start`（系统已起到 Zygote 之后）再加载即可正常工作——这也正是 KernelSU
管理器里手动点"操作"按钮能加载成功的时点。

对应地，脚本**统一使用上游自带的 `susfs_insmod` 加载**，不使用 `ksud insmod`：
后者会在启动早期回调 KernelSU，容易造成死锁。

## 目录结构

```
.
├── .github/workflows/build.yml      # 工作流：定时/手动/改动触发，打包并发布/更新 Release
├── build.sh                         # 核心打包脚本（本地也能直接跑）
├── template/
│   ├── module.prop                  # 模块元信息模板（__ID__/__VERSION__/__AUTHOR__…）
│   ├── service.sh                   # 通用包：late_start 按 KMI 匹配并加载 .ko
│   ├── service-variant.sh           # 单变体包：先校验内核串再加载内置 .ko
│   ├── service-variant-nocheck.sh   # 单变体包：跳过内核校验，直接加载
│   ├── boot-completed.sh            # 开机完成 → 清除防砖守卫
│   ├── action.sh                    # 管理器"操作"按钮：手动加载并回显结果
│   └── customize.sh                 # 安装时：授权可执行位 + 清除上次标记
└── README.md
```

打包后的模块 ZIP 结构（以 `android12-5.10-nocheck` 为例）：

```
module.prop
service.sh              # 开机脚本（late_start）
boot-completed.sh       # 清守卫
action.sh               # "操作"按钮
customize.sh            # 安装时授权 + 清标记
skip_mount              # 不挂载 system 覆盖层（纯脚本模块，无需 metamodule）
loader/
├── susfs_insmod                        # 上游加载器（0755）
└── susfs_guard_lkm-android12-5.10.ko   # 对应内核变体
```

## 实现方式（脚本细节）

### `service.sh`（通用包）

1. 读到 `/data/adb/modules/<id>/disable` 就直接退出（尊重管理器里的禁用开关）。
2. 防砖守卫（见下节）。
3. 取真实内核串：`cat /proc/sys/kernel/osrelease`，失败再退回 `uname -r`。
4. **叠加保护**：若 `/proc/susfs` / `/proc/susfs_mnt_id` 已存在，说明系统已有 SUSFS，
   **不加载**（两个 SUSFS 叠在一起会 panic）。
5. 从内核串解析 KMI：`android1x` + `主.次`（如 `5.15.202-android13-8-xxx` → `android13-5.15`），
   选 `loader/susfs_guard_lkm-<kmi>.ko`；解析不到或文件缺失 → 跳过并写明状态，**绝不猜**。
6. `chmod 0755` 加载器，执行 `susfs_insmod <ko> expose_proc=1`；非零退出则去掉参数重试一次。
7. 成功 / 失败都写入 `/data/adb/susfs_lkm.log` 与模块描述。

### `service-variant.sh` / `service-variant-nocheck.sh`

同样流程，区别只在内核判定：前者要求真实内核串同时包含 `android12` 与 `5.10`（以
`android12-5.10` 为例），不匹配就跳过；后者**不校验**，直接加载内置的那份 `.ko`。

> 当设备内核串**不含 `-androidNN-`**（例如魔改/厂商内核 `5.10.x-moon-xxxx`）时，
> 带校验的包会拒绝加载，此时应使用 `-nocheck` 包。

### `action.sh`

管理器里点"操作 / Action"即执行：设置 `SUSFS_FORCE=1` → 清除禁用标记 → 立即调用
`service.sh` 加载一次 → 回显结果并打印日志尾部。**无需重启、无砖风险**，是最安全的测试方式。

### `customize.sh`

安装（含覆盖安装）时执行：`set_perm_recursive` + `set_perm` 给 `susfs_insmod` 与脚本加
可执行位（KernelSU 解压非脚本文件时只给 `0644`），并删除
`/data/adb/susfs_lkm.disabled`、`/data/adb/susfs_lkm.guard`，使每次重刷都会重新尝试加载。

## 使用方式

### 1. 自动（推荐）

- **定时**：工作流每天 UTC 03:00 检查上游最新 release，有更新就打包。
- **手动**：Actions → *Build SUSFS LKM Loader Module* → Run workflow（可填上游 tag，留空即最新）。
- **改动触发**：`build.sh` / `template/**` / 工作流本身有改动时立即重跑，
  并**覆盖更新**已存在 Release 的资产（这样修好封装后重跑即可生效）。
- **通知**：检测到**上游新版本**时创建 @你 的 Issue（同一 tag 不重复通知）。

产物在仓库 **Releases** 页：

- 通用包 `susfs-lkm-loader-<tag>.zip`：含全部内核变体，开机按 KMI 自动匹配；
- 单变体包 `susfs-lkm-loader-<tag>-<kmi>.zip`：只含该内核的 `.ko`，加载前校验内核串；
- 无校验包 `susfs-lkm-loader-<tag>-<kmi>-nocheck.zip`：不做校验直接加载。

### 2. 本地打包

```bash
chmod +x build.sh
./build.sh                 # 自动取上游最新 release
./build.sh v2.3.0-r18      # 指定 tag
```

产物输出到 `out/`：

```
out/susfs-lkm-loader-<tag>.zip                         # 通用包（全部内核变体）
out/susfs-lkm-loader-<tag>-android12-5.10.zip          # 单变体（带内核校验）
out/susfs-lkm-loader-<tag>-android12-5.10-nocheck.zip  # 无内核校验
out/SHA256SUMS                                         # 所有 zip 的校验和
out/build-info.env
```

### 3. 可配置项

`build.sh` 支持环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `UPSTREAM_REPO` | `inforcqb/susfs4ksu-lkm` | 上游仓库 `owner/repo` |
| `AUTHOR` | `Odda2632 & TraeCode` | 写入 `module.prop` 的作者；脚本会自动追加 `(LKM by <上游 owner>)` 标注上游原作者 |
| `NOCHECK_VARIANTS` | `android12-5.10` | 额外产出的"无内核校验"变体，空格分隔多个 |
| `GITHUB_TOKEN` / `GH_TOKEN` | 空 | 设置后走认证请求，避免 GitHub API 限流 |

## 刷入与验证

1. **先确认内核**：跑 `uname -r`，得到你的 KMI（形如 `android12-5.10`）。
   - 内核串带 `-androidNN-`：优先刷**与该 KMI 完全对应的单变体包**。
   - 内核串**不带** `-androidNN-`（魔改/厂商内核）：用 **`-nocheck`** 包。
2. 在 KernelSU / APatch 中刷入对应 zip 并重启（加载在 `late_start` 进行）。
3. **在 KernelSU 管理器里看状态**：脚本会把结果写回模块描述，卡片上直接显示，例如
   `||STATUS: 已加载 susfs_guard_lkm-android12-5.10.ko @ 10-12 20:30`（下拉刷新即可）。
   常见状态：`已自动禁用: 上次加载后未能开机`、`未加载: 无匹配内核`、
   `未加载: 检测到已有 SUSFS，避免叠加`、`加载失败 exit=<n>`。
4. 进一步验证：
   - 加载日志：`cat /data/adb/susfs_lkm.log`
   - 控制节点：`ls /proc/susfs_*`
   - 内核日志：`dmesg | grep -i susfs`

## 防砖守卫（重要）

自动加载一个会 hook 内核 LSM 的 `.ko` 有让设备起不来的风险，所以模块内置了守卫：

- 加载前写标记 `/data/adb/susfs_lkm.guard`；开机完成后由 `boot-completed.sh` 清除。
- 若下次开机时该标记仍在，说明**上次加载后没能开机** → 自动写下
  `/data/adb/susfs_lkm.disabled` 并**跳过本次加载**：最多只卡一次，不会无限重启。
- 描述里会显示 `||STATUS: 已自动禁用: 上次加载后未能开机`。
- **无需手动删标记**：覆盖安装时 `customize.sh` 会自动清除；点"操作"按钮也会自动清除。

**安全地手动测试**：管理器里点该模块的 **操作 / Action** 按钮，会立即手动加载一次并回显
结果，不重启、无砖风险；成功后守卫会被清除，下次开机恢复自动加载。

## 出问题怎么救（bootloop / 卡第一屏）

- **先别急**：有守卫在，正常只会卡一次就自动禁用，多等一次开机即可。
- **有 root / ADB**：
  - 重新启用自动加载：`adb shell su -c 'rm -f /data/adb/susfs_lkm.disabled /data/adb/susfs_lkm.guard'`
  - 暂停自动加载：`adb shell su -c 'touch /data/adb/susfs_lkm.disabled'`
  - 禁用整个模块：`adb shell su -c 'ksud module disable susfs_lkm_loader_android12_5_10'`
- **进 recovery**：挂载 `/data` 后删除标记或模块目录再开机：
  `rm -f /data/adb/susfs_lkm.guard /data/adb/susfs_lkm.disabled`
  `rm -rf /data/adb/modules/susfs_lkm_loader*`
- **查原因**：`cat /data/adb/susfs_lkm.log`、`/sys/fs/pstore/console-ramoops*`。

> `.ko` 必须与设备内核 KMI 精确匹配；内核若锁死 LKM 加载、或非 GKI/CFI 内核
> （上游明确只支持 GKI/CFI 设备），加载会失败甚至 panic，日志里能看到。

## 免责声明

本项目仅做上游 release 的自动拉取与重新封装，不改动任何内核代码。
SUSFS LKM 属内核级修改，存在风险，请仅在可救砖的设备上做技术研究，后果自负。
上游许可：GPL-2.0。
