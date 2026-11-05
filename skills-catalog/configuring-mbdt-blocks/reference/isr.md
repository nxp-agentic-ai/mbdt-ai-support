# ISR Handler -- MBDT Block Reference

Retrieval-optimized reference for AI agents configuring the
`Hardware_Interrupt_Handler` block on any NXP MBDT-targeted Simulink
model. Covers `MaskType = s32k3_isr_handler`, the `irqGroup` / `irqHandlers`
enums, the simulation-mode flag, the callback string pattern, and the
relationship between this block and every peripheral that exposes interrupt
handlers. Verified on S32K3.

The `Hardware_Interrupt_Handler` block is the **single gateway through which
interrupt service routines (ISRs) are registered and invoked in MBDT
models**. It does not emit code for a specific peripheral; instead it names
one interrupt handler (defined and owned by an RTD driver) and invokes a
user-supplied Simulink function at the end of that handler. Placing this
block in a model causes the code generator to install the named ISR in the
vector table and insert a call-out to the model's callback subsystem.

---

## 1. Peripheral Overview

Adding interrupt handling to a model means placing three artefacts:

| # | Artefact | Where it lives | Owner |
|---|---|---|---|
| 1 | S32CT / EB tresos project: interrupt-source enabled in the relevant peripheral (e.g. ADC end-of-conversion interrupt ON) | External | External config tool |
| 2 | `Hardware_Interrupt_Handler` block with correct `irqGroup` and `irqHandlers` | Simulink model | This skill |
| 3 | Callback subsystem (a Function-Call Subsystem) triggered by the block | Simulink model | Application designer |

**Silent failure modes if any is missing:**

- Missing (1): `irqHandlers` enum shows `"No interrupt handlers configured"`;
  the interrupt is never routed to the model.
- Missing (2): no ISR installed; peripheral fires an unhandled interrupt causing
  a hard fault or silently ignored event.
- Missing (3): the block compiles but the ISR does nothing useful; the function
  call output is unconnected.

**Key characteristics:**

- **One block per interrupt handler.** Each named handler (`irqHandlers`
  entry) requires a separate `Hardware_Interrupt_Handler` block.
- **Not peripheral-specific.** A single block type serves ADC, CAN, GPT,
  IPCF, ICU, PWM, SPI, UART, Fee, Mem, MCL, I2C, and MotorControl groups.
- **irqSim flag.** When `irqSim = true` the block fires its Function-Call
  output during Simulink simulation (triggered by a software event); when
  `false` (default) the output fires only in generated code (hardware ISR).

---

## 2. The `Hardware_Interrupt_Handler` Block -- Complete Behavioral Model

**One block = one named ISR.** `MaskType = s32k3_isr_handler`.

### 2.1 Parameter surface

| Name | Type | Semantics |
|---|---|---|
| `irqGroup` | enum | Peripheral group to which the interrupt belongs (see Sec. 2.2) |
| `irqHandlers` | enum | Specific ISR name within the chosen group; sentinel = `"No interrupt handlers configured"` |
| `irqSim` | boolean | When `true`: fire Function-Call output in simulation; when `false` (default): hardware-only |
| `blockCbk` | string | System-managed post-change callback -- **never set** |
| `text` | string | System-managed cache -- **never set** |

**Selection ordering:** set `irqGroup` first, then `irqHandlers`. Changing
`irqGroup` refreshes the `irqHandlers` enum. Setting `irqHandlers` before
`irqGroup` leaves it on a stale slot.

### 2.2 The `irqGroup` enum

Values read live from S32K3 RTD (R2026a):

`Adc | Can | Fee | Gpt | I2c | Icu | Ipcf | Mcl | Mem | MotorControl | Pwm | Spi | Uart`

Each group corresponds to an RTD driver module. The `irqHandlers` entries
available after selecting a group are the ISR names that the corresponding
RTD module declares and that the config tool has enabled.

**Always read `irqGroup.Enum` live** via
`get_param(<blk>,'DialogParameters').irqGroup.Enum`. The set of groups can
change across RTD versions and platforms.

### 2.3 The `irqHandlers` enum

Entries are populated by the MBDT toolbox from the RTD configuration. They
follow the naming convention of the RTD driver (e.g. `ADC_0_ISR`,
`LPUART_0_TX_ISR`, `CAN_0_MB_00_03_ISR`). The sentinel value
`"No interrupt handlers configured"` appears when:

- The config tool has not enabled any interrupt for the selected group, **or**
- The S32CT / EB tresos project has not been linked to the model yet.

**Read live; never enumerate from memory.** ISR names are toolchain- and
config-specific.

### 2.4 Sentinel rules

| Resource | Sentinel | Action |
|---|---|---|
| `irqHandlers` | `"No interrupt handlers configured"` | Enable the relevant interrupt source in the S32CT peripheral configuration |

### 2.5 Block output

The block has one output port: a **Function-Call** trigger. Connect it to a
Function-Call Subsystem that implements the ISR service logic (e.g. read ADC
result, signal a semaphore, clear a CAN flag).

---

## 3. Required Block Catalog

| Block name | `MaskType` | Library | Role |
|---|---|---|---|
| `Hardware_Interrupt_Handler` | `s32k3_isr_handler` | `mbd_s32k3_isr_library` | Installs one named ISR and calls out to a Simulink function |

No init block is associated with this block itself; the peripheral it services
(e.g. ADC, CAN) must be initialized via its own Init call and board-init entry.

---

## 4. Configuration Workflow

### 4.1 Enable the interrupt in the config tool

For the target peripheral, open its configuration in S32CT / EB tresos and
enable the relevant interrupt source (e.g. ADC End-of-Conversion, CAN Rx
message buffer, GPT channel overflow). Without this step the `irqHandlers`
enum is empty.

Confirm via `nxp_s32ct_inspect(kind='instances')` that the peripheral module
is present and that interrupt-related settings are active.

### 4.2 Place the block

Add `Hardware_Interrupt_Handler` from `mbd_s32k3_isr_library`.

```matlab
% Discover library path
get_mbdt_toolbox('s32k3','blocks')

% Read live parameters
get_param('mbd_s32k3_isr_library/Hardware_Interrupt_Handler','DialogParameters')
```

### 4.3 Set irqGroup, then irqHandlers

```matlab
set_param(blk, 'irqGroup',   'Adc');          % example: ADC group
set_param(blk, 'irqHandlers','ADC_0_ISR');    % read live; do not hardcode
```

**Always set `irqGroup` before `irqHandlers`.**

### 4.4 Connect the output

Connect the Function-Call output port to a Function-Call Subsystem. The
subsystem receives control on every ISR invocation.

### 4.5 Simulation mode (optional)

Set `irqSim = true` if the subsystem must be exercised during Simulink
simulation (software-triggered). Leave at default (`false`) for production
use.

---

## 5. Initialize Function Pattern

This block requires **no initialization of its own**. The peripheral it
services (e.g. ADC, CAN) must have its own Init call in the Initialize
Function or board-init. The `Hardware_Interrupt_Handler` block takes effect
at code-generation time (vector table entry); no runtime init call is emitted
for the ISR block itself.

---

## 6. Runtime Data Flow

```
[Hardware event fires (e.g. ADC conversion complete)]
  RTD ISR (vector table) invoked by CPU
    --> Hardware_Interrupt_Handler block's generated ISR wrapper executes
    --> Function-Call output triggers the connected subsystem
    --> Subsystem runs ISR service logic (read result, set flag, etc.)
    --> Returns from ISR
```

During simulation (irqSim=true):
```
[Simulink step or manual trigger]
  Function-Call output fires
  --> Subsystem executes
```

---

## 7. Interrupt Dependencies

This block **is** the interrupt dependency mechanism. For each peripheral
that uses interrupts:

1. The peripheral block (e.g. `Adc`, `Can`, `Gpt`) is responsible for
   generating init/runtime code.
2. The `Hardware_Interrupt_Handler` block registers the ISR and provides
   the Function-Call trigger.

The two blocks are independent in the model graph; there is no signal
connection between them. The ISR fires asynchronously relative to the model's
step function.

---

## 8. Configuration Correlation Matrix

| Setting | Owned by | Where visible in Simulink |
|---|---|---|
| Interrupt source enable | Peripherals -> (ADC/CAN/etc.) in S32CT | `irqHandlers` enum (populated or sentinel) |
| ISR name / handler ID | RTD driver + config tool | `irqHandlers` enum entries |
| ISR group | RTD module structure | `irqGroup` enum |
| Simulation firing | Block parameter | `irqSim` boolean |
| ISR service logic | Function-Call Subsystem | Downstream subsystem content |

---

## 9. Common Usage Patterns

### Pattern 1: ADC end-of-conversion ISR

```matlab
% 1. Enable ADC interrupt in S32CT (Peripherals -> Adc -> channel -> interrupt ON)
% 2. Place Hardware_Interrupt_Handler
set_param(blk, 'irqGroup',    'Adc');
set_param(blk, 'irqHandlers', 'ADC_0_ISR');  % read live
% 3. Connect output to a Function-Call Subsystem that reads ADC result
%    using an Adc block with api_func=Adc_ReadGroup
```

### Pattern 2: CAN Rx ISR

```matlab
set_param(blk, 'irqGroup',    'Can');
set_param(blk, 'irqHandlers', 'CAN_0_MB_00_03_ISR');  % read live
% Connect to subsystem that calls Can_MainFunction or reads Rx buffer
```

### Pattern 3: IPCF shared-memory notification

```matlab
set_param(blk, 'irqGroup',    'Ipcf');
set_param(blk, 'irqHandlers', 'IPC_SHM_ISR');  % read live
% Connect to subsystem that calls ipc_shm_rx_cb or processes inbound data
```

---

## 10. Troubleshooting

| Symptom | Most likely root cause | Fix |
|---|---|---|
| `irqHandlers` = `"No interrupt handlers configured"` | Interrupt not enabled in config tool | Enable interrupt source in Peripherals section of S32CT for the target peripheral |
| ISR fires but subsystem does not execute | `irqSim = false` and running in simulation | Set `irqSim = true` for simulation testing, or use External mode |
| Hard fault at runtime | ISR vector installed but peripheral not initialized | Confirm peripheral Init call (board-init or Initialize Function) runs before the ISR can fire |
| Subsystem runs every model step instead of asynchronously | Wrong trigger type on subsystem | Ensure the downstream subsystem is a Function-Call Subsystem, not a periodic subsystem |
| Build error: undefined ISR symbol | RTD config tool did not generate the handler | Verify interrupt is enabled in S32CT; regenerate config; run `nxp_s32ct_validate` |

---

## 11. Board-Specific Considerations

- **S32K3:** `irqGroup` values cover `Adc|Can|Fee|Gpt|I2c|Icu|Ipcf|Mcl|Mem|MotorControl|Pwm|Spi|Uart`.
  `MaskType = s32k3_isr_handler`. ISR names follow the RTD naming convention
  (e.g. `ADC_0_ISR`, `LPUART_0_TX_ISR`).

---

## 12. Guardrails (ISR-handler-specific)

Generic block rules (no stubs, no invented names, interrupts only via the
ISR-handler block, `api_func` first, never set `text`) are in
[`../SKILL.md`](../SKILL.md); only ISR-handler-specific rules follow.

- **Set `irqGroup` before `irqHandlers`.** Changing the group refreshes the
  handler enum; setting the handler first leaves it on a stale slot.
- **Read ISR names from the live `irqHandlers` enum after setting
  `irqGroup`.** Names are toolchain-specific.
- **Use one block per ISR.** Do not reuse one block for multiple handlers.
- **Connect the Function-Call output.** An unconnected output compiles, but
  the ISR does nothing and the model reports an unconnected port.
- **Still initialize the peripheral.** This block installs the ISR only; the
  peripheral's own Init call (board-init entry or Initialize Function block)
  is still required.
