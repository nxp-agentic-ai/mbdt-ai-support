# MCL -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the MCL
(Multi-purpose Clock Layer) peripheral on any NXP MBDT-targeted
Simulink model. Covers the `Mcl` block (`MaskType = s32k3_mcl`),
the full `api_func` surface (DMA, eMIOS, LCU, TRGMUX), resource
enum structure, initialization requirements, and external-config-tool
dependencies. Verified on S32K3. 

> **Availability note.** MCL is not a user-facing block on every family.
> **Always call `get_mbdt_toolbox(family,'blocks')` first.** If no `Mcl`
> line is returned, only the board-init entry is needed (Sec.4.2); skip
> Sec.3 and the runtime block steps.

MCL is an **infrastructure driver**: it owns DMA channels, eMIOS
master-bus clocking, LCU (Logic Control Unit) cross-triggering logic,
and TRGMUX signal routing. Other drivers (ADC, PWM, ICU, SPI, UART)
depend on it. A standalone `Mcl` block in the diagram is needed only
when the model must call MCL API functions directly (custom DMA
chains, runtime eMIOS prescaler changes, LCU logic reconfiguration,
TRGMUX mux changes at runtime).

> **Tip -- start from a shipped example.** Examples such as
> `s32k344_pwm_trgmux_lcu_adc_ctu_s32ct` and `s32k3xx_dma_transfer_ebt`
> contain `Mcl` blocks with fully configured `api_func` values. Open
> them via [`opening-mbdt-example`](../../opening-mbdt-example/SKILL.md)
> and inspect each block with `get_param(...,'DialogParameters')`.
> Never carry DMA channel names, LCU identifiers, or TRGMUX mux
> indices from memory.

---

## 1. Peripheral Overview

Adding "MCL to a model" means placing three artefacts:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Peripherals -> Mcl: DMA channels, eMIOS master buses, LCU instances, TRGMUX map) | External | External config tool |
| 2 | Board-init entry `Mcl_Init(&Mcl_Config)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Runtime `Mcl` block (only when the model calls MCL API directly) | Simulink model | This skill |

**Silent failure modes if any is missing:**

- Missing (1): block resource enums resolve to sentinel strings; dependent
  peripherals (PWM, ICU, ADC with DMA/CTU) build but DMA/eMIOS/LCU/TRGMUX
  never fires.
- Missing (2): `Mcl_Init` is never called; DMA channel maps, eMIOS prescalers,
  LCU tables, and TRGMUX routing are uninitialized; all dependent traffic
  silently fails.
- Missing (3): no impact when DMA/eMIOS/LCU is managed entirely by the owning
  peripheral driver. A standalone `Mcl` block is needed only when the model
  must call MCL API directly.

**Key departures from other peripherals:**

- MCL covers **four sub-systems**: DMA, eMIOS, LCU (Logic Control Unit),
  and TRGMUX. Each has its own set of `api_func` values and resource enums.
- The `Mcl` block is often **absent from a working model**. Only add a
  standalone `Mcl` block when the model needs to call MCL functions directly.
- MCL has **no dedicated callback block** and **no ISR-handler entry of its
  own**; DMA transfer-complete IRQs are owned by the peripheral that initiated
  the DMA and route through that peripheral's `Hardware_Interrupt_Handler`.
- `Mcl_Init` must be called **before** `Pwm_Init` and `Icu_Init` when eMIOS
  channels are in use. Enforce via board-init Priority ordering (INV-MCL-1).

---

## 2. The `Mcl` Block -- Complete Behavioral Model

**One `Mcl` block = one `Mcl_*` function call.** `MaskType = s32k3_mcl`.
A model may place several `Mcl` blocks with different `api_func` values.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param(<mclBlk>,'DialogParameters')`. The values below were read
live from S32K3 RTD (R2026a) and are accurate for that version; a
different RTD version may add or rename entries. Validate before
selecting and refuse near-misses.

**DMA functions:**

| `api_func` | Role |
|---|---|
| `Mcl_SetDmaChannelTransferList` | Configure a single TCD transfer list on a DMA logical channel |
| `Mcl_SetDmaChannelScatterGatherList` | Configure scatter-gather TCD list |
| `Mcl_SetDmaChannelScatterGatherConfig` | Configure scatter-gather descriptor |
| `Mcl_SetDmaChannelGlobalList` | Configure global channel settings |
| `Mcl_SetDmaInstanceCommand` | Issue instance-level DMA command (start / stop / pause / resume) |
| `Mcl_SetDmaChannelCommand` | Issue channel-level DMA command (start / stop / ack done / ack error) |
| `Mcl_GetDmaInstanceStatus` | Read DMA instance status flags |
| `Mcl_GetDmaChannelStatus` | Read DMA channel status flags |
| `Mcl_GetDmaChannelParam` | Read a specific DMA channel parameter |

**eMIOS functions:**

| `api_func` | Role |
|---|---|
| `Mcl_EmiosConfigureGlobalTimebase` | Configure the global time-base for an eMIOS instance |
| `Mcl_Emios_SetClockMode` | Switch between normal and alternate prescaler |
| `Mcl_Emios_SetCounterBusPeriod` | Override master-bus period at runtime |
| `Mcl_Emios_SetReloadInterval` | Set reload interval for a master bus channel |

**LCU (Logic Control Unit) functions:**

| `api_func` | Role |
|---|---|
| `Mcl_SetLcuSyncInputMuxSelect` | Select input mux for an LCU logic input |
| `Mcl_SetLcuSyncInputSwOverrideEnable` | Enable/disable SW override on an input |
| `Mcl_SetLcuSyncInputSwOverrideValue` | Set SW override value on an input |
| `Mcl_SetLcuSyncOutputLutControl` | Configure LUT control for an output |
| `Mcl_SetLcuSyncOutputEnable` | Enable/disable an LCU output |
| `Mcl_SetLcuSyncOutputPolarity` | Set output polarity |
| `Mcl_SetLcuSyncOutputDebugMode` | Set debug mode for an output |
| `Mcl_SetLcuSyncOutputForceSyncSelect` | Select force synchronization |
| `Mcl_SetLcuSyncOutputForceClearingMode` | Configure force clearing mode |
| `Mcl_SetLcuSyncOutputForceInputSensitivity` | Configure force input sensitivity |
| `Mcl_SetLcuSyncOutputForceDma` | Configure DMA event on force output |
| `Mcl_SetLcuSyncOutputForceInt` | Configure interrupt on force output |
| `Mcl_SetLcuSyncOutputLutDma` | Configure DMA event on LUT output |
| `Mcl_SetLcuSyncOutputLutInt` | Configure interrupt on LUT output |
| `Mcl_SetLcuSyncOutputRiseFilter` | Configure rise-edge filter |
| `Mcl_SetLcuSyncOutputFallFilter` | Configure fall-edge filter |
| `Mcl_SetLcuSyncCombineForceInput` | Configure combined force input |
| `Mcl_SetLcuSyncForceOutput` | Set force output |
| `Mcl_SetLcuSyncForceStatus` | Set force status |
| `Mcl_SetLcuSyncLogicInput` | Set logic input |
| `Mcl_SetLcuSyncLogicOutput` | Set logic output |
| `Mcl_SetLcuSyncSwOverrideInput` | Set SW override on logic input |
| `Mcl_SetLcuAsyncInputList` | Configure async input list |
| `Mcl_SetLcuAsyncOutputList` | Configure async output list |
| `Mcl_GetLcuSyncCombineForceInput` | Read combined force input |
| `Mcl_GetLcuSyncForceOutput` | Read force output |
| `Mcl_GetLcuSyncForceStatus` | Read force status |
| `Mcl_GetLcuSyncLogicInput` | Read logic input |
| `Mcl_GetLcuSyncLogicOutput` | Read logic output |
| `Mcl_GetLcuSyncSwOverrideInput` | Read SW override on logic input |
| `Mcl_GetLcuAsyncLogicInputInfo` | Read async logic input info |
| `Mcl_GetLcuAsyncLogicOutputInfo` | Read async logic output info |
| `Mcl_SetLcuWriteProtect` | Write-protect an LCU instance |

**TRGMUX functions:**

| `api_func` | Role |
|---|---|
| `Mcl_SetTrgMuxInput` | Route a trigger source to a TRGMUX output |
| `Mcl_SetTrgMuxLock` | Lock a TRGMUX register |

**Version:**

| `api_func` | Role |
|---|---|
| `Mcl_GetVersionInfo` | Read module / vendor version info; no resource needed |

Selecting `api_func` reshapes the S-Function's ports and toggles
visibility of every resource enum. **Set `api_func` first.**

### 2.2 Parameter surface

| Name | Type | Semantics |
|---|---|---|
| `api_func` | enum | Function selector (see Sec.2.1) |
| `logicInput` | enum | LCU logic input identifier (`No LCU Inputs configured` when empty) |
| `logicOutput` | enum | LCU logic output identifier (`No LCU Outputs configured` when empty) |
| `logicInstance` | enum | LCU instance identifier |
| `emiosInstance` | enum | eMIOS instance (`No EMIOS instances configured` when empty) |
| `ftmInstance` | enum | FTM instance (`FTM0 \| FTM1 \| FTM2 \| FTM3` -- legacy, verify live) |
| `logicChannel` | enum | Logic channel within an LCU instance |
| `prescalerType` | enum | `MCL_EMIOS_PRESCALER \| MCL_EMIOS_ALTERNATIVE_PRESCALER` |
| `dmaLogicInstance` | enum | DMA logical instance (`No DMA logic instances configured` when empty) |
| `dmaLogicChannel` | enum | DMA logical channel (`No DMA logic channels configured` when empty) |
| `dmaInstanceCommandType` | enum | `MCL_DMA_INST_STOP \| MCL_DMA_INST_STOP_ERROR \| MCL_DMA_INST_PAUSE \| MCL_DMA_INST_RESUME` |
| `dmaChannelCommandType` | enum | `MCL_DMA_CH_START_REQUEST \| MCL_DMA_CH_STOP_REQUEST \| ...` |
| `dmaScatterGatherElement` | enum | Scatter-gather element identifier |
| `dmaChannelInfo` | enum | `MCL_DMA_CH_GET_SOURCE_ADDRESS \| MCL_DMA_CH_GET_DESTINATION_ADDRESS \| ...` |
| `text` | string | System-managed cache -- **never set** |

### 2.3 Sentinel rules

| Resource | Sentinel string | Action |
|---|---|---|
| `logicInput` | `No LCU Inputs configured` | Declare an LCU input in Peripherals -> Mcl -> LCU |
| `logicOutput` | `No LCU Outputs configured` | Declare an LCU output in Peripherals -> Mcl -> LCU |
| `emiosInstance` | `No EMIOS instances configured` | Declare eMIOS in Peripherals -> Mcl -> EMIOS |
| `dmaLogicInstance` | `No DMA logic instances configured` | Declare a DMA instance in Peripherals -> Mcl -> DMA |
| `dmaLogicChannel` | `No DMA logic channels configured` | Declare a DMA channel in Peripherals -> Mcl -> DMA |
| `dmaScatterGatherElement` | `No DMA Scatter Gather elemenets configured` | Declare scatter-gather element in Peripherals -> Mcl -> DMA |

> **Note:** The sentinel string `"No DMA Scatter Gather elemenets configured"` contains a verbatim spelling typo (`elemenets`) copied from the live block enum. Do **not** correct it — it must match the exact string emitted by the block.

`Mcl_GetVersionInfo` requires no resource; all other functions require
the matching resource to be declared (sentinel = error).

### 2.4 Port signatures per `api_func`

MCL has many `api_func` variants. Port shapes follow the pattern below.
**Always read live after setting `api_func`** -- ports change with function selection.
Port data types not verified live; read from block after setting `api_func`.

| Group | Port pattern |
|---|---|
| `Mcl_SetDma*` / `Mcl_SetLcu*` / `Mcl_SetTrgMux*` / `Mcl_SetEmios*` | u1: configuration value or list; no outputs (void functions) |
| `Mcl_GetDmaInstanceStatus` / `Mcl_GetDmaChannelStatus` | none | y1: status flags |
| `Mcl_GetDmaChannelParam` | none | y1: parameter value |
| `Mcl_GetLcu*` (read functions) | none | y1: value |
| `Mcl_SetDmaInstanceCommand` / `Mcl_SetDmaChannelCommand` | none | y1: status |
| `Mcl_GetVersionInfo` | none | y1: version info |

> **Note:** MCL port shapes are configuration-heavy (TCD lists, mux indices,
> LUT values). Always read port types live from the block after setting
> `api_func` and all resource enums. The table above is a structural guide only.

### 2.5 Selection ordering

1. `api_func` first.
2. Resource enums (`dmaLogicInstance`, `dmaLogicChannel`, `emiosInstance`,
   `logicInput`, `logicOutput`, `logicInstance`) next.
3. Command / info enums (`dmaInstanceCommandType`, `dmaChannelCommandType`,
   `dmaChannelInfo`, `prescalerType`) last.

One `set_param` per parameter.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Library | Role |
|---|---|---|---|
| `Mcl` | `s32k3_mcl` | `mbd_s32k3_cdd_library` | Wraps one `Mcl_*` function; placed only when the model calls MCL API directly |

Discover exact path via `get_mbdt_toolbox('s32k3','blocks')`.
MCL has no dedicated callback block. DMA completion is notified
through the peripheral that owns the DMA.

---

## 4. Configuration Workflow

Config-tool steps first; model steps last.

### 4.1 Peripherals -> Mcl

Declare DMA channels, eMIOS master-bus parameters, LCU instances and
logic inputs/outputs, and TRGMUX mappings. Names assigned here appear
verbatim in the block's resource enums. Confirm via
`nxp_s32ct_inspect(kind='instances')`.

### 4.2 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../editing-mbdt-board-init/SKILL.md):

```
Component : Mcl
Priority  : <NN>   -- must be numerically lower (earlier) than Pwm and Icu when eMIOS is in use
Enabled   : true
Header    : #include "Mcl.h"
Code      : Mcl_Init(&Mcl_Config);
```

Verify Priority and header live via `get_mbdt_board_init(modelName)`.

**Priority ordering constraint (INV-MCL-1):** when eMIOS channels are
shared between MCL, PWM, and ICU, `Mcl_Init` must execute before
`Pwm_Init` and `Icu_Init`. Enforce by assigning MCL a numerically
lower Priority. Wrong ordering is a silent runtime failure.

#### Expected generated C files

The config tool emits (exact names vary by RTD version):
- `Mcl_Cfg.h` / `Mcl_PBcfg.c` -- DMA, eMIOS, LCU, TRGMUX configuration structures.
- `Trgmux_Ip_Cfg.h` / `Trgmux_Ip_PBcfg.c` -- TRGMUX map (when MCL owns TRGMUX).
- `Lcu_Ip_Cfg.h` / `Lcu_Ip_PBcfg.c` -- LCU tables (when LCU is used).

Confirm exact filenames in the generated `<model>_Config/` folder.
Missing files at build time indicate a config-tool problem; run
`nxp_s32ct_validate` and read its output.

#### RTD documentation

```
<family_root>\S32K3_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Mcl_TS_T40D*_M70I*_R0\doc\
    RTD_MCL_IM.pdf   RTD_MCL_UM.pdf
```

`<family_root>` = `mbd_find_s32k3_root()`. Always glob the version segments.

### 4.3 Model Runtime Blocks

Place `Mcl` blocks only when the model must call MCL API directly.
For models where PWM/ICU/ADC use eMIOS/DMA managed by their own
driver, the board-init entry plus config-tool declaration suffice.

---

## 5. Initialize Function Pattern

MCL has no mandatory priming call in the Initialize Function beyond
the board-init `Mcl_Init`. When custom DMA transfer lists must be
configured once at startup, place an `Mcl` block with
`api_func = Mcl_SetDmaChannelTransferList` (or the scatter-gather
variant) inside the Initialize Function subsystem and wire its
inputs from Constant blocks or Data Stores.

Read the shipped example's Initialize Function live to confirm the
exact wiring -- do not assume from memory.

---

## 6. Runtime Data Flow

**eMIOS master-bus prerequisite only (no `Mcl` block in the model):**

```
Board init (via editing-mbdt-board-init):
  Mcl_Init(&Mcl_Config);   [Priority N]
  Pwm_Init(&Pwm_Config);   [Priority N+1]
  Icu_Init(&Icu_Config);   [Priority N+2]
```

No `Mcl` block appears in the Simulink diagram.

**Runtime TRGMUX rerouting:**

```
[Step function]
  Mcl block: api_func=Mcl_SetTrgMuxInput
    inputs: TrgMux instance, input select, mux output index
```

**DMA channel configuration + software trigger (via peripheral):**

```
[Initialize Function]
  Mcl block: api_func=Mcl_SetDmaChannelTransferList
    dmaLogicInstance=<inst>, dmaLogicChannel=<ch>

[Step / ISR callback]
  Mcl block: api_func=Mcl_SetDmaChannelCommand, commandType=MCL_DMA_CH_START_REQUEST
    --> DMA transfer fires; completion notified through owning peripheral's callback
```

---

## 7. Interrupt Dependencies

MCL itself has **no ISR-handler block entry** in the MBDT model.
DMA transfer-complete interrupts are owned by the peripheral that
uses the DMA and route through that peripheral's
`Hardware_Interrupt_Handler` block.

LCU output interrupts, if used, route through `Hardware_Interrupt_Handler`
with `irqGroup` set to the LCU's group name -- read the live enum.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| DMA logical channel name | Peripherals -> Mcl -> DMA | `dmaLogicChannel` enum |
| DMA hardware channel mapping | Peripherals -> Mcl -> DMA | Compiled-in; not exposed |
| eMIOS master-bus prescaler | Peripherals -> Mcl -> EMIOS | `emiosInstance` enum; value compiled-in |
| LCU logic input/output names | Peripherals -> Mcl -> LCU | `logicInput` / `logicOutput` enums |
| TRGMUX mux assignments | Peripherals -> Mcl -> TRGMUX | Compiled-in; changeable at runtime via `Mcl_SetTrgMuxInput` |
| Board-init call | `editing-mbdt-board-init` | Emitted into `mbdt_board_init.c` |
| Init ordering relative to Pwm / Icu | `editing-mbdt-board-init` Priority | Enforced at board-init sequence level |

---

## 9. Common Usage Patterns

### Pattern 1: eMIOS master-bus prerequisite only

No `Mcl` block in the Simulink diagram.

```
Board init:
  Mcl_Init(&Mcl_Config);   Priority N
  Pwm_Init(&Pwm_Config);   Priority N+1
  Icu_Init(&Icu_Config);   Priority N+2
```

### Pattern 2: PWM -> TRGMUX -> LCU -> BCTU -> ADC cross-trigger

This pattern (common in motor-control models) uses MCL to configure
the LCU logic that routes a PWM edge through TRGMUX to trigger ADC
via BCTU. The static routing is config-tool-owned; runtime changes
use `Mcl_SetTrgMuxInput` and `Mcl_SetLcuSync*` functions.

### Pattern 3: Custom DMA transfer chain

```
[Initialize Function]
  Mcl: api_func=Mcl_SetDmaChannelTransferList
    dmaLogicInstance=<inst>, dmaLogicChannel=<ch>

[Periodic step]
  Mcl: api_func=Mcl_SetDmaChannelCommand, dmaChannelCommandType=MCL_DMA_CH_START_REQUEST
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `dmaLogicChannel` enum = `"No DMA logic channels configured"` | Peripherals -> Mcl -> DMA has no channel | Declare DMA channel in config tool |
| PWM / ICU eMIOS channels not outputting | `Mcl_Init` missing or Priority wrong | Add / reorder MCL board-init entry; Priority must be lower than Pwm and Icu |
| LCU output never changes | LCU input or output not declared, or `Mcl_Init` missing | Declare in Peripherals -> Mcl -> LCU; confirm board-init entry |
| TRGMUX cross-trigger not firing | TRGMUX map not declared, or board-init missing | Declare in Peripherals -> Mcl -> TRGMUX; confirm board-init entry |
| Build fails: `Mcl_Cfg.h: No such file` | Config tool did not generate MCL config unit | Run `nxp_s32ct_validate`; look for stale channels or mixed-flavor entries |


---

## 11. Board-Specific Considerations

- **S32K3:** eMIOS_0 / eMIOS_1 with Bus_A through Bus_F. LCU_0 / LCU_1
  with logic inputs/outputs. eDMA_0 with logical channels. `MaskType =
  s32k3_mcl`.

---

## 12. Guardrails (MCL-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only MCL-specific rules follow.

- **Do not add an `irqGroup = Mcl` ISR-handler entry.** DMA completion IRQs
  belong to the owning peripheral's ISR-handler entry.
- **Run `Mcl_Init` before `Pwm_Init` and `Icu_Init` when eMIOS is in use.**
  Enforce it with the board-init Priority.
- **Confirm `Mcl` block availability per family with
  `get_mbdt_toolbox(family,'blocks')` before adding it.**
