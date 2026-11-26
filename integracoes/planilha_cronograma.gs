/**
 * TMC Engenharia — Cronograma do app → Planilha Google
 *
 * Vai dentro da planilha: Extensões → Apps Script. Publicado como "App da Web".
 * A cada marcação no Cronograma do app, o banco de dados (Supabase) envia para cá
 * o andamento completo da obra, e este programa escreve as letras A/B/C/D nas células.
 *
 * Cada planilha tem a sua configuração (as 4 constantes abaixo):
 *  - ABA:    nome da aba do cronograma
 *  - APTOS:  quantas colunas de apartamentos, a partir da coluna B (4 por bloco: 101, 102, 201, 202)
 *  - LINHAS: em que linha da planilha fica cada item do app, setor por setor, na ordem do app
 *            (setores.js). null = o item não existe nesta planilha (fica de fora).
 *            Linhas da planilha que não aparecem aqui não são tocadas (continuam manuais).
 */

const SEGREDO = 'COLE_AQUI_A_CHAVE_SECRETA';     // a mesma cadastrada no banco (tabela planilhas_obra)
const ABA = 'CRONOGRAMA';
const APTOS = 4;
const LINHAS = [                                  // padrão: mesmo layout do app (Residencial Amora, Fase 1)
  [5, 6, 7, 8, 9, 10],                            // SERVIÇOS PRELIMINARES
  [13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23],   // FUNDAÇÃO
  [26, 27, 28, 29, 30, 31, 32, 33],               // ESTRUTURA E ALVENARIA - TÉRREO
  [36, 37, 38, 39],                               // ESTRUTURA E ALVENARIA - SUPERIOR
  [42, 43, 44, 45, 46],                           // ACABAMENTOS DE ESTRUTURAS E ALVENARIAS
  [49, 50, 51, 52],                               // COBERTURA
  [55, 56, 57, 58, 59, 60, 61],                   // IMPERMEABILIZAÇÃO
  [64, 65, 66, 67, 68, 69, 70, 71, 72],           // ÁREAS EXTERNAS - PRÉDIO
  [75, 76, 77, 78, 79, 80],                       // ACABAMENTOS
  [83, 84, 85, 86, 87, 88, 89],                   // INSTALAÇÕES
  [92, 93],                                       // VERIFICAÇÕES
  [96, 97],                                       // PINTURA
  [100, 101, 102, 103]                            // EXTRAS
];

// Recebe o andamento enviado pelo banco: { segredo, obra, marcas: [[setor, item, apto, letra], ...] }
function doPost(e) {
  const dados = JSON.parse(e.postData.contents);
  if (dados.segredo !== SEGREDO) return resposta({ ok: false, erro: 'chave secreta não confere' });
  const trava = LockService.getScriptLock();
  trava.waitLock(30000);                          // duas marcações seguidas: uma espera a outra
  try { escrever(dados.marcas || []); }
  finally { trava.releaseLock(); }
  return resposta({ ok: true, obra: dados.obra, marcas: (dados.marcas || []).length });
}

// Reescreve as letras de todas as linhas ligadas ao app (o que não veio do app fica em branco)
function escrever(marcas) {
  const aba = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(ABA);
  const grade = {};                               // linha da planilha → letras dos apartamentos
  LINHAS.flat().forEach(l => { if (l) grade[l] = Array(APTOS).fill(''); });
  marcas.forEach(([setor, item, apto, letra]) => {
    const l = (LINHAS[setor] || [])[item];
    if (l && apto >= 0 && apto < APTOS) grade[l][apto] = String(letra).toUpperCase();
  });
  // grava em blocos de linhas seguidas (menos chamadas = mais rápido)
  const linhas = Object.keys(grade).map(Number).sort((a, b) => a - b);
  for (let i = 0; i < linhas.length;) {
    let j = i; while (j + 1 < linhas.length && linhas[j + 1] === linhas[j] + 1) j++;
    aba.getRange(linhas[i], 2, j - i + 1, APTOS).setValues(linhas.slice(i, j + 1).map(l => grade[l]));
    i = j + 1;
  }
}

const resposta = obj => ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);

// Rode uma vez pelo editor (botão Executar) para autorizar o programa e conferir a planilha
function testar() {
  const aba = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(ABA);
  if (!aba) throw new Error('Não achei a aba ' + ABA);
  const nomes = LINHAS.flat().filter(Boolean);
  Logger.log('Aba ' + ABA + ' | ' + nomes.length + ' itens ligados ao app | 1º: ' + aba.getRange(nomes[0], 1).getValue()
    + ' | último: ' + aba.getRange(nomes[nomes.length - 1], 1).getValue());
}
