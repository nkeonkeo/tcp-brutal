# Out-of-tree build for BBRX (tcp_bbrx.c → tcp_bbrx.ko, congestion name "bbrx").
#
# Requires kernel headers for the running kernel:
#   Debian/Ubuntu: apt install linux-headers-$(uname -r)

KERNEL_RELEASE ?= $(shell uname -r)
KERNEL_DIR     ?= /lib/modules/$(KERNEL_RELEASE)/build

obj-m          += tcp_bbrx.o
ccflags-y      := -std=gnu99 -DBBRX_OOT_MODULE

KMOD           := tcp_bbrx.ko
DKMS_TARBALL   ?= tcp-bbrx.dkms.tar.gz
TAR            ?= tar

.PHONY: all clean load unload install check-kernel-dir
.PHONY: dkms-tarball clean-dkms-tarball dkms.conf clean-dkms.conf

check-kernel-dir:
	@test -d "$(KERNEL_DIR)" || (echo "Missing $(KERNEL_DIR); install linux-headers-$(KERNEL_RELEASE)" >&2; exit 1)
	@test -f tcp_bbrx.c || (echo "Missing tcp_bbrx.c in $(CURDIR)" >&2; exit 1)

all: check-kernel-dir
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) modules

clean: clean-dkms.conf clean-dkms-tarball
	$(MAKE) -C $(KERNEL_DIR) M=$(CURDIR) clean 2>/dev/null || true

dkms.conf: scripts/mkdkmsconf.sh
	chmod +x scripts/mkdkmsconf.sh
	./scripts/mkdkmsconf.sh > $@

clean-dkms.conf:
	$(RM) -f dkms.conf

$(DKMS_TARBALL): dkms.conf Makefile tcp_bbrx.c bbrx-compat.h scripts/mkdkmsconf.sh
	$(TAR) zcf $(DKMS_TARBALL) \
		--transform 's,^,./dkms_source_tree/,' \
		dkms.conf \
		Makefile \
		tcp_bbrx.c \
		bbrx-compat.h

dkms-tarball: $(DKMS_TARBALL)

clean-dkms-tarball:
	$(RM) -f $(DKMS_TARBALL)

load: all
	sudo insmod ./$(KMOD)

unload:
	-sudo rmmod tcp_bbrx

install: all
	sudo install -D -m 644 ./$(KMOD) /lib/modules/$(KERNEL_RELEASE)/extra/$(KMOD)
	sudo depmod -a
