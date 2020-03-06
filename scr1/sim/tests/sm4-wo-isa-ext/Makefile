src_dir := $(dir $(lastword $(MAKEFILE_LIST)))

c_src := sc_print.c sm4-wo-isa-ext.c

include $(inc_dir)/common.mk

default: $(bld_dir)/sm4-isa-ext.elf $(bld_dir)/sm4-wo-isa-ext.hex $(bld_dir)/sm4-wo-isa-ext.dump

clean:
	$(RM) $(c_objs) $(asm_objs) $(bld_dir)/sm4-wo-isa-ext.elf $(bld_dir)/sm4-wo-isa-ext.hex $(bld_dir)/sm4-wo-isa-ext.dump
