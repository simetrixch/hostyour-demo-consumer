// The demo consumer's requests: it answers whether it serves, and nothing else.
const send = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};

export function handle(req, res) {
  if (req.url === "/healthz" && req.method === "GET") return send(res, 200, { ok: true });
  return send(res, 404, { error: "not found" });
}
