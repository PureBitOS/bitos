; BitOS v0.3 — PS/2 keyboard driver (scancode set 1, US layout).
; IRQ1 context calls keyboard_handler; shell pulls chars via kbd_getc.
; Special codes pushed to the buffer: 0x0A = Enter, 0x08 = Backspace.

global keyboard_handler, kbd_getc

section .text
bits 64

KBD_DATA   equ 0x60
KBD_STATUS equ 0x64

; Called from irq1_stub (caller-saved regs already pushed).
; Only rax/rcx/rdx/rsi/rdi may be clobbered here.
keyboard_handler:
    push rbx                     ; rbx NOT saved by stub — preserve it
.drain:
    in al, KBD_STATUS
    test al, 0x01                ; output buffer full?
    jz .done
    in al, KBD_DATA
    mov bl, al

    cmp bl, 0xE0                 ; extended prefix: swallow, ignore next
    jne .not_ext0
    mov byte [kbd_ext], 1
    jmp .drain
.not_ext0:
    cmp byte [kbd_ext], 0
    je .no_ext
    mov byte [kbd_ext], 0        ; extended key: arrows only, rest ignored
    cmp bl, 0x48
    je .arrow_up
    cmp bl, 0x50
    je .arrow_down
    cmp bl, 0x4B
    je .arrow_left
    cmp bl, 0x4D
    je .arrow_right
    jmp .drain
.arrow_up:
    mov al, 0x90
    call kbd_putc
    jmp .drain
.arrow_down:
    mov al, 0x91
    call kbd_putc
    jmp .drain
.arrow_left:
    mov al, 0x92
    call kbd_putc
    jmp .drain
.arrow_right:
    mov al, 0x93
    call kbd_putc
    jmp .drain
.no_ext:
    test bl, 0x80                ; release?
    jnz .release
    ; ---- press ----
    cmp bl, 0x2A                 ; left/right shift
    je .shift_on
    cmp bl, 0x36
    je .shift_on
    cmp bl, 0x1C                 ; Enter
    jne .not_enter
    mov al, 0x0A
    call kbd_putc
    jmp .drain
.not_enter:
    cmp bl, 0x0E                 ; Backspace
    jne .check_tab
    mov al, 0x08
    call kbd_putc
    jmp .drain
.check_tab:
    cmp bl, 0x0F                 ; Tab
    jne .check_esc
    mov al, 0x09
    call kbd_putc
    jmp .drain
.check_esc:
    cmp bl, 0x01                 ; Esc
    jne .lookup
    mov al, 0x1B
    call kbd_putc
    jmp .drain
.lookup:                         ; normal key: table by shift state
    cmp bl, 0x3A
    ja .drain                    ; outside 0x00-0x39 range (0x3A = Caps, skip)
    movzx eax, bl
    cmp byte [kbd_shift], 0
    je .unshifted
    mov al, [shift_map + rax]
    jmp .push
.unshifted:
    mov al, [key_map + rax]
.push:
    test al, al                  ; 0 = unmapped, drop
    jz .drain
    call kbd_putc
    jmp .drain
.shift_on:
    mov byte [kbd_shift], 1
    jmp .drain
.release:
    and bl, 0x7F
    cmp bl, 0x2A
    je .shift_off
    cmp bl, 0x36
    je .shift_off
    jmp .drain
.shift_off:
    mov byte [kbd_shift], 0
    jmp .drain
.done:
    pop rbx
    ret

; al = char. Drops when buffer full (256).
kbd_putc:
    push rcx
    push rdx
    mov rcx, [kbd_head]
    mov rdx, rcx
    sub rdx, [kbd_tail]
    cmp rdx, 256
    jae .full
    and ecx, 255
    mov [kbd_buf + rcx], al
    inc qword [kbd_head]
.full:
    pop rdx
    pop rcx
    ret

; Blocking read -> al. HLT-sleeps while empty (IRQs wake us).
kbd_getc:
    mov rax, [kbd_tail]
    cmp rax, [kbd_head]
    je .empty
    and eax, 255
    mov al, [kbd_buf + rax]
    inc qword [kbd_tail]
    ret
.empty:
    hlt
    jmp kbd_getc

section .rodata
; Scancode set 1 make codes 0x00-0x39 -> ASCII (0 = ignore).
key_map:
    db 0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0, 0
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 0, 0
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'", '`', 0, 0x5C
    db 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, 0, 0, ' '
shift_map:
    db 0, 0, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0, 0
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 0, 0
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|'
    db 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, 0, 0, ' '

section .bss
kbd_shift: resb 1
kbd_ext:   resb 1
kbd_buf:   resb 256
kbd_head:  resq 1
kbd_tail:  resq 1
