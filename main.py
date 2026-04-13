import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from fastapi import FastAPI, Request, Query, Response
from config import get_settings
from services import database as db
from services.whatsapp import extract_message, send_text_message, mark_as_read
from services.claude import get_sofia_response, get_sofia_response_after_tools
from services.notifications import notify_santiago_handoff, notify_santiago_appointment

# ── Logging ────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger("sofia.main")


# ── App ────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Sofía v1 iniciando...")
    # Verificar conexión a Supabase
    try:
        faqs = db.get_all_faqs()
        logger.info(f"Conectado a Supabase. {len(faqs)} FAQs cargados.")
    except Exception as e:
        logger.error(f"Error conectando a Supabase: {e}")
    yield
    logger.info("Sofía v1 apagándose...")


app = FastAPI(
    title="Sofía v1 — Magnus WhatsApp Agent",
    version="1.0.0",
    lifespan=lifespan,
)


# ── Health Check ───────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "agent": "sofia", "version": "1.0.0"}


# ── Webhook Verification (GET) ─────────────────────────────

@app.get("/webhook")
async def verify_webhook(
    hub_mode: str = Query(None, alias="hub.mode"),
    hub_challenge: str = Query(None, alias="hub.challenge"),
    hub_verify_token: str = Query(None, alias="hub.verify_token"),
):
    """Meta envía un GET para verificar el webhook al configurarlo."""
    s = get_settings()
    if hub_mode == "subscribe" and hub_verify_token == s.wa_verify_token:
        logger.info("Webhook verificado exitosamente")
        return Response(content=hub_challenge, media_type="text/plain")
    logger.warning(f"Verificación fallida: token={hub_verify_token}")
    return Response(status_code=403)


# ── Webhook Receiver (POST) ────────────────────────────────

@app.post("/webhook")
async def receive_webhook(request: Request):
    """Recibe mensajes de WhatsApp y responde con Sofía."""
    payload = await request.json()

    # Extraer mensaje
    message = extract_message(payload)
    if not message:
        # Status update, delivery receipt, etc. — ignorar
        return {"status": "ignored"}

    phone = message["from"]
    body = message["body"]
    wa_message_id = message["wa_message_id"]

    logger.info(f"Mensaje de {phone}: {body[:100]}")

    # Marcar como leído inmediatamente
    await mark_as_read(wa_message_id)

    try:
        # 1. Obtener o crear lead
        lead = db.get_or_create_lead(phone)
        lead_id = lead["id"]

        # 2. Obtener o crear conversación
        conversation = db.get_active_conversation(lead_id)
        if not conversation:
            conversation = db.create_conversation(lead_id)
        conv_id = conversation["id"]

        # 3. Si la conversación está en handoff, ignorar (Santiago responde directo)
        if conversation.get("status") == "handoff":
            logger.info(f"Conversación en handoff, ignorando mensaje de {phone}")
            return {"status": "handoff"}

        # 4. Guardar mensaje inbound
        db.save_message(
            conversation_id=conv_id,
            lead_id=lead_id,
            direction="inbound",
            sender="lead",
            body=body,
            wa_message_id=wa_message_id,
            wa_timestamp=message.get("timestamp"),
        )

        # 5. Obtener respuesta de Sofía
        sofia_response = await get_sofia_response(lead, conv_id)

        # 6. Procesar tool calls si hay
        if sofia_response["tool_calls"] and sofia_response["stop_reason"] == "tool_use":
            tool_results = await process_tool_calls(
                sofia_response["tool_calls"], lead, conv_id
            )
            # Recargar lead con datos actualizados
            lead = db.get_or_create_lead(phone)
            # Obtener respuesta final después de tools
            sofia_response = await get_sofia_response_after_tools(
                lead, conv_id, tool_results
            )

        response_text = sofia_response["text"]

        if not response_text:
            logger.warning(f"Sofía no generó respuesta para {phone}")
            return {"status": "no_response"}

        # 7. Enviar respuesta por WhatsApp
        result = await send_text_message(phone, response_text)

        # 8. Guardar mensaje outbound
        db.save_message(
            conversation_id=conv_id,
            lead_id=lead_id,
            direction="outbound",
            sender="sofia",
            body=response_text,
            wa_message_id=result.get("wa_message_id"),
            claude_model=sofia_response.get("model"),
            tokens_in=sofia_response.get("tokens_in"),
            tokens_out=sofia_response.get("tokens_out"),
            latency_ms=sofia_response.get("latency_ms"),
        )

        # 9. Actualizar estado de conversación
        db.update_conversation(conv_id, {"status": "waiting_reply"})

        logger.info(
            f"Respuesta enviada a {phone} "
            f"({sofia_response.get('tokens_in', 0)}+{sofia_response.get('tokens_out', 0)} tokens, "
            f"{sofia_response.get('latency_ms', 0)}ms)"
        )

        return {"status": "ok"}

    except Exception as e:
        logger.error(f"Error procesando mensaje de {phone}: {e}", exc_info=True)
        # Enviar mensaje de fallback
        await send_text_message(
            phone,
            "Disculpe, tuve un pequeño problema técnico. "
            "¿Podría repetir su mensaje? Si prefiere, puedo "
            "conectarlo directamente con Santiago de Magnus.",
        )
        return {"status": "error", "detail": str(e)}


# ── Tool Processing ────────────────────────────────────────

async def process_tool_calls(
    tool_calls: list[dict], lead: dict, conv_id: str
) -> list[dict]:
    """Procesa los tool calls de Claude y retorna resultados."""
    results = []
    lead_id = lead["id"]

    for tc in tool_calls:
        name = tc["name"]
        input_data = tc["input"]

        if name == "update_lead":
            # Mapear campos y actualizar
            update_data = {}
            field_map = {
                "first_name": "first_name",
                "last_name": "last_name",
                "age": "age",
                "is_homeowner": "is_homeowner",
                "comuna": "comuna",
                "property_type": "property_type",
                "estimated_uf": "estimated_uf",
                "pension_monthly": "pension_monthly",
                "referral_name": "referral_name",
            }
            for key, db_field in field_map.items():
                if key in input_data:
                    update_data[db_field] = input_data[key]

            # Calcular qualification score
            score = calculate_qualification_score({**lead, **update_data})
            update_data["qualification_score"] = score

            # Determinar status
            age = update_data.get("age", lead.get("age"))
            is_owner = update_data.get("is_homeowner", lead.get("is_homeowner"))
            comuna = update_data.get("comuna", lead.get("comuna"))

            if age and is_owner is not None and comuna:
                if age >= 65 and is_owner and comuna != "otra":
                    update_data["status"] = "qualified"
                else:
                    update_data["status"] = "unqualified"
            else:
                update_data["status"] = "qualifying"

            db.update_lead(lead_id, update_data)
            results.append({
                "name": "update_lead",
                "input": input_data,
                "result": f"Lead actualizado. Score: {score}/100. Status: {update_data.get('status', 'qualifying')}.",
            })
            logger.info(f"Lead {lead_id} actualizado: score={score}")

        elif name == "schedule_appointment":
            date_str = input_data.get("date", "")
            time_str = input_data.get("time", "")
            meeting_type = input_data.get("meeting_type", "video")
            notes = input_data.get("notes", "")
            lead_questions = input_data.get("lead_questions", [])

            # Crear la cita
            try:
                scheduled_at = f"{date_str}T{time_str}:00-04:00"  # Chile timezone
                db.create_appointment(
                    lead_id=lead_id,
                    conversation_id=conv_id,
                    scheduled_at=scheduled_at,
                    meeting_type=meeting_type,
                    notes=notes,
                    lead_questions=lead_questions,
                )
                # Notificar a Santiago
                await notify_santiago_appointment(
                    lead, date_str, time_str, meeting_type, notes
                )
                results.append({
                    "name": "schedule_appointment",
                    "input": input_data,
                    "result": f"Reunión agendada para {date_str} a las {time_str}. Santiago fue notificado.",
                })
            except Exception as e:
                logger.error(f"Error agendando cita: {e}")
                results.append({
                    "name": "schedule_appointment",
                    "input": input_data,
                    "result": f"Error agendando la reunión: {str(e)}. Pide disculpas y ofrece intentar otro horario.",
                })

        elif name == "handoff":
            reason = input_data.get("reason", "")
            summary = input_data.get("summary", "")

            # Actualizar conversación a handoff
            db.update_conversation(conv_id, {
                "status": "handoff",
                "handoff_reason": reason,
                "handoff_at": datetime.now(timezone.utc).isoformat(),
                "summary": summary,
            })
            # Notificar a Santiago
            await notify_santiago_handoff(lead, reason, summary)
            results.append({
                "name": "handoff",
                "input": input_data,
                "result": "Conversación transferida a Santiago. Él se comunicará pronto.",
            })
            logger.info(f"Handoff para lead {lead_id}: {reason}")

    return results


def calculate_qualification_score(lead: dict) -> int:
    """Calcula un score de 0-100 basado en los datos del lead."""
    score = 0

    # Edad (máx 30 pts)
    age = lead.get("age")
    if age:
        if age >= 65:
            score += 30
        elif age >= 60:
            score += 15

    # Propietario (25 pts)
    if lead.get("is_homeowner"):
        score += 25

    # Comuna del sector oriente (25 pts)
    target_comunas = {
        "providencia", "las_condes", "vitacura",
        "la_reina", "nunoa", "lo_barnechea",
    }
    if lead.get("comuna") in target_comunas:
        score += 25

    # Tiene valor estimado (10 pts)
    if lead.get("estimated_uf"):
        score += 10

    # Tiene nombre (5 pts)
    if lead.get("first_name"):
        score += 5

    # Tiene info de pensión (5 pts)
    if lead.get("pension_monthly"):
        score += 5

    return min(score, 100)


# ── Run ────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
