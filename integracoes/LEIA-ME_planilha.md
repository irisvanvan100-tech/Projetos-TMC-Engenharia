# Cronograma do app → Planilha Google (Residencial Amora)

Quando o progresso é marcado no Cronograma do app, a planilha se atualiza sozinha.

## Onde está cada coisa
- **Planilha:** Google Drive → pasta *Teste Claude – atualização de planilha* → **Cópia de CRONOGRAMA FISICO FINANCEIRO** (aba CRONOGRAMA).
- **Programa da planilha:** dentro dela, em *Extensões → Apps Script* (código em `integracoes/planilha_cronograma.gs`).
- **Banco de dados:** Supabase, projeto `aaajvihtdhpootilcgll` (tabela `planilhas_obra`, parte 9 do `banco_de_dados.sql`).

## Como funciona
1. Você marca um item no Cronograma do app.
2. O banco envia o andamento da obra para o programa da planilha.
3. O programa escreve as letras A/B/C/D nas colunas B a E (aptos 101, 102, 201, 202 do bloco 1).

## Regras
- Quem manda é o **app**: o que for escrito à mão na planilha é trocado no próximo envio.
- Conta usada nos dois: A = 25%, B = 50%, C = 75%, D = 100%.
- Se a planilha falhar, a marcação no app continua salva normalmente.
- A chave secreta fica só no banco e no programa da planilha (nunca no GitHub).

## Conferir se está funcionando (SQL Editor)
```sql
select status_code, left(content::text, 200) as resposta, created
from net._http_response order by created desc limit 5;
```
- `{"ok":true,...}` → funcionando.
- `{"ok":false,...}` → a chave do banco e a do programa estão diferentes.

## Mandar tudo de novo para a planilha (SQL Editor)
```sql
select sincronizar_planilhas();
```
