"""Build numeric ROM data for the proposed 256-point fixed-point DFT.

This creates initialization data only. It does not generate Anlogic IP or RTL.
Run with the bundled Python runtime from any directory.
"""

from pathlib import Path
import hashlib
import json
import math
import re
import struct


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "spectrum"
N = 256


def q15(value):
    """Round to nearest, ties away from zero, then saturate signed Q1.15."""
    scaled = value * 32768
    rounded = math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)
    return max(-32768, min(32767, rounded))


def signed16(value):
    return value - 65536 if value & 0x8000 else value


def emit(stem, width, words):
    digits = (width + 3) // 4
    (OUT / "td_init").mkdir(parents=True, exist_ok=True)
    hex_text = "".join(f"{word:0{digits}X}\n" for word in words)
    (OUT / f"{stem}.hex").write_text(hex_text, encoding="ascii")
    packed = b"".join(word.to_bytes(width // 8, "little") for word in words)
    (OUT / f"{stem}.bin").write_bytes(packed)
    mif = [f"WIDTH = {width};", f"DEPTH = {len(words)};",
           "ADDRESS_RADIX = HEX;", "DATA_RADIX = HEX;", "CONTENT BEGIN"]
    mif.extend(f"{address:02X} : {word:0{digits}X};" for address, word in enumerate(words))
    mif.append("END;")
    target = OUT / "td_init" / f"{stem}.mif"
    target.write_text("\n".join(mif) + "\n", encoding="ascii")
    parsed = [(int(a, 16), int(v, 16)) for a, v in re.findall(
        r"^([0-9A-F]+)\s*:\s*([0-9A-F]+);", target.read_text(), re.M)]
    assert parsed == list(enumerate(words))
    assert [int(v, 16) for v in (OUT / f"{stem}.hex").read_text().split()] == words
    assert list(struct.unpack("<" + ("H" if width == 16 else "I") * N,
                              (OUT / f"{stem}.bin").read_bytes())) == words


def main():
    cosines = [q15(math.cos(2 * math.pi * i / N)) for i in range(N)]
    negative_sines = [q15(-math.sin(2 * math.pi * i / N)) for i in range(N)]
    # Symmetric Hann: both endpoints are zero. It is not the periodic N-denominator variant.
    window = [q15(0.5 - 0.5 * math.cos(2 * math.pi * i / (N - 1))) for i in range(N)]
    twiddle = [((c & 0xFFFF) << 16) | (s & 0xFFFF)
               for c, s in zip(cosines, negative_sines)]
    emit("dft_twiddle_q15_32x256", 32, twiddle)
    emit("hann_q15_16x256", 16, window)
    assert window[0] == window[-1] == 0
    assert window == window[::-1]
    assert [twiddle[i] for i in (0, 64, 128, 192)] == [
        0x7FFF0000, 0x00008000, 0x80000000, 0x00007FFF]
    error = max(max(abs(cosines[i] / 32768 - math.cos(2 * math.pi * i / N)),
                    abs(negative_sines[i] / 32768 + math.sin(2 * math.pi * i / N)))
                for i in range(N))
    assert error <= 1 / 32768 + 1e-12
    # A numerical signal check exercises sign, packed-word order and phase addressing.
    samples = [round((1 << 21) * math.sin(2 * math.pi * 13 * i / N)) for i in range(N)]
    weighted = [(sample * w) >> 15 for sample, w in zip(samples, window)]
    energies = []
    for k in range(N // 2):
        real = sum(weighted[n] * signed16(twiddle[(k * n) % N] >> 16) for n in range(N))
        imag = sum(weighted[n] * signed16(twiddle[(k * n) % N] & 0xFFFF) for n in range(N))
        energies.append(real * real + imag * imag)
    peak = max(range(1, N // 2), key=lambda k: energies[k])
    assert peak == 13
    files = []
    for path in sorted(OUT.glob("*.bin")) + sorted(OUT.glob("*.hex")) + sorted((OUT / "td_init").glob("*.mif")):
        raw = path.read_bytes()
        files.append({"path": path.relative_to(OUT).as_posix(), "bytes": len(raw),
                      "sha256": hashlib.sha256(raw).hexdigest()})
    report = {
        "purpose": "ROM initialization data for architecture planning; not generated IP or RTL validation",
        "dft_length": N, "sample_rate_hz": 48000, "bin_spacing_hz": 48000 / N,
        "twiddle": {"width": 32, "depth": N,
                    "high_16": "signed Q1.15 cos(2*pi*address/256)",
                    "low_16": "signed Q1.15 -sin(2*pi*address/256)",
                    "phase_address": "(bin_index * sample_index) mod 256",
                    "max_absolute_error": error},
        "window": {"width": 16, "depth": N,
                   "formula": "Q1.15(0.5 - 0.5*cos(2*pi*n/255)), n=0..255",
                   "range": [min(window), max(window)]},
        "checks": ["MIF address continuity and HEX/BIN equality",
                   "twiddle quadrants and quantization error",
                   "Hann symmetry and zero endpoints",
                   "windowed 2437.5 Hz sine has dominant DFT bin 13"],
        "numerical_tone_peak_bin": peak, "files": files,
    }
    (OUT / "validation_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"generated_files": len(files), "checks_passed": len(report["checks"]),
                      "peak_bin": peak, "output": str(OUT)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
