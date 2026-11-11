// webhook.js — normaliza a saída do nó "WhatsApp Trigger" do n8n.
// O nó entrega um item por "change" do webhook da Meta: { ...change.value, field }.
// Retorna uma lista de eventos simples: mensagens recebidas e status de entrega.

const SUPPORTED_TYPES = ['text', 'audio', 'interactive', 'button'];

function parseWhatsAppEvents(values) {
  const events = [];
  for (const v of values || []) {
    if (!v || (v.field && v.field !== 'messages')) continue;
    const meta = v.metadata || {};
    const phoneNumberId = meta.phone_number_id ? String(meta.phone_number_id) : null;
    const contacts = Array.isArray(v.contacts) ? v.contacts : [];

    for (const m of Array.isArray(v.messages) ? v.messages : []) {
      if (!m || !m.id || !m.from) continue;
      const contact = contacts.find((c) => c && c.wa_id === m.from) || contacts[0] || {};
      const ev = {
        kind: 'message',
        phone_number_id: phoneNumberId,
        wa_message_id: String(m.id),
        from: String(m.from).replace(/\D/g, ''),
        profile_name: (contact.profile && contact.profile.name) || null,
        timestamp: m.timestamp ? String(m.timestamp) : null,
        type: m.type || 'unknown',
        text: null,
        audio: null,
        reply_id: null,
        reply_title: null,
        supported: SUPPORTED_TYPES.includes(m.type),
      };
      if (m.type === 'text' && m.text) {
        ev.text = String(m.text.body || '');
      } else if (m.type === 'audio' && m.audio) {
        ev.audio = { id: m.audio.id, mime_type: m.audio.mime_type || null, voice: !!m.audio.voice };
      } else if (m.type === 'interactive' && m.interactive) {
        const r = m.interactive.button_reply || m.interactive.list_reply || {};
        ev.reply_id = r.id ? String(r.id) : null;
        ev.reply_title = r.title ? String(r.title) : null;
        ev.text = ev.reply_title;
      } else if (m.type === 'button' && m.button) {
        // Resposta rápida de template (ex.: lembrete)
        ev.reply_id = m.button.payload ? String(m.button.payload) : null;
        ev.reply_title = m.button.text ? String(m.button.text) : null;
        ev.text = ev.reply_title;
      }
      if (ev.text && ev.text.length > 2000) ev.text = ev.text.slice(0, 2000);
      events.push(ev);
    }

    for (const s of Array.isArray(v.statuses) ? v.statuses : []) {
      if (!s || !s.id) continue;
      const err = Array.isArray(s.errors) && s.errors[0] ? s.errors[0] : null;
      events.push({
        kind: 'status',
        phone_number_id: phoneNumberId,
        wa_message_id: String(s.id),
        status: s.status,
        error_code: err ? String(err.code) : null,
        error_title: err ? String(err.title || err.message || '') : null,
      });
    }
  }
  return events;
}
