# PALCO — Sprint 2 Deploy Guide
**Data:** 18/04/2026
**Sprint:** 2 — memoria via Supabase (ficha por numero_whatsapp)
**Deliverable:** `PALCO-WORKFLOW-SPRINT2.json`
**Workflow alvo (atualizar, NAO criar novo):** `p4w24acxcwpap4ms`

---

## O que este sprint entrega

Workflow Sprint 1 + camada de memoria:
1. Recebe msg WhatsApp via UazAPI
2. **Busca usuario no Supabase** (tabela `usuarios_palco`, projeto `ctvdlamxicoxniyqcpfd`)
3. **Router de estado** decide rota:
   - Primeiro contato -> apresentacao + P1
   - Resposta de P1 -> salva `ativo_principal`, pede P2
   - Resposta de P2 -> salva `publico`, pede P3
   - Resposta de P3 -> salva `emocao_alvo`, conclui onboarding, abre sessao semanal
   - Onboarding concluido -> sessao semanal (Claude recebe ficha como contexto)
4. Claude responde com system prompt dinamico montado pelo router
5. **Upsert Supabase** se a ficha mudou (skip em sessao semanal — Sprint 3 tratara)
6. UazAPI envia resposta ao musico

---

## Pre-requisitos (fazer ANTES de importar)

### 1. Schema Supabase

Rodar `PALCO-SUPABASE-SPRINT2.sql` no projeto `ctvdlamxicoxniyqcpfd` (SQL editor).
Validar com o bloco SMOKE TEST do proprio arquivo.

### 2. Env vars no n8n (EasyPanel)

Confirmar as duas variaveis no container `edilson-dark-n8n`:

```
ANTHROPIC_API_KEY=sk-ant-api03-...
SUPABASE_SERVICE_ROLE_KEY=eyJhbG...   # service_role, NAO anon
```

**Onde pegar `SUPABASE_SERVICE_ROLE_KEY`:**
Supabase Dashboard -> projeto `ctvdlamxicoxniyqcpfd` -> Settings -> API -> `service_role` secret.

> **CRITICO:** usar `service_role`. A chave `anon` nao tem acesso (RLS bloqueia tudo).

Restart do container apos adicionar.

### 3. Confirmar workflow Sprint 1 desativado

- n8n UI -> abrir workflow `p4w24acxcwpap4ms` (PALCO Sprint 1)
- Toggle "Active" para OFF antes de importar o Sprint 2 por cima
  (se o webhook `/palco-mensagem` ficar ativo em 2 workflows, o n8n ignora o duplicado mas gera warning)

---

## Deploy — Passo a Passo

### Opcao A — Atualizar workflow existente via UI (recomendado)

1. n8n UI -> abrir workflow `p4w24acxcwpap4ms`
2. Menu (3 pontos no canto superior direito) -> **Download** (backup local do Sprint 1)
3. Menu -> **Import from File** (mesmo workflow aberto) -> selecionar `PALCO-WORKFLOW-SPRINT2.json`
4. Confirmar sobrescrita: 12 nodes substituem os 8 antigos
5. **NAO ATIVAR AINDA** — testar primeiro (secao Teste abaixo)

### Opcao B — Atualizar via API n8n (script)

Se o Edilson tiver o n8n API key:

```bash
export N8N_API_URL="https://edilson-dark-n8n.7lvlou.easypanel.host/api/v1"
export N8N_API_KEY="<seu api key>"
export WORKFLOW_ID="p4w24acxcwpap4ms"

# 1. Backup do Sprint 1
curl -s -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "$N8N_API_URL/workflows/$WORKFLOW_ID" > palco-sprint1-backup.json

# 2. Desativar
curl -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "$N8N_API_URL/workflows/$WORKFLOW_ID/deactivate"

# 3. PATCH com novo body (nodes + connections do Sprint 2)
# Obs: a API do n8n espera o payload completo no PUT — extrair nodes/connections/settings
#      do JSON do Sprint 2 e enviar:
curl -X PUT -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  "$N8N_API_URL/workflows/$WORKFLOW_ID" \
  -d @PALCO-WORKFLOW-SPRINT2.json

# 4. Reativar (depois de testar via Execution Manual)
curl -X POST -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "$N8N_API_URL/workflows/$WORKFLOW_ID/activate"
```

---

## Teste — Payload manual (SEM enviar WhatsApp real)

No n8n, abrir o workflow e usar **Execute Workflow** no nodo `Webhook UazAPI`.

### Payload 1 — Primeiro contato (user novo)

```json
{
  "body": {
    "sender": "5562999999999@s.whatsapp.net",
    "text": "oi palco",
    "fromMe": false,
    "type": "text"
  }
}
```

**Resultado esperado:**
- `Buscar Usuario Supabase` retorna `[]`
- `Router & Estado` define `route = "ONBOARDING_INICIO"`, `saveBody.pergunta_atual = "P1"`
- Claude responde com apresentacao + P1 literal
- `Salvar Usuario Supabase` cria row com `numero_whatsapp=5562999999999`, `status_onboarding=em_andamento`, `pergunta_atual=P1`, `ficha={}`
- WhatsApp envia a resposta

Validar no Supabase:
```sql
SELECT numero_whatsapp, status_onboarding, pergunta_atual, ficha
  FROM usuarios_palco
 WHERE numero_whatsapp = '5562999999999';
-- Esperado: em_andamento | P1 | {}
```

### Payload 2 — Resposta de P1 (mesmo numero)

```json
{
  "body": {
    "sender": "5562999999999@s.whatsapp.net",
    "text": "Metodo de violao para adultos iniciantes que tem medo de comecar tarde",
    "fromMe": false,
    "type": "text"
  }
}
```

**Resultado esperado:**
- `Buscar Usuario Supabase` retorna a row com `pergunta_atual=P1`
- `Router & Estado` define `route = "ONBOARDING_P1_RESP"`, salva `ativo_principal`, avanca `pergunta_atual=P2`
- Claude reconhece a resposta em 1 frase e faz P2
- Supabase atualizado: `ficha.ativo_principal` preenchido

Validar:
```sql
SELECT ficha, pergunta_atual FROM usuarios_palco
 WHERE numero_whatsapp = '5562999999999';
-- Esperado: {"ativo_principal":"Metodo de violao..."} | P2
```

### Payload 3 — Resposta de P2

```json
{
  "body": {
    "sender": "5562999999999@s.whatsapp.net",
    "text": "Adulto entre 35 e 55 anos que sempre sonhou em tocar mas acha que e tarde demais",
    "fromMe": false,
    "type": "text"
  }
}
```

Esperado: `ficha.publico` preenchido, `pergunta_atual=P3`, Claude faz P3.

### Payload 4 — Resposta de P3 (fecha onboarding)

```json
{
  "body": {
    "sender": "5562999999999@s.whatsapp.net",
    "text": "Que descobrir uma parte deles que estava guardada ha 20 anos",
    "fromMe": false,
    "type": "text"
  }
}
```

Esperado:
- `ficha` completo (3 campos)
- `status_onboarding=concluido`, `pergunta_atual=null`
- Claude confirma DNA e ja pergunta o que aconteceu na semana

```sql
SELECT status_onboarding, pergunta_atual, ficha
  FROM usuarios_palco
 WHERE numero_whatsapp = '5562999999999';
-- Esperado: concluido | NULL | { ativo_principal, publico, emocao_alvo }
```

### Payload 5 — Sessao semanal (ja tem ficha)

```json
{
  "body": {
    "sender": "5562999999999@s.whatsapp.net",
    "text": "Essa semana uma aluna de 47 anos tocou pela primeira vez a musica favorita dela — chorou no final da aula",
    "fromMe": false,
    "type": "text"
  }
}
```

Esperado:
- `route = "SESSAO_SEMANAL"`
- Claude gera o pacote semanal (FEED/REELS/STORIES/GANCHO/CTA)
- `Precisa Salvar?` vai para ramo FALSE — pula Supabase, vai direto pro WhatsApp

### Limpeza apos teste

```sql
DELETE FROM usuarios_palco WHERE numero_whatsapp = '5562999999999';
```

---

## Gate de aceite Sprint 2

- [ ] Primeiro contato cria row no Supabase com `pergunta_atual=P1`
- [ ] Resposta P1 preenche `ficha.ativo_principal` e avanca para P2
- [ ] Resposta P2 preenche `ficha.publico` e avanca para P3
- [ ] Resposta P3 preenche `ficha.emocao_alvo`, marca `status_onboarding=concluido`
- [ ] Sessao semanal (usuario concluido) gera pacote sem tocar em Supabase
- [ ] 5 mensagens seguidas nao geram erros em `Executions`

---

## Troubleshooting

### `Buscar Usuario Supabase` retorna `{"code":"42P01",...}` (tabela nao existe)
- Rodar `PALCO-SUPABASE-SPRINT2.sql` antes de testar.

### `Buscar Usuario Supabase` retorna `{"code":"42501",...}` (permission denied)
- `SUPABASE_SERVICE_ROLE_KEY` esta errado (provavelmente usando anon key). Pegar a chave `service_role` no dashboard.

### Salvar Usuario retorna `409 Conflict` mesmo com `Prefer: merge-duplicates`
- Verificar que `?on_conflict=numero_whatsapp` esta na URL do node `Salvar Usuario Supabase`.

### Router pula direto pra SESSAO_SEMANAL no primeiro contato
- A tabela ja tem row para aquele numero (teste anterior nao limpou). Rodar `DELETE FROM usuarios_palco WHERE numero_whatsapp = '...'`.

### Claude responde fazendo as 3 perguntas de uma vez
- O system prompt nao foi montado dinamicamente (provavel: node `Router & Estado` falhou). Checar `Executions` -> output do Router -> campo `systemPrompt` nao deve conter P1/P2/P3 juntos.

### Musico trava no meio do onboarding (ex: ignora P2 e manda outra coisa)
- Sprint 2 e ingenuo: tudo que chega enquanto `pergunta_atual=P2` e tratado como resposta de P2.
- Se for um problema real em producao, adicionar no Sprint 3 validacao semantica (Claude checa se a resposta parece uma resposta a P2).

---

## Tech debt adicionado no Sprint 2 (tratar em Sprints futuros)

| Item | Prioridade | Motivo |
|---|---|---|
| Evento da semana nao e persistido em `sessao_atual` | MEDIA | Sprint 3 — necessario para calibracao |
| Pacote gerado nao vai para `palco_sessoes_historico` | MEDIA | Sprint 3 — base do aprendizado |
| Nao ha loop de refinamento do pacote (apos "ajusta X") | ALTA | Sprint 3 — core da proposta |
| Se `SUPABASE_SERVICE_ROLE_KEY` faltar, workflow degrada como "primeiro contato" | BAIXA | Aceitavel, mas adicionar alerta no Sprint 4 |
| Router nao distingue "oi" de resposta valida de P1 | MEDIA | Se musico mandar "oi" em vez de responder P1, sera salvo como `ativo_principal="oi"`. Sprint 3 deve detectar respostas curtas demais e re-perguntar |
| Prompt montado em JS (string concat) | BAIXA | Facil de manter por enquanto. Migrar para template engine se crescer |

---

## Mudancas vs Sprint 1

| Aspecto | Sprint 1 | Sprint 2 |
|---|---|---|
| Nodes | 8 | 12 |
| Memoria | Nenhuma (stateless) | Por `numero_whatsapp` em Supabase |
| Prompt Claude | Inline fixo no JSON | Dinamico, montado pelo Router |
| Nota "modo teste" | Presente | **Removida** |
| Onboarding | Claude simulava sozinho (sem salvar) | State machine + persistencia real |
| Dependencias novas | `ANTHROPIC_API_KEY`, UazAPI | `+ SUPABASE_SERVICE_ROLE_KEY`, `+ tabela usuarios_palco` |

---

## Proximo sprint (Sprint 3)

1. Persistir `sessao_atual.evento_semana` e `sessao_atual.pacote_gerado`
2. Implementar loop de refinamento: `"ajusta o FEED pra ficar mais curto"` -> Claude re-gera SO o FEED
3. Criar RPC `palco_append_calibracao` (ja documentada no SUPABASE-SPRINT2-GUIDE secao 3.8) e chamar ao fechar sessao
4. Detectar respostas "inuteis" de P1/P2/P3 (muito curtas, "nao sei", etc) e pedir reformular em vez de salvar lixo
