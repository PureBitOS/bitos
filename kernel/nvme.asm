; BitOS — NVMe storage driver, stage 1: find, map, disable, admin queues,
; enable, Identify (controller + namespace), block read with MBR check.
; (`nvme` shell command.) Real block I/O proves the driver; filesystems
; and I/O queues come later.

global nvme_probe
global print_dec64                ; reused by ata.asm + gui.asm
extern sh_print, sh_putc, pci_hex, palloc, mmio_map

section .text
bits 64

NVM_DEPTH equ 16                 ; admin queue entries (<= MQES)

; ---- PCI config dword: rdi = bus, rsi = dev, rdx = func, rcx = reg ----
ncfg:
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

nrd32:                           ; rdi = mmio base, esi = off -> eax
    mov eax, [rdi + rsi]
    ret
nwr32:                           ; rdi = base, esi = off, edx = val
    mov [rdi + rsi], edx
    ret
nrd64:                           ; rdi = base, esi = off -> rax
    mov eax, [rdi + rsi]
    mov edx, [rdi + rsi + 4]
    shl rdx, 32
    or rax, rdx
    ret

; ---- find NVMe (class 010802). rax=1 + r15/14/13 ----
nvme_find:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor r15d, r15d
.bus:
    xor r14d, r14d
.dev:
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    call ncfg
    and eax, 0xFFFF
    cmp eax, 0xFFFF
    je .next_dev
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    mov ecx, 8
    call ncfg
    shr eax, 8
    and eax, 0xFFFFFF
    cmp eax, 0x010802
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
    xor r13d, r13d
    mov eax, 1
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- bounded MMIO reg waits. rdi = mmio, esi = off, edx = mask ----
; nwait_set: until (reg & mask) == mask. nwait_clr: until == 0.
; rax = 0 ok, 1 timeout.
nwait_set:
    push rcx
    mov ecx, 500000
.loop:
    push rax
    push rdx
    push rsi
    push rdi
    call nrd32
    pop rdi
    pop rsi
    pop rdx
    mov ebx, eax
    pop rax
    and ebx, edx
    cmp ebx, edx
    je .ok
    dec ecx
    jnz .loop
    mov eax, 1
    jmp .out
.ok:
    xor eax, eax
.out:
    pop rcx
    ret
nwait_clr:
    push rcx
    mov ecx, 500000
.loop:
    push rax
    push rdx
    push rsi
    push rdi
    call nrd32
    pop rdi
    pop rsi
    pop rdx
    pop rax
    test eax, edx
    jz .ok
    dec ecx
    jnz .loop
    mov eax, 1
    jmp .out
.ok:
    xor eax, eax
.out:
    pop rcx
    ret

nvme_cmd:

; ---- submit admin command + poll completion ----
; r8d = opcode, r9d = nsid, r10d = cdw10, r11d = cdw11,
; stack param: cdw12 in [rsp+8] on entry... simpler: r12d = cdw12,
; r13 = prp phys. Preserves rbx (caller). rax = 0 ok / status>>17 on fail.
; Uses nvm_tail/nvm_head/nvm_phase + doorbells (stride in nvm_dbstride).
nvme_cmd:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov ebx, [nvm_tail]
    mov rax, rbx
    shl rax, 6                    ; *64 = SQE offset
    add rax, [nvm_sq]             ; base (identity DMA: phys == CPU ptr)
    mov ecx, ebx
    inc ecx
    shl ecx, 16                   ; CID = tail+1
    mov edx, r8d
    and edx, 0xFF                 ; opcode
    or ecx, edx
    mov [rax], ecx                ; DW0
    mov [rax + 4], r9d            ; NSID
    mov dword [rax + 8], 0
    mov dword [rax + 12], 0
    mov dword [rax + 16], 0       ; MPTR
    mov dword [rax + 20], 0
    mov [rax + 24], r13           ; PRP1
    mov qword [rax + 32], 0       ; PRP2
    mov [rax + 40], r10d          ; CDW10
    mov [rax + 44], r11d          ; CDW11
    mov [rax + 48], r12d          ; CDW12
    mov dword [rax + 52], 0
    mov dword [rax + 56], 0
    mov dword [rax + 60], 0
    ; advance tail + ring SQ doorbell
    mov ebx, [nvm_tail]
    inc ebx
    cmp ebx, [nvm_depth]
    jb .notailwrap
    xor ebx, ebx
.notailwrap:
    mov [nvm_tail], ebx
    mov rdi, [nvm_base]
    mov esi, [nvm_db0]
    mov edx, ebx
    call nwr32
    ; poll CQ head for our phase
    mov ecx, 1000000
.poll:
    mov rax, [nvm_head]
    shl rax, 4                    ; *16 = CQE offset
    add rax, [nvm_cq]
    mov edx, [rax + 12]           ; DW3
    shr edx, 16
    and edx, 1                    ; phase bit
    cmp edx, [nvm_phase]
    je .cpl
    dec ecx
    jnz .poll
    mov eax, 0xFFFFFFFF           ; timeout
    jmp .out
.cpl:
    mov edx, [rax + 12]
    shr edx, 17
    and edx, 0xFF                 ; SC
    push rdx                      ; save SC
    mov rbx, [nvm_head]           ; advance head
    inc rbx
    cmp rbx, [nvm_depth]
    jb .nowrap
    xor ebx, ebx
    xor qword [nvm_phase], 1
.nowrap:
    mov [nvm_head], rbx
    mov rdi, [nvm_base]           ; ring CQ doorbell
    mov esi, [nvm_db1]
    mov edx, ebx
    call nwr32
    pop rax                       ; SC (0 = ok)
.out:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- submit NVM I/O command on IOSQ1 + poll IOCQ1 ----
; Same contract as nvme_cmd (r8d..r13 in, SC out), 16-entry queues.
nvme_io_cmd:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    mov ebx, [nvm_io_tail]
    mov rax, rbx
    shl rax, 6
    add rax, [nvm_io_sq]
    mov ecx, ebx
    inc ecx
    shl ecx, 16
    mov edx, r8d
    and edx, 0xFF
    or ecx, edx
    mov [rax], ecx                ; DW0
    mov [rax + 4], r9d            ; NSID
    mov dword [rax + 8], 0
    mov dword [rax + 12], 0
    mov dword [rax + 16], 0
    mov dword [rax + 20], 0
    mov [rax + 24], r13           ; PRP1
    mov qword [rax + 32], 0
    mov [rax + 40], r10d          ; CDW10 (SLBA lo)
    mov [rax + 44], r11d          ; CDW11 (SLBA hi)
    mov [rax + 48], r12d          ; CDW12 (NLB)
    mov dword [rax + 52], 0
    mov dword [rax + 56], 0
    mov dword [rax + 60], 0
    mov ebx, [nvm_io_tail]
    inc ebx
    cmp ebx, 16
    jb .ionotailwrap
    xor ebx, ebx
.ionotailwrap:
    mov [nvm_io_tail], ebx
    mov rdi, [nvm_base]
    mov esi, [nvm_iodb_sq]
    mov edx, ebx
    call nwr32
    mov ecx, 1000000
.iopoll:
    mov rax, [nvm_io_head]
    shl rax, 4
    add rax, [nvm_io_cq]
    mov edx, [rax + 12]
    shr edx, 16
    and edx, 1
    cmp edx, [nvm_io_phase]
    je .iocpl
    dec ecx
    jnz .iopoll
    mov eax, 0xFFFFFFFF
    jmp .ioout
.iocpl:
    mov edx, [rax + 12]
    shr edx, 17
    and edx, 0xFF
    push rdx
    mov rbx, [nvm_io_head]
    inc rbx
    cmp rbx, 16
    jb .ionowrap
    xor ebx, ebx
    xor qword [nvm_io_phase], 1
.ionowrap:
    mov [nvm_io_head], rbx
    mov rdi, [nvm_base]
    mov esi, [nvm_iodb_cq]
    mov edx, ebx
    call nwr32
    pop rax
.ioout:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ---- nvme_probe: full bring-up + identify + block read ----
nvme_probe:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rsi, [msg_nvme_head]
    call sh_print
    call nvme_find
    test rax, rax
    jnz .have
    lea rsi, [msg_nvme_none]
    call sh_print
    jmp .done
.have:
    mov eax, r15d                 ; BB:DD.F
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
    mov rdi, r15                  ; VID:DID
    mov rsi, r14
    mov rdx, r13
    xor ecx, ecx
    call ncfg
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
    ; BAR0 (func is always 0 here)
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    mov ecx, 0x10
    call ncfg
    mov ebx, eax
    test ebx, 1
    jnz .pio_bar
    mov r12d, ebx
    and r12d, ~0xF
    mov r13, r12                  ; base lo
    test ebx, 4                   ; 64-bit BAR? OR high dword
    jz .bar32
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    mov ecx, 0x14
    call ncfg
    shl rax, 32
    or r13, rax
.bar32:
    test r13, r13
    jz .no_bar
    mov [nvm_phys], r13
    mov rdi, r13
    mov rsi, 0x4000               ; 16 KiB: regs + doorbells
    call mmio_map
    mov [nvm_base], rax
    jmp .mapped
.pio_bar:
    lea rsi, [msg_nvme_pio]
    call sh_print
    jmp .done
.no_bar:
    lea rsi, [msg_nvme_nobar]
    call sh_print
    jmp .done
.mapped:
    mov rdi, [nvm_base]           ; CAP (64-bit)
    xor esi, esi
    call nrd64
    mov rbx, rax
    mov rcx, 0x2000000000         ; CSS bit 37 (movabs: full 64-bit)
    test rax, rcx                 ; NVM command set?
    jz .no_nvm
    and eax, 0xFFFF                ; MQES
    inc rax
    cmp rax, 16
    jbe .depth_ok
    mov rax, 16
.depth_ok:
    mov [nvm_depth], rax
    mov rax, rbx
    shr rax, 32
    and eax, 0xF                   ; DBS
    mov ecx, eax
    mov eax, 4
    shl eax, cl                    ; stride = 4 << DBS
    mov [nvm_stride], rax
    mov rax, 0x1000
    add rax, [nvm_stride]          ; db1 = 0x1000 + stride
    mov [nvm_db1], rax
    mov qword [nvm_db0], 0x1000    ; admin SQ tail doorbell
    mov qword [nvm_db0], 0x1000
    lea rsi, [msg_nvme_vs]        ; version MJR.MNR
    call sh_print
    mov rdi, [nvm_base]
    mov esi, 8
    call nrd32
    mov ebx, eax
    shr eax, 16
    mov ecx, 4
    call pci_hex
    mov al, '.'
    call sh_putc
    mov eax, ebx
    shr eax, 8
    and eax, 0xFF
    mov ecx, 2
    call pci_hex
    mov al, 0x0A
    call sh_putc
    ; disable if running: only when CC.EN is actually set (some QEMU
    ; builds report RDY=1 with EN=0; waiting there would hang forever)
    mov rdi, [nvm_base]
    mov esi, 0x1C                  ; CSTS
    call nrd32
    test eax, 1
    jz .not_running
    mov rdi, [nvm_base]            ; RDY set: check CC.EN
    mov esi, 0x14
    call nrd32
    test eax, 1
    jz .not_running                ; EN already 0: QEMU quirk, proceed
    mov rdi, [nvm_base]
    mov esi, 0x14
    xor edx, edx
    call nwr32
    mov rdi, [nvm_base]
    mov esi, 0x1C
    mov edx, 1
    call nwait_clr
    test rax, rax
    jnz .takeover                  ; EN stuck? controller already ready:
                                   ; take over live (QEMU boots enabled)
    jmp .not_running
.takeover:
    lea rsi, [msg_nvme_takeover]
    call sh_print
    jmp .not_running
.not_running:
    ; admin queues: SQ (depth*64 @4K), CQ (depth*16 @4K), data (4K @4K)
    mov rax, [nvm_depth]
    shl rax, 6
    mov rdi, rax
    mov rsi, 4096
    call palloc
    test rax, rax
    jz .alloc_fail
    mov [nvm_sq], rax
    mov rax, [nvm_depth]
    shl rax, 4
    mov rdi, rax
    mov rsi, 4096
    call palloc
    test rax, rax
    jz .alloc_fail
    mov [nvm_cq], rax
    mov rdi, 4096
    mov rsi, 4096
    call palloc
    test rax, rax
    jz .alloc_fail
    mov [nvm_data], rax
    mov rdi, [nvm_sq]              ; zero SQ (depth qwords... 64 B each)
    mov rcx, [nvm_depth]
    shl rcx, 3
    xor eax, eax
.zsq:
    mov [rdi], rax
    add rdi, 8
    dec rcx
    jnz .zsq
    mov rdi, [nvm_cq]              ; zero CQ (depth*2 qwords)
    mov rcx, [nvm_depth]
    shl rcx, 1
.zcq:
    mov [rdi], rax
    add rdi, 8
    dec rcx
    jnz .zcq
    ; AQA = (asqs<<16)|acqs, asqs = acqs = depth-1
    mov rax, [nvm_depth]
    dec rax
    mov rdx, rax
    shl rax, 16
    or rax, rdx
    mov rdx, rax
    mov rdi, [nvm_base]
    mov esi, 0x24
    mov edx, edx
    call nwr32
    mov rdi, [nvm_base]            ; ASQ lo/hi
    mov esi, 0x28
    mov rdx, [nvm_sq]
    mov edx, edx
    call nwr32
    mov rdi, [nvm_base]
    mov esi, 0x2C
    mov rdx, [nvm_sq]
    shr rdx, 32
    mov edx, edx
    call nwr32
    mov rdi, [nvm_base]            ; ACQ lo/hi
    mov esi, 0x30
    mov rdx, [nvm_cq]
    mov edx, edx
    call nwr32
    mov rdi, [nvm_base]
    mov esi, 0x34
    mov rdx, [nvm_cq]
    shr rdx, 32
    mov edx, edx
    call nwr32
    mov qword [nvm_head], 0
    mov qword [nvm_tail], 0
    mov qword [nvm_phase], 1
    ; enable: CC = EN | IOSQES=6 | IOCQES=6
    mov rdi, [nvm_base]
    mov esi, 0x14
    mov edx, 0x460001
    call nwr32
    mov rdi, [nvm_base]
    mov esi, 0x1C
    mov edx, 1
    call nwait_set
    test rax, rax
    jnz .enable_fail
    ; ---- I/O queues (NVM reads need them; admin queue can't do I/O) ----
    mov rdi, 256                  ; IOCQ1: 16 x 16 B @4K
    mov rsi, 4096
    call palloc
    test rax, rax
    jz .alloc_fail
    mov [nvm_io_cq], rax
    mov rdi, 1024                 ; IOSQ1: 16 x 64 B @4K
    mov rsi, 4096
    call palloc
    test rax, rax
    jz .alloc_fail
    mov [nvm_io_sq], rax
    mov rdi, [nvm_io_cq]          ; zero CQ
    mov rcx, 32
    xor eax, eax
.zio_cq:
    mov [rdi], rax
    add rdi, 8
    dec rcx
    jnz .zio_cq
    mov rdi, [nvm_io_sq]          ; zero SQ
    mov rcx, 128
.zio_sq:
    mov [rdi], rax
    add rdi, 8
    dec rcx
    jnz .zio_sq
    mov qword [nvm_io_head], 0    ; (queues allocated below)
    mov qword [nvm_io_tail], 0
    mov qword [nvm_io_phase], 1
    jmp .skip_creates              ; DEBUG BISECT 2: skip IO setup too
    mov rdi, 256                  ; IOCQ1: 16 x 16 B @4K
    xor r9d, r9d
    mov r10d, (1 << 16) | 15
    mov r11d, 1
    xor r12d, r12d
    mov r13, [nvm_io_cq]
    call nvme_cmd
    test rax, rax
    jnz .io_fail
    mov r8d, 0x01                 ; Create IOSQ1: QSIZE=15, QID=1, CQID=1, PC=1
    xor r9d, r9d
    mov r10d, (1 << 16) | 15
    mov r11d, (1 << 16) | 1
    xor r12d, r12d
    mov r13, [nvm_io_sq]
    call nvme_cmd
    test rax, rax
    jnz .io_fail
    ; doorbell offsets: SQ y = 2*QID, CQ y = 2*QID+1
    mov rax, [nvm_stride]
    shl rax, 1
    add rax, 0x1000
    mov [nvm_iodb_sq], rax
    add rax, [nvm_stride]
    mov [nvm_iodb_cq], rax
.skip_creates:
    ; Identify Controller (CNS=1)
    mov r8d, 0x06
    xor r9d, r9d
    mov r10d, 1
    xor r11d, r11d
    xor r12d, r12d
    mov r13, [nvm_data]
    call nvme_cmd
    test rax, rax
    jnz .id_fail
    lea rsi, [msg_nvme_model]
    call sh_print
    mov rbx, [nvm_data]
    add rbx, 24                    ; model: 40 ASCII
    mov rcx, 40
.model:
    mov al, [rbx]
    call sh_putc
    inc rbx
    dec rcx
    jnz .model
    mov al, 0x0A
    call sh_putc
    mov rbx, [nvm_data]
    mov eax, [rbx + 512]          ; NN (informational; layouts vary —
    mov [nvm_nn], rax             ; NSID 1 probe below is the real test)
    lea rsi, [msg_nvme_ns]
    call sh_print
    mov rax, [nvm_nn]
    call print_dec64
    mov al, 0x0A
    call sh_putc
    ; Identify Namespace (CNS=0, NSID=1)
    mov r8d, 0x06
    mov r9d, 1
    xor r10d, r10d
    xor r11d, r11d
    xor r12d, r12d
    mov r13, [nvm_data]
    call nvme_cmd
    test rax, rax
    jnz .id_fail
    mov rbx, [nvm_data]
    mov rax, [rbx]                 ; NSZE (blocks) via double deref
    mov [nvm_nsize], rax
    push rax
    mov ecx, 16
    call pci_hex
    mov al, ' '
    call sh_putc
    pop rax
    mov rbx, [nvm_data]
    movzx eax, byte [rbx + 26]     ; FLBAS -> format
    and eax, 0xF
    shl eax, 4                     ; *16
    add rax, rbx                   ; + buffer base
    add rax, 128                   ; LBAF entry
    movzx eax, byte [rax + 2]      ; LBADS
    mov ecx, eax
    mov eax, 1
    shl eax, cl                    ; block bytes = 1 << LBADS
    mov [nvm_blksz], rax
    lea rsi, [msg_nvme_nsize]
    call sh_print
    mov rax, [nvm_nsize]
    call print_dec64
    lea rsi, [msg_nvme_blocks]
    call sh_print
    mov rax, [nvm_blksz]
    call print_dec64
    lea rsi, [msg_nvme_bpb]
    call sh_print
    ; Read LBA 0 (NLB=0 -> 1 block) via I/O queue, MBR check
    mov r8d, 0x02
    mov r9d, 1
    xor r10d, r10d
    xor r11d, r11d
    xor r12d, r12d
    mov r13, [nvm_data]
    call nvme_io_cmd
    test rax, rax
    jnz .read_fail
    mov rbx, [nvm_data]
    cmp word [rbx + 510], 0xAA55
    je .mbr_ok
    lea rsi, [msg_nvme_nombr]
    call sh_print
    jmp .done
.mbr_ok:
    lea rsi, [msg_nvme_mbr]
    call sh_print
    jmp .done
.no_nvm:
    lea rsi, [msg_nvme_nonvm]
    call sh_print
    jmp .done
.disable_fail:
    lea rsi, [msg_nvme_disable]
    call sh_print
    jmp .done
.alloc_fail:
    lea rsi, [msg_nvme_alloc]
    call sh_print
    jmp .done
.enable_fail:
    lea rsi, [msg_nvme_enable]
    call sh_print
    jmp .done
.io_fail:
    lea rsi, [msg_nvme_iofail]
    call sh_print
    jmp .done
.id_fail:
    lea rsi, [msg_nvme_idfail]
    call sh_print
    jmp .done
.read_fail:
    lea rsi, [msg_nvme_readfail]
    call sh_print
    jmp .done
.no_ns:
    lea rsi, [msg_nvme_nons]
    call sh_print
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rax = u64 -> decimal via sh_putc
print_dec64:
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

section .rodata
msg_nvme_head: db "NVMe bring-up:", 0x0A, 0
msg_nvme_none: db "No NVMe controller (class 010802) found.", 0x0A, 0
msg_nvme_pio:  db "NVMe BAR0 is PIO?! Giving up.", 0x0A, 0
msg_nvme_nobar: db "NVMe BAR0 empty. Giving up.", 0x0A, 0
msg_nvme_nonvm: db "Controller lacks NVM command set. Giving up.", 0x0A, 0
msg_nvme_vs:   db "NVMe version ", 0
msg_nvme_model: db "Model: ", 0
msg_nvme_ns:   db "Namespaces: ", 0
msg_nvme_nons: db "No namespaces present.", 0x0A, 0
msg_nvme_nsize: db "NS1 size: ", 0
msg_nvme_blocks: db " blocks x ", 0
msg_nvme_bpb:  db " bytes/block.", 0x0A, 0
msg_nvme_mbr:  db "LBA0: MBR signature 55AA OK (bootable).", 0x0A, 0
msg_nvme_nombr: db "LBA0: read OK, no MBR signature.", 0x0A, 0
msg_nvme_disable: db "Disable timed out.", 0x0A, 0
msg_nvme_takeover: db "Already enabled: taking over live queues.", 0x0A, 0
msg_nvme_alloc: db "DMA alloc failed.", 0x0A, 0
msg_nvme_enable: db "Enable timed out (no RDY).", 0x0A, 0
msg_nvme_iofail: db "I/O queue setup failed.", 0x0A, 0
msg_nvme_idfail: db "Identify failed.", 0x0A, 0
msg_nvme_readfail: db "Block read failed.", 0x0A, 0

section .bss
nvm_tail:   resq 1
nvm_head:   resq 1
nvm_phase:  resq 1
nvm_depth:  resq 1
nvm_stride: resq 1
nvm_phys:   resq 1
nvm_base:   resq 1
nvm_sq:     resq 1
nvm_cq:     resq 1
nvm_data:   resq 1
nvm_db0:    resq 1
nvm_db1:    resq 1
nvm_nn:     resq 1
nvm_nsize:  resq 1
nvm_blksz:  resq 1
nvm_io_sq:  resq 1
nvm_io_cq:  resq 1
nvm_io_head: resq 1
nvm_io_tail: resq 1
nvm_io_phase: resq 1
nvm_iodb_sq: resq 1
nvm_iodb_cq: resq 1
