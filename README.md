# Dodgeball Bots

Six-a-side elimination dodgeball as a spectator AI sim (Godot 4, 3D, web export). Two things
make each player: a **personality** (how they play) and a **build** (what they are). The five
build properties always add up to 1 — spend it on speed, arm, aim, hands or dodge, and the
simulation decides whether it was well spent. Part of the Precog sim suite.

Live: https://dodgeball.apps.precogsoftwareservices.com

## Rules as played

Based on the National Dodgeball League / USA Dodgeball rule sets:

- 60 × 30 ft court (18.3 × 9.1 m), centre line, 4 ft neutral zone, attack lines 10 ft from
  centre. Red plays x < 0, Blue x > 0; nobody crosses the centre line.
- Six 8.5-inch balls on the centre line. **Opening rush**: the three fastest on each side sprint
  for the three balls on their right; a ball taken off the line must be carried behind the
  attack line before it can be thrown.
- A ball is **live** from the hand until it touches the floor, a wall, or a player. A live
  ball that hits you puts you **out**; you walk to the queue on your sideline.
- **Catch** a live ball and the thrower is out and the first player in your out-queue comes
  back in. Fumble the catch and you are out.
- **Block** with a ball in hand and the throw glances off (still live); lose your grip and you
  are out.
- **Ten-second throw clock** on every held ball; a side sitting on four of the six balls for
  five seconds has to let one go.
- Balls that roll out of bounds come back onto the sideline of the side they left from.
- Last team standing wins. Nothing starts by itself: the results panel asks.

## Builds — five numbers that add up to 1

| property | what it does |
|---|---|
| speed | running speed (rush, fetching, getting to the line) |
| arm | throw speed — a faster ball leaves less time to dodge, catch or block |
| aim | error cone; the accurate throw at the knees (hard to catch) with a clean release (harder to read) |
| hands | catching and blocking, hanging on when a ball hits the one you hold, reach for loose balls |
| dodge | reaction time, sidestep acceleration, noticing the ball at all |

`PlayerBuild.skill()` maps a property to a 0..1 skill: 0.2 (an even split) is the middle, 0.4
the designed top of each span, 0 the floor. Below the middle the fall-off follows `CURVE`
(< 1 is gentler); each property has a `GAIN` that scales its swing. Both are **calibrated**
(`tools/calibrate.py tune`) so that a team of specialists — 0.6 in one property, 0.1 in the
rest — beats an even team about half the time whichever property it is. The report of the
last calibration is in `tools/calibration_report.md`.

Presets: Even, Sprinter, Cannon, Sniper, Glue (hands), Ghost (dodge), Thrower, Keeper, Random.
The sliders in the Teams panel keep the total at 1: push one up and the others give way.

## Personalities

aggression (walk up and throw early), caution (hang back, dodge early), catching (go for the
catch rather than the dodge), teamwork (volley with a mate, pile onto one target), patience
(hold for a clean shot), bully (pick on the weak and the unarmed). Presets: Balanced, Gunner,
Catcher, Dodger, Wall, Tactician, Random.

## Running

Desktop: open the project in Godot 4.4+ and run. Web: `GODOT=godot ./build.sh` exports to
`dist/` (gzipped engine + pack), `Dockerfile` serves it with nginx.

Headless sims (20× speed, capped games):

    godot --headless --path . -- --sim=20 --red=Gunner --blue=Tactician \
        --redbuild=Cannon --bluebuild=0.2,0.2,0.2,0.2,0.2 --seed=1 --cap=180

    godot --headless --path . -- --aimtest=1 --react=1 --n=100 --dist=8 \
        --redbuild=Sniper --bluebuild=Ghost      # one thrower vs one dodger

    GODOT=godot tools/calibrate.py probe|tune|presets

Batch output ends with a `SUMMARY {...}` JSON line.

## Files

`scripts/build.gd` (PlayerBuild), `personality.gd`, `player.gd` (brain, throw, dodge, catch,
block), `ball.gd`, `court.gd`, `match_manager.gd` (rush, queues, possession rule, stats),
`hud.gd`, `camera_rig.gd`, `main.gd` (entry, headless modes). Everything is built in code;
the one scene file is empty but for the root.
