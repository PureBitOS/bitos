ASM_SRCS := kernel/multiboot_header.asm kernel/boot.asm kernel/vga.asm kernel/serial.asm kernel/idt.asm kernel/kbd.asm kernel/shell.asm kernel/pci.asm
ASM_OBJS := $(ASM_SRCS:.asm=.o)

all: bitos.iso

kernel/%.o: kernel/%.asm
	nasm -f elf64 $< -o $@

kernel.bin: $(ASM_OBJS) kernel/linker.ld
	ld -n -T kernel/linker.ld -o iso/boot/kernel.bin $(ASM_OBJS)

bitos.iso: kernel.bin
	grub-mkrescue -o bitos.iso iso

run: bitos.iso
	qemu-system-x86_64 -cdrom bitos.iso -display none -serial stdio || qemu-system-x86_64 -cdrom bitos.iso

clean:
	rm -f kernel/*.o iso/boot/kernel.bin bitos.iso

# Native Windows cmd.exe (no rm): del instead of rm
clean-win:
	del /Q kernel\*.o iso\boot\kernel.bin bitos.iso

.PHONY: all run clean clean-win
