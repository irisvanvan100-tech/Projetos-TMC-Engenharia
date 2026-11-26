/**
 * TMC Engenharia — Cronograma do app → Planilha Google (aba CRONOGRAMA)
 *
 * Vai dentro da planilha: Extensões → Apps Script. Publicado como "App da Web".
 * A cada marcação no Cronograma do app, o banco de dados (Supabase) envia para cá
 * o andamento completo da obra, e este programa escreve as letras A/B/C/D nas células.
 *
 * A planilha segue a mesma ordem de setores e itens do app (setores.js).
 * Apartamentos a partir da coluna B, na ordem do app: 101, 102, 201, 202 do bloco 1,
 * depois os do bloco 2, e assim por diante (APTOS = 4 × número de blocos da planilha).
 */

const SEGREDO = 'COLE_AQUI_A_CHAVE_SECRETA';     // a mesma cadastrada no banco (tabela planilhas_obra)
const ABA = 'CRONOGRAMA';
const APTOS = 4;                                  // colunas de apartamentos: 4 = 1 bloco, 12 = 3 blocos
const COLUNA_101 = 2;                             // coluna B = apto 101 do bloco 1
// Linha do 1º item de cada setor e quantos itens ele tem (mesma ordem do app)
const SETORES = [
  { linha: 5,   itens: 6 },   // SERVIÇOS PRELIMINARES
  { linha: 13,  itens: 11 },  // FUNDAÇÃO
  { linha: 26,  itens: 8 },   // ESTRUTURA E ALVENARIA - TÉRREO
  { linha: 36,  itens: 4 },   // ESTRUTURA E ALVENARIA - SUPERIOR
  { linha: 42,  itens: 5 },   // ACABAMENTOS DE ESTRUTURAS E ALVENARIAS
  { linha: 49,  itens: 4 },   // COBERTURA
  { linha: 55,  itens: 7 },   // IMPERMEABILIZAÇÃO
  { linha: 64,  itens: 9 },   // ÁREAS EXTERNAS - PRÉDIO
  { linha: 75,  itens: 6 },   // ACABAMENTOS
  { linha: 83,  itens: 7 },   // INSTALAÇÕES
  { linha: 92,  itens: 2 },   // VERIFICAÇÕES
  { linha: 96,  itens: 2 },   // PINTURA
  { linha: 100, itens: 4 }    // EXTRAS
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

// Reescreve as letras de todos os itens (o que não veio do app fica em branco)
function escrever(marcas) {
  const aba = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(ABA);
  const grade = SETORES.map(s => Array.from({ length: s.itens }, () => Array(APTOS).fill('')));
  marcas.forEach(([setor, item, apto, letra]) => {
    if (grade[setor] && grade[setor][item] && apto >= 0 && apto < APTOS) grade[setor][item][apto] = String(letra).toUpperCase();
  });
  SETORES.forEach((s, i) => aba.getRange(s.linha, COLUNA_101, s.itens, APTOS).setValues(grade[i]));
}

const resposta = obj => ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);

// Rode uma vez pelo editor (botão Executar) para autorizar o programa e conferir a planilha
function testar() {
  const aba = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(ABA);
  if (!aba) throw new Error('Não achei a aba ' + ABA);
  const primeiro = aba.getRange(SETORES[0].linha, 1).getValue(), ultimo = aba.getRange(SETORES[12].linha + 3, 1).getValue();
  Logger.log('1º item: ' + primeiro + ' | último item: ' + ultimo + ' | tudo certo se forem MOBILIZAÇÃO... e VISTORIAS');
}
