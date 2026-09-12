// Whether the page should look for a local anvil at all. The hosted page is https (Vercel), and a
// public https page reaching 127.0.0.1 trips Chrome's local-network permission prompt
// — on every visitor's screen, every five seconds of re-probe. So the hosted page
// replays and never probes unless the viewer asks for a node with ?rpc=. Plain http is always a
// local serve — vite dev/preview, or freeboard.finance.
// No imports, so the real function runs under node for its check.
export function probesLocalNode(loc: { protocol: string; search: string }): boolean {
  return loc.protocol === "http:" || new URLSearchParams(loc.search).has("rpc");
}
