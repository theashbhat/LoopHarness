//
//  VMAgentRuntime.swift
//  Loop
//
//  Shared building blocks for running a Loop agent turn on the user's VM as a
//  detached, stdlib-only Python one-shot. Two callers use it:
//
//   - `BackgroundTurnRunner` — a single one-shot when the app is backgrounded
//     mid-turn (writes `req-<turnId>.json`, runs once, removes the request).
//   - `VMCronManager` — a recurring cron job (writes a long-lived `req.json`,
//     `python3 run.py req.json` runs on the crontab schedule, minting a fresh
//     `turn_id` each firing and appending to `results.ndjson`).
//
//  The Python script (`pythonScript`) handles both modes off one config:
//  `cron: true` switches it from "write a single result file + delete the
//  request" to "append a results.ndjson line + keep the request" and mints a
//  per-run `turn_id` when none is supplied. Either way it POSTs a `runner_turn`
//  push so the device can surface the reply.
//

import Foundation

enum VMAgentRuntime {

    /// Where the one-shot writes its files on the VM.
    static let remoteDir = "$HOME/.loop"

    /// Same endpoint the Go runner defaults to / PUSH_NOTIFICATIONS.md documents.
    static let pushURL = "https://dev.generalbackend.com/loopharness/push/send"

    /// Pick the model + key for a remote run: the user's selected cloud provider
    /// if it has a key, else any available cloud key (Apple's on-device model
    /// can't run on the VM). `label` is the display name for the message byline.
    static func providerConfig() -> (provider: String, modelID: String, key: String, label: String)? {
        func key(_ k: KeyStore.Key) -> String? {
            let v = KeyStore.shared.value(for: k)
            return (v?.isEmpty == false) ? v : nil
        }
        let sel = ModelSelectionStore.current
        switch sel.provider {
        case .anthropic: if let k = key(.anthropic), let m = sel.apiModelID { return ("anthropic", m, k, sel.displayName) }
        case .openAI:    if let k = key(.openAI),    let m = sel.apiModelID { return ("openai", m, k, sel.displayName) }
        case .fireworks: if let k = key(.fireworks), let m = sel.apiModelID { return ("fireworks", m, k, sel.displayName) }
        case .apple: break
        }
        if let k = key(.openAI)    { return ("openai", "gpt-4o", k, "GPT-4o") }
        if let k = key(.anthropic) { return ("anthropic", "claude-sonnet-4-6", k, "Claude Sonnet 4.6") }
        if let k = key(.fireworks) { return ("fireworks", "accounts/fireworks/models/kimi-k2p6", k, "Kimi K2.6") }
        return nil
    }

    /// Every API key the user has, keyed by its env-var name (KeyStore.Key
    /// rawValue, e.g. GITHUB_PAT). Shipped to the runner so its tools can use any
    /// connected cloud service dynamically — whatever the user has set up.
    static func exportableKeys() -> [String: String] {
        var env: [String: String] = [:]
        for key in KeyStore.Key.allCases {
            if let v = KeyStore.shared.value(for: key), !v.isEmpty {
                env[key.rawValue] = v
            }
        }
        return env
    }

    /// Stdlib-only Python agent loop: read request → call the provider with the
    /// VM-runnable tools (`shell`, `web_fetch`, optional `web_search`) → execute
    /// tool calls → feed results back until a final answer (max 8 steps) → persist
    /// the result + POST the push. Handles both OpenAI-style (`tool_calls`) and
    /// Anthropic-style (`tool_use`) protocols. Errors are reported in the push body.
    ///
    /// Modes (off the request JSON):
    ///   - one-shot (default): writes `result_path` then removes the request file.
    ///   - cron (`cron: true`): mints `turn_id = job_id-<epoch>` when absent,
    ///     appends a line to `results_path`, and keeps the request file for reuse.
    static let pythonScript = #"""
import json, sys, os, time, urllib.request, urllib.error, subprocess

MAX_STEPS = 8
cfg = json.load(open(sys.argv[1]))
ENV = cfg.get("env", {})  # {ENV_VAR_NAME: value} — the user's connected API keys

def run_tool(name, args):
    try:
        if name == "shell":
            out = subprocess.run(["bash", "-lc", args.get("command", "")],
                                 capture_output=True, text=True, timeout=60,
                                 env={**os.environ, **ENV})
            r = out.stdout or ""
            if out.stderr:
                r += "\n[stderr]\n" + out.stderr
            return r[:6000] or "(no output)"
        if name == "web_fetch":
            req = urllib.request.Request(args.get("url", ""), headers={"User-Agent": "Loop/1.0"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read().decode("utf-8", "ignore")[:6000]
        if name == "web_search":
            n = int(args.get("num_results", 5) or 5)
            body = {"query": args.get("query", ""), "numResults": n,
                    "contents": {"text": {"maxCharacters": 800}}}
            req = urllib.request.Request("https://api.exa.ai/search",
                                         data=json.dumps(body).encode("utf-8"),
                                         headers={"x-api-key": ENV.get("EXA_API_KEY", ""),
                                                  "Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            hits = ["%s\n%s\n%s" % (r.get("title", ""), r.get("url", ""), (r.get("text") or "")[:500])
                    for r in data.get("results", [])[:n]]
            return "\n\n".join(hits) or "(no results)"
        return "unknown tool: " + str(name)
    except Exception as e:
        return "tool error: " + str(e)[:300]

def tool_specs():
    specs = [
        ("shell", "Run a bash command on this machine (your VM). Connected API keys are available as environment variables (use curl).",
         {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}),
        ("web_fetch", "HTTP GET a URL and return the body (truncated).",
         {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}),
    ]
    if ENV.get("EXA_API_KEY"):
        specs.append(("web_search", "Search the web (Exa); returns top results with snippets.",
                      {"type": "object", "properties": {"query": {"type": "string"},
                       "num_results": {"type": "integer"}}, "required": ["query"]}))
    return specs

def tools_openai():
    return [{"type": "function", "function": {"name": n, "description": d, "parameters": p}}
            for (n, d, p) in tool_specs()]

def tools_anthropic():
    return [{"name": n, "description": d, "input_schema": p} for (n, d, p) in tool_specs()]

def note():
    refs = {
        "GITHUB_PAT": "GitHub: curl https://api.github.com/... -H \"Authorization: Bearer $GITHUB_PAT\"",
        "NOTION_INTEGRATION_TOKEN": "Notion: curl https://api.notion.com/v1/... -H \"Authorization: Bearer $NOTION_INTEGRATION_TOKEN\" -H \"Notion-Version: 2022-06-28\"",
        "SLACK_USER_TOKEN": "Slack: curl https://slack.com/api/<method> -H \"Authorization: Bearer $SLACK_USER_TOKEN\"",
        "DEVIN_API_KEY": "Devin: curl https://api.devin.ai/v1/... -H \"Authorization: Bearer $DEVIN_API_KEY\"",
    }
    lines = [refs[k] for k in refs if ENV.get(k)]
    names = ", ".join(sorted(ENV.keys()))
    n = ("\n\n[You are Loop running in the BACKGROUND on the user's VM. Tools: "
         + ", ".join(s[0] for s in tool_specs())
         + ". Device-only Loop skills (calendar, files, health, music, location) are NOT available here.")
    if names:
        n += " Connected API keys, set as environment variables for the shell tool: " + names + "."
    if lines:
        n += " Quick refs: " + " | ".join(lines)
    n += " Use these to complete the task or answer directly, then stop.]"
    return n

def http(url, headers, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                 headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read().decode("utf-8"))

def run_openai(base, key, model, msgs):
    headers = {"Authorization": "Bearer " + key, "Content-Type": "application/json"}
    tools = tools_openai(); nt = note()
    if msgs and msgs[0].get("role") == "system":
        msgs[0]["content"] = (msgs[0].get("content") or "") + nt
    else:
        msgs.insert(0, {"role": "system", "content": nt.strip()})
    for _ in range(MAX_STEPS):
        resp = http(base, headers, {"model": model, "messages": msgs,
                                    "tools": tools, "tool_choice": "auto", "max_tokens": 1024})
        m = resp["choices"][0]["message"]
        calls = m.get("tool_calls") or []
        if not calls:
            return m.get("content") or ""
        msgs.append({"role": "assistant", "content": m.get("content") or "", "tool_calls": calls})
        for c in calls:
            try:
                a = json.loads(c["function"].get("arguments") or "{}")
            except Exception:
                a = {}
            msgs.append({"role": "tool", "tool_call_id": c["id"],
                         "content": run_tool(c["function"]["name"], a)})
    return "(stopped after %d tool steps)" % MAX_STEPS

def run_anthropic(key, model, system, msgs):
    headers = {"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"}
    tools = tools_anthropic(); system = (system or "") + note()
    for _ in range(MAX_STEPS):
        resp = http("https://api.anthropic.com/v1/messages", headers,
                    {"model": model, "max_tokens": 1024, "system": system,
                     "messages": msgs, "tools": tools})
        content = resp.get("content", [])
        tool_uses = [b for b in content if b.get("type") == "tool_use"]
        if not tool_uses:
            return "".join(b.get("text", "") for b in content if b.get("type") == "text")
        msgs.append({"role": "assistant", "content": content})
        results = [{"type": "tool_result", "tool_use_id": tu.get("id"),
                    "content": run_tool(tu.get("name"), tu.get("input") or {})} for tu in tool_uses]
        msgs.append({"role": "user", "content": results})
    return "(stopped after %d tool steps)" % MAX_STEPS

provider = cfg.get("provider", "openai")
model = cfg["model"]; key = cfg["api_key"]; msgs = cfg.get("messages", [])
text = ""; err = ""

try:
    if provider == "anthropic":
        system = "\n\n".join(m.get("content", "") for m in msgs if m.get("role") == "system")
        conv = [m for m in msgs if m.get("role") != "system"]
        text = run_anthropic(key, model, system, conv)
    else:
        base = ("https://api.fireworks.ai/inference/v1/chat/completions"
                if provider == "fireworks"
                else "https://api.openai.com/v1/chat/completions")
        text = run_openai(base, key, model, msgs)
except urllib.error.HTTPError as e:
    err = "HTTP %s: %s" % (e.code, e.read().decode("utf-8", "ignore")[:200])
except Exception as e:
    err = str(e)[:200]

is_cron = bool(cfg.get("cron"))
turn_id = cfg.get("turn_id") or (str(cfg.get("job_id", "job")) + "-" + str(int(time.time())))
conv_id = cfg.get("conversation_id", "")

try:
    if is_cron:
        line = json.dumps({"turn_id": turn_id, "conversation_id": conv_id,
                           "text": text, "error": err, "ts": int(time.time())})
        with open(cfg["results_path"], "a") as f:
            f.write(line + "\n")
    else:
        json.dump({"turn_id": turn_id, "conversation_id": conv_id,
                   "text": text, "error": err}, open(cfg["result_path"], "w"))
except Exception:
    pass

push = {
    "user_id": cfg["user_id"],
    "title": cfg.get("title", "Loop"),
    "body": ("⚠️ " + err[:150]) if err else (text[:180] or "Done"),
    "data": {"type": "runner_turn", "turn_id": turn_id,
             "conversation_id": conv_id, "text": text[:3000]},
}
try:
    http(cfg["push_url"], {"Content-Type": "application/json"}, push)
except Exception:
    pass

# The one-shot request file holds the keys, so it's removed after use. A cron
# request is reused on every firing, so it's kept (written chmod 600).
if not is_cron:
    try:
        os.remove(sys.argv[1])
    except Exception:
        pass
"""#
}
