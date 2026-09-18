# SPI -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the SPI
peripheral on any NXP MBDT-targeted Simulink model. Verified against the
MBDT S32K3 shipped example `s32k3xx_spi_async_interr_s32ct` (toolbox
1.9.0, RTD 7.0.0, MATLAB R2026a). The behavioral model is expected to
hold cross-family (S32K3); enum labels and
board-init symbols are verified only on S32K3. API semantics were drawn
from the RTD SPI component folder
`.../eclipse/plugins/Spi_TS_T40D34M70I0R0/` (S32K3 RTD 7.0.0).

> **Tip -- start from a shipped example.** Open a shipped SPI example via
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md); its
> `.mex` project (Pins -> LPSPI, Peripherals -> Spi, Platform -> NVIC for
> the async case) plus its model (Initialize Function `SPI_SetAsyncMode`,
> transmit / read / setup blocks, per-job and per-sequence ISR handlers)
> forms a coherent reference that mirrors the sections below.

---

## 1. Peripheral Overview

The SPI peripheral in MBDT is a composite of four artefacts:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project (Pins -> LPSPI, Peripherals -> Spi, Platform -> NVIC for async) | External to the model | External config tool |
| 2 | Board-init entry `Spi_Init(&Spi_Config)` | `mbdt_board_init.c`, emitted at code-gen | `editing-mbdt-board-init` skill |
| 3 | Setup blocks: `Spi_SetAsyncMode` (in Initialize Function) and `Spi_SetupEB` (arms an External Buffer channel) | Simulink model | This skill |
| 4 | Runtime blocks: `Spi_AsyncTransmit` / `Spi_SyncTransmit` / `Spi_WriteIB` / `Spi_ReadIB` / `Spi_GetJobResult` / `Spi_GetSequenceResult` + (async only) `Hardware_Interrupt_Handler` + callback subsystem | Simulink model | This skill |

**Key departures from other peripherals:**

- **SPI has a four-level resource hierarchy.** Unlike I2C (one channel)
  or UART (one channel), an SPI transfer is built from
  **External Device -> Sequence -> Job -> Channel**:
  - A **Channel** carries the actual data and has a buffer type:
    **Internal Buffers (IB)** (driver-owned, use `Spi_WriteIB` /
    `Spi_ReadIB`) or **External Buffers (EB)** (application-owned, armed
    with `Spi_SetupEB`).
  - A **Job** binds one ordered channel list + one External Device (which
    carries the chip-select and timing), and has its own end
    notification.
  - A **Sequence** binds one or more Jobs and has its own end
    notification. `Spi_AsyncTransmit` / `Spi_SyncTransmit` operate on a
    **Sequence**.
- **Chip-select is a property of the External Device, not the block.**
  PCS identifier, polarity, behavior, and selection engine are all
  configured in the config tool (Sec.8), never on the Simulink block.
- **Two independent notification levels.** `irqHandlers` enumerates
  **both** per-Job end callbacks and per-Sequence end callbacks (Sec.7) --
  a departure from I2C/UART's single fixed callback.
- **Async mode must be armed at init.** `Spi_SetAsyncMode` (in the
  Initialize Function) selects interrupt-vs-polling delivery before any
  async transfer (Sec.5).

---

## 2. The `Spi` Block -- Complete Behavioral Model

**One `Spi` block = one `Spi_*` function call.** Every block has
`MaskType = {family}_spi` (e.g. `s32k3_spi`) and is an `S-Function`.

### 2.1 The `api_func` enum -- the function selector

**Always read the live `api_func.Enum`** via
`get_param({spiBlk}, 'DialogParameters')` -- the set of available
`Spi_*` functions is owned by the installed toolbox version and must
never be carried from memory.

Observed live entries on S32K3 (illustrative -- validate each against the
block's live `api_func.Enum` before selecting, and refuse near-misses):

```
Spi_WriteIB          Spi_AsyncTransmit    Spi_ReadIB
Spi_SetupEB          Spi_GetStatus        Spi_GetJobResult
Spi_GetSequenceResult                     Spi_GetVersionInfo
Spi_SyncTransmit     Spi_GetHWUnitStatus  Spi_Cancel
Spi_SetAsyncMode     Spi_MainFunction
```

**Behavioral facts (independent of the exact function list):**

- **`Spi_WriteIB` / `Spi_ReadIB`** write to / read from an **Internal
  Buffer** channel. Use them with IB-type channels.
- **`Spi_SetupEB`** arms an **External Buffer** channel with the
  application's TX/RX pointers and length before a transfer. Use it with
  EB-type channels.
- **`Spi_AsyncTransmit`** starts a Sequence and returns immediately;
  completion arrives via the Job-end / Sequence-end ISR callback.
- **`Spi_SyncTransmit`** starts a Sequence and blocks until it completes.
- **`Spi_SetAsyncMode`** selects interrupt-vs-polling delivery for async
  transfers (see `mode` in Sec.2.2). Call once at init.
- **`Spi_GetJobResult` / `Spi_GetSequenceResult`** return the pass/fail
  result of a Job / Sequence (e.g. `SPI_JOB_OK`, `SPI_SEQ_OK`).
- **`Spi_GetStatus` / `Spi_GetHWUnitStatus`** report driver / hardware
  unit busy state.
- **`Spi_GetVersionInfo`** is diagnostic; needs no resource enum.
- Selecting `api_func` reshapes the S-Function's ports. **Set `api_func`
  first.**

Whenever this reference names a specific `Spi_*` function, treat it as an
**illustrative** label observed in the shipped S32K3 example -- validate
it against the block's live `api_func.Enum` before selecting it.

### 2.2 Parameter surface (constant across all `api_func` values)

| Name | Type | Prompt | Semantics | Meaningful for |
|---|---|---|---|---|
| `api_func` | enum | Function | Function selector (see Sec.2.1) | All |
| `channel` | enum | Channel | `SpiChannel_N` -- the data channel (IB or EB) | `Spi_WriteIB`, `Spi_ReadIB`, `Spi_SetupEB`, `Spi_SetAsyncMode` |
| `job` | enum | Job | `SpiJob_N` -- one channel-list + one External Device | `Spi_GetJobResult` |
| `sequence` | enum | Sequence | `SpiSequence_N` -- one or more Jobs | `Spi_AsyncTransmit`, `Spi_SyncTransmit`, `Spi_GetSequenceResult` |
| `hwunit` | enum | HW Unit | `CSIB0` \| `CSIB1` -- the External Device handle | `Spi_GetHWUnitStatus` |
| `mode` | enum | Mode | `Polling` \| `Interrupt` -- async delivery | `Spi_SetAsyncMode` |
| `text` | string | *(empty)* | System-managed cache -- never set | Read-only |

The parameter set is constant across `api_func`; the mask shows/enables
only those meaningful for the selected function. Read live which are
enabled after setting `api_func`.

### 2.3 The resource enums

Observed live entries in the shipped example:

```
channel   : SpiChannel_0 | SpiChannel_1
job       : SpiJob_0      | SpiJob_1
sequence  : SpiSequence_0 | SpiSequence_1
hwunit    : CSIB0         | CSIB1
mode      : Polling       | Interrupt
```

Semantics (from the example config tree and README):

```
SpiChannel_0  ->  External Buffers (EB), DataWidth 8, on SpiJob_0
SpiChannel_1  ->  Internal Buffers (IB), on SpiJob_1
SpiJob_0      ->  Channel_0 + SpiExternalDevice_0 (CSIB0, PCS0)  -> SpiSequence_0
SpiJob_1      ->  Channel_1 + SpiExternalDevice_1 (CSIB1, PCS3)  -> SpiSequence_1
CSIB0 / CSIB1 ->  External Device handles (chip-select instances)
```

**Master vs Slave role is not a block parameter.** It is decided in the
config tool: `SpiPhyUnit_0 = LPSPI_2 / SPI_MASTER`,
`SpiPhyUnit_1 = LPSPI_1 / SPI_SLAVE` in the shipped example. Which
Sequence a block drives, plus the External Device it is bound to, decide
the physical unit and chip-select used.

### 2.4 Sentinel rules

| `api_func` | resource sentinel = error? |
|---|---|
| `Spi_GetVersionInfo` | NO -- no resource needed |
| `Spi_MainFunction` | NO -- driver tick, no resource |
| Everything else | YES (on the resource enum(s) it actually uses) |

If `channel.Enum = {"No channels configured"}` (or the equivalent
sentinel on `job` / `sequence` / `hwunit`), route to
`opening-mbdt-config-tool` and declare the missing element in
Peripherals -> Spi.

### 2.5 Selection ordering

1. `api_func` first.
2. `channel` / `job` / `sequence` / `hwunit` (whichever the function
   uses).
3. `mode` (only on `Spi_SetAsyncMode`).

Setting a resource enum before `api_func` leaves it on a stale hidden
slot and the model is incoherent.

---

## 3. Required Block Catalog

| Block name | `MaskType` | Role |
|---|---|---|
| `Spi` | `{family}_spi` | Wraps one `Spi_*` function; multiple instances per model |
| `Hardware_Interrupt_Handler` | `{family}_isr_handler` | Routes a Job-end or Sequence-end notification into a function-call subsystem (async mode only) |
| `FreeMASTER Config` (optional) | `{family}_fm_config` | Ships in the async example's `.pmpx` companion project |

The async example places **two** ISR-handler blocks: one for the Job-end
callback and one for the Sequence-end callback (Sec.7).

---

## 4. Configuration Workflow

Steps 1-3 in the external configuration tool; steps 4-5 in the model.

### 4.1 Pins (S32 Configuration Tools -> Pins, or EB tresos -> Port)

Route SCK, SIN (MISO), SOUT (MOSI), and PCS (chip-select) for each LPSPI
unit. Pin numbers are **board-specific** -- never invent them. Discover
the live pin mapping via `nxp_s32ct_inspect(kind='pins')` on the `.mex`.
In the shipped example the Master (LPSPI_2) and Slave (LPSPI_1) are wired
on the same MCU and bridged with jumpers (Sec.6.3).

### 4.2 Peripherals -> Spi (S32 Configuration Tools -> Peripherals)

Declare the full hierarchy. Assign, in order:

```
SpiPhyUnit_{N}       -> physical LPSPI unit + SPI_MASTER / SPI_SLAVE
SpiChannel_{N}       -> buffer type (IB or EB), DataWidth, buffer length
SpiExternalDevice_{N}-> chip-select (see Sec.8) + baudrate + timings + HwUnit (CSIB{N})
SpiJob_{N}           -> channel list + one External Device + JobEndNotification
SpiSequence_{N}      -> one or more Jobs + SeqEndNotification
```

The **exact names** you assign here (`SpiChannel_0`, `SpiJob_0`,
`SpiSequence_0`, `CSIB0`, ...) are what appear in the block's resource
enums. Case-sensitive. `type_id = Spi` (from
`nxp_s32ct_inspect(kind='instances')`).

### 4.3 Platform -> Interrupt Controller (async mode only)

Enable the NVIC entry for each LPSPI instance used asynchronously (e.g.
`LPSPI{N}_IRQn`). Verify the exact IRQn names via the `.mex` Platform
inspection -- do not assume. Sync mode does not require NVIC enablement.

### 4.4 Board Initialization (Simulink model)

Add via [`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md):

```
Component : Spi
Priority  : 70
Enabled   : true
Header    : #include "Spi.h"
Code      : Spi_Init(&Spi_Config);
```

AUTOSAR standard driver (`mode = autosar` in the `.mex`). `Spi_Config` is
emitted by the code-gen tool from Peripherals -> Spi. (Priority 70 is the
default emitted for this example; verify live via `get_mbdt_board_init`.)

#### Expected generated C files (SPI)

A correctly-configured SPI peripheral must cause the config tool to
**emit these generated units**. If any are missing, the build fails at
compile/link time -- authoritative evidence of a config-tool-side
problem, NOT a model problem (see the generic "Expected generated files
and the missing-file diagnostic" section in `SKILL.md`). Confirm the
exact file names against the generated `{model}_Config/` folder or the
RTD `Spi_TS_T40D34M70I0R0` docs -- do not cite from memory.

| Generated file | Emitted from | Flavor |
|---|---|---|
| `Spi_Cfg.h` / `Spi_PBcfg.*` | Peripherals -> Spi (always) | SPI driver |
| `Lpspi_Ip_Cfg.h` / `Lpspi_Ip_Cfg.c` | Peripherals -> Spi, per LPSPI unit | LPSPI IP |
| `Lpspi_Ip_PBcfg.*` | Peripherals -> Spi, per LPSPI unit | LPSPI IP |

**If `fatal error: Lpspi_Ip_Cfg.h` (or `Spi_Cfg.h`) No such file appears
at build time:** the LPSPI flavor was not emitted. Do NOT touch the
model. Run `nxp_s32ct_validate(project_path={.mex},
tool_name="Peripherals")`, read the parsed problems, and suspect a
leftover / mis-flavored PhyUnit from the shipped example. Remove the
unused flavor in the config tool, re-validate, and re-generate.

#### RTD documentation (Integration + User Manual)

Read the **UM** and the **IM** before you modify the external
configuration tools project (S32CT / EB tresos), or before you implement
a user request the shipped examples do not cover. The **UM** tells you
how each `api_func` behaves, so you pick and drive the right function;
the **IM** covers generated-file expectations, init order, and NVIC
prerequisites. `{family_root}` = `mbd_find_{family}_root()`; glob RTD-
version segments (filenames are uppercased):

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Spi_TS_T40D*_M70I*_R0\doc\
    RTD_SPI_IM.pdf   RTD_SPI_UM.pdf
```

When an LPSPI unit is configured for DMA transfers (rather than
interrupt / polling), the DMA channel routing lives in the **Mcl**
driver. Consult the Mcl IM/UM as well:

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Mcl_TS_T40D*_M70I*_R0\doc\
    RTD_MCL_IM.pdf   RTD_MCL_UM.pdf
```

### 4.5 Model Runtime Blocks (Simulink model)


Assemble per Sec.6.

---

## 5. Initialize Function Pattern

**The shipped async example places `Spi_SetAsyncMode` in the Initialize
Function** to arm interrupt delivery before any async transfer:

```
Event Listener (EventType = Initialize)
    +-- Spi_SetAsyncMode   channel = SpiChannel_0, mode = Interrupt
```

This is a genuine departure from I2C (which puts only
`Spi_GetVersionInfo`-style diagnostics there). For a **polling / sync**
design, `mode = Polling` (or no `Spi_SetAsyncMode` at all) is used and
the Initialize Function may be empty. Read the example's Initialize
Function live -- do not assume.

---

## 6. Runtime Data Flow

### 6.1 Async (`s32k3xx_spi_async_interr_s32ct`) -- Master transmits, ISR delivers completion

```
Initialize Function
   +-- Spi_SetAsyncMode   ch = SpiChannel_0, mode = Interrupt

Top-level (runs at base rate)
   +-- Spi_WriteIB        ch = SpiChannel_1 (IB)   -- load internal TX buffer
   +-- Spi_SetupEB        ch = SpiChannel_0 (EB)   -- arm external TX/RX pointers
   +-- Spi_AsyncTransmit  seq = SpiSequence_0      -- start Job0 (Channel0 + ExtDev0/CSIB0)
   +-- Spi_AsyncTransmit1 seq = SpiSequence_1      -- start Job1 (Channel1 + ExtDev1/CSIB1)
   +-- Spi_ReadIB         ch = SpiChannel_1 (IB)   -- read internal RX buffer

ISR path -- Job-end
   Hardware_Interrupt_Handler  irqGroup = Spi, irqHandlers = MBDT_SPI_end_job0_callback
        | function-call trigger
        v
   Function-Call Subsystem1
        +-- Spi_GetJobResult   job = SpiJob_0   (check SPI_JOB_OK)

ISR path -- Sequence-end
   Hardware_Interrupt_Handler  irqGroup = Spi, irqHandlers = MBDT_SPI_end_sequence1_callback
        | function-call trigger
        v
   Function-Call Subsystem3
        +-- Spi_GetSequenceResult  sequence = SpiSequence_1  (check SPI_SEQ_OK)
        +-- If (result OK) -> DIO_WriteChannel (toggle DioLed2)
```

### 6.2 Sync -- blocking Sequence transfer

```
Top-level (runs once at model start via first-execution logic)
   +-- Spi_SetupEB        ch = SpiChannel_0 (EB)  -- or Spi_WriteIB for an IB channel
   +-- Spi_SyncTransmit   seq = SpiSequence_0     -- BLOCKS until the whole sequence completes
   +-- Spi_GetSequenceResult  sequence = SpiSequence_0
          If (result == SPI_SEQ_OK) -> next transfer
```

No ISR handler in the model. (Validate the exact sync flow against a
shipped sync SPI example before relying on it.)

### 6.3 The two-role setup -- one MCU, two roles

The shipped async example wires **Master (LPSPI_2) and Slave (LPSPI_1) on
the same MCU**. The user physically bridges MOSI/MISO/SCK/CS between the
two units with jumper wires. `master_send` is transmitted by the Master's
Job0; the Slave receives into `slave_recv` and loops it back to the
Master's `master_receive` via Job1. On each successful Slave sequence,
`DioLed2` toggles. This is the shipped-example convention demonstrating
both roles in one model. For a real system with an external SPI device,
only the Master side is instantiated.

### 6.4 IB vs EB channels -- pick the matching api_func

- **Internal Buffers (IB):** the driver owns the buffer. Load it with
  `Spi_WriteIB`, retrieve with `Spi_ReadIB`. No pointer setup needed.
- **External Buffers (EB):** the application owns the buffer. Arm the
  TX/RX pointers and length with `Spi_SetupEB` **before** the transfer.
  `EbMaxLength` in the config tool bounds the length.

Using `Spi_WriteIB` on an EB channel (or `Spi_SetupEB` on an IB channel)
is a configuration mismatch -- match the `api_func` to the channel's
declared buffer type.

---

## 7. Interrupt Dependencies

1. **Async mode:** one `Hardware_Interrupt_Handler` **per notification**.
   The shipped example has two: one for the Job-end callback, one for the
   Sequence-end callback.
2. **Sync mode:** no ISR handler in the model.
3. **`irqHandlers.Enum` under `irqGroup = Spi` enumerates all declared
   Job-end and Sequence-end notification names.** In the shipped example
   it holds `MBDT_SPI_end_job0_callback` and
   `MBDT_SPI_end_sequence1_callback`. This is a **departure** from
   I2C/UART, whose `irqHandlers` under their group hold exactly one fixed
   callback. The set grows with each Job / Sequence you give an end
   notification in the config tool -- **read it live**, never assume.
4. NVIC enablement: `LPSPI{N}_IRQn` per LPSPI instance used
   asynchronously (verify exact names via the `.mex`).

To wire a notification: add a `Hardware_Interrupt_Handler`, set
`irqGroup = Spi`, then set `irqHandlers` to the exact Job-end or
Sequence-end callback name from the live enum.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Channel logical name (`SpiChannel_0`) | Peripherals -> Spi | `channel.Enum` on `Spi` block |
| Channel buffer type (IB / EB), DataWidth, `EbMaxLength` | Peripherals -> Spi | Compiled-in; picks the matching `api_func` |
| Job logical name (`SpiJob_0`) + JobEndNotification | Peripherals -> Spi | `job.Enum`; notification appears in `irqHandlers.Enum` |
| Sequence logical name (`SpiSequence_0`) + SeqEndNotification | Peripherals -> Spi | `sequence.Enum`; notification appears in `irqHandlers.Enum` |
| External Device handle (`CSIB0`) | Peripherals -> Spi | `hwunit.Enum` on `Spi` block |
| Chip-select: `SpiCsIdentifier` (PCS0..PCS7) | Peripherals -> Spi -> External Device | Compiled-in; not exposed on block |
| Chip-select: `SpiCsPolarity` (LOW/HIGH), `SpiCsBehavior` (CS_KEEP_ASSERTED), `SpiCsSelection` (CS_VIA_PERIPHERAL_ENGINE / GPIO), `SpiEnableCs` | Peripherals -> Spi -> External Device | Compiled-in; not exposed |
| Physical unit + Master/Slave (`LPSPI_2` / SPI_MASTER) | Peripherals -> Spi -> SpiPhyUnit | Implicit -- no block parameter |
| Baudrate, DataShiftEdge, ShiftClockIdleLevel, TransferWidth, Clk2Cs/Cs2Clk/Cs2Cs timings | Peripherals -> Spi -> External Device | Compiled-in; not exposed |
| Clock source (`SPI_CLK`) | Peripherals -> Spi -> clock reference -> Mcu | Compiled-in; not exposed |
| DMA (`SpiGlobalDmaEnable`, `SpiPhyUnitAsyncUseDma`) | Peripherals -> Spi | Compiled-in; not exposed |
| SCK / SIN / SOUT / PCS pin muxing | Pins | Compiled-in; not exposed |
| NVIC enable | Platform -> Interrupt Controller | Manifests as the Job/Sequence callback firing |
| Async delivery (Interrupt / Polling) | Simulink model | `mode` on `Spi_SetAsyncMode` |
| Board-init entry `Spi_Init(&Spi_Config)` | `editing-mbdt-board-init` skill | Emitted into `mbdt_board_init.c` |

---

## 9. Common Usage Patterns

### 9.1 Master write to external device (blocking, EB)

```
Top-level
   +-- Spi_SetupEB        ch = SpiChannel_0 (EB, TX pointer = payload)
   +-- Spi_SyncTransmit   seq = SpiSequence_0
   +-- Spi_GetSequenceResult  sequence = SpiSequence_0   (expect SPI_SEQ_OK)
```

### 9.2 Master read from external device (blocking, IB)

```
Top-level
   +-- Spi_WriteIB        ch = SpiChannel_1 (IB, command byte)
   +-- Spi_SyncTransmit   seq = SpiSequence_1
   +-- Spi_ReadIB         ch = SpiChannel_1 (IB, response bytes)
```

### 9.3 Master transmit asynchronously with completion notification

```
Initialize Function
   +-- Spi_SetAsyncMode   ch = SpiChannel_0, mode = Interrupt

Top-level
   +-- Spi_SetupEB        ch = SpiChannel_0 (EB)
   +-- Spi_AsyncTransmit  seq = SpiSequence_0

Hardware_Interrupt_Handler  irqGroup = Spi, irqHandlers = {SequenceEnd callback}
    | trigger
    v
callback subsystem
    +-- Spi_GetSequenceResult  sequence = SpiSequence_0  (expect SPI_SEQ_OK)
```

### 9.4 Same-MCU Master + Slave loopback (shipped-example pattern)

```
Initialize Function
   +-- Spi_SetAsyncMode   ch = SpiChannel_0, mode = Interrupt

Top-level
   +-- Spi_WriteIB        ch = SpiChannel_1 (IB, slave TX)
   +-- Spi_SetupEB        ch = SpiChannel_0 (EB, master TX)
   +-- Spi_AsyncTransmit  seq = SpiSequence_0   (master, Job0/CSIB0)
   +-- Spi_AsyncTransmit1 seq = SpiSequence_1   (slave path, Job1/CSIB1)
   +-- Spi_ReadIB         ch = SpiChannel_1 (IB, master receive)

Two ISR handlers: MBDT_SPI_end_job0_callback -> Spi_GetJobResult(SpiJob_0)
                  MBDT_SPI_end_sequence1_callback -> Spi_GetSequenceResult(SpiSequence_1) -> toggle DioLed2

Hardware wiring (user provides with jumpers):
   Master MOSI --- Slave MOSI      Master MISO --- Slave MISO
   Master SCK  --- Slave SCK       Master CS   --- Slave CS
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `channel` / `job` / `sequence` / `hwunit` enum = "No ... configured" | Config tool has no such element declared | Open config tool via `opening-mbdt-config-tool`; add it in Peripherals -> Spi |
| Build links but no SPI traffic | Missing board-init entry OR wrong jumper wiring | Verify `Spi_Init` in board init (Sec.4.4); check MOSI/MISO/SCK/CS wiring |
| Async callback never fires | ISR handler missing or `LPSPI{N}_IRQn` disabled in config tool, or `Spi_SetAsyncMode` not called with `mode = Interrupt` | Add ISR handler (`irqGroup = Spi`, correct callback); enable NVIC; ensure `Spi_SetAsyncMode` runs at init |
| `Spi_GetSequenceResult` / `Spi_GetJobResult` not OK | CS mis-polarity, baudrate mismatch, wrong shift edge / idle level, wiring | Check External Device settings (Sec.8) against the peer device datasheet; verify wiring |
| EB transfer sends garbage / wrong length | `Spi_SetupEB` not called before transfer, or length > `EbMaxLength` | Arm the EB channel with `Spi_SetupEB` first; keep length <= `EbMaxLength` |
| `Spi_WriteIB` has no effect | Called on an EB-type channel | Match `api_func` to the channel buffer type (IB -> WriteIB/ReadIB; EB -> SetupEB) |
| ISR fires but wrong handler runs | `irqHandlers` set to a Job-end callback when a Sequence-end was intended (or vice versa) | Read `irqHandlers.Enum` live; pick the exact Job-end or Sequence-end name |
| Build fails: unresolved `Spi_Init` / `Spi_AsyncTransmit` | Missing board-init entry | Add via `editing-mbdt-board-init`. Never stub the function. |
| Build fails: `fatal error: Lpspi_Ip_Cfg.h` / `Spi_Cfg.h` No such file | Config tool did not emit the LPSPI / SPI config unit -- often a leftover / mis-flavored PhyUnit from the shipped example | Do NOT edit the model. Run `nxp_s32ct_validate(project_path={.mex}, tool_name="Peripherals")`; remove the leftover flavor; re-validate and re-generate. See Sec.4.4. |

---

## 11. Board-Specific Considerations

- **Board-specific SCK / SIN / SOUT / PCS header pins** are listed in the
  shipped README (per-board Master and Slave pin tables). Never invent
  them -- verify against the `.mex` via `nxp_s32ct_inspect(kind='pins')`.
  Boards covered by the shipped async example include S32K311EVB-Q100,
  S32K312EVB-Q172, FRDM-A-S32K312, S32K3X4EVB-Q172, S32K3X4EVB-T172,
  FRDM-A-S32K344, S32K3X4EVB-Q257, S32K388EVB-Q289, S32K389EVB-Q437.

- **Same-MCU loopback needs jumper wiring.** The shipped example bridges
  the Master and Slave LPSPI units with jumper wires (MOSI-MOSI,
  MISO-MISO, SCK-SCK, CS-CS). A real single-master design does not need
  this.

- **Chip-select engine choice matters.** `SpiCsSelection =
  CS_VIA_PERIPHERAL_ENGINE` uses the LPSPI hardware PCS pin; the GPIO
  option drives CS from a DIO pin instead. The shipped example uses the
  peripheral engine with `SpiCsIdentifier = PCS0` (ExtDev0) / `PCS3`
  (ExtDev1), `SpiCsPolarity = LOW`, `SpiCsBehavior = CS_KEEP_ASSERTED`.

- **FreeMASTER `.pmpx` companion project** ships with the example and
  plots `master_send` / `slave_recv` / `master_receive`.

- **Cross-family portability:** the behavioral model (the `api_func`
  function set discovered live, the External Device -> Sequence -> Job ->
  Channel hierarchy, IB/EB channels, per-Job and per-Sequence
  notifications, ISR routing through the family handler) is expected to
  hold on other MBDT families. Board-init component name may differ
  (S32K3 uses `Spi` with `#include "Spi.h"`); discover live via
  `get_mbdt_board_init({family})`.


---


## 12. Guardrails (SPI-specific)

- **Never stub SPI functions.** Do not hand-write `Spi_Init`,
  `Spi_AsyncTransmit`, `Spi_SyncTransmit`, `Spi_SetupEB`, any
  `MBDT_SPI_*_callback`, or any RTD function into generated C. The
  board-init entry (Sec.4.4) is what triggers MBDT to generate the driver
  code.

- **Never invent Channel / Job / Sequence / External-Device names.**
  `SpiChannel_0`, `SpiJob_0`, `SpiSequence_0`, `CSIB0` are exact strings
  from the config tool. Read them from the block's live enums.

- **Match the `api_func` to the channel buffer type.** `Spi_WriteIB` /
  `Spi_ReadIB` are for IB channels; `Spi_SetupEB` is for EB channels.
  Mixing them silently misbehaves.

- **Set `Spi_AsyncTransmit` / `Spi_SyncTransmit` against a Sequence, not
  a Job or Channel.** The transfer unit is the Sequence; `job` /
  `channel` enums are for the result-query and buffer functions.

- **`Spi_SetAsyncMode` must run before any async transfer** and its
  `mode` must be `Interrupt` for ISR-delivered completion. If it is
  missing or set to `Polling`, the async callbacks never fire -- a
  runtime silence, not a build error.

- **Never route an SPI interrupt through a parameter on the `Spi`
  block.** No `isr_*` / `callback_*` parameter exists on `{family}_spi`.
  All SPI notifications (Job-end and Sequence-end) go through the
  `Hardware_Interrupt_Handler` block, and `irqHandlers` must be the exact
  live callback name.

- **Never set `text` on any `Spi` block** -- system-managed.

- **Chip-select is config-tool-owned.** Do not attempt to set PCS
  identifier, polarity, behavior, or selection engine from the Simulink
  block -- they live on the External Device in Peripherals -> Spi.
