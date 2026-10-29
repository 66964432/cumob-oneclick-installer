import fs from "node:fs";
import { spawnSync } from "node:child_process";

// Read-only preflight. Never print credentials, response bodies, or raw fetch errors.
const [configPath, authPath, catalogUrl] = process.argv.slice(2);
const MAX_BYTES = 1024 * 1024;
function fail(message) { throw new Error(message); }

function checkConfig() {
  if (!fs.existsSync(configPath)) return;
  const lines = fs.readFileSync(configPath, "utf8").split(/\r?\n/);
  let section = "";
  const profiles = new Map();
  for (let line of lines) {
    line = line.replace(/^(\s*)["'](model_provider|model_catalog_json|features|api_key_model_discovery)["'](?=\s*[=.])/, "$1$2");
    const header = line.match(/^\s*\[([^\[\]]+)\]\s*(?:#.*)?$/);
    if (header) { section = header[1].replace(/[\s"']/g, ""); continue; }
    if (!section && /^\s*features\s*=/.test(line)) {
      fail("Inline features configuration is not supported by this installer. Convert it to a [features] table first.");
    }
    if (!section && /^\s*features\./.test(line) && !/^\s*features\.api_key_model_discovery\s*=/.test(line)) {
      fail("Dotted features configuration is not supported by this installer. Convert it to a [features] table first.");
    }
    if (section.startsWith("profiles.")) {
      const name = section.split(".")[1];
      const profile = profiles.get(name) || {};
      if (/^profiles\.[^.]+$/.test(section)) {
        const provider = line.match(/^\s*model_provider\s*=\s*["']([^"']+)["']/);
        if (provider) profile.provider = provider[1];
        if (/^\s*model_catalog_json\s*=/.test(line)) profile.local = true;
        if (/^\s*features\.api_key_model_discovery\s*=\s*false\b/.test(line)) profile.disabled = true;
      }
      if (/^profiles\.[^.]+\.features$/.test(section) && /^\s*api_key_model_discovery\s*=\s*false\b/.test(line)) profile.disabled = true;
      profiles.set(name, profile);
    }
  }
  for (const [name, profile] of profiles) {
    if ((!profile.provider || profile.provider === "cumob") && (profile.local || profile.disabled)) {
      fail(`Profile ${name} overrides remote model discovery. Remove its model_catalog_json / disabled api_key_model_discovery setting, then retry. Other providers are left unchanged.`);
    }
  }
}

function readKey() {
  let auth = {};
  if (fs.existsSync(authPath)) {
    try { auth = JSON.parse(fs.readFileSync(authPath, "utf8").replace(/^\uFEFF/, "")); }
    catch { fail("Invalid auth.json. Repair it before installing; existing files were not changed."); }
    if (!auth || Array.isArray(auth) || typeof auth !== "object") fail("auth.json must contain a JSON object.");
  }
  const key = process.env.CUMOB_INSTALL_API_KEY || auth.OPENAI_API_KEY;
  if (typeof key !== "string" || !key.trim() || /[\r\n]/.test(key)) fail("A CUMOB API Key is required to validate the remote catalog. Supply a key or keep an existing OPENAI_API_KEY in auth.json.");
  return key;
}

function clientVersion() {
  let version = process.env.CUMOB_CODEX_CLIENT_VERSION;
  if (!version) {
    const command = process.platform === "win32" ? "codex.exe" : "codex";
    let result = spawnSync(command, ["--version"], { encoding: "utf8", timeout: 3000 });
    if (result.error && process.platform === "darwin" && fs.existsSync("/Applications/Codex.app/Contents/Resources/codex")) {
      result = spawnSync("/Applications/Codex.app/Contents/Resources/codex", ["--version"], { encoding: "utf8", timeout: 3000 });
    }
    version = (result.stdout || "").match(/\b\d+\.\d+\.\d+\b/)?.[0];
  }
  if (version && !/^\d+\.\d+\.\d+$/.test(version)) fail("CUMOB_CODEX_CLIENT_VERSION must use major.minor.patch.");
  return version;
}

function selectDefault(catalog) {
  if (!catalog || !Array.isArray(catalog.models) || !catalog.models.length) fail("Remote catalog must contain a nonempty models array.");
  const slugs = new Set();
  const eligible = [];
  for (const model of catalog.models) {
    if (!model || typeof model.slug !== "string" || !/^[A-Za-z0-9._:/-]+$/.test(model.slug) || slugs.has(model.slug)) fail("Remote catalog contains an invalid or duplicate model slug.");
    slugs.add(model.slug);
    if (!Number.isInteger(model.priority) || typeof model.display_name !== "string" || !model.display_name.trim()) fail("Remote catalog contains an invalid priority or display_name.");
    if (model.supported_in_api !== true || model.visibility !== "list") continue;
    if (typeof model.default_reasoning_level !== "string" || !/^[a-z]+$/.test(model.default_reasoning_level) || !Array.isArray(model.supported_reasoning_levels) || !model.supported_reasoning_levels.some(level => level?.effort === model.default_reasoning_level)) fail("Remote catalog contains an unsupported default reasoning level.");
    eligible.push(model);
  }
  if (!eligible.length) fail("Remote catalog has no visible API-supported default model.");
  return eligible.reduce((best, model) => model.priority < best.priority ? model : best);
}

try {
  checkConfig();
  const key = readKey();
  const url = new URL(catalogUrl);
  if (url.protocol !== "https:" || !["api.cumob.com", "api.cumob.cn"].includes(url.hostname) || url.port || url.username || url.password || url.pathname !== "/v1/codex/models" || url.search || url.hash) fail("Catalog URL must be the selected CUMOB HTTPS /v1/codex/models endpoint.");
  const version = clientVersion();
  if (version) url.searchParams.set("client_version", version);
  else console.error("Codex version was not detected; requesting the server's default catalog. Keep Codex updated to use remote model discovery.");
  let response;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  let raw;
  try {
    response = await fetch(url, { headers: { Authorization: `Bearer ${key}`, Accept: "application/json" }, redirect: "error", signal: controller.signal });
    if (!response.ok) fail(`Remote catalog request failed (HTTP ${response.status}). Check your API Key and CUMOB endpoint.`);
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.byteLength;
      if (size > MAX_BYTES) fail("Remote catalog exceeds the 1 MiB limit.");
      chunks.push(chunk);
    }
    raw = Buffer.concat(chunks).toString("utf8");
  } catch (error) {
    if (error.message.startsWith("Remote catalog")) throw error;
    fail("Remote catalog request failed (network error, timeout, or redirect). Existing Codex files were not changed.");
  } finally { clearTimeout(timer); }
  let catalog;
  try { catalog = JSON.parse(raw); } catch { fail("Remote catalog did not return valid JSON."); }
  const model = selectDefault(catalog);
  process.stdout.write(`${model.slug}\t${model.default_reasoning_level}\n`);
} catch (error) {
  console.error(`Codex preflight failed: ${error.message}`);
  process.exitCode = 1;
}
