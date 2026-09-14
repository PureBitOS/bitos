; BitOS — xHCI USB3 host controller driver, stage 1: find, take over,
; reset, ring init, start, port scan. (`usb` shell command.)
; Full device addressing / transfers come next; this proves MMIO mapping,
; DMA structures, and live port state. UHCI/EHCI support comes later.

global usb_scan
extern sh_print, sh_putc, pci_hex, palloc, mmio_map

section .text
bits 64

; ---- MMIO helpers. rdi = mmio base, esi = offset ----
; out: eax (rd32) / write edx (wr32)
xrd32:
    mov eax, [rdi + rsi]
    ret
xwr32:
    mov [rdi + rsi], edx
    ret

; ---- bounded delay (~ms scale on QEMU; keeps handlers honest) ----
; rcx = iterations of port-0x80 reads
xdelay:
    push rax
    push rdx
.loop:
    test rcx, rcx
    jz .out
    mov dx, 0x80
    in al, dx
    dec rcx
    jmp .loop
.out:
    pop rdx
    pop rax
    ret

; ---- find xHCI controller (class 0C0330). out: rax=1 + r15/14/13 set ----
xhci_find:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor r15d, r15d                ; bus
.bus:
    xor r14d, r14d                ; dev
.dev:
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    push r15
    push r14
    call pcicfg
    pop r14
    pop r15
    and eax, 0xFFFF
    cmp eax, 0xFFFF
    je .next_dev
    mov ecx, 0x08                 ; class dword
    push r15
    push r14
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    call pcicfg
    pop r14
    pop r15
    shr eax, 8
    and eax, 0xFFFFFF             ; CC SS PP
    cmp eax, 0x0C0330
    je .found
.next_dev:
    inc r14d
    cmp r14d, 32
    jb .dev
    inc r15d
    cmp r15d, 256
    jb .bus
    xor eax, eax
    jmp .out
.found:
    xor r13d, r13d                ; func 0 (xHCI is single-function)
    mov eax, 1
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; raw dword: rdi = bus, rsi = dev, rdx = func, rcx = reg -> eax
pcicfg:
    push rdx
    push rcx
    mov eax, edi
    shl eax, 16
    mov edx, esi
    shl edx, 11
    or eax, edx
    pop rcx
    pop rdx
    shl edx, 8
    or eax, edx
    and ecx, 0xFC
    or eax, ecx
    or eax, 0x80000000
    push rax
    mov dx, 0xCF8
    pop rax
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    ret

; ---- usb_scan: full bring-up + port report ----
usb_scan:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rsi, [msg_usb_head]
    call sh_print
    call xhci_find
    test rax, rax
    jnz .have
    lea rsi, [msg_usb_none]
    call sh_print
    jmp .done
.have:
    ; announce BB:DD.F + VID:DID
    mov eax, r15d
    mov ecx, 2
    call pci_hex
    mov al, ':'
    call sh_putc
    mov eax, r14d
    mov ecx, 2
    call pci_hex
    mov al, '.'
    call sh_putc
    mov eax, r13d
    mov ecx, 1
    call pci_hex
    mov al, ' '
    call sh_putc
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    xor ecx, ecx
    call pcicfg                  ; ids
    push rax
    and eax, 0xFFFF
    mov ecx, 4
    call pci_hex
    mov al, ':'
    call sh_putc
    pop rax
    shr eax, 16
    mov ecx, 4
    call pci_hex
    mov al, 0x0A
    call sh_putc
    ; BAR0 -> MMIO (map 128 KiB: caps + oper + runtime + doors + ports)
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    mov ecx, 0x10
    call pcicfg
    mov ebx, eax
    test ebx, 1
    jnz .pio_bar
    and ebx, ~0xF
    test ebx, ebx
    jz .no_bar
    mov [xhci_phys], rbx
    mov rdi, rbx
    mov rsi, 0x20000
    call mmio_map                ; -> rax = virt
    mov [xhci_base], rax
    jmp .mapped
.pio_bar:
    lea rsi, [msg_usb_pio]
    call sh_print
    jmp .done
.no_bar:
    lea rsi, [msg_usb_nobar]
    call sh_print
    jmp .done
.mapped:
    mov rdi, [xhci_base]
    ; capability parse
    xor esi, esi
    call xrd32                    ; CAPLENGTH (low byte)
    and eax, 0xFF
    mov [xhci_caplen], rax
    mov rdi, [xhci_base]
    mov esi, 2
    call xrd32
    and eax, 0xFFFF               ; HCIVERSION
    mov [xhci_ver], rax
    lea rsi, [msg_usb_ver]
    call sh_print
    shr rax, 8                    ; major
    and eax, 0xFF
    mov ecx, 1
    call pci_hex
    mov al, '.'
    call sh_putc
    mov rax, [xhci_ver]
    and eax, 0xFF                 ; minor (bcd-ish: print hex digit)
    mov ecx, 1
    call pci_hex
    mov al, 0x0A
    call sh_putc
    mov rdi, [xhci_base]          ; HCSPARAMS1: slots + ports
    mov esi, 4
    call xrd32
    mov ebx, eax
    and ebx, 0xFF                 ; MaxSlots
    mov [xhci_slots], rbx
    shr eax, 24                   ; MaxPorts
    and eax, 0xFF
    mov [xhci_ports], rax
    mov rax, [xhci_ports]
    call print_dec_small
    lea rsi, [msg_usb_ports]
    call sh_print
    mov rax, [xhci_slots]
    call print_dec_small
    lea rsi, [msg_usb_ports2]
    call sh_print
    ; ownership (BIOS -> OS) via ext caps
    call xhci_takeover
    test rax, rax
    jnz .takeover_fail
    ; stop + reset + init + start
    call xhci_reset
    test rax, rax
    jnz .reset_fail
    call xhci_rings
    test rax, rax
    jnz .rings_fail
    call xhci_start
    test rax, rax
    jnz .start_fail
    call xhci_portscan
    jmp .done
.takeover_fail:
    lea rsi, [msg_usb_takeover]
    call sh_print
    jmp .done
.reset_fail:
    lea rsi, [msg_usb_reset]
    call sh_print
    jmp .done
.rings_fail:
    lea rsi, [msg_usb_rings]
    call sh_print
    jmp .done
.start_fail:
    lea rsi, [msg_usb_start]
    call sh_print
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rax = small number (ports/slots) -> decimal
print_dec_small:
    push rax
    push rbx
    push rcx
    push rdx
    mov rbx, 10
    xor ecx, ecx
    test rax, rax
    jnz .div
    mov al, '0'
    call sh_putc
    jmp .out
.div:
    xor edx, edx
    div rbx
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

; ---- BIOS -> OS ownership. rax = 0 ok ----
xhci_takeover:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdi, [xhci_base]
    mov esi, 0x10                 ; HCCPARAMS1
    call xrd32
    shr eax, 16
    and eax, 0xFFFF               ; xECP (dwords)
    test eax, eax
    jz .no_ecp
    shl eax, 2                    ; byte offset
    mov ebx, eax
    mov ecx, 16                   ; walk at most 16 caps
.walk:
    mov rdi, [xhci_base]
    mov esi, ebx
    call xrd32
    and eax, 0xFF
    cmp eax, 1                    ; USBLEGSUP?
    je .legsup
    mov rdi, [xhci_base]
    mov esi, ebx
    call xrd32
    shr eax, 8
    and eax, 0xFF                 ; next pointer (dwords)
    test eax, eax
    jz .no_ecp
    shl eax, 2
    mov ebx, eax
    dec ecx
    jnz .walk
.no_ecp:
    xor eax, eax                  ; nothing to take over
    jmp .out
.legsup:
    mov rdi, [xhci_base]
    mov esi, ebx
    call xrd32                    ; current legsup
    test eax, 0x10000             ; BIOS owned?
    jz .already
    or eax, 0x1000000             ; set OS owned
    mov edx, eax
    mov rdi, [xhci_base]
    mov esi, ebx
    call xwr32
    mov ecx, 200000               ; wait BIOS release
.wait:
    mov rdi, [xhci_base]
    mov esi, ebx
    push rcx
    push rbx
    call xrd32
    pop rbx
    pop rcx
    test eax, 0x10000
    jz .already
    dec ecx
    jnz .wait
    mov eax, 1                    ; timeout
    jmp .out
.already:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- stop + reset. rax = 0 ok ----
xhci_reset:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, [xhci_caplen]        ; oper base offset
    mov rdi, [xhci_base]          ; USBCMD = 0 (stop)
    mov rsi, rbx
    xor edx, edx
    call xwr32
    mov ecx, 200000               ; wait HCHalted
.haltw:
    mov rdi, [xhci_base]
    mov rsi, rbx
    add rsi, 4                    ; USBSTS
    push rcx
    call xrd32
    pop rcx
    test eax, 1
    jnz .halted
    dec ecx
    jnz .haltw
    mov eax, 1
    jmp .out
.halted:
    mov rdi, [xhci_base]          ; HCRST
    mov rsi, rbx
    mov edx, 2
    call xwr32
    mov ecx, 500000
.rstwait:
    mov rdi, [xhci_base]
    mov rsi, rbx
    push rcx
    call xrd32                    ; USBCMD
    pop rcx
    test eax, 2
    jz .reset_done
    dec ecx
    jnz .rstwait
    mov eax, 1
    jmp .out
.reset_done:
    mov ecx, 500000               ; wait CNR clear
.cnrwait:
    mov rdi, [xhci_base]
    mov rsi, rbx
    add rsi, 4                    ; USBSTS
    push rcx
    call xrd32
    pop rcx
    test eax, 0x800               ; CNR bit 11
    jz .ready
    dec ecx
    jnz .cnrwait
    mov eax, 1
    jmp .out
.ready:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- DMA rings + DCBAA + event ring. rax = 0 ok ----
xhci_rings:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov rbx, [xhci_caplen]
    ; DCBAA: (slots+1)*8 bytes @64
    mov rax, [xhci_slots]
    cmp rax, 8
    jbe .slots_ok
    mov rax, 8
.slots_ok:
    mov [xhci_slots_en], rax
    inc rax
    shl rax, 3                   ; *8
    mov rdi, rax
    mov rsi, 64
    call palloc
    test rax, rax
    jz .fail
    mov r12, rax                  ; DCBAA phys
    ; zero it (64-bit stores; identity-mapped RAM)
    push rcx
    mov rcx, [xhci_slots_en]
    inc rcx
    shl rcx, 3
    shr rcx, 3                    ; entries... (zero qwords)
    mov rdi, r12
    xor eax, eax
.zdcb:
    test rcx, rcx
    jz .zdcb_done
    mov [rdi], rax
    add rdi, 8
    dec rcx
    jmp .zdcb
.zdcb_done:
    pop rcx
    mov rdi, [xhci_base]          ; DCBAAP lo/hi
    mov rsi, rbx
    add rsi, 0x30
    mov edx, r12d
    call xwr32
    mov rdi, [xhci_base]
    mov rsi, rbx
    add rsi, 0x34
    mov rdx, r12
    shr rdx, 32
    mov edx, edx
    call xwr32
    mov rdi, [xhci_base]          ; CONFIG MaxSlotsEn
    mov rsi, rbx
    add rsi, 0x38
    mov rdx, [xhci_slots_en]
    mov edx, edx
    call xwr32
    ; command ring: 16 TRBs (256 B) @64, link last
    mov rdi, 256
    mov rsi, 64
    call palloc
    test rax, rax
    jz .fail
    mov r12, rax
    push rcx
    mov rcx, 32                   ; zero 32 qwords
    mov rdi, r12
    xor eax, eax
.zcmd:
    mov [rdi], rax
    add rdi, 8
    dec rcx
    jnz .zcmd
    pop rcx
    mov [r12 + 240], r12          ; link TRB DW0: target = ring base
    mov dword [r12 + 248], 0
    mov dword [r12 + 252], (6 << 10) | (1 << 1) | 1
    mov rbx, [xhci_caplen]
    mov rdi, [xhci_base]          ; CRCR lo: base | RCS
    mov rsi, rbx
    add rsi, 0x18
    mov edx, r12d
    or edx, 1
    call xwr32
    mov rdi, [xhci_base]          ; CRCR hi
    mov rsi, rbx
    add rsi, 0x1C
    mov rdx, r12
    shr rdx, 32
    mov edx, edx
    call xwr32
    mov [xhci_cmdring], r12
    ; event ring: 16 TRBs (256 B) @64 + segment table (16 B) @64
    mov rdi, 256
    mov rsi, 64
    call palloc
    test rax, rax
    jz .fail
    mov r12, rax
    push rcx
    mov rcx, 32
    mov rdi, r12
    xor eax, eax
.zevt:
    mov [rdi], rax
    add rdi, 8
    dec rcx
    jnz .zevt
    pop rcx
    mov [xhci_evtring], r12
    mov rdi, 16
    mov rsi, 64
    call palloc
    test rax, rax
    jz .fail
    mov [rax], r12                ; seg0 base (qword)
    mov rbx, rax
    mov dword [rbx + 8], 16       ; seg0 size (TRBs)
    mov dword [rbx + 12], 0
    mov [xhci_erst], rbx
    ; runtime regs: ERSTSZ=1, ERSTBA, ERDP, IMAN
    mov rdi, [xhci_base]
    mov esi, 0x18
    call xrd32                    ; RTSOFF
    and eax, ~0x1F
    mov r12, rax                  ; rt base offset
    add r12, [xhci_base]          ; (r12 = rt abs base; keep)
    mov rdi, r12
    mov esi, 0x28                 ; ERSTSZ
    mov edx, 1
    call xwr32
    mov rdi, r12
    mov esi, 0x30                 ; ERSTBA lo/hi
    mov rdx, [xhci_erst]
    mov edx, edx
    call xwr32
    mov rdi, r12
    mov esi, 0x34
    mov rdx, [xhci_erst]
    shr rdx, 32
    mov edx, edx
    call xwr32
    mov rdi, r12
    mov esi, 0x38                 ; ERDP = event base
    mov rdx, [xhci_evtring]
    mov edx, edx
    call xwr32
    mov rdi, r12
    mov esi, 0x3C
    mov rdx, [xhci_evtring]
    shr rdx, 32
    mov edx, edx
    call xwr32
    mov rdi, r12
    mov esi, 0x20                 ; IMAN: clear IP, enable IE
    mov edx, 3
    call xwr32
    xor eax, eax
    jmp .out
.fail:
    mov eax, 1
.out:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- start controller. rax = 0 ok ----
xhci_start:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, [xhci_caplen]
    mov rdi, [xhci_base]
    mov rsi, rbx
    mov edx, 1                    ; RUN (INTE left off: polling)
    call xwr32
    mov ecx, 200000
.runwait:
    mov rdi, [xhci_base]
    mov rsi, rbx
    add rsi, 4                    ; USBSTS
    push rcx
    call xrd32
    pop rcx
    test eax, 1                   ; HCHalted clear?
    jz .running
    dec ecx
    jnz .runwait
    mov eax, 1
    jmp .out
.running:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- port scan: CCS/PED/speed per port + summary ----
xhci_portscan:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx, [xhci_caplen]
    add rbx, 0x400                 ; port base offset
    xor r13d, r13d                ; port index 0..
    xor r12d, r12d                ; connected count
.port:
    mov rax, [xhci_ports]
    cmp r13d, eax
    jae .summary
    mov rdi, [xhci_base]          ; PORTSC (power it if needed)
    mov rsi, rbx
    mov rax, r13
    shl rax, 4
    add rsi, rax
    push rsi
    call xrd32
    mov edx, eax
    test edx, 0x4000              ; PP?
    jnz .powered
    and edx, ~0x1E                ; keep W1C bits uncleared
    or edx, 0x4000
    mov rdi, [xhci_base]
    pop rsi
    push rsi
    call xwr32
    mov rcx, 5000                 ; settle
    call xdelay
.powered:
    mov rdi, [xhci_base]
    pop rsi
    call xrd32
    mov edx, eax
    ; print "Port N: ..."
    lea rsi, [msg_usb_port]
    call sh_print
    mov eax, r13d
    inc eax                        ; 1-based for humans
    call print_dec_small
    test edx, 1                   ; CCS?
    jz .empty
    inc r12d
    lea rsi, [msg_usb_conn]
    call sh_print
    mov eax, edx
    shr eax, 10
    and eax, 0xF                  ; speed
    cmp eax, 1
    je .spd_fs
    cmp eax, 2
    je .spd_ls
    cmp eax, 3
    je .spd_hs
    cmp eax, 4
    je .spd_ss
    cmp eax, 5
    je .spd_ssp
    lea rsi, [msg_usb_spd_q]
    call sh_print
    jmp .pen
.spd_fs:
    lea rsi, [msg_usb_spd_fs]
    call sh_print
    jmp .pen
.spd_ls:
    lea rsi, [msg_usb_spd_ls]
    call sh_print
    jmp .pen
.spd_hs:
    lea rsi, [msg_usb_spd_hs]
    call sh_print
    jmp .pen
.spd_ss:
    lea rsi, [msg_usb_spd_ss]
    call sh_print
    jmp .pen
.spd_ssp:
    lea rsi, [msg_usb_spd_ssp]
    call sh_print
.pen:
    test edx, 0x200               ; PED?
    jnz .next
    lea rsi, [msg_usb_noped]
    call sh_print
    jmp .next
.empty:
    lea rsi, [msg_usb_empty]
    call sh_print
.next:
    mov al, 0x0A
    call sh_putc
    inc r13d
    jmp .port
.summary:
    lea rsi, [msg_usb_sum]
    call sh_print
    mov eax, r12d
    call print_dec_small
    lea rsi, [msg_usb_sum2]
    call sh_print
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
msg_usb_head:   db "USB xHCI bring-up:", 0x0A, 0
msg_usb_none:   db "No xHCI USB3 controller (class 0C0330) found.", 0x0A
                db "USB sticks/keyboards via UHCI/EHCI come later.", 0x0A, 0
msg_usb_pio:    db "xHCI BAR0 is PIO-mapped?! Giving up.", 0x0A, 0
msg_usb_nobar:  db "xHCI BAR0 empty. Giving up.", 0x0A, 0
msg_usb_ver:    db "xHCI version ", 0
msg_usb_ports:  db " ports, slots=", 0
msg_usb_ports2: db 0x0A, 0
msg_usb_takeover: db "Ownership takeover timed out (BIOS held on).", 0x0A, 0
msg_usb_reset:  db "Controller reset timed out.", 0x0A, 0
msg_usb_rings:  db "DMA alloc failed (need ~8 KiB below 16 MiB).", 0x0A, 0
msg_usb_start:  db "Controller would not start (still halted).", 0x0A, 0
msg_usb_port:   db "Port ", 0
msg_usb_conn:   db ": connected ", 0
msg_usb_empty:  db ": empty", 0
msg_usb_noped:  db " (not enabled yet)", 0
msg_usb_spd_q:  db "speed?", 0
msg_usb_spd_ls: db "Low-speed 1.5M", 0
msg_usb_spd_fs: db "Full-speed 12M", 0
msg_usb_spd_hs: db "High-speed 480M", 0
msg_usb_spd_ss: db "SuperSpeed 5G", 0
msg_usb_spd_ssp: db "SuperSpeedPlus 10G", 0
msg_usb_sum:    db "xHCI: ", 0
msg_usb_sum2:   db " device(s) on ports.", 0x0A, 0

section .bss
xhci_phys:    resq 1
xhci_base:    resq 1
xhci_caplen:  resq 1
xhci_ver:     resq 1
xhci_slots:   resq 1
xhci_ports:   resq 1
xhci_slots_en: resq 1
xhci_cmdring: resq 1
xhci_evtring: resq 1
xhci_erst:    resq 1
