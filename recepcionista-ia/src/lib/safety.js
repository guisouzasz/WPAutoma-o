// safety.js — regras determinísticas de segurança (não dependem da IA).
// Requer: util.js

// Sinais claros de perigo imediato => orientar emergência + humano
const EMERGENCY_PATTERNS = [
  /\b(nao|n) (consigo|consegue|to conseguindo|estou conseguindo) (respirar|engolir)\b/,
  /\b(dificuldade|dificil) (para|pra|de) (respirar|engolir)\b/,
  /\bfalta de ar\b/,
  /\bsangr\w*\b.{0,30}\b(muito|sem parar|nao para|nao parou|nao estanca|forte|intens\w*)\b/,
  /\b(muito|forte|intens\w*) sangr\w*/,
  /\b(rosto|olho|pescoco|garganta|cara) (todo |toda |muito )?inchad[oa]\b/,
  /\binchac\w* (no|na|do|da) (rosto|olho|pescoco|garganta|cara)\b/,
  /\bfebre alta\b/,
  /\b(acidente|atropel\w*|desmai\w*|convuls\w*)\b/,
  /\b(bati|batemos|bateu|caiu|cai|levei uma pancada).{0,30}\b(boca|rosto|dente|cara|queixo)\b/,
  /\bdente (saiu|caiu) (inteiro|todo|com raiz)\b/,
];

// Possível urgência odontológica => prioridade para a equipe (sem avaliar gravidade)
const URGENCY_PATTERNS = [
  /\b(dor|dores|doendo|doi|doido|latej\w*)\b/,
  /\b(inchad[oa]|inchac\w*|incha)\b/,
  /\b(sangr\w*)\b/,
  /\b(abscesso|pus|infeccao|infeccionad\w*)\b/,
  /\b(quebr\w*|trinc\w*|lasc\w*)\b.{0,20}\b(dente|protese|coroa|aparelho)\b/,
  /\b(dente|protese|coroa) (quebr\w*|caiu|soltou|mole)\b/,
  /\b(urgente|urgencia|emergencia|nao aguento)\b/,
];

const HUMAN_PATTERNS = [
  /\b(falar|conversar|atendimento|atender) (com )?(uma |um |a |o )?(pessoa|humano|humana|atendente|recepcionista|secretaria|alguem|gente)\b/,
  /\batendimento humano\b/,
  /\b(quero|queria|preciso de|pode chamar) (uma |um |a |o )?(atendente|recepcionista|secretaria|pessoa|humano)\b/,
  /\b(me liga|me ligue|ligar pra mim|ligar para mim)\b/,
  /\bnao (quero|gosto de) (falar com )?(robo|bot|maquina)\b/,
];

const COMPLAINT_PATTERNS = [
  /\b(reclamacao|reclamar|reclamo|pessimo|horrivel|absurdo|descaso|procon|processar|insatisfeit\w*|mal atendid\w*)\b/,
];

const OPT_OUT_EXACT = ['parar', 'pare', 'sair', 'stop', 'cancelar mensagens', 'nao quero receber mensagens', 'descadastrar', 'parar mensagens'];
const OPT_IN_EXACT = ['voltar', 'quero receber mensagens', 'receber mensagens'];

const INJECTION_PATTERNS = [
  /\b(ignore|ignora|ignorar|esqueca|esquece|desconsidere)\b.{0,40}\b(instruc\w*|regras|prompt|orientac\w*)\b/,
  /\b(system prompt|prompt do sistema|developer|desenvolvedor|modo dev|jailbreak)\b/,
  /\b(voce agora e|a partir de agora voce|aja como|finja ser)\b/,
  /\b(liste|mostre|me passe|me envie).{0,40}\b(todos os pacientes|outros pacientes|agenda de todos|telefones|banco de dados)\b/,
];

const MEDICAL_ADVICE_PATTERNS = [
  /\b\d+\s?mg\b/,
  /\b(antibiotic\w*|amoxicilina|ibuprofeno|dipirona|paracetamol|nimesulida|cetoprofeno|azitromicina|anti-inflamatorio|analgesico)\b/,
  /\b(tome|tomar|tomando|use|aplique|bochech\w*) .{0,25}\b(remedio|medicamento|comprimido|pomada|cha|agua morna com sal)\b/,
  /\bvoce (tem|esta com|pode estar com) (uma |um )?(carie|infeccao|abscesso|pulpite|gengivite|periodontite|fratura)\b/,
  /\b(diagnostic\w*|provavelmente e|parece ser) (uma |um )?(carie|infeccao|abscesso|pulpite|gengivite|periodontite|fratura)\b/,
];

const ACTION_CLAIM_PATTERNS = [/\b(agendad[oa]|marcad[oa]|confirmad[oa]|cancelad[oa]|remarcad[oa]|reservad[oa])\b/];

function matchesAny(patterns, text) {
  const t = normalizeText(text);
  return patterns.some((re) => re.test(t));
}

function detectEmergency(text) { return matchesAny(EMERGENCY_PATTERNS, text); }
function detectUrgency(text) { return matchesAny(URGENCY_PATTERNS, text); }
function detectHumanRequest(text) { return matchesAny(HUMAN_PATTERNS, text); }
function detectComplaint(text) { return matchesAny(COMPLAINT_PATTERNS, text); }
function detectInjection(text) { return matchesAny(INJECTION_PATTERNS, text); }
function isOptOut(text) { return OPT_OUT_EXACT.includes(normalizeText(text).replace(/[.!]+$/, '')); }
function isOptIn(text) { return OPT_IN_EXACT.includes(normalizeText(text).replace(/[.!]+$/, '')); }

const SAFE_FALLBACK_REPLY =
  'Não consigo avaliar sintomas nem indicar medicamentos por aqui. Posso agendar uma avaliação com o dentista ou chamar a nossa equipe. Como prefere?';

// Higieniza a resposta livre gerada pela IA antes de enviar ao paciente
function sanitizeAiReply(text, opts) {
  const o = opts || {};
  let t = String(text == null ? '' : text).replace(/\r/g, '').trim();
  if (!t) return o.fallback || '';
  if (matchesAny(MEDICAL_ADVICE_PATTERNS, t)) return SAFE_FALLBACK_REPLY;
  // A IA nunca confirma ações: quem confirma é o sistema, depois de gravar no banco
  if (o.forbidActionClaims !== false && matchesAny(ACTION_CLAIM_PATTERNS, t)) return o.fallback || '';
  t = t.replace(/https?:\/\/\S+/gi, '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  return truncate(t, o.max || 700);
}
