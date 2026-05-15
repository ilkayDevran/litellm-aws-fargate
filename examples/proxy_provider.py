"""
LiteLLM proxy-backed provider — tipik bir direct-Vertex (google-genai) provider'ın
proxy'ye taşınmış drop-in karşılığı.

Mevcut `vertex_ai.py` ile fark:
  - google-genai SDK + google.oauth2 + boto3 Secrets Manager SA fetch  -> SİLİNDİ
  - GCP project/location/credentials                                   -> SİLİNDİ
  - Hepsinin yerine: tek OpenAI-uyumlu HTTP çağrısı + tek LITELLM_API_KEY
Provider (Vertex/Bedrock) çözümü + cost tracking proxy tarafında.

`base.py`'deki LLMResponse/LLMProvider interface'ine birebir uyar — kendi
projende bu sınıfı aynı interface ile import edip get_provider'a bağlayabilirsin.
Bağımlılık YOK (sadece stdlib urllib) — Lambda paketini şişirmez.

ENV:
    LITELLM_API_KEY     virtual key (sk-...)         [zorunlu]
    LITELLM_BASE_URL    default https://litellm.example.com/v1
    PROXY_MODEL         public model adı, örn 'your-vertex-model'
"""

import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict


# --- base.py'deki ile aynı; kendi projende oradan import et, burada self-contained ---
@dataclass
class LLMResponse:
    text: str
    input_tokens: int
    output_tokens: int
    latency_ms: int
    model_id: str
    model_name: str
    cached_tokens: int = 0


class ProxyLLMProvider:
    """LiteLLM proxy üzerinden tek-seferlik (non-streaming) completion."""

    BASE_URL = os.getenv("LITELLM_BASE_URL", "https://litellm.example.com/v1")
    API_KEY = os.getenv("LITELLM_API_KEY", "")
    MODEL = os.getenv("PROXY_MODEL", "your-vertex-model")

    MAX_TOKENS = 1800
    TEMPERATURE = float(os.getenv("VERTEX_TEMPERATURE", "1.0"))
    TOP_P = 0.99

    def invoke(self, system_prompt: str, user_payload: Dict[str, Any]) -> LLMResponse:
        if not self.API_KEY:
            raise RuntimeError("LITELLM_API_KEY env var is not set")

        user_text = json.dumps(user_payload, ensure_ascii=False)

        body = {
            "model": self.MODEL,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_text},
            ],
            "max_tokens": self.MAX_TOKENS,
            "temperature": self.TEMPERATURE,
            # Gemini ikisini de kabul eder. UYARI: Bedrock Claude `temperature`
            # ve `top_p`'yi BİRLİKTE reddeder (400) — bu provider'ı Claude'a
            # yönlendirirsen top_p'yi kaldır. (bkz. proxy_params_template.py)
            "top_p": self.TOP_P,
            # vertex_ai.py'deki types.ThinkingConfig(thinking_budget=0) karşılığı.
            # Proxy üzerinden kanıtlandı: 'none' thinking'i kapatır, yoksa
            # gemini-2.5-flash token'ı reasoning'e harcayıp boş metin döner.
            # Birebir eşdeğeri istersen: body["thinking_config"]={"thinking_budget":0}
            "reasoning_effort": "none",
        }

        req = urllib.request.Request(
            f"{self.BASE_URL}/chat/completions",
            data=json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {self.API_KEY}",
                     "Content-Type": "application/json"},
        )

        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req) as r:
                d = json.load(r)
        except urllib.error.HTTPError as e:
            # openai SDK'nın AuthenticationError/RateLimitError'ına denk ayrım
            raise RuntimeError(f"proxy {e.code}: {e.read()[:200]!r}") from e
        latency_ms = int((time.perf_counter() - start) * 1000)

        choice = d["choices"][0]
        text = choice["message"].get("content") or ""

        u = d.get("usage", {}) or {}
        prompt_tokens = int(u.get("prompt_tokens", 0) or 0)
        output_tokens = int(u.get("completion_tokens", 0) or 0)
        cached_tokens = int((u.get("prompt_tokens_details") or {}).get("cached_tokens", 0) or 0)
        fresh_input_tokens = max(prompt_tokens - cached_tokens, 0)

        return LLMResponse(
            text=text,
            input_tokens=fresh_input_tokens,
            output_tokens=output_tokens,
            latency_ms=latency_ms,
            model_id=d.get("model", self.MODEL),
            model_name=self.MODEL,
            cached_tokens=cached_tokens,
        )


if __name__ == "__main__":
    resp = ProxyLLMProvider().invoke(
        system_prompt="Kısa ve net cevap ver.",
        user_payload={"soru": "E-spor nedir? 2 maddede özetle."},
    )
    print(resp.text)
    print(
        f"\n[meta] in={resp.input_tokens} out={resp.output_tokens} "
        f"cached={resp.cached_tokens} latency={resp.latency_ms}ms model={resp.model_id}"
    )
