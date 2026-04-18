-- ============================================================================
-- PALCO — Sprint 2: Memória por usuário
-- ============================================================================
-- Projeto Supabase: ctvdlamxicoxniyqcpfd (gestor-trafego) — REUTILIZADO
-- Data: 2026-04-18
-- Autor: DB Sage
--
-- IMPORTANTE:
--   Este script NÃO mexe em nenhuma tabela existente do gestor-trafego.
--   Todos os objetos criados usam o prefixo `palco_*` / `usuarios_palco`
--   para isolamento lógico. Pode ser rodado via SQL editor do Supabase
--   em uma única transação.
--
-- DECISÃO DE MODELAGEM (KISS):
--   - Tabela única `usuarios_palco` concentra: ficha + sessão atual +
--     calibração. É a fonte da verdade do agente no n8n.
--   - Tabela `palco_sessoes_historico` é append-only, separada, para
--     não inchar a row principal com JSONB crescente (histórico já
--     planejado no briefing como "opcional mas útil").
--   - Identidade = numero_whatsapp (PK natural, único, estável no UazAPI).
--   - Ficha e calibração como JSONB: campos ainda estão sendo validados
--     no T3, evita migrations quando a estrutura do prompt mestre mudar.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. TABELA PRINCIPAL — usuarios_palco
-- ----------------------------------------------------------------------------
-- Uma linha por músico (identificado pelo número WhatsApp).
-- Concentra tudo que o workflow n8n precisa em UM SELECT.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.usuarios_palco (
  -- Identificação
  numero_whatsapp       TEXT        PRIMARY KEY,  -- ex: "5562981221474"
  nome                  TEXT,                     -- opcional, capturado pós-P1

  -- Estado do onboarding
  -- status_onboarding: 'em_andamento' | 'concluido'
  -- pergunta_atual:    'P1' | 'P2' | 'P3' | NULL (quando concluido)
  status_onboarding     TEXT        NOT NULL DEFAULT 'em_andamento'
                                    CHECK (status_onboarding IN ('em_andamento','concluido')),
  pergunta_atual        TEXT        CHECK (pergunta_atual IN ('P1','P2','P3') OR pergunta_atual IS NULL),

  -- Ficha de identidade (resultado do onboarding)
  -- Estrutura esperada (mas flexível — JSONB):
  -- {
  --   "ativo_principal": "...",
  --   "publico": "...",
  --   "emocao_alvo": "...",
  --   "vocabulario":  ["palavra1","palavra2",...],
  --   "nao_falar":    ["tema1","tema2",...]
  -- }
  ficha                 JSONB       NOT NULL DEFAULT '{}'::jsonb,

  -- Sessão semanal atual (estado da conversa em andamento)
  -- Estrutura esperada:
  -- {
  --   "ativa": true,
  --   "fase": "aguardando_evento" | "aguardando_calibracao" | "gerando" | "revisao",
  --   "evento_semana": "texto do músico",
  --   "pacote_gerado": {
  --     "feed":"...", "reels":"...", "stories":["f1","f2","f3"],
  --     "gancho":"...", "cta":"..."
  --   },
  --   "iniciada_em": "2026-04-18T12:00:00Z"
  -- }
  sessao_atual          JSONB       NOT NULL DEFAULT '{"ativa":false}'::jsonb,

  -- Calibração acumulada (aprendizado ao longo das semanas)
  -- Estrutura esperada:
  -- {
  --   "semanas": [
  --     {"semana":1, "performou":"reels", "observacao":"...", "data":"..."}
  --   ],
  --   "ajustes_tom":    ["menos emoji","tom mais direto"],
  --   "padrao_identificado": "audiência engaja mais em reels curtos"
  -- }
  calibracao            JSONB       NOT NULL DEFAULT '{"semanas":[],"ajustes_tom":[]}'::jsonb,

  -- Auditoria
  criado_em             TIMESTAMPTZ NOT NULL DEFAULT now(),
  atualizado_em         TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.usuarios_palco IS
  'Estado por usuário do agente PALCO (identidade + sessão atual + calibração).';
COMMENT ON COLUMN public.usuarios_palco.numero_whatsapp IS
  'Número no formato internacional sem + nem espaços. Ex: 5562981221474.';
COMMENT ON COLUMN public.usuarios_palco.ficha IS
  'JSONB — 5 campos do DNA artístico (ativo_principal, publico, emocao_alvo, vocabulario, nao_falar).';
COMMENT ON COLUMN public.usuarios_palco.sessao_atual IS
  'JSONB — estado volátil da conversa semanal em andamento.';
COMMENT ON COLUMN public.usuarios_palco.calibracao IS
  'JSONB — aprendizado acumulado de semana em semana.';

-- Índice para filtrar onboardings em andamento (ajuda ops/monitoria)
CREATE INDEX IF NOT EXISTS idx_usuarios_palco_status_onboarding
  ON public.usuarios_palco (status_onboarding)
  WHERE status_onboarding = 'em_andamento';

-- Trigger para manter atualizado_em sincronizado
CREATE OR REPLACE FUNCTION public.palco_set_atualizado_em()
RETURNS TRIGGER AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_usuarios_palco_atualizado_em ON public.usuarios_palco;
CREATE TRIGGER trg_usuarios_palco_atualizado_em
  BEFORE UPDATE ON public.usuarios_palco
  FOR EACH ROW
  EXECUTE FUNCTION public.palco_set_atualizado_em();

-- ----------------------------------------------------------------------------
-- 2. TABELA DE HISTÓRICO — palco_sessoes_historico
-- ----------------------------------------------------------------------------
-- Append-only. Uma linha por sessão semanal concluída (aprovada ou não).
-- Usado para aprendizado futuro, auditoria, e análise de performance.
-- NÃO é read-path crítico do agente — o agente consulta `usuarios_palco`.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.palco_sessoes_historico (
  id                    BIGSERIAL   PRIMARY KEY,
  numero_whatsapp       TEXT        NOT NULL
                                    REFERENCES public.usuarios_palco(numero_whatsapp)
                                    ON DELETE CASCADE,
  evento_semana         TEXT,                          -- input do músico
  pacote_gerado         JSONB       NOT NULL,          -- feed/reels/stories/gancho/cta
  ajuste_solicitado     TEXT,                          -- se pediu refino
  aprovado              BOOLEAN     NOT NULL DEFAULT false,
  criado_em             TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.palco_sessoes_historico IS
  'Arquivo append-only de sessões semanais concluídas. Alimenta aprendizado.';

CREATE INDEX IF NOT EXISTS idx_palco_historico_numero
  ON public.palco_sessoes_historico (numero_whatsapp, criado_em DESC);

-- ----------------------------------------------------------------------------
-- 3. RLS — Row Level Security
-- ----------------------------------------------------------------------------
-- Política KISS:
--   - service_role (usada pelo n8n via service_role key) tem ACESSO TOTAL.
--   - anon / authenticated têm ZERO acesso (nenhuma policy = bloqueio total
--     uma vez que RLS está habilitado).
--   - service_role by design bypassa RLS no Postgres do Supabase, mas
--     habilitar RLS protege contra vazamento acidental via anon key.
-- ----------------------------------------------------------------------------

ALTER TABLE public.usuarios_palco            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.palco_sessoes_historico   ENABLE ROW LEVEL SECURITY;

-- Blindagem explícita: revogar qualquer grant default para anon/authenticated
REVOKE ALL ON public.usuarios_palco          FROM anon, authenticated;
REVOKE ALL ON public.palco_sessoes_historico FROM anon, authenticated;

-- service_role já tem BYPASS RLS, não precisa de policy — mas garantimos grants:
GRANT ALL ON public.usuarios_palco          TO service_role;
GRANT ALL ON public.palco_sessoes_historico TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.palco_sessoes_historico_id_seq TO service_role;

-- Opcional: policy explícita (defense-in-depth) caso service_role perca bypass.
DROP POLICY IF EXISTS palco_service_role_all ON public.usuarios_palco;
CREATE POLICY palco_service_role_all
  ON public.usuarios_palco
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS palco_hist_service_role_all ON public.palco_sessoes_historico;
CREATE POLICY palco_hist_service_role_all
  ON public.palco_sessoes_historico
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

COMMIT;

-- ============================================================================
-- ROLLBACK (manual, se precisar desfazer)
-- ============================================================================
-- BEGIN;
--   DROP TABLE IF EXISTS public.palco_sessoes_historico;
--   DROP TABLE IF EXISTS public.usuarios_palco;
--   DROP FUNCTION IF EXISTS public.palco_set_atualizado_em();
-- COMMIT;
-- ============================================================================

-- ============================================================================
-- SMOKE TEST (rodar manualmente após deploy)
-- ============================================================================
-- -- 1. Tabelas existem?
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema = 'public'
--    AND table_name IN ('usuarios_palco','palco_sessoes_historico');
--
-- -- 2. RLS habilitado?
-- SELECT relname, relrowsecurity
--   FROM pg_class
--  WHERE relname IN ('usuarios_palco','palco_sessoes_historico');
--
-- -- 3. Insert teste (via service_role)
-- INSERT INTO public.usuarios_palco (numero_whatsapp, status_onboarding, pergunta_atual)
-- VALUES ('5562999999999','em_andamento','P1');
--
-- SELECT numero_whatsapp, status_onboarding, criado_em
--   FROM public.usuarios_palco
--  WHERE numero_whatsapp = '5562999999999';
--
-- -- 4. Limpar
-- DELETE FROM public.usuarios_palco WHERE numero_whatsapp = '5562999999999';
-- ============================================================================
