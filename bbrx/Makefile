# Out-of-tree build for BBRX (tcp_bbr.c → tcp_bbr.ko, congestion name "bbrx").
#
# Requires kernel headers for the *running* kernel (or the kernel you will load into):
#   Debian/Ubuntu: apt install linux-headers-$(uname -r)
#   WSL2: use a kernel whose headers match linux-image (see README in parent repo).
#
# The source targets recent upstream BBR (v3); build against kernel 6.12+ recommended.

KERNEL_RELEASE ?= $(shell uname -r)
KERNEL_DIR     ?= /lib/modules/$(KERNEL_RELEASE)/build

obj-m          += tcp_bbr.o
ccflags-y      := -std=gnu99

# tcp_dctcp.h lives in the kernel tree (not shipped in this repo).
ccflags-y      += -I$(KERNEL_DIR)/net/ipv4

KMOD           := tcp_bbr.ko
DKMS_TARBALL   ?= tcp-bbrx.dkms.tar.gz
TAR            ?= tar

.PHONY: all clean load unload install check-kernel-dir
.PHONY: dkms-tarball clean-dkms-tarball dkms.conf clean-dkms.conf

check-kernel-dir:
	@test -d "$(KERNEL_DIR)" || (echo "Missing $(KERNEL_DIR); install linux-headers-$(KERNEL_RELEASE)" >&2; exit 1)
	@test -f tcp_bbr.c || (echo "Missing tcp_bbr.c in $(CURDIR)" >&2; exit 1)
	@test -f "$(KERNEL_DIR)/net/ipv4/tcp_dctcp.h" || (echo "Missing $(KERNEL_DIR)/net/ipv4/tcp_dctcp.h (kernel too old or incomplete headers?)" >&2; exit 1)

all: check-kernel-dir
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) modules

clean: clean-dkms.conf clean-dkms-tarball
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) clean 2>/dev/null || true

dkms.conf: scripts/mkdkmsconf.sh
	chmod +x scripts/mkdkmsconf.sh
	./scripts/mkdkmsconf.sh > $@

clean-dkms.conf:
	$(RM) -f dkms.conf

$(DKMS_TARBALL): dkms.conf Makefile tcp_bbr.c scripts/mkdkmsconf.sh
	$(TAR) zcf $(DKMS_TARBALL) \
		--transform 's,^,./dkms_source_tree/,' \
		dkms.conf \
		Makefile \
		tcp_bbr.c

dkms-tarball: $(DKMS_TARBALL)

clean-dkms-tarball:
	$(RM) -f $(DKMS_TARBALL)

load: all
	sudo insmod ./$(KMOD)

unload:
	-sudo rmmod tcp_bbr

install: all
	sudo install -D -m 644 ./$(KMOD) /lib/modules/$(KERNEL_RELEASE)/extra/$(KMOD)
	sudo depmod -a
