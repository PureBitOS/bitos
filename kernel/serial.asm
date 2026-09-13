; BitOS v0.3 — COM1 serial driver (0x3F8, 38400 8N1).
; The shell mirrors everything here so QEMU `-serial stdio` shows it
; and scripted tests can assert on exact text.
;   serial_init, serial_putc (al = char), serial_print (rsi = string)

global serial_init, serial_putc, serial_print

section .text
bits 64

COM1 equ 0x3F8

serial_init:
    push rax
    push rdx
    mov dx, COM1 + 1
    xor al, al
    out dx, al                   ; disable interrupts
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al                   ; enable DLAB
    mov dx, COM1                 ; divisor 3 = 38400 baud
    mov al, 3
    out dx, al
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x03
    out dx, al                   ; 8N1
    mov dx, COM1 + 2
    mov al, 0xC7
    out dx, al                   ; FIFO on, clear, 14-byte threshold
    mov dx, COM1 + 4
    mov al, 0x0B
    out dx, al                   ; DTR+RTS, OUT2 (IRQs, unused)
    pop rdx
    pop rax
    ret

; al = char
serial_putc:
    push rdx
    mov ah, al                   ; stash char (wait loop clobbers al)
    mov dx, COM1 + 5
.wait:
    in al, dx
    test al, 0x20                ; THR empty?
    jz .wait
    mov al, ah
    mov dx, COM1
    out dx, al
    pop rdx
    ret

; rsi = NUL string
serial_print:
    push rax
    push rsi
.next:
    lodsb
    test al, al
    jz .done
    call serial_putc
    jmp .next
.done:
    pop rsi
    pop rax
    ret
