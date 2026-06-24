# Ollama LLM Service

Local LLM inference service running on the GPU node (Tesla P40, 24GB VRAM).

## Access

### Web Interface (Open WebUI)

**URL**: https://chat.wind.etherport.net

A ChatGPT-like interface for interacting with the LLM. Features include:
- Conversation history
- Markdown rendering
- Code syntax highlighting
- Multiple model support

> **Auth:** Open WebUI (`chat.wind.etherport.net`) is gated by **Authentik OIDC**
> (the homelab SSO IdP). The raw Ollama API (`ollama.wind.etherport.net`) is
> left **ungated** by design — it's a machine API, scoped by the UDM firewall.

### API Access

**Base URL**: https://ollama.wind.etherport.net

The Ollama API is OpenAI-compatible and can be used directly or with various clients.

#### List Available Models

```bash
curl https://ollama.wind.etherport.net/api/tags
```

#### Generate Completion (Streaming)

```bash
curl https://ollama.wind.etherport.net/api/generate \
  -d '{
    "model": "qwen2.5:32b",
    "prompt": "Explain kubernetes in one paragraph"
  }'
```

#### Generate Completion (Non-Streaming)

```bash
curl https://ollama.wind.etherport.net/api/generate \
  -d '{
    "model": "qwen2.5:32b",
    "prompt": "Explain kubernetes in one paragraph",
    "stream": false
  }'
```

#### Chat Completion (OpenAI-compatible)

```bash
curl https://ollama.wind.etherport.net/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5:32b",
    "messages": [
      {"role": "user", "content": "Hello!"}
    ]
  }'
```

#### Using with Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://ollama.wind.etherport.net/v1",
    api_key="not-needed"  # Ollama doesn't require an API key
)

response = client.chat.completions.create(
    model="qwen2.5:32b",
    messages=[
        {"role": "user", "content": "Hello!"}
    ]
)

print(response.choices[0].message.content)
```

#### Using with curl (Interactive CLI)

```bash
kubectl exec -n ollama deploy/ollama -it -- ollama run qwen2.5:32b
```

## Model Management

#### Pull a New Model

```bash
kubectl exec -n ollama deploy/ollama -- ollama pull <model-name>
```

#### List Models

```bash
kubectl exec -n ollama deploy/ollama -- ollama list
```

#### Remove a Model

```bash
kubectl exec -n ollama deploy/ollama -- ollama rm <model-name>
```

## Current Model

- **qwen2.5:32b** - Qwen 2.5 32B parameter model (Q4_K_M quantization, ~19GB)
  - Comparable to GPT-3.5-Turbo to early GPT-4 level
  - Good for general tasks, coding, and reasoning
  - ~10-15 tokens/sec on Tesla P40

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Traefik                               │
│  chat.wind.etherport.net    ollama.wind.etherport.net       │
└─────────────┬─────────────────────────┬─────────────────────┘
              │                         │
              ▼                         ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│      Open WebUI         │──▶│        Ollama           │
│   (Web Interface)       │   │    (LLM Inference)      │
│   Port: 8080            │   │    Port: 11434          │
└─────────────────────────┘   └─────────────────────────┘
                                        │
                                        ▼
                              ┌─────────────────────────┐
                              │     Tesla P40 GPU       │
                              │      (24GB VRAM)        │
                              └─────────────────────────┘
```

## Notes

- The Ollama data volume is excluded from Velero backups due to the large model size (~19GB)
- Models can be re-downloaded if needed: `ollama pull qwen2.5:32b`
- GPU is shared with Plex for hardware transcoding
