import { log } from "./litellm-core.js"

/**
 * LiteLLM MCP server registration.
 *
 * LiteLLM can proxy MCP servers of its own at `<proxy root>/mcp/`, using the
 * same proxy key as the model routes. This module asks the proxy which MCP
 * servers the key can use (`GET /v1/mcp/server`) and registers each one as a
 * remote MCP server of its own in OpenCode — all on the same gateway, scoped
 * to that server through LiteLLM's `x-mcp-servers` header — reusing the key
 * the engine already resolved (/connect credential, options.apiKey or
 * LITELLM_API_KEY). When the server list is unavailable (route not granted,
 * older proxy) the whole gateway is registered as a single server instead.
 *
 * Opt-in through the plugin's `mcp` option:
 *
 *   "options": { "baseURL": "https://proxy/v1", "mcp": true }
 *   "options": { "baseURL": "https://proxy/v1",
 *                "mcp": { "prefix": "litellm-", "codemode": false } }
 *
 * Sub-options (all optional):
 *   enabled   false to turn it off while keeping the block
 *   url       override the gateway endpoint (default: <baseURL without /v1>/mcp/)
 *   split     false to always register the single aggregated gateway
 *   prefix    prepended to each server's name in OpenCode (default: "")
 *   exclude   server names to skip
 *   name      name of the aggregated gateway server (default: "litellm")
 *   header    auth header name (default: "x-litellm-api-key")
 *   apiKey    explicit key (default: the key the engine resolved)
 *   codemode  expose tools through codemode (default: false)
 */

const DEFAULT_NAME = "litellm"
const DEFAULT_HEADER = "x-litellm-api-key"

function proxyRoot(baseURL) {
  return baseURL.replace(/\/+$/, "").replace(/\/v1$/, "")
}

function mcpOptions(state) {
  const raw = state.options.mcp
  if (!raw) return undefined
  const opts = typeof raw === "object" ? raw : {}
  if (opts.enabled === false) return undefined
  return opts
}

/**
 * Fetch the MCP servers this key can use from the proxy into
 * state.mcpServers (names, in proxy order). Leaves it undefined when the
 * list is unavailable, which makes mcpEntries() fall back to the gateway.
 */
export async function discoverMCPServers(state, reason = "startup") {
  const opts = mcpOptions(state)
  if (!opts || opts.split === false || !state.baseURL) return
  const key = opts.apiKey || state.apiKey
  if (!key) return
  const url = `${proxyRoot(state.baseURL)}/v1/mcp/server`
  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${key}` },
      signal: AbortSignal.timeout(15_000),
    })
    if (!res.ok) {
      log(
        `mcp (${reason}): GET ${url} -> ${res.status} ${res.statusText} — ` +
          `registering the aggregated gateway instead`,
      )
      return
    }
    const json = await res.json()
    const list = Array.isArray(json) ? json : Array.isArray(json?.data) ? json.data : []
    const exclude = new Set(opts.exclude || [])
    state.mcpServers = list
      .map((s) => s && (s.server_name || s.alias || s.server_id))
      .filter((name) => typeof name === "string" && name && !exclude.has(name))
    log(`mcp (${reason}): ${state.mcpServers.length} servers on the proxy: ${state.mcpServers.join(", ")}`)
  } catch (error) {
    log(`mcp (${reason}): server list failed: ${error && error.message ? error.message : error} (non-fatal)`)
  }
}

/**
 * Resolve the `mcp` option into concrete server entries — one per proxy MCP
 * server, or the single aggregated gateway — or [] when MCP registration is
 * off or under-specified (the reason is logged).
 */
export function mcpEntries(state) {
  const opts = mcpOptions(state)
  if (!opts) return []

  const url = opts.url || (state.baseURL ? `${proxyRoot(state.baseURL)}/mcp/` : undefined)
  if (!url) {
    log("mcp: no baseURL and no mcp.url — skipping MCP registration")
    return []
  }

  const key = opts.apiKey || state.apiKey
  if (!key) {
    log("mcp: no LiteLLM key available yet — skipping MCP registration")
    return []
  }

  const auth = { [opts.header || DEFAULT_HEADER]: `Bearer ${key}` }
  const codemode = opts.codemode ?? false
  if (Array.isArray(state.mcpServers) && state.mcpServers.length > 0) {
    return state.mcpServers.map((server) => ({
      name: `${opts.prefix || ""}${server}`,
      url,
      headers: { ...auth, "x-mcp-servers": server },
      codemode,
    }))
  }
  return [{ name: opts.name || DEFAULT_NAME, url, headers: auth, codemode }]
}

/**
 * V2 plugin API: register the servers through `ctx.mcp.transform`.
 * A server of the same name already in the config always wins.
 */
export async function registerMCP(ctx, state) {
  const entries = mcpEntries(state)
  if (entries.length === 0) return
  if (typeof ctx?.mcp?.transform !== "function") {
    log("mcp: this build has no ctx.mcp.transform — MCP registration skipped (non-fatal)")
    return
  }
  try {
    await ctx.mcp.transform((editor) => {
      for (const server of entries) {
        if (editor.get(server.name)) {
          log(`mcp: "${server.name}" is already configured — leaving it alone`)
          continue
        }
        editor.set(server.name, {
          type: "remote",
          url: server.url,
          oauth: false,
          headers: server.headers,
          codemode: server.codemode,
        })
        log(`mcp: registered "${server.name}" -> ${server.url}`)
      }
    })
  } catch (error) {
    log(`mcp: registration failed: ${error && error.message ? error.message : error} (non-fatal)`)
  }
}
