#include <linux/module.h>
#include <linux/version.h>
#include <net/tcp.h>
#include <linux/math64.h>

#if IS_ENABLED(CONFIG_SYSCTL)
#include <linux/sysctl.h>
#include <net/net_namespace.h>
#endif

#if IS_ENABLED(CONFIG_IPV6) && LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)
#include <net/transp_v6.h>
#else
#warning IPv6 support is disabled. Brutal will only work with IPv4. \
 Please ensure you have enabled CONFIG_IPV6 in your kernel config \
 and your kernel version is greater than 5.8.
#endif

#define INIT_PACING_RATE 125000 // 1 Mbps
#define INIT_CWND_GAIN 20

#define MIN_PACING_RATE 62500 // 500 Kbps
#define MIN_CWND_GAIN 5
#define MAX_CWND_GAIN 80
#define MIN_CWND 4

#ifndef ICSK_CA_PRIV_SIZE
#error "ICSK_CA_PRIV_SIZE not defined"
#else
// This is the size of the private data area in struct inet_connection_sock
// The size varies between Linux versions
// We use it to calculate the number of slots in the packet info array
#define RAW_PKT_INFO_SLOTS ((ICSK_CA_PRIV_SIZE - 2 * sizeof(u64)) / sizeof(struct brutal_pkt_info))
#define PKT_INFO_SLOTS (RAW_PKT_INFO_SLOTS < 3 ? 3 : (RAW_PKT_INFO_SLOTS > 5 ? 5 : RAW_PKT_INFO_SLOTS))
#endif

#define MIN_PKT_INFO_SAMPLES 50
#define MIN_ACK_RATE_PERCENT 80

/* Loss % above which pacing is scaled down (0 = feature off). Tunable via sysctl. */
#define DEFAULT_LOSS_SLOW_THRESH 30

#define TCP_BRUTAL_PARAMS 23301

/*
 * Initial target send rate (bytes/s) before the application sets
 * TCP_BRUTAL_PARAMS. When CONFIG_SYSCTL is enabled, this is exposed as
 * net.ipv4.tcp_brutal_default_rate (writable; min = MIN_PACING_RATE).
 */
static unsigned long brutal_default_rate = INIT_PACING_RATE;
static unsigned long brutal_loss_slow_thresh = DEFAULT_LOSS_SLOW_THRESH;

#if IS_ENABLED(CONFIG_SYSCTL)
static unsigned long brutal_default_rate_min = MIN_PACING_RATE;
static unsigned long brutal_default_rate_max = (~0UL) / 200;
static unsigned long brutal_loss_slow_thresh_min = 0;
static unsigned long brutal_loss_slow_thresh_max = 100;

static struct ctl_table brutal_sysctl_table[] = {
	{
		.procname = "tcp_brutal_default_rate",
		.data = &brutal_default_rate,
		.maxlen = sizeof(brutal_default_rate),
		.mode = 0644,
		.proc_handler = proc_doulongvec_minmax,
		.extra1 = &brutal_default_rate_min,
		.extra2 = &brutal_default_rate_max,
	},
	{
		.procname = "tcp_brutal_loss_slow_thresh",
		.data = &brutal_loss_slow_thresh,
		.maxlen = sizeof(brutal_loss_slow_thresh),
		.mode = 0644,
		.proc_handler = proc_doulongvec_minmax,
		.extra1 = &brutal_loss_slow_thresh_min,
		.extra2 = &brutal_loss_slow_thresh_max,
	},
	{ }
};

static struct ctl_table_header *brutal_sysctl_header;
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 13, 0)
static u64 tcp_sock_get_sec(const struct tcp_sock *tp)
{
    return div_u64(tp->tcp_mstamp, USEC_PER_SEC);
}
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)
// see https://github.com/torvalds/linux/commit/9a568de4818dea9a05af141046bd3e589245ab83
static u64 tcp_sock_get_sec(const struct tcp_sock *tp)
{
    return div_u64(tp->tcp_mstamp.stamp_us, USEC_PER_SEC);
}
#else
#include <linux/jiffies.h>
static u64 tcp_sock_get_sec(const struct tcp_sock *tp)
{
    return div_u64(jiffies_to_usecs(tcp_time_stamp), USEC_PER_SEC);
}
#endif

struct brutal_pkt_info
{
    u64 sec;
    u32 acked;
    u32 losses;
};

struct brutal
{
    u64 rate;
    u32 cwnd_gain;

    struct brutal_pkt_info slots[PKT_INFO_SLOTS];
};

struct brutal_params
{
    u64 rate;      // Send rate in bytes per second
    u32 cwnd_gain; // CWND gain in tenths (10=1.0)
} __packed;

static struct proto tcp_prot_override __ro_after_init;
#ifdef _TRANSP_V6_H
static struct proto tcpv6_prot_override __ro_after_init;
#endif // _TRANSP_V6_H

#ifdef _LINUX_SOCKPTR_H
static int brutal_set_params(struct sock *sk, sockptr_t optval, unsigned int optlen)
#else
static int brutal_set_params(struct sock *sk, char __user *optval, unsigned int optlen)
#endif
{
    struct brutal *brutal = inet_csk_ca(sk);
    struct brutal_params params;

    if (optlen < sizeof(params))
        return -EINVAL;

#ifdef _LINUX_SOCKPTR_H
    if (copy_from_sockptr(&params, optval, sizeof(params)))
        return -EFAULT;
#else
    if (copy_from_user(&params, optval, sizeof(params)))
        return -EFAULT;
#endif

    // Sanity checks
    if (params.rate < MIN_PACING_RATE)
        return -EINVAL;
    if (params.cwnd_gain < MIN_CWND_GAIN || params.cwnd_gain > MAX_CWND_GAIN)
        return -EINVAL;

    brutal->rate = params.rate;
    brutal->cwnd_gain = params.cwnd_gain;

    return 0;
}

#ifdef _LINUX_SOCKPTR_H
static int brutal_tcp_setsockopt(struct sock *sk, int level, int optname, sockptr_t optval, unsigned int optlen)
#else
static int brutal_tcp_setsockopt(struct sock *sk, int level, int optname, char __user *optval, unsigned int optlen)
#endif
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_set_params(sk, optval, optlen);
    else
        return tcp_prot.setsockopt(sk, level, optname, optval, optlen);
}

#ifdef _TRANSP_V6_H
#ifdef _LINUX_SOCKPTR_H
static int brutal_tcpv6_setsockopt(struct sock *sk, int level, int optname, sockptr_t optval, unsigned int optlen)
#else  // _LINUX_SOCKPTR_H
static int brutal_tcpv6_setsockopt(struct sock *sk, int level, int optname, char __user *optval, unsigned int optlen)
#endif // _LINUX_SOCKPTR_H
{
    if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
        return brutal_set_params(sk, optval, optlen);
    else
        return tcpv6_prot.setsockopt(sk, level, optname, optval, optlen);
}
#endif // _TRANSP_V6_H

static void brutal_init(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct brutal *brutal = inet_csk_ca(sk);

    if (sk->sk_family == AF_INET)
        sk->sk_prot = &tcp_prot_override;
#ifdef _TRANSP_V6_H
    else if (sk->sk_family == AF_INET6)
        sk->sk_prot = &tcpv6_prot_override;
#endif // _TRANSP_V6_H
    else
        BUG(); // WTF?

    tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;

    {
        u64 rate = READ_ONCE(brutal_default_rate);

        if (rate < MIN_PACING_RATE)
            rate = MIN_PACING_RATE;
        brutal->rate = rate;
    }
    brutal->cwnd_gain = INIT_CWND_GAIN;

    memset(brutal->slots, 0, sizeof(brutal->slots));

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 13, 0)
    // Pacing is REQUIRED for Brutal to work, but Linux only has internal pacing after 4.13.
    // For kernels prior to 4.13, you MUST add fq pacing manually (e.g. "tc qdisc add dev eth0 root fq pacing")
    // or rate control will be broken.
    // See https://github.com/torvalds/linux/commit/218af599fa635b107cfe10acf3249c4dfe5e4123 for details.
    cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
#endif
}

// Copied from tcp.h for compatibility reasons
static inline u32 brutal_tcp_snd_cwnd(const struct tcp_sock *tp)
{
    return tp->snd_cwnd;
}

// Copied from tcp.h for compatibility reasons
static inline void brutal_tcp_snd_cwnd_set(struct tcp_sock *tp, u32 val)
{
    WARN_ON_ONCE((int)val <= 0);
    tp->snd_cwnd = val;
}

static void brutal_update_rate(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct brutal *brutal = inet_csk_ca(sk);

    u64 sec = tcp_sock_get_sec(tp);
    u64 min_sec = sec - PKT_INFO_SLOTS;
    u32 acked = 0, losses = 0;
    u32 total;
    u32 loss_pct = 0;
    u32 ack_rate; // Scaled by 100 (100=1.00) as kernel doesn't support float
    u64 rate = brutal->rate;
    u32 cwnd;

    u32 mss = tp->mss_cache;
    u32 rtt_ms = (tp->srtt_us >> 3) / USEC_PER_MSEC;
    if (!rtt_ms)
        rtt_ms = 1;

    for (int i = 0; i < PKT_INFO_SLOTS; i++)
    {
        if (brutal->slots[i].sec >= min_sec)
        {
            acked += brutal->slots[i].acked;
            losses += brutal->slots[i].losses;
        }
    }
    total = acked + losses;
    if (total < MIN_PKT_INFO_SAMPLES)
        ack_rate = 100;
    else
    {
        ack_rate = acked * 100 / total;
        if (ack_rate < MIN_ACK_RATE_PERCENT)
            ack_rate = MIN_ACK_RATE_PERCENT;
        loss_pct = losses * 100 / total;
    }

    rate *= 100;
    rate = div_u64(rate, ack_rate);

    /* When loss exceeds threshold, scale pacing/cwnd down (linear in loss above thresh). */
    {
        unsigned long thresh = READ_ONCE(brutal_loss_slow_thresh);

        if (thresh > 0 && thresh < 100 && total >= MIN_PKT_INFO_SAMPLES && loss_pct > thresh)
        {
            u32 excess = loss_pct - (u32)thresh;
            u32 room = 100U - (u32)thresh;

            if (room)
            {
                u32 loss_scale = 100U - (excess * 60U) / room;

                if (loss_scale < 15U)
                    loss_scale = 15U;
                rate = mul_u64_u32_div(rate, loss_scale, 100U);
            }
        }
    }

    // The order here is chosen carefully to avoid overflow as much as possible
    cwnd = div_u64(rate, MSEC_PER_SEC);
    cwnd *= rtt_ms;
    cwnd /= mss;
    cwnd *= brutal->cwnd_gain;
    cwnd /= 10;
    cwnd = max_t(u32, cwnd, MIN_CWND);

    brutal_tcp_snd_cwnd_set(tp, min(cwnd, tp->snd_cwnd_clamp));

    WRITE_ONCE(sk->sk_pacing_rate, min_t(u64, rate, READ_ONCE(sk->sk_max_pacing_rate)));
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0)
static void brutal_main(struct sock *sk, u32 ack, int flag, const struct rate_sample *rs)
#else
static void brutal_main(struct sock *sk, const struct rate_sample *rs)
#endif
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct brutal *brutal = inet_csk_ca(sk);

    u64 sec;
    u32 slot;

    // Ignore invalid rate samples
    if (rs->delivered < 0 || rs->interval_us <= 0)
        return;

    sec = tcp_sock_get_sec(tp);
    div_u64_rem(sec, PKT_INFO_SLOTS, &slot);

    if (brutal->slots[slot].sec == sec)
    {
        // Current slot, update
        brutal->slots[slot].acked += rs->acked_sacked;
        brutal->slots[slot].losses += rs->losses;
    }
    else
    {
        // Uninitialized slot or slot expired
        brutal->slots[slot].sec = sec;
        brutal->slots[slot].acked = rs->acked_sacked;
        brutal->slots[slot].losses = rs->losses;
    }

    brutal_update_rate(sk);
}

static u32 brutal_undo_cwnd(struct sock *sk)
{
    return brutal_tcp_snd_cwnd(tcp_sk(sk));
}

static u32 brutal_ssthresh(struct sock *sk)
{
    return tcp_sk(sk)->snd_ssthresh;
}

static struct tcp_congestion_ops tcp_brutal_ops = {
    .flags = TCP_CONG_NON_RESTRICTED,
    .name = "brutal",
    .owner = THIS_MODULE,
    .init = brutal_init,
    .cong_control = brutal_main,
    .undo_cwnd = brutal_undo_cwnd,
    .ssthresh = brutal_ssthresh,
};

static int __init brutal_register(void)
{
    int err;

    BUILD_BUG_ON(sizeof(struct brutal) > ICSK_CA_PRIV_SIZE);
    BUILD_BUG_ON(PKT_INFO_SLOTS < 1);

#if IS_ENABLED(CONFIG_SYSCTL)
    brutal_sysctl_header = register_net_sysctl(&init_net, "net/ipv4", brutal_sysctl_table);
    if (IS_ERR(brutal_sysctl_header)) {
        err = PTR_ERR(brutal_sysctl_header);
        brutal_sysctl_header = NULL;
        return err;
    }
#endif

    tcp_prot_override = tcp_prot;
    tcp_prot_override.setsockopt = brutal_tcp_setsockopt;

#ifdef _TRANSP_V6_H
    tcpv6_prot_override = tcpv6_prot;
    tcpv6_prot_override.setsockopt = brutal_tcpv6_setsockopt;
#endif // _TRANSP_V6_H

    err = tcp_register_congestion_control(&tcp_brutal_ops);
    if (err) {
#if IS_ENABLED(CONFIG_SYSCTL)
        if (brutal_sysctl_header) {
            unregister_net_sysctl_table(brutal_sysctl_header);
            brutal_sysctl_header = NULL;
        }
#endif
    }
    return err;
}

static void __exit brutal_unregister(void)
{
    tcp_unregister_congestion_control(&tcp_brutal_ops);
#if IS_ENABLED(CONFIG_SYSCTL)
    if (brutal_sysctl_header) {
        unregister_net_sysctl_table(brutal_sysctl_header);
        brutal_sysctl_header = NULL;
    }
#endif
}

module_init(brutal_register);
module_exit(brutal_unregister);

MODULE_AUTHOR("Aperture Internet Laboratory");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("TCP Brutal");
MODULE_VERSION("1.0.4");
