# TCP BBRX

基于 Linux 6.6 BBR 的 out-of-tree 内核模块，拥塞控制算法名为 **`bbrx`**，支持通过 sysctl 调节丢包判定阈值。

## 编译与加载

```bash
# 安装内核头文件（Debian/Ubuntu）
sudo apt install linux-headers-$(uname -r) build-essential

make
sudo make load          # 加载 tcp_bbrx.ko
sudo make unload        # 卸载
```

## DKMS 安装

```bash
make dkms-tarball       # 生成 tcp-bbrx.dkms.tar.gz
sudo ./scripts/install_dkms.sh install -l ./tcp-bbrx.dkms.tar.gz
```

## 使用

```bash
# 查看是否可用
sysctl net.ipv4.tcp_available_congestion_control

# 设为默认（可选）
sudo sysctl -w net.ipv4.tcp_congestion_control=bbrx

# 单连接
# setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, "bbrx", 4);
```

## Sysctl

| 参数 | 说明 |
|------|------|
| `net.ipv4.tcp_bbrx_loss_thresh` | 进入/保持激进探测的丢包率上限（**0–99** %），默认 **15** |
| `net.ipv4.tcp_bbrx_loss_thresh_exit` | 退出激进探测的丢包率下限（**0–99** %），默认 **25**（须高于 `loss_thresh`，多流 iperf 防抖动） |
| `net.ipv4.tcp_bbrx_startup_ack_mul` | 激进模式下每个 ACK 的 cwnd 增量倍数（**1–8**），默认 **2**；多流压测可试 **1** |

多连接 / 多线程：丢包统计 per-socket（无全局锁）；丢包率带迟滞，避免 iperf3 `-P` 多流时因瞬时超阈而速度断崖下跌。

## 要求

- Linux **6.1+**（**Debian 12** bookworm / **Debian 13** trixie 及同系列云镜像）
- 与内核版本匹配的 `linux-headers-$(uname -r)`（`apt install linux-headers-$(uname -r)`）
- 每个内核单独 DKMS 编译，不可把为其他版本构建的 `.ko` 直接拷贝使用
