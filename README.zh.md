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
| `net.ipv4.tcp_bbrx_loss_thresh` | 长时带宽估计中的丢包率阈值（**0–99**，单位 %），默认 **10** |

## 要求

- Linux **5.15+**（已在 5.15 / 6.6 上验证编译）
- 与内核版本匹配的 `linux-headers-$(uname -r)`
