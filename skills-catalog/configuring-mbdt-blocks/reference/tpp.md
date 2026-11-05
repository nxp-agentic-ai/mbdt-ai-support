# TPP Config -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the TPP (Three
Phase Power / Gate Driver) peripheral on NXP MBDT-targeted Simulink
models. This document describes the behavior of the `TPP Config` block
(`MaskType = s32k3_tpp_config`), the initialization pattern, and the
external-config-tool dependencies. Verified on S32K3 only -- this block
lives in `mbd_s32k3_utility_library/TPP Blocks` and is S32K3-specific.

> **Tip -- start from a shipped example.** Open a shipped TPP example via
> [`opening-mbdt-example`](../../opening-mbdt-example/SKILL.md).
> Never carry example names from memory -- discover at runtime via
> `get_mbdt_toolbox('s32k3','examples')`.

---

## 1. Peripheral Overview

The TPP (Three Phase Power driver, also referred to as a gate driver) is
an external SPI-controlled gate driver IC that drives the high/low-side
switches of a three-phase inverter. The `TPP Config` block configures the
TPP driver instance: dead time, interrupt enables, and DIO/SPI resource
assignments.

Unlike most MBDT peripheral blocks, `TPP Config` has **no `api_func`
selector** -- it is a configuration-only block that emits driver
initialization parameters. There is typically one `TPP Config` block per
TPP instance in the Initialize Function.

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT project: SPI channel/sequence + DIO channels (EN1, EN2, RST, CS) declared | External to the model | External config tool |
| 2 | Board-init entry for TPP (via SPI + DIO) | `mbdt_board_init.c` | `editing-mbdt-board-init` skill |
| 3 | `TPP Config` block in Initialize Function | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1) -> SPI/DIO resource enums hold sentinels.
- Missing (2) -> TPP driver not initialized at startup.
- Missing (3) -> TPP IC not configured; gate drive signals may be
  incorrect or absent.

---

## 2. The `TPP Config` Block -- Complete Behavioral Model

**`TPP Config` is a configuration block, not a function-call block.**
It has no `api_func` parameter. All parameters are set once (typically in
the Initialize Function) to configure the TPP driver instance.

### 2.1 Parameter surface

| Name | Type | Semantics |
|---|---|---|
| `inst` | enum (`0`, `1`, `2`) | TPP instance index (hardware-assigned, 0-based) |
| `desat_mode` | boolean | Enable desaturation detection mode |
| `full_mode` | boolean | Enable full SPI mode (vs. reduced/simple mode) |
| `locks_mode` | boolean | Enable locks mode |
| `dead_time` | string | Dead time value (in ns or device-specific units; preserve format) |
| `overtemp_int` | boolean | Enable over-temperature interrupt |
| `desat_int` | boolean | Enable desaturation interrupt |
| `vls_undervol_int` | boolean | Enable VLS under-voltage interrupt |
| `overcurr_int` | boolean | Enable over-current interrupt |
| `phase_err_int` | boolean | Enable phase error interrupt |
| `frame_err_int` | boolean | Enable SPI frame error interrupt |
| `write_err_int` | boolean | Enable SPI write error interrupt |
| `rst_ev_int` | boolean | Enable reset event interrupt |
| `en1_chn` | enum | DIO channel for EN1 (enable 1) signal -- config-tool owned |
| `en2_chn` | enum | DIO channel for EN2 (enable 2) signal -- config-tool owned |
| `rst_chn` | enum | DIO channel for RST (reset) signal -- config-tool owned |
| `cs_chn` | enum | DIO channel for CS (chip select) signal -- config-tool owned |
| `spi_chn` | enum | SPI channel -- config-tool owned |
| `spi_seq` | enum | SPI sequence -- config-tool owned |

### 2.2 No `api_func` -- configuration-only block

`TPP Config` does not have an `api_func` parameter. All parameters are
always relevant; the block emits a single driver initialization call.

### 2.3 The `inst` enum

Fixed entries `0`, `1`, `2` (hardware TPP instance indices). No sentinel
pattern -- pick the numeric instance index that matches the physical TPP IC.

### 2.4 Resource enums -- DIO and SPI

`en1_chn`, `en2_chn`, `rst_chn`, `cs_chn` are DIO channels; `spi_chn`
and `spi_seq` are SPI resources. All are populated by the config tool.
Sentinels:
- `"No Dio channels configured"` -> declare the DIO channel in S32CT
  (Peripherals -> Dio / Pins)
- `"No Spi channels configured"` / `"No Spi sequences configured"` ->
  declare SPI channel/sequence in S32CT (Peripherals -> Spi)

### 2.5 Boolean parameters

All `*_int` parameters and mode flags (`desat_mode`, `full_mode`,
`locks_mode`) are `boolean`. Set with `'on'` or `'off'`.

### 2.6 `dead_time` string parameter

Free-form string. Preserve the format exactly as provided (typically a
numeric value with or without units). Do not coerce or reformat.

### 2.7 Selection ordering

No `api_func` to set first. Set in this order:
1. `inst`
2. DIO resource enums (`en1_chn`, `en2_chn`, `rst_chn`, `cs_chn`)
3. SPI resource enums (`spi_chn`, `spi_seq`)
4. Mode booleans (`desat_mode`, `full_mode`, `locks_mode`)
5. `dead_time` string
6. Interrupt enable booleans (`overtemp_int`, `desat_int`, etc.)

One `set_param` per parameter.

---

## 3. Required Block Catalog

| Block name | Library path | Role |
|---|---|---|
| `TPP Config` | `mbd_s32k3_utility_library/TPP Blocks` | Configures one TPP driver instance |
| `Hardware_Interrupt_Handler` | `mbd_s32k3_isr_library` | Routes TPP fault interrupts (if any `*_int` enabled) |

---

## 4. Configuration Workflow

### 4.1 Pins (S32CT)
Route EN1, EN2, RST, CS GPIO pins and SPI clock/data/CS pins for the TPP
IC. Pin assignments are board-specific -- never invent them. Read from the
`.mex` or shipped example.

### 4.2 Peripherals -> Dio (S32CT)
Declare DIO channels for EN1, EN2, RST, CS. The exact channel names
assigned here appear in `en1_chn`, `en2_chn`, `rst_chn`, `cs_chn` enums.

### 4.3 Peripherals -> Spi (S32CT)
Declare the SPI channel and sequence used to communicate with the TPP IC.
The exact names appear in `spi_chn` and `spi_seq` enums.

### 4.4 Platform -> Interrupt Controller (S32CT)
If any `*_int` boolean is `'on'`, enable the corresponding TPP fault IRQ.

### 4.5 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../editing-mbdt-board-init/SKILL.md):

```
Component : Tpp
Priority  : (verify live -- must be higher/later than Spi and Dio)
Enabled   : true
Header    : #include "Tpp.h"
Code      : Tpp_Init(&Tpp_Config);
```

SPI and DIO must be initialized before the TPP driver. Enforce by
assigning TPP a numerically higher Priority than the Spi and Dio
board-init entries. Priority and exact config symbol must be verified
live via `get_mbdt_board_init(modelName)` -- do not carry them from
memory.

#### Expected generated C files

A correctly-configured TPP peripheral must cause the config tool to emit
these generated units. If any are missing, the build fails at
compile/link time -- authoritative evidence of a config-tool-side
problem, NOT a model problem. Confirm the exact file names against the
generated `{model}_Config/` folder -- do not cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `Tpp_Cfg.h` / `Tpp_PBcfg.*` | Peripherals -> Tpp (always) | TPP driver |

**If `fatal error: Tpp_Cfg.h` No such file appears at build time:** the
TPP flavor was not emitted. Do NOT touch the model. Run
`nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`, read
the parsed problems, and re-generate.

#### RTD documentation

Read the **UM** and the **IM** before modifying the external configuration
tool project, or before implementing a user request the shipped examples do
not cover. `{s32k3_root}` = `mbd_find_s32k3_root()`:

```
{s32k3_root}\S32K3_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Tpp_TS_T40D*_M70I*_R0\doc\
    RTD_TPP_IM.pdf   RTD_TPP_UM.pdf
```

Read UM for dead-time and interrupt configuration; read IM for init-order
requirements (SPI and DIO must be initialized before TPP).

### 4.6 Model -- Initialize Function
Place one `TPP Config` block per TPP instance in the Initialize Function.
Set all parameters as described in Sec.2.

---

## 5. Initialize Function Pattern

```
Initialize Function (executed once at startup):
  TPP Config (inst=0, desat_mode='on', dead_time='300',
              en1_chn='EN1_CH', en2_chn='EN2_CH',
              rst_chn='RST_CH', cs_chn='CS_CH',
              spi_chn='SPI_CH_0', spi_seq='SPI_SEQ_0',
              overtemp_int='on', desat_int='on', ...)
```

Exact channel names must match the S32CT declarations exactly
(case-sensitive). Never invent channel names.

---

## 6. Runtime Data Flow

`TPP Config` is initialization-only. At runtime, the gate drive signals
are controlled via the MotorControl CDD or PWM blocks routed to the TPP
hardware. `TPP Config` does not have runtime outputs.

Fault interrupt handling (if `*_int` is `'on'`):
```
Hardware_Interrupt_Handler (irqGroup = appropriate fault IRQ)
  --> function-call subsystem
       --> fault handling logic
```

---

## 7. Interrupt Dependencies

If any `*_int` boolean (`overtemp_int`, `desat_int`, etc.) is `'on'`,
you must:
1. Enable the corresponding IRQ in Platform -> Interrupt Controller in S32CT.
2. Add a `Hardware_Interrupt_Handler` block with the appropriate `irqGroup`
   and `irqHandlers` values (read live after setting `irqGroup`).

If all `*_int` are `'off'`, no ISR handler block is needed for TPP.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| TPP instance index | Hardware (0/1/2) | `inst` enum (fixed 0/1/2) |
| EN1/EN2/RST/CS DIO channels | Peripherals -> Dio in S32CT | `en1_chn`, `en2_chn`, `rst_chn`, `cs_chn` enums |
| SPI channel / sequence | Peripherals -> Spi in S32CT | `spi_chn`, `spi_seq` enums |
| Dead time value | `dead_time` param | Block dialog |
| Interrupt enables | `*_int` boolean params | Block dialog |
| NVIC enable | Platform -> Interrupt Controller | Manifests as ISR firing |

---

## 9. Common Usage Patterns

**Pattern A -- Single TPP instance, over-temperature + desaturation protection**
```
TPP Config: inst=0, desat_mode='on', overtemp_int='on', desat_int='on',
            en1_chn/en2_chn/rst_chn/cs_chn from live enums,
            spi_chn/spi_seq from live enums, dead_time='300'
Hardware_Interrupt_Handler for fault IRQ
```

**Pattern B -- Single TPP instance, polling only (no interrupts)**
```
TPP Config: inst=0, all *_int='off',
            resource enums from live enums, dead_time from application spec
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `en1_chn` = `"No Dio channels configured"` | DIO channel not declared | Add DIO channel in S32CT Peripherals -> Dio |
| `spi_chn` = `"No Spi channels configured"` | SPI channel not declared | Add SPI channel in S32CT Peripherals -> Spi |
| Gate drive signals absent | TPP Config not in Initialize Function | Place `TPP Config` block in Initialize Function |
| Fault interrupt never fires | NVIC not enabled or no ISR handler | Enable IRQ in S32CT; add `Hardware_Interrupt_Handler` |
| SPI communication fails | SPI/DIO not initialized before TPP | Check board-init order (SPI + DIO before TPP) |

---

## 11. Board-Specific Considerations

- S32K3-specific block -- not present on other MBDT families. Confirm
  availability via `get_mbdt_toolbox('s32k3','blocks')`.
- EN1, EN2, RST, CS, and SPI pin assignments are board-specific (depend
  on the physical TPP IC connection). Never invent pin numbers or channel
  names -- read the shipped example or hardware schematic.
- `dead_time` value is application/hardware-specific; read from the motor
  drive specification or the shipped example.

---

## 12. Guardrails (TPP Config-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only TPP Config-specific rules follow.

- **This block has no `api_func`.** Do not try to set it; read
  `DialogParameters` live to confirm the parameter list.
- **`inst` is a fixed enum (`0`, `1`, `2`) with no sentinel.** Pick the index
  that matches the physical hardware.
- **`dead_time` is a string.** Preserve its exact format; never coerce it to a
  number or change its units.
- **S32K3 only.** The block is not available on other families.
- **Initialize SPI and DIO before TPP in board-init.** Verify the order with
  `get_mbdt_board_init`.
