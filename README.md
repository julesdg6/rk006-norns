# rk006-norns

A norns script that replicates all the functionality of the
[Retrokits RK-006 web settings page](https://retrokits.com/rk006/settings/)
directly on your norns device — no computer required.

## Features

| Page | What you can do |
|------|-----------------|
| **ROUTE** | Toggle every cell in the 7 × 7 MIDI routing matrix (6 TRS ports + USB) |
| **PORTS** | Set each TRS port's direction (IN / OUT) and connector type (TRS-A / TRS-B / DIN-5) |
| **FILTER** | Per-port message-type filter — pass or block NOTE, CC, PC, AT, PBend, SysEx, RT, Active Sensing |
| **CLOCK** | Select clock source (internal or any input port), set divider, choose which outputs receive clock |
| **SETTINGS** | Query / push all settings, change MIDI port, set USB mode |

## Installation

```
# from your norns SSH session
cd ~/dust/code
git clone https://github.com/julesdg6/rk006-norns rk006
```

Then select **rk006** from the norns `SELECT` menu.

## Hardware Setup

1. Connect the RK-006 to the norns USB port (USB-A host socket).
2. The script auto-detects the device by USB name (`RK-006` / `Retrokits`).
   If detection fails, go to **SETTINGS → MIDI port** and cycle through ports
   with **E3** until the *Connection* field shows **OK**.

## Controls

| Control | Action |
|---------|--------|
| **E1** | Cycle pages |
| **E2** | Navigate rows / change value (in edit mode) |
| **E3** | Navigate columns / change port / change value |
| **K2** | Back / exit edit mode |
| **K3** | Toggle cell / enter edit mode / execute action |
| **K1 hold** | Alt modifier (reserved for future use) |

## SysEx Protocol

The script communicates with the RK-006 via MIDI System Exclusive messages.

**SysEx header:** `F0 00 21 23 00 06`  
_(Retrokits manufacturer ID `00 21 23`, product `06`)_

Commands follow the Retrokits parameter model (same as RK-002):
`setparam_req (0x08)`, `getparam_req (0x09)`, `getnmbparams_req (0x0A)`, etc.
Data bytes are packed with standard 7-bit SysEx encoding.

Parameter IDs are defined in `lib/rk006_sysex.lua` (`PARAM.*`).  
Cross-reference with the official PDF at
[retrokits.com/rk006/RK006_sysex_manual.pdf](https://retrokits.com/rk006/RK006_sysex_manual.pdf)
and update any values that differ.

## File Structure

```
rk006/
├── rk006.lua           main norns script (UI, keys, encoders)
└── lib/
    └── rk006_sysex.lua SysEx protocol constants and encode/decode helpers
```
