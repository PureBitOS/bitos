ENTRY(start)

SECTIONS {
    . = 1M;

    .boot :
    {
        *(.multiboot_header)
    }

    .text :
    {
        *(.text)
    }

    .rodata :
    {
        *(.rodata)
    }

    /* page tables need real 4K alignment */
    . = ALIGN(4096);
    .bss :
    {
        *(COMMON)
        *(.bss)
    }
}
