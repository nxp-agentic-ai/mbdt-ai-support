# Register Read/Write -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the `Read_Register`
and `Write_Register` blocks on any NXP MBDT-targeted Simulink model. Covers
`MaskType = s32k3_register_read` / `s32k3_register_write`, the `periph` /
`reg` enums, the `regSize` / `addr` / `descript` parameters, and the
relationship to the MCU register map. Verified on S32K3.

`Read_Register` and `Write_Register` are **register-level access blocks**.
Unlike the generic `DataMemRead` / `DataMemWrite` blocks (which accept
arbitrary base + offset strings), these blocks expose a **peripheral dropdown
(`periph`)** and a **register dropdown (`reg`)** populated from the MCU's
address map embedded in the MBDT toolbox. The user selects the peripheral
first, then picks the register from a list -- avoiding the need to look up
base addresses manually.

They generate the same kind of pointer dereference as DataMemRead/Write but
provide guided, MCU-aware register selection.

---

## 1. Peripheral Overview

No config-tool (S32CT / EB tresos) setup is required. These blocks operate
entirely at the model level. Design inputs:

| Input | Source |
|---|---|
| Peripheral (`periph`) | Select from dropdown; entries match MCU address-map identifiers |
| Register (`reg`) | Select from dropdown after choosing peripheral; populated from MCU register map |
| Register size (`regSize`) | Auto-populated or user-confirmed; matches register width |
| Address (`addr`) | Auto-populated display field; shows computed absolute address |

---

## 2. The `Read_Register` Block -- Complete Behavioral Model

**One `Read_Register` block = one register read.**
`MaskType = s32k3_register_read`.

### 2.1 Parameter surface

| Name | Type | Semantics |
|---|---|---|
| `periph` | enum | Peripheral identifier (e.g. `ADC_0`, `LPUART_0`, `SIUL2`); selects the peripheral's base address |
| `reg` | enum | Register name within the peripheral; sentinel = `"No registers configured"` (appears until peripheral is selected) |
| `descript` | string | Auto-filled register description text; read-only informational field |
| `addr` | string | Auto-filled absolute address of the selected register (display only) |
| `regSize` | string | Register bit-width; auto-filled or editable (e.g. `32`, `16`, `8`) |
| `text` | string | System-managed cache -- **never set** |

**Block output:** the value read from the selected register, typed according
to `regSize`.

### 2.2 The `periph` enum

Values read live from S32K3 RTD (R2026a) -- over 150 entries. Examples:

`ADC_0 | ADC_1 | CAN_0 | CAN_1 | EDMA | EMIOS_0 | EMIOS_1 | EMIOS_2 |
FLASH | LPSPI_0 | LPSPI_1 | LPUART_0 | LPUART_1 | MC_CGM | MC_ME |
PIT_0 | SIUL2 | STM_0 | STM_1 | TRGMUX | ...`

**Always read `periph.Enum` live** via
`get_param(<blk>,'DialogParameters').periph.Enum`. The complete list is
MCU-specific and changes across device variants.

### 2.3 The `reg` enum

After `periph` is set, the `reg` dropdown is populated with the registers of
that peripheral. The sentinel `"No registers configured"` appears until a
valid peripheral is selected. **Read live after setting `periph`; never
assume register names.**

### 2.4 Selection ordering

**Critical:** `periph` must be set before `reg`. Selecting `reg` before
`periph` leaves it on a stale/empty slot.

1. `periph` first.
2. `reg` next.

`descript`, `addr`, and `regSize` are auto-filled by the MBDT toolbox after
`reg` is set.

---

## 3. The `Write_Register` Block -- Complete Behavioral Model

**One `Write_Register` block = one register write.**
`MaskType = s32k3_register_write`.

### 3.1 Parameter surface

Identical to `Read_Register` except the block has an **input** port instead
of an output port:

| Name | Type | Semantics |
|---|---|---|
| `periph` | enum | Peripheral identifier (same enum as Read_Register) |
| `reg` | enum | Register name; sentinel = `"No registers configured"` |
| `descript` | string | Auto-filled description |
| `addr` | string | Auto-filled absolute address |
| `regSize` | string | Register bit-width |
| `text` | string | System-managed -- **never set** |

**Block input:** value to write to the selected register.

Generated C: `*(volatile type*)( periph_base + reg_offset ) = input_value;`

---

## 4. Required Block Catalog

| Block name | `MaskType` | Library | Role |
|---|---|---|---|
| `Read_Register` | `s32k3_register_read` | `mbd_s32k3_utility_library/Register Blocks` | Read one MCU register by peripheral + name |
| `Write_Register` | `s32k3_register_write` | `mbd_s32k3_utility_library/Register Blocks` | Write one MCU register by peripheral + name |

Discover exact paths via `get_mbdt_toolbox('s32k3','blocks')`.

---

## 5. Configuration Workflow

### 5.1 No config-tool steps required

These blocks derive their register information from the MBDT toolbox's
embedded MCU address map. No S32CT / EB tresos configuration is needed.

### 5.2 Place and configure

```matlab
% Read_Register example: read PIT_0 Module Control Register
set_param(readBlk, 'periph', 'PIT_0');   % set peripheral first
set_param(readBlk, 'reg',    'MCR');     % set register after -- read live

% Write_Register example: write SIUL2 GPIO Pad Data Output Register
set_param(writeBlk, 'periph', 'SIUL2');
set_param(writeBlk, 'reg',    'GPDO0');  % read live
```

**Always read the live `reg` enum after setting `periph`.** Register names
are not stable across toolbox versions.

```matlab
% Discover available registers after setting periph
dp = get_param(blk,'DialogParameters');
disp(dp.reg.Enum)
```

### 5.3 Verify auto-filled fields

After setting `reg`, confirm `addr` and `regSize` are populated correctly
via `get_param(blk,'addr')` and `get_param(blk,'regSize')`.

---

## 6. Initialize Function Pattern

No initialization required for these blocks. The peripheral they target may
require its own Init call via board-init or Initialize Function (e.g. if
writing to an ADC control register, ADC must be initialized first).

---

## 7. Runtime Data Flow

**Read:**

```
[Model step]
  Read_Register block executes:
    output = *(volatile type*)( periph_base_addr + reg_offset )
```

**Write:**

```
[Model step]
  Write_Register block executes:
    *(volatile type*)( periph_base_addr + reg_offset ) = input_value
```

Both are synchronous with the model step. No job queue, no ISR, no polling.

---

## 8. Interrupt Dependencies

None. These blocks have no interrupt dependency. If register access is needed
inside an ISR context, place the block inside a Function-Call Subsystem
triggered by a `Hardware_Interrupt_Handler` block.

---

## 9. Configuration Correlation Matrix

| Setting | Source | Where it appears |
|---|---|---|
| Peripheral base address | Toolbox MCU address map | Auto-filled `addr` (display only) |
| Register offset | Toolbox MCU address map | Auto-filled `addr` (computed) |
| Register name | Toolbox MCU register database | `reg` enum |
| Register width | Toolbox MCU register database | `regSize` field |
| Description | Toolbox MCU register database | `descript` field |

---

## 10. Common Usage Patterns

### Pattern 1: Read a timer count register

```matlab
% Read STM_0 Counter register
set_param(blk, 'periph', 'STM_0');
set_param(blk, 'reg',    'CNT');  % read live
% Output: current STM counter value (uint32)
```

### Pattern 2: Write a DMA mux register

```matlab
% Route DMA channel via DMAMUX_0
set_param(blk, 'periph', 'DMAMUX_0');
set_param(blk, 'reg',    'CHCFG0');  % read live
% Input: mux configuration value
```

### Pattern 3: Verify peripheral status before action

```matlab
% Read CAN_0 Module Configuration Register to check NOTRDY bit
set_param(blk, 'periph', 'CAN_0');
set_param(blk, 'reg',    'MCR');  % read live
% Output -> check bit field in downstream logic
```

---

## 11. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `reg` = `"No registers configured"` | `periph` not set or set to invalid entry | Set `periph` first; read live `periph.Enum`; select a valid entry |
| `addr` field empty after setting `reg` | `reg` set before `periph` or stale enum | Set `periph`, then `reg`, in that order; refresh via re-set |
| Build error: undefined symbol | Peripheral macro not in platform header scope | Confirm platform header is included; check MCU variant matches block |
| Hard fault at runtime | Peripheral not clocked / powered | Ensure the peripheral's clock gate is enabled; initialize peripheral via RTD driver if required |
| Wrong value read/written | Register selected is not the intended one | Verify register name in MCU reference manual; compare `addr` against manual |

---

## 12. Board-Specific Considerations

- **S32K3:** `periph` enum contains 150+ entries covering all S32K3 peripheral
  blocks (ADC, CAN, CMU, CRC, DMA, EMIOS, FLASH, GPT, ICU, LPCMP, LPI2C,
  LPSPI, LPUART, MC_CGM, PIT, SIUL2, STM, SWT, TRGMUX, ...). `MaskType` =
  `s32k3_register_read` / `s32k3_register_write`.

---

## 13. Guardrails (Register blocks-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only Register blocks-specific rules follow.

- **Set `periph` before `reg`.** The `reg` enum depends on `periph`; setting
  `reg` first leaves it on a stale slot.
- **Read register names from the live `reg` enum after setting `periph`.**
  They are toolbox-version-specific.
- **Never set `addr`.** It is auto-filled, and the toolbox callback overwrites
  a manual value.
- **Prefer RTD driver blocks for standard peripheral access.** Use
  Read_Register / Write_Register only for registers no MBDT driver block
  exposes (non-standard bit fields, diagnostic status reads, one-time
  configuration not covered by S32CT).
- **Expect `volatile` accesses in generated code.** The compiler never
  optimizes them away, which is correct for hardware registers.
- **Do not add config-tool or board-init entries for these blocks.**
