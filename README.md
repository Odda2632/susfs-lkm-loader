# 未测试，可用性存疑
# SUSFS LKM Loader (Auto-Build)

自动追踪上游 [inforcqb/susfs4ksu-lkm](https://github.com/inforcqb/susfs4ksu-lkm) 的最新 release，
把其中的 `susfs_guard_lkm-*.ko`（全部内核变体）与 `susfs_insmod` 加载器重新封装成一个
可直接刷入 **KernelSU / APatch** 的模块 ZIP。

## 工作原理

```
GitHub Actions (每天 03:00 UTC / 手动触发)
   └─ build.sh
        ├─ 向上游 API 查询最新 release（或指定 tag）
        ├─ 下载 susfs_guard_lkm-*.ko + susfs_insmod
        ├─ 套用 template/ 生成 module.prop 与 post-fs-data.sh
        ├─ 打包通用包 susfs-lkm-loader-<tag>.zip（含全部内核变体）
        └─ 再为每个内核变体各打一份单变体包 susfs-lkm-loader-<tag>-<kmi>.zip
   └─ 上传 Artifact + 创建本仓库 GitHub Release
   └─ 若是上游新版本：额外创建一个 @你 的通知 Issue（触发 GitHub 通知）
```

设备侧：刷入模块后，`post-fs-data.sh` 在开机早期运行，读取 `uname -r` 解析 KMI
（如 `android13-5.15`），从模块内 `loader/` 挑出匹配的 `.ko` 并加载。
单变体包只含一个 `.ko`，开机直接加载该文件。

## 目录结构

```
.
├── .github/workflows/build.yml   # 工作流：定时/手动拉取最新版本并打包发布
├── build.sh                      # 核心打包脚本（本地也能直接跑）
├── template/
│   ├── module.prop               # 模块元信息模板（含 __ID__/__VERSION__ 等占位符）
│   ├── post-fs-data.sh           # 通用包的开机脚本（按 KMI 自动选 .ko）
│   └── post-fs-data-variant.sh   # 单变体包的开机脚本（直接加载内置 .ko）
└── README.md
```

## 使用方式

### 1. 自动（推荐）

把本仓库推送到你的 GitHub 后：

- **定时**：工作流每天 UTC 03:00 检查上游最新 release，有更新就打包并创建 Release。
- **手动**：仓库 → Actions → *Build SUSFS LKM Loader Module* → Run workflow
  （可填上游 tag，留空即最新）。
- **通知**：当检测到**上游新版本**时，除自动构建外，还会创建一个 @你 的 Issue，
  通过 GitHub 通知提醒你（同一个 tag 不会重复通知）。

产物在仓库的 **Releases** 页：

- 通用包 `susfs-lkm-loader-<tag>.zip`：含全部内核变体，开机自动匹配；
- 单变体包 `susfs-lkm-loader-<tag>-<kmi>.zip`：如 `susfs-lkm-loader-v2.3.0-r18-android12-5.10.zip`，
  只含该内核的 `.ko`，按需下载刷入。

### 2. 本地打包

```bash
chmod +x build.sh
./build.sh                 # 自动取上游最新 release
./build.sh v2.3.0-r18      # 指定 tag
```

产物输出到 `out/`：

```
out/susfs-lkm-loader-<tag>.zip                        # 通用包（全部内核变体）
out/susfs-lkm-loader-<tag>-android12-5.10.zip         # 单变体……每个内核一份（带内核校验）
out/susfs-lkm-loader-<tag>-android12-5.10-nocheck.zip # 无内核校验版（仅默认的 android12-5.10）
out/SHA256SUMS                                        # 所有 zip 的校验和
out/build-info.env
```

> **两种 12-5.10 包的区别**：普通版加载前会校验内核串；`-nocheck` 版**跳过校验直接加载**，
> 仅当校验误判或你确认内核匹配时使用（装错内核会 panic）。

### 3. 可配置项

`build.sh` 支持环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `UPSTREAM_REPO` | `inforcqb/susfs4ksu-lkm` | 上游仓库 `owner/repo` |
| `AUTHOR` | `github-actions` | 写入 `module.prop` 的作者（工作流里取仓库 owner） |
| `NOCHECK_VARIANTS` | `android12-5.10` | 额外产出的“无内核校验”变体，空格分隔多个 |
| `GITHUB_TOKEN` / `GH_TOKEN` | 空 | 设置后走认证请求，避免 GitHub API 限流 |

## 刷入与验证

1. **先确认内核**：跑 `uname -r`（例如 `5.10.101-android12-9-gxxxx`），得到你的 KMI
   （形如 `android12-5.10`）。**优先刷与该 KMI 完全对应的单变体包**，别用通用包试运气。
2. 在 KernelSU / APatch 中刷入对应 zip 并重启。
3. **加载时机是 `late_start`（`service.sh`），不是开机早期**。这个 `.ko` 会 hook LSM，
   在内核启动早期（`post-fs-data`）加载会**卡第一屏**，所以必须等系统起来后再加载。
   - 加载方式：KernelSU/APatch 走 `ksud insmod`；非 KernelSU 才用自带的 `susfs_insmod`。
   - 单变体包会先校验内核串，不匹配就跳过（不会硬装错版本）。
4. **在 KernelSU 管理器里看状态**：脚本会把结果写回模块描述，模块卡片上直接显示
   `||STATUS: 已加载 susfs_guard_lkm-android12-5.10.ko @ 10-12 20:30`（下拉刷新即可）。
5. 进一步验证：
   - 加载日志：`cat /data/adb/susfs_lkm.log`
   - 检查控制节点：`/proc/susfs_*`
   - `dmesg | grep -i susfs`

## 防砖守卫（重要）

自动加载一个会 hook 内核 LSM 的 `.ko` 有让设备起不来的风险，所以模块内置了守卫：

- 加载前写标记 `/data/adb/susfs_lkm.guard`；开机完成后由 `boot-completed.sh` 清除。
- 若下次开机时该标记仍在，说明**上次加载后没能开机** → 模块自动写下
  `/data/adb/susfs_lkm.disabled` 并**跳过本次加载**，最多只卡一次，不会无限重启。
- 管理器中模块描述会显示 `||STATUS: 已自动禁用: 上次加载后未能开机（点“操作”可手动重试）`。

**安全地手动测试**：在 KernelSU 管理器里点该模块的 **操作 / Action** 按钮，
会立刻手动加载一次并显示结果（成功/失败），不需要重启、也无砖风险。
手动成功后守卫会被清除，下次开机恢复自动加载。

## 出问题怎么救（bootloop / 卡第一屏）

- **先别急**：有了防砖守卫，正常只会卡一次就会自动禁用；多等一次开机即可。
- **有 root/ADB**：
  - 关闭自动加载：`adb shell su -c 'touch /data/adb/susfs_lkm.disabled'`
  - 重新启用自动加载：`adb shell su -c 'rm -f /data/adb/susfs_lkm.disabled /data/adb/susfs_lkm.guard'`
  - 禁用整个模块：`adb shell su -c 'ksud module disable susfs_lkm_loader_android12_5_10'`
- **进 recovery**：挂载 `/data` 后删除标记或模块目录再开机：
  `rm -f /data/adb/susfs_lkm.guard /data/adb/susfs_lkm.disabled`
  `rm -rf /data/adb/modules/susfs_lkm_loader*`
- **查原因**：`cat /data/adb/susfs_lkm.log`、`/sys/fs/pstore/console-ramoops*`。

> 注意：`.ko` 必须与设备内核 KMI 精确匹配；内核若锁死 LKM 加载、或非 GKI/CFI 内核
> （上游明确只支持 GKI/CFI 设备），加载会失败甚至 panic，日志里能看到。

## 免责声明

本项目仅做上游 release 的自动拉取与重新封装，不改动任何内核代码。
SUSFS LKM 属内核级修改，存在风险，请仅在可救砖的设备上做技术研究，后果自负。
上游许可：GPL-2.0。
