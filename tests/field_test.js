// Run with: deno test --allow-read tests/field_test.js
// Loads src/ui/FieldLogic.js (a QML .pragma library) as plain JS.
import { assertEquals, assert } from "jsr:@std/assert@1";

const src = Deno.readTextFileSync(new URL("../src/ui/FieldLogic.js", import.meta.url))
  .replace(/^\.pragma library\s*$/m, "");
const names = [...src.matchAll(/^function (\w+)/gm)].map((m) => m[1]);
const F = new Function(src + "\nreturn {" + names.join(",") + ", MAX_PASTE};")();

Deno.test("typing inserts at the cursor and moves it", () => {
  let s = F.state("ac", 1);
  s = F.insert(s, "b", 0);
  assertEquals([s.text, s.cursor, s.anchor], ["abc", 2, 2]);
});

Deno.test("typing replaces the selection", () => {
  let s = F.selectAll(F.state("hello"));
  s = F.insert(s, "x", 0);
  assertEquals([s.text, s.cursor], ["x", 1]);
});

Deno.test("maxLength truncates what is inserted, counting the replaced selection", () => {
  let s = F.state("abcd", 4);
  assertEquals(F.insert(s, "efgh", 6).text, "abcdef");
  s = F.selectAll(s);
  assertEquals(F.insert(s, "123456789", 6).text, "123456");
  assertEquals(F.insert(F.state("abcdef", 6), "x", 6).text, "abcdef");
});

Deno.test("control characters never enter; line breaks become spaces", () => {
  assertEquals(F.sanitize("a\u0000b\u001bc"), "abc");
  assertEquals(F.sanitize("one\r\ntwo\tthree"), "one two three");
  assertEquals(F.sanitize("12a3 4", true), "1234");
});

Deno.test("backspace and delete, by character and by word", () => {
  assertEquals(F.backspace(F.state("abc", 3)).text, "ab");
  assertEquals(F.backspace(F.state("abc", 0)).text, "abc");
  assertEquals(F.del(F.state("abc", 0)).text, "bc");
  assertEquals(F.del(F.state("abc", 3)).text, "abc");
  assertEquals(F.backspace(F.state("foo bar", 7), true).text, "foo ");
  assertEquals(F.del(F.state("foo bar", 0), true).text, " bar");
  assertEquals(F.backspace(F.selectAll(F.state("abc"))).text, "");
});

Deno.test("word boundaries work without engine-specific regex features", () => {
  assert(F.isWordChar("a") && F.isWordChar("Z") && F.isWordChar("7") && F.isWordChar("_"));
  assert(F.isWordChar("\u05e9") && F.isWordChar("\u00e9"));
  for (const ch of [" ", "-", ".", ",", "/", "@", "[", "^", "`", "{", "~", "\t"]) assert(!F.isWordChar(ch), ch);
  assertEquals(F.backspace(F.state("foo-bar baz", 7), true).text, "foo- baz");
  assertEquals(F.move(F.state("שלום עולם", 9), "left", { word: true }).cursor, 5);
});

Deno.test("an emoji is never split", () => {
  const s = F.state("a\u{1F600}b", 3);
  assertEquals(F.backspace(s).text, "ab");
  assertEquals(F.move(F.state("\u{1F600}", 0), "right").cursor, 2);
  assertEquals(F.del(F.state("\u{1F600}x", 0)).text, "x");
});

Deno.test("cursor movement and selection", () => {
  let s = F.state("hello world", 5);
  assertEquals(F.move(s, "home").cursor, 0);
  assertEquals(F.move(s, "end").cursor, 11);
  assertEquals(F.move(s, "right", { word: true }).cursor, 11);
  assertEquals(F.move(s, "left", { word: true }).cursor, 0);
  const ext = F.move(s, "right", { extend: true });
  assertEquals([ext.anchor, ext.cursor], [5, 6]);
  assertEquals(F.selectedText(ext), " ");
  // collapsing a selection with an arrow key lands on its edge
  const sel = { text: "abcdef", cursor: 4, anchor: 1 };
  assertEquals(F.move(sel, "left").cursor, 1);
  assertEquals(F.move(sel, "right").cursor, 4);
});

Deno.test("indices are clamped", () => {
  assertEquals(F.state("abc", 99).cursor, 3);
  assertEquals(F.state("abc", -4).cursor, 0);
  assertEquals(F.state(null, 2).text, "");
  assertEquals(F.setCursor(F.state("abc"), 10).cursor, 3);
});

Deno.test("click position picks the nearest boundary", () => {
  const advance = (n) => n * 10;
  assertEquals(F.indexAtX("abcd", -5, advance), 0);
  assertEquals(F.indexAtX("abcd", 14, advance), 1);
  assertEquals(F.indexAtX("abcd", 16, advance), 2);
  assertEquals(F.indexAtX("abcd", 999, advance), 4);
  assertEquals(F.indexAtX("", 5, advance), 0);
});

Deno.test("password mask has one dot per character", () => {
  assertEquals(F.mask("abc"), "•••");
  assertEquals(F.mask(""), "");
});

Deno.test("paste is bounded", () => {
  assert(F.MAX_PASTE <= 8192);
});
