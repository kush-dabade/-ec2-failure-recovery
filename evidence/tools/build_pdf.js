// Prints build/report.html (images resolved relative to the project root) to the PDF.
const { chromium } = require("playwright-core");
const path = require("path");
const [root] = process.argv.slice(2);
(async () => {
  const b = await chromium.launch({ executablePath: process.env.HOME + "/.cache/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-linux64/chrome-headless-shell" });
  const p = await b.newPage();
  const fs = require("fs");
  const src = path.join(root, "build", "report.html");
  const printable = path.join(root, "build", "report.print.html");
  fs.writeFileSync(printable, fs.readFileSync(src, "utf8").replace("<head>", `<head><base href="file://${root}/">`));
  await p.goto("file://" + printable, { waitUntil: "load" });
  const broken = await p.evaluate(() => [...document.images].filter((i) => !i.complete || i.naturalWidth === 0).map((i) => i.src));
  if (broken.length) { console.error("BROKEN IMAGES", broken); process.exit(1); }
  await p.pdf({ path: path.join(root, "EC2_Virtual_Machine_Failure_Experiment_Report.pdf"), format: "A4", printBackground: true,
    displayHeaderFooter: true, headerTemplate: "<span></span>",
    footerTemplate: '<div style="font:8px sans-serif;color:#777;width:100%;text-align:center">EC2 Virtual Machine Failure Experiment · page <span class="pageNumber"></span> of <span class="totalPages"></span></div>',
    margin: { top: "16mm", bottom: "18mm", left: "15mm", right: "15mm" } });
  console.log("images:", await p.evaluate(() => document.images.length));
  await b.close();
})();
