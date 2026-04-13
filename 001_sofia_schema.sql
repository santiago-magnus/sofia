-- ============================================================
-- SOFÍA v1 — Supabase Schema Migration
-- Magnus Chile SpA — WhatsApp AI Agent
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- ENUM TYPES
-- ============================================================

CREATE TYPE lead_status AS ENUM (
  'new',              -- Acaba de escribir
  'qualifying',       -- Sofía está calificando
  'qualified',        -- Cumple criterios (65+, propietario, sector oriente)
  'unqualified',      -- No cumple criterios
  'appointment_set',  -- Reunión agendada
  'contacted',        -- Santiago ya habló con el lead
  'proposal_sent',    -- Oferta enviada
  'won',              -- Firmó contrato
  'lost'              -- Descartado
);

CREATE TYPE conversation_status AS ENUM (
  'active',           -- Sofía respondiendo
  'waiting_reply',    -- Esperando respuesta del lead
  'handoff',          -- Transferido a Santiago
  'closed'            -- Conversación cerrada
);

CREATE TYPE message_direction AS ENUM (
  'inbound',          -- Lead → Magnus
  'outbound'          -- Magnus → Lead (Sofía o Santiago)
);

CREATE TYPE message_sender AS ENUM (
  'lead',             -- El lead escribió
  'sofia',            -- Sofía (AI) respondió
  'human'             -- Santiago u otro humano respondió
);

CREATE TYPE appointment_status AS ENUM (
  'scheduled',        -- Agendada
  'confirmed',        -- Lead confirmó
  'completed',        -- Se realizó
  'no_show',          -- Lead no apareció
  'cancelled',        -- Cancelada
  'rescheduled'       -- Reagendada
);

CREATE TYPE comuna_sector AS ENUM (
  'providencia',
  'las_condes',
  'vitacura',
  'la_reina',
  'nunoa',
  'lo_barnechea',
  'otra'              -- Fuera del sector objetivo
);

-- ============================================================
-- TABLE: leads
-- Información del lead/prospecto
-- ============================================================

CREATE TABLE leads (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  
  -- Identificación
  phone           TEXT NOT NULL UNIQUE,        -- +569XXXXXXXX
  first_name      TEXT,
  last_name       TEXT,
  
  -- Calificación Magnus
  status          lead_status NOT NULL DEFAULT 'new',
  age             INTEGER,                     -- Edad estimada o declarada
  is_homeowner    BOOLEAN,                     -- ¿Es propietario?
  comuna          comuna_sector,               -- Comuna de la propiedad
  property_type   TEXT,                        -- casa, depto, etc.
  estimated_uf    NUMERIC(10,2),              -- Valor estimado en UF
  pension_monthly NUMERIC(10,0),              -- Pensión mensual en CLP (aprox)
  
  -- Scoring
  qualification_score  INTEGER DEFAULT 0,      -- 0-100, calculado por Sofía
  qualification_notes  TEXT,                   -- Notas de calificación
  
  -- Referencia
  source          TEXT DEFAULT 'whatsapp',     -- Canal de origen
  referral_name   TEXT,                        -- Quién lo refirió
  
  -- Metadata
  tags            TEXT[] DEFAULT '{}',
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABLE: conversations
-- Sesiones de conversación WhatsApp
-- ============================================================

CREATE TABLE conversations (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  lead_id         UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  
  -- Estado
  status          conversation_status NOT NULL DEFAULT 'active',
  
  -- Contexto para Claude
  summary         TEXT,                        -- Resumen acumulado de la conversación
  current_topic   TEXT,                        -- Tema actual (faq, qualification, appointment)
  
  -- Control de handoff
  handoff_reason  TEXT,                        -- Por qué se transfirió a humano
  handoff_at      TIMESTAMPTZ,
  
  -- WhatsApp metadata
  wa_thread_id    TEXT,                        -- ID del thread en WhatsApp (si aplica)
  
  -- Timestamps
  last_message_at TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABLE: messages
-- Mensajes individuales (inbound y outbound)
-- ============================================================

CREATE TABLE messages (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  lead_id         UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  
  -- Contenido
  direction       message_direction NOT NULL,
  sender          message_sender NOT NULL,
  body            TEXT NOT NULL,               -- Texto del mensaje
  media_url       TEXT,                        -- URL de imagen/audio/doc si hay
  media_type      TEXT,                        -- image, audio, video, document
  
  -- WhatsApp metadata
  wa_message_id   TEXT UNIQUE,                 -- ID del mensaje en WhatsApp
  wa_timestamp    TIMESTAMPTZ,                 -- Timestamp de WhatsApp
  wa_status       TEXT,                        -- sent, delivered, read, failed
  
  -- AI metadata (solo para mensajes outbound de Sofía)
  claude_model    TEXT,                        -- claude-sonnet-4-20250514
  tokens_in       INTEGER,
  tokens_out      INTEGER,
  latency_ms      INTEGER,                    -- Tiempo de respuesta de Claude
  
  -- Timestamps
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABLE: appointments
-- Reuniones agendadas
-- ============================================================

CREATE TABLE appointments (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  lead_id         UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  conversation_id UUID REFERENCES conversations(id),
  
  -- Detalles
  status          appointment_status NOT NULL DEFAULT 'scheduled',
  scheduled_at    TIMESTAMPTZ NOT NULL,        -- Fecha y hora de la reunión
  duration_min    INTEGER DEFAULT 30,          -- Duración en minutos
  meeting_type    TEXT DEFAULT 'video',        -- video, phone, in_person
  location        TEXT,                        -- Link Zoom/Meet o dirección
  
  -- Notas
  notes           TEXT,                        -- Contexto de Sofía para Santiago
  lead_questions  TEXT[],                      -- Preguntas que el lead mencionó
  
  -- Confirmación
  confirmed_at    TIMESTAMPTZ,
  reminder_sent   BOOLEAN DEFAULT FALSE,
  
  -- Timestamps
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABLE: faq_entries
-- Base de conocimiento para Sofía
-- ============================================================

CREATE TABLE faq_entries (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  
  -- Contenido
  question        TEXT NOT NULL,               -- Pregunta frecuente
  answer          TEXT NOT NULL,               -- Respuesta aprobada
  category        TEXT NOT NULL,               -- pension, proceso, legal, costos, general
  keywords        TEXT[] DEFAULT '{}',         -- Palabras clave para matching
  
  -- Control
  is_active       BOOLEAN DEFAULT TRUE,
  priority        INTEGER DEFAULT 0,           -- Mayor = más relevante
  
  -- Timestamps
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- INDEXES
-- ============================================================

-- Leads
CREATE INDEX idx_leads_phone ON leads(phone);
CREATE INDEX idx_leads_status ON leads(status);
CREATE INDEX idx_leads_comuna ON leads(comuna);
CREATE INDEX idx_leads_created ON leads(created_at DESC);
CREATE INDEX idx_leads_score ON leads(qualification_score DESC);

-- Conversations
CREATE INDEX idx_conversations_lead ON conversations(lead_id);
CREATE INDEX idx_conversations_status ON conversations(status);
CREATE INDEX idx_conversations_last_msg ON conversations(last_message_at DESC);

-- Messages
CREATE INDEX idx_messages_conversation ON messages(conversation_id);
CREATE INDEX idx_messages_lead ON messages(lead_id);
CREATE INDEX idx_messages_wa_id ON messages(wa_message_id);
CREATE INDEX idx_messages_created ON messages(created_at DESC);

-- Appointments
CREATE INDEX idx_appointments_lead ON appointments(lead_id);
CREATE INDEX idx_appointments_scheduled ON appointments(scheduled_at);
CREATE INDEX idx_appointments_status ON appointments(status);

-- FAQ
CREATE INDEX idx_faq_category ON faq_entries(category);
CREATE INDEX idx_faq_keywords ON faq_entries USING GIN(keywords);

-- ============================================================
-- UPDATED_AT TRIGGER
-- ============================================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_leads_updated
  BEFORE UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER tr_conversations_updated
  BEFORE UPDATE ON conversations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER tr_appointments_updated
  BEFORE UPDATE ON appointments
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER tr_faq_updated
  BEFORE UPDATE ON faq_entries
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================

-- Habilitar RLS en todas las tablas
ALTER TABLE leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE faq_entries ENABLE ROW LEVEL SECURITY;

-- Policy: service_role tiene acceso total (usado por el backend FastAPI)
-- Supabase service_role bypasses RLS automáticamente, pero
-- definimos policies para anon/authenticated por si usas el dashboard

CREATE POLICY "Authenticated users can read leads"
  ON leads FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can manage leads"
  ON leads FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated users can read conversations"
  ON conversations FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can manage conversations"
  ON conversations FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated users can read messages"
  ON messages FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can manage messages"
  ON messages FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Authenticated users can read appointments"
  ON appointments FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can manage appointments"
  ON appointments FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Anyone can read active FAQs"
  ON faq_entries FOR SELECT
  USING (is_active = true);

CREATE POLICY "Authenticated users can manage FAQs"
  ON faq_entries FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- ============================================================
-- SEED: FAQs iniciales de Magnus
-- ============================================================

INSERT INTO faq_entries (question, answer, category, keywords, priority) VALUES

-- PROCESO
('¿Cómo funciona el modelo de Magnus?',
 'Magnus le compra su propiedad a un precio justo de mercado, y usted sigue viviendo en ella pagando un arriendo mensual muy accesible. Recibe el dinero de la venta de inmediato para complementar su pensión, mejorar su calidad de vida, o lo que usted necesite. Es una compraventa tradicional con un contrato de arriendo, simple y transparente.',
 'proceso', ARRAY['funciona', 'modelo', 'cómo', 'qué hacen', 'servicio'], 10),

('¿Tengo que irme de mi casa?',
 'No, para nada. Esa es justamente la gracia. Usted vende su propiedad pero sigue viviendo en ella con un contrato de arriendo a largo plazo. Su vida cotidiana no cambia en absoluto.',
 'proceso', ARRAY['irme', 'salir', 'mudarme', 'quedarme', 'casa'], 9),

('¿Cuánto demora el proceso?',
 'El proceso completo toma entre 4 y 8 semanas desde la primera reunión hasta que recibe el pago. Incluye la tasación de su propiedad, la revisión legal, y la firma ante notario.',
 'proceso', ARRAY['demora', 'tiempo', 'cuánto tarda', 'plazo', 'semanas'], 8),

('¿Qué pasa si me arrepiento?',
 'Antes de firmar, usted puede desistir sin ningún costo ni compromiso. Nos tomamos todo el tiempo necesario para que esté completamente seguro. También puede consultar con su familia o abogado de confianza antes de tomar la decisión.',
 'proceso', ARRAY['arrepiento', 'desistir', 'cancelar', 'no quiero'], 7),

-- FINANCIERO
('¿Cuánto me pagan por mi propiedad?',
 'Le pagamos el valor justo de mercado, determinado por una tasación profesional independiente. El precio se expresa en UF para protegerlo de la inflación. En una primera conversación podemos darle un rango estimado según su comuna y tipo de propiedad.',
 'financiero', ARRAY['cuánto', 'pagan', 'precio', 'valor', 'plata', 'dinero'], 10),

('¿Cuánto es el arriendo mensual?',
 'El arriendo es significativamente menor que lo que costaría arrendar una propiedad similar en el mercado. Se calcula en UF y se mantiene estable. El monto exacto depende del valor de su propiedad y se define durante el proceso de evaluación.',
 'financiero', ARRAY['arriendo', 'mensual', 'pago', 'cuánto cobran', 'renta'], 9),

('¿Tengo que pagar impuestos por la venta?',
 'En la mayoría de los casos, la venta de su vivienda habitual está exenta del impuesto a la renta según el Artículo 17 N°8 de la Ley de Impuesto a la Renta. De todas formas, revisamos cada caso particular con nuestro equipo legal para asegurarle la mejor estructura tributaria.',
 'financiero', ARRAY['impuestos', 'SII', 'tributario', 'renta', 'pagar impuesto'], 8),

-- LEGAL / SEGURIDAD
('¿Es legal y seguro?',
 'Completamente. Es una compraventa tradicional ante notario, inscrita en el Conservador de Bienes Raíces, igual que cualquier transacción inmobiliaria en Chile. Magnus opera a través de un Fondo de Inversión Privado regulado por la CMF (Comisión para el Mercado Financiero), la misma entidad que supervisa los bancos.',
 'legal', ARRAY['legal', 'seguro', 'confiable', 'estafa', 'regulado', 'CMF'], 10),

('¿Qué pasa si Magnus quiebra?',
 'Su contrato de arriendo está protegido legalmente y es independiente de la situación financiera de Magnus. Además, el fondo que compra las propiedades está regulado por la CMF con supervisión independiente. Su derecho a vivir en su hogar está garantizado por contrato.',
 'legal', ARRAY['quiebra', 'pasa si', 'riesgo', 'garantía', 'protección'], 9),

-- REQUISITOS
('¿Cuáles son los requisitos?',
 'Los requisitos principales son: ser propietario de una vivienda en el sector oriente de Santiago (Providencia, Las Condes, Vitacura, La Reina, Ñuñoa o Lo Barnechea), tener 65 años o más, y que la propiedad esté libre de hipotecas significativas. En nuestra primera conversación evaluamos si su caso califica.',
 'requisitos', ARRAY['requisitos', 'requisito', 'necesito', 'califico', 'puedo', 'condiciones'], 10),

('¿Puedo hacerlo si tengo hipoteca?',
 'Depende del monto pendiente. Si la hipoteca es pequeña respecto al valor de la propiedad, podemos pagarla como parte de la transacción y usted recibe la diferencia. Lo evaluamos caso a caso.',
 'requisitos', ARRAY['hipoteca', 'deuda', 'crédito', 'banco', 'dividendo'], 8),

-- PENSIONES
('¿Esto tiene que ver con la reforma de pensiones?',
 'No directamente, pero sí complementa su pensión. Muchas personas mayores en Chile tienen pensiones que no alcanzan para vivir con dignidad, pero son dueñas de propiedades valiosas. Magnus le permite convertir ese patrimonio inmobiliario en liquidez sin perder su hogar. Es una alternativa real e inmediata, independiente de los tiempos de la reforma.',
 'pension', ARRAY['pensión', 'reforma', 'AFP', 'jubilación', 'retiro'], 9),

-- GENERAL
('¿Puedo hablar con alguien de Magnus?',
 'Por supuesto. Puedo agendar una reunión con Santiago, nuestro fundador, para que converse directamente con usted y resuelva todas sus dudas. ¿Le acomoda una videollamada o prefiere una llamada telefónica?',
 'general', ARRAY['hablar', 'persona', 'reunión', 'contacto', 'llamar', 'alguien'], 10);

-- ============================================================
-- VIEWS útiles
-- ============================================================

-- Vista: leads calificados pendientes de contacto
CREATE VIEW v_qualified_leads AS
SELECT 
  l.id,
  l.first_name,
  l.last_name,
  l.phone,
  l.status,
  l.comuna,
  l.qualification_score,
  l.estimated_uf,
  l.created_at,
  c.last_message_at,
  a.scheduled_at as next_appointment
FROM leads l
LEFT JOIN conversations c ON c.lead_id = l.id 
  AND c.status != 'closed'
LEFT JOIN appointments a ON a.lead_id = l.id 
  AND a.status IN ('scheduled', 'confirmed')
  AND a.scheduled_at > NOW()
WHERE l.status IN ('qualified', 'appointment_set')
ORDER BY l.qualification_score DESC;

-- Vista: métricas diarias de Sofía
CREATE VIEW v_sofia_daily_metrics AS
SELECT 
  DATE(m.created_at) as date,
  COUNT(*) FILTER (WHERE m.direction = 'inbound') as messages_in,
  COUNT(*) FILTER (WHERE m.direction = 'outbound' AND m.sender = 'sofia') as messages_out,
  COUNT(DISTINCT m.lead_id) as unique_leads,
  AVG(m.latency_ms) FILTER (WHERE m.sender = 'sofia') as avg_latency_ms,
  SUM(m.tokens_in + COALESCE(m.tokens_out, 0)) FILTER (WHERE m.sender = 'sofia') as total_tokens
FROM messages m
WHERE m.created_at > NOW() - INTERVAL '30 days'
GROUP BY DATE(m.created_at)
ORDER BY date DESC;
