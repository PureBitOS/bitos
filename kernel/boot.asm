global start

section .text
bits 32
start:
    ; Clear screen a bit and print welcome message to VGA text buffer
    mov edi, 0xb8000
    mov ecx, 80*25
    mov ax, 0x0F20  ; white on black space
.clear:
    mov [edi], ax
    add edi, 2
    loop .clear

    ; Print "BitOS v0.1 - Bare metal rising!"
    mov edi, 0xb8000
    mov esi, msg
.print:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0A  ; light green
    mov [edi], ax
    add edi, 2
    jmp .print
.done:
    ; Halt forever (for now)
    cli
.hang:
    hlt
    jmp .hang

msg: db "BitOS v0.1 - Bare metal rising! (x64 foundation)", 0
