// ============================================================
// ESTOQUE: abas 🛒 Compras (previsto da obra + lista de compras) e 📐 Modelo (1 bloco = 4 aptos)
// Carrega ANTES do script do estoque.html; usa (só na hora de rodar) materiais, movs, obras, st, editor, perfil, render e registrar de lá
// ============================================================
let modelo = null, perdaPadrao = 5, listas = [];
const memC = memoria('tmc_est_');
const cp = { obra: memC.ler('obraCompra'), sel: {}, listaId: null, nome: '', comPrecos: memC.ler('comPrecos', '1') === '1',
             cat: 'TODAS', busca: '', soFalta: false, catMod: 'TODAS', buscaMod: '', semPreco: false, prev: null };

async function carregarCompras() {
  try {
    [modelo, listas] = await Promise.all([
      todos(() => sb.from('modelo_bloco').select('*').order('ordem')),
      todos(() => sb.from('listas_compra').select('*').order('criado_em', { ascending: false }))
    ]);
    const p = ok(await sb.from('parametros').select('valor').eq('chave', 'perda_padrao').maybeSingle());
    if (p) perdaPadrao = +p.valor;
  } catch (e) { modelo = null; }   // banco ainda sem as tabelas novas
}

// ----- cálculo: previsto, comprado, usado, saldo, falta e preço de cada material da obra -----
const obraCompra = () => obras.find(o => o.nome === cp.obra && o.blocos > 0);
const previsto = (it, blocos) => Math.ceil(it.quantidade * blocos * (1 + (it.perda ?? perdaPadrao) / 100) - 1e-9);
function planejamento() {
  const o = obraCompra(); if (!o || !modelo) return [];
  const ult = {}, mov = {}, cat = {};
  movs.forEach(m => {
    if (m.tipo === 'E' && +m.preco > 0) ult[m.material] = +m.preco;          // último preço pago (qualquer obra)
    if (m.obra !== o.nome) return;
    const r = (mov[m.material] ??= { e: 0, s: 0 }); if (m.tipo === 'E') r.e += +m.quantidade; else r.s += +m.quantidade;
  });
  materiais.forEach(m => cat[m.nome] = m.categoria);
  return modelo.map(it => {
    const r = mov[it.material] || { e: 0, s: 0 }, prev = previsto(it, o.blocos);
    const preco = ult[it.material] ?? (it.preco_ref != null ? +it.preco_ref : null);
    return { ...it, cat: cat[it.material] || 'OUTROS', prev, comp: r.e, usado: r.s, saldo: r.e - r.s, falta: Math.max(0, prev - r.e),
             preco, fonte: ult[it.material] != null ? 'último pago' : it.preco_ref != null ? 'planilha' : '' };
  });
}
const itensSelecionados = plano => plano.filter(x => cp.sel[x.material] != null)
  .map(x => ({ material: x.material, unidade: x.unidade, quantidade: cp.sel[x.material], preco: x.preco }));
const totalItens = itens => itens.reduce((a, x) => a + (x.preco != null ? x.quantidade * x.preco : 0), 0);
const filtraCat = (l, cat, busca) => l.filter(x => (cat === 'TODAS' || x.cat === cat) && x.material.toLowerCase().includes(busca.toLowerCase()));
const chipsCat = (l, atual, attr) => `<div class="chips">${['TODAS', ...new Set(l.map(x => x.cat))].map(c => `<button class="${c === atual ? 'on' : ''}" ${attr}="${esc(c)}">${esc(c)}</button>`).join('')}</div>`;
const SEM_TABELAS = '<div class="card">Rode o <b>banco_de_dados.sql</b> novo no Supabase para usar as compras e o modelo de 1 bloco.</div>';

// ----- aba 🛒 Compras -----
function rC() {
  if (!modelo) return SEM_TABELAS;
  const com = obras.filter(o => o.blocos > 0);
  if (!obraCompra()) cp.obra = (com.find(o => o.nome === st.obraFiltro) || com[0])?.nome || '';
  const o = obraCompra();
  if (!o) return '<div class="card">Cadastre a obra com a quantidade de blocos no <b>Cronograma</b> (aba Obras).</div>';
  const plano = planejamento(), vale = k => plano.reduce((a, x) => a + (x.preco != null ? x[k] * x.preco : 0), 0);
  const semPreco = plano.filter(x => x.preco == null).length;
  const lista = filtraCat(plano, cp.cat, cp.busca).filter(x => !cp.soFalta || x.falta > 0);
  return `<div class="card"><label class="muted" for="cObra">Obra</label>
    <select id="cObra">${com.map(x => `<option value="${esc(x.nome)}" ${x.nome === o.nome ? 'selected' : ''}>${esc(x.nome)} (${x.blocos} blocos)</option>`).join('')}</select>
    <p class="muted">${o.blocos} ${o.blocos === 1 ? 'bloco' : 'blocos'} = ${o.blocos * 4} apartamentos • previsto = quantidade de 1 bloco × ${o.blocos} + ${num(perdaPadrao)}% de perda (padrão), arredondado para cima.</p></div>
  <div class="resumo"><div>Previsto da obra<b>${brl(vale('prev'))}</b></div><div>Já comprado<b>${brl(vale('comp'))}</b></div><div>Falta comprar<b>${brl(vale('falta'))}</b></div></div>
  ${semPreco ? `<p class="muted">⚠️ ${semPreco} materiais ainda sem preço não entram nesses valores. Preencha na aba 📐 Modelo.</p>` : ''}
  <div class="card"><input id="cBusca" placeholder="🔍 Buscar material" value="${esc(cp.busca)}" autocomplete="off">
    ${chipsCat(plano, cp.cat, 'data-ccat')}
    <label class="ck"><input type="checkbox" id="cSoFalta" ${cp.soFalta ? 'checked' : ''}> Mostrar só o que falta comprar</label>
    <div class="cl" id="cLista">${lista.map(linhaCompra).join('') || '<p class="muted">Nenhum material.</p>'}</div></div>
  ${rListas()}`;
}
function linhaCompra(x) {
  const q = cp.sel[x.material], on = q != null;
  return `<div class="ci ${on ? 'on' : ''}">
    <label class="ck"><input type="checkbox" class="editor" data-sel="${esc(x.material)}" ${on ? 'checked' : ''}><span><b>${esc(x.material)}</b><small>${esc(x.cat)} • ${esc(x.unidade)}</small></span></label>
    <div class="nums"><span>Previsto<b>${num(x.prev)}</b></span><span>Comprado<b>${num(x.comp)}</b></span><span>Usado<b>${num(x.usado)}</b></span><span>Saldo<b>${num(x.saldo)}</b></span><span class="${x.falta ? 'fx' : ''}">Falta<b>${num(x.falta)}</b></span></div>
    <div class="pr">${x.preco != null ? `${brl(x.preco)}/${esc(x.unidade)} <small>(${x.fonte})</small>` : '<small>sem preço</small>'}
      ${on ? `<span class="qt">Comprar <input data-qtd="${esc(x.material)}" value="${num(q)}" inputmode="decimal" aria-label="Quantidade a comprar"> <b data-tt="${esc(x.material)}">${x.preco != null ? brl(q * x.preco) : ''}</b></span>` : ''}</div></div>`;
}
function rListas() {
  return `<div class="card"><b>Listas guardadas</b>${cp.listaId ? ` <button class="pq editor" id="cNova">+ Nova lista</button>` : ''}
    <table>${listas.map(l => `<tr><td><b>${esc(l.nome)}</b><div class="muted">${esc(l.obra)} • ${fmtDH(l.criado_em)} • ${l.itens.length} itens${l.com_precos ? ' • ' + brl(l.total) : ''}</div></td>
      <td class="n"><button class="pq" data-labrir="${l.id}">Abrir</button> <button class="pq" data-lpdf="${l.id}">📄</button> <button class="pq editor" data-ldel="${l.id}" aria-label="Excluir lista">🗑</button></td></tr>`).join('')
      || '<tr><td class="muted">Nenhuma lista guardada ainda.</td></tr>'}</table></div>`;
}
// barra fixa com o resumo da seleção
function atualizaBarra() {
  const itens = itensSelecionados(planejamento()), n = itens.length;
  $('fabC').hidden = st.tela !== 'c' || !n;
  $('fabC').querySelector('button').textContent = `🛒 ${n} ${n === 1 ? 'item' : 'itens'} • ${brl(totalItens(itens))} — Ver prévia`;
}

// ----- prévia, PDF e guardar -----
function abrePrevia(dados) {
  cp.prev = dados;
  $('cNome').value = dados.nome; $('cPrecos').checked = dados.comPrecos; $('cGuardar').hidden = !dados.daSelecao || !editor;
  $('cGuardar').textContent = cp.listaId ? '💾 Atualizar lista' : '💾 Guardar lista';
  abrirJanela($('ovC')); desenhaFolha();   // abre antes, para a folha saber a largura da tela
}
function desenhaFolha() {
  const d = cp.prev, p = $('cPrecos').checked, tot = totalItens(d.itens);
  $('paperC').innerHTML = `<div class="fc-cab"><img src="logo.jpg" alt="TMC Engenharia"><div><h3>LISTA DE COMPRAS</h3><div>${esc($('cNome').value || d.nome)}</div></div></div>
    <div class="fc-info"><span><small>Obra</small>${esc(d.obra)}</span><span><small>Data</small>${new Date().toLocaleDateString('pt-BR')}</span><span><small>Itens</small>${d.itens.length}</span>${p ? `<span><small>Total</small>${brl(tot)}</span>` : ''}</div>
    <table><thead><tr><th>Nº</th><th>Material</th><th>Unid.</th><th class="n">Qtd.</th>${p ? '<th class="n">Preço un.</th><th class="n">Total</th>' : ''}</tr></thead>
    <tbody>${d.itens.map((x, i) => `<tr><td>${i + 1}</td><td>${esc(x.material)}</td><td>${esc(x.unidade)}</td><td class="n">${num(x.quantidade)}</td>${p ? `<td class="n">${x.preco != null ? brl(x.preco) : '—'}</td><td class="n">${x.preco != null ? brl(x.quantidade * x.preco) : '—'}</td>` : ''}</tr>`).join('')}</tbody>
    ${p ? `<tfoot><tr><td colspan="5">TOTAL</td><td class="n">${brl(tot)}</td></tr></tfoot>` : ''}</table>
    ${p && d.itens.some(x => x.preco == null) ? '<p class="fc-nota">— item sem preço cadastrado (não entra no total).</p>' : ''}`;
  encaixarFolha($('scaleBoxC'), $('scalerC'), 794);
}
async function pdfCompras() {
  const d = cp.prev, p = $('cPrecos').checked, nome = $('cNome').value.trim() || d.nome;
  const jsPDF = await libsPdf('jspdf', 'autotable'), doc = new jsPDF({ unit: 'mm', format: 'a4' }), OLIVA = [122, 139, 111], M = 14;
  try { doc.addImage(await logoPdf(), 'JPEG', M, 10, 34, 21); } catch (e) {}
  doc.setFont('helvetica', 'bold'); doc.setFontSize(16); doc.text('LISTA DE COMPRAS', 54, 19);
  doc.setFont('helvetica', 'normal'); doc.setFontSize(10); doc.text(nome, 54, 25);
  doc.text(`Obra: ${d.obra}   •   Data: ${new Date().toLocaleDateString('pt-BR')}   •   Itens: ${d.itens.length}`, M, 38);
  const head = ['Nº', 'Material', 'Unid.', 'Qtd.', ...(p ? ['Preço un.', 'Total'] : [])];
  const body = d.itens.map((x, i) => [i + 1, x.material, x.unidade, num(x.quantidade), ...(p ? [x.preco != null ? brl(x.preco) : '—', x.preco != null ? brl(x.quantidade * x.preco) : '—'] : [])]);
  doc.autoTable({ startY: 42, margin: { left: M, right: M, bottom: 16 }, head: [head], body,
    foot: p ? [[{ content: 'TOTAL', colSpan: 5, styles: { halign: 'right' } }, brl(totalItens(d.itens))]] : undefined,
    styles: { fontSize: 9, cellPadding: 1.8 }, headStyles: { fillColor: OLIVA }, footStyles: { fillColor: [239, 232, 220], textColor: 20, fontStyle: 'bold' },
    columnStyles: { 0: { cellWidth: 10 }, 2: { cellWidth: 16 }, 3: { halign: 'right', cellWidth: 18 }, 4: { halign: 'right', cellWidth: 26 }, 5: { halign: 'right', cellWidth: 28 } } });
  const n = doc.getNumberOfPages();
  for (let i = 1; i <= n; i++) { doc.setPage(i); doc.setFontSize(7); doc.setTextColor(110); doc.text('TMC Engenharia • Lista de compras • ' + d.obra, M, 290); doc.text(`Página ${i} de ${n}`, 196, 290, { align: 'right' }); }
  doc.save(nomeArquivo('lista_compras', d.obra, nome));
}
async function guardarLista() {
  const d = cp.prev, nome = $('cNome').value.trim();
  if (!nome) return toast('Dê um nome para a lista.');
  const dados = { obra: d.obra, nome, com_precos: $('cPrecos').checked, itens: d.itens, total: totalItens(d.itens) };
  try {
    if (cp.listaId) { ok(await sb.from('listas_compra').update(dados).eq('id', cp.listaId)); Object.assign(listas.find(l => l.id === cp.listaId), dados); }
    else { const l = ok(await sb.from('listas_compra').insert({ ...dados, criado_por: perfil.nome }).select().single()); listas.unshift(l); cp.listaId = l.id; }
    cp.nome = nome; registrar(`Lista de compras guardada: ${nome} (${d.obra}, ${d.itens.length} itens)`);
    toast('Lista guardada.'); fecharJanela($('ovC')); render();
  } catch (e) { toast('Não foi possível guardar: ' + msg(e)); }
}

// ----- aba 📐 Modelo de 1 bloco -----
function rP() {
  if (!modelo) return SEM_TABELAS;
  const cat = {}; materiais.forEach(m => cat[m.nome] = m.categoria);
  const itens = modelo.map(x => ({ ...x, cat: cat[x.material] || 'OUTROS' }));
  const semPreco = itens.filter(x => x.preco_ref == null).length;
  const lista = filtraCat(itens, cp.catMod, cp.buscaMod).filter(x => !cp.semPreco || x.preco_ref == null);
  const fora = materiais.filter(m => !modelo.some(x => x.material === m.nome));
  const dis = editor ? '' : 'disabled';
  return `<div class="card"><b>Modelo de 1 bloco (4 apartamentos)</b>
    <p class="muted">Quantidade de cada material para 1 bloco. O previsto de cada obra é calculado com estes números. O preço daqui só é usado enquanto o material não tiver compra registrada no estoque.</p>
    <label class="muted" for="perdaPad">Perda padrão (%)</label><input id="perdaPad" inputmode="decimal" value="${num(perdaPadrao)}" ${dis} style="max-width:120px"></div>
  <div class="card"><input id="mBusca" placeholder="🔍 Buscar material" value="${esc(cp.buscaMod)}" autocomplete="off">
    ${chipsCat(itens, cp.catMod, 'data-mcat')}
    <label class="ck"><input type="checkbox" id="mSemPreco" ${cp.semPreco ? 'checked' : ''}> Mostrar só os sem preço (${semPreco})</label>
    <div class="cl">${lista.map(x => `<div class="mi"><b>${esc(x.material)}</b> <small class="muted">${esc(x.cat)}</small>${x.preco_ref == null ? ' <small class="fx">sem preço</small>' : ''}
      <div class="mg"><label>Qtd./bloco<input data-mod="${esc(x.material)}" data-campo="quantidade" value="${num(x.quantidade)}" inputmode="decimal" ${dis}></label>
      <label>Unid.<input data-mod="${esc(x.material)}" data-campo="unidade" value="${esc(x.unidade)}" ${dis}></label>
      <label>Preço R$<input data-mod="${esc(x.material)}" data-campo="preco_ref" value="${x.preco_ref != null ? num(x.preco_ref) : ''}" inputmode="decimal" placeholder="—" ${dis}></label>
      <label>Perda %<input data-mod="${esc(x.material)}" data-campo="perda" value="${x.perda != null ? num(x.perda) : ''}" inputmode="decimal" placeholder="${num(perdaPadrao)}" ${dis}></label>
      <button class="pq editor" data-mdel="${esc(x.material)}" aria-label="Tirar do modelo">✕</button></div></div>`).join('') || '<p class="muted">Nenhum material.</p>'}</div></div>
  <div class="card editor"><b>Acrescentar material ao modelo</b>
    <div class="row"><select id="mNovo"><option value="">— material —</option>${fora.map(m => `<option>${esc(m.nome)}</option>`).join('')}</select>
    <input id="mNovoQ" inputmode="decimal" placeholder="Qtd./bloco" style="max-width:120px"></div>
    <button class="btn" id="mAdd">Acrescentar</button></div>`;
}
async function salvaCampoModelo(material, campo, valor) {
  const it = modelo.find(x => x.material === material); let v;
  if (campo === 'unidade') v = UP(valor.trim()) || 'UN';
  else { v = valor.trim() === '' ? null : lerNum(valor); if (v != null && (isNaN(v) || v < 0)) return toast('Valor inválido.'); }
  if (campo === 'quantidade' && !(v > 0)) return toast('A quantidade precisa ser maior que zero.');
  try { ok(await sb.from('modelo_bloco').update({ [campo]: v }).eq('material', material)); it[campo] = v; registrar(`Modelo: ${material} • ${campo} = ${v ?? 'vazio'}`); }
  catch (e) { toast('Não foi possível salvar: ' + msg(e)); render(); }
}

// ----- eventos das duas abas -----
const redesenha = () => { const y = scrollY; render(); scrollTo(0, y); };
$('app').addEventListener('click', async e => {
  const b = e.target.closest('button'); if (!b || !['c', 'p'].includes(st.tela)) return;
  const d = b.dataset;
  if (d.ccat) { cp.cat = d.ccat; redesenha(); }
  else if (d.mcat) { cp.catMod = d.mcat; redesenha(); }
  else if (b.id === 'cNova') { cp.sel = {}; cp.listaId = null; cp.nome = ''; redesenha(); }
  else if (d.labrir) {
    const l = listas.find(x => x.id == d.labrir); cp.obra = l.obra; cp.listaId = l.id; cp.nome = l.nome; cp.comPrecos = l.com_precos;
    cp.sel = Object.fromEntries(l.itens.map(x => [x.material, +x.quantidade])); render(); scrollTo(0, 0); toast(`Lista "${l.nome}" aberta.`);
  }
  else if (d.lpdf) { const l = listas.find(x => x.id == d.lpdf); abrePrevia({ obra: l.obra, nome: l.nome, comPrecos: l.com_precos, itens: l.itens, daSelecao: false }); }
  else if (d.ldel) {
    const l = listas.find(x => x.id == d.ldel); if (!confirm(`Excluir a lista "${l.nome}"?`)) return;
    try { ok(await sb.from('listas_compra').delete().eq('id', l.id)); listas = listas.filter(x => x.id !== l.id); if (cp.listaId === l.id) cp.listaId = null; redesenha(); }
    catch (err) { toast('Não foi possível excluir: ' + msg(err)); }
  }
  else if (d.mdel) {
    if (!confirm(`Tirar "${d.mdel}" do modelo de 1 bloco?`)) return;
    try { ok(await sb.from('modelo_bloco').delete().eq('material', d.mdel)); modelo = modelo.filter(x => x.material !== d.mdel); redesenha(); }
    catch (err) { toast('Não foi possível tirar: ' + msg(err)); }
  }
  else if (b.id === 'mAdd') {
    const material = $('mNovo').value, q = lerNum($('mNovoQ').value);
    if (!material || !(q > 0)) return toast('Escolha o material e a quantidade por bloco.');
    try { modelo.push(ok(await sb.from('modelo_bloco').insert({ material, quantidade: q, unidade: 'UN', ordem: modelo.length + 1 }).select().single())); redesenha(); toast('Material acrescentado ao modelo.'); }
    catch (err) { toast('Não foi possível acrescentar: ' + msg(err)); }
  }
});
$('app').addEventListener('change', async e => {
  const t = e.target; if (!['c', 'p'].includes(st.tela)) return;
  if (t.id === 'cObra') { cp.obra = t.value; memC.gravar('obraCompra', cp.obra); cp.sel = {}; cp.listaId = null; render(); }
  else if (t.id === 'cSoFalta') { cp.soFalta = t.checked; redesenha(); }
  else if (t.id === 'mSemPreco') { cp.semPreco = t.checked; redesenha(); }
  else if (t.dataset.sel) {
    const x = planejamento().find(p => p.material === t.dataset.sel);
    if (t.checked) cp.sel[x.material] = x.falta; else delete cp.sel[x.material];
    redesenha();
  }
  else if (t.dataset.mod) salvaCampoModelo(t.dataset.mod, t.dataset.campo, t.value);
  else if (t.id === 'perdaPad') {
    const v = lerNum(t.value); if (isNaN(v) || v < 0) return toast('Perda inválida.');
    try { ok(await sb.from('parametros').upsert({ chave: 'perda_padrao', valor: v })); perdaPadrao = v; registrar(`Perda padrão: ${v}%`); toast('Perda padrão salva.'); redesenha(); }
    catch (err) { toast('Não foi possível salvar: ' + msg(err)); }
  }
});
$('app').addEventListener('input', e => {
  const t = e.target; if (!['c', 'p'].includes(st.tela)) return;
  if (t.id === 'cBusca') { cp.busca = t.value; $('cLista').innerHTML = filtraCat(planejamento(), cp.cat, cp.busca).filter(x => !cp.soFalta || x.falta > 0).map(linhaCompra).join('') || '<p class="muted">Nenhum material.</p>'; }
  else if (t.id === 'mBusca') { cp.buscaMod = t.value; clearTimeout(t._t); t._t = setTimeout(() => { redesenha(); const b = $('mBusca'); b.focus(); b.setSelectionRange(99, 99); }, 350); }
  else if (t.dataset.qtd) {
    const q = lerNum(t.value) || 0, x = planejamento().find(p => p.material === t.dataset.qtd);
    cp.sel[x.material] = q;
    const tt = document.querySelector(`[data-tt="${CSS.escape(x.material)}"]`); if (tt && x.preco != null) tt.textContent = brl(q * x.preco);
    atualizaBarra();
  }
});
$('fabC').querySelector('button').onclick = () => {
  const itens = itensSelecionados(planejamento()).filter(x => x.quantidade > 0);
  if (!itens.length) return toast('Coloque a quantidade dos itens selecionados.');
  abrePrevia({ obra: cp.obra, nome: cp.nome || `Lista de compras ${new Date().toLocaleDateString('pt-BR')}`, comPrecos: cp.comPrecos, itens, daSelecao: true });
};
$('cPrecos').onchange = () => { cp.comPrecos = $('cPrecos').checked; memC.gravar('comPrecos', cp.comPrecos ? '1' : '0'); desenhaFolha(); };
$('cNome').oninput = () => desenhaFolha();
$('cFechar').onclick = () => fecharJanela($('ovC'));
$('cGuardar').onclick = guardarLista;
$('cBaixar').onclick = async () => {
  const b = $('cBaixar'); b.disabled = true; b.textContent = 'Gerando…';
  try { await pdfCompras(); } catch (e) { toast('Não foi possível gerar o PDF: ' + msg(e)); }
  b.disabled = false; b.textContent = '⬇ Baixar PDF';
};
addEventListener('resize', () => { if (!$('ovC').hidden) encaixarFolha($('scaleBoxC'), $('scalerC'), 794); });
