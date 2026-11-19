-- ============================================================================
-- SISTEMA TMC ENGENHARIA | Banco único (Supabase / PostgreSQL)
-- Prestação de Contas + Folha de Ponto no mesmo projeto.
-- Cole TUDO no SQL Editor e clique em RUN. Pode rodar de novo sem problema.
-- Seus lançamentos e fotos da Prestação de Contas NÃO são apagados.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) PRESTAÇÃO DE CONTAS (já existe no seu projeto; aqui só garante que está tudo)
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
create table if not exists comprovantes (
  id bigint generated always as identity primary key,
  lancamento_id bigint not null references lancamentos(id) on delete cascade,
  caminho text not null unique,
  criado_em timestamptz not null default now()
);
create index if not exists lancamentos_data_idx on lancamentos (data desc);
create index if not exists lancamentos_obra_idx on lancamentos (obra);
create index if not exists comprovantes_lanc_idx on comprovantes (lancamento_id);

insert into obras (nome) values ('Jabuti Park'),('Jabuti Gardem'),('Jabuti Casas'),('Residencial 2'),('Village 1'),('Village 2') on conflict do nothing;
insert into categorias (nome) values ('Material'),('Ferramentas'),('Elétrica'),('Hidráulica'),('Acabamento'),('Transporte'),('Mão de obra'),('Outros') on conflict do nothing;
insert into caixa (id, recebido) values (1, 0) on conflict do nothing;

-- Espaço privado das fotos (limite 5 MB por foto)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprovantes', 'comprovantes', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

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

-- ----------------------------------------------------------------------------
-- 3) USUÁRIOS E PERMISSÕES
--    Cada usuário criado em Authentication > Users ganha uma linha em "perfis".
--    Níveis por página: 'nenhum' (não entra) | 'ver' (só visualiza) | 'editar'
-- ----------------------------------------------------------------------------
create table if not exists perfis (
  id uuid primary key references auth.users on delete cascade,
  email text,
  nome text,
  folha text not null default 'nenhum' check (folha in ('nenhum','ver','editar')),
  prestacao text not null default 'nenhum' check (prestacao in ('nenhum','ver','editar'))
);

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

create or replace function pode_ver_modulo(modulo text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case modulo when 'folha' then folha when 'prestacao' then prestacao end
                   from perfis where id = auth.uid()), 'nenhum') <> 'nenhum' $$;
create or replace function pode_editar_modulo(modulo text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case modulo when 'folha' then folha when 'prestacao' then prestacao end
                   from perfis where id = auth.uid()), 'nenhum') = 'editar' $$;

-- ----------------------------------------------------------------------------
-- 4) SEGURANÇA (RLS): o próprio banco barra quem não tem permissão
-- ----------------------------------------------------------------------------
-- remove as regras antigas (a função antiga pode_editar() deixa de ser usada)
do $$ declare p record; begin
  for p in select schemaname, tablename, policyname from pg_policies
           where schemaname = 'public' and tablename in ('obras','categorias','lancamentos','caixa','comprovantes','quinzenas','funcionarios_quinzena','pontos','perfis')
  loop execute format('drop policy %I on %I.%I', p.policyname, p.schemaname, p.tablename); end loop;
end $$;
drop policy if exists "logado le comprovantes" on storage.objects;
drop policy if exists "logado envia comprovantes" on storage.objects;
drop policy if exists "logado apaga comprovantes" on storage.objects;
drop policy if exists "envia comprovantes" on storage.objects;
drop policy if exists "apaga comprovantes" on storage.objects;
drop policy if exists "tmc le comprovantes" on storage.objects;
drop policy if exists "tmc envia comprovantes" on storage.objects;
drop policy if exists "tmc apaga comprovantes" on storage.objects;

alter table perfis enable row level security;
create policy "ver proprio perfil" on perfis for select to authenticated using (id = auth.uid());

do $$ declare t text; m text; begin
  for t, m in select * from (values
      ('quinzenas','folha'), ('funcionarios_quinzena','folha'), ('pontos','folha'),
      ('obras','prestacao'), ('categorias','prestacao'), ('lancamentos','prestacao'),
      ('caixa','prestacao'), ('comprovantes','prestacao')) v(t, m)
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "ver %1$s" on %1$I for select to authenticated using (pode_ver_modulo(%2$L))', t, m);
    execute format('create policy "alterar %1$s" on %1$I for all to authenticated using (pode_editar_modulo(%2$L)) with check (pode_editar_modulo(%2$L))', t, m);
  end loop;
end $$;

-- Fotos (storage): vê quem vê a Prestação de Contas; envia/apaga só quem edita
create policy "tmc le comprovantes" on storage.objects for select to authenticated
  using (bucket_id = 'comprovantes' and pode_ver_modulo('prestacao'));
create policy "tmc envia comprovantes" on storage.objects for insert to authenticated
  with check (bucket_id = 'comprovantes' and pode_editar_modulo('prestacao'));
create policy "tmc apaga comprovantes" on storage.objects for delete to authenticated
  using (bucket_id = 'comprovantes' and pode_editar_modulo('prestacao'));

-- ----------------------------------------------------------------------------
-- 5) QUEM PODE O QUÊ
--    1) Crie os usuários em Authentication > Users (e-mail + senha).
--    2) Troque cada EMAIL_... abaixo pelo e-mail real e rode este bloco de novo.
-- ----------------------------------------------------------------------------
update perfis set nome = 'Irisvan',   folha = 'editar', prestacao = 'editar'  where lower(email) = lower('irisvan.van100@gmail.com');
update perfis set nome = 'Antônio',   folha = 'ver',    prestacao = 'nenhum'  where lower(email) = lower('antonio@tmc.com');
update perfis set nome = 'Tatiane',   folha = 'editar', prestacao = 'nenhum'  where lower(email) = lower('tatiane@tmc.com');
update perfis set nome = 'Tiago',     folha = 'ver',    prestacao = 'nenhum'  where lower(email) = lower('tiago@tmc.com');
update perfis set nome = 'Dona Clea', folha = 'nenhum', prestacao = 'ver'     where lower(email) = lower('donaclea@tmc.com');

-- Conferir quem tem acesso:  select nome, email, folha, prestacao from perfis order by nome;
