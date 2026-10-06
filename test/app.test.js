import assert from "node:assert/strict";
import { test } from "node:test";
import { Readable } from "node:stream";
import { makeHandler } from "../src/app.js";

/** One request through the handler: answers { status, body }. */
async function call(handler, { method, url, body = "", authorization }) {
  const req = Readable.from([body]);
  Object.assign(req, { method, url, headers: authorization ? { authorization } : {} });
  return new Promise((resolve) => {
    const res = { status: 0, writeHead(s) { this.status = s; }, end(text) { resolve({ status: this.status, body: JSON.parse(text) }); } };
    handler(req, res);
  });
}

const probe = { write: async () => {}, read: async () => ({ redis: "x", mariadb: "x" }), healthy: async () => true };
const logs = [];
const handler = makeHandler({ probe, token: "t0ken", log: (line) => logs.push(line) });

test("PLANTED: PUT /probe without the token, or with another, is refused and writes nothing", async () => {
  let wrote = false;
  const watched = makeHandler({ probe: { ...probe, write: async () => { wrote = true; } }, token: "t0ken", log: () => {} });
  assert.equal((await call(watched, { method: "PUT", url: "/probe", body: "x" })).status, 401);
  assert.equal((await call(watched, { method: "PUT", url: "/probe", body: "x", authorization: "Bearer other" })).status, 401);
  assert.equal(wrote, false);
});

test("PUT /probe with the token writes, and GET /probe is open", async () => {
  assert.equal((await call(handler, { method: "PUT", url: "/probe", body: "x", authorization: "Bearer t0ken" })).status, 200);
  assert.deepEqual((await call(handler, { method: "GET", url: "/probe" })).body, { redis: "x", mariadb: "x" });
});

test("PLANTED: a failing store answers a fixed text, and its message reaches only the log", async () => {
  const failing = makeHandler({ probe: { ...probe, read: async () => { throw new Error("Access denied for user demo@10.1.2.3"); } }, token: "t0ken", log: (line) => logs.push(line) });
  const answer = await call(failing, { method: "GET", url: "/probe" });
  assert.equal(answer.status, 500);
  assert.equal(JSON.stringify(answer.body).includes("10.1.2.3"), false);
  assert.ok(logs.some((line) => line.includes("Access denied")));
});

test("a handler without a token is refused at start", () => {
  assert.throws(() => makeHandler({ probe, token: "", log: () => {} }), /PROBE_TOKEN is not set/);
});
