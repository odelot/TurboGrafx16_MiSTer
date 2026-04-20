# TurboGrafx16_MiSTer — RetroAchievements Fork

This is a fork of the official [TurboGrafx-16 / PC Engine core for MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) with modifications to support **RetroAchievements** on MiSTer FPGA.

> **Status:** Experimental / Proof of Concept — works together with the [modified Main_MiSTer binary](https://github.com/odelot/Main_MiSTer).

## What's Different from the Original

The upstream TurboGrafx-16 core is an FPGA PC Engine / TurboGrafx-16 implementation supporting HuCard, CD-ROM, Super CD-ROM, Arcade Card, and SuperGrafx modes. This fork adds one new module and modifies several existing files so the ARM side (Main_MiSTer) can read emulated RAM for achievement evaluation. **No emulation logic was changed** — the core plays games identically to the original.

### Added Files

| File | Purpose |
|------|--------|
| `rtl/ra_ram_mirror_tgfx16.sv` | Option C selective-address mirror — reads Work RAM from BRAM Port B, CD RAM and Super CD RAM from DDRAM, writes cached values back to DDRAM for the ARM CPU |

### Modified Files

| File | Change |
|------|--------|
| `TurboGrafx16.sv` | Instantiates `ra_ram_mirror_tgfx16`, declares RA signal wiring, passes `cd_en` and `use_sdr` flags for CD mode detection |
| `rtl/ddram.sv` | Adds an RA arbiter channel — secondary priority behind the core, one transaction per idle cycle |
| `rtl/pce_top.vhd` | Exposes Work RAM via BRAM Port B (`RA_RAM_A` address input, `RA_RAM_DO` data output) |
| `files.qip` | Adds `ra_ram_mirror_tgfx16.sv` to the Quartus project |

### How the RAM Mirror Works

The TurboGrafx-16 has a relatively small CPU Work RAM (8 KB) but CD-ROM and Super CD-ROM modes add significantly more. The core uses the **selective address protocol (Option C)**, the same approach used for SNES, Genesis, and other cores:

1. The **ARM binary** writes a list of RAM addresses it needs to DDRAM offset `0x40000` (up to 4096 addresses per frame).
2. On each **VBlank**, the FPGA module dispatches each address to the correct memory backend:
   - **Work RAM** (0x000000–0x001FFF): Read from BRAM Port B of `pce_top` — 1-cycle synchronous read, direct byte access.
   - **CD RAM** (0x002000–0x011FFF): Read from DDRAM at offset 0x0600000 — 64-bit word access with byte extraction.
   - **Super CD RAM** (0x012000–0x041FFF): Read from DDRAM at offset 0x0610000 — same 64-bit word access with byte extraction.
3. Values are packed into 8-byte chunks and written to DDRAM offset `0x48000`, with a response counter so the ARM knows the data is ready.
4. The ARM binary reads the values and feeds them to the rcheevos achievement engine.

**Memory regions exposed:**

| Region | Address Range | Size | Source | Description |
|--------|-------------|------|--------|-------------|
| Work RAM | $000000–$001FFF | 8 KB | BRAM Port B | CPU Work RAM (always available) |
| CD RAM | $002000–$011FFF | 64 KB | DDRAM | CD-ROM system RAM (CD/SCD titles) |
| Super CD RAM | $012000–$041FFF | 192 KB | DDRAM | Super CD-ROM extra RAM (SCD titles) |

**Total exposed: up to 264 KB** (8 KB for HuCard-only games, 264 KB for Super CD-ROM titles)

### Key Differences from Other Cores

| Aspect | PC Engine / TG16 | Genesis |
|--------|-----------------|--------|
| Console ID | 8 (HuCard) / 76 (CD-ROM) | 1 |
| RAM size | 8–264 KB | 64 KB |
| Work RAM access | BRAM Port B (1-cycle) | BRAM (bit-13 inversion) |
| CD/SCD access | DDRAM word-aligned + byte extract | N/A |
| DDRAM integration | Arbiter in `ddram.sv` (secondary priority) | Separate `ddram_arb_md.sv` |
| Game formats | HuCard ROM + CD-ROM (CUE/BIN, CHD, CCD) | ROM cartridge only |
| Clock | clk_sys ~21.477 MHz | clk_sys |

### DDRAM Layout

```
0x00000   Header:   magic ("RACH") + flags (busy bit) + frame counter
0x00010   Debug1:   FPGA version + dispatch/ok/timeout counters
0x00018   Debug2:   first_addr + wram/cdram/max_timeout counters
0x40000   AddrReq:  ARM → FPGA address request list (count + request_id + addresses)
0x48000   ValResp:  FPGA → ARM value response cache (response_id + response_frame + values)
```

All data flows through shared DDRAM at ARM physical address **0x3D000000**.

### HuCard and CD-ROM Support

The same handler supports both HuCard cartridge games and CD-ROM/Super CD-ROM disc games:
- **HuCard**: Console ID 8 (`RC_CONSOLE_PC_ENGINE`). ROM is hashed as MD5, skipping an optional 512-byte copier header.
- **CD-ROM**: Console ID 76 (`RC_CONSOLE_PC_ENGINE_CD`). Disc is hashed via `rc_hash_generate_from_file()` from the rcheevos library, which handles `.cue+.bin`, `.chd`, `.ccd`, `.iso`, and `.img` formats.

The FPGA mirror automatically uses CD/SCD RAM regions when a CD game is loaded (controlled by the `cd_en` flag wired from the core).

### Architecture Diagram

```
┌───────────────────────────────────────┐
│       TG16 / PCE FPGA Core            │
│                                       │
│  Work RAM (8KB)   in BRAM             │
│  CD RAM (64KB)    in DDRAM            │
│  SCD RAM (192KB)  in DDRAM            │
└─────────────┬─────────────────────────┘
              │  VBlank
              ▼
┌───────────────────────────────────────┐
│     ra_ram_mirror_tgfx16.sv          │
│  Work RAM: BRAM Port B (1-cycle)      │
│  CD/SCD RAM: DDRAM word + byte sel    │
│  Arbiter: secondary priority in ddram │
│  Writes header + values to DDRAM      │
└─────────────┬─────────────────────────┘
              │  DDRAM @ 0x3D000000
              ▼
┌───────────────────────────────────────┐
│     Main_MiSTer (ARM binary)          │
│  mmap /dev/mem → reads mirror         │
│  Writes address list → reads values   │
│  rcheevos hashes ROM/disc + evaluates │
└───────────────────────────────────────┘
```

## How to Try It

1. Download the latest TurboGrafx-16 core binary (`TurboGrafx16_*.rbf`) from the [Releases](https://github.com/odelot/TurboGrafx16_MiSTer/releases) page.
2. Copy the `.rbf` file to `/media/fat/_Console/` on your MiSTer SD card (replacing or alongside the stock TurboGrafx-16 core).
3. You will also need the **modified Main_MiSTer binary** from [odelot/Main_MiSTer](https://github.com/odelot/Main_MiSTer) — follow the setup instructions there to configure your RetroAchievements credentials.
4. Reboot your MiSTer, load the TurboGrafx-16 core, and open a game that has achievements on [retroachievements.org](https://retroachievements.org/).

## Building from Source

Open the project in Quartus Prime (use the same version as the upstream MiSTer TurboGrafx-16 core) and compile. The `ra_ram_mirror_tgfx16.sv` file is already included in `files.qip`.

## Links

- Original TurboGrafx-16 core: [MiSTer-devel/TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer)
- Modified Main binary (required): [odelot/Main_MiSTer](https://github.com/odelot/Main_MiSTer)
- RetroAchievements: [retroachievements.org](https://retroachievements.org/)

---

# Original TurboGrafx-16 Core Documentation

*Everything below is from the upstream [TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) README and applies unchanged to this fork.*

## [TurboGrafx 16 / PC Engine](https://en.wikipedia.org/wiki/TurboGrafx-16) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki) 

### This is the port of Gregory Estrade's [FPGAPCE](https://github.com/Torlus/FPGAPCE)

Port to MiSTer, Arcade card, DDR3, mappers and other tweaks [Sorgelig](https://github.com/sorgelig)

Tweaks and CD Support added by [srg320](https://github.com/srg320)

Additional bug fixes by [greyrogue](https://github.com/greyrogue)

Palettes & audio filters by [Kitrinx](https://github.com/Kitrinx)

Further refinements and maintanance by [dshadoff](https://github.com/dshadoff)

## Features
 * Completely rewritten CPU and VDC for cycle accuracy
 * Uses DDR3 and SDRAM for cartridge's ROM (SDRAM is recommended for accuracy)
 * Overall Machine Support:
   - CD-ROM / Super CD-ROM
   - CD+G support
   - Arcade Card
   - SuperGrafx mode
   - Backup Memory Saves
 * Controllers:
   - Turbotap(multiple joysticks)
   - 2-button, 2-button 'turbo', and 6-button joystick support
   - Mouse
   - Pachinko controller
   - XE-1AP analog controller
 * Additional functionality:
   - Street Fighter II and Populous mappers
   - Memory Base 128 storage unit
   - Cheat engine
   - CHD Support

## Installation:
Copy the *.rbf file at the root of the SD card. Copy roms (*PCE,*BIN) to **TGFX16** folder. You may rename ROM of your favorite game to **boot.rom** - it will be automatically loaded upon core loading.
Use SGX file extension for SuperGrafx games.

## SDRAM
This core may work without SDRAM (using on-board DDR3), but it may have different kinds of issues/glitches due to high latency of DDR3 memory. Thus SDRAM module is highly recommended for maximum accuracy.

### Notes:
* Both headerless ROMs and ROMs with header (512b) are supported and automatically distinguished by file size.

## Cheat engine
Standard cheats location is supported for HuCard games. For CD-ROM game all cheats must be zipped into a single zip file and placed inside game's CD-ROM folder.

## Reset
Hold down Run button then press Select. Some games require to keep both buttons pressed longer to reset. The PC Engine/Turbografx-16 did not have a hardware reset button, and instead relies on this button combination. With this method, in-game options will remain if you have changed them, whereas the MiSTer OSD reset will revert them.
(Note: This is a soft-reset method, and is suppressed in a small number of games)

## CD-ROM games
CD-ROM images must be in BIN/CUE or CHD format, and must be located in the **TGFX16-CD** folder. Each CD-ROM image must have its own folder.
**cd_bios.rom** must be placed in the same TGFX16-CD folder as the images mentioned above. **Japanese Super CD-ROM v3.00 is recomended for maximum compatibility**. 
Additionally you can use a different bios for specific games (for example from Games Express) by placing cd_bios.rom inside the game image's folder.

**Do not zip CD-ROM images! It won't work correctly.**

**Attention about US BIOS:** MiSTer requires original dump of US BIOS to work properly. It needs to be of 262144 bytes.
If you can read copyright string at the end of US BIOS file, then it's not correct dump! It's already pre-swapped for emulators.
While it will work on MiSTer, some CD games will refuse to start. **Correct US BIOS file is when copyright string is not readable.**

## CD+G (CD Graphic) Support
CD+G support works only for games in CloneCD format (which can also be ripped by freeware "CD Manipulator"). This format creates cue, img, and sub files - the subcode "sub" file contains
the CD+G subcode information. This must exist with the same name as the "img" (audio portion) of the file, together in the same folder. The CD+G player is available as the "GRAPHICS"
button in the CD player on the system card (versions 2.0, 2.1, or 3.0).  CHD is not supported for CD+G.

## Joystick
Both Turbotap and 6-button joysticks are supported.
For 2-button 'turbo' joypad (sync'd as in original system), turbo fire is provided by alternate buttons : A, B (normal), X, Y (turbo 1 level), and L, R (turbo 2 level)
 * Games Supporting 6-button:
   - Street Fighter II
   - Advanced Variable Geo
   - Battlefield '94 in Tokyo Dome
   - Emerald Dragon
   - Fire Pro Jyoshi - Dome Choujyo Taisen
   - Flash Hiders
   - Garou Densetsu II - Aratanaru Tatakai
   - Garou Densetsu Special
   - Kakutou Haou Densetsu Algunos
   - Linda Cube
   - Mahjong Sword Princess Quest Gaiden
   - Martial Champions
   - Princess Maker 2
   - Ryuuko no Ken
   - Sotsugyou II - Neo Generation
   - Super Real Mahjong P II - P III Custom
   - Super Real Mahjong P V Custom
   - Tengai Makyo - Kabuki Itouryodan
   - World Heroes 2
   - Ys IV
 * XE-1AP analog joystick is supported for the 4 games which are supported:
   - After Burner II
   - Forgotten Worlds
   - Operation Wolf
   - Outrun

Do not enable the above features for games not supporting it, otherwise game will work incorrectly (for example, 6-button is only supported on a very small list of games).

## Mouse
Mouse is supported.  Supported games:
 * 1552 Tenka Tairan
 * A. III - Takin' the A Train
 * Atlas Renaissance Voyage
 * Brandish
 * Dennou Tenshi Digital Angel
 * Doukyuusei
 * Eikan ha Kimini - Koukou Yakyuu Zenkoku Taikai
 * Hatsukoi Monogatari
 * Jantei Monogatari III - Saver Angels
 * Lemmings
 * Metal Angel
 * Nemurenumori no Chiisana Ohanashi
 * Power Golf 2 Golfer
 * Princess Maker 2
 * Tokimeki Memorial
 * Vasteel 2

Do not enable this feature for games not supporting it, otherwise game will work incorrectly.

## Pachinko
Pachinko controller is supported through either paddle or analog joystick Y axis.

## Palettes
The 'Original' palette is based on reverse engineering work of the VDP by [furrtek](https://github.com/furrtek). An RGB to YUV lookup table was discovered that translates the colors to their intended values with the composite output of the console. Further work was done by [ArtemioUrbina](https://github.com/ArtemioUrbina) to verify the color output. [Kitrinx](https://github.com/Kitrinx) created a tool to generate the resulting [palette](https://github.com/Kitrinx/TG16_Palette).

## Memory Base 128 / Save-kun
This was an external save-game mechanism used by a small number of games, late in the PC Engine's life, particularly for complex simulations like the KOEI games.
Enabling this should not interfere with normal operation of games, but will only provide additional storage on a small number of games:
 * A. III - Takin' the A Train
 * Atlas Renaissance Voyage
 * Bishoujo Senshi Sailor Moon Collection
 * Brandish
 * Eikan ha Kimini - Koukou Yakyuu Zenkoku Taikai
 * Emerald Dragon
 * Fire Pro Jyoshi - Dome Choujyo Taisen
 * Ganchouhishi - Aoki Ookami to Shiroki Mejika
 * Linda Cube
 * Magicoal
 * Mahjong Sword Princess Quest Gaiden
 * Nobunaga no Yabou - Bushou Fuuunroku
 * Nobunaga no Yabou Zenkokuban
 * Popful Mail
 * Princess Maker 2
 * Private Eye Dol
 * Sankokushi III
 * Shin Megami Tensei
 * Super Mahjong Taikai
 * Super Real Mahjong P II - P III Custom
 * Super Real Mahjong P V Custom
 * Tadaima Yuusha Boshuuchuu
 * Vasteel 2

## Download precompiled binaries
Go to [releases](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer/tree/master/releases) folder. 
