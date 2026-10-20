# MemKeep++

面向 Android 的内存管理模块：重建 ZRAM 压缩交换区、调优 VM 水位与 LMKD 策略，并支持按应用保活。自带 WebUI，也支持完全不开图形界面运行。

兼容 **KernelSU / KernelSU-Next / SukiSU / APatch / Magisk**。

## 功能

- **ZRAM 重建**：容量可选 8 / 12 / 16 GB 或 1–32 GB 自定义，压缩算法按内核实际支持项动态列出
- **后台保活**：两级 oom 保护（`-1000` 永不被杀 / `-999` 可重启），同时写入 `standby bucket` 与 Doze 白名单，按包名前缀匹配并自动覆盖 `:push` 等子进程
- **进程看板**：实时查看各进程常驻内存、oom 分值与状态，可停止单个进程（系统进程自动禁用该操作）
- **击杀记录**：读取 lmkd 的真实击杀事件，能看到哪个应用几点被杀、oom 分值与释放量
- **保活体检**：把「保活到底有没有生效」变成可读数字——每个应用的 oom 分数是否被系统改回、是否被冻结、工作集回读量
- **VM 调参**：swappiness、水位系数、min_free_kbytes、MGLRU 工作集保护等 7 项，可跟随档位也可逐项手动覆盖
- **三档保活强度**：`均衡 / 增强 / 极限` 不是三组写死的数字，而是「原厂值 + 偏移」——缓存上限与 LMKD 阈值都按安装时快照的原厂值放大，避免在某些 ROM 上把原厂设置调得更紧
- **日志**：按 ZRAM / VM / 保活 / 异常筛选，可复制导出

## 安装

从 [Releases](https://github.com/qvq9999/MemKeep/releases) 下载最新 ZIP，在 root 管理器里刷入，重启。

支持在线更新：模块内置 `updateJson`（托管在 GitHub Pages，发版后约 10 分钟生效），管理器检测到新版本会直接显示「更新」按钮，安装包从 GitHub Release 直链下载。

## 打开图形界面

| 管理器 | 方式 |
|---|---|
| KernelSU / KernelSU-Next / SukiSU | 模块列表 → MemKeep++ → 打开 |
| APatch | 模块列表 → MemKeep++ → 打开 |
| Magisk | 需另装 [KsuWebUI Standalone](https://github.com/5ec1cff/KsuWebUIStandalone) 或 MMRL（WebUI X） |

Magisk 下即使不装 WebUI 也能正常使用：点模块的动作按钮可在终端看到内存状态、当前参数和保活名单，配置照常按 `config.conf` 在开机时生效。

## 配置

所有设置都写在模块目录下：

- `config.conf` — ZRAM 容量/算法、保活强度、VM 参数覆盖、守护开关
- `keep_apps.conf` — 保活名单，每行 `包名 档位`（`critical` / `restartable`）

`ZRAM_*` 改动需要重启才能重建压缩区；`/proc/sys/vm/*` 与 MGLRU 参数保存后立即生效；
**LMKD 阈值（`ro.lmk.*`）与缓存进程上限需要重启一次**——它们在 lmkd / ActivityManager 启动时读取。

## 兼容性与已知限制

- 只处理 `zram0`。多 zram 设备（部分三星/索尼机型）仅重建第一个
- 厂商自带的「内存扩展 / 虚拟内存」如果也在接管 zram，可能与本模块冲突，建议先关掉厂商的
- 依赖内核导出 `comp_algorithm`、`disksize` 等标准 zram 节点；个别魔改内核缺少 `backing_dev` 时会自动跳过该项
- MIUI / HyperOS 的额外后台限制通过 `resetprop` 处理，非 MIUI 设备自动跳过
- 保活依赖守护进程每 5 秒把 oom 分数压回去；关闭守护后名单只在开机时应用一次
- `cgroup v2 memory.low` 只在 memcg 为 v2 且带 memory 控制器的机型上生效；memcg 仍是 v1 的设备会自动跳过（体检页会标注）
- MGLRU 的 `min_ttl_ms` 只在厂商未关闭 MGLRU（`enabled` 非 `0x0000`）的内核上生效，不会强行打开
- 缓存应用冻结器（freezer）只做检测展示，不主动改写——开启后长连接类应用的推送可能延迟

## 从源码构建

```bash
python3 scripts/build.py            # 产物在 dist/ 与 release/
python3 scripts/build.py --update-json   # 同时按 module.prop 重写 update.json
```

发版：改 `module/module.prop` 的 `version` 与 `versionCode`，提交后打 tag 推上去，CI 会自动打包、建 Release 并回写 `update.json`。

版本号规则：`MAJOR.MINOR`，每次发版 +0.1（3.9 之后是 4.0）；`versionCode = MAJOR×10000 + MINOR×1000`。

## 致谢

参数取值与思路参考了这些项目：

- [OomAdjuster](https://github.com/zwajton/OomAdjuster) — 两级 oom 保护的取值
- [BackgroundOpt](https://github.com/Familyye/BackgroundOpt) — 主/子进程分级
- [processkeepalive](https://github.com/guys222/processkeepalive) — 进程看板的信息组织
- [Zram_WebUI](https://github.com/brokestar233/Zram_WebUI) — 状态总览优先的界面思路
- [LMK-Controller](https://github.com/ferrdishx/LMK-Controller) — 读取真实 lmkd 击杀事件的思路
- [Frosty](https://github.com/Drsexo/Frosty) — 按档位分层调整 LMKD / PSI 阈值的做法

## 许可

MIT
