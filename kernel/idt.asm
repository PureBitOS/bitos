; BitOS v0.3 — IDT + 8259 PIC remap + interrupt stubs (64-bit).
;   pic_remap    : master -> 0x20, slave -> 0x28, only IRQ1 open
;   idt_install  : zero IDT, gate exceptions 0-31, IRQ1 -> 33, spurious -> 39
; Hardware IRQs used: IRQ1 (keyboard) only. Timer stays masked.

global pic_remap, idt_install, irq1_stub, irq_spurious
extern keyboard_handler
extern serial_print, serial_putc

section .text
bits 64

PIC1_CMD  equ 0x20
PIC1_DATA equ 0x21
PIC2_CMD  equ 0xA0
PIC2_DATA equ 0xA1

io_wait:
    push rax
    xor eax, eax
    out 0x80, al                 ; dead port: ~1us delay
    pop rax
    ret

pic_remap:
    push rax
    mov al, 0x11
    out PIC1_CMD, al
    call io_wait
    out PIC2_CMD, al
    call io_wait
    mov al, 0x20                 ; master vector offset 32
    out PIC1_DATA, al
    call io_wait
    mov al, 0x28                 ; slave vector offset 40
    out PIC2_DATA, al
    call io_wait
    mov al, 0x04                 ; slave chained at IRQ2
    out PIC1_DATA, al
    call io_wait
    mov al, 0x02
    out PIC2_DATA, al
    call io_wait
    mov al, 0x01                 ; 8086 mode
    out PIC1_DATA, al
    call io_wait
    out PIC2_DATA, al
    call io_wait
    mov al, 0xF9                 ; master: everything masked except
    out PIC1_DATA, al            ; IRQ1 (kbd) + IRQ2 (cascade)
    mov al, 0xFF                 ; slave: fully masked
    out PIC2_DATA, al
    pop rax
    ret

; ---- IDT ----
; rdi = vector, rsi = handler address
idt_gate:
    push rax
    lea rax, [idt]
    shl rdi, 4
    add rax, rdi
    mov rdi, rsi                 ; handler -> rdi for shifting
    mov word [rax], di           ; offset[15:0]
    mov word [rax + 2], 0x08     ; code selector
    mov byte [rax + 4], 0        ; IST = 0
    mov byte [rax + 5], 0x8E     ; present, DPL0, 64-bit interrupt gate
    shr rdi, 16
    mov word [rax + 6], di       ; offset[31:16]
    shr rdi, 16
    mov dword [rax + 8], edi     ; offset[63:32]
    mov dword [rax + 12], 0
    pop rax
    ret

idt_install:
    push rax
    push rcx
    push rdi
    push rsi
    lea rdi, [idt]               ; zero all 256 entries first
    xor eax, eax
    mov ecx, 512                 ; 256 * 16 bytes = 512 qwords
    rep stosq
    xor edi, edi                 ; vectors 0..31 -> exception stubs
    lea rsi, [exc_table]
.vec_loop:
    mov rsi, [exc_table + rdi * 8]
    call idt_gate_vec            ; rdi=vec, rsi=handler
    inc rdi
    cmp rdi, 32
    jb .vec_loop
    mov rdi, 33                  ; IRQ1 -> keyboard stub
    lea rsi, [irq1_stub]
    call idt_gate_vec
    mov rdi, 39                  ; spurious IRQ7 -> silent return
    lea rsi, [irq_spurious]
    call idt_gate_vec
    lidt [idtr]
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; helper: rdi preserved across idt_gate (which shifts rdi) — reload pattern
idt_gate_vec:
    push rdi
    call idt_gate
    pop rdi
    ret

; ---- IRQ stubs ----
irq1_stub:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    cld
    call keyboard_handler
    mov al, 0x20                 ; EOI to master
    out PIC1_CMD, al
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    iretq

irq_spurious:                    ; spurious IRQ7 needs no EOI
    iretq

; ---- CPU exception stubs ----
; Each pushes a dummy error code when the CPU doesn't, then the vector,
; then funnels into exc_common. Stack: [vec][code][rip]...
%macro EXC_STUB 1
exc_%1:
%if %1 != 8 && %1 != 10 && %1 != 11 && %1 != 12 && %1 != 13 && %1 != 14 && %1 != 17 && %1 != 21 && %1 != 29 && %1 != 30
    push 0                       ; dummy error code
%endif
    push %1
    jmp exc_common
%endmacro

EXC_STUB 0
EXC_STUB 1
EXC_STUB 2
EXC_STUB 3
EXC_STUB 4
EXC_STUB 5
EXC_STUB 6
EXC_STUB 7
EXC_STUB 8
EXC_STUB 9
EXC_STUB 10
EXC_STUB 11
EXC_STUB 12
EXC_STUB 13
EXC_STUB 14
EXC_STUB 15
EXC_STUB 16
EXC_STUB 17
EXC_STUB 18
EXC_STUB 19
EXC_STUB 20
EXC_STUB 21
EXC_STUB 22
EXC_STUB 23
EXC_STUB 24
EXC_STUB 25
EXC_STUB 26
EXC_STUB 27
EXC_STUB 28
EXC_STUB 29
EXC_STUB 30
EXC_STUB 31

exc_table:
%assign i 0
%rep 32
    dq exc_%[i]
%assign i i+1
%endrep

; Red "CPU FAULT #hh" + halt. [rsp] = vector.
exc_common:
    cli
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi                      ; 48 bytes; frame now at +48
    lea rsi, [exc_serial]
    call serial_print
    mov rax, [rsp + 48]           ; vec
    call exc_hex8
    mov al, ' '
    call serial_putc
    mov rax, [rsp + 56]           ; err
    call exc_hex8
    mov al, ' '
    call serial_putc
    mov rax, [rsp + 64]           ; fault rip
    call exc_hex16
    mov al, ' '
    call serial_putc
    mov rdi, [rsp + 88]           ; pre-fault rsp
    mov rax, rdi
    call exc_hex16
    mov al, ' '
    call serial_putc
    mov rax, [rdi]                ; 4 qwords at pre-fault rsp
    call exc_hex16
    mov al, ' '
    call serial_putc
    mov rax, [rdi + 8]
    call exc_hex16
    mov al, ' '
    call serial_putc
    mov rax, [rdi + 16]
    call exc_hex16
    mov al, ' '
    call serial_putc
    mov rax, [rdi + 24]
    call exc_hex16
    mov al, ' '
    call serial_putc
    mov rax, [rdi + 32]          ; deeper stack: expect return addresses
    call exc_hex16
    mov al, ' '
    call serial_putc
    mov rax, [rdi + 40]
    call exc_hex16
    mov al, 0x0A
    call serial_putc
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    mov rsi, [rsp]               ; vector number (re-read)
    mov dword [0xb8000], 0x4f554f43       ; "CU"
    mov dword [0xb8004], 0x4f204f50       ; "P "
    mov dword [0xb8008], 0x4c554146       ; "FA"
    mov dword [0xb800c], 0x54204f4c       ; "LT"
    mov dword [0xb8010], 0x23204f20       ; " #"
    mov rax, rsi
    shr al, 4
    call .nibble
    mov [0xb8018], al
    mov byte [0xb8019], 0x4f
    mov rax, rsi
    call .nibble
    mov [0xb801a], al
    mov byte [0xb801b], 0x4f
.hang:
    hlt
    jmp .hang
.nibble:                         ; al low 4 bits -> hex char in al
    and al, 0x0F
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    ret
.digit:
    add al, '0'
    ret

; fault forensics over serial: rax -> hex (ecx = digits), clobbers rax/rcx
exc_hex8:
    push rcx
    mov ecx, 8
    jmp exc_hex_go
exc_hex16:
    push rcx
    mov ecx, 16
exc_hex_go:
    push rax
    push rbx
    push rdx
    mov rbx, rax
    mov edx, ecx
.hex_top:
    dec edx
    mov cl, dl
    shl cl, 2
    mov rax, rbx
    shr rax, cl
    and al, 0x0F
    cmp al, 10
    jb .hex_d
    add al, 'A' - 10
    jmp .hex_o
.hex_d:
    add al, '0'
.hex_o:
    call serial_putc
    test edx, edx
    jnz .hex_top
    pop rdx
    pop rbx
    pop rax
    pop rcx
    ret

section .rodata
align 8
exc_serial: db "FAULT vec=", 0
idtr:
    dw 256 * 16 - 1
    dq idt

section .bss
align 16
idt:
    resb 256 * 16
