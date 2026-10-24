// Novora AI assistant: takes the constructor prompt (project JSON + master's request) and returns the model's JSON answer.
// Only for signed-in masters with an active licence. Runs on Vercel AI Gateway (same credits as AI photos).
const SB_URL = 'https://hzsoschqllsnbwsbufqd.supabase.co', SB_KEY = 'sb_publishable_efvDDxySi05vrJ6Zp6304A_-cjDdVUG';
const ORIGIN_OK = /^https:\/\/(novora\.phillych\.ge|novora-konstruktori[\w-]*\.vercel\.app)(\/|$)/;
const MODELS = ['anthropic/claude-haiku-4.5', 'google/gemini-2.5-flash', 'openai/gpt-4.1-mini'];

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'method not allowed' }); return; }
  const from = req.headers.origin || req.headers.referer || '';
  if (!ORIGIN_OK.test(from)) { res.status(403).json({ error: 'origin not allowed' }); return; }
  const auth = String(req.headers.authorization || '');
  if (!/^Bearer\s+\S+/.test(auth)) { res.status(401).json({ error: 'შედით ანგარიშში' }); return; }
  try {
    const r = await fetch(SB_URL + '/rest/v1/rpc/has_license', { method: 'POST', headers: { apikey: SB_KEY, authorization: auth, 'content-type': 'application/json' }, body: '{}' });
    const ok = await r.json().catch(() => false);
    if (!r.ok) { res.status(401).json({ error: 'შედით ანგარიშში თავიდან' }); return; }
    if (ok !== true) { res.status(403).json({ error: 'ლიცენზია არ არის აქტიური' }); return; }
  } catch (e) { res.status(502).json({ error: 'ანგარიშის შემოწმება ვერ მოხერხდა' }); return; }
  const gw = process.env.AI_GATEWAY_API_KEY || (process.env.AI_GATEWAY_ON === '1' ? (req.headers['x-vercel-oidc-token'] || process.env.VERCEL_OIDC_TOKEN) : null);
  if (!gw) { res.status(503).json({ error: 'AI არ არის ჩართული' }); return; }
  let body = req.body || {};
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (_) { body = {}; } }
  const prompt = String(body.prompt || '').slice(0, 80000);
  if (!prompt) { res.status(400).json({ error: 'empty' }); return; }
  let last = null;
  for (const model of MODELS) {
    try {
      const r = await fetch('https://ai-gateway.vercel.sh/v1/chat/completions', {
        method: 'POST',
        headers: { authorization: 'Bearer ' + gw, 'content-type': 'application/json' },
        body: JSON.stringify({ model, max_tokens: 2000, temperature: 0.2, messages: [{ role: 'user', content: prompt }] })
      });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { console.error('assistant model failed', model, r.status, JSON.stringify(j).slice(0, 300)); last = (j.error && (j.error.message || j.error)) || 'HTTP ' + r.status; continue; }
      const text = (j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) || '';
      console.log('assistant ok', model);
      res.status(200).json({ text, model }); return;
    } catch (e) { last = String(e.message || e); }
  }
  res.status(502).json({ error: String(last || 'AI error').slice(0, 300) });
};
