; BitOS — linear framebuffer console (GOP on UEFI incl. HDMI mirror,
; VBE on BIOS) with built-in 8x8 font. If the firmware provides no
; framebuffer, everything falls back to VGA text transparently.
; Shell + banner talk to con_* (routed here); `gfx` draws a test pattern.
;
; fb_setup: rdi = multiboot2 info ptr. Parses tag 8, maps the framebuffer
;   via mmio_map, clears the screen, selects the console.
; con_putc (al), con_backspace, con_clear, con_print_c (rsi, ah),
; con_setpos (rdi = row, rsi = col), gfx_demo.

global fb_setup, con_putc, con_backspace, con_clear, con_print_c
global con_setpos, gfx_demo
global con_set_scale, wallpaper_blit
global fill_rect_w, fb_text_at    ; used by Prism WM
global fb_present, fb_width, fb_height
global fb_virt                     ; read by Prism desktop (pattern fill)
global con_scale                   ; read by Prism Settings
global fb_pitch                  ; DEBUG visibility for nvme bring-up
extern vga_clear, vga_putc, vga_backspace, vga_setpos, vga_print_c
extern serial_print, serial_putc
extern pci_hex, mmio_map
extern kbd_getc
extern wallpaper_data

section .text
bits 64

FB_BG equ 0x101020               ; console background (near-black blue)
FB_FG equ 0xAAAAAA               ; default foreground (gray)

; ---- fb_setup: rdi = mb info ----
; Multiboot2 tag 8 layout: u32 type, u32 size, u64 addr, u32 pitch,
; u32 width, u32 height, u8 bpp, u8 type, u16 reserved.
fb_setup:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, rdi
    mov eax, [rsi]
    cmp eax, 8
    jb .nofb
    add rsi, 8
.tag:
    mov eax, [rsi]
    cmp eax, 0
    je .nofb
    cmp eax, 8
    je .fbtag
    mov eax, [rsi + 4]
    add eax, 7
    and eax, ~7
    add rsi, rax
    jmp .tag
.fbtag:
    movzx eax, byte [rsi + 28]   ; bpp
    cmp eax, 32
    jne .nofb
    movzx eax, byte [rsi + 29]   ; type 1 = packed RGB
    cmp eax, 1
    jne .nofb
    mov rax, [rsi + 8]           ; addr
    test rax, rax
    jz .nofb
    mov [fb_addr], rax
    mov eax, [rsi + 16]          ; pitch
    mov [fb_pitch], rax
    mov eax, [rsi + 20]          ; width
    cmp eax, 640
    jb .nofb
    cmp eax, 4096
    ja .nofb
    mov [fb_width], rax
    mov eax, [rsi + 24]          ; height
    cmp eax, 400
    jb .nofb
    cmp eax, 4096
    ja .nofb
    mov [fb_height], rax
    ; cols/rows of 8x8 cells
    mov rax, [fb_width]
    shr rax, 3
    mov [fb_cols], rax
    mov rax, [fb_height]
    shr rax, 3
    mov [fb_rows], rax
    ; map it: size = pitch * height
    mov rax, [fb_pitch]
    mul qword [fb_height]        ; rdx:rax = bytes (fits 64)
    mov [fb_size], rax
    mov rdi, [fb_addr]
    mov rsi, rax
    call mmio_map                ; -> rax = virt
    mov [fb_virt], rax
    mov byte [fb_present], 1
    mov dword [fb_fg], FB_FG
    mov qword [con_scale], 1
    mov qword [fb_cellpx], 8
    mov qword [fb_row], 0
    mov qword [fb_col], 0
    call fb_clear_raw
    lea rsi, [msg_fb]
    call serial_print
    mov rax, [fb_width]
    mov ecx, 4
    call pci_hex
    mov al, 'x'
    call serial_putc
    mov rax, [fb_height]
    mov ecx, 4
    call pci_hex
    lea rsi, [msg_fb2]
    call serial_print
    jmp .out
.nofb:
    lea rsi, [msg_nofb]
    call serial_print
    call vga_clear
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ---- routed console ----
con_putc:                        ; al = char
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    cmp byte [fb_present], 0
    je .vga
    call fb_putc_raw
    jmp .out
.vga:
    call vga_putc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

con_backspace:
    push rax
    push rdx
    cmp byte [fb_present], 0
    je .vga
    mov rax, [fb_col]
    test rax, rax
    jz .out
    dec rax
    mov [fb_col], rax
    call fb_erase_cell
    call fb_cursor_draw
    jmp .out
.vga:
    call vga_backspace
.out:
    pop rdx
    pop rax
    ret

con_clear:
    cmp byte [fb_present], 0
    je vga_clear                  ; tail call (vga_clear preserves)
    push rax
    call fb_clear_raw
    mov qword [fb_row], 0
    mov qword [fb_col], 0
    call fb_cursor_draw
    pop rax
    ret

; rsi = string, ah = vga colour
con_print_c:
    push rax
    call attr_to_fg               ; ah -> [fb_fg]
    pop rax
    push rax
    push rsi
.next:
    lodsb
    test al, al
    jz .done
    push rax
    push rsi
    call con_putc
    pop rsi
    pop rax
    jmp .next
.done:
    pop rsi
    pop rax
    ret

; rdi = row, rsi = col
con_setpos:
    cmp byte [fb_present], 0
    je vga_setpos                 ; tail call
    push rax
    call fb_cursor_erase
    mov [fb_row], rdi
    mov [fb_col], rsi
    call fb_cursor_draw
    pop rax
    ret

; ---- UI scale (resolution changer): 1 = native cells, 2 = doubled ----
; con_set_scale: rdi = 1 or 2 (clamped). Recomputes grid, clears screen.
con_set_scale:
    push rax
    cmp rdi, 1
    jb .clamp1
    cmp rdi, 2
    jbe .ok
    mov rdi, 2
    jmp .ok
.clamp1:
    mov rdi, 1
.ok:
    mov [con_scale], rdi
    mov rax, 8
    mul rdi                        ; rax = cell px (8/16)
    mov [fb_cellpx], rax
    mov rax, [fb_width]
    xor edx, edx
    div qword [fb_cellpx]
    mov [fb_cols], rax
    mov rax, [fb_height]
    xor edx, edx
    div qword [fb_cellpx]
    mov [fb_rows], rax
    cmp byte [fb_present], 0
    je .out
    call fb_clear_raw
    mov qword [fb_row], 0
    mov qword [fb_col], 0
.out:
    pop rax
    ret

; rdi = cells -> rdi = pixels (cell = 8*scale)
cell_to_px:
    shl rdi, 3
    cmp byte [con_scale], 2
    jne .out
    shl rdi, 1
.out:
    ret

; draw pixel(s): rdi = addr, eax = colour (1px, or 2x2 at scale 2).
; Clips to the mapped framebuffer (robust against caller bugs).
draw_px:
    push rax
    push rcx
    push rdx
    push rdi
    mov rcx, rdi
    sub rcx, [fb_virt]
    cmp rcx, [fb_size]
    jae .clip
    cmp byte [con_scale], 2
    je .double
    mov [rdi], eax
    jmp .out
.double:
    mov [rdi], eax
    mov [rdi + 4], eax
    mov rdx, [fb_pitch]
    add rdi, rdx
    mov [rdi], eax
    mov [rdi + 4], eax
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret
.clip:
    inc qword [fb_clipped]
    jmp .out

; wallpaper_blit: stock wallpaper (1024x768 XRGB32) -> screen, clipped.
wallpaper_blit:
    push rax
    push rcx
    push rsi
    push rdi
    cmp byte [fb_present], 0
    je .out
    cld
    mov rax, [fb_height]
    cmp rax, 768
    jbe .rows_ok
    mov rax, 768
.rows_ok:
    mov rcx, rax                   ; rows to copy
    mov rsi, wallpaper_data
    mov rdi, [fb_virt]
.row:
    test rcx, rcx
    jz .out2
    push rcx
    push rsi
    push rdi
    mov rax, [fb_pitch]
    shr rax, 2                     ; pitch dwords
    cmp rax, 1024
    jbe .w_ok
    mov rax, 1024
.w_ok:
    mov rcx, rax
    rep movsd
    pop rdi
    pop rsi
    pop rcx
    add rsi, 4096                  ; next wallpaper row (1024*4)
    add rdi, [fb_pitch]            ; next screen row
    dec rcx
    jmp .row
.out2:
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret
attr_to_fg:
    push rax
    cmp ah, 0x0A
    je .green
    cmp ah, 0x08
    je .dark
    mov dword [fb_fg], 0xAAAAAA
    jmp .out
.green:
    mov dword [fb_fg], 0x00AA00
    jmp .out
.dark:
    mov dword [fb_fg], 0x555555
.out:
    pop rax
    ret

; ---- raw framebuffer text ----
; al = char (handles 0x0A)
fb_putc_raw:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    cmp al, 0x0A
    je .nl
    mov rcx, [fb_col]
    cmp rcx, [fb_cols]
    jb .nowrap
    xor ecx, ecx
    mov [fb_col], rcx
    inc qword [fb_row]
.nowrap:
    mov rdx, [fb_row]
    cmp rdx, [fb_rows]
    jb .noscroll
    call fb_scroll
    mov rdx, [fb_rows]
    dec rdx
    mov [fb_row], rdx
.noscroll:
    call fb_cursor_erase
    mov edi, [fb_col]
    call cell_to_px                ; x = col * cellpx
    push rdi
    mov edi, [fb_row]
    call cell_to_px                ; y = row * cellpx
    mov esi, edi
    pop rdi
    mov r8d, [fb_fg]
    call draw_glyph              ; al = char
    inc qword [fb_col]
    call fb_cursor_draw
    jmp .out
.nl:
    mov qword [fb_col], 0
    inc qword [fb_row]
    mov rdx, [fb_row]
    cmp rdx, [fb_rows]
    jb .nl_ok
    call fb_scroll
    mov rax, [fb_rows]
    dec rax
    mov [fb_row], rax
.nl_ok:
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.nl_done equ 0

; erase cell at cursor (bg rect, scaled)
fb_erase_cell:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    mov edi, [fb_col]
    call cell_to_px
    push rdi
    mov edi, [fb_row]
    call cell_to_px
    mov esi, edi
    pop rdi
    mov rdx, [fb_cellpx]
    mov rcx, [fb_cellpx]
    mov r8d, FB_BG
    call fill_rect_w
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

fb_cursor_draw:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    mov edi, [fb_col]
    call cell_to_px                ; x
    push rdi
    mov edi, [fb_row]
    call cell_to_px                ; y base
    mov rcx, [fb_cellpx]
    shr rcx, 2                     ; underline h = cell/4
    cmp rcx, 2
    jae .ch_ok
    mov rcx, 2
.ch_ok:
    add rdi, [fb_cellpx]
    sub rdi, rcx                   ; y = base + cell - h
    mov rsi, rdi                   ; rsi = y
    pop rdi                        ; rdi = x
    mov rdx, [fb_cellpx]           ; w = cell
    mov r8d, [fb_fg]
    call fill_rect_w
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

fb_cursor_erase:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    mov edi, [fb_col]
    call cell_to_px
    push rdi
    mov edi, [fb_row]
    call cell_to_px
    mov rcx, [fb_cellpx]
    shr rcx, 2
    cmp rcx, 2
    jae .ch_ok
    mov rcx, 2
.ch_ok:
    add rdi, [fb_cellpx]
    sub rdi, rcx
    mov rsi, rdi
    pop rdi
    mov rdx, [fb_cellpx]
    mov r8d, FB_BG
    call fill_rect_w
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

; scroll up one text row (cellpx px)
fb_scroll:
    push rax
    push rcx
    push rsi
    push rdi
    cld
    mov rax, [fb_cellpx]
    mul qword [fb_pitch]          ; rax = one text row in bytes
    push rax
    mov rax, [fb_height]
    sub rax, [fb_cellpx]
    mul qword [fb_pitch]          ; rdx:rax = bytes to move
    mov rcx, rax
    pop rax                       ; rax = row bytes
    mov rsi, [fb_virt]
    add rsi, rax                  ; src = top + one text row
    mov rdi, [fb_virt]            ; dst = top
    rep movsb
    ; clear last text row
    mov rax, [fb_height]
    sub rax, [fb_cellpx]
    mul qword [fb_pitch]          ; dest offset
    mov rdi, [fb_virt]
    add rdi, rax
    push rdi
    mov rax, [fb_pitch]
    mul qword [fb_cellpx]         ; row bytes
    shr rax, 2                    ; dwords
    mov rcx, rax
    mov eax, FB_BG
    pop rdi
    rep stosd
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; clear whole screen to bg
fb_clear_raw:
    push rax
    push rcx
    push rdi
    mov rax, [fb_pitch]
    mul qword [fb_height]         ; rdx:rax = bytes
    shr rax, 2                    ; dwords
    mov rcx, rax
    mov rdi, [fb_virt]
    mov eax, FB_BG
    rep stosd
    pop rdi
    pop rcx
    pop rax
    ret

; fill rect: rdi = x px, rsi = y px, w = 8 fixed, ecx = h px, edx = colour
fill_rect:
    push rax
    push rbx
    push rcx
    push rsi
    mov eax, edx                  ; colour first (mul clobbers rdx)
    push rax
    mov rax, rsi                  ; row address = virt + y*pitch + x*4
    mul qword [fb_pitch]
    mov rbx, [fb_virt]
    add rbx, rax
    mov rax, rdi
    shl rax, 2
    add rbx, rax
    pop rax                       ; colour back
.row:
    test ecx, ecx
    jz .out
    mov [rbx], eax
    mov [rbx + 4], eax            ; 8 px = 2 dwords
    add rbx, [fb_pitch]
    dec ecx
    jmp .row
.out:
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; draw glyph: al = char, edi = x px, esi = y px, r8d = fg colour
draw_glyph:
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
    cmp al, 0x20
    jb .as_q
    cmp al, 0x7E
    jbe .ok
.as_q:
    mov al, '?'
.ok:
    movzx eax, al
    sub eax, 0x20
    shl eax, 3
    lea rbx, [font8x8]
    add rbx, rax                  ; rbx = glyph rows
    mov r9d, edi                  ; x base
    xor ecx, ecx                  ; row 0..7
.grow:
    mov dl, [rbx + rcx]           ; glyph byte -> r10b (mul below kills rdx!)
    mov r10b, dl
    ; row base = fb_virt + (y + row) * pitch (once per row: mul safe here)
    mov eax, esi                  ; y base
    add eax, ecx                  ; + row
    mul qword [fb_pitch]
    mov rdi, [fb_virt]
    add rdi, rax
    mov eax, r9d
    shl eax, 2                    ; + x*4
    add rdi, rax
    push rcx
    mov ecx, 8                    ; 8 pixels
    xor r11d, r11d                ; bit index 0..7 (left to right)
.gbit:
    test r10b, 0x80               ; MSB first
    jz .bgpx
    mov eax, r8d
    jmp .draw
.bgpx:
    mov eax, FB_BG
.draw:
    push rdi
    lea rdi, [rdi + r11 * 4]
    call draw_px                  ; scale-aware pixel(s)
    pop rdi
.nextbit:
    shl r10b, 1
    inc r11d
    dec ecx
    jnz .gbit
    pop rcx
    inc ecx
    cmp ecx, 8
    jb .grow
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

; ---- gfx_demo: info + test pattern, wait key, restore console ----
gfx_demo:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    cmp byte [fb_present], 0
    je .nofb
    lea rsi, [msg_gfx]
    call serial_print
    mov rax, [fb_width]
    mov ecx, 4
    call pci_hex
    mov al, 'x'
    call serial_putc
    mov rax, [fb_height]
    mov ecx, 4
    call pci_hex
    mov al, '@'
    call serial_putc
    mov rax, [fb_addr]
    mov ecx, 16
    call pci_hex
    mov al, 0x0A
    call serial_putc
    ; pattern: dark bg, 8 colour bars (bottom half), white border,
    ; centred green box with "BitOS" text
    mov rax, [fb_pitch]
    mul qword [fb_height]         ; rdx:rax = bytes (rax was pitch, NOT colour)
    shr rax, 2                    ; dwords
    mov rcx, rax
    mov rdi, [fb_virt]
    mov eax, 0x101020
    rep stosd
    ; border (white)
    mov r8d, 0xFFFFFF
    mov rdi, 0
    mov esi, 0
    mov rdx, [fb_width]
    mov rcx, 2
    call fill_rect_w              ; top (w=width)
    mov rsi, [fb_height]
    sub rsi, 2
    mov rdi, 0
    mov rdx, [fb_width]
    mov rcx, 2
    call fill_rect_w              ; bottom
    mov rdi, 0
    mov esi, 0
    mov rdx, 2
    mov rcx, [fb_height]
    call fill_rect_w              ; left
    mov rax, [fb_width]
    sub rax, 2
    mov rdi, rax
    mov esi, 0
    mov rdx, 2
    mov rcx, [fb_height]
    call fill_rect_w              ; right (white)
    ; 8 bars across bottom half
    mov rax, [fb_width]
    shr rax, 3                    ; bar width
    mov [gfx_barw], rax
    mov rax, [fb_height]
    shr rax, 1                    ; y start = h/2
    mov [gfx_bary], rax
    mov rax, [fb_height]
    sub rax, [gfx_bary]
    mov [gfx_barh], rax
    xor ebx, ebx                  ; bar index
.bar:
    cmp rbx, 8
    jae .bars_done
    mov rax, [gfx_barw]
    mul rbx                       ; x = barw * i
    mov rdi, rax
    mov rsi, [gfx_bary]
    mov rdx, [gfx_barw]
    mov rcx, [gfx_barh]
    lea rax, [bar_colors]
    mov r8d, [rax + rbx * 4]      ; colour (rdx stays = width)
    call fill_rect_w
    inc rbx
    jmp .bar
.bars_done:
    ; green box + text
    mov rax, [fb_width]
    sub rax, 400
    shr rax, 1
    mov rdi, rax                  ; centred x
    mov rax, [fb_height]
    shr rax, 2                    ; y = h/4
    mov rsi, rax
    mov rdx, 400
    mov rcx, 120
    mov r8d, 0x007700
    call fill_rect_w
    ; "BitOS" centred in box (5 chars * 8px = 40px)
    mov rax, [fb_width]
    sub rax, 40
    shr rax, 1
    mov rdi, rax
    mov rax, [fb_height]
    shr rax, 2
    add rax, 52                   ; vertical centre of box
    mov rsi, rax
    lea rax, [gfx_text]
    mov r8d, 0xFFFFFF
    call fb_text_at
    lea rsi, [msg_gfx_key]
    call serial_print
    call kbd_getc                 ; wait any key (PS/2; al discarded)
    ; restore console screen
    call fb_clear_raw
    mov qword [fb_row], 0
    mov qword [fb_col], 0
    lea rsi, [msg_gfx_back]
    call serial_print
    jmp .out
.nofb:
    push rax
    push rsi
    lea rsi, [msg_gfx_none]
.nofb_loop:
    lodsb
    test al, al
    jz .nofb_done
    push rax
    push rsi
    call vga_putc
    call serial_putc
    pop rsi
    pop rax
    jmp .nofb_loop
.nofb_done:
    pop rsi
    pop rax
    jmp .out
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; fill rect (general): rdi = x px, rsi = y px, rdx = w px, rcx = h px,
; r8d = colour. Base computed from fb_virt (never raw coords as address).
fill_rect_w:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10, rdx                  ; width aside (mul below kills rdx too)
    mov eax, r8d                  ; colour -> stack (mul clobbers rax/rdx)
    push rax
    mov rax, rsi                  ; row base = virt + y*pitch + x*4
    mul qword [fb_pitch]
    mov r9, [fb_virt]
    add r9, rax
    mov rax, rdi
    shl rax, 2
    add r9, rax
    pop rax                       ; colour back in eax
.row:
    test ecx, ecx
    jz .out
    mov rdi, r9
    mov rbx, r10                  ; w remaining (rdx died in mul)
    test rbx, rbx
    jz .nextrow
.px:
    mov [rdi], eax
    add rdi, 4
    dec rbx
    jnz .px
.nextrow:
    add r9, [fb_pitch]            ; next scanline
    dec ecx
    jmp .row
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; text at pixels: rdi = x, rsi = y, rax = string ptr, r8d = colour
fb_text_at:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rax
.next:
    mov al, [rbx]
    test al, al
    jz .out
    push rbx
    call draw_glyph               ; (edi=x, esi=y, al, r8d)
    pop rbx
    add rdi, 8
    inc rbx
    jmp .next
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .rodata
msg_nofb:     db "fb: no 32-bit framebuffer, VGA text console.", 0x0A, 0
msg_fb:       db "fb: linear framebuffer ", 0
msg_fb2:      db "x32 ready (console on pixels).", 0x0A, 0
msg_gfx:      db "gfx: framebuffer mode ", 0
msg_gfx_key:  db "gfx: pattern drawn - press any key (PS/2) to return.", 0x0A, 0
msg_gfx_back: db "gfx: back to console.", 0x0A, 0
msg_gfx_none: db "gfx: no framebuffer here (VGA text mode).", 0x0A, 0
gfx_text:     db "BitOS", 0
bar_colors:
    dd 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00
    dd 0xFF00FF, 0x00FFFF, 0xFFFFFF, 0x808080

section .bss
fb_present: resb 1
fb_addr:    resq 1
fb_pitch:   resq 1
fb_width:   resq 1
fb_height:  resq 1
fb_virt:    resq 1
fb_size:    resq 1                ; framebuffer bytes (clip bound)
fb_clipped: resq 1                ; clipped-pixel counter (debug)
fb_cols:    resq 1
fb_rows:    resq 1
fb_row:     resq 1
fb_col:     resq 1
fb_fg:      resd 1
con_scale:  resq 1                ; 1 = native cells, 2 = doubled (resolution)
fb_cellpx:  resq 1                ; cell size in px (8/16)
dbg_pxc:    resq 1                ; draw_px debug counter
gfx_barw:   resq 1
gfx_bary:   resq 1
gfx_barh:   resq 1

; ---- 8x8 font, ASCII 0x20-0x7E (MSB = left pixel) ----
section .rodata
font8x8:
    ; 0x20-0x2F
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 ; space
    db 0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00 ; !
    db 0x66,0x66,0x24,0x00,0x00,0x00,0x00,0x00 ; "
    db 0x6C,0x6C,0xFE,0x6C,0xFE,0x6C,0x6C,0x00 ; #
    db 0x18,0x3E,0x60,0x3C,0x06,0x7C,0x18,0x00 ; $
    db 0x00,0x63,0x13,0x08,0x14,0x33,0x63,0x00 ; %
    db 0x38,0x44,0x28,0x10,0x28,0x44,0x3A,0x00 ; &
    db 0x18,0x18,0x08,0x00,0x00,0x00,0x00,0x00 ; '
    db 0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00 ; (
    db 0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00 ; )
    db 0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00 ; *
    db 0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00 ; +
    db 0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x08 ; ,
    db 0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00 ; -
    db 0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00 ; .
    db 0x02,0x06,0x0C,0x18,0x30,0x60,0x40,0x00 ; /
    ; 0x30-0x3F
    db 0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00 ; 0
    db 0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00 ; 1
    db 0x3C,0x66,0x06,0x0C,0x18,0x30,0x7E,0x00 ; 2
    db 0x7E,0x0C,0x18,0x0C,0x06,0x66,0x3C,0x00 ; 3
    db 0x0C,0x1C,0x3C,0x6C,0x7E,0x0C,0x0C,0x00 ; 4
    db 0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00 ; 5
    db 0x1C,0x30,0x60,0x7C,0x66,0x66,0x3C,0x00 ; 6
    db 0x7E,0x06,0x0C,0x18,0x30,0x30,0x30,0x00 ; 7
    db 0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00 ; 8
    db 0x3C,0x66,0x66,0x3E,0x06,0x0C,0x38,0x00 ; 9
    db 0x00,0x18,0x18,0x00,0x18,0x18,0x00,0x00 ; :
    db 0x00,0x18,0x18,0x00,0x18,0x18,0x08,0x00 ; ;
    db 0x0C,0x18,0x30,0x60,0x30,0x18,0x0C,0x00 ; <
    db 0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00 ; =
    db 0x30,0x18,0x0C,0x06,0x0C,0x18,0x30,0x00 ; >
    db 0x3C,0x66,0x06,0x0C,0x18,0x00,0x18,0x00 ; ?
    ; 0x40-0x4F
    db 0x3C,0x66,0x6E,0x6E,0x60,0x62,0x3C,0x00 ; @
    db 0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00 ; A
    db 0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C,0x00 ; B
    db 0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00 ; C
    db 0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0x00 ; D
    db 0x7E,0x60,0x60,0x7C,0x60,0x60,0x7E,0x00 ; E
    db 0x7E,0x60,0x60,0x7C,0x60,0x60,0x60,0x00 ; F
    db 0x3C,0x66,0x60,0x6E,0x66,0x66,0x3E,0x00 ; G
    db 0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00 ; H
    db 0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00 ; I
    db 0x1E,0x0C,0x0C,0x0C,0x0C,0x6C,0x38,0x00 ; J
    db 0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0x00 ; K
    db 0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00 ; L
    db 0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x00 ; M
    db 0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x00 ; N
    db 0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00 ; O
    db 0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0x00 ; P
    ; 0x50-0x5F
    db 0x3C,0x66,0x66,0x66,0x6A,0x6C,0x36,0x00 ; Q
    db 0x7C,0x66,0x66,0x7C,0x6C,0x66,0x66,0x00 ; R
    db 0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0x00 ; S
    db 0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00 ; T
    db 0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00 ; U
    db 0xC3,0xC3,0xC3,0xC3,0xC3,0x66,0x3C,0x00 ; V
    db 0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00 ; W
    db 0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00 ; X
    db 0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x00 ; Y
    db 0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00 ; Z
    db 0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00 ; [
    db 0x40,0x60,0x30,0x18,0x0C,0x06,0x02,0x00 ; backslash
    db 0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00 ; ]
    db 0x18,0x3C,0x66,0x00,0x00,0x00,0x00,0x00 ; ^
    db 0x00,0x00,0x00,0x00,0x00,0x00,0xFF,0x00 ; _
    db 0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00 ; `
    ; 0x60-0x6F
    db 0x00,0x00,0x3C,0x06,0x3E,0x66,0x3E,0x00 ; a
    db 0x60,0x60,0x7C,0x66,0x66,0x66,0x7C,0x00 ; b
    db 0x00,0x00,0x3C,0x60,0x60,0x60,0x3C,0x00 ; c
    db 0x06,0x06,0x3E,0x66,0x66,0x66,0x3E,0x00 ; d
    db 0x00,0x00,0x3C,0x66,0x7E,0x60,0x3C,0x00 ; e
    db 0x0E,0x18,0x18,0x7E,0x18,0x18,0x18,0x00 ; f
    db 0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x3C ; g
    db 0x60,0x60,0x7C,0x66,0x66,0x66,0x66,0x00 ; h
    db 0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00 ; i
    db 0x0C,0x00,0x1C,0x0C,0x0C,0x0C,0x6C,0x38 ; j
    db 0x60,0x60,0x66,0x6C,0x78,0x6C,0x66,0x00 ; k
    db 0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00 ; l
    db 0x00,0x00,0x66,0x7F,0x7F,0x6B,0x63,0x00 ; m
    db 0x00,0x00,0x7C,0x66,0x66,0x66,0x66,0x00 ; n
    db 0x00,0x00,0x3C,0x66,0x66,0x66,0x3C,0x00 ; o
    db 0x00,0x00,0x7C,0x66,0x66,0x7C,0x60,0x60 ; p
    ; 0x70-0x7E
    db 0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x06 ; q
    db 0x00,0x00,0x6C,0x76,0x60,0x60,0x60,0x00 ; r
    db 0x00,0x00,0x3E,0x60,0x3C,0x06,0x7C,0x00 ; s
    db 0x18,0x18,0x7E,0x18,0x18,0x18,0x0E,0x00 ; t
    db 0x00,0x00,0x66,0x66,0x66,0x66,0x3E,0x00 ; u
    db 0x00,0x00,0x66,0x66,0x66,0x3C,0x18,0x00 ; v
    db 0x00,0x00,0x63,0x6B,0x7F,0x7F,0x36,0x00 ; w
    db 0x00,0x00,0x66,0x3C,0x18,0x3C,0x66,0x00 ; x
    db 0x00,0x00,0x66,0x66,0x66,0x3E,0x0C,0x78 ; y
    db 0x00,0x00,0x7E,0x0C,0x18,0x30,0x7E,0x00 ; z
    db 0x0E,0x18,0x18,0x70,0x18,0x18,0x0E,0x00 ; {
    db 0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x00 ; |
    db 0x70,0x18,0x18,0x0E,0x18,0x18,0x70,0x00 ; }
    db 0x00,0x00,0x00,0x3B,0x6E,0x00,0x00,0x00 ; ~
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 ; (0x7F unused)
