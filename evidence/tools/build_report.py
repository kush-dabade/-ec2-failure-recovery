#!/usr/bin/env python3
"""Builds EC2_Virtual_Machine_Failure_Experiment_Report.html from the Markdown source
(the HTML is then printed to PDF with Chromium by build_pdf.js)."""
import pathlib, sys
import markdown

root = pathlib.Path(sys.argv[1])
md = (root / "EC2_Virtual_Machine_Failure_Experiment_Report.md").read_text()
body = markdown.markdown(md, extensions=["tables", "fenced_code", "sane_lists"])
css = """
@page { size: A4; margin: 16mm 15mm 18mm 15mm; }
body { font: 10.5pt/1.5 "DejaVu Sans", system-ui, Arial, sans-serif; color: #111; }
h1 { font-size: 20pt; margin: 0 0 4pt; color: #0b3d75; }
h2 { font-size: 14pt; color: #0b3d75; border-bottom: 1.5px solid #c9d6e8; padding-bottom: 3pt; margin-top: 20pt; break-after: avoid; }
h3 { font-size: 12pt; margin-top: 14pt; break-after: avoid; }
table { border-collapse: collapse; width: 100%; margin: 8pt 0; font-size: 9pt; break-inside: auto; }
tr { break-inside: avoid; }
th, td { border: 1px solid #c8c8c4; padding: 4pt 6pt; vertical-align: top; text-align: left; }
th { background: #eef2f7; }
code { font: 8.6pt "DejaVu Sans Mono", ui-monospace, monospace; background: #f3f3f0; padding: 0 2px; border-radius: 2px; }
img { max-width: 100%; max-height: 225mm; display: block; margin: 10pt auto 3pt; border: 1px solid #d0d0cc; }
p:has(> img) { break-inside: avoid; break-after: avoid; margin: 0; }
p > em:only-child { display: block; font-size: 8.8pt; color: #3d3d3a; text-align: center; margin: 0 6% 12pt; }
blockquote { margin: 10pt 0; padding: 6pt 10pt; border-left: 3px solid #fab219; background: #fff9ea; font-size: 9.5pt; }
hr { border: none; border-top: 1px solid #ccc; margin: 14pt 0; }
"""
html = f'<!doctype html><html><head><meta charset="utf-8"><title>EC2 Virtual Machine Failure Experiment Report</title><style>{css}</style></head><body>{body}</body></html>'
(root / "build").mkdir(exist_ok=True)
out = root / "build" / "report.html"
out.write_text(html)
print(out)
