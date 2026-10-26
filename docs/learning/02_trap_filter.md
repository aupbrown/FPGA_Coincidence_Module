# The trapezoidal filter, from scratch

Goal: turn each detector pulse into **one number proportional to its energy**, cleanly enough
that pulses of the same energy all land in the same histogram bin.

## 1. What a detector pulse looks like

A radiation interaction deposits charge Q in the detector. The preamp collects it quickly (the
**rise**) and then the charge leaks away through a resistor: an **exponential decay**.
In discrete time, sample n, with clock period T and decay time τ:

```
x[n] = A · αⁿ         for n ≥ 0,      α = e^(−T/τ)
```

`pulse_gen.vhd` builds exactly this with integers. Each clock the level loses 1/32 of itself:

```
level ← level − level/32       →   α = 1 − 2⁻⁵ = 31/32,   τ ≈ 32 clocks = 0.96 µs
```

The **height A is proportional to the energy**. So why not just take the maximum sample? Because
a real signal has noise on every sample, the peak sits on the tail of earlier pulses, and the
rise time varies. The trapezoidal filter averages over many samples and removes the tail.

## 2. Step 1: the step-input trapezoid (the workshop's Eq. 1)

Start with the simplest pulse, a **step** of height A at n = 0 (a preamp with infinite τ).

**Difference over K samples:** `d1[n] = x[n] − x[n−K]`.
For a step that is A for exactly K samples (n = 0 … K−1), then 0. The step became a
**rectangle** of width K.

**Difference again, over L samples:** `d2[n] = d1[n] − d1[n−L]`.
A positive rectangle at n = 0 … K−1 and a negative one at n = L … L+K−1.

**Accumulate (a running sum):** `y[n] = y[n−1] + d2[n]`.
- n = 0 … K−1: adds A per clock → ramps up to **K·A**
- n = K … L−1: adds 0 → **flat top at K·A**  (L − K samples long; needs L > K)
- n = L … L+K−1: subtracts A per clock → back down to 0

That is the trapezoid: rise K, flat L − K, fall K. **Its height K·A is the energy.** Written out in one line:

```
y[n] = y[n−1] + x[n] − x[n−K] − x[n−L] + x[n−L−K]          (workshop Eq. 1)
```

> Work it on paper for K = 3, L = 5, A = 1: write x, d1, d2, y in rows for n = −1 … 10.

**Why it averages noise:** at the flat top, y = (sum of the last K samples) − (sum of K samples from L
earlier). Each energy uses 2K samples instead of one. A bigger K means less noise but a longer pulse,
so more pile-up. That is the main trade-off in choosing K.

## 3. Step 2: exponential pulses and pole-zero correction

Feed the exponential A·αⁿ into the step filter and the "flat top" isn't flat: x keeps decaying, so
y sags and then undershoots below zero. The fix is to **turn the exponential back into a step first**.

The exponential obeys `x[n] = α·x[n−1]` for n > 0. So

```
x[n] − α·x[n−1] = A at n = 0,   and 0 for every later n
```

That is a single spike, A·δ[n] (this is "deconvolution"). Accumulate it and you get A·u[n], a step. So:
**deconvolve, accumulate (back to a step), then accumulate again (the trapezoid).** The order
of these linear steps can be swapped, and the workshop's `trap_exp` does the two differences first:

```
d1[n]  = x[n]  − x[n−K]
d2[n]  = d1[n] − d1[n−L]
p[n]   = d2[n] − α·d2[n−1]          ← pole-zero correction
acc1   = acc1 + p                   ← exponential → step  (gives the bipolar rectangles)
acc2   = acc2 + acc1                ← rectangles → trapezoid, height K·A
```

This is the second picture on slide 3 of `Trap_Filters.pdf`.

## 4. Making it exact in integer hardware

α = 31/32 isn't an integer. Multiply the whole p line by 2⁵ = 32:

```
32·p[n] = 32·d2[n] − 31·d2[n−1] = (d2[n] << 5) − (d2[n−1] << 5) + d2[n−1]
```

That's shifts and adds only, with no multiplier and no rounding. `trap_filter.vhd` computes this scaled p,
so acc2 is 32 × the trapezoid, and the output shifts right by 5 at the end.

**Why the accumulators can wrap around safely:** two's-complement addition is exact *modulo 2³²*.
Intermediate overflow cancels out as long as the final answer fits. Ours peaks near
32 × 32 × 4095 ≈ 2²², far inside 32 bits.

**Why the output returns to exactly 0** after every pulse, so there's no drift: the sum of d2
over a whole pulse is zero, and so is its first moment (Σ n·d2[n]). That's because each
x sample enters d2 four times, with signs + − − + at shifts that cancel. Both accumulators therefore
end where they started.

## 5. The baseline problem (found by the model)

The derivation assumed x = 0 between pulses. Our ADC idles at **100**, and after a reset the filter's
delay lines hold 0. So at reset the filter sees a **step of 100 that never decays**. Section 3's
deconvolution of a step is a ramp, and the result is a permanent offset of

```
100 · K · L / 2^M = 100 · 32 · 56 / 32 = 5600    → +175 bins on every energy
```

The first model run showed every peak exactly 174 bins too high, which is how this was found. Fix:
**subtract the baseline before the filter** (`x = adc − BASELINE`, a register, default 100), and
reset the filter on CONTROL clear. An error of one count in BASELINE moves every energy
by K·L/2^M = 56, about 2 bins: try `python3 -m model.expected --baseline 101`. Real systems
measure the baseline continuously (baseline restoration), and this is why.

## 6. Choosing K and L for our pulses

| | value | why |
|---|---|---|
| M | 5 | matches `pulse_gen`'s decay; if they differ, the flat top tilts |
| K | 32 clocks | ≈ τ; long enough to average, short compared with the 512-clock period |
| L | 56 | flat top L − K = 24 clocks, longer than the slowest rise (20 clocks in set 1), so the top is reached and stays flat |
| energy | K·A ≤ 32 × 4095 | 17 bits; `conv_gain` = 5 divides by 32, so bin ≈ A |

If the rise is longer than the flat top, the filter never reaches K·A: the **ballistic deficit**. Try
it in the model by setting `rise` to 40 in `model/config.py` for one channel.

## 7. Check yourself

1. With K = 32, how many clocks after a pulse starts does the trap reach its flat top? (Count the
   5-register pipeline latency too.) Compare with `build/sim_out/trap_filter.csv`.
2. Why does the energy window in `energy_capture` need to be about L + 16 clocks long?
3. What happens to the histogram if two pulses arrive 20 clocks apart?
4. Why is the flat top for charge 2000 equal to 63,973 and not 64,000? (Hint: `pulse_gen` rounds
   its decay *up*, so its true α is a hair below 31/32.)
