all: bitos.iso

kernel.bin: kernel/multiboot_header.asm kernel/boot.asm kernel/linker.ld
	nasm -f elf64 kernel/multiboot_header.asm -o kernel/multiboot_header.o
	nasm -f elf64 kernel/boot.asm -o kernel/boot.o
	ld -n -T kernel/linker.ld -o iso/boot/kernel.bin kernel/multiboot_header.o kernel/boot.o

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
