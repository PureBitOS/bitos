; BitOS v0.2 — 32-bit bootstrap: checks + paging + jump to 64-bit long mode.
; Roadmap milestone 1: "Long mode + better kernel foundation".
;
; Flow: start (32-bit, from GRUB Multiboot2) -> checks -> identity-map first
; 1 GiB with 2 MiB pages -> enable PAE + LME + paging -> far jump to
; long_mode_start (64-bit) -> clear VGA -> print messages -> halt.
;
; Error codes (red "ERR:X" in top-left, then halt):
;   ERR:M = bad Multiboot2 magic | ERR:C = no CPUID | ERR:L = no long mode

global start
global p3_table                  ; PDPT for pcibar.mmio_map
extern con_clear, con_print_c, con_setpos
extern fb_setup
extern serial_init, serial_print
extern pic_remap, idt_install
extern mmap_parse
extern shell_run
extern gui_run                    ; Prism desktop (GRUB "prism" arg)

section .text
bits 32

; ---- Kernel foundation: named constants ----
VGA_ADDR equ 0xb8000
VGA_COLS equ 80
VGA_ROWS equ 25
MULTIBOOT_MAGIC equ 0x36d76289
EFER_MSR equ 0xC0000080

start:
    mov [mb_info], ebx        ; Multiboot2 info pointer (for memory map)
    mov esp, stack_top        ; bootstrap stack (see .bss)

    call check_multiboot
    call check_cpuid
    call check_long_mode

    call setup_page_tables
    call enable_paging

    lgdt [gdt64.pointer]      ; load 64-bit GDT
    jmp gdt64.code:long_mode_start
    hlt                       ; never reached

; ---- Pre-flight checks (32-bit) ----
check_multiboot:
    cmp eax, MULTIBOOT_MAGIC
    jne .no_multiboot
    ret
.no_multiboot:
    mov al, 'M'
    jmp error

check_cpuid:
    pushfd                    ; try flipping ID bit (21) in EFLAGS
    pop eax
    mov ecx, eax
    xor eax, 1 << 21
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd
    cmp eax, ecx
    je .no_cpuid
    ret
.no_cpuid:
    mov al, 'C'
    jmp error

check_long_mode:
    mov eax, 0x80000000       ; extended CPUID available?
    cpuid
    cmp eax, 0x80000001
    jb .no_long_mode
    mov eax, 0x80000001       ; LM bit = EDX bit 29?
    cpuid
    test edx, 1 << 29
    jz .no_long_mode
    ret
.no_long_mode:
    mov al, 'L'
    jmp error

; ---- Paging: identity-map first 1 GiB with 2 MiB pages ----
; p4_table[0] -> p3_table, p3_table[0] -> p2_table,
; p2_table[i] maps 2 MiB physical frame i (present + writable + huge).
setup_page_tables:
    mov eax, p3_table
    or eax, 0b11              ; present + writable
    mov [p4_table], eax

    mov eax, p2_table
    or eax, 0b11
    mov [p3_table], eax

    mov ecx, 0
.map_p2:
    mov eax, 0x200000         ; 2 MiB
    mul ecx                   ; eax = frame base address
    or eax, 0b10000011        ; present + writable + huge page
    mov [p2_table + ecx * 8], eax
    inc ecx
    cmp ecx, 512              ; whole 1 GiB mapped?
    jne .map_p2
    ret

enable_paging:
    mov eax, p4_table         ; load PML4
    mov cr3, eax
    mov eax, cr4              ; enable PAE
    or eax, 1 << 5
    mov cr4, eax
    mov ecx, EFER_MSR         ; enable long mode (LME)
    rdmsr
    or eax, 1 << 8
    wrmsr
    mov eax, cr0              ; enable paging
    or eax, 1 << 31
    mov cr0, eax
    ret

; ---- Fatal error: red "ERR:X" top-left, halt. (al = code letter) ----
; Preserve the code across the VGA writes.
error:
    mov bl, al
    mov dword [VGA_ADDR + 0*2], 0x4f524f45   ; "ER" white-on-red
    mov dword [VGA_ADDR + 2*2], 0x4f3a4f52   ; "R:"
    mov byte  [VGA_ADDR + 4*2], bl
    mov byte  [VGA_ADDR + 4*2 + 1], 0x4f
    cli
.hang:
    hlt
    jmp .hang

; ---- 64-bit kernel (long mode) ----
bits 64
long_mode_start:
    mov ax, gdt64.data        ; data selector for all segment regs
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    cld                       ; string ops go forward (lodsb/stosw below)

    call serial_init
    mov edi, [mb_info]        ; parse Multiboot2 memory map now
    call mmap_parse           ; (identity-mapped, < 4 GiB)
    mov edi, [mb_info]        ; framebuffer? (GOP/HDMI or VBE, else VGA)
    call fb_setup             ; selects + clears the console

    ; Line 0 (light green): main banner.
    xor edi, edi              ; row 0
    xor esi, esi              ; col 0
    call con_setpos
    mov esi, msg_banner
    mov ah, 0x0A
    call con_print_c

    ; Line 1 (gray): foundation status.
    mov edi, 1
    xor esi, esi
    call con_setpos
    mov esi, msg_status
    mov ah, 0x07
    call con_print_c

    ; Shell owns the screen from row 3 on.
    mov edi, 3
    xor esi, esi
    call con_setpos

    mov esi, msg_banner
    call serial_print
    mov esi, msg_nl
    call serial_print

    call pic_remap            ; 8259: vectors 0x20/0x28, IRQ1 open
    call idt_install          ; exceptions + IRQ1 keyboard gate
    mov esi, msg_kbd
    call serial_print

    sti                       ; enable keyboard interrupts
    mov edi, [mb_info]
    call check_prism            ; "prism" on kernel cmdline? -> GUI first
    test eax, eax
    jz .shell
    call gui_run                ; Prism desktop (Esc returns here)
.shell:
    call shell_run            ; never returns (`halt` stops the CPU)
    cli
.hang:
    hlt
    jmp .hang

; scan multiboot2 cmdline (tag 1) for "prism". rdi = mb info.
; out: eax = 1 found, 0 not. Preserves rbx,rcx,rdx,rsi,rdi.
check_prism:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, rdi
    mov eax, [rsi]
    cmp eax, 8
    jb .no
    add rsi, 8
.tag:
    mov eax, [rsi]
    cmp eax, 0
    je .no
    cmp eax, 1
    je .cmdline
    mov eax, [rsi + 4]
    add eax, 7
    and eax, ~7
    add rsi, rax
    jmp .tag
.cmdline:
    lea rsi, [rsi + 8]            ; NUL-terminated cmdline string
    mov ecx, 256                  ; scan at most 256 bytes
.scan:
    test ecx, ecx
    jz .no
    mov al, [rsi]
    test al, al
    jz .no
    cmp al, 'p'
    jne .next
    cmp byte [rsi + 1], 'r'
    jne .next
    cmp byte [rsi + 2], 'i'
    jne .next
    cmp byte [rsi + 3], 's'
    jne .next
    cmp byte [rsi + 4], 'm'
    jne .next
    mov eax, 1
    jmp .out
.next:
    inc rsi
    dec ecx
    jmp .scan
.no:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
msg_banner: db "BitOS v0.3 - keyboard + shell online!", 0
msg_status: db "kernel: long mode + IDT + PS/2 driver OK", 0
msg_nl:     db 0x0A, 0
msg_kbd:    db "keyboard: PS/2 ready, shell starting", 0x0A, 0

; ---- 64-bit GDT: null / code / data ----
align 8
gdt64:
    dq 0
.code: equ $ - gdt64
    dq (1 << 41) | (1 << 43) | (1 << 44) | (1 << 47) | (1 << 53) ; readable + exec + code/data + present + 64-bit (= 0x00209A0000000000)
.data: equ $ - gdt64
    dq (1 << 41) | (1 << 44) | (1 << 47)              ; writable + code/data + present (= 0x0000920000000000)
.pointer:
    dw $ - gdt64 - 1
    dq gdt64

; ---- Reserved: page tables + bootstrap stack (zeroed, in .bss) ----
section .bss
mb_info:                     ; Multiboot2 info pointer saved at entry
    resd 1
alignb 4096                  ; (alignb, not align: no init in NOBITS)
p4_table:
    resb 4096
p3_table:
    resb 4096
p2_table:
    resb 4096
stack_bottom:
    resb 16384                 ; 16 KiB bootstrap stack
stack_top:
