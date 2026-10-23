// Novora: turns a 3D snapshot of the project into a photorealistic image.
// Engines, first available wins: GEMINI_API_KEY (Google direct), OPENAI_API_KEY (gpt-image-1),
// otherwise Vercel AI Gateway (AI_GATEWAY_API_KEY, or the deployment's own OIDC token: no key needed).
const ORIGIN_OK = /^https:\/\/(novora\.phillych\.ge|novora-konstruktori[\w-]*\.vercel\.app)(\/|$)/;

module.exports = async (req, res) => {
  const gem = process.env.GEMINI_API_KEY, oai = process.env.OPENAI_API_KEY;
  const gw = process.env.AI_GATEWAY_API_KEY || req.headers['x-vercel-oidc-token'] || process.env.VERCEL_OIDC_TOKEN;
  if (req.method === 'GET') {
    const engine = gem ? 'gemini' : oai ? 'openai' : gw ? 'gateway' : null;
    if (req.query && req.query.test === '1' && engine === 'gateway') {
      try { const out = await gateway(gw, 'A small photorealistic wooden kitchen cabinet on a white background.', null); res.status(200).json({ ready: true, engine, test: 'ok', model: out.model, bytes: out.b64.length }); }
      catch (e) { res.status(200).json({ ready: false, engine, test: String((e && e.message) || e).slice(0, 300) }); }
      return;
    }
    res.status(200).json({ ready: !!engine, engine }); return;
  }
  if (req.method !== 'POST') { res.status(405).json({ error: 'method not allowed' }); return; }
  const from = req.headers.origin || req.headers.referer || '';
  if (!ORIGIN_OK.test(from)) { res.status(403).json({ error: 'origin not allowed' }); return; }
  if (!gem && !oai && !gw) { res.status(503).json({ error: 'AI გასაღები არ არის დაყენებული' }); return; }
  let body = req.body || {};
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (_) { body = {}; } }
  const m = /^data:image\/(png|jpeg);base64,([A-Za-z0-9+/=]+)$/.exec(body.image || '');
  if (!m || m[2].length > 4_000_000) { res.status(400).json({ error: 'bad image' }); return; }
  const prompt = String(body.prompt || '').slice(0, 4000);
  try {
    if (gem) {
      const r = await fetch('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent', {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': gem },
        body: JSON.stringify({ contents: [{ parts: [{ text: prompt }, { inline_data: { mime_type: 'image/' + m[1], data: m[2] } }] }] })
      });
      const j = await r.json();
      if (!r.ok) throw new Error((j.error && j.error.message) || 'HTTP ' + r.status);
      const part = ((j.candidates && j.candidates[0] && j.candidates[0].content && j.candidates[0].content.parts) || []).find(p => p.inlineData || p.inline_data);
      if (!part) throw new Error('სურათი არ დაბრუნდა');
      const d = part.inlineData || part.inline_data;
      res.status(200).json({ b64: d.data, format: String(d.mimeType || d.mime_type || 'image/png').split('/')[1] });
      return;
    }
    if (!oai) { const out = await gateway(gw, prompt, body.image); res.status(200).json({ b64: out.b64, format: out.format }); return; }
    const fd = new FormData();
    fd.append('model', 'gpt-image-1');
    fd.append('prompt', prompt);
    fd.append('size', '1536x1024');
    fd.append('quality', 'medium');
    fd.append('output_format', 'jpeg');
    fd.append('image', new Blob([Buffer.from(m[2], 'base64')], { type: 'image/' + m[1] }), 'scene.' + (m[1] === 'png' ? 'png' : 'jpg'));
    const r = await fetch('https://api.openai.com/v1/images/edits', { method: 'POST', headers: { authorization: 'Bearer ' + oai }, body: fd });
    const j = await r.json();
    if (!r.ok) throw new Error((j.error && j.error.message) || 'HTTP ' + r.status);
    res.status(200).json({ b64: j.data[0].b64_json, format: 'jpeg' });
  } catch (e) {
    res.status(502).json({ error: String((e && e.message) || e).slice(0, 300) });
  }
};

const GW_MODELS = ['google/gemini-3.1-flash-image-preview', 'google/gemini-2.5-flash-image'];
async function gateway(token, prompt, dataUrl) {
  let last = null;
  for (const model of GW_MODELS) {
    const content = dataUrl ? [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: dataUrl } }] : prompt;
    const r = await fetch('https://ai-gateway.vercel.sh/v1/chat/completions', {
      method: 'POST',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
      body: JSON.stringify({ model, messages: [{ role: 'user', content }], modalities: ['text', 'image'], stream: false })
    });
    let j = {}; try { j = await r.json(); } catch (_) {}
    if (!r.ok) { const msg = String((j.error && (j.error.message || j.error)) || 'HTTP ' + r.status); if (/credit card/i.test(msg)) throw new Error('AI-ს ჩასართავად Vercel-ში საბანკო ბარათია დასამატებელი (AI Gateway, უფასო კრედიტები)'); last = new Error(msg); continue; }
    const img = j.choices && j.choices[0] && j.choices[0].message && (j.choices[0].message.images || [])[0];
    const url = img && img.image_url && img.image_url.url;
    const m = /^data:image\/(\w+);base64,(.+)$/.exec(url || '');
    if (!m) { last = new Error('სურათი არ დაბრუნდა'); continue; }
    return { b64: m[2], format: m[1], model };
  }
  throw last || new Error('AI Gateway error');
}
