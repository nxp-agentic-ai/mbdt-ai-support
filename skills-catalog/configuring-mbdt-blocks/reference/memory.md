# Memory Read/Write -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the
`DataMemRead` and `DataMemWrite` blocks on any NXP MBDT-targeted Simulink
model. Covers `MaskType = s32k3_memory_read` / `s32k3_memory_write`, the
address/offset/pointer-type parameters, the bounds-check flag, and the
use-cases for direct memory access in generated embedded C. Verified on
S32K3.

`DataMemRead` and `DataMemWrite` are **direct memory access blocks**. They
generate a C pointer dereference (`*(type*)( base + offset )`) into an
arbitrary memory address at runtime. They are not driver blocks -- they have
no dependency on S32CT configuration, no board-init entry, and no ISR. They
are used to access:

- Hardware peripheral registers not exposed via standard MBDT driver blocks.
- Shared-memory regions mapped by the linker.
- Software-defined buffers at known absolute addresses.
- Memory-mapped I/O not covered by the RTD peripheral drivers.

> **Use with caution.** These blocks bypass AUTOSAR/RTD driver abstraction
> and access memory directly. Incorrect addresses or sizes cause hard faults.
> Prefer RTD driver blocks (Adc, Can, Gpt, ...) for peripheral access; use
> DataMemRead/Write only when no driver block exists for the target address.

---

## 1. Peripheral Overview

No config-tool setup is required. These blocks operate entirely at the model
level. The relevant design inputs are:

| Input | Source |
|---|---|
| Base address (`base`) | Linker script, MCU reference manual, or platform header (e.g. `IP_ADC_0`) |
| Byte offset (`offset`) | Register map in MCU reference manual |
| Pointer type (`ptr`) | Width of the target register or memory field |
| Address-range check (`address_check`) | Optional runtime safety guard |

---

## 2. The `DataMemRead` Block -- Complete Behavioral Model

**One `DataMemRead` block = one pointer-dereference read.**
`MaskType = s32k3_memory_read`.

### 2.1 Parameter surface

| Name | Type | Semantics |
|---|---|---|
| `base` | string | Base address expression (C literal, macro, or symbol, e.g. `IP_ADC_0`, `0x400B4000UL`) |
| `offset` | string | Byte offset from base (C literal or expression, e.g. `0x04`, `offsetof(ADC_Type, MCR)`) |
| `ptr` | enum | Pointer element type: `uint8_t`, `uint16_t`, `uint32_t` |
| `address_check` | boolean | When `true`: emit a runtime bounds check; when `false` (default): no check |

**Block output:** the value read from `*(ptr*)( base + offset )`, typed as
the selected `ptr` type.

### 2.2 Parameter details

- **`base`:** A C expression that evaluates to an address at runtime. May be:
  - A macro defined in an MCU header (`IP_ADC_0`, `ADC_BASE_ADDR`).
  - A decimal or hex literal (`0x400B4000UL`).
  - A symbol from a linker-generated object (`__shared_mem_start`).
  The string is emitted verbatim into generated C. Confirm the macro or
  address in the MCU reference manual or platform header files.
- **`offset`:** Byte offset added to `base`. May be `0` for a direct
  base-address access. Common patterns: hex literals (`0x08`), `offsetof`
  expressions.
- **`ptr`:** Selects the C pointer type for the dereference. Must match
  the width of the hardware register or memory field. Mismatched width causes
  incorrect reads (e.g. reading a 32-bit register as `uint8_t` returns only
  the least-significant byte).
- **`address_check`:** When `true`, the generated code checks that the
  computed address falls within a defined safe range before dereferencing.
  Use in safety-sensitive contexts. Default `false`.

### 2.3 Selection ordering

No ordering dependency between parameters; all can be set independently. Set
`ptr` before connecting signals to ensure correct output port type.

---

## 3. The `DataMemWrite` Block -- Complete Behavioral Model

**One `DataMemWrite` block = one pointer-dereference write.**
`MaskType = s32k3_memory_write`.

### 3.1 Parameter surface

Identical to `DataMemRead` except the block has an **input** port instead of
an output port:

| Name | Type | Semantics |
|---|---|---|
| `base` | string | Base address expression (same rules as DataMemRead) |
| `offset` | string | Byte offset from base |
| `ptr` | enum | Pointer element type: `uint8_t`, `uint16_t`, `uint32_t` |
| `address_check` | boolean | Runtime bounds check flag |

**Block input:** value to write to `*(ptr*)( base + offset )`.

Generated C: `*(ptr*)( base + offset ) = input_value;`

---

## 4. Required Block Catalog

| Block name | `MaskType` | Library | Role |
|---|---|---|---|
| `DataMemRead` | `s32k3_memory_read` | `mbd_s32k3_utility_library/Memory Blocks` | Read one value from an absolute memory address |
| `DataMemWrite` | `s32k3_memory_write` | `mbd_s32k3_utility_library/Memory Blocks` | Write one value to an absolute memory address |

Discover exact paths via `get_mbdt_toolbox('s32k3','blocks')`.

---

## 5. Configuration Workflow

### 5.1 Identify the target address

1. Open the MCU reference manual or platform header (`S32K3xx.h`).
2. Locate the peripheral base address (e.g. `ADC_0_BASE = 0x400B4000`).
3. Locate the register offset (e.g. `MCR` at offset `0x00`, `MSR` at
   offset `0x04`).
4. Confirm the register width in bits to select `ptr` (8 / 16 / 32).

### 5.2 Place and configure

```matlab
% DataMemRead example: read ADC_0 Main Configuration Register (32-bit)
set_param(readBlk, 'base',           'IP_ADC_0');   % macro from platform header
set_param(readBlk, 'offset',         '0x00');        % MCR offset
set_param(readBlk, 'ptr',            'uint32_t');
set_param(readBlk, 'address_check',  'off');

% DataMemWrite example: write ADC_0 MCR
set_param(writeBlk, 'base',          'IP_ADC_0');
set_param(writeBlk, 'offset',        '0x00');
set_param(writeBlk, 'ptr',           'uint32_t');
set_param(writeBlk, 'address_check', 'off');
```

### 5.3 No board-init or S32CT configuration required

These blocks need no config-tool steps and no board-init entries. They
generate inline pointer dereferences; initialization is the responsibility
of the relevant peripheral driver.

---

## 6. Initialize Function Pattern

These blocks have no initialization requirement of their own. If used to
access a peripheral that requires RTD initialization (e.g. ADC), that
peripheral's Init call must still be performed via its own board-init entry
or Initialize Function block.

---

## 7. Runtime Data Flow

**Read:**

```
[Model step]
  DataMemRead block executes:
    output = *(ptr*)( base + offset )
```

**Write:**

```
[Model step]
  DataMemWrite block executes:
    *(ptr*)( base + offset ) = input_value
```

Both are synchronous with the model step rate. No job queue, no ISR, no
main-function polling.

---

## 8. Interrupt Dependencies

None. These blocks have no interrupt dependency. If an interrupt is needed
(e.g. to read a peripheral status register on interrupt), place a
`Hardware_Interrupt_Handler` block and put the `DataMemRead` inside the
connected Function-Call Subsystem.

---

## 9. Configuration Correlation Matrix

| Setting | Source | Where it appears |
|---|---|---|
| Base address | MCU reference manual / platform header | `base` string parameter |
| Register offset | MCU reference manual register map | `offset` string parameter |
| Register width | MCU reference manual register description | `ptr` enum (`uint8_t/uint16_t/uint32_t`) |
| Bounds check | Application safety requirement | `address_check` boolean |

---

## 10. Common Usage Patterns

### Pattern 1: Read a 32-bit hardware register

```matlab
% Read SIUL2 GPDO register for port PA0 (offset from base)
set_param(blk, 'base',   'IP_SIUL2');
set_param(blk, 'offset', '0x1300');   % GPDO offset; verify in ref manual
set_param(blk, 'ptr',    'uint32_t');
```

### Pattern 2: Write to a shared-memory structure field

```matlab
% Write uint16 to a linker-defined shared buffer
set_param(blk, 'base',   '__ipcf_shared_buf');  % linker symbol
set_param(blk, 'offset', '0x04');
set_param(blk, 'ptr',    'uint16_t');
```

### Pattern 3: Read with bounds check (safety context)

```matlab
set_param(blk, 'base',           '0x40000000UL');
set_param(blk, 'offset',         '0x00');
set_param(blk, 'ptr',            'uint32_t');
set_param(blk, 'address_check',  'on');
```

---

## 11. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| Hard fault at runtime | Incorrect base address or offset | Verify address against MCU reference manual; check alignment for `ptr` width |
| Wrong value read | `ptr` width mismatch | Confirm register width in reference manual; adjust `ptr` to match |
| Build error: undefined symbol for `base` | Macro or symbol not in scope | Add the appropriate `#include` in the model's custom code or verify the platform header is on the compiler include path |
| Output type mismatch in model | `ptr` set after signal connection | Set `ptr` before connecting the output port |
| Address-check assertion at runtime | Address outside safe range | Verify `base` + `offset` falls within the MCU's valid address map |

---

## 12. Board-Specific Considerations

- **S32K3:** Platform header `S32K3xx.h` defines base-address macros
  (e.g. `IP_ADC_0`, `IP_SIUL2`, `IP_LPUART_0`). Offsets are in the S32K3
  Reference Manual. `MaskType` = `s32k3_memory_read` / `s32k3_memory_write`.

---

## 13. Guardrails (Memory blocks-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only Memory blocks-specific rules follow.

- **Verify every address against the MCU reference manual.** Wrong addresses
  cause hard faults that are difficult to debug; never guess a base address.
- **Match `ptr` to the register width.** Reading a 32-bit register with
  `uint8_t` is legal C but returns only one byte, which is almost always wrong.
- **Align `base + offset` to the `ptr` width** (4 bytes for `uint32_t`, 2 for
  `uint16_t`). Unaligned accesses hard-fault on Cortex-M without
  unaligned-access support.
- **Prefer RTD peripheral blocks (Adc, Can, Dio, ...) when available.** These
  blocks bypass the RTD driver abstraction; use DataMemRead/Write only for
  registers or memory regions without a dedicated driver block.
- **Do not add S32CT or board-init entries for these blocks.** They generate
  inline C and need no RTD-level configuration.
