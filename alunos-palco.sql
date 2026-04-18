-- PALCO — Tabela de alunos autorizados
-- Rodar no Supabase projeto ctvdlamxicoxniyqcpfd → SQL Editor

BEGIN;

CREATE TABLE IF NOT EXISTS public.alunos_palco (
  id          uuid    DEFAULT gen_random_uuid() PRIMARY KEY,
  email       text    NOT NULL UNIQUE,
  nome        text,
  ativo       boolean NOT NULL DEFAULT true,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);

-- Trigger atualizado_em (reutiliza função já criada pelo Sprint 2, ou cria se não existir)
CREATE OR REPLACE FUNCTION public.set_atualizado_em_alunos()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.atualizado_em = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS alunos_palco_atualizado_em ON public.alunos_palco;
CREATE TRIGGER alunos_palco_atualizado_em
  BEFORE UPDATE ON public.alunos_palco
  FOR EACH ROW EXECUTE FUNCTION public.set_atualizado_em_alunos();

-- RLS
ALTER TABLE public.alunos_palco ENABLE ROW LEVEL SECURITY;

-- Usuário autenticado pode ver apenas o próprio registro (por email)
CREATE POLICY "aluno ve proprio registro"
  ON public.alunos_palco FOR SELECT
  TO authenticated
  USING (email = auth.email());

-- service_role tem acesso total (Edilson gerencia via dashboard)
-- service_role bypassa RLS automaticamente — nenhuma policy extra necessária

COMMIT;

-- SMOKE TEST (rodar separado após o BEGIN/COMMIT acima)
-- INSERT INTO public.alunos_palco (email, nome) VALUES ('teste@palco.com', 'Teste');
-- SELECT * FROM public.alunos_palco WHERE email = 'teste@palco.com';
-- DELETE FROM public.alunos_palco WHERE email = 'teste@palco.com';
