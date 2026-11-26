-- ============================================================================
-- SISTEMA TMC ENGENHARIA | Banco único (Supabase / PostgreSQL)
-- Prestação de Contas + Folha de Ponto + Cronograma + Estoque + Retrabalhos + Vistoria + Entrega de Chaves no mesmo projeto.
-- Cada módulo tem os seus dados; o Cronograma e o Estoque não mexem na Prestação de Contas.
-- Cole TUDO no SQL Editor e clique em RUN. Pode rodar de novo sem problema.
-- Nenhum dado já lançado (prestação, fotos, folha) é apagado.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) PRESTAÇÃO DE CONTAS
-- ----------------------------------------------------------------------------
create table if not exists obras (nome text primary key);
create table if not exists categorias (nome text primary key);
create table if not exists lancamentos (
  id bigint generated always as identity primary key,
  data date not null,
  obra text not null references obras(nome) on update cascade,
  fornecedor text not null default '',
  descricao text not null,
  categoria text not null references categorias(nome) on update cascade,
  valor numeric(12,2) not null check (valor >= 0),
  comprovante boolean not null default true,
  conferido boolean not null default false,
  criado_em timestamptz not null default now()
);
create table if not exists caixa (
  id int primary key default 1 check (id = 1),
  recebido numeric(12,2) not null default 0
);
-- Fotos dos comprovantes. O código do lançamento segue o tipo que a tabela lancamentos já tem
-- no banco (número ou uuid, conforme a versão em que ela foi criada).
do $$ begin
  if to_regclass('public.comprovantes') is null then
    execute format('create table comprovantes (
      id bigint generated always as identity primary key,
      lancamento_id %s not null references lancamentos(id) on delete cascade,
      caminho text not null unique,
      criado_em timestamptz not null default now())',
      (select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.lancamentos'::regclass and attname = 'id'));
  end if;
end $$;
create index if not exists lancamentos_data_idx on lancamentos (data desc);
create index if not exists lancamentos_obra_idx on lancamentos (obra);
create index if not exists comprovantes_lanc_idx on comprovantes (lancamento_id);

-- Categorias iniciais: só entram na primeira vez (tabela vazia). O que você excluir pelo sistema não volta.
insert into categorias (nome) select v from unnest(array['Material','Ferramentas','Elétrica','Hidráulica','Acabamento','Transporte','Mão de obra','Outros']) v
where not exists (select 1 from categorias);
-- Caixa de uma versão antiga sem chave: tira as linhas repetidas (fica a de maior valor) e cria a chave
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.caixa'::regclass and contype = 'p') then
    delete from caixa where id is null;
    delete from caixa a using caixa b where a.id = b.id and (a.recebido, a.ctid) < (b.recebido, b.ctid);
    alter table caixa add primary key (id);
  end if;
end $$;
insert into caixa (id, recebido) values (1, 0) on conflict do nothing;


-- ----------------------------------------------------------------------------
-- 2) FOLHA DE PONTO
-- ----------------------------------------------------------------------------
create table if not exists quinzenas (
  id uuid primary key default gen_random_uuid(),
  obra text not null,
  data_inicio date not null,
  data_fim date not null,
  preco_almoco numeric(10,2) not null default 10,
  preco_pao numeric(10,2) not null default 0.70,
  paes_por_almoco numeric(4,1) not null default 2,
  ajuste_refeicoes jsonb not null default '{}',
  criado_em timestamptz default now()
);
create table if not exists funcionarios_quinzena (
  id uuid primary key default gen_random_uuid(),
  quinzena_id uuid not null references quinzenas on delete cascade,
  nome text not null,
  funcao text not null check (funcao in ('servente','pedreiro')),
  valor_diaria numeric(10,2) not null default 0,
  criado_em timestamptz default clock_timestamp()
);
create table if not exists pontos (
  id uuid primary key default gen_random_uuid(),
  funcionario_id uuid not null references funcionarios_quinzena on delete cascade,
  data date not null,
  valor numeric(2,1) not null check (valor in (0,0.5,1)),
  unique (funcionario_id, data)
);
-- Cadastro de funcionários (histórico de quem trabalhou com a TMC). CPF só com números, sem repetir.
create table if not exists funcionarios (
  id uuid primary key default gen_random_uuid(),
  primeiro_nome text not null,
  segundo_nome text not null,
  cpf text not null unique check (cpf ~ '^[0-9]{11}$'),
  funcao text not null default 'servente' check (funcao in ('servente','pedreiro')),
  valor_diaria numeric(10,2) not null default 0,   -- última diária usada (sugestão para a próxima quinzena)
  criado_em timestamptz not null default now()
);
-- cada linha da quinzena aponta para o cadastro (linhas antigas ficam sem, até completar o CPF)
alter table funcionarios_quinzena add column if not exists funcionario_id uuid references funcionarios(id) on delete set null;
create index if not exists funcionarios_quinzena_func_idx on funcionarios_quinzena (funcionario_id);

-- ----------------------------------------------------------------------------
-- 3) CRONOGRAMA (andamento por obra / bloco / apartamento)
--    Lista de obras PRÓPRIA do cronograma (não mexe na Prestação de Contas).
--    Cada bloco tem 4 aptos (101, 102, 201, 202). apto = número sequencial 0,1,2...
--    nivel: A = 25% | B = 50% | C = 75% | D = 100%
-- ----------------------------------------------------------------------------
create table if not exists crono_obras (
  nome text primary key,
  blocos int not null default 1 check (blocos > 0),
  criado_em timestamptz not null default now()
);

-- Se já existir uma tabela crono_status de outra versão (sem as colunas ou a chave esperadas),
-- ela é renomeada para crono_status_antigo (os dados ficam guardados) e a tabela certa é criada.
do $$ declare nome_novo text; c record; begin
  if to_regclass('public.crono_status') is not null and (
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'crono_status'
          and column_name in ('obra','setor','item','apto','nivel')) < 5
       or not exists (select 1 from pg_constraint where conrelid = to_regclass('public.crono_status') and contype = 'p')) then
    nome_novo := case when to_regclass('public.crono_status_antigo') is null then 'crono_status_antigo'
                      else 'crono_status_antigo_' || to_char(now(), 'YYYYMMDDHH24MISS') end;
    for c in select conname from pg_constraint where conrelid = to_regclass('public.crono_status') loop
      execute format('alter table crono_status rename constraint %I to %I', c.conname, nome_novo || '_' || c.conname);
    end loop;
    execute format('alter table crono_status rename to %I', nome_novo);
    raise notice 'Tabela crono_status antiga renomeada para %', nome_novo;
  end if;
end $$;

-- Se uma versão anterior deste script ligou o cronograma/estoque à tabela da Prestação, desfaz:
alter table obras drop column if exists blocos;
alter table if exists crono_status drop constraint if exists crono_status_obra_fkey;
alter table if exists movimentos drop constraint if exists movimentos_obra_fkey;
do $$ begin
  if to_regclass('public.crono_status') is not null then
    update crono_status set obra = 'JABUTI GARDEN' where obra = 'Jabuti Gardem';
  end if;
end $$;

create table if not exists crono_status (
  obra text not null references crono_obras(nome) on update cascade on delete cascade,
  setor int not null,
  item int not null,
  apto int not null,
  nivel text not null check (nivel in ('A','B','C','D')),
  atualizado_por text,
  atualizado_em timestamptz not null default now(),
  primary key (obra, setor, item, apto)
);
alter table crono_status add column if not exists atualizado_por text;
alter table crono_status add column if not exists atualizado_em timestamptz not null default now();
create table if not exists crono_pesos (
  setor int primary key,
  peso numeric(6,2) not null default 0
);

-- Histórico de alterações (cronograma e estoque)
create table if not exists historico (
  id bigint generated always as identity primary key,
  modulo text not null check (modulo in ('cronograma','estoque')),
  usuario text,
  texto text not null,
  criado_em timestamptz not null default now()
);
create index if not exists historico_idx on historico (modulo, criado_em desc);

-- ----------------------------------------------------------------------------
-- 4) ESTOQUE (materiais, entradas e saídas, foto da nota fiscal)
-- ----------------------------------------------------------------------------
create table if not exists materiais (
  id bigint generated always as identity primary key,
  categoria text not null default 'OUTROS',
  nome text not null unique
);
create table if not exists movimentos (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  usuario text,
  tipo text not null check (tipo in ('E','S')),           -- E = entrada (chegou), S = saída (usado)
  material text not null references materiais(nome) on update cascade,
  quantidade numeric(12,2) not null check (quantidade > 0),
  preco numeric(12,2) not null default 0,                   -- preço unitário (só entrada)
  fornecedor text not null default '',
  nota text not null default '',                            -- nº da nota fiscal
  obra text,                                                -- obra do cronograma para onde foi o material
  foto text                                                 -- caminho da foto no espaço "notas"
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'crono_status_obra_fkey') then
    -- andamento com nome de obra que não existe no cronograma vai para um backup (não trava o script)
    create table if not exists crono_status_sem_obra as select * from crono_status with no data;
    insert into crono_status_sem_obra select * from crono_status where obra not in (select nome from crono_obras);
    delete from crono_status where obra not in (select nome from crono_obras);
    alter table crono_status add constraint crono_status_obra_fkey foreign key (obra) references crono_obras(nome) on update cascade on delete cascade;
  end if;
  -- Estoque ligado às obras do cronograma: lançamentos antigos com nome de obra que não existe ficam sem obra
  update movimentos set obra = 'JABUTI GARDEN' where obra = 'Jabuti Gardem';
  update movimentos set obra = null where obra is not null and obra not in (select nome from crono_obras);
  if not exists (select 1 from pg_constraint where conname = 'movimentos_obra_fkey') then
    -- renomear a obra atualiza o estoque; obra com material lançado não pode ser excluída
    alter table movimentos add constraint movimentos_obra_fkey foreign key (obra) references crono_obras(nome) on update cascade on delete restrict;
  end if;
  -- todo lançamento novo precisa ter obra (os antigos sem obra continuam valendo)
  if not exists (select 1 from pg_constraint where conname = 'movimentos_obra_obrigatoria') then
    alter table movimentos add constraint movimentos_obra_obrigatoria check (obra is not null) not valid;
  end if;
end $$;
create index if not exists movimentos_mat_idx on movimentos (material);

-- Modelo de 1 bloco (4 apartamentos): quanto de cada material um bloco gasta.
-- Previsto da obra = quantidade × blocos da obra × (1 + perda%), arredondado para cima.
create table if not exists modelo_bloco (
  material text primary key references materiais(nome) on update cascade on delete cascade,
  quantidade numeric(12,2) not null check (quantidade > 0),
  unidade text not null default 'UN',
  preco_ref numeric(12,4),                    -- preço da planilha (usado quando ainda não há compra registrada)
  perda numeric(5,2) check (perda >= 0),      -- % de perda só deste material (vazio = usa a perda padrão)
  ordem int
);
-- Ajustes gerais (ex.: perda_padrao = 5 → 5%)
create table if not exists parametros (
  chave text primary key,
  valor numeric not null
);
-- Listas de compras guardadas
create table if not exists listas_compra (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  criado_por text,
  obra text not null,
  nome text not null,
  com_precos boolean not null default true,
  itens jsonb not null default '[]',          -- [{"material": "LAJE", "unidade": "M²", "quantidade": 20, "preco": 85}, ...]
  total numeric(14,2) not null default 0
);
create index if not exists listas_compra_idx on listas_compra (criado_em desc);

-- "Apelidos" aprendidos na lista de materiais: o que foi digitado -> material do cadastro
create table if not exists material_apelidos (
  texto text primary key,
  material text not null references materiais(nome) on update cascade on delete cascade,
  atualizado_em timestamptz not null default now()
);


-- ----------------------------------------------------------------------------
-- 4a) MATERIAL (areia, arisco, brita, pedra, aterro): chegada por obra e pagamento ao fornecedor
-- ----------------------------------------------------------------------------
create table if not exists material_precos (
  material text primary key,
  preco numeric(12,2) not null check (preco >= 0),   -- preço por carrada
  ordem int
);
create table if not exists material_entregas (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),       -- data e hora da chegada (sempre a do momento do registro)
  criado_por text,
  obra text not null,
  fornecedor text not null,
  material text not null,
  quantidade numeric(10,2) not null check (quantidade > 0),   -- carradas
  preco numeric(12,2) not null check (preco >= 0),            -- preço do dia (não muda se a tabela mudar)
  observacao text not null default '',
  pago_em timestamptz,
  pago_por text
);
create index if not exists material_entregas_idx on material_entregas (obra, criado_em desc);
insert into material_precos (material, preco, ordem) select * from (values
  ('AREIA GROSSA', 1000, 1), ('ARISCO', 600, 2), ('BRITA 1/2', 1350, 3), ('BRITA 5/8', 1250, 4), ('PEDRA', 1100, 5), ('ATERRO', 300, 6)
) v where not exists (select 1 from material_precos)
on conflict (material) do nothing;

-- ----------------------------------------------------------------------------
-- 4b) VISTORIA (termo de vistoria de unidade, com assinaturas e PDF guardado)
-- ----------------------------------------------------------------------------
create table if not exists vistorias (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  criado_por text,
  obra text not null,                         -- empreendimento (texto livre)
  unidade text not null,
  cliente text not null,
  data date not null,
  marcacoes jsonb not null default '{}',      -- {"Sala|Elétrica": "C", "WC|Hidráulica": "NC", ...}
  observacoes jsonb not null default '{}',    -- {"WC|Hidráulica": "REGISTRO PINGANDO", ...}
  total_nc int not null default 0,
  assinatura_cliente text,                    -- imagem da assinatura (PNG)
  assinatura_responsavel text,
  pdf text,                                   -- caminho do PDF no espaço "vistorias"
  enviado_retrabalhos_em timestamptz
);
create index if not exists vistorias_idx on vistorias (criado_em desc);


-- ----------------------------------------------------------------------------
-- 4b2) ENTREGA DE CHAVES (termo de recebimento ligado a uma vistoria guardada)
--      Nome do cliente, unidade e data da vistoria vêm da vistoria (não são copiados).
-- ----------------------------------------------------------------------------
create table if not exists entregas_chaves (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  criado_por text,
  vistoria_id bigint not null references vistorias(id) on delete restrict,
  obra text not null,                         -- para achar a versão mais nova da vistoria da mesma unidade
  unidade text not null,
  cpf text not null,
  endereco text not null,
  cidade text not null default 'Itaitinga',
  data_entrega date not null
);
create index if not exists entregas_idx on entregas_chaves (criado_em desc);

-- ----------------------------------------------------------------------------
-- 4c) RETRABALHOS (lista de pendências da obra)
-- ----------------------------------------------------------------------------
create table if not exists pendencias (
  id bigint generated always as identity primary key,
  criado_em timestamptz not null default now(),
  criado_por text,
  obra text not null,
  local text not null default '',             -- Bloco 1 • Apto 101 / Área comum
  comodo text not null,
  descricao text not null,
  responsavel text not null default '',       -- pode ficar vazio só quando vem da vistoria ("a completar")
  material text not null default '',
  origem text not null default 'manual' check (origem in ('manual','vistoria')),
  vistoria_id bigint references vistorias(id) on delete set null
);
create index if not exists pendencias_obra_idx on pendencias (obra);

-- ----------------------------------------------------------------------------
-- 5) USUÁRIOS E PERMISSÕES
--    Cada usuário criado em Authentication > Users ganha uma linha em "perfis".
--    Níveis por página: 'nenhum' (não entra) | 'ver' (só visualiza) | 'editar'
-- ----------------------------------------------------------------------------
create table if not exists perfis (
  id uuid primary key references auth.users on delete cascade,
  email text,
  nome text,
  nome text
);
-- uma coluna de permissão por módulo (para um módulo novo, basta acrescentar o nome na lista)
do $$ declare m text; begin
  foreach m in array array['folha','prestacao','cronograma','estoque','retrabalhos','vistoria','entrega','material'] loop
    execute format('alter table perfis add column if not exists %I text not null default ''nenhum'' check (%I in (''nenhum'',''ver'',''editar''))', m, m);
  end loop;
end $$;

create or replace function novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfis (id, email, nome) values (new.id, new.email, split_part(new.email, '@', 1))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function novo_usuario();

-- usuários que já existiam antes deste script
insert into perfis (id, email, nome) select id, email, split_part(email, '@', 1) from auth.users on conflict (id) do nothing;

create or replace function nivel_modulo(modulo text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select n from (select to_jsonb(p) ->> modulo as n from perfis p where p.id = auth.uid()) x
                   where n in ('nenhum','ver','editar')), 'nenhum') $$;
create or replace function pode_ver_modulo(modulo text) returns boolean
language sql stable security definer set search_path = public as $$ select nivel_modulo(modulo) <> 'nenhum' $$;
create or replace function pode_editar_modulo(modulo text) returns boolean
language sql stable security definer set search_path = public as $$ select nivel_modulo(modulo) = 'editar' $$;

-- ----------------------------------------------------------------------------
-- 6) SEGURANÇA (RLS): o próprio banco barra quem não tem permissão
-- ----------------------------------------------------------------------------
-- Tabela -> módulo que dá acesso. Ver: nível 'ver' ou 'editar'. Alterar: só 'editar'.
-- (select pode_...()) faz o banco conferir a permissão uma vez por consulta, e não uma vez por linha.
do $$ declare
  -- tabela -> módulo que dá acesso
  acesso constant jsonb := '{
    "quinzenas": "folha", "funcionarios_quinzena": "folha", "pontos": "folha", "funcionarios": "folha",
    "obras": "prestacao", "categorias": "prestacao", "lancamentos": "prestacao", "caixa": "prestacao", "comprovantes": "prestacao",
    "crono_obras": "cronograma", "crono_status": "cronograma", "crono_pesos": "cronograma",
    "materiais": "estoque", "movimentos": "estoque", "material_apelidos": "estoque",
    "modelo_bloco": "estoque", "parametros": "estoque", "listas_compra": "estoque",
    "material_precos": "material", "material_entregas": "material",
    "vistorias": "vistoria", "entregas_chaves": "entrega", "pendencias": "retrabalhos"}';
  p record; t text;
begin
  -- apaga as regras antigas destas tabelas e das fotos/PDFs, e cria de novo
  for p in select schemaname, tablename, policyname from pg_policies
           where (schemaname = 'public' and (acesso ? tablename or tablename in ('perfis', 'historico')))
              or (schemaname = 'storage' and tablename = 'objects' and (policyname like 'tmc %' or policyname like 'logado %' or policyname like 'entrega %'
                                                                         or policyname in ('envia comprovantes', 'apaga comprovantes')))
  loop execute format('drop policy %I on %I.%I', p.policyname, p.schemaname, p.tablename); end loop;

  for t in select jsonb_object_keys(acesso) loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "ver %1$s" on %1$I for select to authenticated using ((select pode_ver_modulo(%2$L)))', t, acesso ->> t);
    execute format('create policy "alterar %1$s" on %1$I for all to authenticated using ((select pode_editar_modulo(%2$L))) with check ((select pode_editar_modulo(%2$L)))', t, acesso ->> t);
  end loop;
end $$;

alter table perfis enable row level security;
create policy "ver proprio perfil" on perfis for select to authenticated using (id = (select auth.uid()));

-- Acessos de leitura entre módulos
create policy "estoque ve obras" on crono_obras for select to authenticated using ((select pode_ver_modulo('estoque')));      -- campo "obra" do lançamento
create policy "material ve obras" on crono_obras for select to authenticated using ((select pode_ver_modulo('material')));    -- obra da entrega de material
create policy "entrega ve vistorias" on vistorias for select to authenticated using ((select pode_ver_modulo('entrega')));    -- nome do cliente, data e PDF

-- Histórico: cada um vê o histórico dos módulos que acessa; registra quem edita
alter table historico enable row level security;
create policy "ver historico" on historico for select to authenticated using (pode_ver_modulo(modulo));
create policy "registrar historico" on historico for insert to authenticated with check (pode_editar_modulo(modulo));

-- Espaços de arquivos (privados) e quem pode ver / enviar / apagar em cada um
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('comprovantes', 'comprovantes', false, 5242880,  array['image/jpeg','image/png','image/webp']),   -- fotos da prestação de contas
  ('notas',        'notas',        false, 5242880,  array['image/jpeg','image/png','image/webp']),   -- fotos das notas do estoque
  ('vistorias',    'vistorias',    false, 10485760, array['application/pdf'])                        -- PDFs assinados das vistorias
on conflict (id) do nothing;

do $$ declare b record; begin
  for b in select * from (values ('comprovantes','prestacao'), ('notas','estoque'), ('vistorias','vistoria')) v(espaco, modulo) loop
    execute format('create policy %I on storage.objects for select to authenticated using (bucket_id = %L and (select pode_ver_modulo(%L)))', 'tmc le ' || b.espaco, b.espaco, b.modulo);
    execute format('create policy %I on storage.objects for insert to authenticated with check (bucket_id = %L and (select pode_editar_modulo(%L)))', 'tmc envia ' || b.espaco, b.espaco, b.modulo);
    execute format('create policy %I on storage.objects for delete to authenticated using (bucket_id = %L and (select pode_editar_modulo(%L)))', 'tmc apaga ' || b.espaco, b.espaco, b.modulo);
  end loop;
end $$;
create policy "entrega le vistorias" on storage.objects for select to authenticated using (bucket_id = 'vistorias' and (select pode_ver_modulo('entrega')));

-- ----------------------------------------------------------------------------
-- 7) QUEM PODE O QUÊ
--    Níveis: 'nenhum' | 'ver' | 'editar'. Ajuste e rode este bloco de novo quando quiser.
-- ----------------------------------------------------------------------------
update perfis set nome = 'Irisvan',   folha = 'editar', prestacao = 'editar', cronograma = 'editar', estoque = 'editar',
                      retrabalhos = 'editar', vistoria = 'editar', entrega = 'editar', material = 'editar' where lower(email) = lower('irisvan.van100@gmail.com');
update perfis set nome = 'Antônio',   folha = 'ver',    prestacao = 'nenhum'  where lower(email) = lower('antonio@tmc.com');
update perfis set nome = 'Tatiane',   folha = 'editar', prestacao = 'nenhum'  where lower(email) = lower('tatiane@tmc.com');
update perfis set nome = 'Tiago',     folha = 'editar', prestacao = 'ver', cronograma = 'editar', estoque = 'editar',
                      retrabalhos = 'editar', vistoria = 'editar', entrega = 'editar', material = 'ver' where lower(email) = lower('tiago@tmc.com');
update perfis set nome = 'Dona Clea', folha = 'nenhum', prestacao = 'ver'     where lower(email) = lower('donaclea@tmc.com');
-- Exemplos para liberar os módulos novos (tire o "--" do começo e ajuste):
-- update perfis set cronograma = 'ver'                       where lower(email) = lower('antonio@tmc.com');   -- chefe só acompanha
-- update perfis set estoque = 'editar', cronograma = 'nenhum' where lower(email) = lower('EMAIL_DO_ALMOXARIFE');

-- Conferir quem tem acesso:  select nome, email, folha, prestacao, cronograma, estoque from perfis order by nome;

-- ----------------------------------------------------------------------------
-- 8) CARGA INICIAL (lista de materiais e pesos)
--    Só entra na primeira vez (tabela vazia): o que você alterar ou excluir pelo sistema não volta.
-- ----------------------------------------------------------------------------
insert into materiais (categoria, nome) select * from (values
  ('PRÉ-MOLDADOS','LAJE'),
  ('PRÉ-MOLDADOS','CHAPIM'),
  ('PRÉ-MOLDADOS','VERGAS 1M'),
  ('PRÉ-MOLDADOS','VERGAS 1,5M'),
  ('PRÉ-MOLDADOS','VERGAS 2,5M'),
  ('PRÉ-MOLDADOS','TAMPA + SUBTAMPA 60X60 FURADA ÁGUA'),
  ('PRÉ-MOLDADOS','TAMPA + SUBTAMPA 60X60 ESGOTO'),
  ('PRÉ-MOLDADOS','TAMPA + SUBTAMPA 70X70 FOSSA'),
  ('PRÉ-MOLDADOS','TAMPA + SUBTAMPA 60X60 FILTRO'),
  ('PRÉ-MOLDADOS','TAMPA + SUBTAMPA 60X60 SUMIDOURO'),
  ('PRÉ-MOLDADOS','TAMPA + SUBTAMPA 40X40'),
  ('PRÉ-MOLDADOS','ANÉIS DE 1,2M'),
  ('PRÉ-MOLDADOS','TAMPA PERFURADA 1,2M'),
  ('PRÉ-MOLDADOS','TAMPA 1,2M'),
  ('PRÉ-MOLDADOS','ESCADA'),
  ('PRÉ-MOLDADOS','CASA DE GÁS DUPLA'),
  ('HIDRÁULICA - ÁGUA','JOELHO 25MM'),
  ('HIDRÁULICA - ÁGUA','TÊ 25MM'),
  ('HIDRÁULICA - ÁGUA','JOELHO 25MM X 1/2 LATÃO'),
  ('HIDRÁULICA - ÁGUA','TÊ 25MM X 1/2 LATÃO'),
  ('HIDRÁULICA - ÁGUA','JOELHO 25MM X 45°'),
  ('HIDRÁULICA - ÁGUA','ADAPTADOR 25MM X 3/4'),
  ('HIDRÁULICA - ÁGUA','REGISTRO DE PRESSÃO'),
  ('HIDRÁULICA - ÁGUA','REDUÇÃO 32X25MM'),
  ('HIDRÁULICA - ÁGUA','REGISTRO GAVETA'),
  ('HIDRÁULICA - ÁGUA','BUJÃO 1/2'),
  ('HIDRÁULICA - ÁGUA','REDUÇÃO 40X25MM'),
  ('HIDRÁULICA - ÁGUA','FLANGE 50MM'),
  ('HIDRÁULICA - ÁGUA','FLANGE 32MM'),
  ('HIDRÁULICA - ÁGUA','FLANGE 25MM X 3/4'),
  ('HIDRÁULICA - ÁGUA','TÊ 50MM (ÁGUA)'),
  ('HIDRÁULICA - ÁGUA','JOELHO 50MM (ÁGUA)'),
  ('HIDRÁULICA - ÁGUA','TÊ 32MM'),
  ('HIDRÁULICA - ÁGUA','JOELHO 32MM'),
  ('HIDRÁULICA - ÁGUA','REDUÇÃO 50X32MM'),
  ('HIDRÁULICA - ÁGUA','BOIA'),
  ('HIDRÁULICA - ÁGUA','CANO 25MM'),
  ('HIDRÁULICA - ÁGUA','CANO 32MM'),
  ('HIDRÁULICA - ÁGUA','CANO 50MM (ÁGUA)'),
  ('HIDRÁULICA - ÁGUA','CAIXA D''ÁGUA'),
  ('HIDRÁULICA - ÁGUA','REGISTRO FECHO RÁPIDO 50MM'),
  ('HIDRÁULICA - ÁGUA','REGISTRO FECHO RÁPIDO 32MM'),
  ('HIDRÁULICA - ÁGUA','JOELHO 32MM X 45°'),
  ('HIDRÁULICA - ÁGUA','CAP 32MM'),
  ('HIDRÁULICA - ÁGUA','CAP 25MM'),
  ('HIDRÁULICA - ÁGUA','LUVA 32MM'),
  ('LOUÇAS E METAIS','SANITÁRIO COM CAIXA ACOPLADA DUPLO ACIONAMENTO'),
  ('LOUÇAS E METAIS','ANEL DE VEDAÇÃO'),
  ('LOUÇAS E METAIS','KIT PARAFUSOS SANITÁRIO'),
  ('LOUÇAS E METAIS','ENGATE 60CM'),
  ('LOUÇAS E METAIS','SIFÃO'),
  ('LOUÇAS E METAIS','TORNEIRA BANCADA WC'),
  ('LOUÇAS E METAIS','VÁLVULA PIA'),
  ('LOUÇAS E METAIS','CHUVEIRO WC'),
  ('LOUÇAS E METAIS','TORNEIRA BANCADA COZINHA PAREDE'),
  ('LOUÇAS E METAIS','VÁLVULA TANQUE COZINHA'),
  ('LOUÇAS E METAIS','TANQUE LAVA-ROUPAS 0,50 X 0,50'),
  ('LOUÇAS E METAIS','VÁLVULA PARA TANQUE'),
  ('LOUÇAS E METAIS','TORNEIRA TANQUE PAREDE'),
  ('LOUÇAS E METAIS','CHUVEIRÃO'),
  ('LOUÇAS E METAIS','BANCADA COZINHA 1,20M'),
  ('LOUÇAS E METAIS','BANCADA WC'),
  ('HIDRÁULICA - ESGOTO','JOELHO 50MM (ESGOTO)'),
  ('HIDRÁULICA - ESGOTO','JOELHO 40MM'),
  ('HIDRÁULICA - ESGOTO','TÊ 50MM (ESGOTO)'),
  ('HIDRÁULICA - ESGOTO','TÊ 40MM'),
  ('HIDRÁULICA - ESGOTO','JOELHO 45° 40MM'),
  ('HIDRÁULICA - ESGOTO','JOELHO 45° 50MM'),
  ('HIDRÁULICA - ESGOTO','REDUÇÃO 50X40MM'),
  ('HIDRÁULICA - ESGOTO','LUVA 50MM'),
  ('HIDRÁULICA - ESGOTO','JOELHO 100MM'),
  ('HIDRÁULICA - ESGOTO','JUNÇÃO 100X50MM'),
  ('HIDRÁULICA - ESGOTO','LUVA 100MM'),
  ('HIDRÁULICA - ESGOTO','CAIXA SIFONADA 150MM'),
  ('HIDRÁULICA - ESGOTO','CAIXA SIFONADA 100MM'),
  ('HIDRÁULICA - ESGOTO','LUVA 40MM'),
  ('HIDRÁULICA - ESGOTO','TÊ 100MM'),
  ('HIDRÁULICA - ESGOTO','JOELHO 45° 100MM'),
  ('HIDRÁULICA - ESGOTO','CANO 100MM'),
  ('HIDRÁULICA - ESGOTO','CANO 75MM'),
  ('HIDRÁULICA - ESGOTO','CANO 50MM (ESGOTO)'),
  ('HIDRÁULICA - ESGOTO','CANO 40MM'),
  ('HIDRÁULICA - ESGOTO','COLA 900ML'),
  ('HIDRÁULICA - ESGOTO','VEDA ROSCA'),
  ('HIDRÁULICA - ESGOTO','CAIXA DE GORDURA'),
  ('HIDRÁULICA - ESGOTO','CAIXA DE SABÃO'),
  ('HIDRÁULICA - ESGOTO','JUNÇÃO 50X50MM'),
  ('HIDRÁULICA - ESGOTO','TUBO 150MM'),
  ('IMPERMEABILIZANTES','LONA'),
  ('IMPERMEABILIZANTES','FRIO ASFALTO'),
  ('IMPERMEABILIZANTES','ARGAMASSA POLIMÉRICA'),
  ('IMPERMEABILIZANTES','VEDAPREN PAREDE'),
  ('IMPERMEABILIZANTES','BROCHAS'),
  ('ESQUADRIAS','JANELA 60X60 ALUMÍNIO MAXIM-AR'),
  ('ESQUADRIAS','JANELA 100X60 ALUMÍNIO CORRER'),
  ('ESQUADRIAS','JANELA 120X100 ALUMÍNIO CORRER'),
  ('ESQUADRIAS','PORTA 60X210 ALUMÍNIO ABRIR'),
  ('ESQUADRIAS','PORTA 80X210 ALUMÍNIO ABRIR'),
  ('ESQUADRIAS','PORTA 90X210 ALUMÍNIO ABRIR'),
  ('ESQUADRIAS','PORTA 200X210 VIDRO + ALUMÍNIO CORRER'),
  ('ESQUADRIAS','PORTÃO GARAGEM 240X210 CORRER'),
  ('ESQUADRIAS','PORTA GUARITA 90X210 ABRIR'),
  ('ESQUADRIAS','PORTÃO GÁS 70X60 ABRIR'),
  ('ESQUADRIAS','CORRIMÃO ESCADA 420'),
  ('ESQUADRIAS','CORRIMÃO VARANDA 350'),
  ('ELÉTRICA','CAIXINHA PARA LAJE'),
  ('ELÉTRICA','ELETRODUTO FLEXÍVEL 3/4'),
  ('ELÉTRICA','LUVA DE PRESSÃO 3/4'),
  ('ELÉTRICA','CAIXINHA 4X2'),
  ('ELÉTRICA','CABO 2,5MM AZUL'),
  ('ELÉTRICA','CABO 2,5MM VERDE'),
  ('ELÉTRICA','CABO 2,5MM VERMELHO'),
  ('ELÉTRICA','CABO 1,5MM BRANCO'),
  ('ELÉTRICA','CABO 1,5MM PRETO'),
  ('ELÉTRICA','CABO 6MM AZUL'),
  ('ELÉTRICA','CABO 6MM VERDE'),
  ('ELÉTRICA','CABO 6MM VERMELHO'),
  ('ELÉTRICA','TOMADA DUPLA'),
  ('ELÉTRICA','TOMADA SIMPLES'),
  ('ELÉTRICA','PLAFON SOQUETE'),
  ('ELÉTRICA','INTERRUPTOR + TOMADA (1+1)'),
  ('ELÉTRICA','INTERRUPTOR DUPLO'),
  ('ELÉTRICA','INTERRUPTOR THREE-WAY'),
  ('ELÉTRICA','INTERRUPTOR SIMPLES'),
  ('ELÉTRICA','LUMINÁRIA TIPO TARTARUGA'),
  ('ELÉTRICA','TAMPA CEGA'),
  ('ELÉTRICA','DR 40A'),
  ('ELÉTRICA','DISJUNTOR 10A'),
  ('ELÉTRICA','DISJUNTOR 16A'),
  ('ELÉTRICA','DISJUNTOR 20A'),
  ('ELÉTRICA','DISJUNTOR 32A'),
  ('ELÉTRICA','QUADRO ELÉTRICO 8 DISJUNTORES'),
  ('ELÉTRICA','QUADRO ENEL'),
  ('ELÉTRICA','TUBO RÍGIDO 3/4'),
  ('ELÉTRICA','CURVA ELETRODUTO 3/4'),
  ('ELÉTRICA','LUVA 3/4'),
  ('ELÉTRICA','MINI POSTE'),
  ('ELÉTRICA','ROLDANA DE LOUÇA'),
  ('ELÉTRICA','HASTE DE ATERRAMENTO'),
  ('ELÉTRICA','RACK ELÉTRICO'),
  ('ELÉTRICA','TUBO RÍGIDO 1 1/2'),
  ('ELÉTRICA','LUVA 1 1/2'),
  ('ACABAMENTOS','CERÂMICA CERBRAS AURORA'),
  ('ACABAMENTOS','ARGAMASSA AC2'),
  ('ACABAMENTOS','REJUNTE PLATINA'),
  ('ACABAMENTOS','SOLEIRA 0,65X0,05'),
  ('ACABAMENTOS','SOLEIRA 1,00X0,05'),
  ('ACABAMENTOS','SOLEIRA 1,80X0,20'),
  ('ACABAMENTOS','SOLEIRA 1,20X0,05'),
  ('ACABAMENTOS','PEITORIL 1,05X0,18'),
  ('ACABAMENTOS','PEITORIL 0,65X0,18'),
  ('ACABAMENTOS','PEITORIL 1,25X0,18'),
  ('ACABAMENTOS','PEITORIL 0,90X0,10'),
  ('ACABAMENTOS','BALCÃO 1,05X0,35'),
  ('TINTAS','TINTA LÁTEX BRANCO NEVE'),
  ('TINTAS','TEXTURA BRANCO GELO INTERNO'),
  ('TINTAS','TEXTURA CINZA CLARO EXTERNO'),
  ('TINTAS','TEXTURA VERDE EXTERNO'),
  ('TINTAS','TEXTURA BRANCO NEVE'),
  ('TINTAS','SELADOR'),
  ('TINTAS','LIXA'),
  ('TINTAS','MASSA CORRIDA'),
  ('TINTAS','IGLOFLEX'),
  ('MADEIREIRA / FÔRMAS','PREGO 2,5 X 10'),
  ('MADEIREIRA / FÔRMAS','ARAME RECOZIDO'),
  ('MADEIREIRA / FÔRMAS','TÁBUA 20CM'),
  ('MADEIREIRA / FÔRMAS','TÁBUA 30CM'),
  ('MADEIREIRA / FÔRMAS','BARROTE'),
  ('COBERTA','LINHA 7,50M MAÇARANDUBA'),
  ('COBERTA','LINHA 5,50M MISTA'),
  ('COBERTA','CAIBRO 5M MISTO'),
  ('COBERTA','RIPA MISTA (METRO)'),
  ('COBERTA','BEIRAL 6M MISTO'),
  ('HIDRÁULICA - ÁGUA', 'LUVA 25MM'),
  ('HIDRÁULICA - ESGOTO', 'JOELHO 75MM (ESGOTO)'),
  ('HIDRÁULICA - ESGOTO', 'TÊ 75X50MM (ESGOTO)'),
  ('OUTROS', 'PORTA CARTA')
) v where not exists (select 1 from materiais)
on conflict (nome) do nothing;

insert into crono_pesos (setor, peso) select g, 7.69 from generate_series(0, 12) g on conflict do nothing;

-- Materiais do modelo que bancos antigos ainda não tinham (só junto com a primeira carga do modelo)
insert into materiais (categoria, nome) select * from (values
  ('HIDRÁULICA - ÁGUA', 'LUVA 25MM'),
  ('HIDRÁULICA - ESGOTO', 'JOELHO 75MM (ESGOTO)'),
  ('HIDRÁULICA - ESGOTO', 'TÊ 75X50MM (ESGOTO)'),
  ('OUTROS', 'PORTA CARTA')
) v where not exists (select 1 from modelo_bloco)
on conflict (nome) do nothing;

-- Modelo de 1 bloco (4 apartamentos): planilha LEVANTAMENTO; preço de referência: planilha do PEDIDO.
-- Não sobrescreve o que você já alterou no sistema.
insert into modelo_bloco (material, quantidade, unidade, preco_ref, ordem) select * from (values
  ('LONA', 1, 'RL', null, 1),
  ('ARGAMASSA POLIMÉRICA', 30, 'CX', 94.29, 2),
  ('VEDAPREN PAREDE', 4, 'BALDE', null, 3),
  ('BROCHAS', 10, 'UN', 6.15, 4),
  ('JANELA 60X60 ALUMÍNIO MAXIM-AR', 4, 'UN', null, 5),
  ('JANELA 100X60 ALUMÍNIO CORRER', 4, 'UN', null, 6),
  ('JANELA 120X100 ALUMÍNIO CORRER', 8, 'UN', null, 7),
  ('PORTA 60X210 ALUMÍNIO ABRIR', 8, 'UN', null, 8),
  ('PORTA 80X210 ALUMÍNIO ABRIR', 8, 'UN', null, 9),
  ('PORTA 90X210 ALUMÍNIO ABRIR', 2, 'UN', null, 10),
  ('PORTA 200X210 VIDRO + ALUMÍNIO CORRER', 4, 'UN', null, 11),
  ('PORTÃO GARAGEM 240X210 CORRER', 4, 'UN', null, 12),
  ('PORTA GUARITA 90X210 ABRIR', 1, 'UN', null, 13),
  ('PORTÃO GÁS 70X60 ABRIR', 4, 'UN', null, 14),
  ('CORRIMÃO ESCADA 420', 2, 'UN', null, 15),
  ('CORRIMÃO VARANDA 350', 2, 'UN', null, 16),
  ('CAIXINHA PARA LAJE', 34, 'UN', 2.584, 17),
  ('ELETRODUTO FLEXÍVEL 3/4', 16, 'UN', 72.38, 18),
  ('LUVA DE PRESSÃO 3/4', 60, 'UN', 0.71, 19),
  ('CAIXINHA 4X2', 167, 'UN', 0.61, 20),
  ('CABO 2,5MM AZUL', 4, 'UN', null, 21),
  ('CABO 2,5MM VERDE', 4, 'UN', null, 22),
  ('CABO 2,5MM VERMELHO', 4, 'UN', null, 23),
  ('CABO 1,5MM BRANCO', 4, 'UN', null, 24),
  ('CABO 1,5MM PRETO', 4, 'UN', null, 25),
  ('CABO 6MM AZUL', 2, 'UN', null, 26),
  ('CABO 6MM VERDE', 2, 'UN', null, 27),
  ('CABO 6MM VERMELHO', 2, 'UN', null, 28),
  ('TOMADA DUPLA', 50, 'UN', null, 29),
  ('TOMADA SIMPLES', 27, 'UN', null, 30),
  ('PLAFON SOQUETE', 37, 'UN', null, 31),
  ('INTERRUPTOR + TOMADA (1+1)', 7, 'UN', null, 32),
  ('INTERRUPTOR DUPLO', 5, 'UN', null, 33),
  ('INTERRUPTOR THREE-WAY', 2, 'UN', null, 34),
  ('INTERRUPTOR SIMPLES', 20, 'UN', null, 35),
  ('LUMINÁRIA TIPO TARTARUGA', 8, 'UN', null, 36),
  ('TAMPA CEGA', 54, 'UN', null, 37),
  ('DR 40A', 5, 'UN', null, 38),
  ('DISJUNTOR 10A', 5, 'UN', null, 39),
  ('DISJUNTOR 16A', 9, 'UN', null, 40),
  ('DISJUNTOR 20A', 12, 'UN', null, 41),
  ('QUADRO ELÉTRICO 8 DISJUNTORES', 5, 'UN', 26.13, 42),
  ('QUADRO ENEL', 5, 'UN', 37.99, 43),
  ('TUBO RÍGIDO 3/4', 87, 'UN', 12.02, 44),
  ('CURVA ELETRODUTO 3/4', 27, 'UN', 2.08, 45),
  ('LUVA 3/4', 80, 'UN', 0.62, 46),
  ('MINI POSTE', 5, 'UN', 19.32, 47),
  ('DISJUNTOR 32A', 2, 'UN', null, 48),
  ('ROLDANA DE LOUÇA', 6, 'UN', 4.96, 49),
  ('HASTE DE ATERRAMENTO', 9, 'UN', 8.26, 50),
  ('RACK ELÉTRICO', 1, 'UN', null, 51),
  ('TUBO RÍGIDO 1 1/2', 5, 'UN', 25.47, 52),
  ('LUVA 1 1/2', 4, 'UN', 3.88, 53),
  ('LAJE', 267, 'M²', null, 54),
  ('CHAPIM', 45, 'UN', null, 55),
  ('VERGAS 1M', 14, 'UN', null, 56),
  ('VERGAS 1,5M', 24, 'UN', null, 57),
  ('VERGAS 2,5M', 8, 'UN', null, 58),
  ('TAMPA + SUBTAMPA 60X60 FURADA ÁGUA', 4, 'UN', null, 59),
  ('TAMPA + SUBTAMPA 60X60 ESGOTO', 4, 'UN', null, 60),
  ('TAMPA + SUBTAMPA 70X70 FOSSA', 1, 'UN', null, 61),
  ('TAMPA + SUBTAMPA 60X60 FILTRO', 1, 'UN', null, 62),
  ('TAMPA + SUBTAMPA 60X60 SUMIDOURO', 1, 'UN', null, 63),
  ('TAMPA + SUBTAMPA 40X40', 4, 'UN', null, 64),
  ('ANÉIS DE 1,2M', 6, 'UN', null, 65),
  ('TAMPA PERFURADA 1,2M', 1, 'UN', null, 66),
  ('TAMPA 1,2M', 2, 'UN', null, 67),
  ('JOELHO 25MM', 76, 'UN', 0.57, 68),
  ('TÊ 25MM', 44, 'UN', 0.85, 69),
  ('JOELHO 25MM X 1/2 LATÃO', 20, 'UN', 4.3, 70),
  ('TÊ 25MM X 1/2 LATÃO', 12, 'UN', 7.21, 71),
  ('JOELHO 25MM X 45°', 12, 'UN', null, 72),
  ('ADAPTADOR 25MM X 3/4', 16, 'UN', 0.6, 73),
  ('REGISTRO DE PRESSÃO', 5, 'UN', 8.97, 74),
  ('REDUÇÃO 32X25MM', 12, 'UN', 0.96, 75),
  ('REGISTRO GAVETA', 8, 'UN', 46.84, 76),
  ('BUJÃO 1/2', 16, 'UN', 0.66, 77),
  ('REDUÇÃO 40X25MM', 4, 'UN', 3.37, 78),
  ('FLANGE 50MM', 4, 'UN', 8.56, 79),
  ('FLANGE 32MM', 8, 'UN', 6.38, 80),
  ('FLANGE 25MM X 3/4', 4, 'UN', 4.97, 81),
  ('TÊ 50MM (ÁGUA)', 12, 'UN', 6.89, 82),
  ('JOELHO 50MM (ÁGUA)', 8, 'UN', 3.27, 83),
  ('TÊ 32MM', 8, 'UN', 3.59, 84),
  ('JOELHO 32MM', 20, 'UN', 1.82, 85),
  ('REDUÇÃO 50X32MM', 8, 'UN', 4.51, 86),
  ('BOIA', 4, 'UN', 8.25, 87),
  ('CANO 25MM', 36, 'UN', 18.05, 88),
  ('CANO 32MM', 14, 'UN', 41.38, 89),
  ('CANO 50MM (ÁGUA)', 4, 'UN', 69.3, 90),
  ('CAIXA D''ÁGUA', 4, 'UN', null, 91),
  ('REGISTRO FECHO RÁPIDO 50MM', 4, 'UN', 19.42, 92),
  ('REGISTRO FECHO RÁPIDO 32MM', 4, 'UN', 10.06, 93),
  ('JOELHO 32MM X 45°', 4, 'UN', 3.71, 94),
  ('CAP 32MM', 9, 'UN', 1.97, 95),
  ('CAP 25MM', 9, 'UN', 1.16, 96),
  ('LUVA 32MM', 9, 'UN', 2.13, 97),
  ('LUVA 25MM', 9, 'UN', 0.61, 98),
  ('JOELHO 50MM (ESGOTO)', 16, 'UN', 2.06, 99),
  ('JOELHO 40MM', 48, 'UN', 1.0, 100),
  ('TÊ 50MM (ESGOTO)', 4, 'UN', 4.94, 101),
  ('TÊ 40MM', 12, 'UN', 2.22, 102),
  ('JOELHO 45° 40MM', 24, 'UN', null, 103),
  ('JOELHO 45° 50MM', 16, 'UN', 2.52, 104),
  ('REDUÇÃO 50X40MM', 32, 'UN', 1.66, 105),
  ('LUVA 50MM', 16, 'UN', 2.25, 106),
  ('JOELHO 100MM', 12, 'UN', 4.41, 107),
  ('JUNÇÃO 100X50MM', 8, 'UN', 12.97, 108),
  ('LUVA 100MM', 12, 'UN', 4.08, 109),
  ('CAIXA SIFONADA 150MM', 4, 'UN', 14.35, 110),
  ('CAIXA SIFONADA 100MM', 12, 'UN', 8.92, 111),
  ('LUVA 40MM', 7, 'UN', 1.27, 112),
  ('TÊ 100MM', 9, 'UN', 10.35, 113),
  ('JOELHO 45° 100MM', 8, 'UN', 6.4, 114),
  ('CANO 100MM', 16, 'UN', 68.9, 115),
  ('CANO 75MM', 4, 'UN', 69.15, 116),
  ('CANO 50MM (ESGOTO)', 9, 'UN', 54.25, 117),
  ('CANO 40MM', 12, 'UN', 30.55, 118),
  ('COLA 900ML', 4, 'UN', 40.36, 119),
  ('VEDA ROSCA', 4, 'UN', 2.11, 120),
  ('CAIXA DE GORDURA', 4, 'UN', 104.47, 121),
  ('CAIXA DE SABÃO', 4, 'UN', 113.15, 122),
  ('JUNÇÃO 50X50MM', 12, 'UN', 6.98, 123),
  ('TUBO 150MM', 1, 'UN', 172.93, 124),
  ('SANITÁRIO COM CAIXA ACOPLADA DUPLO ACIONAMENTO', 4, 'UN', null, 125),
  ('ANEL DE VEDAÇÃO', 4, 'UN', null, 126),
  ('KIT PARAFUSOS SANITÁRIO', 8, 'UN', null, 127),
  ('ENGATE 60CM', 13, 'UN', null, 128),
  ('SIFÃO', 13, 'UN', null, 129),
  ('TORNEIRA BANCADA WC', 4, 'UN', null, 130),
  ('VÁLVULA PIA', 4, 'UN', null, 131),
  ('CHUVEIRO WC', 4, 'UN', null, 132),
  ('TORNEIRA BANCADA COZINHA PAREDE', 5, 'UN', null, 133),
  ('VÁLVULA TANQUE COZINHA', 5, 'UN', null, 134),
  ('TANQUE LAVA-ROUPAS 0,50 X 0,50', 4, 'UN', null, 135),
  ('VÁLVULA PARA TANQUE', 4, 'UN', null, 136),
  ('TORNEIRA TANQUE PAREDE', 4, 'UN', null, 137),
  ('CHUVEIRÃO', 1, 'UN', null, 138),
  ('BANCADA COZINHA 1,20M', 5, 'UN', null, 139),
  ('BANCADA WC', 4, 'UN', null, 140),
  ('CERÂMICA CERBRAS AURORA', 410, 'M²', null, 141),
  ('ARGAMASSA AC2', 200, 'PCT', null, 142),
  ('REJUNTE PLATINA', 47, 'KG', null, 143),
  ('SOLEIRA 0,65X0,05', 8, 'UN', null, 144),
  ('SOLEIRA 1,00X0,05', 16, 'UN', null, 145),
  ('SOLEIRA 1,80X0,20', 4, 'UN', null, 146),
  ('SOLEIRA 1,20X0,05', 4, 'UN', null, 147),
  ('PEITORIL 1,05X0,18', 4, 'UN', null, 148),
  ('PEITORIL 0,65X0,18', 4, 'UN', null, 149),
  ('PEITORIL 1,25X0,18', 8, 'UN', null, 150),
  ('PEITORIL 0,90X0,10', 2, 'UN', null, 151),
  ('BALCÃO 1,05X0,35', 4, 'UN', null, 152),
  ('TINTA LÁTEX BRANCO NEVE', 5, 'UN', null, 153),
  ('TEXTURA BRANCO GELO INTERNO', 25, 'UN', null, 154),
  ('TEXTURA CINZA CLARO EXTERNO', 25, 'UN', null, 155),
  ('TEXTURA VERDE EXTERNO', 5, 'UN', null, 156),
  ('TEXTURA BRANCO NEVE', 4, 'UN', null, 157),
  ('SELADOR', 10, 'UN', null, 158),
  ('LIXA', 4, 'PCT', null, 159),
  ('MASSA CORRIDA', 4, 'PCT', null, 160),
  ('IGLOFLEX', 4, 'UN', null, 161),
  ('PREGO 2,5 X 10', 5, 'KG', 14.64, 162),
  ('ARAME RECOZIDO', 7, 'KG', 11.47, 163),
  ('TÁBUA 20CM', 10, 'UN', null, 164),
  ('TÁBUA 30CM', 7, 'UN', null, 165),
  ('BARROTE', 27, 'UN', null, 166),
  ('LINHA 7,50M MAÇARANDUBA', 4, 'UN', null, 167),
  ('LINHA 5,50M MISTA', 20, 'UN', null, 168),
  ('CAIBRO 5M MISTO', 127, 'UN', null, 169),
  ('RIPA MISTA (METRO)', 634, 'M', null, 170),
  ('BEIRAL 6M MISTO', 10, 'UN', null, 171),
  ('JOELHO 75MM (ESGOTO)', 4, 'UN', 4.1, 172),
  ('PORTA CARTA', 5, 'UN', 15.56, 173),
  ('TÊ 75X50MM (ESGOTO)', 4, 'UN', 13.21, 174)
) v where not exists (select 1 from modelo_bloco)
on conflict (material) do nothing;

insert into parametros (chave, valor) values ('perda_padrao', 5) on conflict (chave) do nothing;

-- ----------------------------------------------------------------------------
-- 9) PLANILHA GOOGLE DO CRONOGRAMA (o app atualiza a planilha sozinho)
--    A cada marcação no Cronograma, o banco manda o andamento da obra para o programa
--    (Apps Script) da planilha, que escreve as letras A/B/C/D nas células.
--    A ligação de cada obra (endereço + chave secreta) é cadastrada à parte, fora deste arquivo.
-- ----------------------------------------------------------------------------
do $$ begin create extension if not exists pg_net;              -- permite ao banco chamar um endereço da internet
exception when others then raise notice 'pg_net indisponível: a planilha não será atualizada'; end $$;

create table if not exists planilhas_obra (
  obra text primary key references crono_obras(nome) on update cascade on delete cascade,
  url text not null,                      -- endereço do Apps Script publicado como "App da Web"
  segredo text not null,                  -- mesma chave escrita no Apps Script
  ativo boolean not null default true
);
alter table planilhas_obra enable row level security;           -- sem regras de acesso: o site não lê a chave

-- Envia o andamento completo da(s) obra(s) para a planilha (o programa da planilha usa os blocos que ela tiver)
create or replace function sincronizar_planilhas(so_obra text default null) returns int
language plpgsql security definer set search_path = public as $$
declare p record; n int := 0;
begin
  for p in select * from planilhas_obra where ativo and (so_obra is null or obra = so_obra) loop
    perform net.http_post(
      url := p.url,
      body := jsonb_build_object('segredo', p.segredo, 'obra', p.obra,
        'marcas', coalesce((select jsonb_agg(jsonb_build_array(setor, item, apto, nivel)) from crono_status where obra = p.obra), '[]'::jsonb)),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 30000);
    n := n + 1;
  end loop;
  return n;
end $$;
-- só o próprio banco chama esta função (o site não consegue)
do $$ declare r text; begin
  revoke all on function sincronizar_planilhas(text) from public;
  for r in select rolname from pg_roles where rolname in ('anon', 'authenticated') loop
    execute format('revoke all on function sincronizar_planilhas(text) from %I', r);
  end loop;
end $$;

-- Depois de cada marcação (uma vez por gravação, mesmo marcando vários aptos de uma vez).
-- Se a planilha falhar, a marcação no app continua valendo normalmente.
create or replace function crono_status_planilha() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin perform sincronizar_planilhas(); exception when others then raise warning 'planilha: %', sqlerrm; end;
  return null;
end $$;
drop trigger if exists crono_status_planilha on crono_status;
create trigger crono_status_planilha after insert or update or delete on crono_status
  for each statement execute function crono_status_planilha();

-- Avisa o Supabase para recarregar a lista de tabelas (evita o erro "schema cache")
notify pgrst, 'reload schema';
