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
out/susfs-lkm-loader-<tag>.zip                # 通用包（全部内核变体）
out/susfs-lkm-loader-<tag>-android12-5.10.zip # 单变体……每个内核一份
out/SHA256SUMS                                # 所有 zip 的校验和
out/build-info.env
```

### 3. 可配置项

`build.sh` 支持环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `UPSTREAM_REPO` | `inforcqb/susfs4ksu-lkm` | 上游仓库 `owner/repo` |
| `AUTHOR` | `github-actions` | 写入 `module.prop` 的作者（工作流里取仓库 owner） |
| `GITHUB_TOKEN` / `GH_TOKEN` | 空 | 设置后走认证请求，避免 GitHub API 限流 |

## 刷入与验证

1. **先确认内核**：跑 `uname -r`（例如 `5.10.101-android12-9-gxxxx`），得到你的 KMI
   （形如 `android12-5.10`）。**优先刷与该 KMI 完全对应的单变体包**，别用通用包试运气。
2. 在 KernelSU / APatch 中刷入对应 zip 并重启。
3. 开机脚本会**严格校验**内核串后再加载；不匹配就跳过（不会硬装错版本）。
   - 加载方式：KernelSU/APatch 走 `ksud insmod`；非 KernelSU 才用自带的 `susfs_insmod`。
4. 验证：
   - 加载日志：`cat /data/adb/susfs_lkm.log`
   - 检查控制节点：`/proc/susfs_*`
   - `dmesg | grep -i susfs`

## 出问题怎么救（bootloop / 卡第一屏）

- **有 root/ADB**：`adb shell su -c 'ksud module disable susfs_lkm_loader'`
  （单变体包的 id 是 `susfs_lkm_loader_<kmi>`，如 `susfs_lkm_loader_android12_5_10`）
- **进 recovery**：挂载 `/data` 后删除模块目录再开机：
  `rm -rf /data/adb/modules/susfs_lkm_loader*`

> 注意：`.ko` 必须与设备内核 KMI 精确匹配；内核若锁死 LKM 加载（如部分厂商内核），
> 加载会失败（不会生效，日志里能看到）。

## 免责声明

本项目仅做上游 release 的自动拉取与重新封装，不改动任何内核代码。
SUSFS LKM 属内核级修改，存在风险，请仅在可救砖的设备上做技术研究，后果自负。
上游许可：GPL-2.0。
