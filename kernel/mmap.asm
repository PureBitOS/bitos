; BitOS — physical memory discovery from the Multiboot2 info structure.
; GRUB passes the info pointer in EBX; boot.asm saves it and calls
; mmap_parse once. The `mem` shell command prints usable RAM regions.
; First half of driver foundations (memory before DMA/BARs).

global mmap_parse, mem_print
global mem_total                  ; read by Prism System app
global palloc                       ; bump allocator for DMA structures
extern sh_print, sh_putc, pci_hex

section .text
bits 64

REGION_MAX equ 32

; rdi = multiboot2 info physical address (< 4 GiB, identity-mapped)
mmap_parse:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov rsi, rdi
    mov eax, [rsi]               ; total_size (validate lightly)
    cmp eax, 8
    jb .done
    add rsi, 8                   ; first tag
.tag:
    mov eax, [rsi]               ; type (low 16) + flags
    and eax, 0xFFFF
    cmp eax, 0
    je .done                     ; end tag
    cmp eax, 6
    je .mmap_tag
.next:
    mov eax, [rsi + 4]           ; size
    add eax, 7
    and eax, ~7                  ; 8-byte aligned
    add rsi, rax
    jmp .tag
.mmap_tag:
    push r8
    push r9
    mov eax, [rsi + 4]           ; tag size
    lea r8, [rsi + rax]          ; r8 = tag end
    mov r9d, [rsi + 8]           ; r9 = entry_size (24)
    add rsi, 16                  ; first entry
.entry:
    cmp rsi, r8
    jae .entries_done
    mov eax, [rsi + 16]          ; entry type
    cmp eax, 1                   ; 1 = available RAM
    jne .skip_entry
    mov rax, [mem_count]
    cmp rax, REGION_MAX
    jae .skip_entry
    mov rbx, [rsi]               ; base (rbx/rdx saved at fn entry)
    mov rdx, [rsi + 8]           ; length
    mov [mem_base + rax * 8], rbx
    mov [mem_len + rax * 8], rdx
    inc qword [mem_count]
    add [mem_total], rdx
.skip_entry:
    add rsi, r9
    jmp .entry
.entries_done:
    mov rsi, r8                  ; resume tag walk at next tag
    pop r9
    pop r8
    jmp .tag
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- `mem` shell command ----
mem_print:
    push rax
    push rbx
    push rcx
    push rsi
    lea rsi, [msg_mem_head]
    call sh_print
    xor ebx, ebx                 ; index
.line:
    cmp rbx, [mem_count]
    jae .total
    mov rax, [mem_base + rbx * 8]
    mov ecx, 16
    call pci_hex                 ; base (16 hex digits)
    mov al, '-'
    call sh_putc
    mov rax, [mem_base + rbx * 8]
    add rax, [mem_len + rbx * 8]
    mov ecx, 16
    call pci_hex                 ; end = base + length
    lea rsi, [msg_usable]
    call sh_print
    inc rbx
    jmp .line
.total:
    mov rax, [mem_total]
    shr rax, 20                  ; MiB
    call print_dec
    lea rsi, [msg_mib]
    call sh_print
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; rax = number -> decimal via sh_putc
print_dec:    push rax
    push rbx
    push rcx
    push rdx
    mov rbx, 10
    xor ecx, ecx                 ; digit count
    test rax, rax
    jnz .div
    mov al, '0'
    call sh_putc
    jmp .out
.div:
    xor edx, edx
    div rbx                      ; rax /= 10, rdx = digit
    push rdx
    inc ecx
    test rax, rax
    jnz .div
.pop:
    pop rax
    add al, '0'
    call sh_putc
    dec ecx
    jnz .pop
.out:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- palloc: bump allocator for DMA structures (xHCI rings/contexts) ----
; Arena: conventional RAM 0x200000..0x1000000 (identity-mapped, usable per
; Multiboot2 map on PCs; kernel image + tables live below 0x200000).
; rdi = size bytes, rsi = alignment (power of two) -> rax = phys (0 = fail)
PALLOC_BASE equ 0x200000
PALLOC_TOP  equ 0x1000000
palloc:
    push rbx
    push rcx
    push rdx
    mov rax, [palloc_next]
    test rax, rax
    jnz .have_base
    mov rax, PALLOC_BASE
.have_base:
    mov rbx, rsi
    dec rbx                        ; align mask
    add rax, rbx
    not rbx
    and rax, rbx                   ; round up
    mov rcx, rax
    add rcx, rdi                   ; end = aligned + size
    cmp rcx, PALLOC_TOP
    ja .fail
    mov [palloc_next], rcx
    jmp .out2
.fail:
    xor eax, eax
.out2:
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
msg_mem_head: db "Memory map (usable RAM):", 0x0A, 0
msg_usable:   db " usable", 0x0A, 0
msg_mib:      db " MiB usable total.", 0x0A, 0

section .bss
mem_base:  resq REGION_MAX
mem_len:   resq REGION_MAX
mem_count: resq 1
mem_total: resq 1
palloc_next: resq 1
