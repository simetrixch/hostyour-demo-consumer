// The demo consumer's HTTP surface: PUT /probe writes the probe, GET /probe reads it, GET /healthz
// answers once both data services answer. The connection strings are the provisioner's, taken from
// the ServiceClaims' credential Secrets: REDIS_URI and DATABASE_URL.
import { createServer } from "node:http";
import { createClient } from "redis";
import mysql from "mysql2/promise";
import { makeProbe } from "./probe.js";

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set — it comes from the ServiceClaim's credential Secret`);
  return value;
};

const redis = createClient({ url: required("REDIS_URI") });
redis.on("error", (err) => console.error(`redis: ${err.message}`));
await redis.connect();
const sql = mysql.createPool({ uri: required("DATABASE_URL"), connectionLimit: 2 });
const probe = makeProbe({ redis, sql });

const MAX_TEXT = 200;

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

const send = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};

createServer(async (req, res) => {
  try {
    if (req.url === "/healthz" && req.method === "GET") return send(res, 200, { ok: await probe.healthy() });
    if (req.url === "/probe" && req.method === "GET") return send(res, 200, await probe.read());
    if (req.url === "/probe" && req.method === "PUT") {
      const text = await bodyText(req);
      if (!text) return send(res, 400, { error: "the probe text is empty" });
      await probe.write(text);
      return send(res, 200, await probe.read());
    }
    return send(res, 404, { error: "not found" });
  } catch (err) {
    // The detail goes to the log only: a driver's message can name the user and the in-cluster address.
    console.error(`${req.method} ${req.url}: ${err.message}`);
    return err.status ? send(res, err.status, { error: err.message }) : send(res, 500, { error: "the probe failed; see the consumer's log" });
  }
}).listen(8080, () => console.log("hostyour-demo-consumer listens on 8080"));
