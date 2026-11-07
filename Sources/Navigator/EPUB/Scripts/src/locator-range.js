// Created by Guanghui Liang on 2026/11/7.

import { TextQuoteAnchor } from "./vendor/hypothesis/anchoring/types";

// Only the most recent range is retained: navigating and decorating the same
// match share it without retaining an unbounded number of DOM nodes.
let cached;
let observedBody;
let observer;
const decorationRoots = new WeakSet();

export function registerDecorationRoot(root) {
  decorationRoots.add(root);
}

function isDecoration(node) {
  for (let current = node; current; current = current.parentNode) {
    if (decorationRoots.has(current)) return true;
  }
  return false;
}

function invalidate(records) {
  if (
    records.some((record) => {
      if (isDecoration(record.target)) return false;
      if (record.type === "attributes" && record.attributeName === "style")
        return false;
      if (record.type !== "childList") return true;
      return [
        ...Array.from(record.addedNodes),
        ...Array.from(record.removedNodes),
      ].some((node) => !isDecoration(node));
    })
  ) {
    cached = undefined;
  }
}

function prepareCache() {
  if (observedBody !== document.body) {
    observer?.disconnect();
    observedBody = document.body;
    cached = undefined;
    observer = new MutationObserver(invalidate);
    observer.observe(document.body, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
    });
  }
  // MutationObserver callbacks are asynchronous. Drain pending edits before
  // reusing a live Range, including edits made in the same JavaScript task.
  if (observer) invalidate(observer.takeRecords());
}

export function rangeFromLocator(locator) {
  prepareCache();
  const { locations, text } = locator;
  const key = JSON.stringify([
    locator.href,
    locations?.cssSelector,
    locations?.fragments,
    text?.highlight,
    text?.before,
    text?.after,
  ]);
  if (
    cached?.key === key &&
    cached.range.startContainer.isConnected &&
    cached.range.endContainer.isConnected
  ) {
    return cached.range.cloneRange();
  }

  let range = null;
  if (text?.highlight) {
    const scopedRoot = locations?.cssSelector
      ? document.querySelector(locations.cssSelector)
      : null;
    const root = scopedRoot ?? document.body;
    const anchor = new TextQuoteAnchor(root, text.highlight, {
      prefix: text.before,
      suffix: text.after,
    });
    range = anchor.toRange();
  } else if (locations) {
    let element = locations.cssSelector
      ? document.querySelector(locations.cssSelector)
      : null;
    if (!element) {
      for (const id of locations.fragments ?? []) {
        element = document.getElementById(id);
        if (element) break;
      }
    }
    if (element) {
      range = document.createRange();
      range.setStartBefore(element);
      range.setEndAfter(element);
    }
  }
  cached = range ? { key, range: range.cloneRange() } : undefined;
  return range;
}
