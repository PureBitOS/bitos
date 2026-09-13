; BitOS v0.3 — VGA text-mode driver (80x25, physical 0xb8000).
; Cursor-tracked output with scrolling + hardware cursor.
; All symbols use the System V 64-bit convention loosely:
;   vga_putc:        al = char (0x0A = newline)
;   vga_print_c:     rsi = NUL string, ah = colour
;   vga_backspace:   erase one cell left of cursor
;   vga_setpos:      rdi = row, rsi = col
;   vga_clear:       wipe screen, cursor home

global vga_clear, vga_putc, vga_print_c, vga_backspace, vga_setpos

section .text
bits 64

VGA_ADDR equ 0xb8000
VGA_COLS equ 80
VGA_ROWS equ 25
DEFAULT_ATTR equ 0x07            ; light gray on black

vga_clear:
    push rax
    push rcx
    push rdi
    mov edi, VGA_ADDR
    mov eax, 0x07200720          ; two gray spaces per dword
    mov ecx, (VGA_COLS * VGA_ROWS) / 2
    rep stosd
    mov qword [cursor_row], 0
    mov qword [cursor_col], 0
    call update_hw_cursor
    pop rdi
    pop rcx
    pop rax
    ret

; al = char
vga_putc:
    push rax
    push rcx
    push rdi
    push rsi
    cmp al, 0x0A
    je .newline
    mov rcx, [cursor_row]
    mov rsi, [cursor_col]
    cmp rsi, VGA_COLS
    jb .no_wrap
    xor rsi, rsi
    inc rcx
.no_wrap:
    mov [cursor_col], rsi
    mov [cursor_row], rcx
    cmp rcx, VGA_ROWS
    jb .no_scroll
    call vga_scroll
    mov rcx, VGA_ROWS - 1
    mov [cursor_row], rcx
.no_scroll:
    imul rdi, rcx, VGA_COLS
    add rdi, rsi
    shl rdi, 1
    add rdi, VGA_ADDR
    mov ah, DEFAULT_ATTR
    stosw
    inc qword [cursor_col]
    call update_hw_cursor
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret
.newline:
    mov qword [cursor_col], 0
    inc qword [cursor_row]
    mov rcx, [cursor_row]
    cmp rcx, VGA_ROWS
    jb .nl_done
    call vga_scroll
    mov qword [cursor_row], VGA_ROWS - 1
.nl_done:
    call update_hw_cursor
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; rsi = string, ah = colour (VGA only, no serial mirror)
vga_print_c:
    push rax
    push rcx
    push rdi
    push rsi
.next:
    lodsb
    test al, al
    jz .done
    cmp al, 0x0A
    je .nl
    mov rcx, [cursor_row]
    mov rdi, [cursor_col]
    cmp rdi, VGA_COLS
    jb .nowrap
    xor rdi, rdi
    inc rcx
.nowrap:
    mov [cursor_col], rdi
    mov [cursor_row], rcx
    cmp rcx, VGA_ROWS
    jb .noscroll
    push rax
    call vga_scroll
    pop rax
    mov rcx, VGA_ROWS - 1
    mov [cursor_row], rcx
.noscroll:
    imul rdi, rcx, VGA_COLS
    add rdi, [cursor_col]
    shl rdi, 1
    add rdi, VGA_ADDR
    stosw                        ; ax = char + colour in ah
    inc qword [cursor_col]
    jmp .next
.nl:
    mov qword [cursor_col], 0
    inc qword [cursor_row]
    mov rcx, [cursor_row]
    cmp rcx, VGA_ROWS
    jb .nl_ok
    call vga_scroll
    mov qword [cursor_row], VGA_ROWS - 1
.nl_ok:
    jmp .next
.done:
    call update_hw_cursor
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

vga_backspace:
    push rax
    push rdx
    mov rax, [cursor_col]
    test rax, rax
    jz .done                     ; col 0: refuse (protects prompt)
    dec rax
    mov [cursor_col], rax
    mov rdx, [cursor_row]
    imul rdx, rdx, VGA_COLS
    add rdx, rax
    shl rdx, 1
    add rdx, VGA_ADDR
    mov word [rdx], 0x0720
    call update_hw_cursor
.done:
    pop rdx
    pop rax
    ret

; rdi = row, rsi = col
vga_setpos:
    mov [cursor_row], rdi
    mov [cursor_col], rsi
    jmp update_hw_cursor

; scroll everything up one row, blank last row
vga_scroll:
    push rax
    push rcx
    push rsi
    push rdi
    mov rsi, VGA_ADDR + VGA_COLS * 2
    mov rdi, VGA_ADDR
    mov ecx, VGA_COLS * (VGA_ROWS - 1)
    rep movsw
    mov edi, VGA_ADDR + VGA_COLS * (VGA_ROWS - 1) * 2
    mov eax, 0x07200720
    mov ecx, VGA_COLS / 2
    rep stosd
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

update_hw_cursor:
    push rax
    push rdx
    mov rax, [cursor_row]
    imul rax, rax, VGA_COLS
    add rax, [cursor_col]        ; ax = linear position
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    mov dx, 0x3D5
    mov rax, [cursor_row]
    imul rax, rax, VGA_COLS
    add rax, [cursor_col]
    out dx, al                   ; low byte
    mov dx, 0x3D4
    mov al, 0x0E
    out dx, al
    mov dx, 0x3D5
    mov rax, [cursor_row]
    imul rax, rax, VGA_COLS
    add rax, [cursor_col]
    shr ax, 8
    out dx, al                   ; high byte
    pop rdx
    pop rax
    ret

section .bss
cursor_row:
    resq 1
cursor_col:
    resq 1
