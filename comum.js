// ============================================================
// UTILIDADES COMUNS A TODAS AS PÁGINAS (carregar depois do config.js)
// ============================================================

// ----- DOM e texto -----
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const UP = t => String(t ?? '').toLocaleUpperCase('pt-BR');
const semAcento = s => String(s).normalize('NFD').replace(/[̀-ͯ]/g, '');
const nomeArquivo = (...partes) => semAcento(partes.join('_')).replace(/[^\w-]+/g, '_').replace(/_+/g, '_') + '.pdf';

// ----- números e datas -----
const brl = n => (+n || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const num = n => (+n || 0).toLocaleString('pt-BR', { maximumFractionDigits: 2 });
// aceita "1.234,5", "2,5" e "2.5"
const lerNum = v => { v = String(v).trim(); return parseFloat(v.includes(',') ? v.replace(/\./g, '').replace(',', '.') : v); };
const hojeISO = () => { const d = new Date(); return new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 10); };
const fmtData = d => d ? d.split('-').reverse().join('/') : '';
const fmtDH = d => new Date(d).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' });

// ----- Supabase -----
const ok = r => { if (r.error) throw r.error; return r.data; };
const msg = e => (e && e.message) || 'Erro inesperado.';
// Busca todas as linhas (o Supabase devolve no máximo 1000 por vez)
async function todos(consulta) {
  let r = [];
  for (let i = 0; ; i += 1000) { const d = ok(await consulta().range(i, i + 999)); r = r.concat(d); if (d.length < 1000) return r; }
}
// Abre um arquivo guardado (PDF, foto) numa aba nova. A aba é aberta já no clique: o celular bloqueia se abrir depois.
async function abrirArquivo(espaco, caminho) {
  const aba = window.open('', '_blank');
  try { const d = ok(await sb.storage.from(espaco).createSignedUrl(caminho, 600)); if (aba) aba.location = d.signedUrl; else location.href = d.signedUrl; }
  catch (e) { aba?.close(); toast('Não consegui abrir o arquivo: ' + msg(e)); }
}

// ----- avisos e memória do aparelho -----
function toast(m) {
  let t = $('toast'); if (!t) { t = document.createElement('div'); t.id = 'toast'; document.body.appendChild(t); }
  t.textContent = m; t.className = 'show'; clearTimeout(toast.t); toast.t = setTimeout(() => t.className = '', 3500);
}
// localStorage protegido (navegador anônimo ou bloqueado não quebra a página)
const memoria = prefixo => ({
  ler(k, padrao = '') { try { return localStorage.getItem(prefixo + k) ?? padrao; } catch (e) { return padrao; } },
  gravar(k, v) { try { localStorage.setItem(prefixo + k, v); } catch (e) {} },
  lerJSON(k) { try { return JSON.parse(localStorage.getItem(prefixo + k)); } catch (e) { return null; } },
  gravarJSON(k, v) { try { localStorage.setItem(prefixo + k, JSON.stringify(v)); } catch (e) {} }
});

// ----- janelas por cima da tela (prévia, assinatura, avisos) -----
function abrirJanela(el) { el.hidden = false; document.body.style.overflow = 'hidden'; }
function fecharJanela(el) { el.hidden = true; if (!document.querySelector('.overlay:not([hidden])')) document.body.style.overflow = ''; }
// Encaixa uma folha (A4) na largura disponível
function encaixarFolha(caixa, escala, largura, altura) {
  const w = caixa.clientWidth; if (!w) return;
  const s = Math.min(1, w / largura);
  escala.style.transform = `scale(${s})`;
  caixa.style.height = ((altura || escala.firstElementChild.offsetHeight) * s) + 'px';
}

// ----- PDF: as bibliotecas só carregam quando alguém gera um PDF (página abre mais rápido) -----
const LIBS_PDF = {
  jspdf: 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js',
  autotable: 'https://cdnjs.cloudflare.com/ajax/libs/jspdf-autotable/3.8.2/jspdf.plugin.autotable.min.js',
  html2canvas: 'https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js'
};
const scriptsCarregados = {};
function carregarScript(src) {
  return scriptsCarregados[src] ??= new Promise((res, rej) => {
    const s = document.createElement('script'); s.src = src; s.onload = res;
    s.onerror = () => { delete scriptsCarregados[src]; rej(new Error('Sem internet para gerar o PDF. Tente de novo.')); };
    document.head.appendChild(s);
  });
}
async function libsPdf(...nomes) { for (const n of nomes) await carregarScript(LIBS_PDF[n]); return window.jspdf.jsPDF; }

// Transforma um HTML (folha A4 desenhada na página) em PDF com a mesma aparência
async function pdfDaFolha(html, classe, paisagem) {
  const jsPDF = await libsPdf('jspdf', 'html2canvas');
  const box = document.createElement('div'); box.style.cssText = 'position:fixed;left:-20000px;top:0';
  box.innerHTML = `<article class="${classe}">${html}</article>`; document.body.appendChild(box);
  try {
    await Promise.all([...box.querySelectorAll('img')].map(i => i.complete ? 0 : new Promise(r => { i.onload = i.onerror = r; })));
    const canvas = await html2canvas(box.firstElementChild, { scale: 2, backgroundColor: '#ffffff', logging: false });
    const doc = new jsPDF({ orientation: paisagem ? 'landscape' : 'portrait', unit: 'mm', format: 'a4', compress: true });
    doc.addImage(canvas.toDataURL('image/jpeg', 0.9), 'JPEG', 0, 0, paisagem ? 297 : 210, paisagem ? 210 : 297);
    return doc;
  } finally { box.remove(); }
}
// Logo em base64 para os PDFs feitos com jsPDF
let logoBase64 = null;
async function logoPdf() {
  if (logoBase64) return logoBase64;
  const b = await (await fetch('logo.jpg')).blob();
  return logoBase64 = await new Promise(r => { const f = new FileReader(); f.onload = () => r(f.result); f.readAsDataURL(b); });
}

// ----- abertura padrão de cada página -----
// Confere login e permissão, preenche o cabeçalho (nome, Início, Sair) e mostra a página.
TMC.iniciarPagina = async function (modulo) {
  const perfil = await this.exigirAcesso(modulo), editor = perfil[modulo] === 'editar';
  document.body.classList.toggle('view', !editor);
  if ($('quem')) $('quem').textContent = `${perfil.nome} (${editor ? 'editor' : 'somente visualização'})`;
  if ($('linkInicio')) $('linkInicio').hidden = this.modulos(perfil).length < 2;
  if ($('btnSair')) $('btnSair').onclick = () => this.sair();
  return { perfil, editor };
};
TMC.mostrarPagina = function () { $('carregando')?.remove(); ($('sistema') || $('app'))?.classList.remove('oculto', 'hide'); };
TMC.falhaAoAbrir = e => { const c = $('carregando'); if (c) c.textContent = 'Erro ao carregar: ' + msg(e); else toast(msg(e)); };
