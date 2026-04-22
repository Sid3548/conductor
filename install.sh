#!/usr/bin/env bash
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_JSON="$SCRIPT_DIR/agents.json"
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
    .replace(/(^|[^:])\/\/.*$/gm, "$1");
  return JSON.parse(stripped);
}

const config = parseJsonc(process.env.AGENTS_JSON);
if (!config.agents || !Array.isArray(config.agents)) {
  console.error("  ✗ agents.json missing `agents` array");
  process.exit(1);
}

const found = [];
for (const agent of config.agents) {
  try {
    execSync("command -v " + agent.detect_cmd, { stdio: "ignore", shell: "/bin/bash" });
    found.push(agent);
    console.log("  ✓ " + agent.name + " found");
  } catch {
    console.log("  ✗ " + agent.name + " not found (install " + agent.detect_cmd + ")");
  }
}

fs.writeFileSync(process.env.DETECTED_JSON, JSON.stringify(found, null, 2));
'
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

fs.writeFileSync(process.env.SETTINGS, JSON.stringify(settings, null, 2));
console.log("  ✓ permissions patched");
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
  general: "General tasks",
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
      "`)\n" +
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
