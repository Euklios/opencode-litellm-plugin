#!/usr/bin/env bash
#
# opencode-litellm-plugin installer
#
# Installs the plugin for OpenCode and adds the required
# provider configuration block.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/gianni-bischoff/opencode-litellm-plugin/main/install.sh | bash
#
# With a proxy URL and an optional provider ID/display name (pass them as
# arguments — env vars on the curl side of a pipe do NOT reach bash):
#
#   curl -fsSL https://raw.githubusercontent.com/gianni-bischoff/opencode-litellm-plugin/main/install.sh \
#     | bash -s -- https://your-proxy.example.com/v1 providername
#
#
# (LITELLM_BASE_URL is still honored as a fallback.)
set -euo pipefail

PLUGIN_SPEC="git+https://github.com/gianni-bischoff/opencode-litellm-plugin.git"
# Proxy URL: first script argument, else LITELLM_BASE_URL, else unset.
# Provider ID: second script argument, else the default "litellm".
PROXY_URL="${1:-${LITELLM_BASE_URL:-}}"
PROVIDER_ID="${2:-litellm}"
if ! [[ "$PROVIDER_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERROR: provider ID may only contain letters, digits, '_' and '-': '$PROVIDER_ID'" >&2
  exit 1
fi

# Ensure ~/.opencode/bin is in PATH if installed there
if [ -d "$HOME/.opencode/bin" ] && [[ ":$PATH:" != *":$HOME/.opencode/bin:"* ]]; then
  export PATH="$HOME/.opencode/bin:$PATH"
fi

if ! command -v opencode >/dev/null 2>&1; then
  echo "ERROR: 'opencode' command was not found in PATH." >&2
  echo "Please install OpenCode first: curl -fsSL https://opencode.ai/install | bash" >&2
  exit 1
fi

CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
CONFIG_FILE="$CONFIG_DIR/opencode.json"
CONFIG_FILEC="$CONFIG_DIR/opencode.jsonc"

# ---------------------------------------------------------------------------
# Locate the global config file (prefer jsonc when it is the only one present)
# ---------------------------------------------------------------------------
if [ -f "$CONFIG_FILEC" ] && [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$CONFIG_FILEC"
fi
mkdir -p "$CONFIG_DIR"
[ -f "$CONFIG_FILE" ] || printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$CONFIG_FILE"

# ---------------------------------------------------------------------------
# JSON editor: python3 -> node
# ---------------------------------------------------------------------------
json_edit() {
  if command -v python3 >/dev/null 2>&1; then python3 - "$1" "$2" "$3" "${4:-litellm}" << 'PYEOF'
import json, sys, os, re

config_path, action, arg, provider_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(config_path) as f:
    text = f.read()

try:
    cfg = json.loads(text)
except json.JSONDecodeError:
    cleaned = re.sub(r'^[ \t]*//[^\n]*', '', text, flags=re.MULTILINE)
    cleaned = re.sub(r'/\*.*?\*/', '', cleaned, flags=re.DOTALL)
    cleaned = re.sub(r',(\s*[}\]])', r'\1', cleaned)
    try:
        cfg = json.loads(cleaned)
    except json.JSONDecodeError as e:
        sys.exit(f"ERROR: {config_path} is not valid JSON: {e}")

changed = False

if action == "add-provider":
    providers = cfg.setdefault("providers", {})
    provider_name = "LiteLLM" if provider_id == "litellm" else provider_id
    if provider_id not in providers:
        providers[provider_id] = {
            "name": provider_name,
            "env": ["LITELLM_API_KEY"],
            "package": "@opencode/ai/providers/openai-compatible",
        }
        changed = True
    else:
        provider = providers[provider_id]
        if isinstance(provider, dict):
            if "name" not in provider:
                provider["name"] = provider_name
                changed = True
            env = provider.setdefault("env", [])
            if "LITELLM_API_KEY" not in env:
                env.append("LITELLM_API_KEY")
                changed = True
            if "package" not in provider:
                provider["package"] = "@opencode/ai/providers/openai-compatible"
                changed = True

elif action == "apply-plugin-options":
    base_url = arg
    opts = {}
    if base_url:
        opts["baseURL"] = base_url
    if provider_id != "litellm":
        opts["providerID"] = provider_id
        opts["name"] = provider_id
    plugins = cfg.get("plugins", []) or []
    for idx, entry in enumerate(plugins):
        if isinstance(entry, str) and "opencode-litellm-plugin" in entry:
            plugins[idx] = {"package": entry, "options": opts or {"baseURL": "http://127.0.0.1:4000/v1"}}
            changed = True
        elif isinstance(entry, dict) and "opencode-litellm-plugin" in str(entry.get("package", "")):
            entry.setdefault("options", {}).update(opts)
            changed = True

elif action == "normalize-plugin-entries":
    plugins = cfg.setdefault("plugins", [])
    legacy_plugin = cfg.get("plugin", []) or []
    kept_plugin = []
    mutated = False
    for entry in legacy_plugin:
        if isinstance(entry, dict) and "opencode-litellm-plugin" in str(entry.get("package", "")):
            mutated = True
            if entry not in plugins and not any(
                isinstance(e, dict) and e.get("package") == entry.get("package") for e in plugins
            ):
                plugins.append(entry)
        elif isinstance(entry, str) and "opencode-litellm-plugin" in entry:
            mutated = True
            if entry not in plugins and not any(
                (isinstance(e, str) and e == entry) or (isinstance(e, dict) and e.get("package") == entry)
                for e in plugins
            ):
                plugins.append(entry)
        elif isinstance(entry, list) and len(entry) > 0 and "litellm" in str(entry[0]):
            # Stale hooks tuple from old installer workaround — drop it
            mutated = True
        else:
            kept_plugin.append(entry)
    if mutated:
        if kept_plugin:
            cfg["plugin"] = kept_plugin
        else:
            cfg.pop("plugin", None)
        changed = True

    # Clean up stale copied hooks files if present
    hooks_dir = os.path.join(os.path.dirname(config_path), "hooks")
    for fname in ["litellm-hooks.js", "litellm-core.js"]:
        fpath = os.path.join(hooks_dir, fname)
        if os.path.isfile(fpath):
            try:
                os.remove(fpath)
            except OSError:
                pass

elif action == "has-plugin":
    for entry in (cfg.get("plugins", []) or []):
        if isinstance(entry, str) and "opencode-litellm-plugin" in entry:
            print("yes"); sys.exit(0)
        if isinstance(entry, dict) and "opencode-litellm-plugin" in str(entry.get("package", "")):
            print("yes"); sys.exit(0)
    print("no"); sys.exit(0)

if changed or action == "has-plugin":
    with open(config_path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
PYEOF
  elif command -v node >/dev/null 2>&1; then node - "$1" "$2" "$3" "${4:-litellm}" << 'NODEOF'
const fs = require("fs");
const path = require("path");

const configPath = process.argv[2];
const action = process.argv[3];
const arg = process.argv[4];
const providerID = process.argv[5];

let text = fs.readFileSync(configPath, "utf8");
let cfg;
try {
  cfg = JSON.parse(text);
} catch {
  const cleaned = text
    .replace(/^[ \t]*\/\/[^\n]*/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/,(\s*[}\]])/g, "$1");
  try {
    cfg = JSON.parse(cleaned);
  } catch (err) {
    console.error(`ERROR: ${configPath} is not valid JSON: ${err.message}`);
    process.exit(1);
  }
}

let changed = false;

if (action === "add-provider") {
  cfg.providers = cfg.providers || {};
  const providerName = providerID === "litellm" ? "LiteLLM" : providerID;
  if (!cfg.providers[providerID]) {
    cfg.providers[providerID] = {
      name: providerName,
      env: ["LITELLM_API_KEY"],
      package: "@opencode/ai/providers/openai-compatible",
    };
    changed = true;
  } else if (typeof cfg.providers[providerID] === "object") {
    const p = cfg.providers[providerID];
    if (!p.name) { p.name = providerName; changed = true; }
    p.env = Array.isArray(p.env) ? p.env : [];
    if (!p.env.includes("LITELLM_API_KEY")) { p.env.push("LITELLM_API_KEY"); changed = true; }
    if (!p.package) { p.package = "@opencode/ai/providers/openai-compatible"; changed = true; }
  }
} else if (action === "apply-plugin-options") {
  const opts = {};
  if (arg) opts.baseURL = arg;
  if (providerID !== "litellm") {
    opts.providerID = providerID;
    opts.name = providerID;
  }
  const plugins = cfg.plugins || [];
  for (let i = 0; i < plugins.length; i++) {
    const entry = plugins[i];
    if (typeof entry === "string" && entry.includes("opencode-litellm-plugin")) {
      plugins[i] = { package: entry, options: Object.keys(opts).length ? opts : { baseURL: "http://127.0.0.1:4000/v1" } };
      changed = true;
    } else if (entry && typeof entry === "object" && String(entry.package || "").includes("opencode-litellm-plugin")) {
      entry.options = Object.assign(entry.options || {}, opts);
      changed = true;
    }
  }
} else if (action === "normalize-plugin-entries") {
  cfg.plugins = cfg.plugins || [];
  const legacy = cfg.plugin || [];
  const kept = [];
  let mutated = false;
  for (const entry of legacy) {
    if (entry && typeof entry === "object" && !Array.isArray(entry) && String(entry.package || "").includes("opencode-litellm-plugin")) {
      mutated = true;
      if (!cfg.plugins.some(e => typeof e === "object" && e.package === entry.package)) {
        cfg.plugins.push(entry);
      }
    } else if (typeof entry === "string" && entry.includes("opencode-litellm-plugin")) {
      mutated = true;
      if (!cfg.plugins.some(e => e === entry || (typeof e === "object" && e.package === entry))) {
        cfg.plugins.push(entry);
      }
    } else if (Array.isArray(entry) && entry.length > 0 && String(entry[0]).includes("litellm")) {
      mutated = true;
    } else {
      kept.push(entry);
    }
  }
  if (mutated) {
    if (kept.length > 0) cfg.plugin = kept;
    else delete cfg.plugin;
    changed = true;
  }
  const hooksDir = path.join(path.dirname(configPath), "hooks");
  for (const fname of ["litellm-hooks.js", "litellm-core.js"]) {
    const fpath = path.join(hooksDir, fname);
    if (fs.existsSync(fpath)) {
      try { fs.unlinkSync(fpath); } catch {}
    }
  }
} else if (action === "has-plugin") {
  for (const entry of cfg.plugins || []) {
    if (typeof entry === "string" && entry.includes("opencode-litellm-plugin")) {
      console.log("yes");
      process.exit(0);
    }
    if (entry && typeof entry === "object" && String(entry.package || "").includes("opencode-litellm-plugin")) {
      console.log("yes");
      process.exit(0);
    }
  }
  console.log("no");
  process.exit(0);
}

if (changed) {
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2) + "\n");
}
NODEOF
  else
    echo "ERROR: python3 or node is required by the installer but neither was found." >&2
    echo "Install the plugin manually with: opencode plugin add $PLUGIN_SPEC" >&2
    echo "and add the providers.litellm block from the README to $CONFIG_FILE" >&2
    exit 1
  fi
}

echo "==> Installing opencode-litellm-plugin"

# Clear every generation of this package before updating. Recent OpenCode
# versions nest each install below a timestamp, so testing only for a direct
# node_modules/ child leaves stale generations behind.
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/opencode"
if [ -d "$CACHE_BASE/packages" ]; then
  for d in "$CACHE_BASE"/packages/git-*/; do
    [ -d "$d/node_modules/opencode-litellm-plugin" ] || continue
    rm -rf "$d"
  done
fi
if [ -d "$CACHE_BASE/npm" ]; then
  for d in "$CACHE_BASE"/npm/git-opencode-litellm-plugin-*/; do
    [ -d "$d" ] || continue
    rm -rf "$d"
  done
fi

# 1. Install or update via the OpenCode CLI. OpenCode 2's current CLI uses
# `plugin add` / `plugin update`; older images used `plugin <module>` with
# `--force`. The latter is still common in sandbox base images, so identify
# the CLI shape from its own help rather than its version number.
PLUGIN_HELP="$(opencode plugin --help 2>&1 || true)"
if printf '%s\n' "$PLUGIN_HELP" | grep -q 'plugin <subcommand>'; then
  if [ "$(json_edit "$CONFIG_FILE" has-plugin -)" = "no" ]; then
    opencode plugin add "$PLUGIN_SPEC"
  else
    echo "==> Plugin entry already present in config, updating..."
    opencode plugin update "$PLUGIN_SPEC"
  fi
elif printf '%s\n' "$PLUGIN_HELP" | grep -q 'plugin <module>'; then
  echo "==> Installing with the legacy OpenCode plugin CLI..."
  opencode plugin "$PLUGIN_SPEC" --global --force
else
  echo "ERROR: Could not determine the installed OpenCode plugin CLI syntax." >&2
  printf '%s\n' "$PLUGIN_HELP" >&2
  exit 1
fi

# 2. Add the provider block (creates the /connect integration)
json_edit "$CONFIG_FILE" add-provider - "$PROVIDER_ID"

# 3. Apply the proxy URL/provider ID, if provided, and normalize plugin entries
json_edit "$CONFIG_FILE" normalize-plugin-entries - "$PROVIDER_ID"
if [ -n "$PROXY_URL" ] || [ "$PROVIDER_ID" != "litellm" ]; then
  json_edit "$CONFIG_FILE" apply-plugin-options "$PROXY_URL" "$PROVIDER_ID"
fi
if [ -n "$PROXY_URL" ]; then
  echo "==> Proxy URL set to: $PROXY_URL"
fi
if [ "$PROVIDER_ID" != "litellm" ]; then
  echo "==> Provider ID set to: $PROVIDER_ID"
fi

echo ""
echo "Installed. Next steps:"
echo ""
echo "  1. Connect your $PROVIDER_ID API key:"
echo ""
echo "       opencode auth login"
echo ""
echo "     (pick $PROVIDER_ID and paste the key)"
echo ""
if [ -z "$PROXY_URL" ]; then
  echo "  2. If your proxy is not at http://127.0.0.1:4000/v1, set the URL:"
  echo ""
  echo '       In '"$CONFIG_FILE"' change the plugins entry to:'
  echo '       { "package": "'"$PLUGIN_SPEC"'", "options": { "baseURL": "https://your-proxy/v1" } }'
  echo ""
  echo "  3. Restart the service if OpenCode is running:"
else
  echo "  2. Restart the service if OpenCode is running:"
fi
echo ""
echo "       opencode service restart"
echo ""
echo "  Then pick a $PROVIDER_ID/* model. The provider becomes visible in /models"
echo "  once your key is connected and the first models are discovered."
echo ""
echo "  If no models appear, check the plugin log:"
echo ""
echo "       tail -20 ~/.local/share/opencode/litellm-plugin.log"
