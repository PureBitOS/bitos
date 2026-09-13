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

section .text
bits 32

; ---- Kernel foundation: named constants ----
VGA_ADDR equ 0xb8000
VGA_COLS equ 80
VGA_ROWS equ 25
MULTIBOOT_MAGIC equ 0x36d76289
EFER_MSR equ 0xC0000080

start:
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

    ; Clear VGA text buffer: 80x25 cells of white-on-black space.
    mov edi, VGA_ADDR
    mov eax, 0x0F200F20
    mov ecx, (VGA_COLS * VGA_ROWS) / 2
    rep stosd

    ; Line 0 (light green): main banner.
    mov edi, VGA_ADDR + 0 * VGA_COLS * 2
    mov esi, msg_banner
    mov ah, 0x0A
    call print_string_64

    ; Line 1 (gray): foundation status.
    mov edi, VGA_ADDR + 1 * VGA_COLS * 2
    mov esi, msg_status
    mov ah, 0x07
    call print_string_64

    ; Line 2 (dark gray): next step hint.
    mov edi, VGA_ADDR + 2 * VGA_COLS * 2
    mov esi, msg_next
    mov ah, 0x08
    call print_string_64

    cli
.hang:
    hlt
    jmp .hang

; print NUL-terminated string: rsi = chars, rdi = VGA cell ptr, ah = colour.
print_string_64:
    lodsb
    test al, al
    jz .done
    stosw                     ; writes ax (al=char, ah=colour), rdi += 2
    jmp print_string_64
.done:
    ret

section .rodata
msg_banner: db "BitOS v0.2 - 64-bit long mode engaged!", 0
msg_status: db "kernel: stack + 1GiB paging + GDT OK | halting.", 0
msg_next:   db "next: keyboard + basic shell.", 0

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
align 4096
p4_table:
    resb 4096
p3_table:
    resb 4096
p2_table:
    resb 4096
stack_bottom:
    resb 16384                 ; 16 KiB bootstrap stack
stack_top:
