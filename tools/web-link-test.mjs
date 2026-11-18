// Headless test of the player's lobby and link (web/lobby.js, web/link.js):
// two pages enter the lobby, chat, one asks the other to race, and their two
// Game Boys link through a race room and race; then a friend's link; then
// leaving.  Run by tools/web-link-test.sh, which starts the servers.
//
//   node tools/web-link-test.mjs PAGE_URL LOBBY_URL SYM_FILE
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const [pageUrl, lobbyUrl, symFile] = process.argv.slice(2);
const require = createRequire(path.join(process.env.PLAYWRIGHT_DIR || process.cwd(), "package.json"));
const { chromium } = require("playwright");
const sym = Object.fromEntries(fs.readFileSync(symFile, "utf8").split("\n")
  .map((l) => /^[0-9a-f]+:([0-9a-f]{4}) (\S+)$/i.exec(l)).filter(Boolean).map((m) => [m[2], parseInt(m[1], 16)]));
const shots = process.env.SHOT_DIR || ".";
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME || "/usr/bin/google-chrome", args: ["--no-sandbox", "--autoplay-policy=no-user-gesture-required"] });
let failures = 0;
const check = (what, ok, detail) => { if (!ok) failures++; console.log(`${ok ? "ok  " : "FAIL"} ${what}${detail === undefined ? "" : ": " + JSON.stringify(detail)}`); };
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

async function open(name, query = "") {
  const context = await browser.newContext({ viewport: { width: 1400, height: 800 } });
  const page = await context.newPage();
  page.logs = [];
  page.on("console", (m) => page.logs.push(m.text()));
  page.on("pageerror", (e) => console.log(`[${name}] PAGE ERROR: ${e.message}`));
  await page.goto(`${pageUrl}?server=${encodeURIComponent(lobbyUrl)}${query}`);
  await page.waitForFunction(() => window.__gb && window.__gb.cable, null, { timeout: 20000 });
  page.label = name;
  return page;
}
const until = async (what, fn, secs = 15) => { for (let i = 0; i < secs * 10; i++) { if (await fn()) return true; await sleep(0.1); } return false; };
const hram = (page, name) => page.evaluate((a) => window.__gb.m._emulator_read_mem(window.__gb.e, a), sym[name]);
const cableState = (page) => page.evaluate(() => window.__gb.cable.state);
const text = (page, sel) => page.locator(sel).innerText();
async function press(page, key, ms = 120) { await page.keyboard.down(key); await sleep(ms / 1000); await page.keyboard.up(key); await sleep(0.12); }
async function toLinkRace(page) {
  await page.locator("canvas").click({ position: { x: 5, y: 5 } });   // (the keyboard to the game, not the name box)
  for (const k of ["ArrowDown", "ArrowDown", "ArrowRight", "ArrowRight"]) await press(page, k);
  await press(page, "KeyX");                                            // GAS: the race screen, 2P
}

const A = await open("A"), B = await open("B");
check("both pages in the lobby", await until("lobby", async () => (await text(A, "#lobbyState")) === "2 here" && (await text(B, "#lobbyState")) === "2 here", 20),
  [await text(A, "#lobbyState"), await text(B, "#lobbyState")]);
await A.fill("#lobbyName", "Alice"); await A.locator("#lobbyName").dispatchEvent("change");
await B.fill("#lobbyName", "Bob"); await B.locator("#lobbyName").dispatchEvent("change");
check("each sees the other's name", await until("names", async () => (await text(A, "#roster")).includes("Bob") && (await text(B, "#roster")).includes("Alice")));

await A.fill("#chatInput", "anyone up for Neo City?"); await A.press("#chatInput", "Enter");
check("a line of chat arrives", await until("chat", async () => (await text(B, "#chatLog")).includes("Alice: anyone up for Neo City?")));
await B.fill("#chatInput", "see my site at example.com"); await B.press("#chatInput", "Enter");
await sleep(0.5);
check("a link is not sent", !(await text(A, "#chatLog")).includes("example") && (await text(B, "#chatHint")).includes("links"), await text(B, "#chatHint"));

// Alice asks Bob; Bob says yes.
await A.locator("#roster li", { hasText: "Bob" }).getByRole("button", { name: "Race" }).click();
check("Bob is asked", await until("ask", async () => B.locator("#ask").isVisible()));
await B.click("#askYes");
check("both in a race room, the cable plugged in", await until("race", async () => (await cableState(A)) !== "unplugged" && (await cableState(B)) !== "unplugged", 20), [await cableState(A), await cableState(B)]);
check("the lobby shows them racing", await until("busy", async () => (await text(A, "#roster")).includes("racing") || (await text(A, "#roster")).includes("race room")), await text(A, "#roster"));

await toLinkRace(A); await toLinkRace(B);
check("both Game Boys wait for a link (2P)", await until("2p", async () => A.evaluate(() => window.__gb.cable.listening()) && B.evaluate(() => window.__gb.cable.listening()) && A.evaluate(() => window.__gb.cable.peer.listening)),
  [await A.evaluate(() => window.__gb.cable.peer), await text(A, "#raceText")]);
await press(A, "Enter");
check("linked: Alice's Game Boy clocks, Bob's answers", await until("linked", async () => (await hram(A, "hLinked")) === 1 && (await hram(B, "hLinked")) === 2, 10),
  [await hram(A, "hLinked"), await hram(B, "hLinked"), await cableState(A), await cableState(B)]);
check("the panel says so", (await text(A, "#raceText")).startsWith("Linked with Bob"), await text(A, "#raceText"));

// Race: both on the gas for 12 s.
await A.keyboard.down("KeyX"); await B.keyboard.down("KeyX");
const seen = { A: new Set(), B: new Set() };
let drops = 0;
for (let i = 0; i < 24; i++) {
  await sleep(0.5);
  for (const [n, p] of [["A", A], ["B", B]]) {
    seen[n].add(await p.evaluate((r) => { const g = window.__gb; const rd = (a) => g.m._emulator_read_mem(g.e, a); return rd(r + 1) | rd(r + 2) << 7; }, sym.wRemote));
    if ((await hram(p, "hLinked")) === 0) drops++;
  }
}
check("still linked after 12 s of racing", drops === 0 && (await hram(A, "hLinked")) === 1 && (await hram(B, "hLinked")) === 2, { drops });
check("each sees the other car move", seen.A.size > 15 && seen.B.size > 15, [seen.A.size, seen.B.size]);
console.log("     cable", await A.evaluate(() => window.__gb.cable.stats), await B.evaluate(() => window.__gb.cable.stats));
await A.screenshot({ path: path.join(shots, "a-racing.png") });
await B.screenshot({ path: path.join(shots, "b-racing.png") });
await A.keyboard.up("KeyX"); await B.keyboard.up("KeyX");

// Bob leaves the race: Alice's cable comes out, her Game Boy gives up the link.
await B.click("#raceEnd");
check("Bob left: Alice's Game Boy drops the link", await until("drop", async () => (await cableState(A)) === "unplugged" && (await hram(A, "hLinked")) === 0, 10), [await cableState(A), await hram(A, "hLinked")]);
await A.click("#raceEnd");

// A friend's link: Alice invites, a third page opens the link.
await A.click("#invite");
const link = await until("link", async () => (await A.locator("#raceLink").getAttribute("href")) || false) && await A.locator("#raceLink").getAttribute("href");
check("an invitation link", /[?&]race=FSUB-[A-Z0-9]{6}/.test(link || ""), link);
const C = await open("C", "&race=" + new URL(link).searchParams.get("race"));
check("the friend's page joins the race", await until("friend", async () => (await cableState(A)) !== "unplugged" && (await cableState(C)) !== "unplugged", 20), [await cableState(A), await cableState(C)]);
await A.screenshot({ path: path.join(shots, "a-friend.png") });

// Phone width: the lobby is a drawer.
await C.setViewportSize({ width: 390, height: 800 });
await C.click("#lobbyClose").catch(() => {});
await sleep(0.4);
await C.screenshot({ path: path.join(shots, "c-phone-shut.png") });
await C.click("#lobbyBtn"); await sleep(0.4);
await C.screenshot({ path: path.join(shots, "c-phone-open.png") });

for (const p of [A, B, C]) { const errs = p.logs.filter((l) => /error|exception/i.test(l)); if (errs.length) console.log(`[${p.label}] console:`, errs.slice(0, 5)); }
console.log(failures ? `${failures} FAILED` : "all ok");
await browser.close();
process.exit(failures ? 1 : 0);
