// Run with: TZ=UTC deno test --allow-read tests/model_test.js
// Loads src/ui/Model.js (a QML .pragma library) as plain JS.
import { assertEquals, assert } from "jsr:@std/assert@1";

const src = Deno.readTextFileSync(new URL("../src/ui/Model.js", import.meta.url))
  .replace(/^\.pragma library\s*$/m, "");
const names = [...src.matchAll(/^function (\w+)/gm)].map((m) => m[1]);
const M = new Function(src + "\nreturn {" + names.join(",") + ", DEFAULTS};")();
const cases = JSON.parse(Deno.readTextFileSync(new URL("./time_cases.json", import.meta.url)));

const NOW = Date.parse("2026-09-26T15:30:00Z");
const e = (id, start, stop, extra = {}) => ({
  id, description: "Research", projectId: 2, projectName: "Generic", projectColor: "#465bb3",
  tags: [], billable: false, start, stop, seconds: stop ? (Date.parse(stop) - Date.parse(start)) / 1000 : null, ...extra,
});

Deno.test("TZ is UTC for deterministic day keys", () => {
  assertEquals(new Date(0).getTimezoneOffset(), 0);
});

Deno.test("parseWhen matches python cases", () => {
  for (const [text, expected] of Object.entries(cases)) {
    assertEquals(M.toIso(M.parseWhen(text, NOW)), expected, text);
  }
  assert(isNaN(M.parseWhen("25:00", NOW)));
  assert(isNaN(M.parseWhen("banana", NOW)));
});

Deno.test("formatting", () => {
  assertEquals(M.hms(1805), "0:30:05");
  assertEquals(M.hms(12 * 3600 + 9 * 60 + 42), "12:09:42");
  assertEquals(M.hm(3 * 3600 + 23 * 60 + 38), "3:23");
  assertEquals(M.dayLabel("2026-09-26", "2026-09-26"), "Today");
  assertEquals(M.dayLabel("2026-09-25", "2026-09-26"), "Yesterday");
  assertEquals(M.dayLabel("2026-09-24", "2026-09-26"), "Thu, 24 Sep");
  assertEquals(M.elide("Generic project", 5), "Gene…");
});

Deno.test("groupEntries groups similar entries per day, running first", () => {
  const entries = [
    e(1, "2026-09-26T14:00:00Z", null, { projectId: 3, projectName: "stonks" }),
    e(2, "2026-09-26T12:00:00Z", "2026-09-26T13:00:00Z", { projectId: 3, projectName: "stonks" }),
    e(3, "2026-09-26T10:00:00Z", "2026-09-26T11:00:00Z", { projectId: 3, projectName: "stonks" }),
    e(4, "2026-09-26T08:00:00Z", "2026-09-26T09:00:00Z"),
    e(5, "2026-09-25T08:00:00Z", "2026-09-25T09:30:00Z", { description: "stuff" }),
  ];
  const rows = M.groupEntries(entries, { todayKey: "2026-09-26" }, NOW);
  assertEquals(rows.map((r) => r.kind), ["day", "entry", "group", "entry", "day", "entry"]);
  assertEquals(rows[0].label, "Today");
  assertEquals(rows[0].total, 1.5 * 3600 + 3 * 3600);
  assert(rows[1].running);
  assertEquals(rows[2].count, 2);
  assertEquals(rows[2].seconds, 7200);
  assertEquals(rows[4].label, "Yesterday");
  const expanded = M.groupEntries(entries, { todayKey: "2026-09-26", expanded: { [rows[2].key]: true } }, NOW);
  assertEquals(expanded.filter((r) => r.child).length, 2);
  const flat = M.groupEntries(entries, { todayKey: "2026-09-26", groupSimilar: false }, NOW);
  assertEquals(flat.filter((r) => r.kind === "group").length, 0);
  const filtered = M.groupEntries(entries, { todayKey: "2026-09-26", projectFilter: "none" }, NOW);
  assertEquals(filtered.length, 0);
  const q = M.groupEntries(entries, { todayKey: "2026-09-26", query: "stuff" }, NOW);
  assertEquals(q.length, 2);
});

Deno.test("rangeStats splits midnight and includes the running entry", () => {
  const entries = [
    e(1, "2026-09-25T23:00:00Z", "2026-09-26T01:00:00Z", { billable: true }),
    e(2, "2026-09-26T15:00:00Z", null, { projectId: null, projectName: null, projectColor: null }),
  ];
  const s = M.rangeStats(entries, "2026-09-26", "2026-09-26", NOW);
  assertEquals(s.total, 3600 + 1800);
  assertEquals(s.billable, 3600);
  assertEquals(s.byProject[0].name, "Generic");
  assertEquals(s.byProject[1].name, "(No project)");
  assertEquals(s.byProject[1].color, "");
  const leg = M.legend(s);
  assertEquals(Math.round(leg[0].share * 100), 67);
  const week = M.rangeStats(entries, "2026-09-21", "2026-09-27", NOW);
  assertEquals(week.byDay.length, 7);
  const ts = M.timesheet(week);
  assertEquals(ts.rows[0].cells[4], 3600); // Fri 25th
  assertEquals(ts.rows[0].cells[5], 3600); // Sat 26th
});

Deno.test("suggest modes", () => {
  const entries = [e(1, "2026-09-26T08:00:00Z", "2026-09-26T09:00:00Z"), e(2, "2026-09-26T07:00:00Z", "2026-09-26T07:30:00Z")];
  const projects = [{ id: 1, name: "Snowball", color: "#c7741c" }, { id: 4, name: "Client Work", color: "#111111" }];
  assertEquals(M.suggest("Res", entries, projects, []).length, 1);
  const p = M.suggest("Research @cli", entries, projects, []);
  assertEquals(p[0].completion, 'Research @"Client Work" ');
  const t = M.suggest("x #de", entries, projects, [{ name: "deep" }]);
  assertEquals(t[0].completion, "x #deep ");
});

Deno.test("ranges and weeks", () => {
  assertEquals(M.weekStartKey("2026-09-26", 1), "2026-09-21");
  assertEquals(M.weekStartKey("2026-09-26", 0), "2026-09-20");
  const w = M.rangeFor("week", "2026-09-26", "2026-09-26", 7, 1);
  assertEquals([w.from, w.to, w.label], ["2026-09-21", "2026-09-27", "This week"]);
  assertEquals(M.rangeFor("week", "2026-09-19", "2026-09-26", 7, 1).label, "Last week");
  const all = M.rangeFor("all", "2026-09-26", "2026-09-26", 7, 1);
  assertEquals(all.from, "2026-09-20");
  assertEquals(M.stepRange("day", "2026-09-01", -1), "2026-08-31");
  const state = { config: { historyDays: 7 }, entries: [], running: null, ranges: {} };
  assert(M.entriesFor(state, "2026-09-21", "2026-09-27", "2026-09-26").covered);
  assert(!M.entriesFor(state, "2026-09-14", "2026-09-20", "2026-09-26").covered);
  state.ranges["2026-09-14_2026-09-20"] = { entries: [e(9, "2026-09-15T08:00:00Z", "2026-09-15T09:00:00Z")] };
  assertEquals(M.entriesFor(state, "2026-09-14", "2026-09-20", "2026-09-26").entries.length, 1);
});

Deno.test("dayBlocks lanes overlapping entries", () => {
  const entries = [
    e(1, "2026-09-26T09:00:00Z", "2026-09-26T10:00:00Z"),
    e(2, "2026-09-26T09:30:00Z", "2026-09-26T11:00:00Z"),
    e(3, "2026-09-26T12:00:00Z", "2026-09-26T12:30:00Z"),
  ];
  const b = M.dayBlocks(entries, "2026-09-26", NOW);
  assertEquals(b.map((x) => [x.startMin, x.lane, x.lanes]), [[540, 0, 2], [570, 1, 2], [720, 0, 1]]);
});

Deno.test("parseState guards schema", () => {
  assertEquals(M.parseState("{bad").entries.length, 0);
  assertEquals(M.parseState('{"schema":2,"entries":[1]}').entries.length, 0);
  assertEquals(M.parseState('{"schema":1,"entries":[{"id":1}]}').entries.length, 1);
  assertEquals(M.setting({}, "syncMinutes"), 5);
  assertEquals(M.setting({ syncMinutes: 10 }, "syncMinutes"), 10);
});

Deno.test("flag accepts booleans and string forms", () => {
  assertEquals([true, "true", undefined, 1].map(M.flag), [true, true, true, true]);
  assertEquals([false, "false", 0, "0"].map(M.flag), [false, false, false, false]);
});

Deno.test("timer mode cycles and honours legacy showSeconds", () => {
  assertEquals(M.timerMode({}), "hms");
  assertEquals(M.timerMode({ showSeconds: false }), "hm");
  assertEquals(M.timerMode({ showSeconds: "false" }), "hm");
  assertEquals(M.timerMode({ timerMode: "hidden", showSeconds: true }), "hidden");
  assertEquals(M.timerMode({ timerMode: "bogus" }), "hms");
  assertEquals(["hms", "hm", "hidden"].map(M.nextTimerMode), ["hm", "hidden", "hms"]);
});

Deno.test("escapeMarkup neutralises notification markup", () => {
  assertEquals(M.escapeMarkup('a <img src="http://x/y.png"> & <b>b</b>'),
    'a &lt;img src="http://x/y.png"&gt; &amp; &lt;b&gt;b&lt;/b&gt;');
  assertEquals(M.escapeMarkup(null), "");
});

Deno.test("parseWhen rejects out-of-range times", () => {
  assert(isNaN(M.parseWhen("+99999999999999h", NOW)));
  assert(isNaN(M.parseWhen("-99999999999999m", NOW)));
});
