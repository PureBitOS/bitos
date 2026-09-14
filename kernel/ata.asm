; BitOS — ATA (PATA/IDE) driver: detect, IDENTIFY, LBA28 PIO read/write.
; Scans primary/secondary x master/slave. (`ata` shell command lists
; disks; the installer + Disks app consume ata_* directly.)
; ATAPI (optical) is detected and reported, not driven.

global ata_scan, ata_read_lba, ata_write_lba
global ata_present, ata_atapi, ata_sectors, ata_model
extern sh_print, sh_putc, pci_hex, print_dec64

section .text
bits 64

; ports for channel in rdi (0 = primary 1F0/3F6, 1 = secondary 170/376)
; out: dx = base, cx = alt
chan_ports:
    mov dx, 0x1F0
    mov cx, 0x3F6
    test rdi, rdi
    jz .out
    mov dx, 0x170
    mov cx, 0x376
.out:
    ret

; 400ns delay: 4 reads of alt status. dx = alt port (preserved).
ata_delay:
    push rax
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    pop rax
    ret

; select drive: rdi = channel, rsi = drive (0 master, 1 slave)
ata_select:
    push rax
    push rcx
    push rdx
    call chan_ports                 ; dx = base, cx = alt
    add dx, 6
    mov al, 0xA0
    test rsi, rsi
    jz .master
    mov al, 0xB0
.master:
    out dx, al
    mov dx, cx                      ; dx = alt (no stack tricks!)
    call ata_delay
    pop rdx
    pop rcx
    pop rax
    ret

; poll BSY clear + ERR/DF check. dx = base. rax = 0 ok / 1 fail.
ata_poll:
    push rcx
    push rdx
    mov ecx, 200000
.loop:
    push dx
    add dx, 7
    in al, dx                       ; status
    pop dx
    test al, 0x80                   ; BSY?
    jz .ready
    dec ecx
    jnz .loop
    mov eax, 1
    jmp .out
.ready:
    test al, 0x21                   ; ERR or DF?
    jnz .err
    xor eax, eax
    jmp .out
.err:
    mov eax, 1
.out:
    pop rdx
    pop rcx
    ret

; wait DRQ set (BSY clear first). dx = base. rax = 0 ok / 1 fail.
ata_wait_drq:
    push rcx
    push rdx
    mov ecx, 200000
.loop:
    push dx
    add dx, 7
    in al, dx
    pop dx
    test al, 0x80
    jnz .next
    test al, 0x08                   ; DRQ?
    jnz .ok
    test al, 0x01                   ; ERR?
    jnz .fail
.next:
    dec ecx
    jnz .loop
.fail:
    mov eax, 1
    jmp .out
.ok:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret

; detect: rdi = channel, rsi = drive -> rax: 0 none, 1 ATA, 2 ATAPI
ata_detect:
    push rbx
    push rcx
    push rdx
    call ata_select
    call chan_ports                 ; dx = base
    push dx
    add dx, 7
    in al, dx                       ; status
    pop dx
    cmp al, 0xFF
    je .none
    test al, al
    jz .none
    push dx
    add dx, 7
    mov al, 0xEC                    ; IDENTIFY
    out dx, al
    pop dx
    call ata_poll
    test rax, rax
    jnz .none
    push dx
    add dx, 4
    in al, dx                       ; LBAmid
    mov bl, al
    inc dx
    in al, dx                       ; LBAhi
    pop dx
    test bl, bl
    jnz .maybe_atapi
    test al, al
    jnz .maybe_atapi
    push rcx                        ; ATA: drain the 256 IDENTIFY words
    push rdi                        ; (else DRQ stays set, next cmd fails)
    cld
    lea rdi, [ata_buf]
    mov ecx, 256
    rep insw                        ; dx = base+0 ✓
    pop rdi
    pop rcx
    mov eax, 1                      ; ATA
    jmp .out
.maybe_atapi:
    cmp bl, 0x14
    jne .none
    cmp al, 0xEB
    jne .none
    mov eax, 2                      ; ATAPI
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; identify device idx (0..3) into table. rax = idx. out rax = 0 ok / 1 fail.
ata_identify:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, rax                    ; slot
    mov rax, rbx
    shr rax, 1
    mov rdi, rax                    ; channel = idx/2
    mov rsi, rbx
    and rsi, 1                      ; drive = idx%2
    call ata_select
    mov rax, rbx
    shr rax, 1
    mov rdi, rax
    call chan_ports                 ; dx = base
    push dx
    add dx, 7
    mov al, 0xEC                    ; IDENTIFY
    out dx, al
    pop dx
    call ata_poll
    test rax, rax
    jnz .fail
    cld
    lea rdi, [ata_buf]
    mov ecx, 256
    rep insw                        ; dx = base+0 (data port) ✓
    ; model: words 27..46 -> 40 chars swapped + NUL
    lea rdi, [ata_model]
    mov rax, rbx
    shl rax, 5                      ; slot*32... model stride is 41!
    jmp .model_fix
.model_fix:
    mov rax, rbx
    mov rcx, 41
    mul rcx                           ; rax = slot*41
    lea rdi, [ata_model]
    add rdi, rax
    lea rsi, [ata_buf + 27 * 2]
    mov ecx, 20
.strloop:
    lodsw
    xchg al, ah
    stosw
    dec ecx
    jnz .strloop
    mov byte [rdi], 0
    ; sectors: LBA48? words 100..103 : words 60..61
    mov ax, [ata_buf + 83 * 2]
    test ax, 0x400
    jz .lba28
    mov rax, [ata_buf + 100 * 2]
    jmp .storesec
.lba28:
    mov eax, [ata_buf + 60 * 2]
.storesec:
    mov [ata_sectors + rbx * 8], rax
    mov byte [ata_present + rbx], 1
    xor eax, eax
    jmp .out
.fail:
    mov byte [ata_present + rbx], 0
    push rax
    push rcx
    push rdx
    mov rax, rbx
    shr rax, 1
    mov rdi, rax
    call chan_ports
    add dx, 7
    in al, dx                       ; failing status for diagnosis
    mov cl, al
    pop rdx
    push rdx
    mov al, cl
    mov ecx, 2
    call pci_hex
    mov al, 0x0A
    call sh_putc
    pop rdx
    pop rcx
    pop rax
    mov eax, 1
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sector I/O: rdi = idx, rsi = LBA28, rdx = count, rcx = buffer.
; rax = 0 ok / 1 fail. count 1..256 (256 = full byte rollover).
ata_read_lba:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov r12, rcx                  ; dest ptr
    mov r13d, edx                 ; sectors left
    mov r14, rsi                  ; LBA (preserved: callees save rsi)
    mov rbx, rdi                  ; idx
    mov rax, rbx
    shr rax, 1
    mov rdi, rax                  ; channel
    mov rax, rbx
    and rax, 1
    mov rsi, rax                  ; drive
    call ata_select
    mov rax, rbx
    shr rax, 1
    mov rdi, rax
    call chan_ports               ; dx = base
    push dx                       ; save base
    add dx, 2
    mov al, r13b                  ; sector count
    out dx, al
    pop dx
    push dx
    add dx, 3
    mov rax, r14
    out dx, al                    ; LBA lo
    pop dx
    push dx
    add dx, 4
    mov rax, r14
    shr rax, 8
    out dx, al                    ; LBA mid
    pop dx
    push dx
    add dx, 5
    mov rax, r14
    shr rax, 16
    out dx, al                    ; LBA hi
    pop dx
    push dx
    add dx, 6
    mov rax, r14
    shr rax, 24
    and al, 0x0F
    mov rcx, rbx
    and rcx, 1
    shl cl, 4
    or al, cl
    or al, 0xE0                   ; drive/head
    out dx, al
    pop dx
    push dx
    add dx, 7
    mov al, 0x20                  ; READ SECTORS
    out dx, al
    pop dx
.sector:
    test r13d, r13d
    jz .ok
    call ata_wait_drq
    test rax, rax
    jnz .fail
    mov rax, rbx
    shr rax, 1
    mov rdi, rax
    call chan_ports               ; dx = base (data port)
    cld
    mov rdi, r12
    mov ecx, 256
    rep insw
    add r12, 512
    dec r13d
    jmp .sector
.ok:
    xor eax, eax
    jmp .out
.fail:
    mov eax, 1
.out:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; same contract, buffer -> disk. command 0x30 WRITE SECTORS.
ata_write_lba:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov r12, rcx                  ; src ptr
    mov r13d, edx                 ; sectors left
    mov r14, rsi                  ; LBA
    mov rbx, rdi                  ; idx
    mov rax, rbx
    shr rax, 1
    mov rdi, rax
    mov rax, rbx
    and rax, 1
    mov rsi, rax
    call ata_select
    mov rax, rbx
    shr rax, 1
    mov rdi, rax
    call chan_ports
    push dx
    add dx, 2
    mov al, r13b
    out dx, al
    pop dx
    push dx
    add dx, 3
    mov rax, r14
    out dx, al
    pop dx
    push dx
    add dx, 4
    mov rax, r14
    shr rax, 8
    out dx, al
    pop dx
    push dx
    add dx, 5
    mov rax, r14
    shr rax, 16
    out dx, al
    pop dx
    push dx
    add dx, 6
    mov rax, r14
    shr rax, 24
    and al, 0x0F
    mov rcx, rbx
    and rcx, 1
    shl cl, 4
    or al, cl
    or al, 0xE0
    out dx, al
    pop dx
    push dx
    add dx, 7
    mov al, 0x30                  ; WRITE SECTORS
    out dx, al
    pop dx
.sector:
    test r13d, r13d
    jz .flush
    call ata_wait_drq
    test rax, rax
    jnz .fail
    mov rax, rbx
    shr rax, 1
    mov rdi, rax
    call chan_ports
    cld
    mov rsi, r12
    mov ecx, 256
    rep outsw                     ; dx = base+0, DS:RSI
    add r12, 512
    dec r13d
    jmp .sector
.flush:
    mov rax, rbx                  ; cache flush 0xE7
    shr rax, 1
    mov rdi, rax
    call chan_ports
    push dx
    add dx, 7
    mov al, 0xE7
    out dx, al
    pop dx
    call ata_poll
    test rax, rax
    jnz .fail
    xor eax, eax
    jmp .out
.fail:
    mov eax, 1
.out:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; full scan: detect + identify all 4 slots, print table. Preserves all.
ata_scan:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [msg_ata_head]
    call sh_print
    xor ebx, ebx                  ; idx 0..3
.slot:
    cmp rbx, 4
    jae .done
    mov rax, rbx
    shr rax, 1
    mov rdi, rax                  ; channel
    mov rax, rbx
    and rax, 1
    mov rsi, rax                  ; drive
    push rbx
    call ata_detect
    mov ecx, eax                  ; 0/1/2
    pop rbx
    push rax
    mov al, 'D'
    call sh_putc
    pop rax
    test ecx, ecx
    jz .next
    push rbx
    push rcx
    mov rax, rbx                  ; "hdX: "
    add al, 'a'
    push rax
    mov al, 'h'
    call sh_putc
    mov al, 'd'
    call sh_putc
    pop rax
    call sh_putc
    lea rsi, [msg_ata_sep]
    call sh_print
    pop rcx
    pop rbx
    cmp ecx, 2
    je .atapi
    push rbx                      ; ATA: identify
    mov rax, rbx
    call ata_identify
    test rax, rax
    push rax
    mov al, 'I'
    call sh_putc
    pop rax
    pop rbx
    jnz .ident_fail
    lea rsi, [ata_model]
    mov rax, rbx
    mov rcx, 41
    mul rcx
    add rsi, rax
    call sh_print
    lea rsi, [msg_ata_sp]
    call sh_print
    mov rax, [ata_sectors + rbx * 8]
    call print_dec64
    lea rsi, [msg_ata_blocks]
    call sh_print
    push rbx                      ; MBR probe: read LBA0
    mov rdi, rbx
    xor esi, esi
    mov edx, 1
    lea rcx, [ata_buf]
    call ata_read_lba
    test rax, rax
    jnz .nombr
    cmp word [ata_buf + 510], 0xAA55
    jne .nombr
    lea rsi, [msg_ata_mbr]
    call sh_print
    jmp .next_pop
.nombr:
    lea rsi, [msg_ata_nombr]
    call sh_print
    jmp .next_pop
.next_pop:
    pop rbx
    jmp .next
.atapi:
    lea rsi, [msg_ata_atapi]
    call sh_print
    jmp .next
.ident_fail:
    lea rsi, [msg_ata_identfail]
    call sh_print
    jmp .next
.next:
    inc rbx
    jmp .slot
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .rodata
msg_ata_head:   db "ATA disks (hdX: model sectors [MBR?]):", 0x0A, 0
msg_ata_sep:    db ": ", 0
msg_ata_sp:     db " ", 0
msg_ata_blocks: db " blocks", 0x0A, 0
msg_ata_mbr:    db " [MBR OK]", 0x0A, 0
msg_ata_nombr:  db " [no MBR]", 0x0A, 0
msg_ata_atapi:  db "ATAPI optical (not driven).", 0x0A, 0
msg_ata_identfail: db "IDENTIFY failed.", 0x0A, 0

section .bss
ata_buf:     resb 512
ata_present: resb 4
ata_atapi:   resb 4
ata_sectors: resq 4
ata_model:   resb 4 * 41
