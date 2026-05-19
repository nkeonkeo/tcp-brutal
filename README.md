# TCP BBRX

Out-of-tree Linux kernel module: BBR-derived congestion control registered as **`bbrx`**, with a tunable loss threshold via sysctl.

## Build & load

```bash
sudo apt install linux-headers-$(uname -r) build-essential   # Debian/Ubuntu
make
sudo make load      # insmod tcp_bbrx.ko
sudo make unload
```

## DKMS

```bash
make dkms-tarball
sudo ./scripts/install_dkms.sh install -l ./tcp-bbrx.dkms.tar.gz
```

## Usage

```bash
sysctl net.ipv4.tcp_available_congestion_control
sudo sysctl -w net.ipv4.tcp_congestion_control=bbrx
```

Per-socket: `setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, "bbrx", 4);`

## Sysctl

| Parameter | Description |
|-----------|-------------|
| `net.ipv4.tcp_bbrx_loss_thresh` | Max loss % to enter/stay in aggressive probe mode, default **15** |
| `net.ipv4.tcp_bbrx_loss_thresh_exit` | Loss % to exit aggressive mode, default **25** (hysteresis for multi-stream iperf) |
| `net.ipv4.tcp_bbrx_startup_ack_mul` | CWND increase multiplier per ACK in aggressive mode (**1–8**), default **2** |

Per-connection loss stats with enter/exit hysteresis reduce throughput cliffs under `iperf3 -P` on a shared bottleneck.

## Requirements

- Linux **5.15+** (tested on 5.15 / 6.6)
- `linux-headers` matching `uname -r`
