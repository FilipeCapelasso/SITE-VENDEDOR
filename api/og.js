/* api/og.js — PRÉVIA DO LINK por vendedor (WhatsApp, Instagram, Facebook, Telegram, Google...)
 *
 * O WhatsApp e o Instagram NÃO executam JavaScript: eles leem só o HTML que recebem. Por isso o vercel.json manda
 * SÓ esses "robôs de prévia" para cá; quem é gente (navegador) continua recebendo o index.html normal, sem atraso.
 *
 * Esta função lê os dados PÚBLICOS do vendedor (a mesma view vendedor_publico que o site já usa, com a chave
 * pública do Supabase, que foi feita para ficar no navegador) e devolve um HTML pequeno com as tags de prévia.
 * Para trocar o projeto/chave sem editar o código, use as variáveis de ambiente SUPABASE_URL e SUPABASE_ANON_KEY.
 */
const SB_URL = process.env.SUPABASE_URL || 'https://qrmwgqkiwoenlkfzjazs.supabase.co';
const SB_KEY = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFybXdncWtpd29lbmxrZnpqYXpzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA4MDc3OTIsImV4cCI6MjEwNjM4Mzc5Mn0.lhgkQS_WcB55uG0SKk0ngQgpc9oruFRt2H2D8orjNnc';

const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const clip = (s, n) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s; };
const httpsUrl = u => (/^https:\/\/[^\s"'<>\\]+$/i.test(String(u || '')) ? String(u) : '');

module.exports = async function handler(req, res) {
  const q = req.query || {};
  const slugRaw = String(q.slug || '').toLowerCase().trim();
  const slug = /^[a-z0-9-]{2,40}$/.test(slugRaw) ? slugRaw : '';
  const hostRaw = String((req.headers && (req.headers['x-forwarded-host'] || req.headers.host)) || '').split(',')[0].trim().toLowerCase();
  const base = /^[a-z0-9.-]+(:\d+)?$/.test(hostRaw) ? 'https://' + hostRaw : '';

  let v = null;
  if (slug) {
    try {
      const r = await fetch(SB_URL + '/rest/v1/vendedor_publico?select=nome,bio,foto_url,suspenso,config', {
        headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'x-vendedor': slug, Accept: 'application/json' },
        signal: AbortSignal.timeout(2800)
      });
      if (r.ok) { const j = await r.json(); v = Array.isArray(j) && j[0] ? j[0] : null; }
    } catch (e) { v = null; }
  }
  if (v && v.suspenso) v = null;

  const cfg = v && v.config && typeof v.config === 'object' ? v.config : {};
  const og = cfg.og && typeof cfg.og === 'object' ? cfg.og : {};
  const nome = v ? clip(v.nome, 60) : 'Star Motos';
  const title = clip(og.t || (v ? nome + ' | Consórcio e financiamento Honda' : 'Consórcio e financiamento de motos Honda'), 70);
  const desc = clip(og.d || (v && v.bio) || 'Simule consórcio e financiamento de motos Honda direto comigo. Atendimento rápido pelo WhatsApp.', 160);
  const card = httpsUrl(og.img);
  const img = card || (v ? httpsUrl(v.foto_url) : '');
  const url = base ? base + (slug ? '/' + slug : '') : '';
  const dest = '/' + slug + '?np=1';

  const m = [];
  m.push(['property', 'og:type', 'website'], ['property', 'og:site_name', nome], ['property', 'og:locale', 'pt_BR']);
  if (url) m.push(['property', 'og:url', url]);
  m.push(['property', 'og:title', title], ['property', 'og:description', desc]);
  if (img) {
    m.push(['property', 'og:image', img], ['property', 'og:image:alt', title]);
    if (card) m.push(['property', 'og:image:width', '1200'], ['property', 'og:image:height', '630']);
  }
  m.push(['name', 'twitter:card', card ? 'summary_large_image' : 'summary'], ['name', 'twitter:title', title], ['name', 'twitter:description', desc]);
  if (img) m.push(['name', 'twitter:image', img]);
  m.push(['name', 'description', desc]);

  const html = '<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>' + esc(title) + '</title>' +
    (url ? '<link rel="canonical" href="' + esc(url) + '">' : '') +
    m.map(a => '<meta ' + a[0] + '="' + a[1] + '" content="' + esc(a[2]) + '">').join('') +
    '<meta http-equiv="refresh" content="0;url=' + esc(dest) + '"></head>' +
    '<body style="font-family:system-ui,sans-serif;background:#111;color:#fff;padding:28px"><h1>' + esc(title) + '</h1><p>' + esc(desc) + '</p>' +
    '<p><a style="color:#ff8a8a" href="' + esc(dest) + '">Abrir o site</a></p><script>location.replace(' + JSON.stringify(dest) + ')</script></body></html>';

  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', v ? 'public, max-age=0, s-maxage=600, stale-while-revalidate=86400' : 'public, max-age=0, s-maxage=60');
  res.setHeader('Vary', 'User-Agent');
  res.end(html);
};
