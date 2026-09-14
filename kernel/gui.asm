; Prism desktop environment + BitWM window manager (keyboard-driven).
; `gui` shell command. Apps: Settings (wallpaper/scale), System Info
; (live kernel data), About. Esc backs out; Esc in menu exits to shell.
; Everything real: wallpaper from stockwallpaper.png, values from drivers.

global gui_run
extern fb_present, fb_width, fb_height, con_scale
extern fb_virt, fb_pitch
extern mem_total, pci_count
extern wallpaper_blit, fill_rect_w, fb_text_at, fb_clear_raw
extern con_set_scale, con_clear
extern kbd_getc
extern serial_print
extern print_dec64
extern sh_print                   ; shell output (VGA+serial mirror)

section .text
bits 64

COL_BAR    equ 0x202A30
COL_WINBG  equ 0x16202E
COL_TITLE  equ 0x2E4A6B
COL_HI     equ 0x3B6EA5
COL_TEXT   equ 0xE6E6E6
COL_DIM    equ 0x888888
COL_GREEN  equ 0x00AA00

; gtext: rdi = x, rsi = y, rdx = str, ecx = colour
gtext:
    push rax
    push r8
    mov rax, rdx
    mov r8d, ecx
    call fb_text_at
    pop r8
    pop rax
    ret

; rect: rdi = x, rsi = y, rdx = w, rcx = h, r8d = colour
grect:
    jmp fill_rect_w                ; tail call (same convention)

; rax = u64 -> rsi = static decimal string (NUL). Destroys rax/rcx/rdx.
gui_dec:
    push rax
    push rbx
    push rcx
    push rdx
    lea rsi, [gui_numbuf + 20]
    mov byte [rsi], 0
    mov rbx, 10
    test rax, rax
    jnz .div
    dec rsi
    mov byte [rsi], '0'
    jmp .out
.div:
    xor edx, edx
    div rbx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .div
.out:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- desktop: wallpaper/pattern + top/bottom bars ----
draw_desktop:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    cmp byte [wallpaper_mode], 0
    jne .pattern
    call wallpaper_blit
    jmp .bars
.pattern:
    mov rdi, [fb_virt]
    mov rax, [fb_pitch]
    mul qword [fb_height]
    shr rax, 2
    mov rcx, rax
    mov eax, 0x101020
    rep stosd
.bars:
    ; top bar h=24
    mov rdi, 0
    xor esi, esi
    mov rdx, [fb_width]
    mov rcx, 24
    mov r8d, COL_BAR
    call fill_rect_w
    mov rdi, 8
    mov rsi, 8
    lea rdx, [str_prism]
    mov ecx, COL_TEXT
    call gtext
    ; bottom hint bar h=16
    mov rax, [fb_height]
    sub rax, 16
    mov rsi, rax
    mov rdi, 0
    mov rdx, [fb_width]
    mov rcx, 16
    mov r8d, COL_BAR
    call fill_rect_w
    mov rax, [fb_height]
    sub rax, 12
    mov rsi, rax
    mov rdi, 8
    lea rdx, [str_hints]
    mov ecx, COL_DIM
    call gtext
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- centred window frame: rdi = w, rsi = h, rdx = title ----
; out: r8 = x, r9 = y. Content origin = (x+16, y+48).
win_frame:
    push rax
    push rbx
    push rcx
    push rdx                      ; title
    push r10                      ; w
    push r11                      ; h
    push r12                      ; x
    push r13                      ; y
    mov r10, rdi
    mov r11, rsi
    mov rax, [fb_width]           ; x = (W-w)/2
    sub rax, r10
    shr rax, 1
    mov r12, rax
    mov rax, [fb_height]          ; y = (H-h)/2
    sub rax, r11
    shr rax, 1
    mov r13, rax
    mov rdi, r12                  ; border
    mov rsi, r13
    mov rdx, r10
    mov rcx, r11
    mov r8d, COL_TEXT
    call fill_rect_w
    mov rdi, r12                  ; bg inset 2
    add rdi, 2
    mov rsi, r13
    add rsi, 2
    mov rdx, r10
    sub rdx, 4
    mov rcx, r11
    sub rcx, 4
    mov r8d, COL_WINBG
    call fill_rect_w
    mov rdi, r12                  ; title bar h=24
    add rdi, 2
    mov rsi, r13
    add rsi, 2
    mov rdx, r10
    sub rdx, 4
    mov rcx, 24
    mov r8d, COL_TITLE
    call fill_rect_w
    mov rdi, r12                  ; title text at (x+10, y+9)
    add rdi, 10
    mov rsi, r13
    add rsi, 9
    mov rdx, [rsp + 32]           ; title (stack: r13,r12,r11,r10,rdx,...)
    mov ecx, COL_TEXT
    call gtext
    mov r8, r12                   ; out: x, y
    mov r9, r13
    pop r13
    pop r12
    pop r11
    pop r10
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- redraw everything for current state ----
draw_all:
    push rax
    call draw_desktop
    mov rax, [gui_state]
    cmp rax, 0
    je .menu
    cmp rax, 1
    je .settings
    cmp rax, 2
    je .system
    call draw_about
    jmp .out
.menu:
    call draw_menu
    jmp .out
.settings:
    call draw_settings
    jmp .out
.system:
    call draw_system
.out:
    pop rax
    ret

; ---- main menu window ----
draw_menu:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov rdi, 400
    mov rsi, 280
    lea rdx, [str_menu]
    call win_frame                ; -> r8 = x, r9 = y
    xor ebx, ebx                  ; item 0..2
.item:
    cmp rbx, 3
    jae .done
    mov rax, r9                   ; y = wy + 56 + item*40
    add rax, 56
    mov rcx, rbx
    shl rcx, 5
    add rcx, rbx
    shl rcx, 3                    ; *40
    add rax, rcx
    mov rsi, rax
    mov rax, r8
    add rax, 16
    mov rdi, rax                  ; x = wx+16
    cmp rbx, [gui_sel]            ; highlight?
    jne .nohi
    push rbx
    push rsi
    push rdi
    mov rdx, 368
    mov rcx, 28
    mov r8d, COL_HI
    call fill_rect_w
    pop rdi
    pop rsi
    pop rbx
.nohi:
    add rdi, 12
    add rsi, 8
    cmp rbx, 0
    je .t0
    cmp rbx, 1
    je .t1
    lea rdx, [str_app_about]
    jmp .drawt
.t0:
    lea rdx, [str_app_settings]
    jmp .drawt
.t1:
    lea rdx, [str_app_system]
.drawt:
    mov ecx, COL_TEXT
    call gtext
    inc rbx
    jmp .item
.done:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- settings app (MINIMAL DEBUG: bare window) ----
draw_settings:
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov rdi, 520
    mov rsi, 300
    lea rdx, [str_app_settings]
    call win_frame
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    ret

; ---- system info app (live kernel data) ----
draw_system:
    push rax
    push rbx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov rdi, 560
    mov rsi, 340
    lea rdx, [str_app_system]
    call win_frame
    mov [gui_wx], r8
    mov [gui_wy], r9
    mov rax, [gui_wy]
    add rax, 56
    mov [gui_ly], rax
    lea rdx, [str_sys_fb]
    call sys_line_head
    mov rax, [fb_width]
    call gui_dec                   ; rsi = numstr
    mov rdx, rsi
    mov rdi, [gui_lx]
    mov rsi, [gui_ly]
    mov ecx, COL_TEXT
    call gtext
    jmp .sys_mem
.sys_mem:
    lea rdx, [str_sys_mem]
    call sys_line_head
    mov rax, [mem_total]
    shr rax, 20
    call gui_dec
    mov rdx, rsi
    mov rdi, [gui_lx]
    mov rsi, [gui_ly]
    mov ecx, COL_TEXT
    call gtext
    lea rdx, [str_sys_mib]         ; " MiB" after the number (fixed gap)
    mov ecx, COL_DIM
    mov rdi, [gui_lx]
    add rdi, 96
    mov rsi, [gui_ly]
    call gtext
    jmp .sys_pci
.sys_pci:
    lea rdx, [str_sys_pci]
    call sys_line_head
    mov rax, [pci_count]
    call gui_dec
    mov rdx, rsi
    mov rdi, [gui_lx]
    mov rsi, [gui_ly]
    mov ecx, COL_TEXT
    call gtext
    jmp .sys_rest
.sys_rest:
    lea rdx, [str_sys_kbd]
    call sys_line
    lea rdx, [str_sys_usb]
    call sys_line
    lea rdx, [str_sys_disk]
    call sys_line
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop rax
    ret

; head line: rdx = label. prints at next row, sets gui_lx past label.
sys_line_head:
    push rax
    push rbx
    mov rax, [gui_ly]
    add rax, 24
    mov [gui_ly], rax
    mov rsi, rax
    mov rax, [gui_wx]
    add rax, 16
    mov rdi, rax
    mov ecx, COL_DIM
    call gtext
    mov rax, rdi                  ; lx = x + len*8 (approx via strlen)
    push rsi
    call gui_strlen
    shl rax, 3
    add rax, rdi
    mov [gui_lx], rax
    add rax, 8
    mov [gui_lx2], rax
    pop rsi
    pop rbx
    pop rax
    ret

; full line: rdx = text
sys_line:
    push rax
    push rdi
    push rsi
    mov rax, [gui_ly]
    add rax, 24
    mov [gui_ly], rax
    mov rsi, rax
    mov rax, [gui_wx]
    add rax, 16
    mov rdi, rax
    mov ecx, COL_TEXT
    call gtext
    pop rsi
    pop rdi
    pop rax
    ret

; strlen: rdx = str -> rax = len
gui_strlen:
    push rdx
    xor eax, eax
.len:
    cmp byte [rdx + rax], 0
    je .out
    inc rax
    jmp .len
.out:
    pop rdx
    ret

; ---- about app ----
draw_about:
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov rdi, 480
    mov rsi, 280
    lea rdx, [str_app_about]
    call win_frame
    mov rsi, r9
    add rsi, 56
    mov rdi, r8
    add rdi, 16
    lea rdx, [str_about1]
    mov ecx, COL_TEXT
    call gtext
    add rsi, 24
    lea rdx, [str_about2]
    call gtext
    add rsi, 24
    lea rdx, [str_about3]
    mov ecx, COL_GREEN
    call gtext
    add rsi, 24
    lea rdx, [str_about4]
    mov ecx, COL_DIM
    call gtext
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    ret

; ---- main loop ----
gui_run:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    cmp byte [fb_present], 0
    je .nofb
    lea rsi, [msg_gui_on]
    call serial_print
    mov qword [gui_state], 0
    mov qword [gui_sel], 0
    call draw_all
.loop:
    call kbd_getc                  ; al = key
    cmp al, 0x1B                   ; Esc
    je .esc
    mov rbx, [gui_state]
    cmp rbx, 0
    je .menu_key
    cmp rbx, 1
    je .settings_key
    jmp .loop                      ; system/about: only Esc
.menu_key:
    cmp al, 0x90                   ; Up
    je .menu_up
    cmp al, 0x91                   ; Down
    je .menu_down
    cmp al, 0x0A                   ; Enter
    je .menu_open
    jmp .loop
.menu_up:
    cmp qword [gui_sel], 0
    je .loop
    dec qword [gui_sel]
    call draw_all
    jmp .loop
.menu_down:
    cmp qword [gui_sel], 2
    jae .loop
    inc qword [gui_sel]
    call draw_all
    jmp .loop
.menu_open:
    mov rax, [gui_sel]
    inc rax                        ; state 1..3
    mov [gui_state], rax
    mov qword [gui_sel], 0
    call draw_all                  ; draw FIRST (screen shows progress)
    lea rsi, [msg_gui_app]         ; marker AFTER (proves full path)
    call serial_print
    jmp .loop
.settings_key:
    cmp al, 0x90
    je .set_up
    cmp al, 0x91
    je .set_down
    cmp al, 0x92
    je .set_left
    cmp al, 0x93
    je .set_right
    cmp al, 0x0A
    je .set_toggle
    jmp .loop
.set_up:
    cmp qword [gui_sel], 0
    je .loop
    dec qword [gui_sel]
    call draw_all
    jmp .loop
.set_down:
    cmp qword [gui_sel], 2
    jae .loop
    inc qword [gui_sel]
    call draw_all
    jmp .loop
.set_left:
    jmp .set_toggle
.set_right:
    jmp .set_toggle
.set_toggle:
    mov rax, [gui_sel]
    cmp rax, 0
    je .tog_wall
    cmp rax, 1
    je .tog_scale
    jmp .loop                      ; row 2 = info only
.tog_wall:
    xor byte [wallpaper_mode], 1
    lea rsi, [msg_gui_wall]
    call serial_print
    call draw_all
    jmp .loop
.tog_scale:
    cmp qword [con_scale], 2
    je .scale1
    mov rdi, 2
    jmp .scale_do
.scale1:
    mov rdi, 1
.scale_do:
    call con_set_scale
    lea rsi, [msg_gui_scale]
    call serial_print
    call draw_all
    jmp .loop
.esc:
    cmp qword [gui_state], 0
    je .exit
    mov qword [gui_state], 0       ; back to menu
    mov qword [gui_sel], 0
    call draw_all
    jmp .loop
.exit:
    call con_clear                 ; fresh console screen
    lea rsi, [msg_gui_off]
    call serial_print
    jmp .out
.nofb:
    lea rsi, [msg_gui_nofb]
    call sh_print
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .rodata
str_prism: db "Prism - BitOS Desktop", 0
str_hints: db "Up/Down: move  Enter: open  Esc: back", 0
str_menu:  db "Prism Menu", 0
str_app_settings: db "Settings", 0
str_app_system:   db "System Info", 0
str_app_about:    db "About BitOS", 0
str_set_wall:  db "Wallpaper:", 0
str_v_stock:   db "Stock", 0
str_v_pattern: db "Pattern", 0
str_set_scale: db "UI Scale:", 0
str_v_1x:      db "1x native", 0
str_v_2x:      db "2x large", 0
str_set_disp:  db "Display:", 0
str_set_disp_v: db "1024x768x32 (fixed at boot)", 0
str_sys_fb:    db "Framebuffer: ", 0
str_sys_mem:   db "RAM usable: ", 0
str_sys_mib:   db " MiB", 0
str_sys_pci:   db "PCI devices: ", 0
str_sys_kbd:   db "Keyboard: PS/2 on IRQ1", 0
str_sys_usb:   db "USB: xHCI (run 'usb')", 0
str_sys_disk:  db "Disks: ATA/NVMe (run 'ata'/'nvme')", 0
str_about1:    db "BitOS - minimal x64 OS", 0
str_about2:    db "Window manager: BitWM", 0
str_about3:    db "Desktop: Prism", 0
str_about4:    db "(c) 2026 PureBitOS - DBAD-1.2", 0
msg_gui_on:    db "gui: Prism desktop open.", 0x0A, 0
msg_gui_off:   db "gui: back to shell.", 0x0A, 0
msg_gui_app:   db "gui: app open.", 0x0A, 0
msg_gui_wall:  db "gui: wallpaper toggled.", 0x0A, 0
msg_gui_scale: db "gui: scale applied.", 0x0A, 0
msg_gui_nofb:  db "gui: needs a framebuffer (boot UEFI/VBE).", 0x0A, 0

section .bss
wallpaper_mode: resb 1             ; 0 = stock, 1 = pattern
gui_state:  resq 1                ; 0 menu, 1 settings, 2 system, 3 about
gui_sel:    resq 1                ; menu/app selection
gui_numbuf: resb 24
gui_wx:     resq 1                ; current window content origin
gui_wy:     resq 1
gui_lx:     resq 1                ; current text line x
gui_ly:     resq 1                ; current text line y
gui_lx2:    resq 1
