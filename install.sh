#!/usr/bin/env bash
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"

echo "🎼 conductor installer"
echo ""

# --- Detect CLIs ---
echo "Detecting CLIs..."
CODEX_OK=false
GEMINI_OK=false
command -v codex &>/dev/null && CODEX_OK=true && echo "  ✓ codex found"
command -v gemini &>/dev/null && GEMINI_OK=true && echo "  ✓ gemini found"
$CODEX_OK || echo "  ✗ codex not found — install from https://github.com/openai/codex"
$GEMINI_OK || echo "  ✗ gemini not found — install Gemini CLI"
echo ""

# --- Register MCPs ---
if $CODEX_OK; then
  echo "Registering codex MCP..."
  claude mcp add --scope user codex-delegate -- codex mcp-server 2>/dev/null && echo "  ✓ codex-delegate registered" || echo "  ✗ codex MCP failed (already registered?)"
fi

if $GEMINI_OK; then
  SHIM="$HOME/.claude-router/gemini-mcp/server.mjs"
  if [ -f "$SHIM" ]; then
    echo "Registering gemini MCP..."
    claude mcp add --scope user gemini-delegate -- node "$SHIM" 2>/dev/null && echo "  ✓ gemini-delegate registered" || echo "  ✗ gemini MCP failed (already registered?)"
  else
    echo "  ✗ gemini shim not found at $SHIM — skipping gemini MCP"
  fi
fi
echo ""

# --- Patch settings.json ---
echo "Patching settings.json..."
mkdir -p "$CLAUDE_DIR"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi
# Merge permissions.allow using node
node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync('$SETTINGS', 'utf8'));
s.permissions = s.permissions || {};
s.permissions.allow = s.permissions.allow || [];
const toAdd = ['mcp__codex-delegate__codex','mcp__codex-delegate__codex-reply','mcp__gemini-delegate__gemini'];
toAdd.forEach(t => { if (!s.permissions.allow.includes(t)) s.permissions.allow.push(t); });
fs.writeFileSync('$SETTINGS', JSON.stringify(s, null, 2));
console.log('  ✓ permissions patched');
"
echo ""

# --- Write CLAUDE.md ---
echo "Writing CLAUDE.md..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$CLAUDE_MD" ]; then
  cp "$CLAUDE_MD" "$CLAUDE_MD.conductor-backup"
  echo "  ✓ backed up existing CLAUDE.md to CLAUDE.md.conductor-backup"
fi
cp "$SCRIPT_DIR/CLAUDE.md" "$CLAUDE_MD"
echo "  ✓ CLAUDE.md written"
echo ""

echo "✅ conductor installed. Restart Claude Code to apply."
