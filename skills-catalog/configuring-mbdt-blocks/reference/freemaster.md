# FreeMASTER -- MBDT Block Reference

Reference for adding FreeMASTER observability to any NXP MBDT model.
Covers `FreeMASTER Config`, `FreeMASTER Recorder`, and `FreeMASTER
Poll`. Cross-family (S32K3); enum labels
differ per family. Verified live on S32K3.

## The 4 FreeMASTER invariants

- **INV-1 -- No config-tool component.** FreeMASTER is not a driver
  in S32CT / EB tresos. No `Peripherals -> FreeMASTER` container, no
  `FreeMASTER_*_Cfg.h`, no `FreeMASTER_Init` in `mbdt_board_init.c`.
  All config lives on the `FreeMASTER Config` block, which emits the
  init call into generated model code.

- **INV-2 -- Rides on a real peripheral.** FreeMASTER is a protocol
  over LPUART (`connection_type = Serial`) or FlexCAN
  (`connection_type = CAN`). The underlying `Uart` / `Can`
  peripheral must be configured the normal way (Pins, Peripherals,
  NVIC, board-init entry). The `FreeMASTER Config` block claims it;
  it does not set it up.

- **INV-3 -- Enums come from the config tool.** `instance` is fed
  by S32CT Uart channels (LPUART_N); `cantxobj` / `canrxobj` by
  S32CT `CanHardwareObject_*`. Empty enum = missing peripheral --
  fix the config tool.

- **INV-4 -- The three service modes.**
  - `Poll-driven` -- no interrupt used; all servicing happens on the
    `FreeMASTER Poll` block.
  - `Short Interrupt` -- peripheral ISR only queues incoming bytes
    into the receive FIFO; message decoding still happens on the
    `FreeMASTER Poll` block.
  - `Long Interrupt` -- the entire protocol message is processed
    inside the peripheral ISR; the `FreeMASTER Poll` block is not
    required for protocol handling.

  MBDT auto-inserts a periodic `FreeMASTER Poll` in the generated
  code. It is mandatory for `Poll-driven` and `Short Interrupt`;
  harmless but unnecessary for `Long Interrupt`. Adding a
  `FreeMASTER Poll` block explicitly only forces an additional call
  on a chosen rate. The `FreeMASTER Recorder` block is also optional.

> **Tip.** Open a shipped example via
> [`opening-mbdt-example`](../../../opening-mbdt-example/SKILL.md).
> Verify against a current model via
> `get_param(.., 'DialogParameters')` -- never carry names from memory.

---

## 1. Peripheral Overview

Four artefacts:

| # | Artefact | Where | Owner |
|---|---|---|---|
| 1 | Underlying `Uart` or `Can` peripheral (Pins, Peripherals, NVIC) | Config tool | Uart / Can reference |
| 2 | Peripheral board-init entry (`Uart_Init` / `Can_43_FLEXCAN_Init`) | `editing-mbdt-board-init` | Uart / Can reference |
| 3 | `FreeMASTER Config` block (exactly one) | Model root | This skill |
| 4 | `FreeMASTER Recorder` / `FreeMASTER Poll` blocks (optional) | Model root / fast subsystem | This skill |

---

## 2. The FreeMASTER Blocks

Three blocks. None uses the `api_func` pattern.

### 2.1 `FreeMASTER Config` -- MaskType `{family}_fm_config`

Exactly one per model. Owns the driver config; emits `FMSTR_Init()`
and the transport bind into generated init code.

Live parameter surface (S32K3):

| Name | Type | Prompt | Semantics | Meaningful when |
|---|---|---|---|---|
| `connection_type` | enum | Connection type | `Serial` \| `CAN` | Always |
| `instance` | enum | Instance | `LPUART_N` from S32CT Uart | `connection_type = Serial` |
| `baudrate` | string | Baudrate | UART baud (e.g. `115200`) | `connection_type = Serial` |
| `mode` | enum | Mode | `Poll-driven` \| `Short Interrupt` \| `Long Interrupt` | Always |
| `isr_prio` | enum | ISR priority | `0`..`15` | `mode` != `Poll-driven` |
| `cantxid` | string | CAN TX identifier | Hex, e.g. `0x7AA` | `connection_type = CAN` |
| `cantxidext` | boolean | Extended TX ID | on/off | `connection_type = CAN` |
| `cantxobj` | enum | Hardware Object (TX) | `CanHardwareObject_*` from S32CT | `connection_type = CAN` |
| `canrxid` | string | CAN RX identifier | Hex, e.g. `0x7BB` | `connection_type = CAN` |
| `canrxidext` | boolean | Extended RX ID | on/off | `connection_type = CAN` |
| `canrxobj` | enum | Hardware Object (RX) | `CanHardwareObject_*` from S32CT | `connection_type = CAN` |
| `scope_use` | string | Number of scopes | integer | Always |
| `scope_max_vars` | string | Max variables per scope | integer | Always |
| `automatic_buff_size` / `buff_size` | boolean / string | Communication buffer | on = auto; off = user value | Always |
| `default_rfifo_size` / `rfifo_size` | boolean / string | Recorder FIFO size | on = default; off = user value | Always |
| `text` | string | *(empty)* | System-managed -- never set | Read-only |

Selection order: `connection_type` -> (`instance` \| `cantxobj` +
`canrxobj`) -> `mode` (+ `isr_prio`) -> buffer / scope / recorder
sizing.

### 2.2 `FreeMASTER Recorder` -- MaskType `{family}_fm_recorder`

Declares one recorder (circular buffer, drained on host request).
Zero or more per model. Place inside the subsystem whose rate should
drive it -- placement, not a parameter, sets the cadence.

| Name | Type | Prompt | Semantics |
|---|---|---|---|
| `id` | string | Id | Zero-based recorder index |
| `rec_name` | string | Name | Host-side label |
| `buff_size` | string | Buffer size (1-65536) | Sample slots |
| `timebase` | string | Timebase (0-1e9) ns | Sample period; `0` = per invocation |

### 2.3 `FreeMASTER Poll` -- library entry

Periodic FreeMASTER service block. Optional -- MBDT auto-inserts
one. See INV-4 for when it is mandatory. Add explicitly only to
force an additional service call on a chosen rate. No parameters.

---

## 3. Configuration Workflow

### 3.1 Configure the transport peripheral (config tool)

- **Serial:** one Uart channel in Peripherals -> Uart at the desired
  baud. Route pins. Enable NVIC (required for interrupt modes).
- **CAN:** one Can controller. Two `CanHardwareObject_*` entries --
  one TX, one RX -- with `HandleType` matching intent (usually
  interrupt). Route pins. Enable RX + TX NVIC (required for
  interrupt modes).

Add the peripheral board-init entry (`Uart_Init` or
`Can_43_FLEXCAN_Init`) via
[`editing-mbdt-board-init`](../../../editing-mbdt-board-init/SKILL.md).

FreeMASTER itself has no board-init entry and no
`Hardware_Interrupt_Handler` -- it hooks the peripheral's ISR
internally (INV-1, INV-2).

#### RTD documentation (Integration + User Manual)

**FreeMASTER has no RTD driver component** -- it is a MathWorks/NXP
add-on block, not a Real-Time Drivers peripheral. There is therefore
**no `RTD_*_IM.pdf` / `RTD_*_UM.pdf` pair for FreeMASTER**, no
`Peripherals -> FreeMASTER` container in S32CT / EB tresos, and no
FreeMASTER entry in `mbdt_board_init.c` (INV-1). Do not fabricate an
RTD PDF glob-path for it.

The authoritative documentation for the FreeMASTER blocks and the
embedded-side driver lives with the FreeMASTER product itself (the
FreeMASTER Serial Communication Driver User Guide and the FreeMASTER
tool documentation), not in the RTD `doc` folders.

The **underlying transport peripheral does** have RTD documentation.
When FreeMASTER rides on LPUART (`connection_type = Serial`), consult
the Uart PDFs; when it rides on FlexCAN (`connection_type = CAN`),
consult the Can PDFs. `{family_root}` = `mbd_find_{family}_root()`;
glob RTD-version segments (filenames are uppercased):

```
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Uart_TS_T40D*_M70I*_R0\doc\
    RTD_UART_IM.pdf   RTD_UART_UM.pdf
{family_root}\{FAMILY}_RTD\SW*_RTD_R*_*.*.*\eclipse\plugins\Can_43_FLEXCAN_TS_T40D*_M70I*_R0\doc\
    RTD_CAN_43_FLEXCAN_IM.pdf   RTD_CAN_43_FLEXCAN_UM.pdf
```


### 3.2 Place the FreeMASTER blocks

- One `FreeMASTER Config` at model root (Sec. 2.1).
- Optional `FreeMASTER Recorder` blocks, each inside the fast
  subsystem whose rate should drive it.
- Optional `FreeMASTER Poll` block (see INV-4).

---

## 4. Runtime Data Flow

### 4.1 Poll-driven mode

```
Periodic rate
    +-- FreeMASTER Poll  ->  reads/writes memory,
                             drains recorder buffers,
                             answers host queries over
                             LPUART_N or CAN TX/RX obj
```

### 4.2 Interrupt-driven modes

```
Peripheral IRQ (LPUART_N or CAN RX/TX)
    -> RTD driver ISR
    -> FreeMASTER internal hook
    -> Short: enqueue bytes;  Long: full protocol handling
```

`Short Interrupt` still needs the `FreeMASTER Poll` block for
decoding; `Long Interrupt` does not (INV-4).

### 4.3 Recorder path (any mode)

```
Fast subsystem (rate X)
    +-- FreeMASTER Recorder(id, name, buff_size, timebase)
                (samples tracked variables at rate X or every
                 'timebase' ns)

Host drain:
    Host  --request-->  target (UART or CAN)
          <--samples--
```

`isr_prio` on `FreeMASTER Config` tags the priority the driver uses
when arming the peripheral's ISR; it does not enable an IRQ.

---

## 5. Configuration Correlation Matrix

| Setting | Owned by | Where in Simulink |
|---|---|---|
| Transport type | `FreeMASTER Config` | `connection_type` |
| LPUART instance | S32CT Peripherals -> Uart | `instance` |
| UART baud (actual) | S32CT Peripherals -> Uart | Must match `baudrate` on the block |
| CAN hardware objects | S32CT Peripherals -> Can -> CanHardwareObject_* | `cantxobj` / `canrxobj` |
| CAN TX / RX IDs | `FreeMASTER Config` | `cantxid` / `canrxid` |
| Service mode | `FreeMASTER Config` | `mode` |
| ISR priority | `FreeMASTER Config` | `isr_prio` |
| Recorder buffer / cadence | `FreeMASTER Recorder` | `buff_size` / `timebase` |

FreeMASTER is not represented in the `.mex` (INV-1); the `.mex`
carries only the underlying Uart / Can peripheral.

---

## 6. Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `instance` enum = `"No channels configured"` | S32CT Uart channel missing | Add LPUART channel |
| `cantxobj` / `canrxobj` empty | S32CT CanHardwareObject_* missing | Add TX + RX objects |
| Host connects but scopes never update (`Poll-driven` / `Short Interrupt`) | Auto-inserted `FreeMASTER Poll` never runs, or a user-added one sits in an unreached subsystem | Verify the periodic rate runs; place `FreeMASTER Poll` on a rate that ticks |
| Recorder stuck at zero samples | Recorder placed at model root instead of inside the fast subsystem | Move it into that subsystem |
| No traffic on the wire | Peripheral board-init missing | Add `Uart_Init` or `Can_43_FLEXCAN_Init` |
| Serial link garbled | `baudrate` on the block != S32CT Uart baud | Align both values |
| CAN frames sent but no response | Wrong `cantxid` / `canrxid` pairing with host | Match IDs; check `cantxidext` (29-bit vs 11-bit) |
| ISR never fires | Peripheral NVIC entry disabled | Enable LPUART_N IRQ (Serial) or CAN RX+TX IRQ (CAN) |
| Host cannot find a signal / parameter by name in the ELF | Embedded Coder packed it into a struct (`rtB.*`, `rtDW.*`, `rtP.*`) or optimised it away | Mark the signal / parameter with storage class `ExportedGlobal` (or `Volatile`) in the Simulink data object / Model Explorer so it lands in the ELF as a standalone symbol with the expected name |

---

## 7. Board-Specific Considerations

- Wire path follows the pins. Serial FreeMASTER usually reaches the
  host over OpenSDA / virtual-COM; CAN uses a transceiver plus
  external adapter. Pin routing lives in the config tool.
- Cross-family: the three-block set holds on every MBDT family that
  supports FreeMASTER. `MaskType` prefix and enum values follow the
  family's UART / CAN naming. Discover live.

---

## 8. Guardrails

- Never look for a FreeMASTER component in the config tool (INV-1).
- Never add `FreeMASTER_Init` to `mbdt_board_init.c` -- the block
  emits it. Only the underlying peripheral needs a board-init entry.
- Exactly one `FreeMASTER Config` block per model; never mix `Serial`
  and `CAN` on it.
- Match `baudrate` on the block to the S32CT Uart baud -- the block
  does not program the peripheral.
- `FreeMASTER Poll` and `FreeMASTER Recorder` are optional; see
  INV-4 and Sec 2.2 for placement rules.
- Never set `text` -- system-managed.
- Any variable to be observed / tuned from the FreeMASTER host must
  be emitted as a standalone symbol in the ELF. Give the
  corresponding Simulink signal, block output, or parameter a
  storage class of `ExportedGlobal` (or `Volatile`) via the data
  object / Model Explorer -- otherwise Embedded Coder folds it into
  `rtB` / `rtDW` / `rtP` structures (or optimises it away) and the
  host will not find it by name.
