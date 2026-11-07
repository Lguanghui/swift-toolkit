// Created by Guanghui Liang on 2026/11/7.

import { rangeFromLocator, registerDecorationRoot } from "../src/locator-range";
import { TextQuoteAnchor } from "../src/vendor/hypothesis/anchoring/types";

beforeEach(() => {
  document.body.innerHTML = "";
});
afterEach(() => jest.restoreAllMocks());

test("scopes repeated words to the result and reuses the range for decoration", () => {
  document.body.innerHTML =
    '<p id="a">first needle here</p><p id="b">second needle here</p>';
  const match = jest.spyOn(TextQuoteAnchor.prototype, "toRange");
  const locator = {
    href: "chapter",
    locations: { cssSelector: "#b" },
    text: {
      highlight: "needle",
      before: "first needle here second ",
      after: " here",
    },
  };
  const jump = rangeFromLocator(locator)!;
  const decoration = rangeFromLocator(JSON.parse(JSON.stringify(locator)))!;
  expect(jump.startContainer.parentElement?.id).toBe("b");
  expect(decoration.toString()).toBe("needle");
  expect(match).toHaveBeenCalledTimes(1);
  expect(decoration).not.toBe(jump);
});

test("font changes and decoration insertion do not repeat matching", () => {
  document.body.innerHTML = '<p id="a">a needle here</p>';
  const match = jest.spyOn(TextQuoteAnchor.prototype, "toRange");
  const locator = {
    locations: { cssSelector: "#a" },
    text: { highlight: "needle" },
  };
  rangeFromLocator(locator);
  document.body.style.fontSize = "24px";
  const decoration = document.createElement("div");
  registerDecorationRoot(decoration);
  document.body.appendChild(decoration);
  decoration.appendChild(document.createElement("span"));
  rangeFromLocator(locator);
  expect(match).toHaveBeenCalledTimes(1);
});

test("text edits invalidate cached offsets synchronously", () => {
  document.body.innerHTML = '<p id="a">a needle here</p>';
  const match = jest.spyOn(TextQuoteAnchor.prototype, "toRange");
  const locator = {
    locations: { cssSelector: "#a" },
    text: { highlight: "needle" },
  };
  expect(rangeFromLocator(locator)?.startOffset).toBe(2);
  document.getElementById("a")!.firstChild!.textContent =
    "a longer needle here";
  expect(rangeFromLocator(locator)?.startOffset).toBe(9);
  expect(match).toHaveBeenCalledTimes(2);
});

test("selector changes and replacement chapters invalidate cached ranges", () => {
  document.body.innerHTML =
    '<p id="a">first needle</p><p id="b">second needle</p>';
  const locator = {
    locations: { cssSelector: "#a" },
    text: { highlight: "needle" },
  };
  rangeFromLocator(locator);
  document.getElementById("a")!.id = "old";
  document.getElementById("b")!.id = "a";
  expect(rangeFromLocator(locator)?.startContainer.parentElement?.id).toBe("a");
  document.body.innerHTML = '<p id="a">replacement needle</p>';
  expect(rangeFromLocator(locator)?.startOffset).toBe(12);
});

test("different hits in one paragraph use their respective contexts", () => {
  document.body.innerHTML = '<p id="a">first needle then second needle</p>';
  const base = { locations: { cssSelector: "#a" } };
  const first = rangeFromLocator({
    ...base,
    text: {
      highlight: "needle",
      before: "first ",
      after: " then second needle",
    },
  })!;
  const second = rangeFromLocator({
    ...base,
    text: { highlight: "needle", before: "first needle then second " },
  })!;
  expect(first.startOffset).toBe(6);
  expect(second.startOffset).toBe(25);
});

test("cross-element matches retain the document fallback", () => {
  document.body.innerHTML = "<p>The quick </p><p>brown fox.</p>";
  expect(
    rangeFromLocator({ text: { highlight: "quick brown" } })?.toString()
  ).toBe("quick brown");
});

test("inline markup, br, CJK, emoji and combining characters retain the exact range", () => {
  document.body.innerHTML = '<p id="a">前言<br/>夜灯 <em>café 👩🏽‍🚀</em> 后文</p>';
  const range = rangeFromLocator({
    locations: { cssSelector: "#a" },
    text: { highlight: "夜灯 café 👩🏽‍🚀", before: "前言 ", after: " 后文" },
  })!;
  expect(range.toString()).toBe("夜灯 café 👩🏽‍🚀");
});

test("identical text in different chapters does not share a cache entry", () => {
  document.body.innerHTML = '<p id="a">needle</p>';
  const match = jest.spyOn(TextQuoteAnchor.prototype, "toRange");
  const locator = {
    locations: { cssSelector: "#a" },
    text: { highlight: "needle" },
  };
  rangeFromLocator({ ...locator, href: "chapter1" });
  rangeFromLocator({ ...locator, href: "chapter2" });
  expect(match).toHaveBeenCalledTimes(2);
});

test("attribute-based selectors are re-evaluated after edits", () => {
  document.body.innerHTML =
    '<p data-key="hit">first needle</p><p>second needle</p>';
  const locator = {
    locations: { cssSelector: '[data-key="hit"]' },
    text: { highlight: "needle" },
  };
  rangeFromLocator(locator);
  document.querySelector("p")!.removeAttribute("data-key");
  document.querySelectorAll("p")[1].setAttribute("data-key", "hit");
  expect(rangeFromLocator(locator)?.startOffset).toBe(7);
});
