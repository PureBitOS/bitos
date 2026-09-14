section .multiboot_header
header_start:
    dd 0xe85250d6                ; Multiboot2 magic
    dd 0                         ; architecture 0 = i386
    dd header_end - header_start ; header length
    dd 0x100000000 - (0xe85250d6 + 0 + (header_end - header_start)) ; checksum
    ; framebuffer request tag (type 5, OPTIONAL: boot in VGA text if
    ; the firmware/GRUB cannot provide 1024x768x32). On UEFI this is
    ; GOP (mirrored to HDMI); on BIOS GRUB tries VBE.
    ; NOTE: first tag follows the 16-byte fixed part immediately; every
    ; tag's SIZE is padded to a multiple of 8 (GRUB steps ALIGN_UP).
    dw 5                         ; type = framebuffer
    dw 0                         ; flags = optional
    dd 20                        ; size (content)
    dd 1024                      ; width
    dd 768                       ; height
    dd 32                        ; depth
    align 8                      ; pad tag to 24 bytes (GRUB lands +24)
    ; end tag
    dw 0
    dw 0
    dd 8
header_end:
