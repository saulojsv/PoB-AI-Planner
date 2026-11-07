// Supported poe.ninja public economy API client for the local MCP companion.
// Never use builds/profiles endpoints: they are explicitly outside the public API.

const API_ROOT = "https://poe.ninja/poe1/api/economy";
const CACHE_MS = 5 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const ITEM_CATEGORIES = [
  "UniqueWeapon", "UniqueArmour", "UniqueAccessory", "UniqueFlask",
  "UniqueJewel", "ForbiddenJewel", "UniqueTincture", "UniqueRelic", "ClusterJewel",
];

function normalizedName(value) {
  return String(value ?? "").normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function isUnique(item) {
  const rarity = item?.rarity;
  return typeof rarity === "string" ? /unique/i.test(rarity) : rarity === 3;
}

function mergeItems(snapshot) {
  const items = new Map();
  for (const item of [...(snapshot?.availableItems ?? []), ...Object.values(snapshot?.items ?? {})]) {
    if (!Number.isInteger(item?.id) || item.id <= 0) continue;
    const previous = items.get(item.id);
    items.set(item.id, previous ? { ...previous, ...item } : item);
  }
  return [...items.values()];
}

function choosePrice(lines, item) {
  const name = normalizedName(item?.name);
  if (!name) return null;
  const matches = lines.filter((line) => normalizedName(line?.name) === name
    && Number.isFinite(line?.chaosValue) && line.chaosValue > 0
    && Number.isFinite(line?.listingCount) && line.listingCount > 0);
  if (matches.length === 0) return null;
  // Same-name variants can differ in value. Use the highest current estimate
  // so the budget gate does not underprice a roll we cannot identify exactly.
  matches.sort((a, b) => b.chaosValue - a.chaosValue || (b.listingCount ?? 0) - (a.listingCount ?? 0));
  const selected = matches[0];
  return {
    chaosValue: selected.chaosValue,
    divineValue: Number.isFinite(selected.divineValue) && selected.divineValue > 0 ? selected.divineValue : null,
    listingCount: selected.listingCount,
    observationCount: Number.isFinite(selected.count) ? selected.count : null,
    variantsConsidered: matches.length,
    match: "exact_name_conservative_variant",
  };
}

export function createMarketProvider({
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  cache = new Map(),
  userAgent = "PathOfBuildingCommunity-AIPlanner-MCP/0.1 (https://github.com/PathOfBuildingCommunity/PathOfBuilding)",
} = {}) {
  if (typeof fetchImpl !== "function") throw new Error("A fetch implementation is required for market pricing.");

  async function requestJson(url) {
    const cached = cache.get(url);
    if (cached && now() < cached.expiresAt) return cached.value;
    const headers = { "User-Agent": userAgent, "Accept": "application/json" };
    if (cached?.etag) headers["If-None-Match"] = cached.etag;
    if (cached?.lastModified) headers["If-Modified-Since"] = cached.lastModified;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    let response;
    let value;
    try {
      response = await fetchImpl(url, { method: "GET", headers, signal: controller.signal });
      if (response.status === 304 && cached) {
        cached.expiresAt = now() + CACHE_MS;
        return cached.value;
      }
      if (!response.ok) throw new Error(`poe.ninja economy API returned HTTP ${response.status}.`);
      const contentLength = Number(response.headers?.get?.("content-length"));
      if (Number.isFinite(contentLength) && contentLength > MAX_RESPONSE_BYTES) {
        throw new Error("poe.ninja economy response exceeded the local size limit.");
      }
      if (typeof response.text === "function") {
        const body = await response.text();
        if (Buffer.byteLength(body, "utf8") > MAX_RESPONSE_BYTES) {
          throw new Error("poe.ninja economy response exceeded the local size limit.");
        }
        try { value = JSON.parse(body); }
        catch { throw new Error("poe.ninja economy API returned malformed JSON."); }
      } else {
        value = await response.json();
      }
    } finally {
      clearTimeout(timer);
    }
    if (!value || typeof value !== "object") throw new Error("poe.ninja economy API returned an invalid JSON object.");
    cache.set(url, {
      value,
      etag: response.headers?.get?.("etag") ?? cached?.etag ?? null,
      lastModified: response.headers?.get?.("last-modified") ?? cached?.lastModified ?? null,
      expiresAt: now() + CACHE_MS,
    });
    return value;
  }

  async function listLeagues() {
    const data = await requestJson(`${API_ROOT}/leagues`);
    if (!Array.isArray(data)) throw new Error("poe.ninja returned an invalid league list.");
    return data.filter((entry) => typeof entry?.id === "string" && typeof entry?.name === "string")
      .map(({ id, name }) => ({ id: id.slice(0, 80), name: name.slice(0, 100) }));
  }

  async function quoteBuildItems(snapshot, requestedLeague) {
    const leagues = await listLeagues();
    const league = requestedLeague
      ? leagues.find((entry) => entry.id === requestedLeague)
      : leagues[0];
    if (!league) throw new Error(requestedLeague
      ? `League '${requestedLeague}' is not listed by poe.ninja's economy API.`
      : "poe.ninja did not report an active Path of Exile economy league.");

    // Fetch only documented item-overview categories. They are sequential to
    // keep concurrency low; the five-minute cache prevents redundant traffic.
    const categoryLines = new Map();
    for (const category of ITEM_CATEGORIES) {
      const url = `${API_ROOT}/stash/current/item/overview?league=${encodeURIComponent(league.id)}&type=${encodeURIComponent(category)}`;
      const data = await requestJson(url);
      if (!Array.isArray(data.lines)) throw new Error(`poe.ninja returned an invalid ${category} overview.`);
      for (const line of data.lines) {
        const key = normalizedName(line?.name);
        if (!key) continue;
        const matches = categoryLines.get(key) ?? [];
        matches.push(line);
        categoryLines.set(key, matches);
      }
    }

    const itemQuotes = {};
    const unmatched = [];
    const seen = new Set();
    for (const item of mergeItems(snapshot)) {
      if (seen.has(item.id)) continue;
      seen.add(item.id);
      if (!isUnique(item)) {
        unmatched.push({ itemId: item.id, name: String(item.name ?? "Unknown item").slice(0, 128), reason: "manual_price_required_for_non_unique_item" });
        continue;
      }
      const price = choosePrice(categoryLines.get(normalizedName(item.name)) ?? [], item);
      if (!price) {
        unmatched.push({ itemId: item.id, name: String(item.name ?? "Unknown item").slice(0, 128), reason: "no_current_unique_listing_match" });
        continue;
      }
      itemQuotes[item.id] = {
        ...price,
        source: "poe.ninja",
        league: league.id,
      };
    }

    let divineChaosRate = null;
    const currencyUrl = `${API_ROOT}/stash/current/currency/overview?league=${encodeURIComponent(league.id)}&type=Currency`;
    const currencyData = await requestJson(currencyUrl);
    const divine = Array.isArray(currencyData.lines)
      ? currencyData.lines.find((entry) => normalizedName(entry?.currencyTypeName) === "divine orb")
      : null;
    if (Number.isFinite(divine?.chaosEquivalent) && divine.chaosEquivalent > 0) {
      divineChaosRate = divine.chaosEquivalent;
    }

    const budgetQuotes = Object.fromEntries(Object.entries(itemQuotes).map(([itemId, quote]) => [itemId, {
      chaosValue: quote.chaosValue,
      listingCount: quote.listingCount,
    }]));
    const budgetSnapshot = {
      provider: "poe.ninja documented economy overview API",
      source: "poe.ninja",
      league,
      capturedAtUnixMs: now(),
      divineChaosRate,
      quotes: budgetQuotes,
    };
    return {
      provider: "poe.ninja documented economy overview API",
      source: "poe.ninja",
      game: "Path of Exile 1",
      league,
      capturedAtUnixMs: now(),
      cacheTtlMs: CACHE_MS,
      divineChaosRate,
      priceSemantics: "Market estimates from current economy overviews; not exact listing quotes. Ambiguous same-name variants use the highest observed estimate.",
      quotes: itemQuotes,
      budgetSnapshot,
      unmatched,
      itemCount: Object.keys(itemQuotes).length,
    };
  }

  return { listLeagues, quoteBuildItems };
}

export const marketConstants = { API_ROOT, CACHE_MS, MAX_RESPONSE_BYTES, ITEM_CATEGORIES };
