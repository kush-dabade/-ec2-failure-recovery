// Evidence tool: keeps ONE real browser session open on the live dashboard (so its
// timeline and run-result accumulate across the whole experiment), clicks
// "Start normal operation", then takes a screenshot whenever a request file appears.
//
//   node dashboard_watch.js <dashboard-url> <evidence-dir> <request-dir>
//   touch <request-dir>/<name>            -> <evidence-dir>/<name>.png (full page)
//   touch <request-dir>/<name>@<selector> -> element screenshot
//   touch <request-dir>/dump              -> raw/dashboard-<time>.txt (timeline + run result text)
//   touch <request-dir>/quit              -> exit
const { chromium } = require("playwright-core");
const fs = require("fs");
const path = require("path");

const [url, evDir, reqDir] = process.argv.slice(2);
const exe = process.env.HOME + "/.cache/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-linux64/chrome-headless-shell";

(async () => {
  const browser = await chromium.launch({ executablePath: exe });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, colorScheme: "light" });
  page.on("pageerror", (e) => console.log("PAGE ERROR:", e.message));
  await page.goto(url, { waitUntil: "load" });
  await page.waitForSelector(".inst", { timeout: 30000 });
  await page.click("#btn-start");
  console.log("READY", new Date().toISOString());
  fs.mkdirSync(reqDir, { recursive: true });
  for (;;) {
    for (const f of fs.readdirSync(reqDir).sort()) {
      fs.unlinkSync(path.join(reqDir, f));
      if (f === "quit") { await browser.close(); return; }
      if (f === "dump") {
        const text = await page.evaluate(() => [
          "OVERALL: " + document.getElementById("overall-text").textContent,
          "KPIs: " + [...document.querySelectorAll(".kpi")].map((k) => k.innerText.replace(/\s+/g, " ")).join(" | "),
          "\n=== RUN RESULT ===\n" + (document.getElementById("summary-card").hidden ? "(none)" : document.getElementById("summary-card").innerText),
          "\n=== INSTANCES ===\n" + document.getElementById("instances").innerText,
          "\n=== TIMELINE (newest first) ===\n" + document.getElementById("timeline").innerText,
        ].join("\n"));
        const out = path.join(evDir, "raw", `dashboard-dump-${new Date().toISOString().replace(/[:.]/g, "-")}.txt`);
        fs.writeFileSync(out, text);
        console.log("DUMP", out);
        continue;
      }
      const [name, selector] = f.split("@");
      const out = path.join(evDir, `${name}.png`);
      if (selector) await page.locator(selector.replace(/__/g, " ")).first().screenshot({ path: out });
      else await page.screenshot({ path: out, fullPage: true });
      console.log("SHOT", out, new Date().toISOString());
    }
    await new Promise((r) => setTimeout(r, 300));
  }
})().catch((e) => { console.error(e); process.exit(1); });
