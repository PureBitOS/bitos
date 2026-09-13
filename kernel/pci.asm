; BitOS — PCI device discovery (configuration mechanism 1, ports 0xCF8/0xCFC).
; `devices` shell command: recursive bus scan (follows PCI-PCI bridges),
; prints bus:dev.func + vendor:device + class + known vendor names.
; Groundwork for real drivers (popular devices + partial laptop support).

global pci_scan
extern sh_print, sh_putc

section .text
bits 64

PCI_ADDR equ 0xCF8
PCI_DATA equ 0xCFC

; dword config read: rdi = bus, rsi = dev, rdx = func, rcx = reg -> eax
pci_read:
    push rdx
    push rcx
    mov eax, edi
    shl eax, 16                  ; bus
    mov edx, esi
    shl edx, 11                  ; device
    or eax, edx
    pop rcx
    pop rdx
    shl edx, 8                   ; function
    or eax, edx
    and ecx, 0xFC
    or eax, ecx
    or eax, 0x80000000           ; enable bit
    push rax
    mov dx, PCI_ADDR
    pop rax
    out dx, eax
    mov dx, PCI_DATA
    in eax, dx
    ret

; print hex: eax = value, ecx = digits
pci_hex:
    push rax
    push rbx
    push rcx
    push rdx
    mov ebx, eax
    mov edx, ecx
.top:
    dec edx
    mov cl, dl
    shl cl, 2
    mov eax, ebx
    shr eax, cl
    and al, 0x0F
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .out
.digit:
    add al, '0'
.out:
    call sh_putc
    test edx, edx
    jnz .top
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ax = vendor id -> rsi = name (or "?" )
vendor_name:
    push rax
    push rdx
    lea rdx, [vendor_table]
.loop:
    cmp word [rdx], 0xFFFF
    je .unknown
    cmp ax, [rdx]
    je .found
    add rdx, 10
    jmp .loop
.found:
    mov rsi, [rdx + 2]
    jmp .out
.unknown:
    lea rsi, [str_q]
.out:
    pop rdx
    pop rax
    ret

; eax = class dword (CCSSPPRR) -> rsi = class string
class_name:
    push rax
    push rcx
    mov ecx, eax
    shr ecx, 24                  ; base class in cl
    cmp cl, 0x01
    je .storage
    cmp cl, 0x02
    je .network
    cmp cl, 0x03
    je .display
    cmp cl, 0x04
    je .multimedia
    cmp cl, 0x05
    je .memory
    cmp cl, 0x06
    je .bridge
    cmp cl, 0x07
    je .comm
    cmp cl, 0x08
    je .generic
    cmp cl, 0x09
    je .input
    cmp cl, 0x0C
    je .serial
    cmp cl, 0x0D
    je .wireless
    lea rsi, [str_legacy]
    jmp .out
.storage:
    lea rsi, [str_storage]
    shr eax, 16
    and al, 0xFF                 ; subclass
    cmp al, 0x01
    je .is_ide
    cmp al, 0x06
    je .is_sata
    cmp al, 0x08
    je .is_nvme
    jmp .out
.is_ide:
    lea rsi, [str_ide]
    jmp .out
.is_sata:
    lea rsi, [str_sata]
    jmp .out
.is_nvme:
    lea rsi, [str_nvme]
    jmp .out
.network:
    lea rsi, [str_network]
    shr eax, 16
    and al, 0xFF                 ; subclass
    cmp al, 0x00
    jne .out
    lea rsi, [str_ethernet]
    jmp .out
.display:
    lea rsi, [str_display]
    shr eax, 16
    and al, 0xFF
    cmp al, 0x00
    jne .out
    lea rsi, [str_vga]
    jmp .out
.multimedia:
    lea rsi, [str_media]
    shr eax, 16
    and al, 0xFF
    cmp al, 0x03
    jne .out
    lea rsi, [str_audio]
    jmp .out
.memory:
    lea rsi, [str_memory]
    jmp .out
.bridge:
    lea rsi, [str_bridge]
    shr eax, 16
    and al, 0xFF
    cmp al, 0x00
    je .is_host
    cmp al, 0x01
    je .is_isa
    cmp al, 0x04
    je .is_p2p
    jmp .out
.is_host:
    lea rsi, [str_host]
    jmp .out
.is_isa:
    lea rsi, [str_isa]
    jmp .out
.is_p2p:
    lea rsi, [str_p2p]
    jmp .out
.comm:
    lea rsi, [str_comm]
    jmp .out
.generic:
    lea rsi, [str_generic]
    jmp .out
.input:
    lea rsi, [str_input]
    jmp .out
.serial:
    lea rsi, [str_serial]
    shr eax, 16
    and al, 0xFF
    cmp al, 0x03
    jne .out
    lea rsi, [str_usb]           ; USB (prog-if tells UHCI/OHCI/EHCI/xHCI)
    jmp .out
.wireless:
    lea rsi, [str_wireless]
    jmp .out
.out:
    pop rcx
    pop rax
    ret

; print one device line: r15 = bus, r14 = dev, r13 = func
; eax destroyed freely; rsi/rdi preserved for caller? scan owns them — clobber ok
; except must preserve r15/r14/r13 (loop vars) across sh_* calls (they preserve).
print_device:
    push rax
    push rcx
    push rdx
    ; "BB:DD.F "
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
    ; re-read ids (pci_read clobbers nothing we need)
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    xor ecx, ecx
    call pci_read                ; eax = device:vendor
    push rax
    and eax, 0xFFFF              ; vendor id first (VVVV:DDDD)
    mov ecx, 4
    call pci_hex
    mov al, ':'
    call sh_putc
    pop rax                      ; ids dword back
    push rax                     ; keep full ids for vendor lookup below
    shr eax, 16                  ; then device id
    push rax
    mov ecx, 4
    call pci_hex
    mov al, ' '
    call sh_putc
    ; class
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    mov ecx, 0x08
    call pci_read
    push rax
    call class_name              ; -> rsi
    call sh_print
    mov al, ' '
    call sh_putc
    ; vendor name
    pop rax                      ; class dword (discard)
    pop rax                      ; shifted device id (discard)
    pop rax                      ; ids dword
    and eax, 0xFFFF
    call vendor_name
    call sh_print
    mov al, 0x0A
    call sh_putc
    inc qword [pci_count]
    pop rdx
    pop rcx
    pop rax
    ret

; recursive scan: rdi = bus
scan_bus:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdi                 ; bus
    xor r14d, r14d               ; dev 0..31
.dev_loop:
    ; vendor of func 0 decides if device exists
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    call pci_read
    and eax, 0xFFFF
    cmp eax, 0xFFFF
    je .next_dev
    ; header type -> multifunction?
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    mov ecx, 0x0C
    call pci_read
    shr eax, 16
    and eax, 0xFF
    mov r12d, 0
    test al, 0x80
    jz .func_loop
    mov r12d, 7
.func_loop:                      ; r13 = func
    xor r13d, r13d
.func_each:
    ; skip absent non-zero funcs
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    xor ecx, ecx
    call pci_read
    and eax, 0xFFFF
    cmp eax, 0xFFFF
    je .next_func
    call print_device
    ; PCI-PCI bridge? follow to secondary bus
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    mov ecx, 0x08
    call pci_read
    cmp eax, 0x06040000
    jb .next_func                ; base != 06? (unsigned: class < 0604xx)
    shr eax, 16
    and eax, 0xFFFF
    cmp ax, 0x0604
    jne .next_func
    mov rdi, r15
    mov rsi, r14
    mov rdx, r13
    mov ecx, 0x18
    call pci_read                ; bits 15:8 = secondary bus
    shr eax, 8
    and eax, 0xFF
    cmp eax, r15d                ; sanity: never recurse into own bus
    je .next_func
    push rdi
    mov edi, eax
    call scan_bus
    pop rdi
.next_func:
    inc r13d
    cmp r13d, r12d
    jbe .func_each
.next_dev:
    inc r14d
    cmp r14d, 32
    jb .dev_loop
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; shell entry: list every PCI device + total
pci_scan:
    push rdi
    lea rsi, [msg_pci_head]
    call sh_print
    mov qword [pci_count], 0
    xor edi, edi                 ; bus 0
    call scan_bus
    mov rax, [pci_count]
    mov ecx, 2                   ; device count in hex (enough for real hw)
    cmp rax, 0xFF
    jbe .small
    mov ecx, 4
.small:
    call pci_hex
    lea rsi, [msg_pci_tail]
    call sh_print
    pop rdi
    ret

section .rodata
msg_pci_head: db "PCI bus:dev.func vendor:device class vendor-name", 0x0A, 0
msg_pci_tail: db " device(s) found.", 0x0A, 0
str_q:        db "?", 0
str_legacy:   db "legacy", 0
str_storage:  db "storage", 0
str_ide:      db "storage/IDE", 0
str_sata:     db "storage/SATA", 0
str_nvme:     db "storage/NVMe", 0
str_network:  db "network", 0
str_ethernet: db "network/Ethernet", 0
str_display:  db "display", 0
str_vga:      db "display/VGA", 0
str_media:    db "multimedia", 0
str_audio:    db "multimedia/HD-Audio", 0
str_memory:   db "memory", 0
str_bridge:   db "bridge", 0
str_host:     db "bridge/host", 0
str_isa:      db "bridge/ISA", 0
str_p2p:      db "bridge/PCI-PCI", 0
str_comm:     db "comm", 0
str_generic:  db "generic", 0
str_input:    db "input", 0
str_serial:   db "serial-bus", 0
str_usb:      db "serial-bus/USB", 0
str_wireless: db "wireless", 0

; popular vendors: dw id, dq name (0xFFFF ends)
vendor_table:
    dw 0x8086
    dq str_intel
    dw 0x10DE
    dq str_nvidia
    dw 0x1002
    dq str_amd
    dw 0x1022
    dq str_amd
    dw 0x14C3
    dq str_mediatek
    dw 0x10EC
    dq str_realtek
    dw 0x168C
    dq str_atheros
    dw 0x1969
    dq str_atheros
    dw 0x1B21
    dq str_asmedia
    dw 0x1AF4
    dq str_virtio
    dw 0x1234
    dq str_qemu
    dw 0x80EE
    dq str_vbox
    dw 0x15AD
    dq str_vmware
    dw 0xFFFF
    dq str_q
str_intel:    db "Intel", 0
str_nvidia:   db "NVIDIA", 0
str_amd:      db "AMD", 0
str_mediatek: db "MediaTek", 0
str_realtek:  db "Realtek", 0
str_atheros:  db "Atheros", 0
str_asmedia:  db "ASMedia", 0
str_virtio:   db "RedHat/VirtIO", 0
str_qemu:     db "QEMU", 0
str_vbox:     db "VirtualBox", 0
str_vmware:   db "VMware", 0

section .bss
pci_count: resq 1
