#!/usr/bin/env python3
"""Generate standalone SVG cat icons from one shared, editable geometry."""
from pathlib import Path
import json
import xml.etree.ElementTree as ET

SCRIPT = Path(__file__).resolve()
IN_REPOSITORY = SCRIPT.parent.name == "branding" and SCRIPT.parent.parent.name == "scripts"
OUT = SCRIPT.parents[2] / "assets/branding/cats" if IN_REPOSITORY else SCRIPT.parent

# Coordinates follow the approved Earth cat. Tail has one arc and no inner coil.
BODY = """M74 149 C75 109 80 63 99 40 C107 30 117 33 129 42
L180 84 Q185 88 191 87 Q213 84 234 88 Q240 89 245 84
L293 43 C305 32 316 34 323 47
C336 77 340 112 340 152 C357 179 359 210 347 236
C337 255 322 268 302 279 L316 320 C328 345 337 374 337 411
C337 450 316 479 282 480 L274 480
C270 488 260 492 248 492 C236 492 226 488 222 480
L186 480 C182 488 172 492 160 492 C148 492 138 488 134 480
L102 480 C67 480 50 456 51 421
C51 378 75 323 101 280 C71 263 50 242 49 213
C46 191 57 168 74 149 Z"""
TAIL = "M278 451 C365 451 422 425 422 369 C422 317 405 279 373 261"
# The paws belong to BODY, so a coat pattern cannot acquire a rectangular seam
# from a second paw fill. These four curves only describe the front-leg edges.
PAW_LINES = """M138 447 C133 459 133 472 138 480
M182 447 C187 459 187 472 182 480
M226 447 C221 459 221 472 226 480
M270 447 C275 459 275 472 270 480"""
MOUTH = "M179 209 C181 222 196 224 204 215 C212 224 227 222 229 209"
LEFT_LAND = """M-20 311 H55 C83 302 107 302 122 326 C139 350 176 352 191 364
C215 383 196 396 174 404 C150 416 142 431 139 460
C117 454 109 443 99 426 C88 413 24 408 -20 382 Z"""
RIGHT_LAND = """M360 248 C335 260 320 266 301 274
C277 285 258 297 241 307 C219 321 210 338 230 350
C243 359 258 355 272 369 C288 385 292 407 340 415
L390 430 V240 Z"""
MUZZLE = """M204 189 C189 189 184 198 173 202 C161 206 146 202 132 206
C110 212 101 234 110 251 C126 278 171 290 204 290
C237 290 282 278 298 251 C307 234 298 212 276 206
C262 202 247 206 235 202 C224 198 219 189 204 189 Z"""
STRIPES = """M170 74 H196 L194 112 Q193 125 184 125 Q175 125 173 112 Z
M212 74 H238 L235 112 Q233 125 224 125 Q215 125 214 112 Z"""
LEFT_EAR_PATCH = """M-20 -20 H215 L183 86 C151 108 105 135 69 152 H-20 Z"""
RIGHT_EAR_PATCH = """M242 -20 H390 V162 C349 150 294 123 241 88 Z"""
COW_FACE_PATCH = """M268 -20 H390 V180 C356 207 325 224 293 222
C257 222 233 206 228 178 C223 149 234 125 247 105
C259 88 263 61 268 -20 Z"""

DEFAULT_ICON = "cow"

THEMES = [
    dict(id="orange", name="橘猫", colors=["#FFB34C", "#F78A24", "#DB6418"],
         face="#573017", line="#A94A16", detail="橙金渐变 · 奶油色嘴部"),
    dict(id="cow", name="奶牛猫", colors=["#FFFFFF", "#F3F4F7", "#DCE2E9"],
         face="#252935", line="#747E8E", detail="黑白花纹 · 默认图标"),
    dict(id="prism", name="炫彩猫", colors=["#04DCE5", "#4069F5", "#E746C8"],
         face="#FFFFFF", line="#3835B4", detail="青蓝紫粉 · 连续渐变"),
    dict(id="four-color", name="四色猫", colors=["#62A4FF", "#4285F4", "#2866CC"],
         face="#FFFFFF", line="#AD5B22", detail="红黄蓝绿 · 简洁色块"),
    dict(id="earth", name="地球猫", colors=["#04B8F1", "#0878F4", "#073ACB"],
         face="#FFFFFF", line="#07349A", detail="海洋蓝绿 · 单弧尾巴"),
]


def gradient(name, colors, diagonal=False):
    x1, y1, x2, y2 = (65, 40, 445, 470) if diagonal else (0, 35, 0, 488)
    stops = "".join(f'<stop offset="{i / (len(colors)-1):.3f}" stop-color="{c}"/>'
                    for i, c in enumerate(colors))
    return (f'<linearGradient id="{name}" gradientUnits="userSpaceOnUse" '
            f'x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{stops}</linearGradient>')


def svg(theme, prefix=""):
    key = theme["id"]
    p = prefix or f"cat-{key}-"
    main, accent, dark = p + "coat", p + "accent", p + "dark"
    fill = f"url(#{main})"
    defs = gradient(main, theme["colors"], key == "prism")
    defs += gradient(accent, ["#91F4CE", "#20B9A1"])
    defs += gradient(dark, ["#4C566B", "#3C4558"])
    coat = ""
    eyes = [theme["face"], theme["face"]]
    tail_fill = fill
    if key == "orange":
        defs += gradient(accent + "cream", ["#FFF5DF", "#FFE3B8"])
        coat = (f'<path d="{MUZZLE}" fill="url(#{accent}cream)"/>'
                f'<path d="{STRIPES}" fill="#B85B22" opacity=".65"/>')
    elif key == "cow":
        tail_fill = f"url(#{dark})"
        # Patches are broad so the eye remains legible when the icon is small.
        coat = (f'<path d="{LEFT_EAR_PATCH}" fill="{tail_fill}"/>'
                f'<path d="{COW_FACE_PATCH}" fill="{tail_fill}"/>'
                f'<path d="M-20 337 H55 C89 328 119 350 119 379 C117 406 86 419 53 410 L-20 400 Z" fill="{tail_fill}"/>')
        eyes[1] = "#FFFFFF"
    elif key == "four-color":
        defs += gradient(p + "red", ["#F66B5C", "#EA4335", "#C9302C"])
        defs += gradient(p + "yellow", ["#FFD568", "#FBBC05", "#EDA510"])
        defs += gradient(p + "green", ["#62CC82", "#34A853", "#228944"])
        tail_fill = f"url(#{p}green)"
        coat = (f'<path d="{LEFT_EAR_PATCH}" fill="url(#{p}red)"/>'
                f'<path d="{RIGHT_EAR_PATCH}" fill="url(#{p}yellow)"/>'
                f'<path d="M-30 298 C90 320 238 306 350 265 L400 520 H-30 Z" fill="url(#{p}red)"/>'
                f'<path d="M380 316 C282 321 221 348 175 390 C148 413 135 451 132 520 H390 Z" fill="url(#{p}yellow)"/>')
    elif key == "earth":
        coat = f'<path d="{LEFT_LAND} {RIGHT_LAND}" fill="url(#{accent})"/>'
    # Paint the complete coat through one silhouette. Separate clipped layers
    # accumulate antialiasing at the outside edge and create theme-specific rims.
    defs += (f'<pattern id="{p}pattern" patternUnits="userSpaceOnUse" width="512" height="512">'
             f'<rect width="512" height="512" fill="{fill}"/>{coat}</pattern>')
    eye_shapes = "".join(f'<circle cx="{x}" cy="180" r="18.5" fill="{c}"/>'
                         for x, c in zip([147, 261], eyes))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512" role="img" aria-labelledby="{p}title {p}desc">
  <title id="{p}title">FreeV6 · {theme["name"]}</title>
  <desc id="{p}desc">坐姿小猫，圆眼睛、W 形嘴和两只前爪；身体与单弧尾巴整体呼应数字 6。透明背景。</desc>
  <defs>{defs}</defs>
  <g transform="translate(15.36 15.36) scale(.94)">
  <path id="{p}tail" d="{TAIL}" fill="none" stroke="{tail_fill}" stroke-width="58" stroke-linecap="round"/>
  <path id="{p}body-shape" d="{BODY}" fill="url(#{p}pattern)"/>
  <path id="{p}paws" d="{PAW_LINES}" fill="none" stroke="{theme["line"]}" stroke-width="2.6" stroke-linecap="round" opacity=".40"/>
  {eye_shapes}
  <path id="{p}mouth" d="{MOUTH}" fill="none" stroke="{theme["face"]}" stroke-width="10.5" stroke-linecap="round" stroke-linejoin="round"/>
  </g>
</svg>
'''


def preview():
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="690" viewBox="0 0 1500 690">',
             '<rect width="1500" height="690" rx="28" fill="#F6F7FA"/>',
             '<text x="44" y="55" font-family="Arial,sans-serif" font-size="26" font-weight="600" fill="#1C2534">FreeV6 · Cat icons</text>',
             '<text x="1456" y="53" text-anchor="end" font-family="Arial,sans-serif" font-size="15" fill="#657184">SVG / shared silhouette / gradient</text>']
    for i, theme in enumerate(THEMES):
        x = 28 + i * 294
        parts += [f'<rect x="{x}" y="85" width="268" height="350" rx="22" fill="white"/>',
                  svg(theme, f"preview-{i}-").replace('width="512" height="512"', f'x="{x+12}" y="100" width="244" height="244"', 1),
                  f'<text x="{x+134}" y="380" text-anchor="middle" font-family="PingFang SC,Arial,sans-serif" font-size="22" fill="#172235">{theme["name"]}{" · 默认" if theme["id"] == DEFAULT_ICON else ""}</text>',
                  f'<text x="{x+134}" y="409" text-anchor="middle" font-family="PingFang SC,Arial,sans-serif" font-size="13" fill="#657184">{theme["detail"]}</text>']
    parts += ['<rect x="28" y="459" width="1444" height="203" rx="22" fill="#192230"/>',
              '<text x="51" y="492" font-family="PingFang SC,Arial,sans-serif" font-size="14" fill="#BBC5D5">深色背景与小尺寸预览</text>']
    for i, theme in enumerate(THEMES):
        x = 28 + i * 294
        parts += [svg(theme, f"dark-{i}-").replace('width="512" height="512"', f'x="{x+58}" y="510" width="112" height="112"', 1),
                  svg(theme, f"small-{i}-").replace('width="512" height="512"', f'x="{x+194}" y="551" width="32" height="32"', 1),
                  f'<text x="{x+210}" y="608" text-anchor="middle" font-family="Arial,sans-serif" font-size="11" fill="#93A1B6">32 px</text>']
    return "\n".join(parts) + "</svg>\n"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for theme in THEMES:
        content = svg(theme)
        ET.fromstring(content)
        (OUT / (theme["id"] + ".svg")).write_text(content)
    (OUT / "preview.svg").write_text(preview())
    (OUT / "catalog.json").write_text(json.dumps({
        "default": DEFAULT_ICON, "viewBox": [0, 0, 512, 512],
        "icons": [{"id": t["id"], "name": t["name"], "file": t["id"] + ".svg"} for t in THEMES],
    }, ensure_ascii=False, indent=2) + "\n")
    print(f"Generated {len(THEMES)} standalone SVG icons and preview in {OUT}")


if __name__ == "__main__":
    main()
