#!/usr/bin/env python3
"""End-to-end check of the lining-up search on real WAV files.

Builds a small fake rehearsal in a temporary folder: a REAPER-style
recording and a WING-LIVE-style session (32-channel, 24-bit, split into two
chunk files), started at different moments, then runs tools/align_wavs.lua
on them and checks the offset comes back to the exact sample. Nothing is
written into the repository; the files vanish when the check ends.

    python3 tools/test_align_wavs.py

Needs numpy and a `lua` on PATH. Not run in CI, because of numpy.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import tempfile

import numpy as np

RATE = 48000
REPO = pathlib.Path(__file__).resolve().parent.parent


def write_wav(path: pathlib.Path, data: np.ndarray) -> None:
    """data: frames x channels, floats in -1..1, written as 24-bit PCM."""
    frames, channels = data.shape
    ints = np.clip(np.round(data * 8388607), -8388608, 8388607).astype("<i4")
    raw = ints.reshape(-1).view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
    block = channels * 3
    fmt = (b"fmt " + (16).to_bytes(4, "little") + (1).to_bytes(2, "little")
           + channels.to_bytes(2, "little") + RATE.to_bytes(4, "little")
           + (RATE * block).to_bytes(4, "little") + block.to_bytes(2, "little")
           + (24).to_bytes(2, "little"))
    body = b"WAVE" + fmt + b"data" + len(raw).to_bytes(4, "little") + raw
    path.write_bytes(b"RIFF" + len(body).to_bytes(4, "little") + body)


def kick_track(seconds: float, seed: int) -> np.ndarray:
    """A kick drum mic: low sine thumps with a click, at human timing.
    Mostly low frequency, which is the hard case for sample accuracy."""
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    x = rng.normal(0, 0.002, n)
    t = np.arange(int(0.35 * RATE)) / RATE
    at = 0
    while at < n:
        f = 55 + rng.uniform(-3, 3)
        hit = np.sin(2 * np.pi * f * t) * np.exp(-t * 9) * rng.uniform(0.3, 0.9)
        hit[:96] += rng.normal(0, 0.3, 96) * np.exp(-np.arange(96) / 20)
        end = min(n, at + len(hit))
        x[at:end] += hit[: end - at]
        at += int(RATE * rng.uniform(0.35, 0.75))
    return x


def run(ref: pathlib.Path, ref_ch: int, chunks: list[pathlib.Path], sd_ch: int,
        seconds: float, rng: float, at: float) -> str:
    out = subprocess.run(
        ["lua", "tools/align_wavs.lua", str(ref), str(ref_ch),
         ",".join(str(c) for c in chunks), str(sd_ch), str(seconds), str(rng), str(at)],
        cwd=REPO, capture_output=True, text=True)
    return (out.stdout + out.stderr).strip()


def main() -> int:
    failures = 0
    performance = kick_track(20, 1)          # what the kick mic heard
    overheads = kick_track(20, 2) * 0.5      # something else entirely
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        cases = [
            # name, REAPER started at, SD started at (samples into the
            # performance), reference channel count and channel, SD channel
            ("SD started first, kick on channel 1", 160_000, 100_747, 1, 1, 1),
            ("SD started second, signal on channel 17, stereo reference",
             60_000, 151_111, 2, 2, 17),
        ]
        for name, ref_start, sd_start, ref_chans, ref_ch, sd_ch in cases:
            ref_len = 12 * RATE
            ref = np.zeros((ref_len, ref_chans))
            ref[:, ref_ch - 1] = performance[ref_start:ref_start + ref_len]
            if ref_chans > 1:
                ref[:, 0] = overheads[ref_start:ref_start + ref_len]
            ref_path = tmp / "reaper.wav"
            write_wav(ref_path, ref)

            sd_len = 12 * RATE
            rng = np.random.default_rng(5)
            sd = rng.normal(0, 0.05, (sd_len, 32))
            sd[:, 1] = overheads[sd_start:sd_start + sd_len]
            # The console's own preamp tap: quieter, its own noise.
            sd[:, sd_ch - 1] = (performance[sd_start:sd_start + sd_len] * 0.7
                                + rng.normal(0, 0.001, sd_len))
            split = 250_001                  # chunk boundary, deliberately odd
            chunks = [tmp / "00000001.wav", tmp / "00000002.wav"]
            write_wav(chunks[0], sd[:split])
            write_wav(chunks[1], sd[split:])

            expected = ref_start - sd_start
            # Start the stretch 3 s in, so the SD session covers it at the
            # true offset either way round.
            line = run(ref_path, ref_ch, chunks, sd_ch, 6, 3, 3)
            m = re.match(r"offset (-?\d+) samples.*confidence (\w+)", line)
            ok = bool(m) and int(m.group(1)) == expected and m.group(2) == "high"
            print(f"{'ok  ' if ok else 'FAIL'} {name}: expected {expected}, {line}")
            failures += not ok

            # The same reference against the wrong channel must not match.
            line = run(ref_path, ref_ch, chunks, 3, 6, 3, 3)
            ok = "confidence low" in line
            print(f"{'ok  ' if ok else 'FAIL'} {name}, wrong channel refused: {line}")
            failures += not ok
    print("all passed" if failures == 0 else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
