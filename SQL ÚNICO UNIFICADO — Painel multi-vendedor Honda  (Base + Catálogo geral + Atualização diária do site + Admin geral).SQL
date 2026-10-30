-- =====================================================================================================
--  SQL ÚNICO UNIFICADO — Painel multi-vendedor Honda  (Base + Catálogo geral + Atualização diária do site + Admin geral)
--
--  COMO USAR: Supabase > SQL Editor > New query > colar TUDO > Run.  (uma vez; pode rodar de novo sem medo)
--  Antes (recomendado): Database > Extensions > ativar  pg_cron  e  pg_net  (para a atualização diária do site).
--  No fim, a tela mostra um CHECKLIST: todas as linhas devem aparecer como OK.
--
--  O que este arquivo faz, em ordem:
--    1) BASE: tabelas dos vendedores, motos, leads, fichas, contratos, pedidos do chat (com a cor da moto), RLS, storage, bot do Telegram
--    2) CATÁLOGO GERAL: um cadastro único de motos para todos os vendedores; consórcio travado (valores do site oficial);
--       cores por moto; suspensão de moto; admin geral e ADMIN GERAL definido: filipecapelasso27@gmail.com (login e senha criados no passo 14 da parte 2)
--    3) ATUALIZAÇÃO DIÁRIA do site vendedor.site/shayrondahonda (04:00 Rio Branco) com histórico e trava de segurança
--    4) ADMIN GERAL: vendedores (perfil, criar, senha, suspender), pedidos de todos os clientes e ranking
--    + PREENCHIMENTO EM ANDAMENTO: o que o cliente digita nos formulários já chega ao vendedor e ao admin geral, mesmo sem clicar em Enviar
--
--  Pode apagar os scripts antigos salvos no editor: eles são só texto. As tabelas e os dados NÃO são afetados.
--  NÃO coloque tokens/senhas dentro deste arquivo. Para ligar o bot, rode à parte: select public.ativar_bot('TOKEN_NOVO','CHAT_ID');
-- =====================================================================================================














































-- #####################################################################################################
-- #####  1/4 · BASE (inclui personalização do site, preenchimento em andamento, fases da venda, cofre de senhas e checkup de entrega)
-- #####################################################################################################

-- =====================================================================
--  SCRIPT 01 · BASE: MULTI-VENDEDOR COM ISOLAMENTO TOTAL (RLS) + Vitrine + Ficha + Pré-contrato + BOT TELEGRAM (v11)
--  v10: remove triggers antigos que bloqueavam a cópia do catálogo (erro "Sem permissão para gravar neste vendedor"),
--       copia o catálogo modelo (motos, motores, fotos, descrição, preços, consórcio, financiamento) para todo vendedor novo
--       e para os que estão sem motos. Depois da cópia, cada vendedor mexe só nas linhas dele.
--  Rode no Supabase: SQL Editor > New query > colar tudo > Run.
--  Pode rodar de novo sem medo (idempotente). Compatível com os 3 index.html limpos.
--
--  MODELO DE SEGURANÇA
--   * 1 vendedor = 1 usuário em auth.users + 1 linha em public.vendedores (slug único).
--   * Todo dado de negócio carrega vendedor_id. O vendedor_id NUNCA vem do navegador:
--     é preenchido por trigger a partir (a) do cabeçalho x-vendedor (site público) ou
--     (b) do login (painel). Qualquer valor enviado pelo cliente é sobrescrito.
--   * Painel: acesso = (login é dono da linha) E (cabeçalho do site == esse vendedor).
--     Logo, o vendedor A logado no site do B não enxerga nada de A nem de B.
--   * Público (anon): só INSERE leads/fichas/contratos/pedidos e LÊ motos ativas do slug.
--   * Dono da plataforma (tabela donos): só gerencia a tabela vendedores. Não lê leads.
-- =====================================================================

-- ---------- 0. EXTENSÃO (aviso por Telegram) ----------
do $$ begin create extension if not exists pg_net; exception when others then
  raise notice 'pg_net indisponível: avisos do Telegram ficam desativados'; end $$;

-- ---------- 1. TABELAS ----------
create table if not exists public.vendedores(
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique not null references auth.users(id) on delete cascade,
  slug text unique not null,
  nome text not null default 'Vendedor',
  created_at timestamptz not null default now());
alter table public.vendedores
  add column if not exists bio text, add column if not exists whatsapp text,
  add column if not exists instagram text, add column if not exists facebook text,
  add column if not exists foto_url text, add column if not exists logo_url text,
  add column if not exists suspenso boolean not null default false;
-- config: personalização do site de cada vendedor (textos, horário/endereço, vídeos, fotos de entrega/contemplação).
--         É PÚBLICO (aparece no site): não guarde segredos aqui. Limite de tamanho para ninguém lotar o banco.
alter table public.vendedores add column if not exists config jsonb default '{}'::jsonb;
update public.vendedores set config = '{}'::jsonb where config is null;
do $$ begin
  alter table public.vendedores add constraint vendedores_config_tam check (config is null or octet_length(config::text) <= 30000);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.vendedores add constraint vendedores_slug_fmt
    check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) between 3 and 40);
exception when duplicate_object then null; end $$;
-- o endereço do vendedor é site.com/NOME: nomes que já são caminhos do sistema (api, admin, index...) são reservados
do $$ begin
  alter table public.vendedores add constraint vendedores_slug_reservado
    check (slug !~ '^(api|admin|admingeral|index|ficha|contrato|cdc|cnh|vitrine|termos|og|vercel|static|assets|public|favicon|robots|sitemap|login|painel|www|app)$');
exception when duplicate_object then null; end $$;

create table if not exists public.donos(user_id uuid primary key references auth.users(id) on delete cascade);

create table if not exists public.vendedor_segredos(   -- segredos: nenhuma policy = invisível pela API
  vendedor_id uuid primary key references public.vendedores(id) on delete cascade,
  telegram_token text, telegram_chat_id text);

create table if not exists public.motos(
  id uuid primary key default gen_random_uuid(),
  vendedor_id uuid references public.vendedores(id) on delete cascade,
  nome text not null, modelo text, categoria text, selo text, preco numeric, descricao text,
  fotos jsonb not null default '[]', video_url text, planos jsonb not null default '[]',
  emplacamento text, ordem int not null default 0, ativo boolean not null default true,
  created_at timestamptz not null default now());

create table if not exists public.leads(
  id uuid primary key default gen_random_uuid(),
  vendedor_id uuid references public.vendedores(id) on delete cascade,
  tipo text, moto_id text, moto_nome text, nome text, telefone text, cpf text, nascimento text,
  entrada text, habilitacao text, detalhes text, created_at timestamptz not null default now());

create table if not exists public.fichas(
  id uuid primary key default gen_random_uuid(),
  vendedor_id uuid references public.vendedores(id) on delete cascade,
  moto_id text, moto_nome text, nome text, nascimento text, cidade_nascimento text, pai text, mae text,
  telefone text, email text, cpf text, rg text, rg_emissao text, cep text, rua text, numero text,
  bairro text, cidade text, estado text, ref_nome text, ref_telefone text, ocupacao text, renda text,
  entrada text, habilitacao text, lgpd_aceite boolean not null default false,
  status text not null default 'novo' check (status in ('novo','em_analise','aprovado','recusado')),
  created_at timestamptz not null default now());

create table if not exists public.contratos(
  id uuid primary key default gen_random_uuid(),
  vendedor_id uuid references public.vendedores(id) on delete cascade,
  moto_id text, moto_nome text, nome text, telefone text, email text, cpf text, rg text, rg_emissao text,
  nascimento text, cidade_nascimento text, pai text, mae text, cep text, rua text, numero text,
  bairro text, cidade text, estado text, telefone_recado text, ocupacao text, renda text,
  lance text, lance_valor text, lgpd_aceite boolean not null default false,
  status text not null default 'novo'
    check (status in ('novo','em_analise','contrato_enviado','assinado','recusado')),
  created_at timestamptz not null default now());

create table if not exists public.pedidos_chat(
  id uuid primary key,                                   -- gerado pelo chat (UUID)
  vendedor_id uuid references public.vendedores(id) on delete cascade,
  completo boolean not null default false, moto_id text, moto_nome text, pagamento text,
  nome text, nome_completo text, telefone text, cpf text, nascimento text, entrada text, parcela text,
  forma_pagamento text, troca text, parcelamento_cartao text, habilitacao text, mensagem text,
  status text not null default 'novo' check (status in ('novo','atendimento','concluido','cancelado')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());

-- Se vinha de um banco antigo: garante a coluna em tabelas já existentes
alter table public.leads        add column if not exists cor text;
alter table public.fichas       add column if not exists cor text;
alter table public.contratos    add column if not exists cor text;
alter table public.pedidos_chat add column if not exists cor text;
alter table public.motos        add column if not exists vendedor_id uuid references public.vendedores(id) on delete cascade;
alter table public.leads        add column if not exists vendedor_id uuid references public.vendedores(id) on delete cascade;
alter table public.fichas       add column if not exists vendedor_id uuid references public.vendedores(id) on delete cascade;
alter table public.contratos    add column if not exists vendedor_id uuid references public.vendedores(id) on delete cascade;
alter table public.pedidos_chat add column if not exists vendedor_id uuid references public.vendedores(id) on delete cascade;

-- ---------- 1b. ALINHA OS TIPOS DAS COLUNAS (corrige tabelas criadas por versões antigas) ----------
--  Colunas de texto dos formulários que nasceram com outro tipo (data, número...) viram TEXT; o conteúdo é preservado.
--  ATENÇÃO: moto_id NÃO entra aqui. Ele é UUID de propósito (tem chave estrangeira para motos.id); a função do chat
--  (registrar_pedido_chat) cuida de gravar um UUID válido ou deixar vazio, para o pedido entrar sempre.
do $$ declare r record; begin
  for r in
    select c.table_name, c.column_name, c.data_type from information_schema.columns c
     where c.table_schema = 'public' and c.data_type not in ('text', 'character varying', 'character')
       and (c.table_name, c.column_name) in (
    ('pedidos_chat','moto_nome'),
    ('pedidos_chat','pagamento'),
    ('pedidos_chat','nome'),
    ('pedidos_chat','nome_completo'),
    ('pedidos_chat','telefone'),
    ('pedidos_chat','cpf'),
    ('pedidos_chat','nascimento'),
    ('pedidos_chat','entrada'),
    ('pedidos_chat','parcela'),
    ('pedidos_chat','forma_pagamento'),
    ('pedidos_chat','troca'),
    ('pedidos_chat','parcelamento_cartao'),
    ('pedidos_chat','habilitacao'),
    ('pedidos_chat','mensagem'),
    ('pedidos_chat','cor'),
    ('leads','tipo'),
    ('leads','moto_nome'),
    ('leads','nome'),
    ('leads','telefone'),
    ('leads','cpf'),
    ('leads','nascimento'),
    ('leads','entrada'),
    ('leads','habilitacao'),
    ('leads','detalhes'),
    ('leads','cor'),
    ('fichas','moto_nome'),
    ('fichas','nome'),
    ('fichas','nascimento'),
    ('fichas','cidade_nascimento'),
    ('fichas','pai'),
    ('fichas','mae'),
    ('fichas','telefone'),
    ('fichas','email'),
    ('fichas','cpf'),
    ('fichas','rg'),
    ('fichas','rg_emissao'),
    ('fichas','cep'),
    ('fichas','rua'),
    ('fichas','numero'),
    ('fichas','bairro'),
    ('fichas','cidade'),
    ('fichas','estado'),
    ('fichas','ref_nome'),
    ('fichas','ref_telefone'),
    ('fichas','ocupacao'),
    ('fichas','renda'),
    ('fichas','entrada'),
    ('fichas','habilitacao'),
    ('fichas','cor'),
    ('contratos','moto_nome'),
    ('contratos','nome'),
    ('contratos','telefone'),
    ('contratos','email'),
    ('contratos','cpf'),
    ('contratos','rg'),
    ('contratos','rg_emissao'),
    ('contratos','nascimento'),
    ('contratos','cidade_nascimento'),
    ('contratos','pai'),
    ('contratos','mae'),
    ('contratos','cep'),
    ('contratos','rua'),
    ('contratos','numero'),
    ('contratos','bairro'),
    ('contratos','cidade'),
    ('contratos','estado'),
    ('contratos','telefone_recado'),
    ('contratos','ocupacao'),
    ('contratos','renda'),
    ('contratos','lance'),
    ('contratos','lance_valor'),
    ('contratos','cor'))
  loop
    begin
      execute format('alter table public.%I alter column %I type text using %I::text', r.table_name, r.column_name, r.column_name);
      raise notice 'coluna %.% (era %) agora é texto', r.table_name, r.column_name, r.data_type;
    exception when others then raise notice 'NÃO consegui converter %.%: %', r.table_name, r.column_name, sqlerrm;
    end;
  end loop;
end $$;

-- ---------- 1c. FASE DA VENDA (1 a 10) em cada cliente: Prospecção, Recepção, Sondagem, Apresentação, Objeções, Acompanhamento, Fechamento, Pós-venda, Indicação, Reativação ----------
do $$ declare t text; begin
  foreach t in array array['leads', 'fichas', 'contratos', 'pedidos_chat'] loop
    execute format('alter table public.%I add column if not exists fase smallint', t);
    begin execute format('alter table public.%I add constraint %I check (fase is null or fase between 1 and 10)', t, t || '_fase_chk');
    exception when duplicate_object then null; end;
  end loop;
end $$;

create index if not exists i_motos_v  on public.motos(vendedor_id, ordem);
create index if not exists i_leads_v  on public.leads(vendedor_id, created_at desc);
create index if not exists i_fichas_v on public.fichas(vendedor_id, created_at desc);
create index if not exists i_contr_v  on public.contratos(vendedor_id, created_at desc);
create index if not exists i_ped_v    on public.pedidos_chat(vendedor_id, created_at desc);

-- ---------- 2. FUNÇÕES AUXILIARES ----------
create or replace function public.slug_ctx() returns text language sql stable as $$
  select nullif(regexp_replace(lower(btrim(coalesce(nullif(current_setting('request.headers', true),'')::json->>'x-vendedor',''))), '[^a-z0-9-]', '', 'g'), '') $$;

create or replace function public.vendedor_ctx() returns uuid language sql stable security definer set search_path=public as $$
  select id from public.vendedores where slug = public.slug_ctx() $$;

create or replace function public.meu_vendedor() returns uuid language sql stable security definer set search_path=public as $$
  select id from public.vendedores where user_id = auth.uid() $$;

create or replace function public.vendedor_ativo(vid uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.vendedores where id = vid and not suspenso) $$;

create or replace function public.eh_dono() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.donos where user_id = auth.uid()) $$;

-- Painel: login é dono do registro E o site aberto é o do mesmo vendedor E conta não suspensa
create or replace function public.pode_gerir(vid uuid) returns boolean language sql stable security definer set search_path=public as $$
  select vid is not null and vid = public.meu_vendedor() and public.vendedor_ativo(vid)
         and (public.slug_ctx() is null or vid = public.vendedor_ctx()) $$;

-- ---------- 3. TRIGGERS (vendedor_id nunca vem do navegador) ----------
create or replace function public.tg_vendedor_publico() returns trigger language plpgsql as $$
begin
  if current_user not in ('anon','authenticated') then return new; end if;  -- SQL Editor/service_role: livre
  new.vendedor_id := public.vendedor_ctx();
  if new.vendedor_id is null then raise exception 'Site sem vendedor (use o link com o nome do vendedor)'; end if;
  return new; end $$;

create or replace function public.tg_vendedor_gestor() returns trigger language plpgsql as $$
begin
  if current_user not in ('anon','authenticated') then return new; end if;
  new.vendedor_id := public.meu_vendedor();
  if new.vendedor_id is null then raise exception 'Login sem vendedor cadastrado'; end if;
  return new; end $$;

create or replace function public.tg_trava_vendedor() returns trigger language plpgsql as $$
begin
  if new.vendedor_id is distinct from old.vendedor_id then raise exception 'vendedor_id é imutável'; end if;
  return new; end $$;

create or replace function public.tg_guard_vendedores() returns trigger language plpgsql as $$
begin   -- vendedor comum só edita perfil; slug, user_id e suspensão são do dono
  if current_user in ('anon','authenticated') and not public.eh_dono() then
    new.user_id := old.user_id; new.slug := old.slug; new.suspenso := old.suspenso; new.id := old.id; end if;
  return new; end $$;

-- v10: REMOVE triggers/funções antigas de versões anteriores nas tabelas de negócio.
--      (ex.: tg_set_vendedor_admin, que barrava a cópia do catálogo). Os triggers corretos são recriados logo abaixo e nas seções 7 e 12.
drop function if exists public.tg_set_vendedor_admin() cascade;
do $$ declare r record; begin
  for r in select c.relname, t.tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid
           where c.relnamespace = 'public'::regnamespace and not t.tgisinternal and t.tgname not like 'c\_mestre%'
             and c.relname in ('motos','leads','fichas','contratos','pedidos_chat') loop
    execute format('drop trigger if exists %I on public.%I', r.tgname, r.relname);
  end loop;
end $$;

do $$ declare t text; begin
  foreach t in array array['leads','fichas','contratos'] loop
    execute format('drop trigger if exists a_vend_ins on public.%I', t);
    execute format('create trigger a_vend_ins before insert on public.%I for each row execute function public.tg_vendedor_publico()', t);
  end loop;
  foreach t in array array['motos','leads','fichas','contratos','pedidos_chat'] loop
    execute format('drop trigger if exists b_vend_upd on public.%I', t);
    execute format('create trigger b_vend_upd before update on public.%I for each row execute function public.tg_trava_vendedor()', t);
  end loop;
end $$;
drop trigger if exists a_vend_ins on public.motos;
create trigger a_vend_ins before insert on public.motos for each row execute function public.tg_vendedor_gestor();
-- remove QUALQUER trigger antigo da tabela vendedores (ex.: "Campo protegido ...") e recria só o nosso
do $$ declare r record; begin
  for r in select tgname from pg_trigger where tgrelid = 'public.vendedores'::regclass and not tgisinternal loop
    execute format('drop trigger %I on public.vendedores', r.tgname);
  end loop;
end $$;
create trigger a_guard before update on public.vendedores for each row execute function public.tg_guard_vendedores();

-- ---------- 4. VIEW PÚBLICA (só campos seguros, só o vendedor do cabeçalho) ----------
drop view if exists public.vendedor_publico;
create view public.vendedor_publico as
  select id, slug, nome, bio, whatsapp, instagram, facebook, foto_url, logo_url, suspenso, config
  from public.vendedores where slug = public.slug_ctx();   -- roda como dono da view de propósito; 1 linha no máximo
grant select on public.vendedor_publico to anon, authenticated;

-- ---------- 5. RLS: limpa policies antigas (evita brechas herdadas) e recria ----------
do $$ declare r record; begin
  for r in select schemaname, tablename, policyname from pg_policies
           where schemaname='public' and tablename in
           ('vendedores','donos','vendedor_segredos','motos','leads','fichas','contratos','pedidos_chat') loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

alter table public.vendedores         enable row level security;
alter table public.donos              enable row level security;
alter table public.vendedor_segredos  enable row level security;
alter table public.motos              enable row level security;
alter table public.leads              enable row level security;
alter table public.fichas             enable row level security;
alter table public.contratos          enable row level security;
alter table public.pedidos_chat       enable row level security;

-- vendedores
create policy v_sel on public.vendedores for select to authenticated using (user_id = auth.uid() or public.eh_dono());
create policy v_upd on public.vendedores for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy v_dono on public.vendedores for all to authenticated using (public.eh_dono()) with check (public.eh_dono());

-- motos: público lê só ativas do slug; vendedor gerencia as dele
create policy m_pub on public.motos for select to anon, authenticated
  using (ativo and vendedor_id = public.vendedor_ctx() and public.vendedor_ativo(vendedor_id));
create policy m_sel on public.motos for select to authenticated using (public.pode_gerir(vendedor_id));
create policy m_ins on public.motos for insert to authenticated with check (public.pode_gerir(vendedor_id));
create policy m_upd on public.motos for update to authenticated using (public.pode_gerir(vendedor_id)) with check (public.pode_gerir(vendedor_id));
create policy m_del on public.motos for delete to authenticated using (public.pode_gerir(vendedor_id));

-- leads / fichas / contratos: público só insere; vendedor lê/edita/apaga os dele
do $$ declare t text; begin
  foreach t in array array['leads','fichas','contratos'] loop
    execute format($f$create policy %1$s_ins on public.%1$I for insert to anon, authenticated
      with check (vendedor_id = public.vendedor_ctx() and public.vendedor_ativo(vendedor_id))$f$, t);
    execute format('create policy %1$s_sel on public.%1$I for select to authenticated using (public.pode_gerir(vendedor_id))', t);
    execute format('create policy %1$s_upd on public.%1$I for update to authenticated using (public.pode_gerir(vendedor_id)) with check (public.pode_gerir(vendedor_id))', t);
    execute format('create policy %1$s_del on public.%1$I for delete to authenticated using (public.pode_gerir(vendedor_id))', t);
  end loop;
end $$;
-- fichas e contratos exigem aceite LGPD
drop policy fichas_ins on public.fichas;
create policy fichas_ins on public.fichas for insert to anon, authenticated
  with check (lgpd_aceite and vendedor_id = public.vendedor_ctx() and public.vendedor_ativo(vendedor_id));
drop policy contratos_ins on public.contratos;
create policy contratos_ins on public.contratos for insert to anon, authenticated
  with check (lgpd_aceite and vendedor_id = public.vendedor_ctx() and public.vendedor_ativo(vendedor_id));

-- pedidos_chat: SEM insert direto; entra só pela função registrar_pedido_chat
create policy p_sel on public.pedidos_chat for select to authenticated using (public.pode_gerir(vendedor_id));
create policy p_upd on public.pedidos_chat for update to authenticated using (public.pode_gerir(vendedor_id)) with check (public.pode_gerir(vendedor_id));
create policy p_del on public.pedidos_chat for delete to authenticated using (public.pode_gerir(vendedor_id));

-- privilégios mínimos (defesa em profundidade além da RLS)
revoke all on public.vendedores, public.donos, public.vendedor_segredos, public.motos, public.leads,
              public.fichas, public.contratos, public.pedidos_chat from anon, authenticated;
grant select, update on public.vendedores to authenticated;
grant insert, delete on public.vendedores to authenticated;              -- insert/delete só passam para o dono (policy v_dono)
grant select on public.motos to anon;
grant select, insert, update, delete on public.motos, public.leads, public.fichas, public.contratos, public.pedidos_chat to authenticated;
grant insert on public.leads, public.fichas, public.contratos to anon;

-- ---------- 6. PEDIDOS DO CHAT (upsert seguro, cada pedido preso ao seu vendedor) ----------
create or replace function public.jtxt(p jsonb, k text, n int default 300) returns text language sql immutable as $$
  select left(nullif(btrim(p->>k),''), n) $$;

drop function if exists public.registrar_pedido_chat(jsonb);
create or replace function public.registrar_pedido_chat(p jsonb) returns void language plpgsql security definer set search_path=public as $$
declare v uuid := public.vendedor_ctx(); pid uuid := nullif(p->>'id','')::uuid; mid uuid;
begin
  if v is null or not public.vendedor_ativo(v) then raise exception 'Site sem vendedor'; end if;
  if pid is null then raise exception 'id obrigatório'; end if;
  -- moto_id tem chave estrangeira para motos: só vale um id de moto DESTE vendedor; qualquer outra coisa vira vazio e o pedido entra do mesmo jeito
  if jtxt(p,'moto_id',64) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select m.id into mid from public.motos m where m.id = jtxt(p,'moto_id',64)::uuid and m.vendedor_id = v;
  end if;
  insert into public.pedidos_chat as t(id, vendedor_id, completo, moto_id, moto_nome, pagamento, nome, nome_completo,
      telefone, cpf, nascimento, entrada, parcela, forma_pagamento, troca, parcelamento_cartao, habilitacao, mensagem, cor)
  values (pid, v, coalesce((p->>'completo')::boolean,false), mid, jtxt(p,'moto_nome'), jtxt(p,'pagamento',30),
      jtxt(p,'nome'), jtxt(p,'nome_completo'), jtxt(p,'telefone',30), jtxt(p,'cpf',20), jtxt(p,'nascimento',20),
      jtxt(p,'entrada',60), jtxt(p,'parcela',60), jtxt(p,'forma_pagamento',60), jtxt(p,'troca',200),
      jtxt(p,'parcelamento_cartao',60), jtxt(p,'habilitacao',30), jtxt(p,'mensagem',3000), jtxt(p,'cor',40))
  on conflict (id) do update set
      completo = excluded.completo, moto_id = coalesce(excluded.moto_id,t.moto_id), moto_nome = coalesce(excluded.moto_nome,t.moto_nome),
      pagamento = coalesce(excluded.pagamento,t.pagamento), nome = coalesce(excluded.nome,t.nome),
      nome_completo = coalesce(excluded.nome_completo,t.nome_completo), telefone = coalesce(excluded.telefone,t.telefone),
      cpf = coalesce(excluded.cpf,t.cpf), nascimento = coalesce(excluded.nascimento,t.nascimento),
      entrada = coalesce(excluded.entrada,t.entrada), parcela = coalesce(excluded.parcela,t.parcela),
      forma_pagamento = coalesce(excluded.forma_pagamento,t.forma_pagamento), troca = coalesce(excluded.troca,t.troca),
      parcelamento_cartao = coalesce(excluded.parcelamento_cartao,t.parcelamento_cartao),
      habilitacao = coalesce(excluded.habilitacao,t.habilitacao), mensagem = coalesce(excluded.mensagem,t.mensagem), cor = coalesce(excluded.cor,t.cor),
      updated_at = now()
    where t.vendedor_id = v and t.completo = false;   -- só o MESMO vendedor, e só enquanto incompleto
end $$;
revoke all on function public.registrar_pedido_chat(jsonb) from public;
grant execute on function public.registrar_pedido_chat(jsonb) to anon, authenticated;

-- ---------- 7. AVISO NO TELEGRAM (token de cada vendedor, nunca exposto) ----------
-- registros de TESTE de entrega (nome __TESTE_ENTREGA__) nunca disparam aviso no Telegram de ninguém
create or replace function public._eh_teste(t text) returns boolean language sql immutable as $$ select coalesce(t, '') like '\_\_TESTE\_ENTREGA\_\_%' escape '\' $$;

create or replace function public.tg_aviso_pedido() returns trigger language plpgsql security definer set search_path=public as $$
declare s record; ini boolean := false;
begin
  if public._eh_teste(coalesce(new.nome_completo, new.nome)) then return new; end if;
  if new.completo then
    if tg_op = 'UPDATE' and old.completo then return new; end if;
  elsif nullif(btrim(coalesce(new.telefone, '')), '') is not null and (tg_op = 'INSERT' or nullif(btrim(coalesce(old.telefone, '')), '') is null) then
    ini := true;                                   -- cliente deu o telefone no chat mas ainda não concluiu
  else return new; end if;
  select telegram_token, telegram_chat_id into s from public.vendedor_segredos where vendedor_id = new.vendedor_id;
  if s.telegram_token is null or s.telegram_chat_id is null then return new; end if;
  begin
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || s.telegram_token || '/sendMessage',
      body := jsonb_build_object('chat_id', s.telegram_chat_id, 'text',
        case when ini then 'Cliente começou o chat (ainda não concluiu)' else 'Novo pedido' end || E'\n' || coalesce(new.moto_nome,'-') || E'\n' || coalesce(new.nome_completo,new.nome,'-') ||
        E'\n' || coalesce(new.telefone,'-') || E'\n' || coalesce(new.pagamento,'-') || coalesce(E'\nCor: ' || new.cor, '')),
      headers := '{"Content-Type":"application/json"}'::jsonb);
  exception when others then null;   -- aviso nunca derruba o pedido
  end;
  return new; end $$;
drop trigger if exists c_aviso on public.pedidos_chat;
create trigger c_aviso after insert or update on public.pedidos_chat for each row execute function public.tg_aviso_pedido();

-- realtime do painel (respeita RLS)
alter table public.pedidos_chat replica identity full;
do $$ begin alter publication supabase_realtime add table public.pedidos_chat;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ---------- 8. STORAGE: bucket "midia" (leitura pública por URL, escrita só na própria pasta) ----------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('midia','midia',true,52428800, array['image/png','image/jpeg','image/webp','image/gif','video/mp4','video/webm'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ declare r record; begin
  for r in select policyname from pg_policies where schemaname='storage' and tablename='objects'
           and (coalesce(qual,'') || coalesce(with_check,'')) ilike '%midia%' loop
    execute format('drop policy %I on storage.objects', r.policyname);
  end loop;
end $$;
-- caminho do upload é <vendedor_id>/arquivo (o painel já faz isso)
create policy midia_ins on storage.objects for insert to authenticated
  with check (bucket_id='midia' and (storage.foldername(name))[1] = public.meu_vendedor()::text and public.vendedor_ativo(public.meu_vendedor()));
create policy midia_upd on storage.objects for update to authenticated
  using (bucket_id='midia' and (storage.foldername(name))[1] = public.meu_vendedor()::text);
create policy midia_del on storage.objects for delete to authenticated
  using (bucket_id='midia' and (storage.foldername(name))[1] = public.meu_vendedor()::text);
create policy midia_sel on storage.objects for select to authenticated   -- listar só a própria pasta
  using (bucket_id='midia' and (storage.foldername(name))[1] = public.meu_vendedor()::text);

-- ---------- 9. COMANDOS DA EQUIPE (só SQL Editor / service_role) ----------
-- 9.1 cadastrar vendedor: crie antes o usuário em Authentication > Users, depois rode:
--     select public.cadastrar_vendedor('email@dele.com', 'slug-dele', 'Nome Dele', '5568999990000');
create or replace function public.cadastrar_vendedor(p_email text, p_slug text, p_nome text, p_whatsapp text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare u uuid; v uuid;
begin
  select id into u from auth.users where lower(email) = lower(btrim(p_email));
  if u is null then raise exception 'Usuário % não existe. Crie em Authentication > Users (Add user, com Auto Confirm).', p_email; end if;
  insert into public.vendedores(user_id, slug, nome, whatsapp)
  values (u, lower(btrim(p_slug)), btrim(p_nome), regexp_replace(coalesce(p_whatsapp,''),'\D','','g')) returning id into v;
  return v; end $$;

-- 9.2 Telegram do vendedor:  select public.definir_telegram('slug-dele','<token do bot>','<chat id>');
create or replace function public.definir_telegram(p_slug text, p_token text, p_chat text) returns void
language sql security definer set search_path=public as $$
  insert into public.vendedor_segredos(vendedor_id, telegram_token, telegram_chat_id)
  select id, p_token, p_chat from public.vendedores where slug = lower(p_slug)
  on conflict (vendedor_id) do update set telegram_token = excluded.telegram_token, telegram_chat_id = excluded.telegram_chat_id $$;

-- 9.3 dono da plataforma (painel "Vendedores"):  select public.promover_dono('seu@email.com');
create or replace function public.promover_dono(p_email text) returns void language sql security definer set search_path=public as $$
  insert into public.donos(user_id) select id from auth.users where lower(email) = lower(p_email) on conflict do nothing $$;

revoke all on function public.cadastrar_vendedor(text,text,text,text), public.definir_telegram(text,text,text),
                       public.promover_dono(text) from public, anon, authenticated;

-- 9.4 suspender / reativar:  update public.vendedores set suspenso = true where slug = 'slug-dele';

-- ---------- 10. MIGRAÇÃO (só se já existiam dados do modelo antigo sem vendedor_id) ----------
-- update public.motos set vendedor_id = (select id from public.vendedores where slug='slug-dele') where vendedor_id is null;
-- (repita para leads, fichas, contratos, pedidos_chat) e depois trave:
-- alter table public.motos alter column vendedor_id set not null;   -- idem nas outras 4

-- ---------- 11. AUDITORIA (rode quando quiser: tudo deve dar OK) ----------
create or replace view public.auditoria_isolamento as
  select c.relname as tabela, c.relrowsecurity as rls_ligada,
         (select count(*) from pg_policies p where p.schemaname='public' and p.tablename=c.relname) as policies,
         case when c.relrowsecurity then 'OK' else 'RISCO: RLS DESLIGADA' end as status
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r'
    and c.relname in ('vendedores','donos','vendedor_segredos','motos','leads','fichas','contratos','pedidos_chat');
revoke all on public.auditoria_isolamento from anon, authenticated;
-- select * from public.auditoria_isolamento;

-- ---------- 12. CADASTRO RÁPIDO, LINKS, TELEGRAM E PROTEÇÕES (v5) ----------
-- =====================================================================
--  v5 — CADASTRO RÁPIDO + LINKS + TELEGRAM + PROTEÇÕES   (pode rodar várias vezes)
-- =====================================================================

-- ---------- Configuração da plataforma (endereços dos sites e Telegram do dono) ----------
create table if not exists public.plataforma_config(chave text primary key, valor text not null);
alter table public.plataforma_config enable row level security;
revoke all on public.plataforma_config from anon, authenticated;
insert into public.plataforma_config(chave, valor) values
  ('url_vitrine','https://honda-star-motos.vercel.app/'),
  ('url_cdc','https://sitecdc.vercel.app/'),
  ('url_cnh','https://sitecnh.vercel.app/'),
  ('ficha_path','0')            -- 1 = links das fichas CDC/CNH no formato site/nome (exige vercel.json nesses 2 sites)
on conflict (chave) do nothing;
-- vitrine oficial (sobrescreve o valor antigo salvo no banco)
update public.plataforma_config set valor = 'https://honda-star-motos.vercel.app/' where chave = 'url_vitrine';
-- trocar endereço: update public.plataforma_config set valor='https://novo.vercel.app/' where chave='url_vitrine';

create or replace function public.links_vendedor(p_slug text) returns table(etiqueta text, endereco text)
language sql stable security definer set search_path = public as $$
  with c as (select rtrim(max(valor) filter (where chave='url_vitrine'),'/') vit, rtrim(max(valor) filter (where chave='url_cdc'),'/') cdc,
                    rtrim(max(valor) filter (where chave='url_cnh'),'/') cnh, coalesce(max(valor) filter (where chave='ficha_path'),'0') = '1' fp from public.plataforma_config),
       s as (select lower(btrim(p_slug)) as slug)
  select x.etiqueta, x.endereco from (
    select 1 o, 'Vitrine de motos'::text etiqueta, c.vit || '/' || s.slug endereco from c, s
    union all select 2, 'Painel do vendedor (admin)', c.vit || '/' || s.slug || '#admin' from c, s
    union all select 3, 'Ficha CDC (financiamento)', case when c.fp then c.cdc || '/' || s.slug else c.cdc || '/?v=' || s.slug end from c, s
    union all select 4, 'Pré-contrato CNH (consórcio)', case when c.fp then c.cnh || '/' || s.slug else c.cnh || '/?v=' || s.slug end from c, s
  ) x order by x.o $$;

-- ---------- Telegram do DONO (recebe os acessos de cada vendedor novo) ----------
create or replace function public.tg_dono(p_texto text) returns boolean
language plpgsql security definer set search_path = public as $$
declare tk text; ch text;
begin
  select valor into tk from public.plataforma_config where chave = 'telegram_dono_token';
  select valor into ch from public.plataforma_config where chave = 'telegram_dono_chat';
  if tk is null or ch is null then return false; end if;
  perform net.http_post(url := 'https://api.telegram.org/bot' || tk || '/sendMessage',
    body := jsonb_build_object('chat_id', ch, 'text', left(p_texto, 4000), 'disable_web_page_preview', true),
    headers := '{"Content-Type":"application/json"}'::jsonb);
  return true;
exception when others then return false; end $$;

-- ---------- CADASTRO: login + vendedor + links + Telegram ----------
drop function if exists public.novo_vendedor(text,text,text,text,text,boolean);
drop function if exists public.novo_vendedor(text,text,text,text,text,boolean,text,text);
drop function if exists public.novo_vendedor(text,text,text,text,text,boolean,text,text,boolean);
create function public.novo_vendedor(
  p_nome text, p_email text, p_senha text, p_slug text,
  p_whatsapp text default null, p_assumir boolean default false,
  p_tg_token text default null, p_tg_chat text default null, p_avisar boolean default true)
returns table(etiqueta text, endereco text) language plpgsql security definer set search_path = public, extensions, auth as $$
declare
  e text := lower(btrim(p_email)); s text := lower(btrim(p_slug)); n text := btrim(p_nome);
  w text := regexp_replace(coalesce(p_whatsapp,''), '\D', '', 'g');
  u uuid; v uuid; dono uuid; acao text; msg text; tg text; cat text;
begin
  if s !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(s) not between 3 and 40 then
    raise exception 'Slug inválido "%": use 3 a 40 caracteres, só minúsculas, números e hífen (ex: joao-motos).', s; end if;
  if s ~ '^(api|admin|admingeral|index|ficha|contrato|cdc|cnh|vitrine|termos|og|vercel|static|assets|public|favicon|robots|sitemap|login|painel|www|app)$' then raise exception 'O nome "%" é reservado pelo sistema (api, admin, index...). Escolha outro nome para o endereço.', s; end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido: %', e; end if;
  if length(coalesce(p_senha,'')) < 8 then raise exception 'A senha precisa ter pelo menos 8 caracteres.'; end if;
  if length(coalesce(n,'')) < 2 then raise exception 'Informe o nome do vendedor.'; end if;
  if length(w) in (10,11) then w := '55' || w; end if;

  select id into u from auth.users where lower(email) = e;
  if u is null then
    u := gen_random_uuid();
    insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change, email_change_token_new)
    values ('00000000-0000-0000-0000-000000000000', u, 'authenticated', 'authenticated', e,
        crypt(p_senha, gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
    insert into auth.identities(id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), u, u::text, 'email',
        jsonb_build_object('sub', u::text, 'email', e, 'email_verified', true), now(), now(), now());
    acao := 'login criado';
  else
    update auth.users set encrypted_password = crypt(p_senha, gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = u;
    acao := 'login já existia (senha redefinida)';
  end if;

  select id, user_id into v, dono from public.vendedores where slug = s;
  if v is not null and dono is distinct from u then
    if not p_assumir then
      raise exception 'O slug "%" já pertence a outro login (%). Use outro slug, ou rode com p_assumir => true para transferir esse vendedor (e os dados dele) para %.',
        s, (select email from auth.users where id = dono), e; end if;
    if exists(select 1 from public.vendedores where user_id = u and id <> v) then
      raise exception 'O login % já tem outro vendedor cadastrado. Veja: select * from public.equipe_vendedores;', e; end if;
    update public.vendedores set user_id = u where id = v;
  end if;
  if v is null then
    select id into v from public.vendedores where user_id = u;
    if v is null then
      insert into public.vendedores(user_id, slug, nome, whatsapp) values (u, s, n, nullif(w,'')) returning id into v;
      acao := acao || ', vendedor criado';
      begin cat := public.copiar_catalogo(s);   -- catálogo pronto (fotos, preços, consórcio...) copiado do vendedor modelo
      exception when others then cat := 'catálogo não copiado: ' || sqlerrm; end;
    else
      update public.vendedores set slug = s, nome = n, whatsapp = coalesce(nullif(w,''), whatsapp) where id = v;
      acao := acao || ', slug/nome atualizados (links antigos deixam de valer)';
    end if;
  else
    update public.vendedores set nome = n, whatsapp = coalesce(nullif(w,''), whatsapp), suspenso = false where id = v;
    acao := acao || ', vendedor atualizado';
  end if;

  if p_tg_token is not null and p_tg_chat is not null then perform public.definir_telegram(s, p_tg_token, p_tg_chat); end if;
  perform public._guarda_senha(v, p_senha);

  -- aviso para o dono, com e-mail + senha + links
  select string_agg(l.etiqueta || ': ' || l.endereco, E'\n') into tg from public.links_vendedor(s) l;
  msg := E'🆕 Vendedor cadastrado\nNome: ' || n || E'\nE-mail: ' || e || E'\nSenha: ' || p_senha || E'\n\n' || tg;
  return query select 'Status'::text, acao;
  return query select 'Login (e-mail)'::text, e;
  if cat is not null then return query select 'Catálogo'::text, cat; end if;
  return query select * from public.links_vendedor(s);
  if p_avisar then
    return query select 'Telegram'::text, case when public.tg_dono(msg)
      then 'acesso enviado ao seu Telegram' else 'NÃO enviado (rode antes: select public.ativar_bot(token, chat_id);)' end;
  end if;
end $$;

-- ---------- AVISO DE FICHA / PRÉ-CONTRATO no Telegram do vendedor (sem CPF na mensagem) ----------
create or replace function public.tg_aviso_cadastro() returns trigger language plpgsql security definer set search_path = public as $$
declare s record; j jsonb := to_jsonb(new);
begin
  if public._eh_teste(coalesce(j->>'nome_completo', j->>'nome')) then return new; end if;
  select telegram_token, telegram_chat_id into s from public.vendedor_segredos where vendedor_id = new.vendedor_id;
  if s.telegram_token is null or s.telegram_chat_id is null then return new; end if;
  begin
    perform net.http_post(url := 'https://api.telegram.org/bot' || s.telegram_token || '/sendMessage',
      body := jsonb_build_object('chat_id', s.telegram_chat_id, 'text',
        case tg_table_name when 'fichas' then 'Nova ficha CDC (financiamento)' else 'Novo pré-contrato CNH (consórcio)' end
        || E'\n' || coalesce(j->>'nome','-') || E'\n' || coalesce(j->>'telefone','-') || E'\n' || coalesce(j->>'moto_nome','-') || coalesce(E'\nCor: ' || (j->>'cor'), '')),
      headers := '{"Content-Type":"application/json"}'::jsonb);
  exception when others then null; end;
  return new; end $$;

-- ---------- AVISO PARA O ADMIN GERAL (Telegram do dono): cada pedido/ficha/pré-contrato novo, com o vendedor de origem ----------
--  Desligar:  update public.plataforma_config set valor = 'nao' where chave = 'avisar_dono_pedidos';   (ligar: 'sim')
insert into public.plataforma_config(chave, valor) values ('avisar_dono_pedidos', 'sim') on conflict (chave) do nothing;
create or replace function public.tg_aviso_dono() returns trigger language plpgsql security definer set search_path = public as $$
declare j jsonb := to_jsonb(new); vn text; flag text; tp text;
begin
  if public._eh_teste(coalesce(j->>'nome_completo', j->>'nome')) then return new; end if;
  select valor into flag from public.plataforma_config where chave = 'avisar_dono_pedidos';
  if coalesce(flag, 'sim') = 'nao' then return new; end if;
  if tg_table_name = 'pedidos_chat' then
    if new.completo then
      if tg_op = 'UPDATE' and old.completo then return new; end if; tp := 'Pedido do chat';
    elsif nullif(btrim(coalesce(new.telefone, '')), '') is not null and (tg_op = 'INSERT' or nullif(btrim(coalesce(old.telefone, '')), '') is null) then
      tp := 'Cliente começou o chat (ainda não concluiu)';
    else return new; end if;
  elsif tg_table_name = 'fichas' then tp := 'Ficha CDC (financiamento)'; else tp := 'Pré-contrato CNH (consórcio)'; end if;
  select nome into vn from public.vendedores where id = new.vendedor_id;
  perform public.tg_dono(E'📥 ' || tp || E'\nVendedor: ' || coalesce(vn, '-') || E'\nCliente: ' || coalesce(j->>'nome_completo', j->>'nome', '-')
    || E'\nTel: ' || coalesce(j->>'telefone', '-') || E'\nMoto: ' || coalesce(j->>'moto_nome', '-') || coalesce(E'\nCor: ' || (j->>'cor'), ''));
  return new;
exception when others then return new;   -- o aviso nunca derruba o pedido
end $$;

-- ---------- ANTI-SPAM: no máximo 30 envios por minuto por vendedor ----------
create or replace function public.tg_throttle() returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  execute format('select count(*) from public.%I where vendedor_id = $1 and created_at > now() - interval ''1 minute''', tg_table_name)
    into n using new.vendedor_id;
  if n >= 30 then raise exception 'Muitas solicitações em pouco tempo. Tente novamente em instantes.'; end if;
  return new; end $$;

do $$ declare t text; begin
  foreach t in array array['leads','fichas','contratos'] loop
    execute format('drop trigger if exists d_throttle on public.%I', t);
    execute format('create trigger d_throttle before insert on public.%I for each row execute function public.tg_throttle()', t);
  end loop;
  foreach t in array array['fichas','contratos'] loop
    execute format('drop trigger if exists e_aviso on public.%I', t);
    execute format('create trigger e_aviso after insert on public.%I for each row execute function public.tg_aviso_cadastro()', t);
  end loop;
  foreach t in array array['fichas','contratos'] loop
    execute format('drop trigger if exists g_aviso_dono on public.%I', t);
    execute format('create trigger g_aviso_dono after insert on public.%I for each row execute function public.tg_aviso_dono()', t);
  end loop;
  drop trigger if exists g_aviso_dono on public.pedidos_chat;
  create trigger g_aviso_dono after insert or update on public.pedidos_chat for each row execute function public.tg_aviso_dono();
end $$;

-- ---------- FERRAMENTAS DA EQUIPE ----------
create or replace function public.suspender_vendedor(p_slug text, p_suspenso boolean default true) returns text
language plpgsql security definer set search_path = public as $$
begin
  update public.vendedores set suspenso = p_suspenso where slug = lower(btrim(p_slug));
  if not found then raise exception 'Slug "%" não existe.', p_slug; end if;
  return case when p_suspenso then 'Site suspenso (cliente vê "indisponível").' else 'Site reativado.' end; end $$;

-- ---------- COFRE DE SENHAS: o admin geral enxerga a senha que ele (ou o bot) definiu para cada vendedor ----------
--  Atenção: a senha que já existe no Supabase é só um HASH e NÃO tem como ser lida. Este cofre guarda (criptografada) a senha
--  que for DEFINIDA a partir de agora (cadastro, troca pelo admin geral, bot). Só as funções do admin geral conseguem ler.
--  Se o vendedor trocar a própria senha por fora, o admin geral vê o aviso "desatualizada" (a cópia deixa de conferir com a senha real).
create table if not exists public.vendedor_senhas(
  vendedor_id uuid primary key references public.vendedores(id) on delete cascade,
  senha_enc bytea not null, atualizado_em timestamptz not null default now());
alter table public.vendedor_senhas enable row level security;
revoke all on public.vendedor_senhas from public, anon, authenticated;
create or replace function public._cofre_chave() returns text language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  select valor into k from public.plataforma_config where chave = 'cofre_chave';
  if k is null then
    insert into public.plataforma_config(chave, valor) values ('cofre_chave', encode(gen_random_bytes(32), 'hex')) on conflict (chave) do nothing;
    select valor into k from public.plataforma_config where chave = 'cofre_chave';
  end if;
  return k;
end $$;
create or replace function public._guarda_senha(p_vendedor uuid, p_senha text) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_vendedor is null or p_senha is null then return; end if;
  insert into public.vendedor_senhas(vendedor_id, senha_enc, atualizado_em) values (p_vendedor, pgp_sym_encrypt(p_senha, public._cofre_chave()), now())
  on conflict (vendedor_id) do update set senha_enc = excluded.senha_enc, atualizado_em = now();
end $$;
revoke all on function public._cofre_chave(), public._guarda_senha(uuid, text) from public, anon, authenticated;

create or replace function public.trocar_senha(p_email text, p_senha text) returns text
language plpgsql security definer set search_path = public, extensions, auth as $$
declare vid uuid;
begin
  if length(coalesce(p_senha,'')) < 8 then raise exception 'A senha precisa ter pelo menos 8 caracteres.'; end if;
  if length(p_senha) > 72 then raise exception 'A senha pode ter no máximo 72 caracteres.'; end if;
  update auth.users set encrypted_password = crypt(p_senha, gen_salt('bf')), updated_at = now() where lower(email) = lower(btrim(p_email));
  if not found then raise exception 'E-mail não encontrado.'; end if;
  select v.id into vid from public.vendedores v join auth.users u on u.id = v.user_id where lower(u.email) = lower(btrim(p_email));
  perform public._guarda_senha(vid, p_senha);      -- vendedor: guarda no cofre (o admin geral não é vendedor, então não entra)
  return 'Senha alterada.'; end $$;

create or replace view public.equipe_vendedores as
  select v.slug, v.nome, u.email, v.whatsapp, v.suspenso, v.created_at, v.id as vendedor_id,
    (select count(*) from public.motos m where m.vendedor_id = v.id) as motos,
    (select count(*) from public.pedidos_chat p where p.vendedor_id = v.id and p.completo) as pedidos,
    (select count(*) from public.fichas f where f.vendedor_id = v.id) as fichas,
    (select count(*) from public.contratos c where c.vendedor_id = v.id) as contratos
  from public.vendedores v left join auth.users u on u.id = v.user_id order by v.created_at;

-- ---------- permissões: nada disso é acessível pelos sites ----------
revoke all on function public.links_vendedor(text), public.tg_dono(text),
  public.novo_vendedor(text,text,text,text,text,boolean,text,text,boolean), public.suspender_vendedor(text,boolean),
  public.trocar_senha(text,text), public.tg_aviso_cadastro(), public.tg_throttle(), public.tg_aviso_dono() from public, anon, authenticated;
revoke all on public.equipe_vendedores from anon, authenticated;

-- ---------- BOT DO TELEGRAM (/cadastrar): estado da conversa + permissões do service_role ----------
create table if not exists public.bot_sessoes(
  chat_id bigint primary key, etapa text not null, dados jsonb not null default '{}', atualizado timestamptz not null default now());
alter table public.bot_sessoes enable row level security;          -- sem policies: só a Edge Function (service_role) acessa
revoke all on public.bot_sessoes from anon, authenticated;
grant all on public.bot_sessoes to service_role;
grant execute on function public.novo_vendedor(text,text,text,text,text,boolean,text,text,boolean),
  public.links_vendedor(text), public.suspender_vendedor(text,boolean) to service_role;
grant select on public.equipe_vendedores to service_role;

-- =====================================================================
--  (Opcional, sem o bot) cadastro direto por SQL — preencha e rode
-- =====================================================================
-- select * from public.novo_vendedor(p_nome=>'Nome', p_email=>'email@dele.com', p_senha=>'SenhaForte123', p_slug=>'slug-dele', p_whatsapp=>'68999990000');
-- Ferramentas:  select * from public.equipe_vendedores;  |  select * from public.links_vendedor('slug');
--               select public.trocar_senha('email','NovaSenha123');  |  select public.suspender_vendedor('slug', true);


-- =====================================================================
--  13. BOT DO TELEGRAM DENTRO DO BANCO  (só precisa de TOKEN + CHAT ID)
--  O Telegram chama direto o Postgres (sem Edge Function, sem secrets manuais):
--     Telegram  ->  /rest/v1/rpc/telegram_webhook  ->  telegram_processar()  ->  bot_processar()
--  A resposta volta no próprio retorno do webhook (o Telegram executa o "method" devolvido).
-- =====================================================================

-- log curto para diagnóstico (guarda só o COMANDO, nunca o texto digitado: senhas ficam de fora)
create table if not exists public.bot_log(
  id bigint generated always as identity primary key,
  ts timestamptz not null default now(),
  chat_id bigint, de_id bigint, comando text, resultado text);
alter table public.bot_log enable row level security;
revoke all on public.bot_log from anon, authenticated;
grant all on public.bot_log to service_role;

-- ---------- helpers ----------
create or replace function public.bot_esc(t text) returns text language sql immutable as $$
  select replace(replace(replace(coalesce(t,''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') $$;

create or replace function public.bot_slugify(t text) returns text language sql immutable as $$
  select btrim(left(btrim(regexp_replace(
    translate(lower(coalesce(t,'')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'),
    '[^a-z0-9]+', '-', 'g'), '-'), 40), '-') $$;

create or replace function public.bot_gerar_senha() returns text language sql volatile
set search_path = public, extensions as $$
  select string_agg(substr(x.a, 1 + (get_byte(x.b, i) % length(x.a)), 1), '')
  from (select 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'::text as a, gen_random_bytes(10) as b) x,
       generate_series(0, 9) i $$;

create or replace function public.bot_resposta(p_chat bigint, p_texto text) returns jsonb language sql immutable as $$
  select jsonb_build_object('method', 'sendMessage', 'chat_id', p_chat, 'text', left(p_texto, 4000),
                            'parse_mode', 'HTML', 'disable_web_page_preview', true) $$;

-- chamada genérica à API do Telegram com o token do dono (assíncrona, nunca derruba quem chamou)
create or replace function public.tg_api(p_metodo text, p_corpo jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare tk text;
begin
  select valor into tk from public.plataforma_config where chave = 'telegram_dono_token';
  if tk is null then return false; end if;
  perform net.http_post(url := 'https://api.telegram.org/bot' || tk || '/' || p_metodo,
    body := p_corpo, headers := '{"Content-Type":"application/json"}'::jsonb);
  return true;
exception when others then return false; end $$;

-- (o catálogo modelo e os planos de consórcio agora ficam no script 02: catálogo geral)

create or replace function public.definir_modelo(p_slug text) returns text
language plpgsql security definer set search_path = public as $$
declare s text := lower(btrim(p_slug)); n int;
begin
  if not exists (select 1 from public.vendedores where slug = s) then raise exception 'Slug "%" não existe.', s; end if;
  insert into public.plataforma_config(chave, valor) values ('vendedor_modelo', s)
    on conflict (chave) do update set valor = excluded.valor;
  select count(*) into n from public.motos m join public.vendedores v on v.id = m.vendedor_id where v.slug = s;
  return format('Modelo definido: %s (%s motos). Todo vendedor novo vai receber uma cópia desse catálogo.', s, n);
end $$;


-- se ainda não há modelo, usa o vendedor "shayron" (confira com /modelo; troque com /modelo slug)
insert into public.plataforma_config(chave, valor)
  select 'vendedor_modelo', slug from public.vendedores where slug ilike '%shayron%' order by created_at limit 1
on conflict (chave) do nothing;

-- ---------- contagem de dados de UM vendedor (só números, nunca o conteúdo) ----------
create or replace function public.bot_contagem(p_vid uuid) returns text language sql stable security definer set search_path = public as $$
  select format('motos %s · leads %s · fichas CDC %s · pré-contratos CNH %s · pedidos do chat %s',
    (select count(*) from public.motos where vendedor_id = p_vid),
    (select count(*) from public.leads where vendedor_id = p_vid),
    (select count(*) from public.fichas where vendedor_id = p_vid),
    (select count(*) from public.contratos where vendedor_id = p_vid),
    (select count(*) from public.pedidos_chat where vendedor_id = p_vid)) $$;

-- ---------- EXCLUIR UM VENDEDOR E TUDO DELE (atômico: ou apaga tudo, ou nada) ----------
-- Só mexe em linhas com vendedor_id = esse vendedor. Outros vendedores não são tocados.
create or replace function public.excluir_vendedor(p_slug text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare v record; n_m int; n_l int; n_f int; n_c int; n_p int; n_media int; apagou_login boolean := false; txt text;
begin
  select id, user_id, nome, slug into v from public.vendedores where slug = lower(btrim(p_slug)) for update;
  if not found then raise exception 'Slug "%" não existe.', p_slug; end if;

  delete from public.motos        where vendedor_id = v.id; get diagnostics n_m = row_count;
  delete from public.leads        where vendedor_id = v.id; get diagnostics n_l = row_count;
  delete from public.fichas       where vendedor_id = v.id; get diagnostics n_f = row_count;
  delete from public.contratos    where vendedor_id = v.id; get diagnostics n_c = row_count;
  delete from public.pedidos_chat where vendedor_id = v.id; get diagnostics n_p = row_count;
  delete from public.vendedor_segredos where vendedor_id = v.id;
  delete from public.vendedores   where id = v.id;

  -- apaga o login (só se não for dono da plataforma e não for usado por outro vendedor)
  if not exists (select 1 from public.donos where user_id = v.user_id)
     and not exists (select 1 from public.vendedores where user_id = v.user_id) then
    delete from auth.identities where user_id = v.user_id;
    delete from auth.users where id = v.user_id;
    apagou_login := true;
  end if;

  -- mídia (fotos/vídeos): o SQL não consegue apagar os arquivos do Storage, só contar
  begin
    select count(*) into n_media from storage.objects where bucket_id = 'midia' and (storage.foldername(name))[1] = v.id::text;
  exception when others then n_media := null; end;

  txt := format(E'Vendedor %s (%s) excluído.\nApagado: %s motos, %s leads, %s fichas CDC, %s pré-contratos CNH, %s pedidos do chat e o Telegram dele.\n%s',
    v.nome, v.slug, n_m, n_l, n_f, n_c, n_p,
    case when apagou_login then 'Login apagado.' else 'Login mantido (é dono da plataforma).' end);
  if coalesce(n_media, 0) > 0 then
    txt := txt || format(E'\nAtenção: %s arquivo(s) de mídia continuam no Storage. Apague a pasta %s no bucket "midia" (Storage > midia).', n_media, v.id);
  end if;
  return txt;
end $$;

-- ---------- cérebro do bot: recebe o texto, devolve a resposta em HTML ----------
create or replace function public.bot_processar(p_chat bigint, p_msg bigint, p_texto text)
returns text language plpgsql security definer set search_path = public, extensions, auth as $$
declare
  t text := btrim(coalesce(p_texto, ''));
  iscmd boolean := left(btrim(coalesce(p_texto, '')), 1) = '/';
  cmd text := ''; arg text; argl text;
  ajuda constant text := E'🤖 <b>Painel de vendedores</b>\n\n/cadastrar – cadastrar novo vendedor\n/equipe – listar vendedores\n/links slug – ver links de um vendedor\n/suspender slug – suspender site\n/reativar slug – reativar site\n/avisos slug TOKEN CHAT_ID – ligar avisos no Telegram do vendedor\n/trocarsenha email – gerar nova senha para um vendedor\n/excluir – listar vendedores e excluir um (apaga tudo dele)\n/catalogo slug – copiar o catálogo modelo para um vendedor\n/catalogotodos – copiar o catálogo modelo para todos os vendedores sem motos\n/modelo – ver ou definir o vendedor modelo\n/cancelar – cancelar o cadastro em andamento';
  vid uuid; s public.bot_sessoes%rowtype; d jsonb; w text; sl text; p text; lista text; v_links jsonb; tk text; ch text;
begin
  if iscmd then cmd := lower(regexp_replace(substring(t from '^\S+'), '@.*$', '')); end if;
  arg := coalesce(btrim(substring(t from '^\S+\s+(.*)$')), '');
  argl := lower(arg);

  if cmd in ('/start', '/ajuda') then return ajuda; end if;

  if cmd = '/cancelar' then
    delete from public.bot_sessoes where chat_id = p_chat;
    return 'Cancelado. ✅';
  end if;

  if cmd = '/cadastrar' then
    delete from public.bot_sessoes where atualizado < now() - interval '1 day';
    insert into public.bot_sessoes(chat_id, etapa, dados, atualizado) values (p_chat, 'nome', '{}', now())
      on conflict (chat_id) do update set etapa = 'nome', dados = '{}', atualizado = now();
    return E'📝 <b>Novo vendedor</b>\n\n1/5 · Qual o <b>nome</b> do vendedor?\n(/cancelar para sair)';
  end if;

  if cmd = '/equipe' then
    select string_agg(format(E'%s <b>%s</b> · <code>%s</code>\n%s\nmotos %s · pedidos %s · fichas %s · contratos %s',
             case when q.suspenso then '⏸' else '🟢' end, public.bot_esc(q.nome), public.bot_esc(q.slug),
             public.bot_esc(coalesce(q.email, '-')), q.motos, q.pedidos, q.fichas, q.contratos), E'\n\n' order by q.created_at)
      into lista from (select * from public.equipe_vendedores limit 25) q;
    return coalesce(lista, 'Nenhum vendedor cadastrado.');
  end if;

  if cmd = '/links' then
    if argl = '' then return 'Use: /links slug-do-vendedor'; end if;
    if not exists (select 1 from public.vendedores where slug = argl) then return 'Esse slug não existe. Veja /equipe.'; end if;
    select string_agg(public.bot_esc(l.etiqueta) || ': ' || public.bot_esc(l.endereco), E'\n') into lista
      from public.links_vendedor(argl) l;
    return lista;
  end if;

  if cmd in ('/suspender', '/reativar') then
    if argl = '' then return 'Use: ' || cmd || ' slug-do-vendedor'; end if;
    return public.bot_esc(public.suspender_vendedor(argl, cmd = '/suspender'));
  end if;

  if cmd = '/modelo' then
    if argl = '' then
      select valor into sl from public.plataforma_config where chave = 'vendedor_modelo';
      if sl is null then return 'Nenhum modelo definido. Use: /modelo slug-do-vendedor-com-as-motos-prontas'; end if;
      return format(E'Vendedor modelo: <code>%s</code>\n%s\n\nPara trocar: /modelo slug', public.bot_esc(sl),
        public.bot_contagem((select id from public.vendedores where slug = sl)));
    end if;
    return public.bot_esc(public.definir_modelo(argl));
  end if;

  if cmd = '/catalogo' then
    sl := lower(split_part(arg, ' ', 1)); w := lower(split_part(arg, ' ', 2));
    if sl = '' then return 'Use: /catalogo slug   (ou /catalogo slug substituir, para refazer do zero)'; end if;
    return '📦 ' || public.bot_esc(public.copiar_catalogo(sl, w = 'substituir'));
  end if;

  if cmd = '/catalogotodos' then
    return '📦 ' || public.bot_esc(public.copiar_catalogo_todos());
  end if;

  if cmd = '/excluir' then
    if argl = '' then   -- lista todos os cadastros (só nomes e contagens)
      select string_agg(format(E'%s <b>%s</b> · <code>%s</code>\n%s', case when q.suspenso then '⏸' else '🟢' end,
               public.bot_esc(q.nome), public.bot_esc(q.slug), public.bot_contagem(q.vendedor_id)), E'\n\n' order by q.created_at)
        into lista from (select * from public.equipe_vendedores limit 25) q;
      return coalesce(lista || E'\n\nPara excluir um deles: /excluir slug', 'Nenhum vendedor cadastrado.');
    end if;
    select id into vid from public.vendedores where slug = argl;
    if vid is null then return 'Esse slug não existe. Veja a lista em /excluir.'; end if;
    insert into public.bot_sessoes(chat_id, etapa, dados, atualizado) values (p_chat, 'excluir', jsonb_build_object('slug', argl), now())
      on conflict (chat_id) do update set etapa = 'excluir', dados = jsonb_build_object('slug', argl), atualizado = now();
    return format(E'⚠️ <b>Excluir <code>%s</code>?</b>\n\nVai apagar PARA SEMPRE o login, as motos, leads, fichas CDC, pré-contratos CNH, pedidos do chat e o Telegram desse vendedor:\n%s\n\nNão dá para desfazer. Para confirmar, envie exatamente:\n<code>CONFIRMAR %s</code>\nou /cancelar.',
      public.bot_esc(argl), public.bot_contagem(vid), public.bot_esc(argl));
  end if;

  if cmd = '/trocarsenha' then
    if argl = '' then return 'Use: /trocarsenha email-do-vendedor'; end if;
    p := public.bot_gerar_senha();
    perform public.trocar_senha(argl, p);
    return format(E'🔑 Nova senha de <code>%s</code>:\n<code>%s</code>', public.bot_esc(argl), public.bot_esc(p));
  end if;

  if cmd = '/avisos' then   -- liga os avisos de pedido/ficha/contrato no Telegram do vendedor
    perform public.tg_api('deleteMessage', jsonb_build_object('chat_id', p_chat, 'message_id', p_msg));  -- some com o token
    sl := lower(split_part(arg, ' ', 1)); tk := split_part(arg, ' ', 2); ch := split_part(arg, ' ', 3);
    if sl = '' or tk = '' or ch = '' then return 'Use: /avisos slug TOKEN_DO_BOT_DELE CHAT_ID_DELE'; end if;
    if not exists (select 1 from public.vendedores where slug = sl) then return 'Esse slug não existe. Veja /equipe.'; end if;
    perform public.definir_telegram(sl, tk, ch);
    return format('✅ Avisos ligados para <code>%s</code>. Apaguei a sua mensagem com o token. O vendedor precisa ter dado /start no bot dele.', public.bot_esc(sl));
  end if;

  if iscmd and cmd not in ('/ok', '/gerar', '/pular') then return E'Comando desconhecido.\n\n' || ajuda; end if;

  -- ---------- conversa guiada do /cadastrar ----------
  select * into s from public.bot_sessoes where chat_id = p_chat and atualizado > now() - interval '1 hour';
  if not found then return ajuda; end if;
  d := s.dados;

  if s.etapa = 'excluir' then
    if lower(t) <> 'confirmar ' || (d->>'slug') then
      return format(E'Não confirmado. Envie exatamente <code>CONFIRMAR %s</code> ou /cancelar.', public.bot_esc(d->>'slug')); end if;
    lista := public.excluir_vendedor(d->>'slug');
    delete from public.bot_sessoes where chat_id = p_chat;
    return '🗑 ' || public.bot_esc(lista);
  end if;

  if s.etapa = 'nome' then
    if length(t) < 2 or iscmd then return 'Digite o nome do vendedor.'; end if;
    d := d || jsonb_build_object('nome', left(t, 80));
    update public.bot_sessoes set etapa = 'email', dados = d, atualizado = now() where chat_id = p_chat;
    return E'2/5 · Qual o <b>e-mail</b> de login dele?';
  end if;

  if s.etapa = 'email' then
    w := lower(t);
    if w !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return 'E-mail inválido. Digite de novo.'; end if;
    select v.slug into sl from public.vendedores v join auth.users u on u.id = v.user_id where lower(u.email) = w;
    if sl is not null then
      return format(E'Esse e-mail já pertence ao vendedor <code>%s</code>. Use outro e-mail, ou veja /links %s.', public.bot_esc(sl), public.bot_esc(sl));
    end if;
    d := d || jsonb_build_object('email', w);
    update public.bot_sessoes set etapa = 'senha', dados = d, atualizado = now() where chat_id = p_chat;
    return E'3/5 · Qual a <b>senha</b> do painel? (mínimo 8 caracteres)\nOu envie /gerar para eu criar uma forte.\n<i>Vou apagar a sua mensagem com a senha.</i>'
      || case when exists (select 1 from auth.users where lower(email) = w)
              then E'\n\n⚠️ Esse e-mail já tem login: a senha dele será redefinida.' else '' end;
  end if;

  if s.etapa = 'senha' then
    if cmd = '/gerar' then p := public.bot_gerar_senha();
    else
      p := t;
      perform public.tg_api('deleteMessage', jsonb_build_object('chat_id', p_chat, 'message_id', p_msg));
    end if;
    if length(p) < 8 then return 'A senha precisa ter pelo menos 8 caracteres. Tente de novo ou /gerar.'; end if;
    d := d || jsonb_build_object('senha', p, 'sugestao', public.bot_slugify(d->>'nome'));
    update public.bot_sessoes set etapa = 'slug', dados = d, atualizado = now() where chat_id = p_chat;
    return format(E'4/5 · Qual o <b>slug</b> (endereço) dele? Só letras minúsculas, números e hífen.\nSugestão: <code>%s</code> — envie /ok para usar.',
                  public.bot_esc(d->>'sugestao'));
  end if;

  if s.etapa = 'slug' then
    sl := case when cmd = '/ok' then coalesce(d->>'sugestao', '') else public.bot_slugify(t) end;
    if sl !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(sl) not between 3 and 40 then
      return 'Slug inválido (3 a 40 caracteres: letras, números e hífen). Tente outro.'; end if;
    if exists (select 1 from public.vendedores where slug = sl) then
      return format('O slug <code>%s</code> já existe. Envie outro.', public.bot_esc(sl)); end if;
    d := d || jsonb_build_object('slug', sl);
    update public.bot_sessoes set etapa = 'whatsapp', dados = d, atualizado = now() where chat_id = p_chat;
    return E'5/5 · <b>WhatsApp</b> dele com DDD (ex: 68999990000) ou /pular.';
  end if;

  if s.etapa = 'whatsapp' then
    if cmd = '/pular' then d := d - 'whatsapp';
    else
      w := regexp_replace(t, '\D', '', 'g');
      if length(w) < 10 or length(w) > 13 then return 'Número inválido. Use DDD + número, ou /pular.'; end if;
      d := d || jsonb_build_object('whatsapp', w);
    end if;
    update public.bot_sessoes set etapa = 'confirmar', dados = d, atualizado = now() where chat_id = p_chat;
    return format(E'Confere?\n\n<b>Nome:</b> %s\n<b>E-mail:</b> %s\n<b>Slug:</b> %s\n<b>WhatsApp:</b> %s\n\nResponda <b>sim</b> para cadastrar ou /cancelar.',
      public.bot_esc(d->>'nome'), public.bot_esc(d->>'email'), public.bot_esc(d->>'slug'), public.bot_esc(coalesce(d->>'whatsapp', '-')));
  end if;

  if s.etapa = 'confirmar' then
    if lower(replace(t, '/', '')) not in ('sim', 's', 'confirmo', 'ok') then
      return E'Responda <b>sim</b> para cadastrar ou /cancelar.'; end if;
    begin
      select jsonb_agg(jsonb_build_object('e', r.etiqueta, 'u', r.endereco)) into v_links
        from public.novo_vendedor(p_nome => d->>'nome', p_email => d->>'email', p_senha => d->>'senha',
                                  p_slug => d->>'slug', p_whatsapp => d->>'whatsapp', p_avisar => false) r;
    exception when others then
      return E'⚠️ Não consegui cadastrar:\n' || public.bot_esc(sqlerrm) || E'\n\nCorrija e rode /cadastrar de novo.';
    end;
    delete from public.bot_sessoes where chat_id = p_chat;   -- apaga a senha da sessão
    select string_agg('<b>' || public.bot_esc(x->>'e') || E'</b>\n' || public.bot_esc(x->>'u'), E'\n\n') into lista
      from jsonb_array_elements(v_links) x where x->>'e' not in ('Status', 'Login (e-mail)', 'Telegram', 'Catálogo');
    return E'✅ <b>Vendedor cadastrado</b>\n\n<b>Nome:</b> ' || public.bot_esc(d->>'nome')
      || E'\n<b>E-mail:</b> <code>' || public.bot_esc(d->>'email') || E'</code>\n<b>Senha:</b> <code>' || public.bot_esc(d->>'senha')
      || E'</code>\n\n' || coalesce(lista, '')
      || coalesce(E'\n\n📦 Catálogo: ' || (select public.bot_esc(x->>'u') from jsonb_array_elements(v_links) x where x->>'e' = 'Catálogo'), '')
      || E'\n\n<i>Peça para ele trocar a senha no primeiro acesso. Para ligar os avisos dele no Telegram: /avisos ' || public.bot_esc(d->>'slug') || ' TOKEN CHAT_ID</i>';
  end if;

  return ajuda;
exception when others then
  return '⚠️ Erro: ' || public.bot_esc(sqlerrm);
end $$;

-- ---------- porta de entrada: valida segredo + dono, chama o cérebro, devolve o "method" para o Telegram ----------
create or replace function public.telegram_processar(p_update jsonb, p_secret text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  esperado text; dono bigint; m jsonb := p_update->'message';
  chat bigint; de bigint; txt text; mid bigint; cmd1 text;
begin
  select valor into esperado from public.plataforma_config where chave = 'bot_webhook_secret';
  if esperado is null or p_secret is distinct from esperado then
    insert into public.bot_log(resultado) values ('segredo_invalido');
    return '{}'::jsonb;
  end if;
  if m is null or m->>'text' is null then return '{}'::jsonb; end if;

  chat := (m->'chat'->>'id')::bigint;
  de   := (m->'from'->>'id')::bigint;
  mid  := (m->>'message_id')::bigint;
  txt  := m->>'text';
  cmd1 := case when left(txt, 1) = '/' then left(lower(split_part(split_part(txt, ' ', 1), '@', 1)), 30) else '(texto)' end;
  delete from public.bot_log where ts < now() - interval '7 days';

  begin select valor::bigint into dono from public.plataforma_config where chave = 'telegram_dono_chat';
  exception when others then dono := null; end;

  if dono is null or chat <> dono or de is distinct from dono then
    insert into public.bot_log(chat_id, de_id, comando, resultado) values (chat, de, cmd1, 'nao_autorizado');
    if cmd1 in ('/start', '/meuid') then
      return public.bot_resposta(chat, E'🔒 Este bot é privado.\nSeu chat id: <code>' || chat || '</code>');
    end if;
    return '{}'::jsonb;   -- qualquer outra pessoa é ignorada em silêncio
  end if;

  insert into public.bot_log(chat_id, de_id, comando, resultado) values (chat, de, cmd1, 'ok');
  return public.bot_resposta(chat, public.bot_processar(chat, mid, txt));
exception when others then
  insert into public.bot_log(chat_id, de_id, comando, resultado) values (chat, de, cmd1, left('erro: ' || sqlerrm, 300));
  if chat is not null then return public.bot_resposta(chat, '⚠️ Erro: ' || public.bot_esc(sqlerrm)); end if;
  return '{}'::jsonb;
end $$;

-- endpoint que o Telegram chama (PostgREST: parâmetro único sem nome = recebe o corpo JSON inteiro)
create or replace function public.telegram_webhook(jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h json;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  return public.telegram_processar($1, coalesce(h->>'x-telegram-bot-api-secret-token', ''));
end $$;

-- ---------- LIGAR O BOT: só token + chat id ----------
create or replace function public.ativar_bot(
  p_token text, p_chat text,
  p_url  text default 'https://qrmwgqkiwoenlkfzjazs.supabase.co',
  p_anon text default 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFybXdncWtpd29lbmxrZnpqYXpzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA4MDc3OTIsImV4cCI6MjEwNjM4Mzc5Mn0.lhgkQS_WcB55uG0SKk0ngQgpc9oruFRt2H2D8orjNnc',
  p_modo text default 'direto')   -- 'direto' = Telegram -> banco | 'edge' = Telegram -> Edge Function telegram-bot -> banco
returns text language plpgsql security definer set search_path = public, extensions as $$
declare seg text; destino text; tk text := btrim(p_token); ch text := btrim(p_chat);
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise exception 'A extensão pg_net está desligada. Ative em Database > Extensions > pg_net e rode de novo.'; end if;
  if tk !~ '^\d+:[A-Za-z0-9_-]{30,}$' then raise exception 'Token inválido (formato 123456:ABC...). Copie de novo do @BotFather.'; end if;
  if ch !~ '^-?\d+$' then raise exception 'Chat ID inválido: só números (mande /start para o @userinfobot para descobrir o seu).'; end if;

  seg := encode(gen_random_bytes(24), 'hex');
  insert into public.plataforma_config(chave, valor)
    values ('telegram_dono_token', tk), ('telegram_dono_chat', ch), ('bot_webhook_secret', seg)
  on conflict (chave) do update set valor = excluded.valor;

  destino := rtrim(p_url, '/') || case when p_modo = 'edge' then '/functions/v1/telegram-bot'
                                       else '/rest/v1/rpc/telegram_webhook?apikey=' || p_anon end;
  perform net.http_post(url := 'https://api.telegram.org/bot' || tk || '/setWebhook',
    body := jsonb_build_object('url', destino, 'secret_token', seg,
                               'allowed_updates', jsonb_build_array('message'), 'drop_pending_updates', true),
    headers := '{"Content-Type":"application/json"}'::jsonb);
  perform public.tg_dono('✅ Bot ativo. Envie /start para ver os comandos.');
  return 'Webhook pedido ao Telegram (modo ' || p_modo || '). Em alguns segundos deve chegar uma mensagem de teste no seu Telegram. '
      || 'Se não chegar: dê /start no bot, e confira em https://api.telegram.org/bot<SEU_TOKEN>/getWebhookInfo (campo last_error_message).';
end $$;

-- compatibilidade com a v5: mesmo efeito que ativar_bot
create or replace function public.definir_telegram_dono(p_token text, p_chat text) returns text
language sql security definer set search_path = public as $$ select public.ativar_bot(p_token, p_chat) $$;

-- ---------- permissões ----------
revoke all on function public.bot_esc(text), public.bot_slugify(text), public.bot_gerar_senha(), public.bot_resposta(bigint,text),
  public.tg_api(text,jsonb), public.bot_processar(bigint,bigint,text), public.telegram_processar(jsonb,text),
  public.telegram_webhook(jsonb), public.ativar_bot(text,text,text,text,text), public.definir_telegram_dono(text,text),
  public.bot_contagem(uuid), public.excluir_vendedor(text), public.definir_modelo(text)
  from public, anon, authenticated;
grant execute on function public.telegram_webhook(jsonb) to anon, authenticated;            -- único ponto público (protegido pelo segredo do webhook)
grant execute on function public.telegram_processar(jsonb,text) to service_role;           -- usado só se você optar pelo modo 'edge'

-- =====================================================================
--  PRONTO. Para ligar o bot (rode UMA vez, trocando só as duas coisas):
--     select public.ativar_bot('123456:TOKEN_DO_BOTFATHER', '123456789');
--  Diagnóstico:   select * from public.bot_log order by id desc limit 10;
--     'ok' = respondeu | 'nao_autorizado' = chat id errado (veja chat_id/de_id) | 'segredo_invalido' = rode ativar_bot de novo
--     tabela vazia  = o Telegram não está chegando no banco (veja getWebhookInfo ou use p_modo => 'edge')
-- =====================================================================

-- =====================================================================
--  14. PREENCHIMENTO EM ANDAMENTO (rascunhos): o que o cliente digita já chega ao vendedor, mesmo sem clicar em "Enviar"
--  • o site salva o que foi digitado (a cada pausa de digitação) por registrar_rascunho — "melhor esforço", nunca dá erro ao cliente;
--  • assim que o rascunho tem um telefone válido, o vendedor E o admin geral recebem aviso no Telegram;
--  • quando o cliente envia o formulário, o rascunho vira "completo" e some da lista "Em andamento";
--  • o painel do vendedor (aba Vendas) mostra os rascunhos com botão de WhatsApp e atualiza sozinho (tempo real).
-- =====================================================================
create table if not exists public.rascunhos(
  id uuid primary key,                                          -- gerado no navegador do cliente
  vendedor_id uuid not null references public.vendedores(id) on delete cascade,
  origem text not null check (origem in ('financiamento','ficha','contrato','chat')),
  nome text, telefone text, moto_nome text, cor text,
  dados jsonb not null default '{}'::jsonb,
  completo boolean not null default false, avisado boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
-- o chat também salva "em andamento" desde a 1ª resposta: libera a origem 'chat' (bancos que já tinham a regra antiga)
do $$ begin
  alter table public.rascunhos drop constraint if exists rascunhos_origem_check;
  alter table public.rascunhos add constraint rascunhos_origem_check check (origem in ('financiamento','ficha','contrato','chat'));
exception when others then raise notice 'não consegui ajustar a regra de origem dos rascunhos: %', sqlerrm; end $$;
alter table public.rascunhos add column if not exists fase smallint;
do $$ begin alter table public.rascunhos add constraint rascunhos_fase_chk check (fase is null or fase between 1 and 10); exception when duplicate_object then null; end $$;
create index if not exists i_rasc_v on public.rascunhos(vendedor_id, updated_at desc);
alter table public.rascunhos enable row level security;
drop policy if exists r_sel on public.rascunhos; drop policy if exists r_upd on public.rascunhos; drop policy if exists r_del on public.rascunhos;
create policy r_sel on public.rascunhos for select to authenticated using (public.pode_gerir(vendedor_id));
create policy r_upd on public.rascunhos for update to authenticated using (public.pode_gerir(vendedor_id)) with check (public.pode_gerir(vendedor_id));
create policy r_del on public.rascunhos for delete to authenticated using (public.pode_gerir(vendedor_id));
revoke all on public.rascunhos from public, anon, authenticated;
grant select, update, delete on public.rascunhos to authenticated;

create or replace function public.registrar_rascunho(p jsonb) returns void language plpgsql security definer set search_path = public as $$
declare v uuid := public.vendedor_ctx(); pid uuid := nullif(p->>'id', '')::uuid; o text := p->>'origem'; d jsonb := '{}'::jsonb; k text; val text; n int;
begin
  if v is null or not public.vendedor_ativo(v) then return; end if;                 -- melhor esforço: nunca erro para o cliente
  if pid is null or o is null or o not in ('financiamento', 'ficha', 'contrato', 'chat') then return; end if;
  select count(*) into n from public.rascunhos where vendedor_id = v and updated_at > now() - interval '1 minute';
  if n >= 300 then return; end if;                                                    -- anti-abuso
  for k, val in select key, left(btrim(value), 300) from jsonb_each_text(coalesce(p->'dados', '{}'::jsonb)) limit 40 loop
    if k ~ '^[a-z_]{1,40}$' and k not in ('id', 'vendedor_id', 'lgpd_aceite', 'status', 'created_at', 'completo') and coalesce(val, '') <> '' then
      d := d || jsonb_build_object(k, val);
    end if;
  end loop;
  insert into public.rascunhos as r(id, vendedor_id, origem, nome, telefone, moto_nome, cor, dados, completo)
  values (pid, v, o, left(nullif(btrim(p->>'nome'), ''), 120), left(nullif(btrim(p->>'telefone'), ''), 30),
          left(nullif(btrim(p->>'moto_nome'), ''), 160), left(nullif(btrim(p->>'cor'), ''), 40), d, coalesce((p->>'completo')::boolean, false))
  on conflict (id) do update set
      nome = coalesce(excluded.nome, r.nome), telefone = coalesce(excluded.telefone, r.telefone),
      moto_nome = coalesce(excluded.moto_nome, r.moto_nome), cor = coalesce(excluded.cor, r.cor),
      dados = r.dados || excluded.dados, completo = r.completo or excluded.completo, updated_at = now()
    where r.vendedor_id = v;
  perform public._rascunho_notificar(pid, v);
exception when others then return;
end $$;
revoke all on function public.registrar_rascunho(jsonb) from public;
grant execute on function public.registrar_rascunho(jsonb) to anon, authenticated;

-- aviso (Telegram) UMA única vez, quando o rascunho passa a ter telefone válido: vendedor + admin geral
-- (feito dentro da função, de forma atômica: o "upsert" do Postgres dispararia gatilhos em dobro)
drop trigger if exists a_aviso on public.rascunhos;
drop function if exists public.tg_rascunho_aviso();
create or replace function public._rascunho_notificar(p_id uuid, p_v uuid) returns void language plpgsql security definer set search_path = public as $$
declare s record; vn text; txt text; flag text; r_nome text; r_tel text; r_moto text; r_cor text; r_orig text;
begin
  update public.rascunhos set avisado = true
   where id = p_id and vendedor_id = p_v and not avisado and not completo and not public._eh_teste(nome)
     and length(regexp_replace(coalesce(telefone, ''), '\D', '', 'g')) >= 10
  returning nome, telefone, moto_nome, cor, origem into r_nome, r_tel, r_moto, r_cor, r_orig;
  if not found then return; end if;
  select nome into vn from public.vendedores where id = p_v;
  txt := E'✍️ Cliente começou a preencher (' || r_orig || E')\nVendedor: ' || coalesce(vn, '-') || E'\nNome: ' || coalesce(r_nome, '-')
      || E'\nTel: ' || coalesce(r_tel, '-') || E'\nMoto: ' || coalesce(r_moto, '-') || coalesce(E'\nCor: ' || r_cor, '')
      || E'\n(ainda não enviou o formulário: vale chamar no WhatsApp)';
  begin
    select telegram_token, telegram_chat_id into s from public.vendedor_segredos where vendedor_id = p_v;
    if s.telegram_token is not null and s.telegram_chat_id is not null then
      perform net.http_post(url := 'https://api.telegram.org/bot' || s.telegram_token || '/sendMessage',
        body := jsonb_build_object('chat_id', s.telegram_chat_id, 'text', txt), headers := '{"Content-Type":"application/json"}'::jsonb);
    end if;
  exception when others then null; end;
  begin
    select valor into flag from public.plataforma_config where chave = 'avisar_dono_pedidos';
    if coalesce(flag, 'sim') <> 'nao' then perform public.tg_dono(txt); end if;
  exception when others then null; end;
end $$;

-- quando o formulário é ENVIADO (ficha, pré-contrato ou lead de financiamento), o rascunho do mesmo telefone vira "completo"
create or replace function public.tg_rascunho_completa() returns trigger language plpgsql security definer set search_path = public as $$
declare j jsonb := to_jsonb(new); tel text := right(regexp_replace(coalesce(to_jsonb(new)->>'telefone', ''), '\D', '', 'g'), 10);
begin
  if length(tel) = 10 and (tg_table_name <> 'leads' or coalesce(j->>'tipo', '') in ('financiamento', 'ficha', 'contrato')) then
    update public.rascunhos set completo = true, updated_at = now()
     where vendedor_id = new.vendedor_id and not completo
       and right(regexp_replace(coalesce(telefone, ''), '\D', '', 'g'), 10) = tel;
  end if;
  return new;
exception when others then return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['fichas', 'contratos', 'leads'] loop
    execute format('drop trigger if exists h_completa on public.%I', t);
    execute format('create trigger h_completa after insert on public.%I for each row execute function public.tg_rascunho_completa()', t);
  end loop;
  -- tempo real no painel (respeita RLS): cada pedido/rascunho novo aparece sem recarregar
  foreach t in array array['leads', 'fichas', 'contratos', 'rascunhos'] loop
    execute format('alter table public.%I replica identity full', t);
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; when undefined_object then null; end;
  end loop;
end $$;
revoke all on function public._rascunho_notificar(uuid, uuid), public.tg_rascunho_completa() from public, anon, authenticated;

-- =====================================================================================================
--  CHECKUP DE ENTREGA — reproduz DENTRO do seu banco o caminho de um cliente real (visitante anônimo) e mostra,
--  etapa por etapa, o que funciona e o ERRO EXATO do que falhar. Os registros de teste são apagados no final.
--  Rode no SQL Editor (pode rodar sozinho, sem o resto):     select * from public.checkup_entrega('capelasso');
--  (troque capelasso pelo slug do vendedor que está sem receber pedidos)
-- =====================================================================================================
create or replace function public.checkup_entrega(p_slug text default null) returns table(etapa text, resultado text, detalhe text)
language plpgsql as $$
declare
  s text := lower(btrim(coalesce(p_slug, ''))); v record; tag text := '__TESTE_ENTREGA__'; pid uuid := gen_random_uuid(); n int; hdr text; flag text;
begin
  if s = '' then select slug into s from public.vendedores order by created_at desc limit 1; end if;
  select * into v from public.vendedores where slug = s;
  if not found then
    return query select '1. Vendedor', 'ERRO', 'O slug "' || s || '" NÃO existe. Slugs cadastrados: ' || coalesce((select string_agg(slug::text, ', ') from public.vendedores), '(nenhum)'); return;
  end if;
  return query select '1. Vendedor', case when v.suspenso then 'ERRO' else 'OK' end,
    v.nome || ' (slug ' || v.slug || ')' || case when v.suspenso then ' — SITE SUSPENSO: formulários recusam tudo' else ' — ativo' end;
  return query select '2. Login do vendedor', case when exists (select 1 from auth.users u where u.id = v.user_id) then 'OK' else 'ERRO' end,
    coalesce((select u.email::text from auth.users u where u.id = v.user_id), 'o vendedor não está ligado a nenhum login (user_id inválido)'::text);

  return query select '3. Função do chat existe e o visitante pode usar', case
      when to_regprocedure('public.registrar_pedido_chat(jsonb)') is null then 'ERRO'
      when has_function_privilege('anon', 'public.registrar_pedido_chat(jsonb)', 'execute') then 'OK' else 'ERRO' end,
    case when to_regprocedure('public.registrar_pedido_chat(jsonb)') is null then 'registrar_pedido_chat NÃO existe: rode o SQL único'
         when has_function_privilege('anon', 'public.registrar_pedido_chat(jsonb)', 'execute') then 'ok' else 'o visitante (anon) não tem permissão de executar' end;
  return query select '4. Função de "preenchimento em andamento"', case
      when to_regprocedure('public.registrar_rascunho(jsonb)') is null then 'FALTA'
      when has_function_privilege('anon', 'public.registrar_rascunho(jsonb)', 'execute') then 'OK' else 'ERRO' end,
    case when to_regprocedure('public.registrar_rascunho(jsonb)') is null then 'ainda não instalada: rode o SQL único atualizado' else 'ok' end;
  return query select '5. Formulários podem inserir leads (visitante)', case when exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'leads' and cmd = 'INSERT') then 'OK' else 'ERRO' end,
    coalesce((select string_agg(policyname::text, ', ') from pg_policies where schemaname = 'public' and tablename = 'leads' and cmd = 'INSERT'), 'não há política de insert em leads')::text;

  -- silencia os avisos de Telegram durante o teste
  select valor into flag from public.plataforma_config where chave = 'avisar_dono_pedidos';
  insert into public.plataforma_config(chave, valor) values ('avisar_dono_pedidos', 'nao') on conflict (chave) do update set valor = 'nao';

  hdr := json_build_object('x-vendedor', s)::text;
  -- A) CHAT: o que acontece quando o cliente termina a conversa
  begin
    perform set_config('request.headers', hdr, true); set local role anon;
    perform public.registrar_pedido_chat(jsonb_build_object('id', pid, 'completo', true, 'nome', tag, 'nome_completo', tag, 'telefone', '+5568900000000',
        'moto_nome', 'TESTE',
        'moto_id', coalesce((select m2.id::text from public.motos m2 where m2.vendedor_id = v.id limit 1), ''), 'pagamento', 'consorcio', 'parcela', '60x de R$ 1,00', 'mensagem', 'teste de entrega'));
    reset role;
    select count(*) into n from public.pedidos_chat where id = pid and vendedor_id = v.id;
    return query select '6. TESTE: cliente termina o chat', case when n = 1 then 'OK' else 'ERRO' end,
      case when n = 1 then 'pedido gravado no vendedor certo' else 'a função rodou sem erro mas NÃO gravou (veja vendedor_ctx e o cabeçalho x-vendedor)' end;
  exception when others then
    reset role; return query select '6. TESTE: cliente termina o chat', 'ERRO', sqlerrm;
  end;
  -- B) FORMULÁRIO (lead direto na tabela)
  begin
    perform set_config('request.headers', hdr, true); set local role anon;
    insert into public.leads(tipo, nome, telefone, moto_nome) values ('teste', tag, '+5568900000000', 'TESTE');
    reset role;
    select count(*) into n from public.leads where nome = tag and vendedor_id = v.id;
    return query select '7. TESTE: formulário de financiamento (lead)', case when n = 1 then 'OK' else 'ERRO' end, case when n = 1 then 'lead gravado no vendedor certo' else 'inseriu mas não ficou com este vendedor' end;
  exception when others then
    reset role; return query select '7. TESTE: formulário de financiamento (lead)', 'ERRO', sqlerrm;
  end;
  -- C) PREENCHIMENTO EM ANDAMENTO
  if to_regprocedure('public.registrar_rascunho(jsonb)') is not null then
    begin
      perform set_config('request.headers', hdr, true); set local role anon;
      perform public.registrar_rascunho(jsonb_build_object('id', gen_random_uuid(), 'origem', 'financiamento', 'nome', tag, 'telefone', '(68) 90000-0000', 'moto_nome', 'TESTE', 'dados', jsonb_build_object('nome', tag)));
      reset role;
      execute 'select count(*) from public.rascunhos where nome = $1 and vendedor_id = $2' into n using tag, v.id;
      return query select '8. TESTE: cliente digitando (sem enviar)', case when n = 1 then 'OK' else 'ERRO' end, case when n = 1 then 'rascunho gravado' else 'não gravou o rascunho' end;
    exception when others then
      reset role; return query select '8. TESTE: cliente digitando (sem enviar)', 'ERRO', sqlerrm;
    end;
  end if;
  -- C2) CHAT desde a 1ª resposta (cópia "em andamento" com origem chat)
  if to_regprocedure('public.registrar_rascunho(jsonb)') is not null then
    begin
      perform set_config('request.headers', hdr, true); set local role anon;
      perform public.registrar_rascunho(jsonb_build_object('id', gen_random_uuid(), 'origem', 'chat', 'nome', tag, 'dados', jsonb_build_object('nome', tag, 'etapa', 'nome')));
      reset role;
      execute 'select count(*) from public.rascunhos where nome = $1 and origem = ''chat'' and vendedor_id = $2' into n using tag, v.id;
      return query select '8b. TESTE: chat salva desde a 1ª resposta', case when n = 1 then 'OK' else 'ERRO' end, case when n = 1 then 'ok' else 'não gravou: rode o SQL único atualizado (origem chat)' end;
    exception when others then
      reset role; return query select '8b. TESTE: chat salva desde a 1ª resposta', 'ERRO', sqlerrm;
    end;
  end if;
  -- D) PAINEL: o vendedor logado enxerga o que chegou?
  begin
    perform set_config('request.headers', hdr, true);
    perform set_config('request.jwt.claim.sub', v.user_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', v.user_id, 'role', 'authenticated')::text, true);
    set local role authenticated;
    select count(*) into n from public.pedidos_chat where nome = tag;
    reset role;
    return query select '9. TESTE: painel do vendedor enxerga o pedido', case when n >= 1 then 'OK' else 'ERRO' end,
      case when n >= 1 then 'o vendedor logado vê o pedido' else 'o pedido existe no banco mas o painel NÃO o enxerga (RLS/pode_gerir)' end;
  exception when others then
    reset role; return query select '9. TESTE: painel do vendedor enxerga o pedido', 'ERRO', sqlerrm;
  end;
  -- E) o site mostra as motos para o visitante?
  begin
    perform set_config('request.headers', hdr, true); set local role anon;
    select count(*) into n from public.motos; reset role;
    return query select '10. Site mostra motos ao visitante', case when n > 0 then 'OK' else 'ERRO' end, n || ' moto(s) visíveis' || case when n = 0 then ' (vitrine vazia)' else '' end;
  exception when others then
    reset role; return query select '10. Site mostra motos ao visitante', 'ERRO', sqlerrm;
  end;

  -- limpeza
  delete from public.pedidos_chat where nome = tag;
  delete from public.leads where nome = tag;
  if to_regclass('public.rascunhos') is not null then execute 'delete from public.rascunhos where nome = $1' using tag; end if;
  if flag is null then delete from public.plataforma_config where chave = 'avisar_dono_pedidos'; else update public.plataforma_config set valor = flag where chave = 'avisar_dono_pedidos'; end if;
  return query select '11. Limpeza', 'OK', 'registros de teste apagados';
end $$;
revoke all on function public.checkup_entrega(text) from public, anon, authenticated;

-- Testa TODOS os vendedores de uma vez (cadastrados hoje e os que forem cadastrados depois): uma linha por vendedor.
--     select * from public.checkup_entrega_todos();
create or replace function public.checkup_entrega_todos() returns table(vendedor text, slug text, resultado text, detalhe text)
language plpgsql as $$
declare v record; r jsonb; falhas text;
begin
  for v in select vd.slug as s, vd.nome as nm, vd.suspenso as sus from public.vendedores vd order by vd.created_at, vd.slug loop
    if v.sus then
      return query select v.nm::text, v.s::text, 'SUSPENSO'::text, 'site suspenso de propósito: os formulários recusam tudo até reativar'::text; continue;
    end if;
    select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into r from public.checkup_entrega(v.s) c;
    select string_agg((e->>'etapa') || ': ' || (e->>'detalhe'), ' | ') into falhas from jsonb_array_elements(r) e where e->>'resultado' in ('ERRO', 'FALTA');
    if falhas is null then
      return query select v.nm::text, v.s::text, 'OK'::text, 'todas as etapas passaram'::text;
    else
      return query select v.nm::text, v.s::text, 'ERRO'::text, falhas;
    end if;
  end loop;
  if not found then return query select '(nenhum)'::text, ''::text, 'ERRO'::text, 'não há vendedores cadastrados'::text; end if;
end $$;
revoke all on function public.checkup_entrega_todos() from public, anon, authenticated;



-- Para testar a entrega de pedidos de um vendedor:  select * from public.checkup_entrega('slug-do-vendedor');

-- =====================================================================
--  FIM DO SCRIPT 01 (base). Próximo: SQL_02_catalogo_geral.
--  Para ligar o bot (uma vez, com o token NOVO do @BotFather):  select public.ativar_bot('TOKEN', 'CHAT_ID');
-- =====================================================================


-- #####################################################################################################
-- #####  2/4 · CATÁLOGO GERAL + ADMIN GERAL + CONFIGURAÇÕES (vídeo e dados da loja)
-- #####################################################################################################

-- =====================================================================================================
--  SCRIPT 02 · CATÁLOGO GERAL (ADMIN GERAL)  —  um único cadastro de motos que alimenta TODOS os sites dos vendedores
--  Rode DEPOIS do SQL_01_base. Seguro rodar mais de uma vez (não apaga nem reseta o que você editar no admin geral).
--
--  O que faz:
--   • cria o catálogo geral (tabela catalogo_mestre) com as motos, fotos, descrição, planos de consórcio (do site
--     vendedor.site/shayrondahonda), preço à vista e cores disponíveis; liga as motos de todos os vendedores a ele;
--   • CONSÓRCIO TRAVADO: planos, valores e condição de emplacamento são sempre os do catálogo (o vendedor não edita);
--   • o que o vendedor personaliza (descrição, fotos, preço à vista etc.) fica protegido de atualizações em massa
--     (o admin geral pode "forçar em todos"); moto suspensa pelo admin geral some em todos os sites;
--   • vendedor novo já nasce com o catálogo completo;
--   • o ADMIN GERAL passa a ser filipecapelasso27@gmail.com (login e senha definidos no passo 14).
--  Tabelas: catalogo_mestre (nova) | motos (colunas catalogo_id, custom, bloqueada_mestre, cores) | donos (admin geral)
--  Remove o que ficou obsoleto: tabela planos_padrao e as funções antigas de "planos padrão".
--  NÃO mexe em user_id, em fichas/contratos/leads/pedidos nem em dados de clientes.
-- =====================================================================================================

-- ---------- 0. pré-requisitos ----------
do $$ begin
  if to_regclass('public.motos') is null or to_regclass('public.vendedores') is null or to_regclass('public.donos') is null
     or to_regclass('public.plataforma_config') is null then
    raise exception 'Faltam as tabelas base. Rode primeiro o SQL_01_base.';
  end if;
end $$;

-- ---------- 1. utilidades ----------

create or replace function public.norm_moto(t text) returns text language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(translate(upper(coalesce(t, '')), '×', 'X'), '\s*\([^)]*\)\s*', ' ', 'g'), '\s+', ' ', 'g')) $$;
create or replace function public.plano_qtd(j jsonb) returns int language sql immutable as $$
  select case when jsonb_typeof(j) = 'array' then jsonb_array_length(j) else 0 end $$;
create or replace function public.plano_igual_ou_subconjunto(cur jsonb, pad jsonb) returns boolean language sql immutable as $$
  select public.plano_qtd(cur) > 0 and not exists (
    select 1 from jsonb_array_elements(cur) e
     where not exists (select 1 from jsonb_array_elements(pad) s
            where (s->>'parcelas')::numeric = (e->>'parcelas')::numeric
              and abs((s->>'valor')::numeric - (e->>'valor')::numeric) <= 0.011)) $$;
create or replace function public.planos_equivalentes(a jsonb, b jsonb) returns boolean language sql immutable as $$
  select public.plano_qtd(a) = public.plano_qtd(b) and (public.plano_qtd(a) = 0 or public.plano_igual_ou_subconjunto(a, b)) $$;

-- ---------- 2. catálogo geral ----------
create table if not exists public.catalogo_mestre(
  id uuid primary key default gen_random_uuid(),
  nome text not null, modelo text, categoria text, selo text,
  preco numeric,                                   -- preço à vista
  descricao text,
  fotos jsonb not null default '[]',
  video_url text,
  planos jsonb not null default '[]',              -- consórcio: [{parcelas, valor}]
  emplacamento text,
  cores jsonb not null default '[]',               -- cores disponíveis: ["Prata","Preto"]
  ordem int not null default 0,
  ativo boolean not null default true,             -- false = suspensa em todos os sites
  sync_site boolean not null default true,         -- true = planos atualizados todo dia a partir do site
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
alter table public.catalogo_mestre add column if not exists sync_site boolean not null default true;
create unique index if not exists catalogo_mestre_nome_norm on public.catalogo_mestre (public.norm_moto(nome));
alter table public.catalogo_mestre enable row level security;
drop policy if exists cm_dono_sel on public.catalogo_mestre;
create policy cm_dono_sel on public.catalogo_mestre for select to authenticated using (public.eh_dono());
revoke all on public.catalogo_mestre from public, anon;
grant select on public.catalogo_mestre to authenticated;       -- só o dono enxerga (policy); escrita só pelas funções

-- ---------- 3. motos dos vendedores ficam ligadas ao catálogo ----------
alter table public.motos add column if not exists catalogo_id uuid references public.catalogo_mestre(id) on delete set null;
alter table public.motos add column if not exists custom text[] not null default '{}';          -- campos que o VENDEDOR personalizou
alter table public.motos add column if not exists bloqueada_mestre boolean not null default false; -- suspensa pelo admin geral
alter table public.motos add column if not exists cores jsonb not null default '[]';
create index if not exists motos_catalogo_idx on public.motos(catalogo_id);

-- lê os valores do catálogo para o trigger (o vendedor não pode ler o catálogo direto; planos e condição já são públicos nos sites)

create or replace function public._mestre_valores(p_id uuid, p_nome text) returns table(planos jsonb, emplacamento text)
language sql stable security definer set search_path = public as $$
  select c.planos, c.emplacamento from public.catalogo_mestre c
   where (p_id is not null and c.id = p_id) or (p_id is null and public.norm_moto(c.nome) = public.norm_moto(p_nome)) limit 1 $$;

-- ---------- 4. trigger: protege campos do sistema, registra personalização e TRAVA o consórcio ----------
create or replace function public.tg_mestre_motos() returns trigger language plpgsql as $$
declare c text[] := '{}'; m_planos jsonb; m_emp text; m_ok boolean := false;
begin
  if current_user not in ('anon', 'authenticated') then return new; end if;     -- sistema/admin geral: não marca personalização
  if tg_op = 'INSERT' then
    new.catalogo_id := null; new.custom := '{}'; new.bloqueada_mestre := false;
    select v.planos, v.emplacamento into m_planos, m_emp from public._mestre_valores(null, new.nome) v;   -- cópia de moto do catálogo: planos vêm do catálogo
    if found then new.planos := m_planos; new.emplacamento := m_emp; end if;
    return new;
  end if;
  new.catalogo_id := old.catalogo_id; new.bloqueada_mestre := old.bloqueada_mestre; new.cores := old.cores; new.custom := old.custom;
  select v.planos, v.emplacamento into m_planos, m_emp from public._mestre_valores(old.catalogo_id, new.nome) v; m_ok := found;
  if m_ok then new.planos := m_planos; new.emplacamento := m_emp; end if;   -- TRAVA: valores do consórcio = os do site
  if old.catalogo_id is null then return new; end if;
  if upper(btrim(new.nome)) is distinct from upper(btrim(old.nome)) then c := array_append(c, 'nome'::text); end if;
  if coalesce(btrim(new.modelo), '') is distinct from coalesce(btrim(old.modelo), '') then c := array_append(c, 'modelo'::text); end if;
  if coalesce(btrim(new.categoria), '') is distinct from coalesce(btrim(old.categoria), '') then c := array_append(c, 'categoria'::text); end if;
  if coalesce(btrim(new.selo), '') is distinct from coalesce(btrim(old.selo), '') then c := array_append(c, 'selo'::text); end if;
  if coalesce(new.preco, 0) is distinct from coalesce(old.preco, 0) then c := array_append(c, 'preco'::text); end if;
  if coalesce(btrim(new.descricao), '') is distinct from coalesce(btrim(old.descricao), '') then c := array_append(c, 'descricao'::text); end if;
  if new.fotos is distinct from old.fotos then c := array_append(c, 'fotos'::text); end if;
  if coalesce(btrim(new.video_url), '') is distinct from coalesce(btrim(old.video_url), '') then c := array_append(c, 'video_url'::text); end if;
  if old.bloqueada_mestre then new.ativo := false;
  elsif new.ativo is distinct from old.ativo then c := array_append(c, 'ativo'::text); end if;
  new.custom := (select coalesce(array_agg(distinct x), '{}') from unnest(old.custom || c) x where x not in ('planos', 'emplacamento'));
  return new;
end $$;
drop trigger if exists c_mestre on public.motos;
create trigger c_mestre before insert or update on public.motos for each row execute function public.tg_mestre_motos();

-- ---------- 5. permissão: só o dono (admin geral) ----------
create or replace function public.sou_dono() returns boolean language sql stable security definer set search_path = public as $$ select public.eh_dono() $$;
create or replace function public._exige_dono() returns void language plpgsql security definer set search_path = public as $$
begin
  if public.eh_dono() then return; end if;
  if auth.uid() is null and session_user in ('postgres', 'supabase_admin', 'service_role') then return; end if;   -- SQL Editor
  raise exception 'Somente o administrador geral pode fazer isso';
end $$;

-- ---------- 6. aplicar mudanças do catálogo em todos os vendedores ----------
create or replace function public._mestre_aplicar(p_id uuid, p jsonb, p_forcar boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare campos text[]; n_tot int; n_prot int := 0; k text;
begin
  if not exists (select 1 from public.catalogo_mestre where id = p_id) then raise exception 'Moto do catálogo não encontrada'; end if;
  if p ? 'nome' and btrim(coalesce(p->>'nome', '')) = '' then raise exception 'O nome da moto é obrigatório'; end if;
  update public.catalogo_mestre c set
      nome = case when p ? 'nome' then btrim(p->>'nome') else c.nome end,
      modelo = case when p ? 'modelo' then nullif(btrim(p->>'modelo'), '') else c.modelo end,
      categoria = case when p ? 'categoria' then nullif(btrim(p->>'categoria'), '') else c.categoria end,
      selo = case when p ? 'selo' then nullif(btrim(p->>'selo'), '') else c.selo end,
      preco = case when p ? 'preco' then nullif(p->>'preco', '')::numeric else c.preco end,
      descricao = case when p ? 'descricao' then p->>'descricao' else c.descricao end,
      fotos = case when p ? 'fotos' then coalesce(nullif(p->'fotos', 'null'::jsonb), '[]'::jsonb) else c.fotos end,
      video_url = case when p ? 'video_url' then nullif(btrim(p->>'video_url'), '') else c.video_url end,
      planos = case when p ? 'planos' then coalesce(nullif(p->'planos', 'null'::jsonb), '[]'::jsonb) else c.planos end,
      emplacamento = case when p ? 'emplacamento' then nullif(btrim(p->>'emplacamento'), '') else c.emplacamento end,
      cores = case when p ? 'cores' then coalesce(nullif(p->'cores', 'null'::jsonb), '[]'::jsonb) else c.cores end,
      ordem = case when p ? 'ordem' then coalesce(nullif(p->>'ordem', '')::int, c.ordem) else c.ordem end,
      sync_site = case when p ? 'sync_site' then coalesce((p->>'sync_site')::boolean, c.sync_site) else c.sync_site end,
      updated_at = now()
   where c.id = p_id;
  select coalesce(array_agg(x), '{}') into campos from jsonb_object_keys(p) x
   where x in ('nome','modelo','categoria','selo','preco','descricao','fotos','video_url','planos','emplacamento');
  select count(*) into n_tot from public.motos where catalogo_id = p_id;
  if not p_forcar then select count(*) into n_prot from public.motos where catalogo_id = p_id and custom && campos; end if;
  update public.motos t set
      nome = case when p ? 'nome' and (p_forcar or not ('nome' = any (t.custom))) then btrim(p->>'nome') else t.nome end,
      modelo = case when p ? 'modelo' and (p_forcar or not ('modelo' = any (t.custom))) then nullif(btrim(p->>'modelo'), '') else t.modelo end,
      categoria = case when p ? 'categoria' and (p_forcar or not ('categoria' = any (t.custom))) then nullif(btrim(p->>'categoria'), '') else t.categoria end,
      selo = case when p ? 'selo' and (p_forcar or not ('selo' = any (t.custom))) then nullif(btrim(p->>'selo'), '') else t.selo end,
      preco = case when p ? 'preco' and (p_forcar or not ('preco' = any (t.custom))) then nullif(p->>'preco', '')::numeric else t.preco end,
      descricao = case when p ? 'descricao' and (p_forcar or not ('descricao' = any (t.custom))) then p->>'descricao' else t.descricao end,
      fotos = case when p ? 'fotos' and (p_forcar or not ('fotos' = any (t.custom))) then coalesce(nullif(p->'fotos', 'null'::jsonb), '[]'::jsonb) else t.fotos end,
      video_url = case when p ? 'video_url' and (p_forcar or not ('video_url' = any (t.custom))) then nullif(btrim(p->>'video_url'), '') else t.video_url end,
      planos = case when p ? 'planos' then coalesce(nullif(p->'planos', 'null'::jsonb), '[]'::jsonb) else t.planos end,
      emplacamento = case when p ? 'emplacamento' then nullif(btrim(p->>'emplacamento'), '') else t.emplacamento end,
      cores = case when p ? 'cores' then coalesce(nullif(p->'cores', 'null'::jsonb), '[]'::jsonb) else t.cores end,
      custom = case when p_forcar then array(select x from unnest(t.custom) x where x <> all (campos)) else t.custom end
   where t.catalogo_id = p_id;
  if p ? 'planos' or p ? 'emplacamento' then      -- cópias soltas da mesma moto (sem vínculo) também acompanham o catálogo
    update public.motos t set planos = c.planos, emplacamento = c.emplacamento from public.catalogo_mestre c
     where c.id = p_id and t.catalogo_id is null and public.norm_moto(t.nome) = public.norm_moto(c.nome);
  end if;
  return format('Salvo. Atualizado em %s vendedor(es)%s.', n_tot,
         case when n_prot > 0 then format('; em %s deles algum campo foi mantido porque o vendedor personalizou (use "forçar em todos" para sobrescrever)', n_prot) else '' end);
end $$;
create or replace function public.mestre_salvar(p_id uuid, p jsonb, p_forcar boolean default false) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  return public._mestre_aplicar(p_id, p, p_forcar);
end $$;

-- ---------- 7. ligar/criar motos dos vendedores a partir do catálogo ----------
create or replace function public.mestre_vincular() returns text
language plpgsql security definer set search_path = public as $$
declare n_link int := 0;
begin
  create temp table if not exists _vinc(tid uuid primary key, cid uuid) on commit drop;
  delete from _vinc;
  insert into _vinc select distinct on (t.id) t.id, c.id from public.motos t
    join public.catalogo_mestre c on public.norm_moto(c.nome) = public.norm_moto(t.nome)
   where t.catalogo_id is null order by t.id, c.ordem;
  get diagnostics n_link = row_count;
  update public.motos t set catalogo_id = v.cid from _vinc v where t.id = v.tid;
  -- planos e condição: SEMPRE os do catálogo (consórcio travado)
  update public.motos t set planos = c.planos, emplacamento = c.emplacamento
    from public.catalogo_mestre c, _vinc v where t.id = v.tid and c.id = v.cid and public.plano_qtd(c.planos) > 0;
  -- o que difere do catálogo já nasce como "personalizado" (fica protegido de atualizações em massa)
  update public.motos t set custom = coalesce((select array_agg(f) from (values
      ('nome',         upper(btrim(t.nome)) is distinct from upper(btrim(c.nome))),
      ('modelo',       coalesce(btrim(t.modelo), '') is distinct from coalesce(btrim(c.modelo), '')),
      ('categoria',    coalesce(btrim(t.categoria), '') is distinct from coalesce(btrim(c.categoria), '')),
      ('selo',         coalesce(btrim(t.selo), '') is distinct from coalesce(btrim(c.selo), '')),
      ('preco',        coalesce(t.preco, 0) is distinct from coalesce(c.preco, 0)),
      ('descricao',    coalesce(btrim(t.descricao), '') is distinct from coalesce(btrim(c.descricao), '')),
      ('fotos',        t.fotos is distinct from c.fotos),
      ('video_url',    coalesce(btrim(t.video_url), '') is distinct from coalesce(btrim(c.video_url), '')),
      ('ativo',        c.ativo and t.ativo is distinct from c.ativo)) x(f, diff) where diff), '{}'),
      cores = c.cores,
      bloqueada_mestre = not c.ativo,
      ativo = case when c.ativo then t.ativo else false end
    from public.catalogo_mestre c, _vinc v where t.id = v.tid and c.id = v.cid;
  return n_link || ' moto(s) ligada(s) ao catálogo geral';
end $$;
create or replace function public.mestre_sincronizar_vendedor(p_slug text) returns text
language plpgsql security definer set search_path = public as $$
declare did uuid; base int; n int := 0;
begin
  select id into did from public.vendedores where slug = lower(btrim(p_slug));
  if did is null then raise exception 'Slug "%" não existe.', p_slug; end if;
  select max(ordem) into base from public.motos where vendedor_id = did;
  with novas as (
    select c.*, row_number() over (order by c.ordem, c.created_at) rn from public.catalogo_mestre c
     where not exists (select 1 from public.motos m where m.vendedor_id = did and (m.catalogo_id = c.id or public.norm_moto(m.nome) = public.norm_moto(c.nome))))
  insert into public.motos(vendedor_id, catalogo_id, nome, modelo, categoria, selo, preco, descricao, fotos, video_url, planos, emplacamento, cores, ordem, ativo, bloqueada_mestre)
  select did, n.id, n.nome, n.modelo, n.categoria, n.selo, n.preco, n.descricao, n.fotos, n.video_url, n.planos, n.emplacamento, n.cores,
         case when base is null then n.ordem else base + n.rn end, n.ativo, not n.ativo from novas n;
  get diagnostics n = row_count;
  perform public.mestre_vincular();
  return format('%s: %s moto(s) criada(s) a partir do catálogo geral', lower(btrim(p_slug)), n);
end $$;
create or replace function public.mestre_sincronizar_todos() returns text
language plpgsql security definer set search_path = public as $$
declare r record; txt text := ''; k int := 0;
begin
  perform public._exige_dono();
  for r in select slug from public.vendedores order by created_at loop
    txt := txt || E'\n' || public.mestre_sincronizar_vendedor(r.slug); k := k + 1;
  end loop;
  return k || ' vendedor(es) verificados:' || txt;
end $$;

-- ---------- 8. admin geral: adicionar, suspender, estatísticas ----------
create or replace function public.mestre_adicionar(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  perform public._exige_dono();
  if btrim(coalesce(p->>'nome', '')) = '' then raise exception 'O nome da moto é obrigatório'; end if;
  if exists (select 1 from public.catalogo_mestre where public.norm_moto(nome) = public.norm_moto(p->>'nome')) then raise exception 'Já existe uma moto com esse nome no catálogo'; end if;
  insert into public.catalogo_mestre(nome, modelo, categoria, selo, preco, descricao, fotos, video_url, planos, emplacamento, cores, ordem)
  values (btrim(p->>'nome'), nullif(btrim(p->>'modelo'), ''), nullif(btrim(p->>'categoria'), ''), nullif(btrim(p->>'selo'), ''),
          nullif(p->>'preco', '')::numeric, p->>'descricao', coalesce(nullif(p->'fotos', 'null'::jsonb), '[]'::jsonb), nullif(btrim(p->>'video_url'), ''),
          coalesce(nullif(p->'planos', 'null'::jsonb), '[]'::jsonb), nullif(btrim(p->>'emplacamento'), ''), coalesce(nullif(p->'cores', 'null'::jsonb), '[]'::jsonb),
          coalesce(nullif(p->>'ordem', '')::int, (select coalesce(max(ordem), -1) + 1 from public.catalogo_mestre)))
  returning id into nid;
  perform public.mestre_sincronizar_todos();
  return nid;
end $$;
create or replace function public.mestre_suspender(p_id uuid, p_suspender boolean) returns text
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public._exige_dono();
  update public.catalogo_mestre set ativo = not p_suspender, updated_at = now() where id = p_id;
  if not found then raise exception 'Moto do catálogo não encontrada'; end if;
  if p_suspender then
    update public.motos set ativo = false, bloqueada_mestre = true where catalogo_id = p_id;
  else
    update public.motos set bloqueada_mestre = false, ativo = case when 'ativo' = any (custom) then ativo else true end where catalogo_id = p_id;
  end if;
  get diagnostics n = row_count;
  return format('%s em %s vendedor(es).', case when p_suspender then 'Suspensa' else 'Reativada' end, n);
end $$;
create or replace function public.mestre_estatisticas() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  return jsonb_build_object(
    'vendedores', (select count(*) from public.vendedores),
    'motos', coalesce((select jsonb_agg(jsonb_build_object('id', c.id,
        'vendedores', (select count(*) from public.motos m where m.catalogo_id = c.id),
        'personalizados', (select count(*) from public.motos m where m.catalogo_id = c.id and cardinality(m.custom) > 0))) from public.catalogo_mestre c), '[]'::jsonb));
end $$;

-- ---------- 9. vendedor novo e vendedores sem motos recebem o catálogo geral ----------
create or replace function public.copiar_catalogo(p_slug text, p_substituir boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare modelo text; mid uuid; did uuid; n_dest int; cols text; n int; extra text;
begin
  select id into did from public.vendedores where slug = lower(btrim(p_slug));
  if did is null then raise exception 'Slug "%" não existe.', p_slug; end if;
  select count(*) into n_dest from public.motos where vendedor_id = did;
  if n_dest > 0 and not p_substituir then
    return format('Esse vendedor já tem %s motos (nada copiado). Para refazer do zero: /catalogo %s substituir', n_dest, lower(btrim(p_slug))); end if;
  if exists (select 1 from public.catalogo_mestre) then
    if p_substituir then delete from public.motos where vendedor_id = did; end if;
    extra := public.mestre_sincronizar_vendedor(p_slug);
    select count(*) into n from public.motos where vendedor_id = did;
    return format('%s motos/motores copiados do catálogo geral. %s', n, extra);
  end if;
  -- sem catálogo geral ainda: comportamento antigo (copia do vendedor modelo)
  select valor into modelo from public.plataforma_config where chave = 'vendedor_modelo';
  if modelo is null then return 'Sem vendedor modelo definido (use /modelo slug).'; end if;
  select id into mid from public.vendedores where slug = modelo;
  if mid is null then return format('O vendedor modelo "%s" não existe mais (use /modelo slug).', modelo); end if;
  if did = mid then return 'Esse é o próprio vendedor modelo.'; end if;
  if p_substituir then delete from public.motos where vendedor_id = did; end if;
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'public' and table_name = 'motos'
     and column_name not in ('id', 'vendedor_id', 'created_at', 'catalogo_id', 'custom', 'bloqueada_mestre');
  execute format('insert into public.motos(vendedor_id, %1$s) select $1, %1$s from public.motos where vendedor_id = $2', cols) using did, mid;
  get diagnostics n = row_count;
  return format('%s motos/motores copiados do modelo (%s).', n, modelo);
end $$;
create or replace function public.copiar_catalogo_todos() returns text
language plpgsql security definer set search_path = public as $$
declare r record; txt text := ''; n int := 0;
begin
  for r in select v.slug from public.vendedores v where not exists (select 1 from public.motos m where m.vendedor_id = v.id) order by v.created_at loop
    txt := txt || E'\n' || r.slug || ': ' || public.copiar_catalogo(r.slug); n := n + 1;
  end loop;
  if n = 0 then return 'Nenhum vendedor sem motos. Nada a copiar.'; end if;
  return n || ' vendedor(es) atendidos:' || txt;
end $$;

-- botão antigo do painel (versões antigas do site ainda chamam): agora só informa
create or replace function public.carregar_meus_planos(p_vendedor uuid) returns text
language plpgsql security definer set search_path = public as $$
begin return 'Os planos do consórcio agora são atualizados automaticamente pelo site oficial.'; end $$;

-- ---------- 10. fotos do admin geral (pasta "mestre" do bucket midia) ----------
drop policy if exists midia_dono_mestre on storage.objects;
create policy midia_dono_mestre on storage.objects for all to authenticated
  using (bucket_id = 'midia' and public.eh_dono() and (storage.foldername(name))[1] = 'mestre')
  with check (bucket_id = 'midia' and public.eh_dono() and (storage.foldername(name))[1] = 'mestre');


-- ---------- 11. permissões das funções ----------
revoke all on function public.norm_moto(text), public.plano_qtd(jsonb), public.plano_igual_ou_subconjunto(jsonb, jsonb), public.planos_equivalentes(jsonb, jsonb),
  public.tg_mestre_motos(), public._exige_dono(), public._mestre_aplicar(uuid, jsonb, boolean), public.mestre_vincular(), public.mestre_sincronizar_vendedor(text),
  public.copiar_catalogo(text, boolean), public.copiar_catalogo_todos() from public, anon, authenticated;
grant execute on function public.norm_moto(text), public.plano_qtd(jsonb), public.plano_igual_ou_subconjunto(jsonb, jsonb), public.planos_equivalentes(jsonb, jsonb) to anon, authenticated;  -- usadas pelo trigger
grant execute on function public.tg_mestre_motos() to anon, authenticated;
revoke all on function public.mestre_salvar(uuid, jsonb, boolean), public.mestre_adicionar(jsonb), public.mestre_suspender(uuid, boolean),
  public.mestre_estatisticas(), public.mestre_sincronizar_todos(), public.sou_dono(), public.carregar_meus_planos(uuid) from public, anon, authenticated;
grant execute on function public.mestre_salvar(uuid, jsonb, boolean), public.mestre_adicionar(jsonb), public.mestre_suspender(uuid, boolean),
  public.mestre_estatisticas(), public.mestre_sincronizar_todos(), public.sou_dono(), public.carregar_meus_planos(uuid) to authenticated;   -- cada uma confere se é o dono

-- ---------- 12. CARGA INICIAL (só cria o que ainda não existe; nunca sobrescreve edição sua) ----------
--  Fonte: motos do vendedor modelo (fotos, nomes, descrição) + planos e emplacamento do site https://vendedor.site/shayrondahonda
do $$
declare modelo text; mid uuid; r record; nid uuid; k int := 0;
begin
  create temp table _site(nome_norm text primary key, emp text, planos jsonb) on commit drop;
  insert into _site values
  ('POP 110I ES +10%', 'Com emplacamento', '[{"parcelas":80,"valor":216.59},{"parcelas":60,"valor":280.54},{"parcelas":48,"valor":345.55},{"parcelas":36,"valor":455.23},{"parcelas":24,"valor":669.58},{"parcelas":18,"valor":887.6},{"parcelas":12,"valor":1323.66}]'::jsonb),
  ('BIZ 125 ES', 'Com emplacamento', '[{"parcelas":80,"valor":273.75},{"parcelas":60,"valor":354.56},{"parcelas":48,"valor":436.72},{"parcelas":36,"valor":575.35},{"parcelas":24,"valor":846.25},{"parcelas":18,"valor":1121.8},{"parcelas":12,"valor":1672.91}]'::jsonb),
  ('ELITE 125', 'Com emplacamento', '[{"parcelas":80,"valor":287.34},{"parcelas":60,"valor":372.16},{"parcelas":48,"valor":458.4},{"parcelas":36,"valor":603.92},{"parcelas":24,"valor":888.27},{"parcelas":18,"valor":1177.49},{"parcelas":12,"valor":1755.97}]'::jsonb),
  ('BIZ 125 EX', 'Com emplacamento', '[{"parcelas":80,"valor":339.18},{"parcelas":60,"valor":439.31},{"parcelas":48,"valor":541.12},{"parcelas":36,"valor":712.89},{"parcelas":24,"valor":1048.54},{"parcelas":18,"valor":1389.96},{"parcelas":12,"valor":2072.81}]'::jsonb),
  ('CG 160 START', 'Com emplacamento', '[{"parcelas":80,"valor":349.24},{"parcelas":60,"valor":452.34},{"parcelas":48,"valor":557.16},{"parcelas":36,"valor":734.03},{"parcelas":24,"valor":1079.64},{"parcelas":18,"valor":1431.17},{"parcelas":12,"valor":2134.28}]'::jsonb),
  ('PCX CBS', 'Com emplacamento', '[{"parcelas":80,"valor":374.6},{"parcelas":60,"valor":485.19},{"parcelas":48,"valor":597.62},{"parcelas":36,"valor":787.33},{"parcelas":24,"valor":1158.04},{"parcelas":18,"valor":1535.11},{"parcelas":12,"valor":2289.27}]'::jsonb),
  ('CG 160 FAN', 'Com emplacamento', '[{"parcelas":80,"valor":381.06},{"parcelas":60,"valor":493.56},{"parcelas":48,"valor":607.93},{"parcelas":36,"valor":800.91},{"parcelas":24,"valor":1178.01},{"parcelas":18,"valor":1561.58},{"parcelas":12,"valor":2328.74}]'::jsonb),
  ('CG 160 TITAN', 'Com emplacamento', '[{"parcelas":80,"valor":404.82},{"parcelas":60,"valor":524.33},{"parcelas":48,"valor":645.83},{"parcelas":36,"valor":850.85},{"parcelas":24,"valor":1251.46},{"parcelas":18,"valor":1658.94},{"parcelas":12,"valor":2473.95}]'::jsonb),
  ('PCX ABS', 'Com emplacamento', '[{"parcelas":80,"valor":410.87},{"parcelas":60,"valor":532.17},{"parcelas":48,"valor":655.49},{"parcelas":36,"valor":863.56},{"parcelas":24,"valor":1270.17}]'::jsonb),
  ('NXR160 BROS CBS', 'Com emplacamento', '[{"parcelas":80,"valor":447.9},{"parcelas":60,"valor":580.12},{"parcelas":48,"valor":714.55},{"parcelas":36,"valor":941.38},{"parcelas":24,"valor":1384.62}]'::jsonb),
  ('NXR160 BROS ABS', 'Com emplacamento', '[{"parcelas":80,"valor":469.53},{"parcelas":60,"valor":608.14},{"parcelas":48,"valor":749.07},{"parcelas":36,"valor":986.85},{"parcelas":24,"valor":1451.51}]'::jsonb),
  ('CRF 300F', 'Sem emplacamento', '[{"parcelas":80,"valor":439.74},{"parcelas":60,"valor":569.56},{"parcelas":48,"valor":701.54},{"parcelas":36,"valor":924.24},{"parcelas":24,"valor":1359.41}]'::jsonb),
  ('XRE 190', 'Com emplacamento', '[{"parcelas":80,"valor":469.31},{"parcelas":60,"valor":607.86},{"parcelas":48,"valor":748.72},{"parcelas":36,"valor":986.4},{"parcelas":24,"valor":1450.83}]'::jsonb),
  ('HONDA ADV', 'Com emplacamento', '[{"parcelas":80,"valor":504.99},{"parcelas":60,"valor":654.08},{"parcelas":48,"valor":805.64},{"parcelas":36,"valor":1061.39},{"parcelas":24,"valor":1561.13}]'::jsonb),
  ('CB300F TWISTER ABS', 'Com emplacamento', '[{"parcelas":80,"valor":512.68},{"parcelas":60,"valor":664.03},{"parcelas":48,"valor":817.9},{"parcelas":36,"valor":1077.53},{"parcelas":24,"valor":1584.88}]'::jsonb),
  ('XR 300L TORNADO', 'Com emplacamento', '[{"parcelas":80,"valor":602.02},{"parcelas":60,"valor":779.75},{"parcelas":48,"valor":960.44},{"parcelas":36,"valor":1265.32},{"parcelas":24,"valor":1861.08}]'::jsonb),
  ('SAHARA 300', 'Com emplacamento', '[{"parcelas":80,"valor":618.12},{"parcelas":60,"valor":800.59},{"parcelas":48,"valor":986.11},{"parcelas":36,"valor":1299.14},{"parcelas":24,"valor":1910.83}]'::jsonb),
  ('SAHARA 300 ADV', 'Com emplacamento', '[{"parcelas":80,"valor":638.8},{"parcelas":60,"valor":827.38},{"parcelas":48,"valor":1019.11},{"parcelas":36,"valor":1342.61},{"parcelas":24,"valor":1974.77}]'::jsonb),
  ('CB 500 HORNET', 'Sem emplacamento', '[{"parcelas":72,"valor":779.89}]'::jsonb),
  ('NX 500', 'Sem emplacamento', '[{"parcelas":72,"valor":829.67}]'::jsonb),
  ('CB1000 HORNET ABS', 'Sem emplacamento', '[{"parcelas":72,"valor":955.38}]'::jsonb),
  ('CB 750 HORNET', 'Sem emplacamento', '[{"parcelas":72,"valor":961.23}]'::jsonb),
  ('TRX 420FM', 'Sem emplacamento', '[{"parcelas":72,"valor":998.13}]'::jsonb),
  ('NC 750X ABS MT', 'Sem emplacamento', '[{"parcelas":72,"valor":1014.82}]'::jsonb),
  ('CB 650R E-CLUTCH', 'Sem emplacamento', '[{"parcelas":72,"valor":1065.03}]'::jsonb),
  ('CRF 1100L AFRICA TWIN MT', 'Sem emplacamento', '[{"parcelas":72,"valor":1067.64}]'::jsonb),
  ('XL 750 TRANSALP', 'Sem emplacamento', '[{"parcelas":72,"valor":1171.81}]'::jsonb),
  ('M&M ESSENCIAL', 'Sem emplacamento', '[{"parcelas":18,"valor":126.04}]'::jsonb),
  ('M&M ESSENCIAL+', 'Sem emplacamento', '[{"parcelas":18,"valor":163.51}]'::jsonb),
  ('M&M AVANÇADO', 'Sem emplacamento', '[{"parcelas":18,"valor":204.39}]'::jsonb),
  ('M&M AVANÇADO+', 'Sem emplacamento', '[{"parcelas":18,"valor":245.27}]'::jsonb);
  select valor into modelo from public.plataforma_config where chave = 'vendedor_modelo';
  select id into mid from public.vendedores where slug = coalesce(modelo, 'shayron');
  if mid is null then raise notice 'Vendedor modelo não encontrado: catálogo geral não foi semeado (use /modelo slug e rode de novo).'; return; end if;
  for r in select m.* from public.motos m where m.vendedor_id = mid order by m.ordem, m.created_at loop
    continue when exists (select 1 from public.catalogo_mestre c where public.norm_moto(c.nome) = public.norm_moto(r.nome));
    insert into public.catalogo_mestre(nome, modelo, categoria, selo, preco, descricao, fotos, video_url, planos, emplacamento, ordem, ativo)
    select r.nome, r.modelo, r.categoria, r.selo, r.preco, r.descricao, r.fotos, r.video_url,
           coalesce(s.planos, r.planos), coalesce(s.emp, r.emplacamento), r.ordem, r.ativo
      from (select 1) x left join _site s on s.nome_norm = public.norm_moto(r.nome)
    returning id into nid;
    k := k + 1;
    if public.norm_moto(r.nome) like 'CG 160 FAN%' then update public.catalogo_mestre set cores = '["Prata","Preto","Vermelho"]'::jsonb where id = nid; end if;
  end loop;
  raise notice 'Catálogo geral: % moto(s) criada(s) a partir de %', k, coalesce(modelo, 'shayron');
end $$;


select public.mestre_vincular() as vinculo;                       -- liga as motos de TODOS os vendedores ao catálogo geral
select public.mestre_sincronizar_todos() as sincronizacao;        -- cria o que faltar em cada vendedor

-- CORES por moto, sugeridas pelas FOTOS do site https://vendedor.site/shayrondahonda (cada foto = uma cor; o site não publica o nome).
--  Só preenche moto que ainda está SEM cores (nunca sobrescreve o que você editou no admin geral). Confira/edite lá.
update public.catalogo_mestre c set cores = v.cores, updated_at = now()
  from (values
  ('POP 110I ES +10%', '["Azul", "Vermelho", "Branco"]'::jsonb),
  ('BIZ 125 ES', '["Branco", "Preto"]'::jsonb),
  ('ELITE 125', '["Roxo", "Vermelho", "Preto", "Cinza"]'::jsonb),
  ('BIZ 125 EX', '["Azul", "Bege", "Cinza", "Vermelho"]'::jsonb),
  ('CG 160 START', '["Azul", "Preto", "Vermelho"]'::jsonb),
  ('PCX CBS', '["Branco"]'::jsonb),
  ('CG 160 FAN', '["Prata", "Preto", "Vermelho"]'::jsonb),
  ('CG 160 TITAN', '["Prata", "Preto", "Vermelho"]'::jsonb),
  ('PCX ABS', '["Azul"]'::jsonb),
  ('NXR160 BROS CBS', '["Preto", "Vermelho"]'::jsonb),
  ('NXR160 BROS ABS', '["Verde", "Vermelho"]'::jsonb),
  ('CRF 300F', '["Vermelho"]'::jsonb),
  ('XRE 190', '["Preto", "Vermelho"]'::jsonb),
  ('HONDA ADV', '["Cinza", "Vermelho"]'::jsonb),
  ('CB300F TWISTER ABS', '["Vermelho", "Preto"]'::jsonb),
  ('XR 300L TORNADO', '["Vermelho", "Preto"]'::jsonb),
  ('SAHARA 300', '["Cinza"]'::jsonb),
  ('SAHARA 300 ADV', '["Tricolor"]'::jsonb),
  ('CB 500 HORNET', '["Prata", "Preto", "Vermelho"]'::jsonb),
  ('NX 500', '["Prata", "Preto", "Vermelho"]'::jsonb),
  ('CB1000 HORNET ABS', '["Vermelho", "Branco"]'::jsonb),
  ('CB 750 HORNET', '["Branco", "Preto"]'::jsonb),
  ('TRX 420FM', '["Vermelho", "Cinza"]'::jsonb),
  ('NC 750X ABS MT', '["Preto", "Vermelho"]'::jsonb),
  ('CB 650R E-CLUTCH', '["Azul", "Vermelho", "Cinza"]'::jsonb),
  ('CRF 1100L AFRICA TWIN MT', '["Preto"]'::jsonb),
  ('XL 750 TRANSALP', '["Tricolor", "Preto"]'::jsonb)
  ) v(nome_norm, cores)
 where public.norm_moto(c.nome) = v.nome_norm and (c.cores is null or c.cores = '[]'::jsonb);
-- vendedores recebem as cores do catálogo (vendedor não edita cores)
update public.motos m set cores = c.cores from public.catalogo_mestre c where m.catalogo_id = c.id and m.cores is distinct from c.cores;

-- realinha: toda moto ligada ao catálogo passa a ter os planos/condição do catálogo (descarta valores digitados antes)
update public.motos t set planos = c.planos, emplacamento = c.emplacamento,
       custom = array(select x from unnest(t.custom) x where x not in ('planos', 'emplacamento'))
  from public.catalogo_mestre c where t.catalogo_id = c.id
   and (t.planos is distinct from c.planos or t.emplacamento is distinct from c.emplacamento or t.custom && array['planos','emplacamento']);

-- ---------- 13. limpeza do que ficou obsoleto ----------
drop function if exists public.carregar_planos_padrao(text, boolean);
drop function if exists public.carregar_planos_padrao_todos();
drop function if exists public.proteger_tabelas_consorcio();
drop function if exists public.aplicar_planos_padrao(text, boolean, boolean);
drop function if exists public.aplicar_planos_padrao_todos(boolean);
drop function if exists public.cols_copia(regclass, text[]);
drop table if exists public.planos_padrao;

-- ---------- 14. ADMINISTRADOR GERAL: cria/atualiza o login e define a senha; só ele (e mais ninguém) é o admin geral ----------
create or replace function public.definir_admin_geral(p_email text, p_senha text, p_exclusivo boolean default true) returns text
language plpgsql security definer set search_path = public, extensions, auth as $$
declare e text := lower(btrim(p_email)); u uuid; acao text;
begin
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido: %', e; end if;
  if length(coalesce(p_senha, '')) < 8 then raise exception 'A senha precisa ter pelo menos 8 caracteres.'; end if;
  select id into u from auth.users where lower(email) = e;
  if u is null then
    u := gen_random_uuid();
    insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change, email_change_token_new)
    values ('00000000-0000-0000-0000-000000000000', u, 'authenticated', 'authenticated', e, crypt(p_senha, gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
    insert into auth.identities(id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), u, u::text, 'email', jsonb_build_object('sub', u::text, 'email', e, 'email_verified', true), now(), now(), now());
    acao := 'login criado';
  else
    update auth.users set encrypted_password = crypt(p_senha, gen_salt('bf')), email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = u;
    acao := 'login já existia: senha redefinida';
  end if;
  insert into public.donos(user_id) values (u) on conflict do nothing;
  if p_exclusivo then delete from public.donos where user_id <> u; end if;
  return format('Admin geral: %s (%s).', e, acao);
end $$;
revoke all on function public.definir_admin_geral(text, text, boolean) from public, anon, authenticated;

select public.definir_admin_geral('filipecapelasso27@gmail.com', 'Capelasso2391') as admin_geral;

-- ---------- 15. CONFIGURAÇÕES GERAIS (vídeo "Como funciona o consórcio" e dados da loja) ----------
--  O admin geral define UMA vez e aparece em todos os sites dos vendedores.
insert into public.plataforma_config(chave, valor) values ('video_como_funciona', ''), ('video_titulo', 'Como funciona o consórcio Honda') on conflict (chave) do nothing;
insert into public.plataforma_config(chave, valor) values
  ('loja_nome', 'Star Motos · Grupo Star'),
  ('loja_endereco', 'Via Chico Mendes, 929 – Triângulo Velho (6 de Agosto), Rio Branco – AC'),
  ('loja_telefone', '(68) 3302-3080'), ('loja_horario', ''), ('loja_maps', '') on conflict (chave) do nothing;
create or replace function public.config_publica() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'video_como_funciona', nullif((select valor from public.plataforma_config where chave = 'video_como_funciona'), ''),
    'video_titulo', coalesce(nullif((select valor from public.plataforma_config where chave = 'video_titulo'), ''), 'Como funciona o consórcio Honda'),
    'loja_nome', nullif((select valor from public.plataforma_config where chave = 'loja_nome'), ''),
    'loja_endereco', nullif((select valor from public.plataforma_config where chave = 'loja_endereco'), ''),
    'loja_telefone', nullif((select valor from public.plataforma_config where chave = 'loja_telefone'), ''),
    'loja_horario', nullif((select valor from public.plataforma_config where chave = 'loja_horario'), ''),
    'loja_maps', nullif((select valor from public.plataforma_config where chave = 'loja_maps'), ''),
    'ficha_path', coalesce((select valor from public.plataforma_config where chave = 'ficha_path'), '0') = '1') $$;
create or replace function public.mestre_config_salvar(p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare u text; t text; k text;
begin
  perform public._exige_dono();
  if p ? 'video_como_funciona' then
    u := btrim(coalesce(p->>'video_como_funciona', ''));
    if u <> '' and u !~* '^https?://[^\s]+$' then raise exception 'O link do vídeo precisa começar com https://'; end if;
    if length(u) > 600 then raise exception 'Link do vídeo muito longo'; end if;
    insert into public.plataforma_config(chave, valor) values ('video_como_funciona', u) on conflict (chave) do update set valor = excluded.valor;
  end if;
  if p ? 'video_titulo' then
    t := left(btrim(coalesce(p->>'video_titulo', '')), 120);
    insert into public.plataforma_config(chave, valor) values ('video_titulo', t) on conflict (chave) do update set valor = excluded.valor;
  end if;
  foreach k in array array['loja_nome', 'loja_endereco', 'loja_telefone', 'loja_horario'] loop
    if p ? k then
      t := left(btrim(coalesce(p->>k, '')), 200);
      insert into public.plataforma_config(chave, valor) values (k, t) on conflict (chave) do update set valor = excluded.valor;
    end if;
  end loop;
  if p ? 'loja_maps' then
    u := btrim(coalesce(p->>'loja_maps', ''));
    if u <> '' and u !~* '^https?://[^\s]+$' then raise exception 'O link do mapa precisa começar com https://'; end if;
    insert into public.plataforma_config(chave, valor) values ('loja_maps', left(u, 600)) on conflict (chave) do update set valor = excluded.valor;
  end if;
  return 'Salvo. Vale para todos os sites dos vendedores.';
end $$;
revoke all on function public.config_publica(), public.mestre_config_salvar(jsonb) from public, anon, authenticated;
grant execute on function public.config_publica() to anon, authenticated;
grant execute on function public.mestre_config_salvar(jsonb) to authenticated;     -- confere se é o dono

select (select count(*) from public.catalogo_mestre) as motos_no_catalogo,
       (select count(*) from public.motos where catalogo_id is not null) as motos_de_vendedores_ligadas,
       (select count(*) from public.donos) as admin_geral_cadastrado;


-- #####################################################################################################
-- #####  3/4 · ATUALIZAÇÃO DIÁRIA DO SITE
-- #####################################################################################################

-- =====================================================================================================
--  SCRIPT 03 · ATUALIZAÇÃO DIÁRIA AUTOMÁTICA dos planos de consórcio a partir de https://vendedor.site/shayrondahonda
--  Rode DEPOIS do SQL_02_catalogo_geral. Seguro rodar mais de uma vez.
--
--  Todo dia, às 04:00 (Rio Branco) o próprio Supabase busca a página (pg_net) e às 04:10 aplica (pg_cron):
--  atualiza no catálogo geral os planos e a condição de emplacamento de cada moto com "atualizar do site" ligado,
--  e todos os vendedores recebem na hora. Motos novas do site NÃO são criadas sozinhas (só aparecem no histórico).
--  Segurança: se a leitura do site parecer quebrada (poucas motos / planos vazios / valor absurdo) NADA é alterado
--  e o motivo vai para o histórico (tabela site_sync_log, visível no admin geral).
--  ANTES: ative pg_cron e pg_net em Database > Extensions (o script tenta ativar sozinho).
-- =====================================================================================================

do $$ begin
  if to_regclass('public.catalogo_mestre') is null or to_regprocedure('public._mestre_aplicar(uuid,jsonb,boolean)') is null then
    raise exception 'Rode primeiro o SQL_02_catalogo_geral.';
  end if;
end $$;

-- ---------- 0. extensões de agendamento e de acesso à internet ----------
do $$ begin
  begin create extension if not exists pg_net with schema extensions; exception when others then raise notice 'pg_net: % (ative em Database > Extensions)', sqlerrm; end;
  begin create extension if not exists pg_cron; exception when others then raise notice 'pg_cron: % (ative em Database > Extensions)', sqlerrm; end;
end $$;

-- ---------- 1. colunas e histórico ----------
alter table public.catalogo_mestre add column if not exists sync_site boolean not null default true;   -- true = planos vêm do site todo dia
create table if not exists public.site_sync_log(
  id bigserial primary key, quando timestamptz not null default now(),
  status text not null,                       -- ok | abortado | erro | aguardando
  motos_lidas int not null default 0, motos_alteradas int not null default 0,
  detalhes jsonb not null default '{}'::jsonb);
alter table public.site_sync_log enable row level security;
drop policy if exists sl_dono_sel on public.site_sync_log;
create policy sl_dono_sel on public.site_sync_log for select to authenticated using (public.eh_dono());
revoke all on public.site_sync_log from public, anon; grant select on public.site_sync_log to authenticated;
insert into public.plataforma_config(chave, valor) values ('site_sync_url', 'https://vendedor.site/shayrondahonda') on conflict (chave) do nothing;





-- ---------- 3. leitura do site: HTML -> lista de motos com planos ----------
create or replace function public.site_sync_parse(p_html text) returns jsonb
language plpgsql immutable as $$
declare t text; L text[]; i int; j int; n int; nome text; emp text; pl jsonb; ln text; m text[]; seen text[] := '{}'; out jsonb := '[]'::jsonb;
begin
  t := regexp_replace(p_html, '<script.*?</script>', '', 'gi');     -- separado: com "|" o Postgres torna o .*? guloso
  t := regexp_replace(t, '<style.*?</style>', '', 'gi');
  t := regexp_replace(t, '<br\s*/?>', E'\n', 'gi');
  t := regexp_replace(t, '</(p|div|h[1-6]|li|tr|section|a|span|strong|b)>', E'\n', 'gi');
  t := regexp_replace(t, '<[^>]+>', '', 'g');
  t := replace(replace(replace(replace(replace(replace(t, '&nbsp;', ' '), '&quot;', '"'), '&#039;', chr(39)), '&lt;', '<'), '&gt;', '>'), '&amp;', '&');
  select coalesce(array_agg(x), '{}') into L from (
    select regexp_replace(x0, '^\s+|\s+$', '', 'g') x from unnest(string_to_array(t, E'\n')) x0) q where x <> '';
  n := coalesce(array_length(L, 1), 0);
  for i in 2..n loop
    if L[i] = 'Tabela de consórcio' then
      nome := regexp_replace(L[i-1], '\s+', ' ', 'g'); emp := null; pl := '[]'::jsonb;
      for j in i+1..least(i+40, n) loop
        ln := L[j];
        if ln in ('Com emplacamento', 'Sem emplacamento') then emp := ln; end if;
        m := regexp_match(ln, '^(\d+)x\s*R\$\s*([\d.]+,\d{2})$');
        if m is not null then pl := pl || jsonb_build_object('parcelas', m[1]::int, 'valor', replace(replace(m[2], '.', ''), ',', '.')::numeric); end if;
        exit when ln like '*Os valores%';
      end loop;
      if not (public.norm_moto(nome) = any (seen)) then
        seen := seen || public.norm_moto(nome);
        out := out || jsonb_build_array(jsonb_build_object('nome', nome, 'nome_norm', public.norm_moto(nome), 'emp', emp, 'planos', pl));
      end if;
    end if;
  end loop;
  return out;
end $$;

-- ---------- 4. aplica o resultado da leitura no catálogo ----------
create or replace function public.site_sync_aplicar(p_html text default null) returns text
language plpgsql security definer set search_path = public as $$
declare rid bigint; resp record; html text := p_html; lst jsonb; n int; vazias int := 0; e jsonb; c record; alter_ int := 0;
        mud jsonb := '[]'::jsonb; novas jsonb := '[]'::jsonb; ausentes jsonb := '[]'::jsonb; res text; v numeric; bad boolean := false;
begin
  if html is null then
    select nullif(valor, '')::bigint into rid from public.plataforma_config where chave = 'site_sync_req';
    if rid is null then insert into public.site_sync_log(status, detalhes) values ('erro', '{"motivo":"nenhuma busca iniciada"}'); return 'Nenhuma busca iniciada.'; end if;
    select * into resp from net._http_response where id = rid;
    if not found then return 'Ainda aguardando a resposta do site. Tente de novo em alguns segundos.'; end if;
    if coalesce(resp.status_code, 0) <> 200 or resp.content is null then
      insert into public.site_sync_log(status, detalhes) values ('erro', jsonb_build_object('motivo', 'o site respondeu com erro', 'http', resp.status_code, 'erro', resp.error_msg, 'timeout', resp.timed_out));
      return format('Falha ao ler o site (HTTP %s %s). Nada foi alterado.', coalesce(resp.status_code::text, '-'), coalesce(resp.error_msg, ''));
    end if;
    html := resp.content;
  end if;
  lst := public.site_sync_parse(html); n := jsonb_array_length(lst);
  for e in select * from jsonb_array_elements(lst) loop
    if jsonb_array_length(e->'planos') = 0 then vazias := vazias + 1; end if;
    for v in select (x->>'valor')::numeric from jsonb_array_elements(e->'planos') x loop if v < 10 or v > 100000 then bad := true; end if; end loop;
  end loop;
  if n < 20 or vazias > n / 3 or bad then
    insert into public.site_sync_log(status, motos_lidas, detalhes) values ('abortado', n, jsonb_build_object('motivo', 'leitura do site suspeita (layout mudou?)', 'motos', n, 'sem_plano', vazias, 'valor_fora_do_normal', bad));
    return format('Atualização ABORTADA por segurança: li %s motos (%s sem plano). Nada foi alterado.', n, vazias);
  end if;
  for e in select * from jsonb_array_elements(lst) loop
    select * into c from public.catalogo_mestre where public.norm_moto(nome) = e->>'nome_norm';
    if not found then novas := novas || jsonb_build_array(e->>'nome'); continue; end if;
    continue when not c.sync_site or jsonb_array_length(e->'planos') = 0;
    if c.planos is distinct from (e->'planos') or coalesce(c.emplacamento, '') is distinct from coalesce(e->>'emp', c.emplacamento, '') then
      res := public._mestre_aplicar(c.id, jsonb_build_object('planos', e->'planos', 'emplacamento', coalesce(e->>'emp', c.emplacamento)), false);
      alter_ := alter_ + 1;
      mud := mud || jsonb_build_array(jsonb_build_object('moto', c.nome, 'de', c.planos, 'para', e->'planos', 'resultado', res));
    end if;
  end loop;
  select coalesce(jsonb_agg(c2.nome), '[]'::jsonb) into ausentes from public.catalogo_mestre c2
   where c2.sync_site and not exists (select 1 from jsonb_array_elements(lst) x where x->>'nome_norm' = public.norm_moto(c2.nome));
  insert into public.site_sync_log(status, motos_lidas, motos_alteradas, detalhes)
  values ('ok', n, alter_, jsonb_build_object('alteradas', mud, 'novas_no_site', novas, 'fora_do_site', ausentes));
  return format('Site lido: %s motos. Planos atualizados em %s moto(s)%s%s.', n, alter_,
         case when jsonb_array_length(novas) > 0 then format('; %s moto(s) nova(s) no site (não criadas): %s', jsonb_array_length(novas), novas::text) else '' end,
         case when jsonb_array_length(ausentes) > 0 then format('; %s do catálogo não estão mais no site', jsonb_array_length(ausentes)) else '' end);
end $$;

-- ---------- 5. busca o site (assíncrona) ----------
create or replace function public.site_sync_iniciar() returns bigint
language plpgsql security definer set search_path = public as $$
declare u text; rid bigint;
begin
  select valor into u from public.plataforma_config where chave = 'site_sync_url';
  select net.http_get(url := u, headers := jsonb_build_object('User-Agent', 'Mozilla/5.0 (compatible; CatalogoSync/1.0)'), timeout_milliseconds := 30000) into rid;
  insert into public.plataforma_config(chave, valor) values ('site_sync_req', rid::text) on conflict (chave) do update set valor = excluded.valor;
  return rid;
end $$;

-- botões do admin geral (só o dono)
create or replace function public.site_sync_manual_iniciar() returns bigint language plpgsql security definer set search_path = public as $$
begin perform public._exige_dono(); return public.site_sync_iniciar(); end $$;
create or replace function public.site_sync_manual_aplicar() returns text language plpgsql security definer set search_path = public as $$
begin perform public._exige_dono(); return public.site_sync_aplicar(); end $$;
create or replace function public.site_sync_historico() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.quando desc) from (select * from public.site_sync_log where status <> 'aguardando' order by quando desc limit 15) l), '[]'::jsonb);
end $$;

revoke all on function public.site_sync_parse(text), public.site_sync_aplicar(text), public.site_sync_iniciar(),
  public.site_sync_manual_iniciar(), public.site_sync_manual_aplicar(), public.site_sync_historico() from public, anon, authenticated;
grant execute on function public.site_sync_manual_iniciar(), public.site_sync_manual_aplicar(), public.site_sync_historico() to authenticated;   -- cada uma confere se é o dono

-- ---------- 6. AGENDAMENTO DIÁRIO: 09:00 UTC = 04:00 em Rio Branco (busca) e 09:10 UTC (aplica) ----------
do $$ begin
  perform cron.schedule('site_sync_iniciar', '0 9 * * *', 'select public.site_sync_iniciar()');
  perform cron.schedule('site_sync_aplicar', '10 9 * * *', 'select public.site_sync_aplicar()');
  raise notice 'Agendamento diário criado (04:00 Rio Branco).';
exception when others then raise notice 'Não consegui agendar: % — ative pg_cron e pg_net em Database > Extensions e rode este arquivo de novo.', sqlerrm;
end $$;

-- ---------- 7. primeira busca agora (o resultado aparece no admin geral em alguns segundos) ----------
do $$ begin perform public.site_sync_iniciar(); exception when others then raise notice 'Busca inicial não feita: %', sqlerrm; end $$;

-- Passo seguinte (espere ~10 segundos e rode):  select public.site_sync_aplicar();   -- lê o que o site respondeu e atualiza
-- Histórico:  select quando, status, motos_lidas, motos_alteradas from public.site_sync_log order by id desc limit 5;


-- #####################################################################################################
-- #####  4/4 · ADMIN GERAL: VENDEDORES, SENHAS, EXCLUIR, TESTE DE ENTREGA, PEDIDOS E RANKING
-- #####################################################################################################

-- =====================================================================================================
--  SCRIPT 04 · ADMIN GERAL: VENDEDORES (perfil, criar, senha, suspender), PEDIDOS DE TODOS OS CLIENTES e RANKING
--  Rode DEPOIS do SQL_02_catalogo_geral. Seguro rodar mais de uma vez. Não mexe em user_id nem apaga dados.
--  Todas as funções conferem se quem chama é o administrador geral (tabela donos).
-- =====================================================================================================

do $$ begin
  if to_regprocedure('public._exige_dono()') is null then raise exception 'Rode primeiro o SQL_02_catalogo_geral.'; end if;
  if to_regprocedure('public.novo_vendedor(text,text,text,text,text,boolean,text,text,boolean)') is null then raise exception 'Rode primeiro o SQL_01_base.'; end if;
end $$;

create or replace function public._senha_aleatoria() returns text language plpgsql volatile as $$
declare h text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''); a text := 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'; r text := ''; i int;
begin
  for i in 0..9 loop r := r || substr(a, 1 + (('x' || substr(h, 2 * i + 1, 2))::bit(8)::int % length(a)), 1); end loop;
  return r;
end $$;
create or replace function public.mestre_vendedores() returns jsonb language plpgsql security definer set search_path = public, auth as $$
begin
  perform public._exige_dono();
  return coalesce((select jsonb_agg(x order by x->>'criado') from (
    select jsonb_build_object('id', v.id, 'slug', v.slug, 'nome', v.nome, 'email', u.email, 'whatsapp', v.whatsapp, 'suspenso', v.suspenso, 'criado', v.created_at,
      'motos', (select count(*) from public.motos m where m.vendedor_id = v.id),
      'chat', (select count(*) from public.pedidos_chat p where p.vendedor_id = v.id and p.completo),
      'fichas', (select count(*) from public.fichas f where f.vendedor_id = v.id),
      'contratos', (select count(*) from public.contratos c where c.vendedor_id = v.id),
      'contatos', (select count(*) from public.leads l where l.vendedor_id = v.id and coalesce(l.tipo, '') not in ('ficha', 'contrato')) + (select count(*) from public.rascunhos r where r.vendedor_id = v.id and not r.completo),
      'links', coalesce((select jsonb_agg(jsonb_build_object('etiqueta', k.etiqueta, 'endereco', k.endereco)) from public.links_vendedor(v.slug) k), '[]'::jsonb)) x
    from public.vendedores v left join auth.users u on u.id = v.user_id) q), '[]'::jsonb);
end $$;
create or replace function public.mestre_criar_vendedor(p_nome text, p_email text, p_whatsapp text default null, p_slug text default null, p_senha text default null) returns jsonb
language plpgsql security definer set search_path = public, auth, extensions as $$
declare s text := lower(btrim(coalesce(p_slug, ''))); sen text := nullif(btrim(coalesce(p_senha, '')), ''); base text; k int := 1; links jsonb;
begin
  perform public._exige_dono();
  if btrim(coalesce(p_nome, '')) = '' then raise exception 'Informe o nome do vendedor.'; end if;
  if s = '' then
    base := regexp_replace(translate(lower(btrim(p_nome)), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc'), '[^a-z0-9]+', '-', 'g');
    base := btrim(base, '-'); if length(base) < 3 or base ~ '^(api|admin|admingeral|index|ficha|contrato|cdc|cnh|vitrine|termos|og|vercel|static|assets|public|favicon|robots|sitemap|login|painel|www|app)$' then base := base || '-vendedor'; end if; base := left(base, 34); s := base;
    while exists (select 1 from public.vendedores where slug = s) loop k := k + 1; s := base || '-' || k; end loop;
  end if;
  if sen is null then sen := public._senha_aleatoria(); end if;
  select coalesce(jsonb_agg(jsonb_build_object('etiqueta', r.etiqueta, 'endereco', r.endereco)), '[]'::jsonb) into links
    from public.novo_vendedor(p_nome, p_email, sen, s, p_whatsapp, false, null::text, null::text, false) r
   where r.etiqueta not in ('Status', 'Login (e-mail)', 'Telegram', 'Catálogo');
  return jsonb_build_object('slug', s, 'nome', btrim(p_nome), 'email', lower(btrim(p_email)), 'senha', sen, 'links', links);
end $$;
create or replace function public.mestre_redefinir_senha(p_id uuid) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare em text; sen text := public._senha_aleatoria();
begin
  perform public._exige_dono();
  select u.email into em from public.vendedores v join auth.users u on u.id = v.user_id where v.id = p_id;
  if em is null then raise exception 'Vendedor não encontrado.'; end if;
  perform public.trocar_senha(em, sen);
  return jsonb_build_object('email', em, 'senha', sen);
end $$;
-- ---------- SENHA DO VENDEDOR: ver (do cofre) e trocar (escrevendo a nova) ----------
create or replace function public.mestre_vendedor_senha(p_id uuid) returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare r record; sen text;
begin
  perform public._exige_dono();
  select s.senha_enc as enc, s.atualizado_em as quando, u.encrypted_password as h into r
    from public.vendedores v join auth.users u on u.id = v.user_id left join public.vendedor_senhas s on s.vendedor_id = v.id where v.id = p_id;
  if not found then raise exception 'Vendedor não encontrado.'; end if;
  if r.enc is null then return jsonb_build_object('tem', false); end if;
  sen := pgp_sym_decrypt(r.enc, public._cofre_chave());
  return jsonb_build_object('tem', true, 'senha', sen, 'atualizado_em', r.quando, 'confere', crypt(sen, r.h) = r.h);
end $$;
create or replace function public.mestre_definir_senha(p_id uuid, p_senha text) returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare em text;
begin
  perform public._exige_dono();
  if length(coalesce(p_senha, '')) < 8 then raise exception 'A senha precisa ter pelo menos 8 caracteres.'; end if;
  select u.email into em from public.vendedores v join auth.users u on u.id = v.user_id where v.id = p_id;
  if em is null then raise exception 'Vendedor não encontrado.'; end if;
  perform public.trocar_senha(em, p_senha);
  return jsonb_build_object('email', em, 'senha', p_senha);
end $$;
revoke all on function public.mestre_vendedor_senha(uuid), public.mestre_definir_senha(uuid, text) from public, anon, authenticated;
grant execute on function public.mestre_vendedor_senha(uuid), public.mestre_definir_senha(uuid, text) to authenticated;     -- confere se é o dono

-- ---------- EXCLUIR VENDEDOR (só o admin geral; apaga o vendedor, as motos, os clientes e o login) ----------
create or replace function public.mestre_excluir_vendedor(p_id uuid, p_confirma text) returns text language plpgsql security definer set search_path = public, auth as $$
declare v record; uid uuid;
begin
  perform public._exige_dono();
  select id, slug, nome, user_id into v from public.vendedores where id = p_id;
  if not found then raise exception 'Vendedor não encontrado.'; end if;
  if lower(btrim(coalesce(p_confirma, ''))) <> v.slug then raise exception 'Confirmação incorreta: digite o endereço "%" para excluir.', v.slug; end if;
  if exists (select 1 from public.donos where user_id = v.user_id) then raise exception 'Este login é de um administrador geral e não pode ser excluído por aqui.'; end if;
  uid := v.user_id;
  delete from public.pedidos_chat where vendedor_id = v.id;
  delete from public.fichas where vendedor_id = v.id;
  delete from public.contratos where vendedor_id = v.id;
  delete from public.leads where vendedor_id = v.id;
  delete from public.motos where vendedor_id = v.id;
  if to_regclass('public.rascunhos') is not null then execute 'delete from public.rascunhos where vendedor_id = $1' using v.id; end if;
  if to_regclass('public.vendedor_senhas') is not null then execute 'delete from public.vendedor_senhas where vendedor_id = $1' using v.id; end if;
  if to_regclass('public.vendedor_segredos') is not null then execute 'delete from public.vendedor_segredos where vendedor_id = $1' using v.id; end if;
  delete from public.vendedores where id = v.id;
  -- o login só é apagado se não pertencer a mais ninguém
  if not exists (select 1 from public.vendedores where user_id = uid) and not exists (select 1 from public.donos where user_id = uid) then
    delete from auth.identities where user_id = uid;
    delete from auth.users where id = uid;
  end if;
  return format('Vendedor "%s" excluído, com as motos, os dados dos clientes e o login.', v.nome);
end $$;
revoke all on function public.mestre_excluir_vendedor(uuid, text) from public, anon, authenticated;
grant execute on function public.mestre_excluir_vendedor(uuid, text) to authenticated;     -- confere se é o dono

-- ---------- TESTE DE ENTREGA pelo admin geral: conta o que realmente chegou em cada vendedor e limpa os registros de teste ----------
create or replace function public.mestre_testes_entrega_contagem() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  return coalesce((select jsonb_agg(jsonb_build_object('vendedor_id', v.id, 'slug', v.slug,
    'chat', (select count(*) from public.pedidos_chat p where p.vendedor_id = v.id and public._eh_teste(coalesce(p.nome_completo, p.nome))),
    'lead', (select count(*) from public.leads l where l.vendedor_id = v.id and public._eh_teste(l.nome)),
    'rasc_fin', (select count(*) from public.rascunhos r where r.vendedor_id = v.id and r.origem = 'financiamento' and public._eh_teste(r.nome)),
    'rasc_chat', (select count(*) from public.rascunhos r where r.vendedor_id = v.id and r.origem = 'chat' and public._eh_teste(r.nome)))) from public.vendedores v), '[]'::jsonb);
end $$;
create or replace function public.mestre_limpar_testes_entrega() returns text language plpgsql security definer set search_path = public as $$
declare n int := 0; k int;
begin
  perform public._exige_dono();
  delete from public.pedidos_chat where public._eh_teste(coalesce(nome_completo, nome)); get diagnostics k = row_count; n := n + k;
  delete from public.leads where public._eh_teste(nome); get diagnostics k = row_count; n := n + k;
  delete from public.fichas where public._eh_teste(nome); get diagnostics k = row_count; n := n + k;
  delete from public.contratos where public._eh_teste(nome); get diagnostics k = row_count; n := n + k;
  delete from public.rascunhos where public._eh_teste(nome); get diagnostics k = row_count; n := n + k;
  return n || ' registro(s) de teste apagado(s).';
end $$;
revoke all on function public.mestre_testes_entrega_contagem(), public.mestre_limpar_testes_entrega() from public, anon, authenticated;
grant execute on function public.mestre_testes_entrega_contagem(), public.mestre_limpar_testes_entrega() to authenticated;     -- confere se é o dono

create or replace function public.mestre_suspender_vendedor(p_id uuid, p_suspender boolean) returns text language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  update public.vendedores set suspenso = p_suspender where id = p_id;
  if not found then raise exception 'Vendedor não encontrado.'; end if;
  return case when p_suspender then 'Site e painel suspensos: o site sai do ar e o vendedor não acessa os dados.' else 'Site e painel reativados.' end;
end $$;
create or replace function public.mestre_pedidos(p_vendedor uuid default null, p_tipo text default null, p_limit int default 300) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  return coalesce((select jsonb_agg(to_jsonb(q) order by q.criado desc) from (
    select u.tipo, u.id, u.criado, v.slug as vendedor_slug, v.nome as vendedor_nome, v.id as vendedor_id, u.nome, u.telefone, u.moto, u.cor, u.pagamento, u.status, u.dados
      from (
        select 'chat' tipo, p.id::text id, p.vendedor_id, p.created_at criado, coalesce(p.nome_completo, p.nome) nome, p.telefone, p.moto_nome moto, to_jsonb(p)->>'cor' cor, p.pagamento, p.status, to_jsonb(p) - 'vendedor_id' dados from public.pedidos_chat p where p.completo
        union all select 'ficha', f.id::text, f.vendedor_id, f.created_at, f.nome, f.telefone, f.moto_nome, to_jsonb(f)->>'cor', 'financiamento', f.status, to_jsonb(f) - 'vendedor_id' from public.fichas f
        union all select 'contrato', c.id::text, c.vendedor_id, c.created_at, c.nome, c.telefone, c.moto_nome, to_jsonb(c)->>'cor', 'consorcio', c.status, to_jsonb(c) - 'vendedor_id' from public.contratos c
        union all select 'contato', l.id::text, l.vendedor_id, l.created_at, l.nome, l.telefone, l.moto_nome, to_jsonb(l)->>'cor', l.tipo, null, to_jsonb(l) - 'vendedor_id' from public.leads l where coalesce(l.tipo, '') not in ('ficha', 'contrato')
        union all select 'rascunho', r.id::text, r.vendedor_id, r.updated_at, r.nome, r.telefone, r.moto_nome, r.cor, r.origem, null, (to_jsonb(r) - 'vendedor_id' - 'dados' - 'avisado') || r.dados from public.rascunhos r where not r.completo
      ) u join public.vendedores v on v.id = u.vendedor_id
     where (p_vendedor is null or u.vendedor_id = p_vendedor) and (p_tipo is null or u.tipo = p_tipo)
     order by u.criado desc limit least(greatest(coalesce(p_limit, 300), 1), 1000)) q), '[]'::jsonb);
end $$;
create or replace function public.mestre_ranking(p_dias int default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare desde timestamptz := case when p_dias is null then '-infinity' else now() - make_interval(days => p_dias) end;
begin
  perform public._exige_dono();
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.total desc, r.nome) from (
    select v.id, v.slug, v.nome, v.suspenso,
      (select count(*) from public.pedidos_chat p where p.vendedor_id = v.id and p.completo and p.created_at >= desde)::int chat,
      (select count(*) from public.fichas f where f.vendedor_id = v.id and f.created_at >= desde)::int fichas,
      (select count(*) from public.contratos c where c.vendedor_id = v.id and c.created_at >= desde)::int contratos,
      ((select count(*) from public.leads l where l.vendedor_id = v.id and coalesce(l.tipo, '') not in ('ficha', 'contrato') and l.created_at >= desde) + (select count(*) from public.rascunhos r where r.vendedor_id = v.id and not r.completo and r.updated_at >= desde))::int contatos,
      ((select count(*) from public.pedidos_chat p where p.vendedor_id = v.id and p.completo and p.created_at >= desde)
     + (select count(*) from public.fichas f where f.vendedor_id = v.id and f.created_at >= desde)
     + (select count(*) from public.contratos c where c.vendedor_id = v.id and c.created_at >= desde)
     + ((select count(*) from public.leads l where l.vendedor_id = v.id and coalesce(l.tipo, '') not in ('ficha', 'contrato') and l.created_at >= desde) + (select count(*) from public.rascunhos r where r.vendedor_id = v.id and not r.completo and r.updated_at >= desde)))::int total
    from public.vendedores v) r), '[]'::jsonb);
end $$;

revoke all on function public._senha_aleatoria(), public.mestre_vendedores(), public.mestre_criar_vendedor(text, text, text, text, text), public.mestre_redefinir_senha(uuid),
  public.mestre_suspender_vendedor(uuid, boolean), public.mestre_pedidos(uuid, text, int), public.mestre_ranking(int) from public, anon, authenticated;
grant execute on function public.mestre_vendedores(), public.mestre_criar_vendedor(text, text, text, text, text), public.mestre_redefinir_senha(uuid),
  public.mestre_suspender_vendedor(uuid, boolean), public.mestre_pedidos(uuid, text, int), public.mestre_ranking(int) to authenticated;   -- cada uma confere se é o dono



-- #####################################################################################################
-- #####  CHECKLIST FINAL (somente leitura)
-- #####################################################################################################

-- =====================================================================================================
--  SCRIPT 00 · VERIFICAR (somente leitura): mostra o que já existe no seu banco e o que falta rodar.
--  Rode quando quiser, em qualquer momento. Não altera nada.
-- =====================================================================================================
select ordem, item, case when ok then 'OK' else 'FALTA' end as situacao, onde_resolver from (
  select 1 ordem, 'Base multi-vendedor (tabelas e RLS)' item, to_regclass('public.vendedores') is not null and to_regclass('public.pedidos_chat') is not null ok, 'SQL_01_base' onde_resolver
  union all select 2, 'Coluna "cor" nos formulários', exists(select 1 from information_schema.columns where table_schema='public' and table_name='fichas' and column_name='cor'), 'SQL_01_base'
  union all select 12, 'Preenchimento em andamento (rascunhos)', to_regclass('public.rascunhos') is not null and to_regprocedure('public.registrar_rascunho(jsonb)') is not null, 'SQL_01_base'
  union all select 13, 'Coluna "cor" em leads (envio do financiamento)', exists(select 1 from information_schema.columns where table_schema='public' and table_name='leads' and column_name='cor'), 'SQL_01_base'
  union all select 3, 'Bot do Telegram (telegram_webhook)', to_regprocedure('public.telegram_webhook(jsonb)') is not null, 'SQL_01_base'
  union all select 4, 'Catálogo geral (catalogo_mestre)', to_regclass('public.catalogo_mestre') is not null, 'SQL_02_catalogo_geral'
  union all select 5, 'Trava de consórcio (trigger c_mestre)', exists(select 1 from pg_trigger where tgname='c_mestre' and not tgisinternal), 'SQL_02_catalogo_geral'
  union all select 6, 'Admin geral = filipecapelasso27@gmail.com', exists(select 1 from public.donos d join auth.users u on u.id = d.user_id where lower(u.email) = 'filipecapelasso27@gmail.com'), 'SQL_02_catalogo_geral (passo 14)'
  union all select 7, 'Atualização do site (site_sync_aplicar)', to_regprocedure('public.site_sync_aplicar(text)') is not null, 'SQL_03_atualizacao_site'
  union all select 8, 'pg_net ativo', exists(select 1 from pg_extension where extname='pg_net'), 'Database > Extensions > pg_net'
  union all select 9, 'pg_cron ativo', exists(select 1 from pg_extension where extname='pg_cron'), 'Database > Extensions > pg_cron'
  union all select 10, 'Agendamento diário criado', case when to_regclass('cron.job') is not null then (xpath('/row/c/text()', query_to_xml('select count(*) c from cron.job where jobname like ''site_sync%''', false, true, '')))[1]::text::int = 2 else false end, 'SQL_03_atualizacao_site'
  union all select 14, 'Personalização do site (coluna config: vídeos, fotos de entrega, textos)', exists(select 1 from information_schema.columns where table_schema='public' and table_name='vendedores' and column_name='config') and exists(select 1 from information_schema.columns where table_schema='public' and table_name='vendedor_publico' and column_name='config'), 'SQL_01_base'
  union all select 11, 'Funções do admin geral (vendedores/pedidos/ranking)', to_regprocedure('public.mestre_ranking(integer)') is not null, 'SQL_04_admin_geral'
) t order by ordem;
