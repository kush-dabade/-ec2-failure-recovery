// Evidence tool: renders a saved CLI output file to PNG for the report, with a header
// that states plainly it is AWS CLI output and NOT an AWS Console screenshot.
//   node render_cli.js <input.txt> <output.png> "<title>"
const { chromium } = require("playwright-core");
const fs = require("fs");
const [inp, out, title] = process.argv.slice(2);
const exe = process.env.HOME + "/.cache/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-linux64/chrome-headless-shell";
const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
(async () => {
  const b = await chromium.launch({ executablePath: exe });
  const p = await b.newPage({ viewport: { width: 1200, height: 400 } });
  await p.setContent(`<html><body style="margin:0;background:#1a1a19;font:13px/1.45 ui-monospace,Menlo,Consolas,monospace;color:#f0efec">
    <div style="padding:10px 16px;background:#2b2b29;color:#c3c2b7;font:600 13px system-ui,sans-serif;border-bottom:1px solid #444">
      ${esc(title)} <span style="float:right;color:#fab219">AWS CLI output (terminal capture), not an AWS Console screenshot</span></div>
    <pre style="margin:0;padding:14px 16px;white-space:pre-wrap;word-break:break-all">${esc(fs.readFileSync(inp, "utf8"))}</pre></body></html>`);
  await p.screenshot({ path: out, fullPage: true });
  await b.close();
})();
