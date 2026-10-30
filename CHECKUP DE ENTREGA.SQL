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
        'moto_nome', 'TESTE', 'pagamento', 'consorcio', 'parcela', '60x de R$ 1,00', 'mensagem', 'teste de entrega'));
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

select * from public.checkup_entrega('capelasso');   -- <<< troque pelo slug do vendedor
