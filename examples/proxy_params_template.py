"""
PROXY PARAMETRE REFERANSI — açıklamalı template.

proxy_provider.py sade (drop-in) kalsın diye tüm opsiyonel parametreler burada
toplandı. Her parametrenin yanında: NE İŞE YARAR, HANGİ MODEL, KANIT durumu.
Buradan ihtiyacın olanı kopyalayıp kendi invoke()'una taşı.

Tüm değerler bu canlı proxy'de (eu.anthropic.claude-sonnet-4-5 + Vertex
gemini-2.5-flash) 2026-05-15'te bizzat test edildi — tahmin değil.

    export LITELLM_API_KEY="sk-..."
    python examples/proxy_params_template.py
"""

import json
import os
import urllib.request

BASE_URL = os.environ.get("LITELLM_BASE_URL", "https://litellm.example.com/v1")
API_KEY = os.environ.get("LITELLM_API_KEY", "")


def build_request_body() -> dict:
    """Her opsiyonel alanı açıklamalı gösteren tam bir istek gövdesi."""

    body = {
        # ── ZORUNLU ───────────────────────────────────────────────────────
        "model": "claude-sonnet-4-5",          # UI'daki public ad. Provider proxy'de çözülür.
        "messages": [
            {"role": "system", "content": "Sen bir e-spor analistisin."},
            {"role": "user", "content": "Kısa bir analiz yaz."},
        ],

        # ── ÜRETİM KONTROLÜ (OpenAI-standart, TÜM modeller) ───────────────
        "max_tokens": 1800,        # Üst sınır. gemini thinking açıkken bunu YÜKSEK tut.
        "temperature": 1.0,        # 0=deterministik, yüksek=yaratıcı. [KANIT: çalışıyor]
        # ⚠️ CROSS-PROVIDER TUZAK: Bedrock Claude `temperature` VE `top_p`'yi
        # BİRLİKTE reddeder -> 400 "cannot both be specified". Sadece BİRİNİ ver.
        # Gemini ikisini de kabul eder. Senin Vertex kodun ikisini de veriyordu;
        # aynı kodu Claude'a route edersen patlar. [KANIT: 2026-05-15 bisect]
        # "top_p": 0.99,           # Nucleus sampling. Claude'da temperature ile BİRLİKTE KULLANMA.
        "stop": ["</son>"],        # Bu dizilerden biri görülünce üretimi kes. [KANIT: stop=['3'] -> '1, 2, ']
        "seed": 42,                # Tekrarlanabilirlik (best-effort). [KANIT: kabul ediliyor]
        # "n": 1,                  # Kaç alternatif yanıt. Genelde 1; >1 maliyeti çarpar.
        # "frequency_penalty": 0,  # Tekrarı cezalandır (OpenAI-standart).
        # "presence_penalty": 0,   # Yeni konuya teşvik (OpenAI-standart).

        # ── THINKING KONTROLÜ (Gemini / reasoning modeller) ───────────────
        # Gemini-2.5-flash thinking-mode: kapatmazsan max_tokens'ı reasoning'e
        # harcayıp BOŞ metin döndürür (kanıtlandı).
        "reasoning_effort": "none",            # ✅ thinking'i KAPAT. En temiz yol (OpenAI-portable).
        #                                        "none" çalışır; "low" gemini'de KAPATMADI.
        # "thinking_config": {"thinking_budget": 0},    # ✅ senin ThinkingConfig(0)'ın BİREBİR karşılığı.
        # "thinking_config": {"thinking_budget": 256},  # ✅ N reasoning token AYIR (max_tokens > N olmalı).
        # NOT: "thinking": {"type": "disabled"} -> Anthropic-stili, gemini'de İŞE YARAMADI.

        # ── PROMPT CACHING ────────────────────────────────────────────────
        # Bedrock/Anthropic Claude: AÇIK cache. Uzun, sabit system/context'i
        # cache_control'lü BLOK olarak gönder -> 2. çağrıdan itibaren o kısım
        # ~%90 ucuz. Sonnet için min ~1024 token. [KANIT: create=2072 -> read=2072]
        #   "messages": [
        #     {"role": "system", "content": [
        #       {"type": "text", "text": UZUN_SABIT_BAGLAM,
        #        "cache_control": {"type": "ephemeral"}},
        #     ]},
        #     {"role": "user", "content": "asıl soru"},
        #   ]
        # Vertex Gemini: IMPLICIT cache (5K+ token'da otomatik) — PARAM GEREKMEZ.
        # Cache'i usage'da gör: cache_creation_input_tokens / cache_read_input_tokens
        #                       / prompt_tokens_details.cached_tokens

        # ── MALİYET ATIFLAMA (LiteLLM proxy'ye özel — projenin asıl amacı) ─
        # Spend log'a düşer, cost-report.sh / Usage'da kırılım için kullanılır.
        "metadata": {"tags": ["proj-a", "env-prod", "feature-x"]},
        #            ^ [KANIT: spend log request_tags'e düştü]
        "user": "proj-a",          # [KANIT: spend log end_user'a düştü]
        # (LiteLLM ayrıca User-Agent'ı otomatik tag'ler.)

        # ── AKIŞ ──────────────────────────────────────────────────────────
        # "stream": True,   # Token token akış. Senin invoke() tek-seferlik
        #                   # olduğu için GEREKMEZ; açarsan response'u
        #                   # iterator gibi tüketmen gerekir.
    }
    return body


def call(body: dict) -> dict:
    req = urllib.request.Request(
        f"{BASE_URL}/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as r:
        return json.load(r)


if __name__ == "__main__":
    if not API_KEY:
        raise SystemExit("LITELLM_API_KEY set edilmemiş.")
    d = call(build_request_body())
    print(d["choices"][0]["message"]["content"])
    u = d.get("usage", {})
    print(
        f"\n[usage] prompt={u.get('prompt_tokens')} comp={u.get('completion_tokens')} "
        f"cache_create={u.get('cache_creation_input_tokens')} "
        f"cache_read={u.get('cache_read_input_tokens')}"
    )
