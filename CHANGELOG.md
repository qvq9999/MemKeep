# 更新日志

版本号规则：`MAJOR.MINOR.PATCH`，`versionCode = MAJOR×10000 + MINOR×100 + PATCH`。
（例：v2.1.0 → 20100，v2.2.0 → 20200，v2.2.1 → 20201）

## v2.1.0

首个带更新通道的发布版本。

- 新增 `updateJson` 在线更新：KernelSU / KernelSU-Next / APatch / Magisk / MMRL 的模块列表里会直接出现「更新」按钮，点一下自动下载安装，无需手动找 ZIP
- 下载源走 jsDelivr 镜像（`cdn.jsdelivr.net`），国内网络无需代理即可下载；GitHub Release 仍保留作为存档
- 配置与脚本行为与 v2.1 完全一致，仅补齐模块元数据（修订 versionCode 为 MMmmpp 编码，旧版 21 会被视为旧版本并收到本次更新）
- 新增构建脚本与 GitHub Actions 自动发版
