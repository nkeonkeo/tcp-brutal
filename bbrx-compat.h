/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _BBRX_COMPAT_H_
#define _BBRX_COMPAT_H_

#include <linux/version.h>

/* Out-of-tree modules cannot use in-kernel BPF struct_ops kfuncs. */
#if defined(BBRX_OOT_MODULE) || LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
#define BBRX_NO_BTF 1
#endif

#ifdef BBRX_NO_BTF
#undef __bpf_kfunc
#define __bpf_kfunc
#endif

#ifndef GSO_LEGACY_MAX_SIZE
#define GSO_LEGACY_MAX_SIZE GSO_MAX_SIZE
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 1, 0)
static inline u32 bbrx_get_random_u32_below(u32 ceil)
{
	if (!ceil)
		return 0;
	return get_random_u32() % ceil;
}
#define get_random_u32_below bbrx_get_random_u32_below
#endif

#endif /* _BBRX_COMPAT_H_ */
