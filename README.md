# vkit · NetFlow

专为高延迟网络链路设计的确定性 Linux TCP 吞吐优化与流控工具。

基于 `tcpfit` (v0.5.9) 核心数学推导模型构建，彻底剥离第三方测速依赖，以固定 **220ms** 高延迟为 BDP 基准，通过单一带宽数值实现内核缓冲区计算与网卡队列调度的精准联动。

## 快速开始

在终端以 `root` 权限执行以下命令，唤出交互式面板并自动完成本地全局命令注册：

```
bash <(curl -fsSL https://raw.githubusercontent.com/muyeleng/vkit/main/netflow.sh)
```

> **提示**：若刚在仓库提交完代码更新，可在链接末尾追加 `?t=$(date +%s)` 绕过 GitHub CDN 缓存立即拉取最新版：
>
>
>
> ```
> bash <(curl -fsSL "https://raw.githubusercontent.com/muyeleng/vkit/main/netflow.sh?t=$(date +%s)")
> ```

## 日常快捷指令

首次运行后，脚本会自动安装至 `/usr/local/bin/netflow`。日常维护可直接通过终端快速调用：

| 指令 | 说明 |
| --- | --- |
| `netflow` | 唤出交互式管理主面板 |
| `netflow <Mbps>` | **二次调参**：直接按指定带宽计算内存并下发流控（如 `netflow 300` 或 `netflow 1000`） |
| `netflow status` | 查看当前内核核心参数、出厂基线同行对比及系统健康度 (Health) |
| `netflow rollback` | 一键还原至出厂默认状态，并在还原成功后自动重置基线快照 |
| `netflow uninstall` | 彻底卸载（先执行出厂还原，再清理全部配置文件与快捷命令） |
| `netflow help` | 查看命令行帮助指南 |

## 核心机制与分流策略

当你输入一个正整数目标带宽（单位 Mbps）时，系统将自动执行以下三层调优：

### 1. 动态内存推导与防 OOM 封顶

- **BDP 基准**：固定按 `220ms` 高延迟计算带宽时延积 (BDP=BW×220ms)。
- **单流最大缓冲 (`rmem_max` / `wmem_max`)**：取 2×BDP+2MB 余量，保底下限 `4MB`；同时受物理内存安全预算严格封顶（不超过 min(RAM/32,256MB)），确保多并发大流下绝不触发系统 OOM。
- **全局 TCP 内存池 (`tcp_mem`)**：严格按物理内存总页数的 `1/16`（低水位）、`1/8`（压力水位）、`1/4`（硬上限）推导。

### 2. 智能流控分水岭 (`1000 Mbps`)

- **精准限速模式 (`< 1000 Mbps`)**：自动挂载 `HTB` 令牌桶（突发桶容量按 4ms 线速动态推导，下限 32KB）配合底层 `fq` 叶子队列平滑发包 (Pacing)，精准压制晚高峰运营商 Policer 尾丢包。
- **满速释放模式 (`>= 1000 Mbps`)**：自动卸除 `HTB` 全局单核锁，切换为纯 `fq` 队列（自动识别并保护多核网卡的 `mq` 多队列硬件结构），零吞吐损耗释放 G 口物理上限。

### 3. 首包加速窗口 (`initcwnd`) 与自适应兼容

- **带宽分级**：`<= 100 Mbps` 保持系统默认窗口 (`10`)，防止首轮突发打穿小带宽令牌桶；`> 100 Mbps` 自动开启 `initcwnd / initrwnd = 32` 加速长距离连接爬坡，并自动探测 `systemd-networkd`、`networkd-dispatcher` 或 `systemd` 服务实现开机持久化。
- **内核安全排雷**：自动识别并保留系统已有的 BBR 变种（如 XanMod BBRv3）；写入 `/etc/sysctl.d/99-netflow.conf` 时逐项试探内核支持度，对老旧或受限容器内核不支持的参数自动注释跳过，确保 `systemd-sysctl` 开机零报错。

## 文件路径清单

| 路径 | 用途说明 |
| --- | --- |
| `/usr/local/bin/netflow` | 全局快捷命令本体 |
| `/var/lib/netflow/origin.snapshot` | 首次调优前锁定的纯净出厂基线快照 |
| `/etc/sysctl.d/99-netflow.conf` | 内核网络与缓冲区调优持久化配置 |
| `/usr/local/sbin/netflow-qdisc.sh` | TC 网卡队列整形执行脚本（仅 `< 1000 Mbps` 模式生成） |
| `/etc/systemd/system/netflow-qdisc.service` | 端口限速开机自启服务 |
