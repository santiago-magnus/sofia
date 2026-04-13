# Sofía v1 — Backend

WhatsApp AI Agent para Magnus Chile. FastAPI + Claude + Supabase.

## Estructura

```
sofia-backend/
├── main.py              # FastAPI app, webhook, message flow
├── config.py            # Environment variables (Pydantic)
├── services/
│   ├── database.py      # Supabase client (leads, conversations, messages)
│   ├── whatsapp.py      # Meta WhatsApp Cloud API client
│   ├── claude.py        # Claude AI (system prompt, tools, responses)
│   └── notifications.py # Alertas a Santiago (handoff, citas)
├── requirements.txt
├── Dockerfile
├── Procfile
└── .env.example
```

## Setup local

```bash
# Clonar e instalar
cd sofia-backend
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Configurar variables de entorno
cp .env.example .env
# Editar .env con tus valores reales

# Correr
python main.py
# → http://localhost:8000
# → http://localhost:8000/docs (Swagger UI)
```

## Deploy en Railway

1. Sube el código a un repo en GitHub
2. En [railway.app](https://railway.app), crea un nuevo proyecto desde GitHub
3. Railway detecta el Procfile automáticamente
4. Agrega las variables de entorno en Settings → Variables
5. Deploy automático. Copia la URL pública (ej: `https://sofia-xxx.up.railway.app`)

## Configurar Webhook en Meta

1. Ve a Meta for Developers → Tu App → WhatsApp → Configuration
2. En "Webhook", pon la URL: `https://TU_URL_RAILWAY/webhook`
3. Verify Token: `magnus_sofia_2026` (o el que pongas en WA_VERIFY_TOKEN)
4. Suscríbete a: `messages`

## Flujo de un mensaje

```
Lead escribe → Meta Webhook → POST /webhook
  → extract_message()
  → get_or_create_lead()
  → get_active_conversation()
  → save_message(inbound)
  → get_sofia_response(Claude)
    → [tool_calls? → process → get_sofia_response_after_tools()]
  → send_text_message(WhatsApp)
  → save_message(outbound)
```

## Variables de entorno

| Variable | Descripción |
|----------|-------------|
| `SUPABASE_URL` | URL de tu proyecto Supabase |
| `SUPABASE_SERVICE_KEY` | Service role key de Supabase |
| `WA_PHONE_NUMBER_ID` | Phone Number ID de WhatsApp Cloud API |
| `WA_ACCESS_TOKEN` | System User token permanente |
| `WA_VERIFY_TOKEN` | Token para verificar webhook (tú lo defines) |
| `ANTHROPIC_API_KEY` | API key de Anthropic |
| `SANTIAGO_PHONE` | Tu número para notificaciones (+569...) |
