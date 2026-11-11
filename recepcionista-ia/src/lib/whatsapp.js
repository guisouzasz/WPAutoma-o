// whatsapp.js — monta payloads oficiais da WhatsApp Cloud API (Graph API /messages).
// Requer: util.js

function toGraphPayload(to, msg) {
  const base = { messaging_product: 'whatsapp', recipient_type: 'individual', to: String(to).replace(/\D/g, '') };
  switch (msg && msg.type) {
    case 'text':
      return Object.assign(base, { type: 'text', text: { preview_url: false, body: truncate(msg.text, 4096) } });
    case 'buttons':
      return Object.assign(base, { type: 'interactive', interactive: {
        type: 'button', body: { text: truncate(msg.text, 1024) },
        action: { buttons: msg.buttons.slice(0, 3).map((b) => ({ type: 'reply', reply: { id: b.id, title: truncate(b.title, 20) } })) },
      } });
    case 'list':
      return Object.assign(base, { type: 'interactive', interactive: {
        type: 'list', body: { text: truncate(msg.text, 1024) },
        action: { button: truncate(msg.button || 'Opções', 20), sections: [{ title: 'Opções', rows: msg.rows.slice(0, 10).map((r) => {
          const row = { id: r.id, title: truncate(r.title, 24) };
          if (r.description) row.description = truncate(r.description, 72);
          return row;
        }) }] },
      } });
    case 'location':
      return Object.assign(base, { type: 'location', location: {
        latitude: msg.latitude, longitude: msg.longitude, name: truncate(msg.name || '', 100), address: truncate(msg.address || '', 200),
      } });
    case 'template':
      return Object.assign(base, { type: 'template', template: { name: msg.name, language: { code: msg.language || 'pt_BR' }, components: msg.components || [] } });
    default:
      throw new Error('Tipo de mensagem não suportado: ' + (msg && msg.type));
  }
}

function graphKind(msg) {
  return { text: 'text', buttons: 'interactive', list: 'interactive', location: 'location', template: 'template' }[msg.type] || 'text';
}

// Template Utility de lembrete (aprovado na Meta) com botões de resposta rápida
function buildReminderTemplate(rem) {
  const tpl = rem.template || {};
  const params = (tpl.body_params || []).map((k) => ({ type: 'text', text: truncate(String(rem[k] == null ? '' : rem[k]), 60) || '-' }));
  const components = [];
  if (params.length) components.push({ type: 'body', parameters: params });
  (tpl.quick_reply_buttons || []).forEach((b, idx) => {
    components.push({ type: 'button', sub_type: 'quick_reply', index: String(idx), parameters: [{ type: 'payload', payload: `${b}:${rem.appointment_id}` }] });
  });
  return { type: 'template', name: tpl.name, language: tpl.language || 'pt_BR', components };
}

// Lembrete dentro da janela de 24h (mensagem de sessão, sem template)
function buildReminderSession(rem) {
  const name = rem.patient_first_name ? `Olá, ${rem.patient_first_name}! ` : 'Olá! ';
  return {
    type: 'buttons',
    text: `${name}Lembrete da sua consulta na ${rem.clinic_name}:\n\n📅 ${rem.label}\n🦷 ${rem.service_name}\n👩‍⚕️ ${rem.professional_name}\n📍 ${rem.address}\n\nVocê confirma a sua presença?`,
    buttons: [
      { id: 'CONFIRM:' + rem.appointment_id, title: 'Confirmar presença' },
      { id: 'RESCHEDULE:' + rem.appointment_id, title: 'Remarcar' },
      { id: 'CANCEL:' + rem.appointment_id, title: 'Cancelar' },
    ],
  };
}

function buildStaffAlertTemplate(tplCfg, text) {
  return { type: 'template', name: tplCfg.name, language: tplCfg.language || 'pt_BR',
    components: [{ type: 'body', parameters: [{ type: 'text', text: truncate(text.replace(/\s*\n\s*/g, ' | '), 900) }] }] };
}

// Interpreta a resposta do HTTP Request (com "Never Error" + resposta completa)
function parseGraphResponse(res) {
  const status = res && (res.statusCode || res.status);
  const body = res && (res.body !== undefined ? res.body : res);
  const parsed = typeof body === 'string' ? safeJsonParse(body) : body;
  if (status >= 200 && status < 300 && parsed && parsed.messages && parsed.messages[0]) {
    return { ok: true, wa_message_id: parsed.messages[0].id };
  }
  const err = (parsed && parsed.error) || {};
  return { ok: false, status: status || 0, error_code: String(err.code || status || 'network'), error_title: sanitizeForLog(err.message || err.error_user_msg || 'Falha ao enviar', 200),
    retryable: !status || status >= 500 || status === 429 || String(err.code) === '131048' || String(err.code) === '130429' };
}
