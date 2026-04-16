# codex2vllm

`codex2vllm` exists to connect **OpenAI Codex CLI** to a **vLLM** server.

This service is not primarily for generic OpenAI-compatible clients. Its main job is to make Codex CLI work reliably against a vLLM-backed model by normalizing the `/v1/responses` request and response flow that Codex depends on. It does not run models itself. It sits between Codex CLI and vLLM.

## Why Codex CLI Needs It

Codex CLI is built around the Responses API and expects stable request and streaming semantics. `codex2vllm` fills the gap between those expectations and a raw vLLM endpoint.

At a high level:

```text
Codex CLI -> codex2vllm -> vLLM
              |            |
              |            -> model inference
              |
              -> /v1/responses request normalization
              -> response and SSE cleanup
              -> optional debug session logs
```

The service is built around a single Sinatra app: `Qwen3CoderToolCallShim`.

## Codex CLI Quickstart

This is the best onboarding path for new users:

1. Install Codex CLI.
2. Start the backing vLLM model with the expected flags.
3. Run `codex2vllm` against that vLLM server.
4. Add a custom Codex provider in `~/.codex/config.toml`.
5. Start Codex with a dedicated profile that points at this shim.

OpenAI’s Codex docs say:

- Codex CLI setup: <https://developers.openai.com/codex/cli>
- Config basics: <https://developers.openai.com/codex/config-basic>
- Config reference: <https://developers.openai.com/codex/config-reference>
- Authentication: <https://developers.openai.com/codex/auth>

### 1. Install Codex CLI

```bash
npm i -g @openai/codex
```

### 2. Start The Backing vLLM Model

`codex2vllm` expects a vLLM OpenAI server behind it.

Start vLLM with these parameters:

```bash
docker run --rm \
  --gpus all \
  -p 8000:8000 \
  vllm/vllm-openai:latest \
  --model RedHatAI/Qwen3.5-35B-A3B-FP8-dynamic \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 1 \
  --served-model-name Qwen3.5-35B-A3B-FP8 \
  --gpu-memory-utilization 0.92 \
  --max-model-len auto \
  --kv-cache-dtype fp8_e4m3 \
  --max-num-seqs 1 \
  --language-model-only \
  --generation-config vllm \
  --enable-auto-tool-choice \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --structured-outputs-config.backend xgrammar
```

Notes:

- The Codex profile below should use the same value as `--served-model-name`.
- Add extra vLLM flags only if your hardware requires them.

### 3. Build And Run `codex2vllm`

Point the shim at the vLLM server from the previous step.

```bash
docker build -t codex2vllm:test -f docker/ruby/Dockerfile src
docker run --rm \
  -p 9293:9293 \
  -e VLLM_UPSTREAM=http://127.0.0.1:8000 \
  codex2vllm:test
```

### 4. Configure Codex CLI

Add a custom provider and profile to `~/.codex/config.toml`.

```toml
[model_providers.codex2vllm_local]
name = "codex2vllm local"
base_url = "http://127.0.0.1:9293/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false

[profiles.codex2vllm_local]
model_provider = "codex2vllm_local"
model = "Qwen3.5-35B-A3B-FP8"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
```

Notes:

- OpenAI documents `~/.codex/config.toml` as the user-level config location.
- OpenAI also documents project-scoped `.codex/config.toml`, but this README uses the user config because it is the least surprising first-run setup.
- `wire_api = "responses"` matches the protocol this shim is built for.
- `requires_openai_auth = false` tells Codex to use this custom provider instead of OpenAI authentication for model requests.
- `model = "Qwen3.5-35B-A3B-FP8"` must match the vLLM `--served-model-name`.
- If your proxy or gateway requires an auth header, prefer `env_key` or command-backed auth from the Codex config reference instead of `experimental_bearer_token`.

### 5. Start Codex With The Profile

```bash
codex --profile codex2vllm_local
```

Short form:

```bash
codex -p codex2vllm_local
```

### 6. Verify The Setup

Check that the model server is up:

```bash
curl http://127.0.0.1:8000/v1/models
```

Then check that the shim is up:

```bash
curl http://127.0.0.1:9293/health
```

Expected response:

```json
{"ok":true,"service":"Qwen3CoderToolCallShim"}
```

Then launch Codex with the configured profile and ask it to inspect the current repository.

```bash
codex -p codex2vllm_local
```

## Key Functionality

- Full HTTP proxy: forwards `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`, and `HEAD` requests for `/` and `/*` to the upstream service so Codex CLI can use one base URL.
- `/responses` request normalization: rewrites `developer` and `system` message content into `instructions`, normalizes message and reasoning items, and drops malformed unsupported items before vLLM sees them.
- Response normalization: cleans JSON responses and rewrites SSE streams so Codex CLI sees coherent assistant message lifecycle events.
- Health endpoint: exposes `GET /health` for fast local readiness checks.
- Debug session logging: when enabled, writes normalized requests, upstream responses, traces, and metadata to disk.

## What It Does Not Do

- It does not serve models.
- It does not replace vLLM.
- It does not add authentication, rate limiting, or persistent storage.
- It does not change non-`/responses` endpoints beyond standard proxy header filtering.

## How Requests Flow

1. Codex CLI sends a request to `codex2vllm`.
2. `GET /health` is answered locally.
3. All other requests are proxied to `VLLM_UPSTREAM`.
4. Requests for `/v1/responses` and `/responses` are normalized before forwarding.
5. JSON and SSE responses are normalized before Codex CLI receives them.
6. If debug logging is enabled, request and response artifacts are written to disk.

## Configuration

- `VLLM_UPSTREAM`: base URL of the upstream vLLM service. Default: `http://vllm.h100.local`.
- `BIND`: listen address for the Sinatra app. Default: `127.0.0.1`.
- `PORT`: listen port. Default: `9293`.
- `VLLM_SHIM_SESSION_LOG_DIR`: root directory for per-session trace output. Default: `/tmp/vllm-shim-tool-call-sessions`.
- `VLLM_SHIM_TOOL_CALL_DEBUG`: enables debug snapshots and session trace logging when set.

Container defaults also set:

- `SERVER_ENV=production`
- `RACK_ENV=production`

## Debugging

When `VLLM_SHIM_TOOL_CALL_DEBUG=1` is set, the shim writes debug artifacts such as:

- `/tmp/vllm-shim-tool-call-last-request.json`
- `/tmp/vllm-shim-tool-call-last-upstream-response.txt`
- `/tmp/vllm-shim-tool-call-last-response.txt`
- Per-session files under `VLLM_SHIM_SESSION_LOG_DIR`

Per-session logs can include:

- Raw request body
- Normalized outbound request
- Upstream response
- Normalized response
- Headers
- Trace JSONL
- Turn metadata

## Local Development

If you want to run the service without Docker:

```bash
cd src
bundle install
VLLM_UPSTREAM=http://127.0.0.1:8000 \
  bundle exec rackup tool-call-shim.ru -o 0.0.0.0 -p 9293 -s falcon
```

The project is pinned to Ruby `3.4.4`.

## Repository Layout

```text
.
├── .github/workflows/main.yml
├── docker/
│   ├── docker-compose.yml
│   └── ruby/Dockerfile
└── src/
    ├── Gemfile
    ├── Gemfile.lock
    ├── .ruby-version
    ├── .version
    └── tool-call-shim.ru
```

## Delivery Notes

- The image is built from `src/` using `docker/ruby/Dockerfile`.
- CI publishes images on pushes to `main`, `release`, and `dev`.

## Summary

This service is best understood as a Codex CLI compatibility shim in front of vLLM:

- use it when you want Codex CLI to drive a vLLM-backed model
- start the upstream model with the tool-calling and parser flags required by your chosen model
- rely on it most for `/responses` compatibility and stream cleanup
- keep vLLM responsible for model execution
