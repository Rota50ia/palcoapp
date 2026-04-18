# PALCO — Sprint 1 Deploy Guide
**Data:** 18/04/2026
**Sprint:** 1 — stateless echo (sem memoria)
**Deliverable:** `PALCO-WORKFLOW-SPRINT1.json`

---

## O que esse sprint entrega

Um workflow n8n que:
1. Recebe mensagem WhatsApp via webhook UazAPI
2. Roteia para Claude API (modelo `claude-sonnet-4-5`) com o PALCO-PROMPT-MESTRE
3. Devolve a resposta da Claude de volta pro musico via UazAPI

**NAO entrega ainda (Sprint 2):**
- Memoria entre mensagens
- Supabase (ficha do musico)
- Calibracao semanal

---

## Respostas as 3 perguntas do handoff

| Pergunta | Resposta |
|---|---|
| 1. Claude API key ativa? | **NAO no `.env` local.** So `OPENAI_KEY` esta setada. **BLOQUEADOR antes de ativar.** Acao: gerar em console.anthropic.com e adicionar no n8n como env var `ANTHROPIC_API_KEY`. |
| 2. Workflow antigo reaproveitavel? | **Nao ha workflow n8n antigo exportado** para agente conversacional. Workflow Sprint 1 foi criado do zero, seguindo padroes de UazAPI de `MAESTRO-POS-COMPRA.json`. |
| 3. Supabase novo ou reutilizar? | **Reutilizar `ctvdlamxicoxniyqcpfd`** — criar tabela nova `usuarios_palco` (isolamento por tabela, nao por projeto). Menos infra, aproveita service_role ja configurado. Decisao final fica para Sprint 2. |

---

## Pre-requisitos (fazer ANTES de importar)

### 1. Gerar Claude API key
- Acessar https://console.anthropic.com/
- Settings > API Keys > Create Key (nome sugerido: `palco-n8n-sprint1`)
- Copiar a chave (`sk-ant-api03-...`)

### 2. Adicionar ANTHROPIC_API_KEY no n8n

**Opcao A — env var no EasyPanel (recomendado):**
- EasyPanel > edilson-dark-n8n > Environment
- Adicionar:
  ```
  ANTHROPIC_API_KEY=sk-ant-api03-xxx
  ```
- Restart do container

**Opcao B — Credential n8n (mais portable):**
- n8n > Credentials > Create New > HTTP Header Auth
- Name: `Claude API`
- Header Name: `x-api-key`
- Header Value: `sk-ant-api03-xxx`
- No node `Claude API (Palco)`: trocar de "Generic Credential" para essa credential e remover o header `x-api-key` do parameter list

**Sprint 1 usa Opcao A** (mais rapido pra teste). Se for multi-tenant futuro, migrar para credential.

---

## Deploy — Passo a Passo

### 1. Importar o workflow

- n8n UI > Workflows > Import from File
- Selecionar: `PALCO-WORKFLOW-SPRINT1.json`
- Confirmar: 8 nodes importados
- **NAO ATIVAR AINDA.**

### 2. Copiar URL do webhook

- Abrir node `Webhook UazAPI`
- Copiar "Production URL":
  ```
  https://edilson-dark-n8n.7lvlou.easypanel.host/webhook/palco-mensagem
  ```

### 3. Configurar UazAPI para postar no webhook

UazAPI precisa saber onde postar quando uma msg entrar. Duas opcoes:

**Opcao A — Webhook global da instancia (mais simples):**
```bash
curl -X POST 'https://edilsonmorais.uazapi.com/instance/updateWebhook' \
  -H 'token: 62a7447d-fdb3-41e0-b342-4835cb812490' \
  -H 'Content-Type: application/json' \
  -d '{
    "webhook": "https://edilson-dark-n8n.7lvlou.easypanel.host/webhook/palco-mensagem",
    "events": ["messages"],
    "excludeMessages": ["wasSentByApi"]
  }'
```

> **CUIDADO:** se a instancia `edilson_empresa_2026` JA tem webhook global configurado para outro workflow (ex: W-RESPOSTA), sobrescrever aqui quebra o outro. Verificar antes com:
> ```bash
> curl -H 'token: 62a7447d-...' https://edilsonmorais.uazapi.com/instance
> ```
> Se ja tem webhook ativo, usar Opcao B.

**Opcao B — Instancia separada pro Palco (recomendado se nao puder compartilhar):**
- Criar nova instancia UazAPI: `palco_sprint1`
- Conectar numero dedicado do Palco (idealmente nao o `556282060863` que ja e o numero empresa)
- Apontar webhook dessa instancia para o workflow PALCO

### 4. Ativar o workflow

- n8n UI > abrir workflow PALCO
- Toggle "Active" no canto superior direito

### 5. Teste smoke (antes de T3)

**Do numero de teste, mandar para o numero UazAPI:**
```
Oi Palco
```

**Resposta esperada em ate 30s:**
> "Antes de criar qualquer coisa, preciso entender quem voce e. Tres perguntas..."

Se nao responder, checklist de troubleshooting abaixo.

---

## Troubleshooting

### Workflow roda mas Claude retorna erro
- Checar execucao n8n > node `Claude API (Palco)` > JSON output
- Se `error.type == 'authentication_error'` → key invalida ou nao setada
- Se `error.type == 'rate_limit'` → key com credito zerado
- Se timeout → aumentar `timeout` do node de 60000 para 120000

### Webhook recebe mas "Mensagem Valida?" vai pro false
- Executar manualmente o node `Normalizar Mensagem` com payload real
- Inspecionar `rawKeys` no output — UazAPI pode estar enviando shape que nao casa com os paths do normalizer
- Ajustar regras de extracao em `number`, `text`, `fromMe` conforme necessario
- **Isto e esperado** no primeiro teste — ajuste iterativo

### Musico responde mas Palco responde ao proprio numero do bot (loop)
- `fromMe` nao foi detectado corretamente
- Adicionar no `excludeMessages` do webhook UazAPI: `["wasSentByApi", "fromMe"]`
- Ou endurecer a regra em `Normalizar Mensagem` comparando `number` com o numero da instancia

### Resposta sai mas com a nota "modo teste sem memoria"
- Isso e proposital no Sprint 1 — quando o musico responder P1, ele vai continuar a conversa, mas a proxima msg nao tera contexto anterior
- No Sprint 2 essa nota e removida

---

## O que testar antes do T3 rodar

**Gate de aceite Sprint 1:**
- [ ] Mensagem "oi" → Palco responde com apresentacao + P1
- [ ] Mensagem "meu ativo e X" → Palco responde algo coerente (mesmo sem memoria)
- [ ] Mensagem do proprio numero do bot → NAO gera resposta (filtro fromMe funciona)
- [ ] Execucao n8n nao acumula erros por 10 min consecutivos
- [ ] Log de `usage` na saida do Claude mostra tokens consumidos (input + output)

**Se todos ✓ → Sprint 1 aprovado, partir pra Sprint 2 (Supabase + memoria).**

---

## Tech debt identificado (tratar em sprints futuros)

| Item | Prioridade | Motivo |
|---|---|---|
| Prompt mestre inline no JSON (string escapada) | MEDIA | Dificil manter. Sprint 2: mover pra Set node ou tabela Supabase |
| Sem rate limiting por numero | BAIXA | OK pra 1-10 usuarios. Acima disso, adicionar redis ou tabela de ultimos acessos |
| Sem retry em falha Claude | BAIXA | `neverError:true` devolve msg amigavel. Retry automatico com backoff em Sprint 3 |
| Token UazAPI hardcoded no node | BAIXA | Padrao do projeto (todos workflows fazem assim). Refatorar com credential n8n em ciclo de hardening |
| Sem observabilidade (Sentry, logs estruturados) | MEDIA | Confiar em "Executions" do n8n por enquanto |

---

## Proximos passos (Sprint 2 — prox sessao)

1. **Criar tabela `usuarios_palco`** no Supabase `ctvdlamxicoxniyqcpfd`:
   ```sql
   create table usuarios_palco (
     numero text primary key,
     ficha_json jsonb,
     sessao_atual text default 'onboarding_p1',
     ultima_mensagem_em timestamptz default now(),
     calibracao_json jsonb,
     criado_em timestamptz default now()
   );
   ```

2. **Adicionar no workflow:**
   - Node Supabase GET pelo numero (depois de Normalizar, antes de Claude)
   - Ramificar: sem ficha → rota onboarding / com ficha → rota semanal
   - Passar ficha como context no system prompt
   - Node Supabase UPSERT depois de Claude (salvar estado)

3. **Remover a nota de sistema "modo teste sem memoria"** do prompt.

Sprint 2 estimativa: 1 sessao de ~2h.
