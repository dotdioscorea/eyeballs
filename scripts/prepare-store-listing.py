#!/usr/bin/env python3
"""Validate the listing draft and generate its local review files. No uploads."""

import argparse
import hashlib
import html
import json
from pathlib import Path
import shutil
import struct


ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / "docs/app-store"
SOURCE = DIRECTORY / "listing-en-GB.json"


def escaped(value):
    return html.escape(str(value), quote=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate existing outputs without rewriting them")
    args = parser.parse_args()
    listing = json.loads(SOURCE.read_text())
    metadata = listing["metadata"]
    limits = {"name": 30, "subtitle": 30, "promotionalText": 170, "description": 4000, "keywords": 100}
    counts = {}
    for field, limit in limits.items():
        value = metadata[field]
        # All keywords are ASCII; byte and character limits agree for this draft.
        count = len(value.encode("utf-8")) if field == "keywords" else len(value)
        if not value or count > limit:
            raise ValueError(f"{field}: {count}/{limit}")
        counts[field] = {"length": count, "limit": limit}
    keywords = metadata["keywords"].split(",")
    if any(not word or word != word.strip() for word in keywords) or len(set(keywords)) != len(keywords):
        raise ValueError("Keywords must be unique comma-separated terms without padding")
    if listing["status"] != "draft-for-owner-review":
        raise ValueError("This renderer handles review drafts only")

    (DIRECTORY / "assets").mkdir(exist_ok=True)
    assets = []
    for shot in listing["screenshots"] + listing.get("ipadScreenshots", []):
        source = ROOT / shot["source"]
        destination = DIRECTORY / shot["asset"]
        if args.check:
            data = destination.read_bytes()
        else:
            if source.resolve() != destination.resolve():
                shutil.copyfile(source, destination)
            data = destination.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"Not a PNG: {destination}")
        width, height = struct.unpack(">II", data[16:24])
        expected = (2064, 2752) if "/ipad/" in shot["asset"] else (1320, 2868)
        if (width, height) != expected or data[25] != 2:
            raise ValueError(f"Expected opaque RGB PNG at {expected}: {destination}")
        assets.append({"asset": shot["asset"], "width": width, "height": height,
                       "sha256": hashlib.sha256(data).hexdigest(), "sourceBuild": shot["sourceBuild"], "alpha": False, "nativeCapture": shot["nativeCapture"]})
    icon = ROOT / "App/Eyeballs/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    if not args.check:
        shutil.copyfile(icon, DIRECTORY / "assets/icon.png")

    labels = {"name": "Name", "subtitle": "Subtitle", "promotionalText": "Promotional text",
              "description": "Description", "keywords": "Keywords", "supportURL": "Support URL",
              "privacyPolicyURL": "Privacy policy URL", "copyright": "Copyright"}
    text_lines = ["REQUOTA — APP STORE LISTING DRAFT", "Prepared 4 October 2026 · English (UK) · Version 1.0", ""]
    for field, label in labels.items():
        count = counts.get(field)
        suffix = f" ({count['length']}/{count['limit']})" if count else ""
        text_lines += [label.upper() + suffix, metadata[field], ""]
    text_lines += ["RECOMMENDED CATEGORIES", "Utilities; optional secondary category: Productivity", "",
                   "PRICE", listing["recommendations"]["pricing"], "", "SCREENSHOT ORDER"]
    for number, shot in enumerate(listing["screenshots"], 1):
        text_lines += [f"{number}. {shot['headline']}"]
    text_lines += ["", "Screenshots use native captures with illustrative account data; original captures are included.",
                   "The listing has not been entered into App Store Connect or submitted for review.", ""]
    text_output = "\n".join(text_lines)

    paragraphs = []
    for paragraph in metadata["description"].split("\n\n"):
        if paragraph.startswith("• "):
            paragraphs.append("<ul>" + "".join(f"<li>{escaped(line[2:])}</li>" for line in paragraph.splitlines()) + "</ul>")
        elif paragraph.startswith("Supported providers\n"):
            paragraphs.append("<h3>Supported providers</h3><p>" + escaped(paragraph.split("\n", 1)[1]) + "</p>")
        else:
            paragraphs.append("<p>" + escaped(paragraph) + "</p>")
    description = "\n".join(paragraphs)
    def gallery(shots, ipad=False):
        return "\n".join(
            f'<article class="shot{ " ipad" if ipad else "" }"><a href="{escaped(shot["asset"])}" target="_blank" rel="noopener">'
            f'<img src="{escaped(shot["asset"])}" alt="{escaped(shot["capture"])}" width="{2064 if ipad else 1320}" height="{2752 if ipad else 2868}"></a>'
            f'<div class="native-link"><a href="{escaped(shot["nativeCapture"])}" target="_blank" rel="noopener">Original capture</a></div></article>'
            for shot in shots
        )
    screenshots = gallery(listing["screenshots"])
    ipad_screenshots = gallery(listing.get("ipadScreenshots", []), ipad=True)
    research = "\n".join(
        f'<li><a href="{escaped(item["url"])}" target="_blank" rel="noopener">{escaped(item["name"])}</a>'
        f'<p>{escaped(item["observations"])}</p></li>' for item in listing["research"]["comparisons"]
    )
    screenshot_notes = "".join(f"<li>{escaped(note)}</li>" for note in listing["screenshotNotes"])
    apple_links = " · ".join(f'<a href="{escaped(item["url"])}" target="_blank" rel="noopener">{escaped(item["name"])}</a>'
                              for item in listing["research"]["appleReferences"])
    keywords_field = f'''<div class="field"><div class="field-header"><h3>Keywords</h3><span class="count">{counts['keywords']['length']}/100</span></div>
<code id="keywords">{escaped(metadata['keywords'])}</code><button class="copy" data-field="keywords">Copy keywords</button></div>'''
    document = f'''<!doctype html>
<html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Requota — App Store listing draft</title>
<style>
:root{{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#202421;background:#f5f6f3;font-synthesis:none}}
*{{box-sizing:border-box}}body{{margin:0}}a{{color:#376232;text-underline-offset:3px}}button{{font:inherit;cursor:pointer}}
.toolbar{{max-width:1100px;margin:auto;padding:28px 28px 20px;display:flex;gap:16px;align-items:center;justify-content:space-between;font-size:13px;color:#657060}}
.tag{{padding:7px 11px;background:#e8edde;border-radius:6px;color:#3b5230;font-weight:600}}.page{{max-width:1100px;margin:0 auto 56px;background:white;border:1px solid #e2e5df;border-radius:20px;padding:40px}}
.identity{{display:flex;gap:24px;align-items:center}}.icon{{width:112px;height:112px;border-radius:25px;border:1px solid #20261c}}
h1{{font-size:30px;line-height:1.16;letter-spacing:-.7px;margin:0 0 8px}}.subtitle{{font-size:19px;margin:0;color:#687068}}.publisher{{font-size:14px;color:#888e86;margin:12px 0 0}}
.positioning{{margin:27px 0 32px;padding:15px 0;border-top:1px solid #eceee9;border-bottom:1px solid #eceee9;display:flex;gap:24px;font-size:13px;color:#657060;flex-wrap:wrap}}
.section-title{{display:flex;align-items:center;justify-content:space-between;gap:14px;margin-bottom:16px}}h2{{font-size:21px;letter-spacing:-.3px;margin:0}}h3{{font-size:16px;margin:0 0 8px}}p{{line-height:1.6;margin:0 0 17px}}
.gallery{{display:flex;gap:16px;overflow-x:auto;scroll-snap-type:x mandatory;padding:0 0 16px;scrollbar-color:#b8c6a9 #f1f4ed}}
.shot{{flex:0 0 250px;scroll-snap-align:start;background:#121711;border-radius:16px;overflow:hidden;border:1px solid #20291e;color:#fff}}
.shot.ipad{{flex-basis:330px}}.native-link{{padding:10px 16px;font-size:11px;text-align:center}}.native-link a{{color:#c5cebc}}.shot-copy{{padding:19px 19px 15px;min-height:168px;background:linear-gradient(150deg,#23331e,#131912)}}.shot-number{{font-size:11px;letter-spacing:1px;color:#b9f577}}
.shot h3{{font-size:22px;line-height:1.16;letter-spacing:-.4px;margin:13px 0 8px}}.shot p{{font-size:13px;line-height:1.4;color:#d0dac8;margin:0}}.shot img{{display:block;width:100%;height:auto}}.shot a{{display:block}}
.note{{font-size:12px;color:#788271;margin:9px 0 29px}}.columns{{display:grid;grid-template-columns:minmax(0,1fr) 270px;gap:36px;padding-top:27px;border-top:1px solid #eceee9}}
.promo{{font-size:17px;margin-bottom:26px}}.description{{font-size:15px;line-height:1.6}}.description ul{{padding-left:20px;margin:0 0 20px}}.description li{{margin:0 0 11px;padding-left:2px}}.description h3{{margin-top:24px}}
.copy{{border:1px solid #dfe5d7;background:#f6f9f1;color:#3b5730;font-size:12px;border-radius:7px;padding:7px 10px;white-space:nowrap}}.copy:focus-visible,summary:focus-visible,a:focus-visible{{outline:3px solid #719955;outline-offset:3px}}.count{{font-size:11px;color:#8a9382;white-space:nowrap}}
.field{{margin:0 0 25px;font-size:13px;overflow-wrap:anywhere}}.field-header{{display:flex;align-items:baseline;justify-content:space-between;gap:8px}}.field p{{line-height:1.5;margin:0 0 9px}}code{{display:block;font-family:ui-monospace,SFMono-Regular,monospace;font-size:12px;line-height:1.6;margin-bottom:10px;overflow-wrap:anywhere}}
.details{{margin:28px 0 0;padding-top:22px;border-top:1px solid #eceee9}}summary{{cursor:pointer;font-size:14px;font-weight:600;color:#42543b;padding:5px 0}}details>div{{font-size:13px;margin-top:17px;line-height:1.6}}.research{{list-style:none;padding:0;display:grid;grid-template-columns:1fr 1fr;gap:15px 26px}}.research li a{{font-weight:600}}.research p{{margin:5px 0 0}}.review-notes{{padding-left:20px}}.review-notes li{{margin:0 0 9px}}
#copy-status{{position:fixed;bottom:22px;left:50%;transform:translateX(-50%);border-radius:8px;background:#24301e;color:white;padding:10px 17px;font-size:13px;box-shadow:0 3px 12px #0002}}#copy-status:empty{{display:none}}
@media(max-width:750px){{.toolbar{{padding:20px 16px;font-size:11px}}.page{{margin:0 10px 24px;padding:24px 18px;border-radius:15px}}.identity{{gap:15px}}.icon{{width:80px;height:80px;border-radius:18px}}h1{{font-size:24px}}.subtitle{{font-size:16px}}.publisher{{font-size:12px;margin-top:8px}}.positioning{{gap:10px 20px;margin:22px 0}}.columns{{grid-template-columns:1fr;gap:26px}}.shot{{flex-basis:235px}}.research{{grid-template-columns:1fr}}}}
@media print{{body{{background:white}}.toolbar,.copy,.details,#copy-status{{display:none}}.page{{border:0;margin:0;padding:0}}.gallery{{overflow:visible;flex-wrap:wrap}}.shot{{flex-basis:28%;break-inside:avoid}}.columns{{display:block}}}}
</style></head><body>
<div class="toolbar"><span class="tag">Draft for review</span><span>4 October 2026 · English (UK) · v1.0</span></div>
<main class="page">
<header class="identity"><img class="icon" src="assets/icon.png" width="112" height="112" alt="Requota app icon"><div><h1 id="name">{escaped(metadata['name'])}</h1><p class="subtitle" id="subtitle">{escaped(metadata['subtitle'])}</p><p class="publisher">Aaron Rucinski</p></div></header>
<div class="positioning"><span>Recommended category: Utilities</span><span>iPhone &amp; iPad · iOS 17+</span><span>Price to be chosen</span></div>
<section aria-label="iPhone screenshots"><div class="section-title"><h2>iPhone screenshots</h2><span class="count">1320 × 2868</span></div><div class="gallery">{screenshots}</div>
<p class="note">Native captures with illustrative account data. Click an image to inspect the full upload file.</p></section>
<details class="details" style="margin:0 0 28px"><summary>iPad screenshots · 2064 × 2752</summary><div class="gallery">{ipad_screenshots}</div></details>
<div class="columns"><section><div class="section-title"><h2>Promotional text</h2><button class="copy" data-field="promotionalText">Copy text</button></div><p class="promo" id="promotionalText">{escaped(metadata['promotionalText'])}</p>
<div class="section-title"><h2>Description</h2><button class="copy" data-field="description">Copy description</button></div><div class="description">{description}</div></section>
<aside aria-label="Listing fields"><div class="field"><div class="field-header"><h3>Name</h3><span class="count">{counts['name']['length']}/30</span></div><p>{escaped(metadata['name'])}</p><button class="copy" data-field="name">Copy name</button></div>
<div class="field"><div class="field-header"><h3>Subtitle</h3><span class="count">{counts['subtitle']['length']}/30</span></div><p>{escaped(metadata['subtitle'])}</p><button class="copy" data-field="subtitle">Copy subtitle</button></div>
{keywords_field}<div class="field"><h3>Support</h3><a href="{escaped(metadata['supportURL'])}">GitHub issues</a></div><div class="field"><h3>Privacy policy</h3><a href="{escaped(metadata['privacyPolicyURL'])}">Published policy</a></div>
<div class="field"><h3>Copy lengths</h3><p>Promotional text: {counts['promotionalText']['length']}/170<br>Description: {counts['description']['length']}/4,000</p></div>
<div class="field"><h3>Files</h3><a href="listing-en-GB.txt">Plain-text listing</a><br><a href="listing-en-GB.json">Metadata and screenshot brief</a></div></aside></div>
<details class="details"><summary>Comparison notes</summary><div><p>{escaped(listing['research']['approach'])}</p><ul class="research">{research}</ul><p class="note">Listings checked 4 October 2026. These notes describe positioning and copy, not independent verification of competing apps.</p></div></details>
<details class="details"><summary>Screenshot preparation notes</summary><div><ul class="review-notes">{screenshot_notes}</ul><p>{apple_links}</p></div></details>
<p class="note" style="margin:25px 0 0">This is a local review draft. No App Store metadata has been changed or submitted.</p>
</main><div id="copy-status" role="status" aria-live="polite"></div>
<script type="application/json" id="listing-data">{json.dumps(metadata, ensure_ascii=False).replace('<', chr(92) + 'u003c')}</script>
<script>
const fields=JSON.parse(document.getElementById('listing-data').textContent);
let timeout;
document.querySelectorAll('[data-field]').forEach(button=>button.addEventListener('click',async()=>{{
  const value=fields[button.dataset.field]; let copied=false;
  try {{ await navigator.clipboard.writeText(value); copied=true; }} catch {{
    const area=document.createElement('textarea'); area.value=value; area.style.cssText='position:fixed;left:-9999px'; document.body.append(area); area.select(); copied=document.execCommand('copy'); area.remove();
  }}
  const status=document.getElementById('copy-status'); status.textContent=copied?'Copied':'Open the plain-text listing to copy this field'; clearTimeout(timeout); timeout=setTimeout(()=>status.textContent='',2200);
}}));
</script></body></html>
'''
    validation = {"preparedOn": listing["preparedOn"], "metadata": counts, "screenshots": assets,
                  "scope": "Reviewable copy and native screenshot artwork; no App Store Connect mutation or submission."}
    outputs = {"listing-en-GB.txt": text_output, "review.html": document,
               "validation.json": json.dumps(validation, indent=2) + "\n"}
    for name, value in outputs.items():
        path = DIRECTORY / name
        if args.check:
            if path.read_text() != value:
                raise ValueError(f"Stale generated file: {path.relative_to(ROOT)}")
        else:
            path.write_text(value)
    print(json.dumps({"fields": counts, "screenshots": len(assets), "check": args.check}, indent=2))


if __name__ == "__main__":
    main()
