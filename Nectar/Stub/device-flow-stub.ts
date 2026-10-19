// Local stand-in for nectar#379 slice 1 (device flow) while it isn't live, built to the contract
// pinned on nectar#379. Run: bun Stub/device-flow-stub.ts, then approve a code with
//   curl -X POST localhost:8787/activate -d code=ABCD-EFGH        (or -d deny=1)
// Dev tool only; nothing here ships.
const port = 8787;
const issuer = `http://localhost:${port}`;
const alphabet = "BCDFGHJKLMNPQRSTVWXZ";

type Grant = { userCode: string; deviceName: string; expiresAt: number; status: "pending" | "approved" | "denied" | "used"; lastPoll: number };
const grants = new Map<string, Grant>();
const refresh = new Map<string, string>(); // refresh token -> user
const access = new Set<string>();
let interval = 5;

const json = (body: unknown, status = 200) => Response.json(body, { status });
const oauthError = (error: string) => json({ error }, 400);
const pick = (n: number) => Array.from({ length: n }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join("");
const tokens = (user: string) => {
  const accessToken = `stub-access-${crypto.randomUUID()}`, refreshToken = `stub-refresh-${crypto.randomUUID()}`;
  access.add(accessToken); refresh.set(refreshToken, user);
  return { access_token: accessToken, token_type: "Bearer", expires_in: 86400, refresh_token: refreshToken };
};

Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);
    const form = req.method === "POST" ? new URLSearchParams(await req.text()) : new URLSearchParams();
    const who = ["x-nectar-client", "x-nectar-device", "x-nectar-test"].map((h) => req.headers.get(h)).filter((v) => v !== null);
    console.log(req.method, url.pathname, [...form.keys()].join(","), who.length ? `[${who.join(" | ")}]` : "");

    switch (url.pathname) {
      case "/.well-known/openid-configuration":
        return json({ issuer, token_endpoint: `${issuer}/token`, device_authorization_endpoint: `${issuer}/device_authorization`,
          grant_types_supported: ["authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:device_code"] });

      case "/device_authorization": {
        if (form.get("client_id") !== "nectar-tv") return json({ error: "invalid_client" }, 401);
        const deviceCode = crypto.randomUUID(), userCode = `${pick(4)}-${pick(4)}`;
        grants.set(deviceCode, { userCode, deviceName: form.get("device_name") ?? "", expiresAt: Date.now() + 600_000, status: "pending", lastPoll: 0 });
        console.log(`  code ${userCode} for "${form.get("device_name")}"`);
        return json({ device_code: deviceCode, user_code: userCode, verification_uri: `${issuer}/activate`,
          verification_uri_complete: `${issuer}/activate?code=${userCode}`, expires_in: 600, interval });
      }

      case "/activate": {
        const code = (form.get("code") ?? "").toUpperCase().replace(/-?/, "");
        const grant = [...grants.values()].find(g => g.userCode.replace("-", "") === code.replace("-", ""));
        if (!grant || grant.status !== "pending") return json({ ok: false }, 404);
        grant.status = form.get("deny") ? "denied" : "approved";
        return json({ ok: true, device: grant.deviceName, status: grant.status });
      }

      case "/token": {
        if (form.get("client_id") !== "nectar-tv") return json({ error: "invalid_client" }, 401);
        if (form.get("grant_type") === "refresh_token") {
          const user = refresh.get(form.get("refresh_token") ?? "");
          if (!user) return oauthError("invalid_grant");
          refresh.delete(form.get("refresh_token")!);
          return json(tokens(user));
        }
        const grant = grants.get(form.get("device_code") ?? "");
        if (!grant || grant.status === "used") return oauthError("invalid_grant");
        if (Date.now() > grant.expiresAt) return oauthError("expired_token");
        const now = Date.now(), tooSoon = now - grant.lastPoll < interval * 1000 - 500;
        grant.lastPoll = now;
        if (tooSoon) return oauthError("slow_down");
        if (grant.status === "denied") return oauthError("access_denied");
        if (grant.status === "pending") return oauthError("authorization_pending");
        grant.status = "used";
        return json(tokens("pia"));
      }

      case "/api/v1/users/me": {
        const bearer = req.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
        if (!access.has(bearer)) return json({ error: "unauthorized" }, 401);
        return json({ id: "stub-user", username: "pia", email: null, is_admin: true });
      }
    }
    return media(req, url);
  },
});
console.log(`device-flow stub on ${issuer}`);

// A little of nectar's media API, for the playlist slice (#33): one playlist with two playable
// clips around a wanted entry, decide answering direct play, and the clips served with ranges.
// Clips: STUB_MEDIA (default ~/scratch/nectar-apple/stub-media) holding clip-a.mp4 and clip-b.mp4.
const mediaDir = process.env.STUB_MEDIA ?? `${process.env.HOME}/scratch/nectar-apple/stub-media`;
const clips: Record<string, string> = { "clip-a": "clip-a.mp4", "clip-b": "clip-b.mp4" };

function authorized(req: Request, url: URL) {
  const bearer = req.headers.get("authorization")?.replace(/^Bearer /, "") ?? url.searchParams.get("access_token") ?? "";
  return access.has(bearer);
}

async function media(req: Request, url: URL): Promise<Response> {
  if (!url.pathname.startsWith("/api/v1/")) return json({ error: "not found" }, 404);
  if (!authorized(req, url)) return json({ error: "unauthorized" }, 401);
  const path = url.pathname;

  if (path === "/api/v1/media/continue") return json({ items: [], total: 0 });
  // As an admin sees it: everyone's requests. The TV's list keeps the stub user's own (#56).
  if (path === "/api/v1/requests") {
    const at = (d: number) => new Date(Date.now() - d * 3600_000).toISOString();
    const ref = (kind: string, tmdb_id: number, title: string, year: number) => ({ kind, tmdb_id, title, year });
    return json({ requests: [
      { id: "q1", media_ref: ref("movie", 399106, "Piper", 2016), requested_by: "stub-user", requested_by_name: "pia", status: "approved", monitored_item_id: "mi1", created_at: at(1), decided_at: at(1), auto_approved: true },
      { id: "q2", media_ref: ref("series", 1399, "Game of Thrones", 2011), requested_by: "someone-else", requested_by_name: "maggie", status: "pending", monitored_item_id: null, created_at: at(5), decided_at: null, auto_approved: false },
      { id: "q3", media_ref: ref("series", 95396, "Severance", 2022), requested_by: "stub-user", requested_by_name: "pia", status: "pending", monitored_item_id: null, created_at: at(26), decided_at: null, auto_approved: false },
      { id: "q4", media_ref: ref("movie", 5, "Four Rooms", 1995), requested_by: "stub-user", requested_by_name: "pia", status: "fulfilled", monitored_item_id: "mi2", created_at: at(200), decided_at: at(200), auto_approved: true },
      { id: "q5", media_ref: ref("movie", 6, "Judgment Night", 1993), requested_by: "stub-user", requested_by_name: "pia", status: "denied", monitored_item_id: null, created_at: at(400), decided_at: at(390), auto_approved: false },
    ] });
  }
  if (path === "/api/v1/collections") {
    return json({ collections: [{ id: "stub-pl", user_id: "stub-user", name: "Stub playlist", description: "Two clips around a wanted title", kind: "playlist", item_count: "2" }] });
  }
  if (path === "/api/v1/collections/stub-pl") {
    return json({
      collection: { id: "stub-pl", name: "Stub playlist", description: "Two clips around a wanted title", kind: "playlist", item_count: "2" },
      items: [
        { id: "clip-a", item_type: "movie", title: "Red clip", year: 2026, sort_index: 0, poster_url: null, entry: "owned", media_item_id: "clip-a" },
        { id: "w-piper", entry: "wanted", item_type: "movie", title: "Piper", year: 2016, sort_index: 1, poster_url: null, media_item_id: null, tmdb_id: "399106", request_status: "approved" },
        { id: "clip-b", item_type: "movie", title: "Green clip", year: 2026, sort_index: 2, poster_url: null, entry: "owned", media_item_id: "clip-b" },
      ],
    });
  }
  const decide = path.match(/^\/api\/v1\/streaming\/([^/]+)\/decide$/);
  if (decide && req.method === "POST") {
    return json({ strategy: "direct", stream_url: `/api/v1/streaming/${decide[1]}/direct`, content_type: "video/mp4", job_id: null,
      play_method: "DirectPlay", duration_seconds: 6, start_offset_seconds: 0, audio_reason: "first" });
  }
  const direct = path.match(/^\/api\/v1\/streaming\/([^/]+)\/direct$/);
  if (direct && clips[direct[1]!]) {
    const file = Bun.file(`${mediaDir}/${clips[direct[1]!]}`);
    const size = file.size;
    const range = req.headers.get("range")?.match(/bytes=(\d+)-(\d*)/);
    if (!range) return new Response(file, { headers: { "content-type": "video/mp4", "accept-ranges": "bytes", "content-length": String(size) } });
    const start = Number(range[1]), end = range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    return new Response(file.slice(start, end + 1), { status: 206, headers: {
      "content-type": "video/mp4", "accept-ranges": "bytes", "content-range": `bytes ${start}-${end}/${size}`, "content-length": String(end - start + 1) } });
  }
  if (/^\/api\/v1\/media\/[^/]+\/progress$/.test(path) && req.method === "POST") {
    return json({}); // the body was read (and logged) by the handler above
  }
  return json({ error: "not found" }, 404);
}
