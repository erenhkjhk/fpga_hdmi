"""Build deterministic FPGA font/ROM data from installed fonts and the saved logo cutout.

This is an asset converter, not an RTL simulator. Requires Python 3 and Pillow.
The logo background extraction is a separately saved imagegen result; this script
only fits it to the target pixel grid and encodes the hardware pixel format.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version


CN_CHARS = "安路多媒体展示运行亮度对比轮播开状态显图片关加载转场错误"
STRINGS = {
    "slogan": "安路 FPGA 多媒体展示",
    "uptime_template": "运行 00:00:00",
    "parameters_template": "亮度:+00 对比:1.0x",
    "playback_template": "轮播:开 状态:显示",
    "image_index_template": "图片:00001/00001",
    "other_states": ["关", "加载", "转场", "错误"],
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def encode_mask(glyph: Image.Image) -> bytes:
    """Top row first, left byte first, most significant bit at the left."""
    width, height = glyph.size
    result = bytearray()
    for y in range(height):
        for x_base in range(0, width, 8):
            value = 0
            for bit in range(8):
                value = (value << 1) | int(bool(glyph.getpixel((x_base + bit, y))))
            result.append(value)
    return bytes(result)


def decode_mask(data: bytes, width: int, height: int = 16) -> Image.Image:
    glyph = Image.new("1", (width, height), 0)
    stride = width // 8
    for y in range(height):
        for x in range(width):
            if data[y * stride + x // 8] & (0x80 >> (x % 8)):
                glyph.putpixel((x, y), 255)
    return glyph


def write_byte_data(stem: Path, data: bytes) -> None:
    stem.with_suffix(".bin").write_bytes(data)
    stem.with_suffix(".hex").write_text(
        "".join(f"{value:02X}\n" for value in data), encoding="ascii"
    )


def write_td_mif(path: Path, width: int, values: list[int]) -> None:
    """Addressed MIF format documented in the installed TD 6.2 user guide."""
    path.parent.mkdir(parents=True, exist_ok=True)
    digits = (width + 3) // 4
    assert all(0 <= value < (1 << width) for value in values)
    lines = [f"WIDTH = {width};", f"DEPTH = {len(values)};",
             "ADDRESS_RADIX = HEX;", "DATA_RADIX = HEX;", "CONTENT BEGIN"]
    lines.extend(f"{address:04X} : {value:0{digits}X};" for address, value in enumerate(values))
    lines.append("END;")
    path.write_bytes(("\n".join(lines) + "\n").encode("ascii"))


def make_font_data(out: Path, ascii_path: Path, cn_path: Path) -> tuple[dict, list, list]:
    ascii_font = ImageFont.truetype(str(ascii_path), 13)
    cn_font = ImageFont.truetype(str(cn_path), 16, index=0)
    missing_shape = bytes(cn_font.getmask(chr(0x10FFFF), mode="1"))
    ascii_glyphs = []
    for code in range(128):
        glyph = Image.new("1", (8, 16), 0)
        if 33 <= code <= 126:
            draw = ImageDraw.Draw(glyph)
            draw.fontmode = "1"
            draw.text((0, 12), chr(code), font=ascii_font, fill=255, anchor="ls")
            if not glyph.getbbox():
                raise ValueError(f"Empty ASCII glyph: {code}")
        ascii_glyphs.append(glyph)

    cn_glyphs = []
    mapping = []
    for index, char in enumerate(CN_CHARS):
        if bytes(cn_font.getmask(char, mode="1")) == missing_shape:
            raise ValueError(f"Font does not contain {char}")
        glyph = Image.new("1", (16, 16), 0)
        draw = ImageDraw.Draw(glyph)
        draw.fontmode = "1"
        draw.text((0, 0), char, font=cn_font, fill=255)
        if not glyph.getbbox():
            raise ValueError(f"Empty Chinese glyph: {char}")
        cn_glyphs.append(glyph)
        mapping.append({
            "index": index,
            "character": char,
            "unicode": f"U+{ord(char):04X}",
            "rom_base_decimal": 2048 + index * 32,
            "rom_base_hex": f"0x{2048 + index * 32:04X}",
            "byte_count": 32,
        })

    ascii_data = b"".join(encode_mask(glyph) for glyph in ascii_glyphs)
    cn_data = b"".join(encode_mask(glyph) for glyph in cn_glyphs).ljust(4096, b"\x00")
    combined = (ascii_data + cn_data).ljust(8192, b"\x00")
    assert len(ascii_data) == 2048 and len(cn_data) == 4096 and len(combined) == 8192
    write_byte_data(out / "font_ascii_8x16", ascii_data)
    write_byte_data(out / "font_cn_16x16", cn_data)
    write_byte_data(out / "osd_font_8x8192", combined)

    # All previews below are decoded from packed bytes, not separate text rendering.
    ascii_glyphs = [decode_mask(ascii_data[i * 16:(i + 1) * 16], 8) for i in range(128)]
    cn_slots = [decode_mask(cn_data[i * 32:(i + 1) * 32], 16) for i in range(128)]
    ascii_atlas = Image.new("1", (128, 128), 0)
    cn_atlas = Image.new("1", (256, 128), 0)
    for index, glyph in enumerate(ascii_glyphs):
        ascii_atlas.paste(glyph, ((index % 16) * 8, (index // 16) * 16))
    for index, glyph in enumerate(cn_slots):
        cn_atlas.paste(glyph, ((index % 16) * 16, (index // 16) * 16))
    ascii_atlas.save(out / "font_ascii_8x16.png")
    cn_atlas.save(out / "font_cn_16x16.png")

    font_map = {
        "schema_version": 1,
        "width_bits": 8,
        "depth_words": 8192,
        "mask": "1=foreground; 0=transparent background",
        "bit_order": "MSB is leftmost pixel; scan top to bottom; left byte before right byte",
        "ascii": {"first_code": 0, "count": 128, "width": 8, "height": 16,
                  "base": 0, "bytes_per_glyph": 16, "bytes_per_row": 1,
                  "blank_codes": "0..32 and 127"},
        "chinese": {"characters": CN_CHARS, "count": len(CN_CHARS), "capacity": 128,
                    "width": 16, "height": 16, "base": 2048,
                    "bytes_per_glyph": 32, "bytes_per_row": 2, "glyphs": mapping},
        "reserved": {"base": 6144, "byte_count": 2048, "value": 0},
        "source_fonts": {
            "ascii": {"name": list(ascii_font.getname()), "raster_size": 13,
                      "baseline_y": 12, "sha256": sha256(ascii_path)},
            "chinese": {"name": list(cn_font.getname()), "raster_size": 16,
                        "collection_index": 0, "sha256": sha256(cn_path)},
        },
    }
    save_json(out / "font_map.json", font_map)
    (out / "font_cn_chars.txt").write_text(CN_CHARS + "\n", encoding="utf-8")
    csv_lines = ["index,character,unicode,rom_base_decimal,rom_base_hex"]
    for item in mapping:
        csv_lines.append(
            f"{item['index']},{item['character']},{item['unicode']},"
            f"{item['rom_base_decimal']},{item['rom_base_hex']}"
        )
    (out / "font_cn_map.csv").write_text("\n".join(csv_lines) + "\n", encoding="utf-8-sig")
    return font_map, ascii_glyphs, cn_slots


def make_logo_data(out: Path) -> tuple[dict, Image.Image]:
    source_path = out / "source" / "anlogic_logo_cutout.png"
    source = Image.open(source_path).convert("RGBA")
    # Values below 16 disappear at the planned four-bit alpha precision. Use the
    # useful-alpha bounds so near-transparent generator noise cannot shrink the mark.
    alpha = source.getchannel("A")
    bounds = alpha.point(lambda value: 255 if value >= 16 else 0).getbbox()
    if bounds is None:
        raise ValueError("Logo cutout has no visible content")
    x0, y0, x1, y1 = bounds
    bounds = (max(0, x0 - 2), max(0, y0 - 2), min(source.width, x1 + 2), min(source.height, y1 + 2))
    cropped = source.crop(bounds)
    scale = min(124 / cropped.width, 60 / cropped.height)
    size = (max(1, round(cropped.width * scale)), max(1, round(cropped.height * scale)))
    # Resize premultiplied RGBA to avoid colored fringes around transparent pixels.
    fitted = cropped.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")
    canvas = Image.new("RGBA", (128, 64), (0, 0, 0, 0))
    offset = ((128 - size[0]) // 2, (64 - size[1]) // 2)
    canvas.paste(fitted, offset)

    words = []
    decoded_pixels = []
    for pixel_index in range(128 * 64):
        red, green, blue, opacity = canvas.getpixel((pixel_index % 128, pixel_index // 128))
        a = min(15, (opacity + 8) // 17)
        r, g, b = ((value + 8) // 17 for value in (red, green, blue))
        if a == 0:
            r = g = b = 0
        word = (a << 12) | (r << 8) | (g << 4) | b
        words.append(word)
        decoded_pixels.append((r * 17, g * 17, b * 17, a * 17))
    assert len(words) == 8192
    (out / "anlogic_logo_argb4444.hex").write_text(
        "".join(f"{word:04X}\n" for word in words), encoding="ascii"
    )
    (out / "anlogic_logo_argb4444.bin").write_bytes(struct.pack("<8192H", *words))
    decoded = Image.new("RGBA", (128, 64))
    decoded.putdata(decoded_pixels)
    decoded.save(out / "anlogic_logo_128x64.png")
    return {
        "width": 128, "height": 64, "width_bits": 16, "depth_words": 8192,
        "pixel_format": "ARGB4444; [15:12]A [11:8]R [7:4]G [3:0]B",
        "address": "y*128+x; top to bottom, left to right",
        "bin_byte_order": "little-endian uint16: low byte then high byte",
        "hex_format": "one 16-bit word per line, four hexadecimal digits, no header",
        "alpha": "0=transparent; 15=opaque",
        "source": "source/anlogic_logo_original.png",
        "cutout": "source/anlogic_logo_cutout.png",
        "cutout_method": "built-in imagegen transparent background extraction",
        "cutout_crop": list(bounds), "fitted_size": list(size), "offset": list(offset),
    }, decoded


def draw_packed_text(image: Image.Image, position: tuple[int, int], text: str,
                     ascii_glyphs: list, cn_slots: list, color=(255, 255, 255)) -> None:
    x, y = position
    for char in text:
        if ord(char) < 128:
            glyph = ascii_glyphs[ord(char)]
        else:
            glyph = cn_slots[CN_CHARS.index(char)]
        image.paste(color, (x, y, x + glyph.width, y + 16), glyph)
        x += glyph.width


def make_previews(out: Path, ascii_glyphs: list, cn_slots: list,
                  logo: Image.Image, label_font: ImageFont.FreeTypeFont) -> None:
    preview = out / "preview"
    preview.mkdir(exist_ok=True)
    ascii_sheet = Image.new("RGB", (16 * 48, 8 * 84), (24, 29, 40))
    draw = ImageDraw.Draw(ascii_sheet)
    for index, glyph in enumerate(ascii_glyphs):
        x, y = (index % 16) * 48, (index // 16) * 84
        draw.rectangle((x, y, x + 47, y + 83), outline=(70, 78, 94))
        draw.text((x + 9, y + 3), f"{index:02X}", font=label_font, fill=(135, 199, 255))
        mask = glyph.resize((24, 48), Image.Resampling.NEAREST)
        ascii_sheet.paste((255, 255, 255), (x + 12, y + 24, x + 36, y + 72), mask)
    ascii_sheet.save(preview / "font_ascii_labeled.png")

    cn_sheet = Image.new("RGB", (7 * 96, 4 * 112), (24, 29, 40))
    draw = ImageDraw.Draw(cn_sheet)
    for index, char in enumerate(CN_CHARS):
        x, y = (index % 7) * 96, (index // 7) * 112
        draw.rectangle((x, y, x + 95, y + 111), outline=(70, 78, 94))
        draw.text((x + 5, y + 2), f"{index:02d} U+{ord(char):04X}", font=label_font, fill=(135, 199, 255))
        mask = cn_slots[index].resize((64, 64), Image.Resampling.NEAREST)
        cn_sheet.paste((255, 255, 255), (x + 16, y + 24, x + 80, y + 88), mask)
        draw.text((x + 19, y + 92), f"@{2048 + index * 32:04X}", font=label_font, fill=(178, 190, 208))
    cn_sheet.save(preview / "font_cn_labeled.png")

    # A static technical asset preview, not a screenshot of the FPGA or RTL output.
    screen = Image.new("RGB", (640, 480))
    pixels = []
    for y in range(480):
        for x in range(640):
            tile = 18 * ((x // 80 + y // 80) % 2)
            pixels.append((64 + x * 140 // 639 + tile,
                           84 + y * 110 // 479 + tile, 126 + x * 50 // 639))
    screen.putdata(pixels)
    layer = Image.new("RGBA", screen.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rectangle((4, 4, 180, 27), fill=(0, 0, 0, 160))
    draw.rectangle((500, 4, 635, 75), fill=(255, 255, 255, 220))
    draw.rectangle((4, 380, 292, 451), fill=(0, 0, 0, 160))
    draw.rectangle((4, 452, 635, 475), fill=(0, 0, 0, 144))
    screen = Image.alpha_composite(screen.convert("RGBA"), layer).convert("RGB")
    screen.paste(logo, (504, 8), logo.getchannel("A"))
    for pos, text in [((8, 8), "运行 00:01:23"),
                      ((8, 384), "亮度:+32 对比:1.5x"),
                      ((8, 400), "轮播:开 状态:显示"),
                      ((8, 416), "图片:00001/00012"),
                      ((8, 432), "状态:转场"),
                      ((68, 456), STRINGS["slogan"])]:
        draw_packed_text(screen, pos, text, ascii_glyphs, cn_slots)
    screen.save(preview / "osd_preview_640x480.png")
    screen.resize((1280, 960), Image.Resampling.NEAREST).save(preview / "osd_preview_2x.png")

    checker = Image.new("RGB", (128, 64))
    draw = ImageDraw.Draw(checker)
    for y in range(0, 64, 8):
        for x in range(0, 128, 8):
            shade = 232 if (x // 8 + y // 8) % 2 == 0 else 192
            draw.rectangle((x, y, x + 7, y + 7), fill=(shade, shade, shade))
    checker.paste(logo, (0, 0), logo.getchannel("A"))
    checker.resize((768, 384), Image.Resampling.NEAREST).save(preview / "logo_alpha_6x.png")


def validate_saved_data(out: Path, ascii_glyphs: list, cn_slots: list) -> dict:
    ascii_data = (out / "font_ascii_8x16.bin").read_bytes()
    cn_data = (out / "font_cn_16x16.bin").read_bytes()
    combined = (out / "osd_font_8x8192.bin").read_bytes()
    assert combined[:2048] == ascii_data
    assert combined[2048:6144] == cn_data
    assert not any(combined[6144:])
    assert not any(cn_data[len(CN_CHARS) * 32:])
    for stem, expected in [("font_ascii_8x16", ascii_data), ("font_cn_16x16", cn_data),
                           ("osd_font_8x8192", combined)]:
        values = (out / f"{stem}.hex").read_text(encoding="ascii").splitlines()
        assert all(len(value) == 2 for value in values)
        assert bytes(int(value, 16) for value in values) == expected
    for index, glyph in enumerate(ascii_glyphs):
        assert encode_mask(glyph) == ascii_data[index * 16:(index + 1) * 16]
    for index, glyph in enumerate(cn_slots):
        assert encode_mask(glyph) == cn_data[index * 32:(index + 1) * 32]
    logo_words = [int(value, 16) for value in
                  (out / "anlogic_logo_argb4444.hex").read_text(encoding="ascii").splitlines()]
    assert len(logo_words) == 8192
    assert struct.pack("<8192H", *logo_words) == (out / "anlogic_logo_argb4444.bin").read_bytes()
    expected_rgba = [(((word >> 8) & 15) * 17, ((word >> 4) & 15) * 17,
                      (word & 15) * 17, ((word >> 12) & 15) * 17) for word in logo_words]
    with Image.open(out / "anlogic_logo_128x64.png") as image:
        assert image.size == (128, 64) and image.mode == "RGBA"
        assert image.tobytes() == bytes(channel for pixel in expected_rgba for channel in pixel)
        assert image.getchannel("A").getextrema() == (0, 255)
    for name, width, expected in [("osd_font_8x8192.mif", 8, list(combined)),
                                  ("anlogic_logo_argb4444.mif", 16, logo_words)]:
        lines = (out / "td_init" / name).read_text(encoding="ascii").splitlines()
        assert lines[:5] == [f"WIDTH = {width};", "DEPTH = 8192;",
                             "ADDRESS_RADIX = HEX;", "DATA_RADIX = HEX;", "CONTENT BEGIN"]
        assert lines[-1] == "END;" and len(lines) == 8198
        entries = [re.fullmatch(r"([0-9A-F]{4}) : ([0-9A-F]+);", line) for line in lines[5:-1]]
        assert all(entries)
        assert [int(entry[1], 16) for entry in entries] == list(range(8192))
        assert [int(entry[2], 16) for entry in entries] == expected
    for value in STRINGS.values():
        for text in value if isinstance(value, list) else [value]:
            assert all(ord(char) < 128 or char in CN_CHARS for char in text)
    return {"ascii_codes": 128, "ascii_nonblank_glyphs": 94,
            "chinese_glyphs": len(CN_CHARS), "chinese_reserved_slots": 128,
            "font_rom_bytes": len(combined), "logo_words": len(logo_words),
            "checks": ["text coverage", "glyph availability", "ROM address layout",
                       "blank reserved regions", "HEX/BIN agreement", "packed mask round trip",
                       "logo HEX/BIN/PNG agreement", "transparent and opaque logo pixels",
                       "MIF width/depth/continuous addresses/content agree with BIN and HEX"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "assets" / "osd")
    parser.add_argument("--ascii-font", type=Path, default=Path("C:/Windows/Fonts/consola.ttf"))
    parser.add_argument("--cn-font", type=Path, default=Path("C:/Windows/Fonts/simsun.ttc"))
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    assert len(CN_CHARS) == len(set(CN_CHARS)) == 28
    font_map, ascii_glyphs, cn_slots = make_font_data(out, args.ascii_font, args.cn_font)
    logo_info, logo = make_logo_data(out)
    write_td_mif(out / "td_init" / "osd_font_8x8192.mif", 8,
                 list((out / "osd_font_8x8192.bin").read_bytes()))
    write_td_mif(out / "td_init" / "anlogic_logo_argb4444.mif", 16,
                 list(struct.unpack("<8192H", (out / "anlogic_logo_argb4444.bin").read_bytes())))
    save_json(out / "osd_strings.json", STRINGS)
    (out / "osd_text.txt").write_text(
        "标语=安路 FPGA 多媒体展示\n运行时间=运行 00:00:00\n"
        "参数=亮度:+00 对比:1.0x\n轮播状态=轮播:开 状态:显示\n"
        "图片索引=图片:00001/00001\n其他状态=关 加载 转场 错误\n", encoding="utf-8")
    label_font = ImageFont.truetype(str(args.ascii_font), 12)
    make_previews(out, ascii_glyphs, cn_slots, logo, label_font)
    validation = validate_saved_data(out, ascii_glyphs, cn_slots)
    save_json(out / "validation_report.json", validation)
    tracked_files = [path for path in sorted(out.rglob("*")) if path.is_file()
                     and path.name not in {"asset_manifest.json", "README.md"}]
    save_json(out / "asset_manifest.json", {
        "schema_version": 1, "pillow_version": pillow_version,
        "font": {"width_bits": 8, "depth_words": 8192, "map_file": "font_map.json",
                 "chinese_count": len(CN_CHARS), "source_fonts": font_map["source_fonts"]},
        "logo": logo_info,
        "files": [{"path": path.relative_to(out).as_posix(), "bytes": path.stat().st_size,
                   "sha256": sha256(path)} for path in tracked_files],
    })
    print(json.dumps({"output": str(out), "validation": validation}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
