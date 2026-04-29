# SPDX-License-Identifier: GPL-2.0
#
# Makefile for the kernel software bcache
#

KERNEL_RELEASE	:= $(shell uname -r)
KDIR		:= /lib/modules/$(KERNEL_RELEASE)/build
PWD		:= $(CURDIR)

obj-m		+= src/

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

compile_commands.json:
	+$(MAKE) -C $(KDIR) M=$(PWD) compile_commands.json 2>/dev/null || true

clangd: compile_commands.json

.PHONY: all clean clangd
