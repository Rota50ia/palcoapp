# PALCO — Guia de Acesso Supabase (Sprint 2)

**Projeto:** `ctvdlamxicoxniyqcpfd` (reutilizado — gestor-trafego)
**Data:** 2026-04-18
**DDL:** `PALCO-SUPABASE-SPRINT2.sql` (rodar antes de usar este guia)

---

## 1. Decisão de Modelagem (TL;DR)

**2 tabelas — a mais simples que atende ao produto:**

| Tabela | Propósito | Volume esperado |
|---|---|---|
| `usuarios_palco` | Estado "vivo" por músico (ficha + sessão atual + calibração) | 10-30 linhas no lançamento |
| `palco_sessoes_historico` | Arquivo append-only de sessões concluídas | ~4 linhas/usuário/mês |

**Por que não tabela única?** Histórico em JSONB na mesma row cresce sem limite e força rewrite da row principal a cada sessão. Duas tabelas planas = grep/debug triviais.

**Por que não múltiplas tabelas para ficha/calibração/sessão?** Com 10-30 usuários e JSONB, joins não são necessários. Estrutura dos campos ainda está em calibração no T3 — JSONB evita migrations a cada ajuste de prompt.

**Identidade:** `numero_whatsapp` é PK natural (único, estável no UazAPI, é o que o webhook já entrega).

---

## 2. Setup Inicial

### 2.1 Rodar o DDL
1. Abrir Supabase → projeto `ctvdlamxicoxniyqcpfd` → SQL Editor
2. Colar conteúdo de `PALCO-SUPABASE-SPRINT2.sql`
3. Executar (tudo roda em `BEGIN/COMMIT` — atômico)
4. Rodar o bloco "SMOKE TEST" no final do SQL para validar

### 2.2 Credenciais para o n8n
No n8n, criar (ou reusar) credencial Supabase com:
- **URL:** `https://ctvdlamxicoxniyqcpfd.supabase.co`
- **Service Role Key:** (pegar no Dashboard → Settings → API → `service_role` secret)

**CRÍTICO:** usar `service_role`, NÃO `anon`. RLS está habilitado e anon tem zero acesso.

---

## 3. Padrão de Acesso — n8n (REST API)

Base URL para todas as chamadas:
```
https://ctvdlamxicoxniyqcpfd.supabase.co/rest/v1
```

Headers obrigatórios em todas as requests:
```
apikey: {{SUPABASE_SERVICE_ROLE_KEY}}
Authorization: Bearer {{SUPABASE_SERVICE_ROLE_KEY}}
Content-Type: application/json
```

### 3.1 Recuperar ficha pelo número (GET)

**Quando:** primeira coisa que o workflow faz ao receber msg do WhatsApp — decide o roteamento (sem ficha / com ficha / sessão ativa).

```
GET /rest/v1/usuarios_palco?numero_whatsapp=eq.5562981221474&select=*
```

**Resposta:**
- `[]` (array vazio) → usuário novo, iniciar onboarding (P1)
- `[{...}]` → tem registro, examinar `status_onboarding` e `sessao_atual.ativa`

Lógica de roteamento no n8n (node Function ou IF chain):
```javascript
const usuario = items[0]?.json;
if (!usuario)                                       return 'ONBOARDING_P1';
if (usuario.status_onboarding === 'em_andamento')   return 'ONBOARDING_' + usuario.pergunta_atual;
if (usuario.sessao_atual?.ativa)                    return 'CONTINUAR_SESSAO';
return 'INICIAR_SESSAO_SEMANAL';
```

### 3.2 Criar usuário novo (onboarding P1)

**Quando:** primeira msg de um número novo. Cria linha e marca P1.

```
POST /rest/v1/usuarios_palco
Prefer: return=representation
```
Body:
```json
{
  "numero_whatsapp": "5562981221474",
  "status_onboarding": "em_andamento",
  "pergunta_atual": "P1"
}
```

### 3.3 Upsert da ficha (onboarding — cada resposta)

**Quando:** músico respondeu P1 / P2 / P3. Atualiza campo correspondente dentro do JSONB e avança `pergunta_atual`.

Usamos **UPSERT idempotente** com `on_conflict` no PK:

```
POST /rest/v1/usuarios_palco?on_conflict=numero_whatsapp
Prefer: resolution=merge-duplicates,return=representation
```

Body (depois de P1 — ativo principal):
```json
{
  "numero_whatsapp": "5562981221474",
  "ficha": {"ativo_principal": "Método de violão para adultos iniciantes"},
  "pergunta_atual": "P2"
}
```

**PROBLEMA:** esse upsert substitui o JSONB inteiro e perde campos já preenchidos. Para merge parcial, usar o endpoint PATCH com expressão SQL via RPC, OU ler-alterar-escrever no n8n:

**Padrão recomendado (mais simples):** PATCH com JSONB merge usando operador `||` via RPC. Criar uma RPC no Supabase:

```sql
-- Rodar uma vez no SQL editor:
CREATE OR REPLACE FUNCTION public.palco_merge_ficha(
  p_numero TEXT,
  p_patch  JSONB,
  p_proxima_pergunta TEXT DEFAULT NULL
) RETURNS public.usuarios_palco
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r public.usuarios_palco;
BEGIN
  INSERT INTO public.usuarios_palco (numero_whatsapp, ficha, pergunta_atual)
  VALUES (p_numero, p_patch, p_proxima_pergunta)
  ON CONFLICT (numero_whatsapp) DO UPDATE
    SET ficha          = public.usuarios_palco.ficha || EXCLUDED.ficha,
        pergunta_atual = COALESCE(EXCLUDED.pergunta_atual, public.usuarios_palco.pergunta_atual)
  RETURNING * INTO r;
  RETURN r;
END;$$;

GRANT EXECUTE ON FUNCTION public.palco_merge_ficha(TEXT,JSONB,TEXT) TO service_role;
```

Chamar a RPC do n8n:
```
POST /rest/v1/rpc/palco_merge_ficha
```
Body:
```json
{
  "p_numero": "5562981221474",
  "p_patch":  {"ativo_principal": "Método de violão para adultos iniciantes"},
  "p_proxima_pergunta": "P2"
}
```

### 3.4 Concluir onboarding (após P3)

```
PATCH /rest/v1/usuarios_palco?numero_whatsapp=eq.5562981221474
```
Body:
```json
{
  "status_onboarding": "concluido",
  "pergunta_atual": null,
  "ficha": { "...ficha completa merged..." }
}
```
Alternativa: chamar `palco_merge_ficha` com `p_proxima_pergunta=null` e depois PATCH só do `status_onboarding`.

### 3.5 Iniciar sessão semanal

```
PATCH /rest/v1/usuarios_palco?numero_whatsapp=eq.5562981221474
```
Body:
```json
{
  "sessao_atual": {
    "ativa": true,
    "fase": "aguardando_evento",
    "iniciada_em": "2026-04-18T14:00:00Z"
  }
}
```

### 3.6 Atualizar fase da sessão / salvar pacote gerado

```
PATCH /rest/v1/usuarios_palco?numero_whatsapp=eq.5562981221474
```
Body:
```json
{
  "sessao_atual": {
    "ativa": true,
    "fase": "revisao",
    "evento_semana": "Aluna de 47 anos tocou a música favorita...",
    "pacote_gerado": {
      "feed":"...", "reels":"...",
      "stories":["f1","f2","f3"],
      "gancho":"...", "cta":"..."
    },
    "iniciada_em": "2026-04-18T14:00:00Z"
  }
}
```

**Obs:** PATCH substitui o JSONB inteiro. Como a `sessao_atual` é de vida curta (uma sessão semanal) e o workflow tem estado em memória durante a conversa, esse trade-off é aceitável. Se quiser merge, use outra RPC espelhando `palco_merge_ficha`.

### 3.7 Fechar sessão e arquivar no histórico

Duas chamadas em sequência:

**a) Inserir no histórico:**
```
POST /rest/v1/palco_sessoes_historico
Prefer: return=minimal
```
Body:
```json
{
  "numero_whatsapp": "5562981221474",
  "evento_semana": "Aluna de 47 anos tocou...",
  "pacote_gerado": { "...": "..." },
  "ajuste_solicitado": null,
  "aprovado": true
}
```

**b) Limpar sessão atual:**
```
PATCH /rest/v1/usuarios_palco?numero_whatsapp=eq.5562981221474
```
Body:
```json
{ "sessao_atual": {"ativa": false} }
```

### 3.8 Atualizar calibração (semana 2+)

Mesmo padrão da ficha — criar uma RPC de merge (espelho da 3.3):

```sql
CREATE OR REPLACE FUNCTION public.palco_append_calibracao(
  p_numero TEXT,
  p_semana JSONB           -- {"semana":2,"performou":"reels","observacao":"..."}
) RETURNS public.usuarios_palco
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r public.usuarios_palco;
BEGIN
  UPDATE public.usuarios_palco
     SET calibracao = jsonb_set(
           calibracao,
           '{semanas}',
           COALESCE(calibracao->'semanas','[]'::jsonb) || p_semana
         )
   WHERE numero_whatsapp = p_numero
   RETURNING * INTO r;
  RETURN r;
END;$$;

GRANT EXECUTE ON FUNCTION public.palco_append_calibracao(TEXT,JSONB) TO service_role;
```

Chamada:
```
POST /rest/v1/rpc/palco_append_calibracao
```
Body:
```json
{
  "p_numero": "5562981221474",
  "p_semana": {"semana":2,"performou":"reels","observacao":"ganchos curtos","data":"2026-04-25"}
}
```

---

## 4. Mapa de Chamadas por Fluxo

### Fluxo A — Onboarding (primeira conversa)
| Momento | Chamada |
|---|---|
| Msg 1 recebida, número novo | `GET /usuarios_palco?numero_whatsapp=eq.X` → vazio |
| Cria user + pergunta P1 | `POST /usuarios_palco` (body 3.2) |
| Resposta P1 chega | `POST /rpc/palco_merge_ficha` com `ativo_principal` + `p_proxima_pergunta=P2` |
| Resposta P2 chega | `POST /rpc/palco_merge_ficha` com `publico` + `p_proxima_pergunta=P3` |
| Resposta P3 chega | `POST /rpc/palco_merge_ficha` com `emocao_alvo` + `p_proxima_pergunta=null` |
| Fechar onboarding | `PATCH /usuarios_palco` `{status_onboarding:"concluido"}` |

### Fluxo B — Sessão semanal (semana 1)
| Momento | Chamada |
|---|---|
| Msg chega | `GET /usuarios_palco?numero_whatsapp=eq.X` |
| Confirma ficha pronta, sem sessão | `PATCH` iniciar sessão (3.5) |
| Músico manda evento | `PATCH` atualizar `sessao_atual.evento_semana` |
| Claude gera pacote | `PATCH` com `pacote_gerado` + `fase=revisao` (3.6) |
| Músico aprova | `POST /palco_sessoes_historico` + `PATCH` limpar sessão (3.7) |

### Fluxo C — Sessão semanal (semana 2+)
Igual B, com calibração antes do evento:
| Momento | Chamada adicional |
|---|---|
| Antes de pedir evento | perguntar o que performou; quando responder, `POST /rpc/palco_append_calibracao` |

---

## 5. Segurança (RLS)

| Role | Acesso | Como usar |
|---|---|---|
| `service_role` | TOTAL (bypassa RLS + policy explícita) | APENAS dentro do n8n (backend) |
| `anon` | ZERO (RLS on, sem policy) | Nunca expor para o frontend |
| `authenticated` | ZERO | Sprint 3+ se criarmos login |

**Regra dura:** `service_role` key NUNCA vai para navegador, apenas para o n8n (server-side). Se um dia houver painel web para o músico, criar um role separado com RLS por `numero_whatsapp = auth.jwt()->>'phone'` — fora do escopo do Sprint 2.

---

## 6. Checklist de Deploy

- [ ] Abrir `PALCO-SUPABASE-SPRINT2.sql` no SQL editor do projeto `ctvdlamxicoxniyqcpfd`
- [ ] Rodar em uma transação (já está envolvido em BEGIN/COMMIT)
- [ ] Rodar bloco "SMOKE TEST" do próprio SQL (último bloco do arquivo)
- [ ] Criar as 2 RPCs opcionais (`palco_merge_ficha`, `palco_append_calibracao`) — seção 3.3 e 3.8
- [ ] Confirmar `service_role key` no n8n (Settings → API do Supabase)
- [ ] Fazer um POST de teste criando um usuário fictício (`5562999999999`) e validar GET
- [ ] Deletar o usuário fictício
- [ ] Ligar o workflow Sprint 1 aos novos endpoints

---

## 7. Rollback

Se precisar desfazer (sem afetar gestor-trafego):
```sql
BEGIN;
  DROP FUNCTION IF EXISTS public.palco_append_calibracao(TEXT,JSONB);
  DROP FUNCTION IF EXISTS public.palco_merge_ficha(TEXT,JSONB,TEXT);
  DROP TABLE    IF EXISTS public.palco_sessoes_historico;
  DROP TABLE    IF EXISTS public.usuarios_palco;
  DROP FUNCTION IF EXISTS public.palco_set_atualizado_em();
COMMIT;
```

Como todos os objetos usam prefixo `palco_*` / `usuarios_palco`, o rollback é cirúrgico — zero risco para as tabelas existentes do gestor-trafego.
