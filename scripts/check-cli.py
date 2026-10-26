#!/usr/bin/env python3
"""Exercise the compiled JSON CLI. Writes only to a fresh validation directory."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import sys

binary = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=False)
checks = []

fixture_source = r'''
import Foundation
import CoreGraphics
import ImageIO
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let context = CGContext(data: nil, width: 1000, height: 800, bitsPerComponent: 8, bytesPerRow: 4000,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 0.5)
context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
context.setFillColor(gray: 1, alpha: 1)
for y in stride(from: 0, to: 800, by: 16) {
    for x in stride(from: 0, to: 1000, by: 16) { context.fill(CGRect(x: x, y: y, width: 4, height: 4)) }
}
let image = context.makeImage()!
func save(_ name: String, _ type: String, count: Int = 1, orientation: Int = 1) {
    let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, type as CFString, count, nil)!
    for _ in 0..<count { CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary) }
    precondition(CGImageDestinationFinalize(destination))
}
save("源图.png", "public.png")
save("rotated.jpg", "public.jpeg", orientation: 6)
save("animation.gif", "com.compuserve.gif", count: 2)
'''
subprocess.run(["swift", "-e", fixture_source, str(output)], check=True, capture_output=True)
input_path = output / "源图.png"
original = hashlib.sha256(input_path.read_bytes()).hexdigest()


def invoke(*args, request=None, expected=0):
    process = subprocess.run([str(binary), "--cli", *args], input=request, text=True, capture_output=True, timeout=60)
    assert process.returncode == expected, (args, process.returncode, process.stdout, process.stderr)
    value = json.loads(process.stdout)
    assert value["schemaVersion"] == 1 and value["ok"] == (expected == 0), value
    return value


def job(name, operations, target=None, source=None):
    value = {"schemaVersion": 1, "input": str(source or input_path),
             "output": str(target or output / name), "operations": operations}
    return json.dumps(value, ensure_ascii=False)


capabilities = invoke("capabilities")["result"]
assert capabilities["overwrite"] is False
assert capabilities["defaults"]["diameter"] == 20
checks.append("Machine-readable capabilities and parameter defaults")
info = invoke("inspect", str(input_path))["result"]
assert (info["pixelWidth"], info["pixelHeight"]) == (1000, 800)
rotated = invoke("inspect", str(output / "rotated.jpg"))["result"]
assert (rotated["pixelWidth"], rotated["pixelHeight"]) == (800, 1000)
checks.append("Unicode paths, inspect and EXIF orientation")

operations = [
    {"type": "crop", "x": 100, "y": 80, "width": 800, "height": 600},
    {"type": "rectangle", "x": 40, "y": 40, "width": 300, "height": 150},
    {"type": "pencil", "points": [{"x": 100, "y": 300}, {"x": 700, "y": 350}], "opacity": 0.8},
    {"type": "mosaic", "points": [{"x": 100, "y": 480}, {"x": 600, "y": 480}]},
]
for extension in ["png", "jpg", "webp"]:
    text = job("结果." + extension, operations)
    request_file = output / ("request-" + extension + ".json")
    request_file.write_text(text)
    result = invoke("edit", "--request", str(request_file))["result"]
    assert (result["pixelWidth"], result["pixelHeight"]) == (800, 600)
    saved = invoke("inspect", result["output"])["result"]
    assert (saved["pixelWidth"], saved["pixelHeight"]) == (800, 600)
    target = Path(result["output"])
    before = target.read_bytes()
    refused = invoke("edit", "--request", "-", request=text, expected=1)
    assert refused["error"]["code"] == "output_exists"
    assert target.read_bytes() == before
checks.append("Four sequential edits, PNG/JPEG/WebP output and reopen; existing output preserved")

in_place = invoke("edit", "--request", "-", request=job("", [], target=input_path), expected=1)
assert in_place["error"]["code"] == "output_exists"
symlink = output / "symlink.png"
symlink.symlink_to(output / "missing.png")
assert invoke("edit", "--request", "-", request=job("", [], target=symlink), expected=1)["error"]["code"] == "output_exists"
assert symlink.is_symlink() and not (output / "missing.png").exists()
bad = invoke("edit", "--request", "-", request=job("invalid.png", [
    {"type": "crop", "x": 0, "y": 0, "width": 1001, "height": 800}
]), expected=2)
assert bad["error"]["code"] == "out_of_bounds" and bad["error"]["operationIndex"] == 0
assert not (output / "invalid.png").exists()
assert invoke("edit", "--request", "-", request="{", expected=2)["error"]["code"] == "invalid_request"
assert invoke("edit", "--request", "-", request=job("unsupported.heic", []), expected=2)["error"]["code"] == "unsupported_output"
assert invoke("edit", "--request", "-", request=job("unsupported.png", [], source=output / "not-an-image.txt"), expected=2)["error"]["code"] == "unsupported_input"
checks.append("Source, dangling symlink, invalid JSON and out-of-range protections")

gif = invoke("edit", "--request", "-", request=job("first-frame.png", [], source=output / "animation.gif"))["result"]
assert "first_frame_only" in gif["warnings"]
checks.append("Multi-frame warning and static output")

race_job = job("race.webp", [])
def race(_):
    process = subprocess.run([str(binary), "--cli", "edit", "--request", "-"],
                             input=race_job, text=True, capture_output=True, timeout=60)
    return process.returncode, json.loads(process.stdout)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(race, range(4)))
assert sum(code == 0 for code, _ in results) == 1, results
assert all(code == 0 or value["error"]["code"] == "output_exists" for code, value in results)
assert invoke("inspect", str(output / "race.webp"))["result"]["pixelWidth"] == 1000
assert hashlib.sha256(input_path.read_bytes()).hexdigest() == original
assert not list(output.glob(".picglide-*"))
checks.append("Concurrent CLI writers create one valid file without replacing anything")

report = {"checks": checks, "capabilities": capabilities, "sourceSHA256": original,
          "sourceUnchanged": True, "temporaryFilesRemoved": True}
(output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"PICGLIDE_CLI_PASS {len(checks)} groups")
