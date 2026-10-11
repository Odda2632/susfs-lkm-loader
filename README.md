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
        └─ 打包出 susfs-lkm-loader-<tag>.zip
   └─ 上传 Artifact + 创建本仓库 GitHub Release
```

设备侧：刷入模块后，`post-fs-data.sh` 在开机早期运行，读取 `uname -r` 解析 KMI
（如 `android13-5.15`），从模块内 `loader/` 挑出匹配的 `.ko` 并加载。

## 目录结构

```
.
├── .github/workflows/build.yml   # 工作流：定时/手动拉取最新版本并打包发布
├── build.sh                      # 核心打包脚本（本地也能直接跑）
├── template/
│   ├── module.prop               # 模块元信息模板（含 __VERSION__ 等占位符）
│   └── post-fs-data.sh           # 开机自动加载脚本（按 KMI 自动选 .ko）
└── README.md
```

## 使用方式

### 1. 自动（推荐）

把本仓库推送到你的 GitHub 后：

- **定时**：工作流每天 UTC 03:00 检查上游最新 release，有更新就打包并创建 Release。
- **手动**：仓库 → Actions → *Build SUSFS LKM Loader Module* → Run workflow
  （可填上游 tag，留空即最新）。

产物在仓库的 **Releases** 页，下载 `susfs-lkm-loader-<tag>.zip` 直接刷入即可。

### 2. 本地打包

```bash
chmod +x build.sh
./build.sh                 # 自动取上游最新 release
./build.sh v2.3.0-r18      # 指定 tag
```

产物输出到 `out/`：

```
out/susfs-lkm-loader-<tag>.zip
out/susfs-lkm-loader-<tag>.zip.sha256
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

1. 在 KernelSU / APatch 中刷入 `susfs-lkm-loader-<tag>.zip` 并重启。
2. 开机脚本会按 KMI 自动加载匹配的 `.ko`。
3. 验证：
   - 查看日志：`cat /data/adb/ksu/ksu.log` 或模块日志中 `susfs_lkm` 标签
   - 检查探针/控制节点：`/proc/susfs_*`
   - `dmesg | grep -i susfs`

> 注意：`.ko` 必须与设备内核 KMI 匹配；内核若锁死 LKM 加载（如部分厂商内核），刷入也不会生效。

## 免责声明

本项目仅做上游 release 的自动拉取与重新封装，不改动任何内核代码。
SUSFS LKM 属内核级修改，存在风险，请仅在可救砖的设备上做技术研究，后果自负。
上游许可：GPL-2.0。
