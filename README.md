# BitOS

A minimal x64 operating system written primarily in assembly.

**Mascot:** The Bit — a floating, slightly smug 0/1 that occasionally glitches into a face just to judge you.

**License:** Don't Be A Dick Public License (DBAD)

This is the very beginning.  
Current status (v0.2): boots via GRUB, enters 64-bit long mode (own paging + GDT + stack), prints a status screen, then halts.

## Building

```bash
make          # builds bitos.iso
make run      # boots it in QEMU
```

On Windows: use WSL2 + Debian (`sudo apt install -y nasm make grub-pc-bin xorriso qemu-system-x86 binutils`), then `make` / `make run` from the repo dir. Native `nasm` + `qemu-system-x86_64` work too, but linking and ISO creation need WSL. See `docs.html` → “Building on Windows”.

## Roadmap (high level)

1. ✅ Long mode + better kernel foundation (done — v0.2)
2. Keyboard + basic shell (next)
3. Simple package format + free GitHub-based package repo
4. Graphics / early windowing
5. Desktop environment (much later)

## Hosting

Everything (code, ISOs, packages) is hosted for free on this GitHub account.  
No domain and no paid hosting required.
