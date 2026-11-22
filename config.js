// ============================================================
// CONFIGURAÇÃO ÚNICA DO SISTEMA TMC (usada por todas as páginas)
// ============================================================
const TMC_CONFIG = {
  SUPABASE_URL: "https://aaajvihtdhpootilcgll.supabase.co",
  SUPABASE_KEY: "sb_publishable_Qc3dWQs2NjcrePWpmrGnTQ_Z2YxAduq",
  LEITOR_EMAIL: "leitor@prestacao-obras.com" // acesso "só com senha" da Dona Clea
};
const sb = supabase.createClient(TMC_CONFIG.SUPABASE_URL, TMC_CONFIG.SUPABASE_KEY);

const TMC = {
  // Módulos do sistema: chave = coluna na tabela "perfis"
  MODULOS: {
    folha:      { pagina: 'folha_ponto.html',      titulo: 'Folha de Ponto' },
    cronograma: { pagina: 'cronograma.html',       titulo: 'Cronograma' },
    estoque:    { pagina: 'estoque.html',          titulo: 'Estoque' },
    vistoria:   { pagina: 'vistoria.html',         titulo: 'Vistoria' },
    retrabalhos:{ pagina: 'retrabalhos.html',      titulo: 'Retrabalhos' },
    entrega:    { pagina: 'entrega_chaves.html',   titulo: 'Entrega de Chaves' },
    prestacao:  { pagina: 'prestacao_contas.html', titulo: 'Prestação de Contas' }
  },
  async sessao() { return (await sb.auth.getSession()).data.session; },
  // Perfil do usuário logado: { nome, folha, prestacao, cronograma, estoque, retrabalhos, vistoria, entrega } com níveis 'nenhum' | 'ver' | 'editar'
  async perfil() {
    const s = await this.sessao(); if (!s) return null;
    const { data, error } = await sb.from('perfis').select('*').eq('id', s.user.id).maybeSingle();
    if (error) throw error; return data;
  },
  // Módulos que o usuário pode abrir
  modulos(p) { return p ? Object.keys(this.MODULOS).filter(m => p[m] && p[m] !== 'nenhum') : []; },
  // Chamada no início de cada módulo: sem login ou sem permissão volta para a página central
  async exigirAcesso(modulo) {
    const p = await this.perfil();
    if (!p || !p[modulo] || p[modulo] === 'nenhum') { location.replace('index.html'); return new Promise(() => {}); }
    return p;
  },
  async sair() { await sb.auth.signOut(); location.replace('index.html'); }
};
