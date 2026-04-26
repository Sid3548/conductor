#!/usr/bin/env node
// MCP server — wraps locally running llama-server (llama.cpp) for Qwen.
// No external dependencies. Requires Node 18+ (built-in fetch).
// Start the server before use: run-qwen27b-server.cmd

const QWEN_BASE_URL = process.env.QWEN_BASE_URL || "http://127.0.0.1:8080";

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function callQwen(prompt, cwd) {
  const system = cwd
    ? `Working directory: ${cwd}\nYou are a helpful AI assistant.`
    : "You are a helpful AI assistant.";

  const res = await fetch(`${QWEN_BASE_URL}/v1/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "qwen",
      messages: [
        { role: "system", content: system },
        { role: "user", content: prompt },
      ],
      temperature: 0.3,
      max_tokens: 2048,
      stream: false,
    }),
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`llama-server HTTP ${res.status}: ${body}`);
  }
  const data = await res.json();
  return data.choices?.[0]?.message?.content ?? "(no response)";
}

let buffer = "";
process.stdin.setEncoding("utf8");

process.stdin.on("data", async (chunk) => {
  buffer += chunk;
  const lines = buffer.split("\n");
  buffer = lines.pop();

  for (const line of lines) {
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }

    if (msg.method === "initialize") {
      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "qwen-delegate", version: "0.1.0" },
        },
      });
    } else if (msg.method === "notifications/initialized") {
      // no-op
    } else if (msg.method === "tools/list") {
      send({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          tools: [
            {
              name: "qwen",
              description:
                "Delegate a task to locally running Qwen via llama.cpp. Requires llama-server on port 8080.",
              inputSchema: {
                type: "object",
                properties: {
                  prompt: { type: "string", description: "Task or question for Qwen" },
                  cwd: { type: "string", description: "Working directory context" },
                },
                required: ["prompt"],
              },
            },
          ],
        },
      });
    } else if (msg.method === "tools/call") {
      const { name, arguments: args } = msg.params;
      if (name !== "qwen") {
        send({
          jsonrpc: "2.0",
          id: msg.id,
          error: { code: -32601, message: `Unknown tool: ${name}` },
        });
        continue;
      }
      try {
        const text = await callQwen(args.prompt, args.cwd);
        send({
          jsonrpc: "2.0",
          id: msg.id,
          result: { content: [{ type: "text", text }] },
        });
      } catch (err) {
        send({
          jsonrpc: "2.0",
          id: msg.id,
          error: { code: -32000, message: err.message },
        });
      }
    } else if (msg.id !== undefined) {
      send({
        jsonrpc: "2.0",
        id: msg.id,
        error: { code: -32601, message: `Method not found: ${msg.method}` },
      });
    }
  }
});
