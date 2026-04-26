#!/usr/bin/env bash
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
HOOKS_DIR="$CLAUDE_DIR/conductor-hooks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_JSON="$SCRIPT_DIR/agents.json"
SOURCE_HOOKS_DIR="$SCRIPT_DIR/hooks"
DETECTED_JSON="$(mktemp -t conductor-detected.XXXXXX.json)"
trap 'rm -f "$DETECTED_JSON"' EXIT

echo "🎼 conductor installer"
echo ""

# Parse agents.json — need node/bun
if ! command -v node &>/dev/null && ! command -v bun &>/dev/null; then
  echo "Error: node or bun required to parse agents.json"
  exit 1
fi
RUNNER="$(command -v bun || command -v node)"

# Detect which agents are available
echo "Detecting agents from agents.json..."
DETECTED_JSON="$DETECTED_JSON" AGENTS_JSON="$AGENTS_JSON" "$RUNNER" -e '
const fs = require("fs");
const { execSync } = require("child_process");

function parseJsonc(path) {
  const raw = fs.readFileSync(path, "utf8");
  const stripped = raw
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:])\/.*/gm, "$1");
  return JSON.parse(stripped);
}

const config = parseJsonc(process.env.AGENTS_JSON);
if (!config.agents || !Array.isArray(config.agents)) {
  console.error("  ✗ agents.json missing `agents` array");
  process.exit(1);
}

const found = [];
for (const agent of config.agents) {
  let detected = false;
  if (agent.detect_cmd) {
    try {
      execSync("command -v " + agent.detect_cmd, { stdio: "ignore", shell: "/bin/bash" });
      detected = true;
    } catch {}
  } else if (agent.detect_path) {
    const resolved = agent.detect_path.replace(/^~/, process.env.HOME || "~");
    try {
      execSync("test -f \"" + resolved + "\"", { stdio: "ignore", shell: "/bin/bash" });
      detected = true;
    } catch {}
  }

  if (detected) {
    found.push(agent);
    console.log("  ✓ " + agent.name + " found");
  } else {
    const hint = agent.detect_cmd || agent.detect_path || "?";
    console.log("  ✗ " + agent.name + " not found (" + hint + ")");
  }
}

fs.writeFileSync(process.env.DETECTED_JSON, JSON.stringify(found, null, 2));
'
echo ""

# Copy MCP shim directories to ~/.claude-router/
echo "Installing MCP shims..."
mkdir -p ~/.claude-router
shim_count=0
for shim_dir in "$SCRIPT_DIR"/*-mcp; do
  [ -d "$shim_dir" ] || continue
  shim_name="$(basename "$shim_dir")"
  cp -rf "$shim_dir" ~/.claude-router/
  echo "  ✓ $shim_name → ~/.claude-router/$shim_name"
  shim_count=$((shim_count + 1))
done
[ "$shim_count" -eq 0 ] && echo "  (no shim directories found)"
echo ""

# Register MCPs for detected agents
echo "Registering MCPs..."
DETECTED_JSON="$DETECTED_JSON" "$RUNNER" -e '
const fs = require("fs");
const { spawnSync } = require("child_process");
const agents = JSON.parse(fs.readFileSync(process.env.DETECTED_JSON, "utf8"));

for (const agent of agents) {
  const cmd = (agent.mcp_cmd || []).map((part) =>
    typeof part === "string" && part.startsWith("~")
      ? part.replace(/^~/, process.env.HOME || "~")
      : part
  );

  const args = ["mcp", "add", "--scope", "user", agent.mcp_name, "--", ...cmd];
  const result = spawnSync("claude", args, { stdio: "ignore" });
  if (result.status === 0) {
    console.log("  ✓ " + agent.mcp_name + " registered");
  } else {
    console.log("  ✗ " + agent.mcp_name + " failed (already registered?)");
  }
}
'
echo ""

# Install conductor hooks
echo "Installing conductor hooks..."
mkdir -p "$HOOKS_DIR"
cp -f "$SOURCE_HOOKS_DIR/token-tracker.sh" "$HOOKS_DIR/token-tracker.sh"
cp -f "$SOURCE_HOOKS_DIR/token-summary.sh" "$HOOKS_DIR/token-summary.sh"
chmod +x "$HOOKS_DIR/token-tracker.sh" "$HOOKS_DIR/token-summary.sh"
echo "  ✓ hooks copied to $HOOKS_DIR"
echo ""

# Patch settings.json — add permissions.allow for detected agents
echo "Patching settings.json..."
mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo "{}" > "$SETTINGS"
DETECTED_JSON="$DETECTED_JSON" SETTINGS="$SETTINGS" "$RUNNER" -e '
const fs = require("fs");
const agents = JSON.parse(fs.readFileSync(process.env.DETECTED_JSON, "utf8"));
const settings = JSON.parse(fs.readFileSync(process.env.SETTINGS, "utf8"));

settings.permissions = settings.permissions || {};
settings.permissions.allow = settings.permissions.allow || [];
for (const agent of agents) {
  const tools = [
    "mcp__" + agent.mcp_name + "__" + agent.name,
    "mcp__" + agent.mcp_name + "__" + agent.name + "-reply",
  ];
  for (const tool of tools) {
    if (!settings.permissions.allow.includes(tool)) {
      settings.permissions.allow.push(tool);
    }
  }
}

settings.hooks = settings.hooks || {};
settings.hooks.PostToolUse = settings.hooks.PostToolUse || [];
settings.hooks.Stop = settings.hooks.Stop || [];

const trackerCommand = "~/.claude/conductor-hooks/token-tracker.sh";
const summaryCommand = "~/.claude/conductor-hooks/token-summary.sh";
const agentMatcher = agents.map(a => "mcp__" + a.mcp_name + "__").join("|");

const trackerIdx = settings.hooks.PostToolUse.findIndex((entry) =>
  Array.isArray(entry.hooks) &&
  entry.hooks.some((hook) => hook && hook.command === trackerCommand)
);

if (trackerIdx === -1) {
  settings.hooks.PostToolUse.push({
    matcher: agentMatcher,
    hooks: [{ type: "command", command: trackerCommand }],
  });
} else {
  settings.hooks.PostToolUse[trackerIdx].matcher = agentMatcher;
}

const hasSummary = settings.hooks.Stop.some((entry) =>
  Array.isArray(entry.hooks) &&
  entry.hooks.some((hook) => hook && hook.command === summaryCommand)
);

if (!hasSummary) {
  settings.hooks.Stop.push({
    hooks: [{ type: "command", command: summaryCommand }],
  });
}

fs.writeFileSync(process.env.SETTINGS, JSON.stringify(settings, null, 2));
console.log("  ✓ permissions + hooks patched");
'
echo ""

# Generate CLAUDE.md from template + detected agents
echo "Generating CLAUDE.md..."
[ -f "$CLAUDE_MD" ] && {
  cp "$CLAUDE_MD" "$CLAUDE_MD.conductor-backup"
  echo "  ✓ backed up existing CLAUDE.md"
}

DETECTED_JSON="$DETECTED_JSON" TEMPLATE="$SCRIPT_DIR/CLAUDE.md" CLAUDE_MD="$CLAUDE_MD" "$RUNNER" -e '
const fs = require("fs");
const agents = JSON.parse(fs.readFileSync(process.env.DETECTED_JSON, "utf8"));
const template = fs.readFileSync(process.env.TEMPLATE, "utf8");

const title = (value) => value.charAt(0).toUpperCase() + value.slice(1);
const roleMap = {
  code: "Code, repo, files, debug, tests, refactor, build",
  search: "Search, web research, UI, visual design",
  design: "UI/UX, prototypes, visual",
  general: "Offline / local tasks, sensitive data, no internet",
};

const teamLines = agents
  .map(
    (agent) =>
      "- **" +
      title(agent.name) +
      "** — " +
      agent.description +
      " Called via `" +
      agent.mcp_name +
      "` MCP."
  )
  .join("\n");

const classifierLines = agents
  .map((agent) => "   - " + (roleMap[agent.role] || agent.role) + " → **" + title(agent.name) + "**")
  .join("\n");

const delegationLines = agents
  .map(
    (agent) =>
      "### " +
      title(agent.name) +
      " (`mcp__" +
      agent.mcp_name +
      "__" +
      agent.name +
      "`}\n" +
      "- `prompt`: caveman-compressed request. Include desired output.\n" +
      "- `cwd`: project dir. Pass every time.\n" +
      "- `sandbox`: read-only | workspace-write | danger-full-access\n" +
      "- `approval-policy`: on-request"
  )
  .join("\n\n");

const permLines = agents
  .flatMap((agent) => [
    "\"mcp__" + agent.mcp_name + "__" + agent.name + "\"",
    "\"mcp__" + agent.mcp_name + "__" + agent.name + "-reply\"",
  ])
  .join(", ");

const rendered = template
  .replace("{{TEAM}}", teamLines)
  .replace("{{CLASSIFIER}}", classifierLines)
  .replace("{{DELEGATION}}", delegationLines)
  .replace("{{PERMISSIONS}}", permLines);

fs.writeFileSync(process.env.CLAUDE_MD, rendered);
console.log("  ✓ CLAUDE.md generated with " + agents.length + " agent(s)");
'

AGENT_SUMMARY="$("$RUNNER" -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(d.length+" agent(s): "+d.map(a=>a.name).join(", "));' "$DETECTED_JSON")"
echo ""
echo "✅ conductor installed with $AGENT_SUMMARY. Restart Claude Code to apply."
