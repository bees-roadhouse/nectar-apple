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
    console.log(req.method, url.pathname, [...form.keys()].join(","));

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
    return json({ error: "not found" }, 404);
  },
});
console.log(`device-flow stub on ${issuer}`);
