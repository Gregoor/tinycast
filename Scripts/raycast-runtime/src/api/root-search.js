// Tinycast-specific root-search provider API (`@tinycast/api`), plan §2-4. Not part of @raycast/api:
// real Raycast has no result-provider hook, so this only exists in Tinycast.
//
// An extension calls `registerRootSearchProvider({ id, search, perform })` from a command's default
// export. While that command's session stays mounted (Tinycast keeps a mounted session resident
// across keystrokes), Swift asks `search(query, { limit, signal })` per root-query keystroke and
// routes activation of a returned candidate to `perform(resultId)`.

import { hostCall } from "../host.js";

const registered = new Map(); // providerID -> { search, perform }

/// Open a URL in the system's default browser (Safari), the same path `@raycast/api`'s `system.open`
/// uses. Exposed here so Tinycast-specific providers can activate without pulling in `@raycast/api`.
export function open(target, application) {
  return hostCall("system", "open", [String(target), application ?? null]);
}

export function registerRootSearchProvider({ id, search, perform }) {
  const providerID = String(id || "");
  if (!providerID || typeof search !== "function") {
    throw new Error("registerRootSearchProvider needs { id, search }");
  }
  // Register into Swift, then attach the JS callbacks that `__tinycast.rootSearchQuery` routes to.
  const token = hostCall("rootSearch", "register", [providerID]);
  registered.set(providerID, { search, perform: typeof perform === "function" ? perform : null });

  // Unregister is not strictly needed for v1 (a mounted session lives and dies with its command),
  // but it is cheap and lets a command drop its provider without being torn down.
  const unregister = () => {
    registered.delete(providerID);
    return hostCall("rootSearch", "unregister", [providerID]);
  };
  return unregister;
}

/// Swift→JS: run a provider's `search` for a root query. `requestId` lets the reply match the right
/// query even if responses arrive out of order. The JS side starts the (possibly async) search and
/// reports back over hostCall("rootSearch", "results") when it settles.
export function runRootSearchQuery(providerID, query, limit, requestId) {
  const provider = registered.get(String(providerID));
  if (!provider) return "0";
  try {
    const signalBus = {};
    Promise.resolve(provider.search(query, { limit, signal: signalBus })).then(
      (candidates) => {
        const safe = candidates ? normalizeCandidates(candidates) : [];
        hostCall("rootSearch", "results", [String(requestId), safe]);
      },
      (error) => hostCall("rootSearch", "results", [String(requestId), [], String(error?.message ?? error)]),
    );
    return "1";
  } catch (error) {
    hostCall("rootSearch", "results", [String(requestId), [], String(error?.message ?? error)]);
    return "1";
  }
}

/// Swift→JS: run the default action for a selected candidate.
export function runRootSearchPerform(providerID, resultID) {
  const provider = registered.get(String(providerID));
  if (!provider?.perform) return "0";
  try {
    Promise.resolve(provider.perform(String(resultID))).catch(() => {});
    return "1";
  } catch {
    return "1";
  }
}

/// Coerce a provider's returned array into the `{ id, title, subtitle?, keywords? }` shape Swift
/// understands, dropping anything malformed rather than failing the whole query.
function normalizeCandidates(candidates) {
  return candidates
    .filter((c) => c && typeof c === "object" && typeof c.id === "string" && typeof c.title === "string")
    .map((c) => ({
      id: c.id,
      title: c.title,
      subtitle: typeof c.subtitle === "string" ? c.subtitle : undefined,
      keywords: Array.isArray(c.keywords) ? c.keywords.filter((k) => typeof k === "string") : [],
      posterURL: typeof c.posterURL === "string" ? c.posterURL : undefined,
      label: typeof c.label === "string" ? c.label : undefined,
    }));
}

/// The module an extension `require("@tinycast/api")` resolves to. Kept separate so the provider
/// API can grow without touching the rest of the tinycast surface.
export const tinycastApi = { registerRootSearchProvider, open };