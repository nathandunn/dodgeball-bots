# Build calibration — 2026-09-14

**Test.** For each property, a team of specialists (0.6 in that property, 0.1 in the other four)
plays an Even team (0.2 each). Both sides use the Balanced personality; half the games are played
from each end of the court; headless at 20× with a 180 s cap. "Fair" means every specialist wins
about half the time: then a point of budget is worth the same wherever it is spent.

**Knobs.** `CURVE` (how much starving a property below 0.2 costs; < 1 is gentler) sets the mean
specialist win rate; the per-property `GAINS` (geometric mean pinned to 1) set the properties
against each other. `tools/calibrate.py tune` moves both by `1.3^(deviation/0.15)` per round;
24-game rounds turned out too noisy (±10 points), so the tuner's rounds were averaged and then
checked with 60-game probes (±6.4 points one sigma).

## What had to change in the game before any gains could balance it

| finding | fix |
|---|---|
| Every specialist lost (10–40 %) under the first mapping (0.6 → skill 1.0, 0.1 → 0.25): four small losses outweighed one big gain | skill linear in the property (0.6 → 1.5), plus `CURVE` below the midpoint |
| Aim was worth nothing (0 %): an alert dodger escapes any ball, and hits land on players who did not see the throw, where precision does not matter | the sidestep accelerates from standing (a fast ball beats a slow reaction); accurate throws go knee-high (hard to catch); a clean release is harder to notice (`disguise` up to 0.9); lead from smoothed velocity scaled by aim; the accurate throw from range while the wild must walk in close |
| Hands rarely mattered (blocks are rare) | a held ball absorbs hits at 0.45 × block skill even when not planned; longer reach for loose balls |
| Catches were 30 % of throws | catch wish and success reduced for fast and for low balls |

## Probes with the shipped settings

`GAINS = {speed 0.91, arm 0.58, aim 5.0, hands 0.74, dodge 0.45}`, `CURVE = 0.31` (the mean of
the last two 60-game probes below; aim sits at the gain cap — its levers are saturated, so it is
the property most likely to still be a touch cheap).

| property | probe 7 (gains .88/.57/5/.77/.47, curve .30) | probe 8 (gains .95/.60/5/.72/.44, curve .32) |
|---|---|---|
| speed | 50.0 % | 58.3 % |
| arm | 51.7 % | 44.2 % |
| aim | 46.7 % | 45.0 % |
| hands | 58.3 % | 51.7 % |
| dodge | 58.3 % | 56.7 % |

60 games each; average game 29–36 s. Everything is inside ±9 points of even, which is within
about 1.4 sigma of the measurement itself.

## Earlier rounds (24 games, noisy)

tune 2 → gains {speed 1.0, arm 0.87, aim 1.9, hands 0.65, dodge 0.93} curve 0.41: aim 33 %
tune 3 rounds 1–4 → aim climbed to the 3.0 cap and stayed at 25–45 %; dodge 42–63 %;
the cap was lifted to 5 and aim's disguise and range levers widened before the final probes.

Re-run: `GODOT=godot tools/calibrate.py probe --games 60` (about 8 minutes).
