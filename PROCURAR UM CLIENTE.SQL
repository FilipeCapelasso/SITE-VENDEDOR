-- =====================================================================================================
--  PROCURAR UM CLIENTE no banco (somente leitura) — use para achar a venda que "sumiu"
--  1) troque o texto entre aspas: parte do NOME ou do TELEFONE do cliente (ex.: 'maria', '99999', '68999')
--  2) rode. Mostra onde o cliente aparece (qualquer vendedor), de qual vendedor, quando e o que foi preenchido.
--  Se NADA aparecer, o formulário não chegou a ser gravado: o único registro é a mensagem de WhatsApp que o cliente enviou.
-- =====================================================================================================
with b as (select lower('COLOQUE_AQUI_NOME_OU_TELEFONE') as q, regexp_replace('COLOQUE_AQUI_NOME_OU_TELEFONE', '\D', '', 'g') as d)
select * from (
  select 'chat' origem, p.created_at quando, v.slug vendedor, coalesce(p.nome_completo, p.nome) nome, p.telefone, p.moto_nome moto, p.pagamento detalhe, case when p.completo then 'concluído' else 'incompleto' end situacao from public.pedidos_chat p join public.vendedores v on v.id = p.vendedor_id, b
    where lower(coalesce(p.nome_completo, p.nome, '')) like '%' || b.q || '%' or (b.d <> '' and regexp_replace(coalesce(p.telefone, ''), '\D', '', 'g') like '%' || b.d || '%')
  union all
  select 'ficha CDC', f.created_at, v.slug, f.nome, f.telefone, f.moto_nome, f.status, 'enviada' from public.fichas f join public.vendedores v on v.id = f.vendedor_id, b
    where lower(coalesce(f.nome, '')) like '%' || b.q || '%' or (b.d <> '' and regexp_replace(coalesce(f.telefone, ''), '\D', '', 'g') like '%' || b.d || '%')
  union all
  select 'pré-contrato CNH', c.created_at, v.slug, c.nome, c.telefone, c.moto_nome, c.status, 'enviado' from public.contratos c join public.vendedores v on v.id = c.vendedor_id, b
    where lower(coalesce(c.nome, '')) like '%' || b.q || '%' or (b.d <> '' and regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g') like '%' || b.d || '%')
  union all
  select 'contato/lead (' || coalesce(l.tipo, '-') || ')', l.created_at, v.slug, l.nome, l.telefone, l.moto_nome, l.detalhes, 'registrado' from public.leads l join public.vendedores v on v.id = l.vendedor_id, b
    where lower(coalesce(l.nome, '')) like '%' || b.q || '%' or (b.d <> '' and regexp_replace(coalesce(l.telefone, ''), '\D', '', 'g') like '%' || b.d || '%')
  union all
  select 'preenchimento em andamento (' || r.origem || ')', r.updated_at, v.slug, r.nome, r.telefone, r.moto_nome, left(r.dados::text, 200), case when r.completo then 'enviou depois' else 'NÃO enviou' end from public.rascunhos r join public.vendedores v on v.id = r.vendedor_id, b
    where lower(coalesce(r.nome, '')) like '%' || b.q || '%' or (b.d <> '' and regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g') like '%' || b.d || '%')
) x order by quando desc limit 50;

-- Para ver a atividade recente de TODOS os vendedores (quem recebeu o quê nos últimos 14 dias), troque o texto acima por '' e rode:
-- select v.slug, (select count(*) from public.leads l where l.vendedor_id=v.id and l.created_at > now()-interval '14 days') leads,
--        (select count(*) from public.fichas f where f.vendedor_id=v.id and f.created_at > now()-interval '14 days') fichas,
--        (select count(*) from public.contratos c where c.vendedor_id=v.id and c.created_at > now()-interval '14 days') contratos,
--        (select count(*) from public.pedidos_chat p where p.vendedor_id=v.id and p.created_at > now()-interval '14 days') chat
--   from public.vendedores v order by 1;
