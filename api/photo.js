// Novora: turns a 3D snapshot of the project into a photorealistic image.
// Uses GEMINI_API_KEY (Gemini 2.5 Flash Image) or OPENAI_API_KEY (gpt-image-1), whichever is set in Vercel env.
const ORIGIN_OK = /^https:\/\/(novora\.phillych\.ge|novora-konstruktori[\w-]*\.vercel\.app)(\/|$)/;

module.exports = async (req, res) => {
  const gem = process.env.GEMINI_API_KEY, oai = process.env.OPENAI_API_KEY;
  if (req.method === 'GET') { res.status(200).json({ ready: !!(gem || oai), engine: gem ? 'gemini' : oai ? 'openai' : null }); return; }
  if (req.method !== 'POST') { res.status(405).json({ error: 'method not allowed' }); return; }
  const from = req.headers.origin || req.headers.referer || '';
  if (!ORIGIN_OK.test(from)) { res.status(403).json({ error: 'origin not allowed' }); return; }
  if (!gem && !oai) { res.status(503).json({ error: 'AI გასაღები არ არის დაყენებული' }); return; }
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
