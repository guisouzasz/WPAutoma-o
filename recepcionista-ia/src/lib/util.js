// util.js — funções utilitárias puras (sem dependências).
// Este arquivo é embutido nos nós Code do n8n pelo gerador (scripts/build-workflows.mjs).

function normalizeText(s) {
  return String(s == null ? '' : s)
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

function truncate(s, max) {
  const t = String(s == null ? '' : s);
  return t.length <= max ? t : t.slice(0, Math.max(0, max - 1)).trimEnd() + '…';
}

function isUuid(s) {
  return typeof s === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

function isIsoDate(s) {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(s + 'T00:00:00Z');
  return !isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

function addDays(isoDate, n) {
  const d = new Date(isoDate + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function weekdayOf(isoDate) {
  return new Date(isoDate + 'T00:00:00Z').getUTCDay(); // 0 = domingo
}

function safeJsonParse(s) {
  if (s && typeof s === 'object') return s;
  try {
    return JSON.parse(s);
  } catch (e) {
    return null;
  }
}

function maskPhone(p) {
  const s = String(p || '');
  return s ? '****' + s.slice(-4) : '';
}

// Remove números longos e e-mails de mensagens de erro antes de registrar
function sanitizeForLog(s, max) {
  return truncate(
    String(s == null ? '' : s)
      .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[email]')
      .replace(/\+?\d[\d\s().-]{7,}\d/g, '[numero]')
      .replace(/(Bearer|token|access_token|key)[=:\s]+[A-Za-z0-9._-]{8,}/gi, '$1 [oculto]'),
    max || 300
  );
}

// Data local (AAAA-MM-DD) de um instante ISO no fuso informado
function localDate(iso, tz) {
  try {
    return new Intl.DateTimeFormat('en-CA', { timeZone: tz || 'America/Sao_Paulo', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(iso));
  } catch (e) {
    return String(iso || '').slice(0, 10);
  }
}
