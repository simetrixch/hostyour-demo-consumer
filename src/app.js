// The demo consumer's requests, apart from the connections they run over, so they can be tested with
// a stand-in probe. PUT /probe takes the token the platform generated for this consumer; GET /probe
// and GET /healthz are open, because they show only the probe text and whether the stores answer.
import { timingSafeEqual } from "node:crypto";

export const MAX_TEXT = 200;
const FAILED = "the probe failed; see the consumer's log";

/** The request body as text, refused past MAX_TEXT characters. */
async function bodyText(req) {
  req.setEncoding("utf8");
  let text = "";
  for await (const chunk of req) {
    text += chunk;
    if (text.length > MAX_TEXT) throw Object.assign(new Error(`the probe text is longer than ${MAX_TEXT} characters`), { status: 413 });
  }
  return text.trim();
}

/** Whether the request carries `Authorization: Bearer <token>`, compared in constant time. */
function bearerMatches(req, token) {
  const given = Buffer.from(String(req.headers.authorization ?? ""));
  const wanted = Buffer.from(`Bearer ${token}`);
  return given.length === wanted.length && timingSafeEqual(given, wanted);
}

const send = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};

/** The request handler. A failure answers a fixed text; its detail goes to `log` only, because a
 *  driver's message can name the user and the in-cluster address. */
export function makeHandler({ probe, token, log }) {
  if (!token) throw new Error("PROBE_TOKEN is not set — it comes from the consumer's app secret");
  return async (req, res) => {
    try {
      if (req.url === "/healthz" && req.method === "GET") return send(res, 200, { ok: await probe.healthy() });
      if (req.url === "/probe" && req.method === "GET") return send(res, 200, await probe.read());
      if (req.url === "/probe" && req.method === "PUT") {
        if (!bearerMatches(req, token)) return send(res, 401, { error: "PUT /probe takes the consumer's probe token" });
        const text = await bodyText(req);
        if (!text) return send(res, 400, { error: "the probe text is empty" });
        await probe.write(text);
        return send(res, 200, await probe.read());
      }
      return send(res, 404, { error: "not found" });
    } catch (err) {
      log(`${req.method} ${req.url}: ${err.message}`);
      return err.status ? send(res, err.status, { error: err.message }) : send(res, 500, { error: FAILED });
    }
  };
}
