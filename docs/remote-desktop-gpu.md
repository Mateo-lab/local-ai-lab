# Impact of the remote desktop on GPU power draw

Analysis done on the reference machine (RTX 3090, driver 595.99.02, Ubuntu 26.04).

## Summary

The system service `gnome-remote-desktop` (remote desktop) kept the RTX 3090 permanently in performance state
**P2 (compute)**, even at 0 % utilisation: **~123 W at idle** instead of **~17-23 W** (P8 state). Stopping the service
brought the GPU to P8 in less than 20 seconds. Measured difference: **~100 W continuously**, i.e. ~2.4 kWh/day.

## 1. Symptom

| Measurement | Value |
|---|---|
| Idle power (benchmark, `quick-smoke`) | 123.3 W, 44 °C |
| Idle power (benchmark, `power-sweep`) | 124.5 W |
| `nvidia-smi`, GPU at 0 % utilisation | P2, SM 1740 MHz, memory 9501 MHz, 124 W |
| Fan | 53 % at 44 °C |
| VRAM used without a loaded model | 777 to 1148 MB |

An idle RTX 3090 is normally in P8 (SM ~210 MHz) and draws 15 to 40 W.

## 2. Diagnosis

`nvidia-smi` listed processes marked `C+G` (graphics context **and** CUDA compute context):

| Process | Type | VRAM |
|---|---|---|
| `gnome-remote-desktop-daemon` | C+G | 344 MB |
| `ptyxis` (terminal) | C+G | 46 MB |
| `resources` (system monitor) | C+G | 31 MB |
| `gnome-shell` (×2), `Xwayland` | G | 112 / 161 / 6 MB |

Hypothesis: an open compute context prevents the driver from going back down to P8. The main suspect was the remote
desktop, the largest of these applications.

## 3. Test

The active service was the **system** version (not the user version):

```bash
systemctl --user is-active gnome-remote-desktop.service   # inactive
systemctl is-active gnome-remote-desktop.service          # active
```

Test done from an SSH session (so as not to be cut off), by stopping the service:

```bash
sudo systemctl stop gnome-remote-desktop.service
sleep 20
nvidia-smi --query-gpu=pstate,clocks.sm,power.draw --format=csv
```

| | State | SM | Power |
|---|---|---|---|
| Before | P2 | 1740 MHz | 122.7 - 123.0 W |
| After stopping the service | **P8** | **210 MHz** | **17.2 - 23.3 W** |

**Conclusion: stopping this service is enough to bring the GPU back to real idle.** The difference is about
**100 W**. Cause established by the test; the exact mechanism (CUDA context / GPU encoding of the capture) is a probable
explanation, not verified in the service's code.

## 4. Cost

Assumptions: 100 W difference, machine on 24/7, electricity at €0.30/kWh (replace with your rate).

- 100 W × 24 h = **2.4 kWh/day**
- ≈ **€0.72/day**, ≈ **€260/year**
- With the remote desktop left on continuously. No cost while it is off.

## 5. Effect on the benchmark results

The `power-sweep` (49 measurements, qwen3.8:27b) was run **with the remote desktop active**.

- **Comparisons between power limits: valid.** Every level had the same conditions.
- **Absolute J/token value: slightly inflated.** It includes the GPU's background draw.
- **Measurement noise: plausibly increased** (median CV 9 %, smallest detectable difference ~10.5 %).
- **Idle power measurement: wrong** (124.5 W instead of ~20 W).

Conclusions of the `power-sweep` (unchanged): 300 W is the best compromise (−9 % generation speed, −10 % energy per
token), and below 250 W you lose on every count. A confirmation experiment (`power-confirm`, 15 repetitions at 350 /
300 / 250 W) is planned **with the remote desktop off**.

## 6. Options

| Option | Effect | Command |
|---|---|---|
| Off by default, started on demand | full saving, started over SSH | `lab desktop on` / `lab desktop off` |
| Not started at boot | same after a reboot | `sudo systemctl disable gnome-remote-desktop.service` |
| Always on | comfort, ~100 W more continuously | none |
| Another remote access tool | to evaluate: some also keep a compute context | not verified |

Prerequisite for the first two options: an **SSH fallback access** (`openssh-server`, VPN access from outside). Never
stop the service from a terminal opened *inside* the remote desktop: the session gets cut.

## 7. Reproducible test procedure

1. Connect over SSH from another device (not through the remote desktop).
2. Note the state: `nvidia-smi --query-gpu=pstate,clocks.sm,power.draw --format=csv`.
3. Stop the service: `sudo systemctl stop gnome-remote-desktop.service`, wait 20 s, read the state again.
4. If the GPU stays in P2: list the remaining compute contexts
   `nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv`.
5. Restore: `sudo systemctl start gnome-remote-desktop.service`.

## 8. Limits and unverified points

- A single machine, a single driver (595.99.02). Another driver or another version of the service may behave
  differently.
- The precise mechanism (CUDA or NVENC in the service) is not confirmed; only the correlation "service stopped → P8" is
  measured.
- `ptyxis` and `resources` also hold a `C+G` context. Their effect alone was not tested; the test shows they are not
  enough to keep the GPU in P2 when the remote desktop is stopped (whether they were open or not was not noted).
- The yearly cost entirely depends on the assumed rate and uptime.
- The `power-sweep` had not been run again without the remote desktop when this note was written.

## Appendix: `power-sweep` results (remote desktop active)

qwen3.8:27b, 7 repetitions per level, 2048 tokens of filled context, 256 tokens generated, baseline 350 W.

| Limit | Generation (tok/s) | vs 350 W | Prefill (tok/s) | J/token | SM clock (MHz) |
|---|---|---|---|---|---|
| 350 W | 55.1 | baseline | 1,238 | 7.6 | 1,591 |
| 300 W | 50.3 | −9 % | 1,166 | 6.8 | 1,419 |
| 250 W | 40.7 | −26 % | 1,059 | 7.4 | 1,088 |
| 220 W | 29.8 | −46 % | 889 | 8.5 | 855 |
| 200 W | 24.8 | −55 % | 750 | 9.2 | 662 |
| 180 W | 19.0 | −66 % | 575 | 10.9 | 506 |
| 150 W | 9.6 | −83 % | 316 | 17.7 | 245 |

Generation speed follows the SM clock almost proportionally (≈ 0.035 to 0.039 tok/s per MHz).

## 9. Follow-up: service active without a session = GPU idle

The next day, `lab doctor` found the `gnome-remote-desktop` service **active** and yet the GPU in **P8 at 43 W**, with
no model loaded and no remote desktop session open (access over SSH only).

Consequence: it is probably not the service alone that keeps the GPU in P2, but an **open remote desktop session** (and
the CUDA context it creates). The first test (service stopped → P8) took place while that session was open: it did not
separate the two causes.

Not measured yet: the GPU state **during** an open session, then **after closing it** with the service active. To test:
open the remote desktop, read `nvidia-smi --query-gpu=pstate,power.draw --format=csv`, disconnect, read it again after
30 s. Meanwhile, the cautious rule remains: close the session when it is not used, and `lab desktop off` if you do not
use it at all. The `GpuStuckInP2AtIdle` alert reports the case.
