; BitOS v0.3 — tiny shell: prompt, line editing, built-in commands.
; Every byte goes to VGA *and* serial (scripted QEMU tests read serial).
;   shell_run  (never returns; `halt` stops the CPU)

global shell_run
global sh_putc, sh_print          ; reused by pci.asm (devices output)
extern vga_putc, vga_backspace, vga_clear
extern serial_putc
extern kbd_getc
extern pci_scan

section .text
bits 64

LINE_MAX equ 120

; ---- output helpers (VGA + serial) ----
sh_putc:                         ; al = char
    push rax
    call vga_putc
    call serial_putc
    pop rax
    ret

sh_print:                        ; rsi = NUL string
    push rax
    push rsi
.next:
    lodsb
    test al, al
    jz .done
    call sh_putc
    jmp .next
.done:
    pop rsi
    pop rax
    ret

; ---- string compare: rsi = input, rdx = command -> rax = 1 if equal ----
streq:
    push rcx
    push rsi
    push rdx
.loop:
    mov cl, [rsi]
    cmp cl, [rdx]
    jne .no
    test cl, cl
    jz .yes
    inc rsi
    inc rdx
    jmp .loop
.yes:
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop rdx
    pop rsi
    pop rcx
    ret

shell_run:
    lea rsi, [msg_welcome]
    call sh_print
.prompt:
    lea rsi, [msg_prompt]
    call sh_print
    xor ebx, ebx                 ; line length (rbx preserved? kbd clobbers
                                 ; rbx? handler saves/restores rbx. vga_putc
                                 ; preserves all but flags. serial_putc only
                                 ; rdx. sh_* preserve. SAFE.)
.read_key:
    call kbd_getc                ; -> al (clobbers rax only)
    cmp al, 0x0A                 ; Enter
    je .exec
    cmp al, 0x08                 ; Backspace
    je .bs
    cmp al, 0x20                 ; printable?
    jb .read_key
    cmp al, 0x7E
    ja .read_key
    cmp rbx, LINE_MAX
    jae .read_key                ; line full: swallow
    mov [shell_buf + rbx], al
    inc rbx
    call sh_putc                 ; echo
    jmp .read_key
.bs:
    test rbx, rbx
    jz .read_key                 ; empty: protect prompt
    dec rbx
    call vga_backspace
    mov al, 0x08                 ; "\b \b" on serial
    call serial_putc
    mov al, ' '
    call serial_putc
    mov al, 0x08
    call serial_putc
    jmp .read_key
.exec:
    mov byte [shell_buf + rbx], 0
    mov al, 0x0A
    call sh_putc
    test rbx, rbx
    jz .prompt                   ; empty line: reprompt
    lea rsi, [shell_buf]
    lea rdx, [cmd_help]
    call streq
    test rax, rax
    jnz .do_help
    lea rsi, [shell_buf]
    lea rdx, [cmd_ver]
    call streq
    test rax, rax
    jnz .do_ver
    lea rsi, [shell_buf]
    lea rdx, [cmd_clear]
    call streq
    test rax, rax
    jnz .do_clear
    lea rsi, [shell_buf]
    lea rdx, [cmd_halt]
    call streq
    test rax, rax
    jnz .do_halt
    lea rsi, [shell_buf]
    lea rdx, [cmd_devices]
    call streq
    test rax, rax
    jnz .do_devices
    lea rsi, [shell_buf]         ; echo <text>?
    lea rdx, [cmd_echo]
    call streq_prefix            ; -> rax=1, rcx = rest pointer
    test rax, rax
    jnz .do_echo
    lea rsi, [msg_unknown]
    call sh_print
    lea rsi, [shell_buf]
    call sh_print
    mov al, 0x0A
    call sh_putc
    jmp .prompt
.do_help:
    lea rsi, [msg_help]
    call sh_print
    jmp .prompt
.do_ver:
    lea rsi, [msg_ver]
    call sh_print
    jmp .prompt
.do_clear:
    call vga_clear
    jmp .prompt
.do_echo:                        ; rcx = text after "echo "
    mov rsi, rcx
    call sh_print
    mov al, 0x0A
    call sh_putc
    jmp .prompt
.do_halt:
    lea rsi, [msg_halt]
    call sh_print
    cli
.hang:
    hlt
    jmp .hang
.do_devices:
    call pci_scan
    jmp .prompt

; prefix match "echo " or bare "echo": rsi=input, rdx=cmd
; -> rax = 1/0, rcx = rest ("" if bare)
streq_prefix:
    push rsi
    push rdx
.loop:
    mov cl, [rdx]
    test cl, cl
    jz .cmd_end
    cmp cl, [rsi]
    jne .no
    inc rsi
    inc rdx
    jmp .loop
.cmd_end:
    cmp byte [rsi], 0            ; bare "echo"
    je .bare
    cmp byte [rsi], ' '          ; "echo <...>"
    jne .no
    inc rsi
    mov rcx, rsi
    mov eax, 1
    jmp .out
.bare:
    lea rcx, [empty_str]
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop rdx
    pop rsi
    ret

section .rodata
msg_welcome: db "Type 'help' and press Enter. PS/2 keyboard ready.", 0x0A, 0
msg_prompt:  db "bitos> ", 0
msg_unknown: db "unknown command: ", 0
msg_help:    db "Commands:", 0x0A
             db "  help       - this list", 0x0A
             db "  ver        - BitOS version", 0x0A
             db "  echo <txt> - print text", 0x0A
             db "  clear      - clear screen", 0x0A
             db "  devices    - list PCI hardware", 0x0A
             db "  halt       - stop the CPU", 0x0A, 0
msg_ver:     db "BitOS v0.3 (long mode + keyboard + shell)", 0x0A, 0
msg_halt:    db "halting. bye!", 0x0A, 0
cmd_help:    db "help", 0
cmd_ver:     db "ver", 0
cmd_clear:   db "clear", 0
cmd_halt:    db "halt", 0
cmd_devices: db "devices", 0
cmd_echo:    db "echo", 0
empty_str:   db 0

section .bss
shell_buf: resb 128
