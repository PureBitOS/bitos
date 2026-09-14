; BitOS — PCI BAR inspection + MMIO mapping window.
; `bars` shell command: probes BAR0-5 of every PCI device (address, size,
; MMIO32/MMIO64/PIO/empty) via the standard write-all-ones sizing, then
; maps the first MMIO BAR through mmio_map and reads it back as proof.
; Next drivers (USB xHCI, display, NVMe) will consume mmio_map directly.
;
; mmio_map: rdi = phys addr, rsi = size bytes -> rax = virtual addr.
; Window: PDPT[510] (virt 0x7FC0000000+), 2 MiB pages, bump-allocated.

global bars_print, mmio_map
global mmio_next                 ; DEBUG visibility for nvme bring-up
extern sh_print, sh_putc, pci_hex
extern p3_table

section .text
bits 64

VIRT_MMIO_BASE equ 0x7F80000000   ; PDPT[510] start (510 * 1 GiB)
PAGE2M         equ 0x200000

; ---- raw config access (local copy; pci.asm owns the other one) ----
; rdi = bus, rsi = dev, rdx = func, rcx = reg -> eax
cfg_read:
    push rdx
    push rcx
    mov eax, edi
    shl eax, 16
    mov edx, esi
    shl edx, 11
    or eax, edx
    pop rcx
    pop rdx
    shl edx, 8
    or eax, edx
    and ecx, 0xFC
    or eax, ecx
    or eax, 0x80000000
    push rax
    mov dx, 0xCF8
    pop rax
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    ret

; rdi = bus, rsi = dev, rdx = func, rcx = reg, r8d = value
cfg_write:
    push rax
    push rbx
    mov eax, edi
    shl eax, 16                  ; bus
    mov ebx, esi
    shl ebx, 11                  ; device
    or eax, ebx
    shl edx, 8                   ; function
    or eax, edx
    and ecx, 0xFC
    or eax, ecx
    or eax, 0x80000000
    mov ebx, r8d                 ; value aside (preserved reg)
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    mov eax, ebx
    out dx, eax
    pop rbx
    pop rax
    ret

; ---- mmio_map: rdi = phys, rsi = size -> rax = virt ----
mmio_map:
    push rbx
    cmp qword [mmio_linked], 0   ; link PDPT[510] -> pd_mmio once
    jne .linked
    mov rax, pd_mmio
    or rax, 0b11
    mov [p3_table + 510 * 8], rax
    mov qword [mmio_linked], 1
.linked:
    mov rbx, rdi                 ; phys (preserved)
    mov rax, rdi
    shr rax, 21                  ; aligned base -> r8 (clear low 21 bits)
    shl rax, 21
    mov r8, rax
    mov rcx, rdi
    and rcx, (PAGE2M - 1)
    add rcx, rsi                 ; span = offset + size
    add rcx, PAGE2M - 1
    shr rcx, 21                  ; page count
    mov r9, [mmio_next]
    mov r10, r9
    shr r10, 21                  ; start page index
    mov r11, r10
.loop:
    test rcx, rcx
    jz .mapped
    mov rax, r8
    or rax, 0b10000011           ; present + writable + huge
    mov [pd_mmio + r11 * 8], rax
    mov rax, r11                 ; invlpg the new virtual page
    shl rax, 21
    mov rdx, VIRT_MMIO_BASE      ; movabs: full 64-bit immediate
    add rax, rdx
    invlpg [rax]
    add r8, PAGE2M
    inc r11
    dec rcx
    jmp .loop
.mapped:
    mov rax, r11                 ; bump allocator past new pages
    shl rax, 21
    mov [mmio_next], rax
    mov rax, VIRT_MMIO_BASE      ; movabs: full 64-bit immediate
    add rax, r9                  ; + window offset (once!)
    mov rcx, rbx
    and rcx, (PAGE2M - 1)        ; + in-page offset
    add rax, rcx
    pop rbx
    ret

; ---- one BAR probe+print. r15 = bus, r14 = dev, r13 = func ----
; r12 = bar index (advanced past a 64-bit pair). Preserves r13-r15, rbx.
probe_bar:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r13
    push r14
    push r15
    ; prefix "BB:DD.F BARn "
    mov eax, r15d
    mov ecx, 2
    call pci_hex
    mov al, ':'
    call sh_putc
    mov eax, r14d
    mov ecx, 2
    call pci_hex
    mov al, '.'
    call sh_putc
    mov eax, r13d
    mov ecx, 1
    call pci_hex
    mov al, ' '
    call sh_putc
    lea rsi, [str_bar]
    call sh_print
    mov eax, r12d
    mov ecx, 1
    call pci_hex
    mov al, ' '
    call sh_putc
    ; reg = 0x10 + bar*4
    mov ecx, r12d
    shl ecx, 2
    add ecx, 0x10
    mov r9d, ecx
    ; orig
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    call cfg_read
    mov ebx, eax
    ; mask (write all ones, read, restore)
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    mov ecx, r9d
    mov r8d, 0xFFFFFFFF
    call cfg_write
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    mov ecx, r9d
    call cfg_read
    mov r8d, eax                  ; mask
    push r8                       ; save mask across orig restore
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    mov ecx, r9d
    push rbx
    pop r8
    call cfg_write                ; restore orig (r8d = ebx low32)
    pop r8                        ; mask back (orig stays in ebx)
    ; empty?
    test ebx, ebx
    jnz .has_something
    test r8d, r8d
    jnz .has_something
    lea rsi, [str_empty]
    call sh_print
    mov al, 0x0A
    call sh_putc
    jmp .done
.has_something:
    test ebx, 1
    jnz .pio
    mov eax, ebx                  ; MMIO type bits
    shr eax, 1
    and eax, 3
    cmp eax, 2
    je .mmio64
    lea rsi, [str_mmio32]
    call sh_print
    mov eax, ebx
    and eax, ~0xF                 ; base
    mov r10d, eax
    mov eax, r8d
    and eax, ~0xF                 ; mask
    not eax
    inc eax                       ; size = ~mask + 1
    mov r11d, eax
    mov ecx, 8                    ; 32-bit print
    jmp .print_addr
.mmio64:
    lea rsi, [str_mmio64]
    call sh_print
    inc r12                       ; skip companion BAR (out-param)
    mov ecx, r9d
    add ecx, 4
    mov r10d, ecx                 ; companion reg
    mov rdi, r15                  ; high orig
    mov rsi, r14
    mov rdx, r13
    mov ecx, r10d
    call cfg_read
    mov r11d, eax
    mov rdi, r15                  ; high mask
    mov rsi, r14
    mov rdx, r13
    mov ecx, r10d
    mov r8d, 0xFFFFFFFF
    call cfg_write
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    mov ecx, r10d
    call cfg_read
    push rax                      ; high mask
    mov rdi, r15                  ; restore high orig
    mov rsi, r14
    mov rdx, r13
    mov ecx, r10d
    mov r8d, r11d
    call cfg_write
    pop rax                       ; high mask
    shl r11, 32                   ; r11d write zeroed upper, now hi<<32
    mov r10d, ebx
    and r10d, ~0xF
    or r11, r10                   ; r11 = base (64-bit)
    shl rax, 32                   ; maskhi << 32
    mov r10d, r8d
    and r10d, ~0xF
    or rax, r10                   ; rax = combined mask
    not rax
    inc rax                       ; rax = size
    mov r10, r11                  ; r10 = base
    mov r11, rax                  ; r11 = size
    mov ecx, 16
    jmp .print_addr
.pio:
    lea rsi, [str_pio]
    call sh_print
    or r9d, 0x80000000            ; marker: skip MMIO probe below
    mov eax, ebx
    and eax, ~3
    mov r10d, eax
    mov eax, r8d
    and eax, ~3
    not eax
    inc eax
    mov r11d, eax
    mov ecx, 8
    jmp .print_addr
.print_addr:                      ; ecx = digits, r10 = base, r11 = size
    mov al, '@'
    call sh_putc
    mov rax, r10
    call pci_hex
    lea rsi, [str_size]
    call sh_print
    mov rax, r11
    call pci_hex
    test r9d, 0x80000000          ; PIO? no probe
    jnz .eol
    cmp qword [bar_probed], 0
    jne .eol
    test r11, r11
    jz .eol
    mov qword [bar_probed], 1
    mov rdi, r10                  ; map first MMIO BAR as proof
    mov rsi, r11
    call mmio_map                 ; -> rax = virt
    push rax
    lea rsi, [str_probe]
    call sh_print
    pop rax
    mov eax, [rax]                ; read back through the mapping
    mov ecx, 8
    call pci_hex
.eol:
    mov al, 0x0A
    call sh_putc
.done:
    pop r15
    pop r14
    pop r13
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- bars_print: full scan (brute-force buses, no bridge chasing needed) ----
bars_print:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    lea rsi, [str_bars_head]
    call sh_print
    mov qword [bar_probed], 0
    xor r15d, r15d                ; bus 0..255
.bus:
    xor r14d, r14d                ; dev 0..31
.dev:
    mov rdi, r15                  ; vendor(func0): device present?
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    call cfg_read
    and eax, 0xFFFF
    cmp eax, 0xFFFF
    je .next_dev
    mov rdi, r15                  ; multifunction?
    mov rsi, r14
    xor edx, edx
    mov ecx, 0x0C
    call cfg_read
    shr eax, 16
    and eax, 0xFF
    mov r11d, 0
    test al, 0x80
    jz .funcs
    mov r11d, 7
.funcs:
    xor r13d, r13d                ; func
.func:
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    xor ecx, ecx
    call cfg_read
    and eax, 0xFFFF
    cmp eax, 0xFFFF
    je .next_func
    xor r12d, r12d                ; bar 0..5 (probe_bar skips pairs)
.bar:
    cmp r12d, 6
    jae .next_func
    call probe_bar
    inc r12d
    jmp .bar
.next_func:
    inc r13d
    cmp r13d, r11d
    jbe .func
.next_dev:
    inc r14d
    cmp r14d, 32
    jb .dev
    inc r15d
    cmp r15d, 256
    jb .bus
    lea rsi, [str_bars_done]
    call sh_print
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .rodata
str_bar:       db "BAR", 0
str_empty:     db "empty", 0
str_mmio32:    db "MMIO32", 0
str_mmio64:    db "MMIO64", 0
str_pio:       db "PIO", 0
str_size:      db " size ", 0
str_probe:     db " probe: map OK, [0]=", 0
str_bars_head: db "PCI BARs (bus:dev.func BARn type @addr size):", 0x0A, 0
str_bars_done: db "BAR scan done.", 0x0A, 0

section .bss
alignb 4096                  ; page table: PDPT entry needs low 12 bits zero
pd_mmio:     resb 4096
mmio_next:   resq 1
mmio_linked: resq 1
bar_probed:  resq 1
