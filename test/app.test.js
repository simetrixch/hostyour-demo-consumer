import assert from "node:assert/strict";
import { test } from "node:test";
import { handle } from "../src/app.js";

/** One request through the handler: answers { status, body }. */
function call(method, url) {
  let answer;
  const res = { status: 0, writeHead(s) { this.status = s; }, end(text) { answer = { status: this.status, body: JSON.parse(text) }; } };
  handle({ method, url }, res);
  return answer;
}

test("GET /healthz answers 200", () => {
  assert.deepEqual(call("GET", "/healthz"), { status: 200, body: { ok: true } });
});

test("PLANTED: any other request answers 404", () => {
  assert.equal(call("GET", "/other").status, 404);
  assert.equal(call("PUT", "/healthz").status, 404);
});
