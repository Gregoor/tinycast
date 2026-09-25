// JS-bridge round-trip for the root-search provider (plan §2-4): an extension registers a provider
// via `@tinycast/api`, Swift fires `__tinycast.rootSearchQuery`, and the async `search` result comes
// back over hostCall("rootSearch","results"). Drives the REAL generated runtime in a bare `vm`
// context (closest to JavaScriptCore Node offers), exactly like `test.mjs`.
//
//   node Scripts/raycast-runtime/root-search-fixture.mjs

import { createContext, runInContext } from "node:vm";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { transformSync } from "esbuild";
import { cpus, freemem, homedir, loadavg, tmpdir, uptime } from "node:os";
import * as fs from "node:fs";
import * as zlib from "node:zlib";

const runtimePath = [
  resolve("Tinycast/Resources/RaycastRuntime.generated.js"),
  resolve("../../Tinycast/Resources/RaycastRuntime.generated.js"),
].find(existsSync);
const runtime = readFileSync(runtimePath, "utf8");

let pass = 0;
let fail = 0;
const check = (label, cond, extra = "") => {
  if (cond) pass++;
  else { fail++; console.log(`  FAIL ${label}${extra ? ` — ${extra}` : ""}`); }
};

// Mutable test-observable host state, declared before the harness so the stubs can close over it.
const hostState = {
  registered: [],
  unregistered: [],
  results: [],
  performed: [],
};

function createHarness() {
  const context = createContext({});
  const timers = new Map();
  const state = { hostCalls: [] };
  const host = {
    log(level, message) { console.log(`  [${level}] ${message}`); },
    render() {},
    failed(sessionId, message) { state.fail = message; },
    navigationDepthChanged() {},
    finished() {},
    fieldCommand() {},
    startTimer(id, ms, repeats) {
      const fire = () => runInContext(`__tinycast.fireTimer(${JSON.stringify(id)})`, context);
      timers.set(id, repeats ? setInterval(fire, Math.max(ms, 1)) : setTimeout(fire, ms));
    },
    clearTimer(id) {
      const h = timers.get(id);
      if (h) { clearTimeout(h); clearInterval(h); timers.delete(id); }
    },
    invoke(callId, api, method, argsJson) {
      const name = `${api}.${method}`;
      state.hostCalls.push(name);
      const args = JSON.parse(argsJson);
      Promise.resolve(stub(api, method, args)).then(
        (value) => settle(callId, true, value),
        (error) => settle(callId, false, String(error?.message ?? error)),
      );
    },
    invokeSync(api, method, argsJson) {
      return JSON.stringify({ ok: true, value: syncHost(api, method, JSON.parse(argsJson)) });
    },
  };
  function settle(callId, ok, value) {
    runInContext(
      `__tinycast.settle(${JSON.stringify(String(callId))}, ${ok}, ${JSON.stringify(value === undefined ? "" : JSON.stringify(value))})`,
      context,
    );
  }
  context.__tinycastHost = host;
  context.__tinycastCompile = (code, filename) =>
    runInContext(`(function (exports, require, module, __filename, __dirname) {\n${code}\n})`, context, { filename });
  runInContext(runtime, context, { filename: "RaycastRuntime.generated.js" });
  return {
    context, state,
    call: (expr) => runInContext(expr, context),
    boot: () => runInContext(`__tinycast.boot(JSON.stringify(JSON.stringify(${JSON.stringify(bootCfg())})))`, context),
    start: (sid, code, filename, dirname_, mode, ctx) =>
      runInContext(`__tinycast.start(${JSON.stringify(sid)}, ${JSON.stringify(code)}, ${JSON.stringify(filename)}, ${JSON.stringify(dirname_)}, ${JSON.stringify(mode)}, ${JSON.stringify(JSON.stringify(ctx))})`, context),
    stop: (sid) => runInContext(`__tinycast.stop(${JSON.stringify(sid)})`, context),
  };
}

function bootCfg() {
  return {
    node: { arch: "arm64", env: { HOME: homedir(), PATH: process.env.PATH }, cwd: homedir(), homedir: homedir(), tmpdir: tmpdir() },
    environment: { extensionName: "probe", commandName: "probe", commandMode: "no-view", isDevelopment: false, raycastVersion: "2.0.3" },
    preferences: {}, caches: {},
  };
}
function stub(api, method, args) {
  switch (`${api}.${method}`) {
    case "rootSearch.register": hostState.registered.push(args[0]); return { ok: true };
    case "rootSearch.unregister": hostState.unregistered.push(args[0]); return null;
    case "rootSearch.results":
      hostState.results.push({ requestId: args[0], candidates: args[1], error: args[2] });
      return null;
    default: return null;
  }
}
function syncHost(api, method, args) {
  switch (`${api}.${method}`) {
    case "os.uptime": return uptime();
    case "os.loadavg": return loadavg();
    case "os.cpus": return cpus();
    case "os.freemem": return freemem();
    case "zlib.inflate": return zlib.inflateSync(Buffer.from(args[0], "base64")).toString("base64");
    case "fs.open": return fs.openSync(args[0], args[1], args[2]);
    default: return null;
  }
}

// ── the extension bundle under test ────────────────────────────────────────────────────────────
// `perform` records into a JS global so the outer harness can read it back (the vm context is not
// the outer scope).
const source = `
import { registerRootSearchProvider, open } from "@tinycast/api";
export default async function command() {
  registerRootSearchProvider({
    id: "movies",
    async search(query, { limit }) {
      if (query === "matrix") {
        return [
          {
            id: "tmdb:603", title: "The Matrix", subtitle: "1999", keywords: ["Wachowski"],
            score: 0.82, iconPath: "probe.png",
            actions: [
              { id: "open", title: "Open Result" },
              { id: "de", title: "Open in German", shortcut: "⌘1", startsSection: true },
              { id: "es", title: "Open in Spanish", shortcut: "⌘2" },
            ],
          },
          { id: "tmdb:604", title: "The Matrix Reloaded", subtitle: "2003", score: "high" },
        ].slice(0, limit ?? 10);
      }
      if (query === "error") throw new Error("boom");
      return [];
    },
    async perform(resultId, actionId) {
      globalThis.__performed = resultId;
      globalThis.__performedAction = actionId ?? null;
      await open("https://example.test/wiki/" + resultId, "Safari");
    },
  });
}
`;

const accept = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const harness = createHarness();
  harness.boot();

  const { code } = transformSync(source, {
    loader: "jsx", jsx: "automatic", jsxImportSource: "react", format: "cjs", target: "es2022",
  });
  harness.start("s1", code, "/probe.js", "/probe", "no-view", {});
  await accept(200);

  check("provider registered into Swift", hostState.registered.includes("movies"), String(hostState.registered));

  // Fire a query: Swift calls __tinycast.rootSearchQuery, JS runs `search`, replies via results.
  harness.call(`__tinycast.rootSearchQuery("s1", "movies", "matrix", 10, "req-1")`);
  await accept(300);
  const matrix = hostState.results.find((r) => r.requestId === "req-1");
  check("results arrived for 'matrix'", !!matrix);
  check("results[0] is The Matrix", matrix?.candidates?.[0]?.title === "The Matrix", JSON.stringify(matrix?.candidates));
  check("subtitle + keywords carried", matrix?.candidates?.[0]?.subtitle === "1999" && matrix?.candidates?.[0]?.keywords?.[0] === "Wachowski");
  check("limit honoured (2 returned)", matrix?.candidates?.length === 2, String(matrix?.candidates?.length));
  check("candidate actions carried with their fields",
    matrix?.candidates?.[0]?.actions?.[0]?.title === "Open Result"
      && matrix?.candidates?.[0]?.actions?.[1]?.id === "de"
      && matrix?.candidates?.[0]?.actions?.[1]?.shortcut === "⌘1"
      && matrix?.candidates?.[0]?.actions?.[1]?.startsSection === true
      && matrix?.candidates?.[0]?.actions?.[2]?.startsSection === false,
    JSON.stringify(matrix?.candidates?.[0]?.actions));
  check("a candidate with no actions carries an empty list",
    Array.isArray(matrix?.candidates?.[1]?.actions) && matrix.candidates[1].actions.length === 0,
    JSON.stringify(matrix?.candidates?.[1]?.actions));
  // A provider's own strength rides along so Swift can order that provider's rows by it; a non-number
  // is dropped rather than decoded into a rank.
  check("candidate score carried, and a non-number dropped",
    matrix?.candidates?.[0]?.score === 0.82 && matrix?.candidates?.[1]?.score === undefined,
    JSON.stringify(matrix?.candidates?.map((c) => c.score)));
  // The row's own icon, as a path the host resolves inside the provider's own directory.
  check("candidate icon path carried",
    matrix?.candidates?.[0]?.iconPath === "probe.png" && matrix?.candidates?.[1]?.iconPath === undefined,
    JSON.stringify(matrix?.candidates?.map((c) => c.iconPath)));

  // A provider that throws must still reply (no candidates, an error string), not hang.
  harness.call(`__tinycast.rootSearchQuery("s1", "movies", "error", 10, "req-2")`);
  await accept(300);
  const errored = hostState.results.find((r) => r.requestId === "req-2");
  check("throwing search replies with an error", typeof errored?.error === "string", JSON.stringify(errored));

  // Activation routes through perform, and an action id reaches it: Swift passes one for a menu row
  // and nothing for the default, which is the first action the candidate listed.
  harness.call(`__tinycast.rootSearchPerform("s1", "movies", "tmdb:603")`);
  await accept(300);
  check("perform routed resultId", harness.call("globalThis.__performed") === "tmdb:603");
  check("no action id means the provider's default", harness.call("globalThis.__performedAction") === null);

  harness.call(`__tinycast.rootSearchPerform("s1", "movies", "tmdb:603", "de")`);
  await accept(300);
  check("a named action reaches perform", harness.call("globalThis.__performedAction") === "de");
  check("...for the same result", harness.call("globalThis.__performed") === "tmdb:603");
  // The last link between a provider naming a URL and the app opening it. Nothing else covers it: the
  // Node harness stubs the api module, so only this one runs the real `open`.
  check("a provider's open reaches the host as system.open",
    harness.state.hostCalls.includes("system.open"), harness.state.hostCalls.join(","));

  // Unknown provider id is a quiet no-op, not a crash.
  harness.call(`__tinycast.rootSearchQuery("s1", "ghost", "x", 10, "req-3")`);
  await accept(200);
  check("unknown provider id is a no-op", !hostState.results.some((r) => r.requestId === "req-3"));

  harness.stop("s1");
  console.log(`\nJS bridge: ${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
}

await main();