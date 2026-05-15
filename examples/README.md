# examples/

Proxy'ye OpenAI-uyumlu HTTP ile çağrı örnekleri. Bağımlılık yok (stdlib `urllib`).
Provider (Bedrock/Vertex) proxy'de çözülür; kod sadece public model adını bilir.

## Kurulum

```bash
export LITELLM_API_KEY="sk-..."                          # virtual key
export LITELLM_BASE_URL="https://<DOMAIN_NAME>/v1"       # opsiyonel
```

## Dosyalar

| Dosya | Amaç | Çalıştırma |
|---|---|---|
| `proxy_provider.py` | Mevcut bir LLM provider'ını proxy'ye taşımak için drop-in sınıf | `LITELLM_API_KEY=sk-... python examples/proxy_provider.py` |
| `proxy_params_template.py` | Geçilebilecek tüm opsiyonel parametrelerin açıklamalı referansı | `LITELLM_API_KEY=sk-... python examples/proxy_params_template.py` |

## proxy_provider.py

`base.py`'deki `LLMProvider`/`LLMResponse` interface'ine uyan, tek-seferlik
(non-streaming) completion yapan bir sınıf:
`invoke(system_prompt, user_payload) -> LLMResponse`.

Kendi projende:
1. Dosyadaki yerel `LLMResponse` kopyasını sil, kendi `base.py`'inden import et.
2. Sınıfı provider factory'ne (`get_provider`) bağla.
3. Sağlayıcıya özel SDK/credential katmanını (ör. google-genai + SA fetch) kaldır;
   yerine tek `LITELLM_API_KEY` + public model adı kalır.

Env: `LITELLM_API_KEY` (zorunlu), `LITELLM_BASE_URL`, `PROXY_MODEL`,
`VERTEX_TEMPERATURE`.

## proxy_params_template.py

Tek bir istek gövdesinde tüm opsiyonel parametreleri, her birinin ne işe
yaradığını ve hangi modelde geçerli olduğunu açıklamalı gösterir. İhtiyacın olanı
kopyalayıp kendi çağrına taşı. Çalıştırılabilir: tek istek atıp usage döker.

Kapsadığı parametreler: `temperature` / `top_p` / `stop` / `seed`, thinking
kontrolü, prompt caching, maliyet atıflama tag'leri.

## Kullanım notları

- **Gemini thinking**: `gemini-2.5-flash` gibi thinking modeller, thinking
  kapatılmazsa `max_tokens`'ı reasoning'e harcayıp boş metin döndürebilir.
  Kapatmak için `reasoning_effort: "none"` (önerilen) veya
  `thinking_config: {"thinking_budget": 0}`. `reasoning_effort: "low"` Gemini'de
  thinking'i kapatmaz.
- **temperature + top_p**: Bedrock Claude bu ikisini **birlikte** kabul etmez
  (400 döner); Gemini eder. Aynı kodu her iki sağlayıcıya yönlendiriyorsan Claude
  için yalnız birini gönder.
- **Prompt caching**: Bedrock Claude'da uzun, sabit bir system bloğunu
  `cache_control: {"type": "ephemeral"}` ile işaretle — sonraki çağrılarda o
  bölüm büyük ölçüde ucuzlar (Sonnet için ~1024 token alt sınır). Vertex Gemini
  implicit cache uygular, parametre gerekmez.
- **Maliyet kırılımı**: `metadata: {"tags": [...]}` ve `user: "..."` alanları
  spend log'a düşer; `scripts/cost-report.sh` ile proje/feature bazında raporlanır.
