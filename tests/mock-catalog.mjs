// Process-local transport fixture; never installed with the Skill.
import fs from "node:fs";

if (process.env.CUMOB_TEST_CATALOG) {
  globalThis.fetch = async (input, options) => {
    const url = new URL(input);
    if (!/^https:\/\/api\.cumob\.(com|cn)\/v1\/codex\/models$/.test(url.origin + url.pathname)) throw new Error("Unexpected test URL");
    if (options.redirect !== "error" || !options.signal) throw new Error("Missing redirect/timeout protection");
    if (options.headers.Authorization !== `Bearer ${process.env.CUMOB_TEST_EXPECTED_KEY}`) throw new Error("Incorrect test authentication");
    if (url.searchParams.get("client_version") !== process.env.CUMOB_CODEX_CLIENT_VERSION) throw new Error("Missing client version");
    if (process.env.CUMOB_TEST_REQUESTS) fs.appendFileSync(process.env.CUMOB_TEST_REQUESTS, `${url}\n`);
    switch (process.env.CUMOB_TEST_MODE) {
      case "401": return new Response("Unauthorized", { status: 401 });
      case "redirect": return new Response("", { status: 302, headers: { Location: "https://untrusted.invalid/" } });
      case "timeout": throw new Error("Simulated timeout");
      case "invalid-json": return new Response("not JSON");
      case "oversize": return new Response(" ".repeat(1024 * 1024 + 1));
      default: return new Response(fs.readFileSync(process.env.CUMOB_TEST_CATALOG), { headers: { "Content-Type": "application/json" } });
    }
  };
}
