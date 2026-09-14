#!/usr/bin/env python3
"""Calibrate PlayerBuild.GAINS so that a point spent on any property is worth about the same.

For each property k, a team of specialists (0.6 in k, 0.1 in the rest) plays N games against an
even team (0.2 everywhere), both with the Balanced personality, mirrored across sides. If the
specialists win too often the gain for k is too strong (or the others too weak); the gains are
nudged and the sweep repeats until every specialist sits inside 50 +- TOL.

Usage:
  tools/calibrate.py probe  [--games 20]           # measure with the gains in build.gd
  tools/calibrate.py tune   [--games 24 --rounds 6] # iterate and rewrite GAINS in build.gd
  tools/calibrate.py presets [--games 20]          # every build preset vs Even
"""
import argparse, json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = os.environ.get("GODOT", "godot")
PROPS = ["speed", "arm", "aim", "hands", "dodge"]
BUILD_GD = os.path.join(ROOT, "scripts", "build.gd")
REPORT = os.path.join(ROOT, "tools", "calibration_report.md")


def specialist(k, hi=0.6):
    lo = (1.0 - hi) / 4.0
    return ",".join("%.3f" % (hi if p == k else lo) for p in PROPS)


def run(red_build, blue_build, games, gains, seed, persona="Balanced", cap=180):
    args = [GODOT, "--headless", "--path", ROOT, "--",
            "--sim=%d" % games, "--red=%s" % persona, "--blue=%s" % persona,
            "--redbuild=%s" % red_build, "--bluebuild=%s" % blue_build,
            "--seed=%d" % seed, "--cap=%d" % cap,
            "--gains=" + ",".join("%s:%.4f" % (k, v) for k, v in gains.items())]
    out = subprocess.run(args, capture_output=True, text=True, timeout=3600).stdout
    for line in out.splitlines():
        if line.startswith("SUMMARY "):
            return json.loads(line[8:])
    raise RuntimeError("no SUMMARY in output:\n" + out[-2000:])


def winrate(k, games, gains, seed, hi=0.6):
    """Specialist-in-k win rate vs Even, mirrored (half the games on each side)."""
    half = max(games // 2, 1)
    a = run(specialist(k, hi), "Even", half, gains, seed)
    b = run("Even", specialist(k, hi), half, gains, seed + 1000)
    wins = a["wins"][0] + b["wins"][1]
    draws = a["draws"] + b["draws"]
    total = a["games"] + b["games"]
    dur = (a["avg_duration"] * a["games"] + b["avg_duration"] * b["games"]) / total
    return (wins + 0.5 * draws) / total, dur, total


def read_gains():
    src = open(BUILD_GD).read()
    m = re.search(r"const GAINS := \{([^}]*)\}", src)
    gains = {}
    for k, v in re.findall(r'"(\w+)":\s*([0-9.]+)', m.group(1)):
        gains[k] = float(v)
    gains["curve"] = float(re.search(r"const CURVE := ([0-9.]+)", src).group(1))
    return gains


def write_gains(gains):
    src = open(BUILD_GD).read()
    line = "const GAINS := {" + ", ".join('"%s": %.3f' % (k, gains[k]) for k in PROPS) + "}"
    src = re.sub(r"const GAINS := \{[^}]*\}", line, src)
    src = re.sub(r"const CURVE := [0-9.]+", "const CURVE := %.3f" % gains["curve"], src)
    open(BUILD_GD, "w").write(src)


def probe(games, gains, seed):
    rows = []
    for k in PROPS:
        w, dur, n = winrate(k, games, gains, seed)
        rows.append((k, w, dur, n))
        print("  %-6s specialist vs Even: %5.1f%% over %d games (avg %ds)" % (k, w * 100, n, dur), flush=True)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["probe", "tune", "presets"])
    ap.add_argument("--games", type=int, default=20)
    ap.add_argument("--rounds", type=int, default=6)
    ap.add_argument("--tol", type=float, default=0.06)
    ap.add_argument("--seed", type=int, default=100)
    ap.add_argument("--step", type=float, default=1.2)
    a = ap.parse_args()
    gains = read_gains()
    print("gains:", gains)
    t0 = time.time()
    if a.mode == "probe":
        probe(a.games, gains, a.seed)
    elif a.mode == "presets":
        from itertools import count
        for name in ["Sprinter", "Cannon", "Sniper", "Glue", "Ghost", "Thrower", "Keeper"]:
            half = max(a.games // 2, 1)
            x = run(name, "Even", half, gains, a.seed)
            y = run("Even", name, half, gains, a.seed + 1000)
            w = (x["wins"][0] + y["wins"][1] + 0.5 * (x["draws"] + y["draws"])) / (x["games"] + y["games"])
            print("  %-8s vs Even: %5.1f%%" % (name, w * 100), flush=True)
    else:
        history = []
        for r in range(a.rounds):
            print("round %d" % (r + 1), flush=True)
            rows = probe(a.games, gains, a.seed + r * 7)
            history.append((dict(gains), rows))
            worst = max(abs(w - 0.5) for _, w, _, _ in rows)
            if worst <= a.tol:
                print("within tolerance")
                break
            # two knobs: CURVE sets how much specialising costs overall (mean win rate -> 50%),
            # the per-property gains sort out which properties are worth more than the others.
            mean = sum(w for _, w, _, _ in rows) / len(rows)
            gains["curve"] = max(0.25, min(1.6, gains["curve"] * a.step ** ((mean - 0.5) / 0.12)))
            for k, w, _, _ in rows:
                gains[k] *= a.step ** (-(w - mean) / 0.15)
            gm = 1.0
            for k in PROPS:
                gm *= gains[k]
            gm **= 1.0 / len(PROPS)
            for k in PROPS:
                gains[k] = max(0.3, min(5.0, gains[k] / gm))
            print("  new gains:", {k: round(v, 3) for k, v in gains.items()}, flush=True)
            write_gains(gains)
        with open(REPORT, "w") as fh:
            fh.write("# Build calibration\n\nSpecialist (0.6 in one property, 0.1 in the rest) vs Even (0.2 each), Balanced personality, mirrored sides.\n\n")
            for i, (g, rows) in enumerate(history):
                fh.write("## Round %d - gains %s\n\n| property | specialist win rate | games | avg game |\n|---|---|---|---|\n" % (i + 1, json.dumps({k: round(v, 3) for k, v in g.items()})))
                for k, w, dur, n in rows:
                    fh.write("| %s | %.1f%% | %d | %ds |\n" % (k, w * 100, n, dur))
                fh.write("\n")
            fh.write("Final gains written to scripts/build.gd: %s\n" % json.dumps({k: round(v, 3) for k, v in gains.items()}))
        print("report:", REPORT)
    print("done in %ds" % (time.time() - t0))


if __name__ == "__main__":
    main()
