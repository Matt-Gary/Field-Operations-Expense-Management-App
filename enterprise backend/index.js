const express = require('express');
const mysql = require('mysql2/promise');
const cors = require('cors');
const axios = require('axios');
const multer = require('multer');
const fs = require('fs');
const path = require('path');
const os = require('os');
const FormData = require('form-data');
const mime = require('mime-types');
const sharp = require('sharp');
const archiver = require('archiver');
require('dotenv').config();

const STORAGE_PATH = process.env.STORAGE_PATH || 'C:\\enterprise-files';
if (!fs.existsSync(STORAGE_PATH)) {
  fs.mkdirSync(STORAGE_PATH, { recursive: true });
}

const app = express();
app.use(cors());
app.use(express.json({ limit: '5mb' }));

app.use((req, res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.originalUrl}`);
  next();
});
const PROJECT_ID = Number(process.env.PROJECT_ID);

// ========= MySQL POOLS =========
// enterprise (existing)
const enterprisePool = mysql.createPool({
  host: process.env.ENTERPRISE_DB_HOST,
  port: process.env.ENTERPRISE_DB_PORT,
  user: process.env.ENTERPRISE_DB_USER,
  password: process.env.ENTERPRISE_DB_PASS,
  database: process.env.ENTERPRISE_DB_NAME,
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0,
  // give the driver time to reconnect on slow setups
  connectTimeout: 20000,
});

// glpi (NEW - needed for users & project tasks)
const glpiPool = mysql.createPool({
  host: process.env.GLPI_DB_HOST,
  port: process.env.GLPI_DB_PORT,
  user: process.env.GLPI_DB_USER,
  password: process.env.GLPI_DB_PASS,
  database: process.env.GLPI_DB_NAME,
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0,
  enableKeepAlive: true,
  keepAliveInitialDelay: 10000,
  connectTimeout: 30000,
  ssl: {
    rejectUnauthorized: false,
  },
});
setInterval(async () => {
  try {
    await enterprisePool.query('SELECT 1');
    await glpiPool.query('SELECT 1');
  } catch (err) {
    console.warn('DB keepalive failed:', err.message);
  }
}, 60000); // 1 minute

async function queryWithRetry(pool, sql, params = [], attempts = 2) {
  let lastErr;
  for (let i = 0; i < attempts; i++) {
    try {
      const [rows] = await pool.query(sql, params); // call the real pool
      return rows;
    } catch (err) {
      lastErr = err;
      const transient = [
        'ECONNRESET',
        'PROTOCOL_CONNECTION_LOST',
        'ER_SERVER_SHUTDOWN',
        'ETIMEDOUT',
        'EPIPE',
      ];
      if (transient.includes(err.code) && i < attempts - 1) {
        console.warn(`[mysql] transient ${err.code}; retrying ${i + 1}/${attempts - 1}`);
        continue;
      }
      throw err;
    }
  }
  throw lastErr;
}
// Minimal helper with one retry on dropped connections
async function execOnceWithRetry(sql, params) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const [result] = await enterprisePool.execute(sql, params); // mysql2/promise
      return result;
    } catch (err) {
      if (attempt === 1 && (err.code === 'ECONNRESET' || err.code === 'PROTOCOL_CONNECTION_LOST')) {
        console.warn('MySQL connection dropped, retrying once…');
        continue;
      }
      throw err;
    }
  }
}


const MAX_FILE_SIZE = Number(process.env.MAX_FILE_SIZE) || 2097152;
const ALLOWED_EXTENSIONS = (process.env.ALLOWED_EXTENSIONS || 'jpg,jpeg,png,pdf,txt,doc,docx,heic')
  .split(',')
  .map(ext => ext.trim().toLowerCase());

// ===== Multer storage =====
const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => cb(null, STORAGE_PATH),
    filename: (req, file, cb) => {
      let ext = path.extname(file.originalname).toLowerCase();
      cb(null, `${Date.now()}-${Math.round(Math.random() * 1E9)}${ext}`);
    }
  }),
  limits: {
    fileSize: MAX_FILE_SIZE
  },
  fileFilter: (req, file, cb) => {
    let ext = path.extname(file.originalname).toLowerCase();
    if (ext.startsWith('.')) ext = ext.substring(1);

    if (ALLOWED_EXTENSIONS.includes(ext)) {
      cb(null, true);
    } else {
      cb(new Error(`Extensão não permitida: ${ext}`));
    }
  }
});

// ===== GLPI helpers =====
async function glpiInitSession() {
  const { data } = await axios.get(`${process.env.GLPI_URL}/initSession`, {
    headers: {
      'App-Token': process.env.APP_TOKEN,
      'Authorization': `user_token ${process.env.USER_TOKEN}`
    }
  });
  const token = data && data.session_token;
  if (!token) throw new Error('Failed to get GLPI Session-Token');
  return token;
}

async function glpiKillSession(sessionToken) {
  try {
    await axios.get(`${process.env.GLPI_URL}/killSession`, {
      headers: { 'App-Token': process.env.APP_TOKEN, 'Session-Token': sessionToken }
    });
  } catch (_) { /* ignore */ }
}

function glpiFrontBase() {
  if (process.env.GLPI_FRONT_URL && process.env.GLPI_FRONT_URL.trim()) {
    return process.env.GLPI_FRONT_URL.replace(/\/+$/, '');
  }
  return String(process.env.GLPI_URL).replace(/\/apirest\.php\/?$/, '');
}

function inferExt(mime) {
  if (!mime) return null;
  const m = mime.toLowerCase();
  if (m.includes('jpeg') || m === 'image/jpg') return 'jpg';
  if (m.includes('png')) return 'png';
  if (m.includes('gif')) return 'gif';
  if (m.includes('pdf')) return 'pdf';
  if (m.includes('plain')) return 'txt';
  if (m.includes('json')) return 'json';
  if (m.includes('heic')) return 'heic';
  return null;
}

function looksLikeHtml(ctype) {
  return typeof ctype === 'string' && ctype.toLowerCase().startsWith('text/html');
}

function extractGlpiDocId(url) {
  if (!url || typeof url !== 'string') return null;
  const m = url.match(/[?&]docid=(\d+)/);
  return m ? Number(m[1]) : null;
}

async function migrateGlpiFileToLocal({ docid, entityType, entityId, columnToClear }) {
  let sessionToken;
  try {
    sessionToken = await glpiInitSession();

    // Fetch metadata for filename/mimetype
    let meta = {};
    try {
      const r = await axios.get(`${process.env.GLPI_URL}/Document/${docid}`, {
        headers: { 'App-Token': process.env.APP_TOKEN, 'Session-Token': sessionToken },
        validateStatus: () => true,
      });
      if (r.status === 200) meta = r.data;
    } catch (_) { }

    const stored = (meta.filename || '').trim();
    const display = (meta.name || '').trim();
    const mime = (meta.mime || '').trim() || 'application/octet-stream';
    let origFilename = display || stored || `document-${docid}`;
    if (!/\.[a-z0-9]{2,8}$/i.test(origFilename)) {
      const ext = inferExt(mime);
      if (ext) origFilename += `.${ext}`;
    }

    // Download file bytes
    let dlResp = null;
    for (const url of [
      `${process.env.GLPI_URL}/Document/${docid}/download`,
      `${process.env.GLPI_URL}/Document/${docid}?download=1`,
    ]) {
      try {
        const r = await axios.get(url, {
          responseType: 'arraybuffer',
          headers: { 'App-Token': process.env.APP_TOKEN, 'Session-Token': sessionToken, Accept: 'application/octet-stream' },
          maxRedirects: 3, validateStatus: (s) => s >= 200 && s < 400,
        });
        if (!looksLikeHtml(r.headers['content-type'] || '')) { dlResp = r; break; }
      } catch (_) { }
    }
    if (!dlResp) {
      try {
        const r = await axios.get(`${glpiFrontBase()}/front/document.send.php?docid=${docid}`, {
          responseType: 'arraybuffer',
          headers: { 'App-Token': process.env.APP_TOKEN, 'Session-Token': sessionToken, Accept: '*/*' },
          maxRedirects: 5, validateStatus: (s) => s >= 200 && s < 400,
        });
        if (!looksLikeHtml(r.headers['content-type'] || '')) dlResp = r;
      } catch (_) { }
    }
    if (!dlResp) throw new Error(`Could not download GLPI docid ${docid}`);

    const bytes = Buffer.from(dlResp.data);

    // Guard: GLPI document exists but has no content — clear URL to stop retrying, skip save
    if (bytes.length === 0) {
      console.warn(`[migrate] docid ${docid} is empty in GLPI — clearing URL, skipping save`);
      if (entityType === 'viagem') {
        await enterprisePool.execute(`UPDATE registro_viagem SET ${columnToClear} = NULL WHERE viagem_id = ?`, [entityId]);
      } else {
        await enterprisePool.execute(`UPDATE despesas SET ${columnToClear} = NULL WHERE despesa_id = ?`, [entityId]);
      }
      return null;
    }

    const localFilename = `glpi_${docid}_${origFilename.replace(/[^\w.\-]/g, '_')}`;
    fs.writeFileSync(path.join(STORAGE_PATH, localFilename), bytes);

    let insertId;
    if (entityType === 'viagem') {
      const [r] = await enterprisePool.execute(
        'INSERT INTO enterprise_viagem_arquivos (viagem_id, filename, mimetype, size) VALUES (?, ?, ?, ?)',
        [entityId, localFilename, mime, bytes.length]
      );
      insertId = r.insertId;
      await enterprisePool.execute(`UPDATE registro_viagem SET ${columnToClear} = NULL WHERE viagem_id = ?`, [entityId]);
    } else {
      const [r] = await enterprisePool.execute(
        'INSERT INTO enterprise_despesas_arquivos (despesas_id, filename, mimetype, size) VALUES (?, ?, ?, ?)',
        [entityId, localFilename, mime, bytes.length]
      );
      insertId = r.insertId;
      await enterprisePool.execute(`UPDATE despesas SET ${columnToClear} = NULL WHERE despesa_id = ?`, [entityId]);
    }

    return { id: insertId, filename: localFilename, mimetype: mime, size: bytes.length };
  } finally {
    if (sessionToken) await glpiKillSession(sessionToken);
  }
}

async function glpiCreateProjectTask(sessionToken, { atividade, data_conclusao, comentario }) {
  const payload = {
    input: {
      name: atividade,
      plan_end_date: data_conclusao, // ISO 8601 is fine
      content: comentario,
      projects_id: process.env.PROJECT_ID,
      projectstates_id: 1
    }
  };

  const { data } = await axios.post(`${process.env.GLPI_URL}/ProjectTask`, payload, {
    headers: {
      'App-Token': process.env.APP_TOKEN,
      'Session-Token': sessionToken,
      'Content-Type': 'application/json'
    }
  });
  const id = data?.id ?? data?.[0]?.id;
  if (!id) throw new Error('GLPI did not return a ProjectTask id');
  return Number(id);
}

async function optimizeImageFile(inputPath, originalName, mimeType, sizeLimitBytes = MAX_PART_BYTES) {
  // non-image? skip
  if (!/^image\//i.test(mimeType)) return { path: inputPath, filename: originalName, optimized: false };

  let image = sharp(inputPath, { failOnError: false });
  const meta = await image.metadata();

  // Resize if huge (preserve aspect)
  if (meta.width && meta.height) {
    const larger = Math.max(meta.width, meta.height);
    if (larger > OPTS.maxDim) {
      image = image.resize({
        width: meta.width >= meta.height ? OPTS.maxDim : null,
        height: meta.height > meta.width ? OPTS.maxDim : null,
        withoutEnlargement: true,
        fit: 'inside'
      });
    }
  }

  // choose target format
  const hasAlpha = !!meta.hasAlpha;
  let target = 'jpeg';

  // base quality
  let quality = target === 'webp' ? OPTS.webpQuality : OPTS.jpegQuality;

  // function to encode with current quality
  const encode = (q) => {
    let pipeline = image.clone().withMetadata({ orientation: meta.orientation }); // keep orientation only
    // strip other metadata to save bytes
    pipeline = pipeline.rotate(); // respect EXIF orientation
    if (target === 'jpeg') {
      pipeline = pipeline.jpeg({
        quality: q,
        progressive: true,
        mozjpeg: true,
        chromaSubsampling: '4:2:0'
      });
    } else if (target === 'webp') {
      pipeline = pipeline.webp({
        quality: q,
        alphaQuality: hasAlpha ? 75 : undefined,
        smartSubsample: true
      });
    } else {
      // Fallback: try jpeg
      target = 'jpeg';
      pipeline = pipeline.jpeg({ quality: q, progressive: true, mozjpeg: true });
    }
    return pipeline.toBuffer();
  };

  // try, then step down until ≤ sizeLimitBytes or quality floor
  let out = await encode(quality);
  while (out.length > sizeLimitBytes && quality > OPTS.minQuality) {
    quality = Math.max(OPTS.minQuality, quality - OPTS.qualityStep);
    out = await encode(quality);
  }

  // write optimized to a new temp file (don’t overwrite original until we succeed)
  const newExt = '.jpg';
  const newName = originalName.replace(/\.[^.]+$/g, '') + newExt;
  const outPath = path.join(path.dirname(inputPath), `${Date.now()}-opt-${newName}`);
  await fs.promises.writeFile(outPath, out);

  // if we created a new file, delete the original temp
  try { await fs.promises.unlink(inputPath); } catch { }

  return { path: outPath, filename: newName, optimized: true, finalBytes: out.length };
}


function mapGlpiStateToStatus(stateId) {
  switch (Number(stateId)) {
    case 1: return 'Novo';
    case 2: return 'Pendente';
    case 3: return 'Fechado';
    case 4: return 'Planejado';
    case 6: return 'Cancelado';
    case 7: return 'Aguardando Aprovação';
    case 8: return 'Em Andamento';
    case 9: return 'Reprovado';
    default: return `State-${stateId}`;
  }
}


async function glpiGetProjectTask(sessionToken, id) {
  const { data } = await axios.get(`${process.env.GLPI_URL}/ProjectTask/${id}`, {
    headers: {
      'App-Token': process.env.APP_TOKEN,
      'Session-Token': sessionToken
    }
  });
  return data;
}

async function glpiUpdateProjectTask(sessionToken, id, fields) {
  // GLPI expects PUT /ProjectTask/{id} with payload: { input: { id, ...fields } }
  const payload = { input: { id, ...fields } };
  const { data } = await axios.put(`${process.env.GLPI_URL}/ProjectTask/${id}`, payload, {
    headers: {
      'App-Token': process.env.APP_TOKEN,
      'Session-Token': sessionToken,
      'Content-Type': 'application/json'
    }
  });
  return data;
}
// Create a membership in glpi_projecttaskteams (assign user to task)
async function glpiAddProjectTaskTeam(sessionToken, { projecttasks_id, itemtype = 'User', items_id }) {
  const payload = { input: { projecttasks_id, itemtype, items_id } };
  const { data } = await axios.post(`${process.env.GLPI_URL}/ProjectTaskTeam`, payload, {
    headers: {
      'App-Token': process.env.APP_TOKEN,
      'Session-Token': sessionToken,
      'Content-Type': 'application/json'
    }
  });
  return data;
}
// --- NEW: map para gravar no task_status_log
function mapStatusIdToLogName(id) {
  switch (Number(id)) {
    case 6: return 'CANCELADO';
    case 8: return 'EM_ANDAMENTO';
    case 2: return 'PENDENTE';
    case 7: return 'APROVACAO';
    case 3: return 'CONCLUIDO';
    case 9: return 'REPROVADO';
    default: return 'PENDENTE';
  }
}

async function appendStatusLog(taskId, statusId, changedBy, whenConn = enterprisePool) {
  const statusName = mapStatusIdToLogName(statusId);
  const sql = `
    INSERT INTO task_status_log (task_id, status, changed_at, changed_by)
    VALUES (?, ?, NOW(), ?)
  `;
  await whenConn.execute(sql, [taskId, statusName, changedBy ?? null]);
}
function toMySQLDateTime(value) {
  if (!value) return null;

  // 1) If it's already a clean MySQL-ready string, just return it
  if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(value.trim())) {
    return value.trim();
  }

  // 2) Use Date object for parsing
  const d = new Date(value);
  if (isNaN(d.getTime())) return null;

  // 3) Extract parts based on the input style to preserve "literal" numbers.
  // We want what the user typed. If they sent a string without 'Z', JS parses as Local.
  // If they sent 'Z', JS parses as UTC.
  // To keep it simple and match "What goes in, stays", we'll check if the input string had 'Z'.
  const isUtcInput = typeof value === 'string' && (value.includes('Z') || value.includes('+'));

  if (isUtcInput) {
    const yyyy = d.getUTCFullYear();
    const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
    const dd = String(d.getUTCDate()).padStart(2, '0');
    const hh = String(d.getUTCHours()).padStart(2, '0');
    const mi = String(d.getUTCMinutes()).padStart(2, '0');
    const ss = String(d.getUTCSeconds()).padStart(2, '0');
    return `${yyyy}-${mm}-${dd} ${hh}:${mi}:${ss}`;
  } else {
    // Treat as Local numbers (literal)
    const yyyy = d.getFullYear();
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    const hh = String(d.getHours()).padStart(2, '0');
    const mi = String(d.getMinutes()).padStart(2, '0');
    const ss = String(d.getSeconds()).padStart(2, '0');
    return `${yyyy}-${mm}-${dd} ${hh}:${mi}:${ss}`;
  }
}
// Extract local parts in America/Sao_Paulo without DST
function getLocalParts(dateStr) {
  if (!dateStr) return null;
  const d = new Date(dateStr);
  if (Number.isNaN(d.getTime())) return null;

  const fmt = new Intl.DateTimeFormat('pt-BR', {
    timeZone: 'America/Sao_Paulo',
    hour12: false,
    weekday: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });

  // ex: "sex., 08:30" or similar (locale-dependent)
  const parts = fmt.formatToParts(d).reduce((acc, p) => {
    acc[p.type] = p.value;
    return acc;
  }, {});

  // weekday short → map to 0..6? We'll check by name
  const wd = (parts.weekday || '').toLowerCase(); // seg., ter., qua., qui., sex., sáb., dom.
  const hour = Number(parts.hour ?? '0');   // 0..23
  const minute = Number(parts.minute ?? '0'); // 0..59

  return { wd, hour, minute };
}

function isWeekend(dateStr) {
  const p = getLocalParts(dateStr);
  if (!p) return false;
  // covers both "sáb." and "sab.", "dom."
  return p.wd.includes('sáb') || p.wd.includes('sab') || p.wd.includes('dom');
}

// inclusive 08:00 and 18:00 are **inside** HC window
function isInsideHC(dateStr) {
  const p = getLocalParts(dateStr);
  if (!p) return false;
  const hm = p.hour * 60 + p.minute;
  return hm >= (8 * 60) && hm <= (18 * 60);
}

/**
 * Compute modo_de_trabalho:
 * - If any of start/end is weekend → "FDS"
 * - Else if any of start/end is outside HC window:
 *     return considerFhc ? "FHC" : "HC"
 * - Else → "HC"
 */
function computeModoDeTrabalho({ startISO, endISO, considerFhc }) {
  if (!startISO || !endISO) return null;

  if (isWeekend(startISO) || isWeekend(endISO)) return 'FDS';

  const startIn = isInsideHC(startISO);
  const endIn = isInsideHC(endISO);

  if (!startIn || !endIn) {
    return considerFhc ? 'FHC' : 'HC';
  }
  return 'HC';
}
app.get('/__dbinfo', async (req, res) => {
  try {
    const [[db]] = await enterprisePool.query(`SELECT DATABASE() AS db`);
    const [[user]] = await enterprisePool.query(`SELECT USER() AS userhost`);
    const [[host]] = await enterprisePool.query(`SELECT @@hostname AS mysql_host`);
    const [[port]] = await enterprisePool.query(`SELECT @@port AS mysql_port`);
    const [[ver]] = await enterprisePool.query(`SELECT @@version AS mysql_version`);

    res.json({
      poolEnv: {
        host: process.env.ENTERPRISE_DB_HOST,
        port: process.env.ENTERPRISE_DB_PORT,
        user: process.env.ENTERPRISE_DB_USER,
        database: process.env.ENTERPRISE_DB_NAME
      },
      server: { ...db, ...user, ...host, ...port, ...ver }
    });
  } catch (e) {
    console.error('dbinfo error:', e);
    res.status(500).json({ error: e.message });
  }
});
app.get('/enterprise-lider', async (req, res) => {
  try {
    const results = await queryWithRetry(
      enterprisePool,
      'SELECT id, nome FROM enterprise_liders ORDER BY nome ASC'
    );
    res.json(results.map(r => ({ id: r.id, nome: r.nome })));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /sites-enterprise  →  [{id, site}, ...]  (for Survey Site ENTERPRISE dropdown)
app.get('/sites-enterprise', async (req, res) => {
  try {
    const results = await queryWithRetry(
      enterprisePool,
      'SELECT id, site FROM sites_enterprise ORDER BY site ASC'
    );
    res.json(results.map(r => ({ id: r.id, site: r.site })));
  } catch (err) {
    console.error('GET /sites-enterprise error:', err);
    res.status(500).json({ error: err.message });
  }
});

// POST /survey-enterprise  →  insert survey record
app.post('/survey-enterprise', async (req, res) => {
  try {
    const {
      solicitante,
      projeto,
      objetivo,
      site_enterprise,
      data_de_execucao,
      horario_agendado,
      empresa_responsavel,
      entregavel_previsto,
    } = req.body || {};

    if (!solicitante || !projeto || !objetivo || !site_enterprise ||
      !data_de_execucao || !horario_agendado ||
      !empresa_responsavel || !entregavel_previsto) {
      return res.status(400).json({ error: 'Todos os campos são obrigatórios.' });
    }

    const sql = `
      INSERT INTO survey_enterprise
        (Solicitante, Projeto, Objetivo, Site_ENTERPRISE,
         Data_de_execucao, Horario_Agendado, Empresa_Responsavel, Entregavel_Previsto)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `;
    const result = await execOnceWithRetry(sql, [
      solicitante,
      projeto,
      objetivo,
      site_enterprise,
      data_de_execucao,    // YYYY-MM-DD
      horario_agendado,    // HH:MM:SS
      empresa_responsavel,
      entregavel_previsto,
    ]);

    res.status(201).json({ ok: true, id: result.insertId });
  } catch (err) {
    console.error('POST /survey-enterprise error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/service-types', async (req, res) => {
  try {
    const results = await queryWithRetry(
      enterprisePool,
      'SELECT DISTINCT TIPO_DE_SERVIÇO AS tipo FROM Tab_6_Tabela_de_servicos_US'
    );
    res.json(results.map(r => r.tipo));
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});


app.get('/services', async (req, res) => {
  const type = req.query.type;
  if (!type) return res.status(400).json({ error: 'type is required' });

  const sql = `
    SELECT 
      ITEM,
      ATIVIDADE,
      DESCRIÇÃO_DETALHADA AS descricao_detalhada
    FROM Tab_6_Tabela_de_servicos_US
    WHERE TIPO_DE_SERVIÇO = ?
  `;

  try {
    const results = await queryWithRetry(enterprisePool, sql, [type]);
    res.json(results);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});


app.get('/service-detail', async (req, res) => {
  const item = req.query.item;
  if (!item) return res.status(400).json({ error: 'item is required' });

  try {
    const results = await queryWithRetry(
      enterprisePool,
      'SELECT * FROM Tab_6_Tabela_de_servicos_US WHERE ITEM = ?',
      [item]
    );
    res.json(results[0] || null);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});
// PIN
// === FETCH LIST OF ALL USERS (id + name) ===
app.get('/user-pin', async (req, res) => {
  try {
    const results = await queryWithRetry(
      enterprisePool,
      'SELECT user_id, name, role FROM user_pins',
      []
    );
    res.json(results);
  } catch (err) {
    console.error('Error fetching user list:', err);
    res.status(500).json({ error: 'Failed to fetch user list' });
  }
});


// === FETCH SINGLE USER (name + pin) ===
app.get('/user-pin/:user_id', async (req, res) => {
  const userId = parseInt(req.params.user_id, 10);
  if (isNaN(userId)) {
    return res.status(400).json({ error: 'Invalid user_id parameter' });
  }

  try {
    const results = await queryWithRetry(
      enterprisePool,
      'SELECT name, pin, role FROM user_pins WHERE user_id = ?',
      [userId]
    );

    if (!results || results.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    res.json({
      user_id: userId,
      name: results[0].name,
      pin: results[0].pin,
      role: results[0].role,
    });
  } catch (err) {
    console.error('Error fetching user PIN:', err);
    res.status(500).json({ error: 'Failed to fetch user PIN' });
  }
});
/// ### FAVORITOS ###
// GET /preaprovados/favoritos?userId=123
app.get('/preaprovados/favoritos', async (req, res) => {
  const userId = Number(req.query.userId);
  if (!userId) {
    return res.status(400).json({ error: 'userId obrigatório' });
  }

  try {
    const [rows] = await enterprisePool.query(
      'SELECT tarefa FROM user_preaprovadas_favorites WHERE user_id = ? ORDER BY tarefa ASC',
      [userId]
    );
    res.json(rows); // [{ tarefa: 'XYZ' }, ...]
  } catch (err) {
    console.error('Erro ao buscar favoritos:', err);
    res.status(500).json({ error: 'Erro ao buscar favoritos' });
  }
});
// POST /preaprovados/favoritos
// body: { userId, tarefa }
app.post('/preaprovados/favoritos', async (req, res) => {
  const { userId, tarefa } = req.body || {};
  if (!userId || !tarefa || !tarefa.trim()) {
    return res.status(400).json({ error: 'userId e tarefa são obrigatórios' });
  }

  try {
    await enterprisePool.query(
      `INSERT INTO user_preaprovadas_favorites (user_id, tarefa)
       VALUES (?, ?)
       ON DUPLICATE KEY UPDATE tarefa = VALUES(tarefa)`,
      [userId, tarefa.trim()]
    );
    res.json({ ok: true });
  } catch (err) {
    console.error('Erro ao favoritar tarefa:', err);
    res.status(500).json({ error: 'Erro ao favoritar tarefa' });
  }
});
// DELETE /preaprovados/favoritos
// query: ?userId=123&tarefa=XYZ
app.delete('/preaprovados/favoritos', async (req, res) => {
  const userId = Number(req.query.userId);
  const tarefa = (req.query.tarefa || '').trim();

  if (!userId || !tarefa) {
    return res.status(400).json({ error: 'userId e tarefa são obrigatórios' });
  }

  try {
    await enterprisePool.query(
      'DELETE FROM user_preaprovadas_favorites WHERE user_id = ? AND tarefa = ?',
      [userId, tarefa]
    );
    res.json({ ok: true });
  } catch (err) {
    console.error('Erro ao desfavoritar tarefa:', err);
    res.status(500).json({ error: 'Erro ao desfavoritar tarefa' });
  }
});
// ### end-FAVORITOS ###

// GET /preaprovados?user_id=<GLPI user id>
// Returns ["ATIVIDADE", ...] filtered by user's cargo (cdigocargofield)
// Empty list [] if user_id missing/invalid, user has no cargo, or no matches
app.get('/preaprovados', async (req, res) => {
  try {
    const userId = Number(req.query.user_id);

    if (!Number.isFinite(userId) || userId <= 0) {
      return res.json([]);
    }

    // fetch user's cargo
    const cargoRows = await queryWithRetry(
      glpiPool,
      `
        SELECT TRIM(cdigocargofield) AS cargo
        FROM glpi_plugin_fields_usercdcargos
        WHERE items_id = ?
          AND cdigocargofield IS NOT NULL
          AND TRIM(cdigocargofield) <> ''
        LIMIT 1
      `,
      [userId]
    );
    const cargo = cargoRows?.[0]?.cargo || null;
    if (!cargo) return res.json([]);

    // CHANGED: read from Tab_6_Tabela_de_servicos_US and filter preaprovados='Sim'
    const atividadesRows = await queryWithRetry(
      enterprisePool,
      `
        SELECT DISTINCT ATIVIDADE, ITEM
        FROM Tab_6_Tabela_de_servicos_US
        WHERE TRIM(SUBITEM_NUM) = ?
          AND UPPER(COALESCE(preaprovados, 'Não')) = 'SIM'   -- <— filter here
        ORDER BY ATIVIDADE ASC
      `,
      [cargo]
    );

    const atividades = (atividadesRows || [])
      .map(r => ({
        atividade: String(r.ATIVIDADE || '').trim(),
        item: String(r.ITEM || '').trim()
      }))
      .filter(o => o.atividade);

    return res.json(atividades);
  } catch (err) {
    console.error('GET /preaprovados error:', err);
    return res.json([]); // keep UX smooth
  }
});

// GET /preaprovados/info?user_id=123&tarefa=ESTUDOS%20...
app.get('/preaprovados/info', async (req, res) => {
  try {
    const userId = Number(req.query.user_id);
    const tarefa = (req.query.tarefa || '').toString().trim();

    if (!Number.isFinite(userId) || userId <= 0 || !tarefa) {
      return res.json({
        tarefa,
        tempo_previsto_h: null,
        tipo_de_evidencia: null,
        fracao_de_us: null,
        multiplo_de_us: null
      });
    }

    const cargoRows = await queryWithRetry(
      glpiPool,
      `
        SELECT TRIM(cdigocargofield) AS cargo
        FROM glpi_plugin_fields_usercdcargos
        WHERE items_id = ?
          AND cdigocargofield IS NOT NULL
          AND TRIM(cdigocargofield) <> ''
        LIMIT 1
      `,
      [userId]
    );
    const cargo = cargoRows?.[0]?.cargo || null;
    if (!cargo) {
      return res.json({
        tarefa,
        tempo_previsto_h: null,
        tipo_de_evidencia: null,
        fracao_de_us: null,
        multiplo_de_us: null
      });
    }

    // CHANGED: source table + evidence + preaprovados filter
    const infoRows = await queryWithRetry(
      enterprisePool,
      `
        SELECT \`H.h\` AS tempo_previsto_h, tipo_de_evidencia, FRACAO_DE_US, MULTIPLO_DE_US
        FROM Tab_6_Tabela_de_servicos_US
        WHERE ATIVIDADE = ?
          AND TRIM(SUBITEM_NUM) = ?
          AND UPPER(COALESCE(preaprovados, 'Não')) = 'SIM'
        LIMIT 1
      `,
      [tarefa, cargo]
    );

    let tempo = null;
    let tipo = null;
    let fracao = null;
    let multiplo = null;
    if (infoRows && infoRows.length) {
      const raw = infoRows[0].tempo_previsto_h;
      const num = Number(typeof raw === 'string' ? raw.replace(',', '.') : raw);
      tempo = Number.isFinite(num) ? num : null;
      tipo = (infoRows[0].tipo_de_evidencia ?? null);
      if (typeof tipo === 'string') tipo = tipo.trim();
      fracao = (infoRows[0].FRACAO_DE_US ?? null);
      multiplo = (infoRows[0].MULTIPLO_DE_US ?? null);
    }

    return res.json({
      tarefa,
      tempo_previsto_h: tempo,
      tipo_de_evidencia: tipo,
      fracao_de_us: fracao,
      multiplo_de_us: multiplo
    });
  } catch (err) {
    console.error('GET /preaprovados/info error:', err);
    return res.json({
      tarefa: (req.query.tarefa || null),
      tempo_previsto_h: null,
      tipo_de_evidencia: null,
      fracao_de_us: null,
      multiplo_de_us: null
    });
  }
});

// POST /preaprovados/create-task
app.post('/preaprovados/create-task', async (req, res) => {
  console.log('[preaprovados/create-task] incoming body:', req.body);

  const {
    tarefa,
    user_id,
    projectstates_id,
    comment,
    real_start_date,     // REQUIRED for any status
    user_conclude_date,  // REQUIRED only if status = 7 (Aprovação)
    data_start_pendente, // optional (REQUIRED if status=2)
    data_end_pendente,    // optional
    sobreaviso           // optional
  } = req.body || {};

  // ---- validations ----
  const tarefaText = (tarefa ?? '').toString().trim();
  if (!tarefaText) return res.status(400).json({ error: 'tarefa is required' });
  if (!user_id) return res.status(400).json({ error: 'user_id is required' });
  if (!projectstates_id) return res.status(400).json({ error: 'projectstates_id is required' });

  const quantidade_tarefas = Number(req.body?.quantidade_tarefas ?? 1);
  const qty = Number.isFinite(quantidade_tarefas) && quantidade_tarefas > 0 ? quantidade_tarefas : 1;
  const startForDb = toMySQLDateTime(real_start_date);
  const endForDb = toMySQLDateTime(user_conclude_date);
  const pendStartDb = toMySQLDateTime(data_start_pendente);
  const pendEndDb = toMySQLDateTime(data_end_pendente);
  const consider_fhc = Boolean(req.body?.consider_fhc);

  // Always require real_start_date (independent from pendente dates)
  if (!startForDb) {
    return res.status(400).json({ error: 'real_start_date é obrigatório.' });
  }

  // If status is 7 (Aprovação), require end date
  if (Number(projectstates_id) === 7 && !endForDb) {
    return res.status(400).json({ error: 'user_conclude_date é obrigatório quando status é Aprovação (7).' });
  }

  // If status is 2 (Pendente), require pendente start (but DO NOT align real_start)
  if (Number(projectstates_id) === 2 && !pendStartDb) {
    return res.status(400).json({ error: 'data_start_pendente é obrigatório quando status é Pendente (2).' });
  }

  // Compute working seconds only if closing (7) with start+end present
  // ativo_acumulado_seg = (real_end - real_start) - (pend_end - pend_start), clamped to >= 0
  const diffSeconds = (a, b) => {
    if (!a || !b) return 0;
    const A = new Date(a).getTime();
    const B = new Date(b).getTime();
    if (!Number.isFinite(A) || !Number.isFinite(B)) return 0;
    return Math.max(0, Math.floor((B - A) / 1000));
  };

  let ativoAcumuladoSeg = 0;
  if (Number(projectstates_id) === 7 && startForDb && endForDb) {
    const total = diffSeconds(startForDb, endForDb);
    let pend = 0;
    if (pendStartDb && pendEndDb) {
      // subtract only the intersection with [start..end]
      const s = new Date(startForDb).getTime();
      const e = new Date(endForDb).getTime();
      const ps = new Date(pendStartDb).getTime();
      const pe = new Date(pendEndDb).getTime();
      if (Number.isFinite(s) && Number.isFinite(e) && Number.isFinite(ps) && Number.isFinite(pe) && pe > ps) {
        const intStart = Math.max(s, ps);
        const intEnd = Math.min(e, pe);
        if (intEnd > intStart) pend = Math.floor((intEnd - intStart) / 1000);
      }
    }
    ativoAcumuladoSeg = Math.max(0, total - pend);
  }
  let modo = null;
  if (Number(projectstates_id) === 7 && startForDb && endForDb) {
    modo = computeModoDeTrabalho({
      startISO: startForDb,
      endISO: endForDb,
      considerFhc: consider_fhc,
    });
  }
  const finalModo = sobreaviso === 'Sim' ? 'HC' : modo;
  const finalSobreaviso = sobreaviso === 'Sim' ? 'Sim' : 'Nao';
  let sessionToken;
  try {
    // 1) Open GLPI session
    sessionToken = await glpiInitSession();

    // 2) Create task (minimal), then update with real fields
    const created = await glpiCreateProjectTask(sessionToken, {
      atividade: tarefaText,
      data_conclusao: null,
      comentario: (comment || '').toString()
    });

    let newTaskId = null;
    if (typeof created === 'number') newTaskId = created;
    else if (typeof created === 'string' && /^\d+$/.test(created)) newTaskId = Number(created);
    else if (created && typeof created === 'object') {
      newTaskId = created.id ?? (Array.isArray(created) ? created[0]?.id : undefined) ?? created.task?.id ?? created?.[0]?.id ?? null;
    }
    if (!newTaskId) {
      return res.status(500).json({ error: 'GLPI did not return a new task id', glpi_result: created });
    }

    // 3) Update GLPI task (use the provided real_start_date; DO NOT align to pendente)
    const updateFields = {
      name: tarefaText,
      projectstates_id: Number(projectstates_id),
      users_id: Number(user_id),
      real_start_date: startForDb,
    };
    if (endForDb) updateFields.real_end_date = endForDb;
    if (comment?.trim()) updateFields.content = comment.trim();
    await glpiUpdateProjectTask(sessionToken, newTaskId, updateFields);

    // 4) Assign user to task team (best-effort)
    try {
      await glpiAddProjectTaskTeam(sessionToken, {
        projecttasks_id: newTaskId, itemtype: 'User', items_id: Number(user_id)
      });
    } catch (e) {
      console.warn('[preaprovados/create-task] attach user failed:', e?.response?.data || e?.message);
    }

    // 5) Prepare formas_enviadas insert
    const statusText = mapGlpiStateToStatus(projectstates_id);

    // --- NEW: resolve ITEM using user's cargo (SUBITEM_NUM) ---
    let itemValue = null;

    // 5.a) read cargo for this GLPI user
    let cargo = null;
    try {
      const cargoRows = await queryWithRetry(
        glpiPool,
        `
          SELECT TRIM(cdigocargofield) AS cargo
          FROM glpi_plugin_fields_usercdcargos
          WHERE items_id = ?
            AND cdigocargofield IS NOT NULL
            AND TRIM(cdigocargofield) <> ''
          LIMIT 1
        `,
        [Number(user_id)]
      );
      cargo = (cargoRows?.[0]?.cargo || null);
    } catch (e) {
      console.warn('[preaprovados/create-task] cargo lookup failed:', e?.message);
    }

    // 5.b) first try: match by ATIVIDADE + SUBITEM_NUM = cargo
    if (cargo) {
      const [rowsByCargo] = await enterprisePool.execute(
        `
          SELECT ITEM
          FROM Tab_6_Tabela_de_servicos_US
          WHERE ATIVIDADE = ?
            AND TRIM(SUBITEM_NUM) = ?
          ORDER BY ITEM
          LIMIT 1
        `,
        [tarefaText, cargo]
      );
      if (rowsByCargo && rowsByCargo.length) {
        itemValue = String(rowsByCargo[0].ITEM).trim();
      }
    }

    // 5.c) fallback: match only by ATIVIDADE (previous behavior) if nothing found
    if (!itemValue) {
      const [rowsAny] = await enterprisePool.execute(
        `SELECT ITEM FROM Tab_6_Tabela_de_servicos_US WHERE ATIVIDADE = ? ORDER BY ITEM LIMIT 1`,
        [tarefaText]
      );
      if (rowsAny && rowsAny.length) {
        itemValue = String(rowsAny[0].ITEM).trim();
      }
    }
    // last_started_at: only if starts in Em Andamento (8)
    let lastStartedAt = null;
    if (Number(projectstates_id) === 8 && startForDb) {
      lastStartedAt = startForDb;
    }

    // 6) INSERT formas_enviadas (keeps pendente dates; ativo_acumulado_seg never NULL)
    const insertSql = `
      INSERT INTO formas_enviadas
      (task_id, lider, tipo_servico, item, atividade, descricao_detalhada,
       data_conclusao, comentario, enviado_em, status,
       user_conclude_date, user_id, data_start_real,
       ativo_acumulado_seg, last_started_at,
       data_start_pendente, data_end_pendente, quantidade_tarefas, modo_de_trabalho, sobreaviso)
      VALUES (?, NULL, ?, ?, ?, ?, NULL, ?, NOW(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `;

    const params = [
      newTaskId,
      tarefaText,                   // tipo_servico
      itemValue,                    // item
      tarefaText,                   // atividade
      tarefaText,                   // descricao_detalhada
      (comment || '').toString(),   // comentario
      statusText,                   // status (text)
      endForDb || null,             // user_conclude_date
      Number(user_id),
      startForDb,                   // data_start_real (independent)
      Number.isFinite(ativoAcumuladoSeg) ? ativoAcumuladoSeg : 0,
      lastStartedAt,
      pendStartDb,                  // data_start_pendente
      pendEndDb,                     // data_end_pendente
      qty,
      finalModo,
      finalSobreaviso
    ];

    const [result] = await enterprisePool.execute(insertSql, params);
    if (!result || result.affectedRows === 0) {
      console.error('[preaprovados/create-task] formas_enviadas insert failed:', { params });
      return res.status(500).json({ error: 'Failed to insert formas_enviadas', task_id: newTaskId });
    }

    await appendStatusLog(newTaskId, projectstates_id, Number(user_id));
    res.status(201).json({ success: true, task_id: newTaskId });
  } catch (err) {
    const detail = err?.response?.data ?? err?.message ?? String(err);
    console.error('POST /preaprovados/create-task error:', detail);
    res.status(500).json({ error: 'Failed to create preaprovada task', detail });
  } finally {
    if (sessionToken) await glpiKillSession(sessionToken);
  }
});



app.get('/vehicle', async (req, res) => {
  try {
    const rows = await queryWithRetry(
      enterprisePool,
      'SELECT DISTINCT registration_plate, vehicle_type FROM registered_vehicle'
    );
    res.json(rows.map(r => ({
      registration_plate: r.registration_plate,
      vehicle_type: r.vehicle_type
    })));
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

// POST /vehicle -> Register a new vehicle
app.post('/vehicle', async (req, res) => {
  const {
    registration_plate,
    producent,
    model,
    vehicle_type,
    cor,
    contract = 'Enterprise',
    consumo
  } = req.body || {};

  if (!registration_plate || !producent || !model || !vehicle_type || !consumo) {
    return res.status(400).json({ error: 'Campos obrigatórios faltando!' });
  }

  try {
    const sql = `
      INSERT INTO registered_vehicle
        (registration_plate, producent, model, vehicle_type, cor, contract, consumo)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `;
    const params = [
      registration_plate.toUpperCase().trim(),
      producent.trim(),
      model.trim(),
      vehicle_type.trim(),
      cor ? cor.trim() : null,
      contract.trim(),
      Number(consumo)
    ];

    const [result] = await enterprisePool.execute(sql, params);
    res.status(201).json({ success: true, id: result.insertId });
  } catch (err) {
    console.error('POST /vehicle error:', err);
    if (err.code === 'ER_DUP_ENTRY') {
      return res.status(409).json({ error: 'Veículo com esta placa já existe.' });
    }
    res.status(500).json({ error: 'Erro ao registrar veículo' });
  }
});

// ========= FORM SUBMIT: save to formas_enviadas + create GLPI tasks --> lider ENTERPRISE
app.post('/enviar-forma', async (req, res) => {
  const { lider, tipo_servico, servicos, comentario } = req.body || {};

  // Basic required fields (root level)
  if (!lider || !tipo_servico || !Array.isArray(servicos) || servicos.length === 0) {
    return res.status(400).json({ error: 'Campos obrigatórios faltando!' });
  }

  // Optional: enforce per-service user_id
  // if (servicos.some(s => !s?.user_id)) {
  //   return res.status(400).json({ error: 'user_id obrigatório por serviço' });
  // }

  const insertQuery = `
    INSERT INTO formas_enviadas
      (lider, tipo_servico, user_id, item, atividade, descricao_detalhada, data_conclusao, quantidade_tarefas, comentario, sobreaviso, modo_de_trabalho)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `;

  const updateQuery = `
    UPDATE formas_enviadas
       SET task_id = ?, status = ?
     WHERE id = ?
  `;

  let sessionToken;
  try {
    const inserted = [];

    for (const svc of servicos) {
      const {
        item,
        atividade,
        descricao_detalhada,
        data_conclusao,
        quantidade,
        user_id, // 👈 per-service assignee
        sobreaviso, // new field
      } = svc || {};

      // Validate required per-service fields
      if (!item || !atividade) {
        return res.status(400).json({ error: `Serviço inválido (item/atividade ausentes)` });
      }
      // If mandatory, enforce user_id here:
      if (!user_id) return res.status(400).json({ error: `user_id ausente para o item ${item}` });

      const quantidadeParsed = typeof quantidade === 'number'
        ? quantidade
        : (Number.parseFloat(quantidade) || 0);

      const modoDeTrabalho = sobreaviso === 'Sim' ? 'HC' : null;

      const [result] = await enterprisePool.execute(insertQuery, [
        lider,
        tipo_servico,
        user_id ?? null,
        item,
        atividade,
        descricao_detalhada ?? null,
        data_conclusao ?? null, // allow null if column permits
        quantidadeParsed,
        comentario ?? null,
        sobreaviso ?? 'Nao', // insert 'Sim' or 'Nao'
        modoDeTrabalho, // 'HC' if Sim, else null
      ]);

      const rowId = result.insertId;
      inserted.push({ rowId, svc });
    }

    // Create GLPI tasks and update their rows
    sessionToken = await glpiInitSession();

    for (const { rowId, svc } of inserted) {
      let taskId = null;

      // 1) Create task
      try {
        taskId = await glpiCreateProjectTask(sessionToken, {
          atividade: svc.atividade,
          data_conclusao: svc.data_conclusao,
          comentario
        });
      } catch (err) {
        console.error('GLPI task create failed:', err.response?.data || err.message);
        // leave task_id null but mark status
        await enterprisePool.execute(updateQuery, [null, 'GLPI Error', rowId]);
        continue;
      }

      // 2) Immediately persist task_id to formas_enviadas
      try {
        await enterprisePool.execute(updateQuery, [taskId, 'New', rowId]);
      } catch (err) {
        console.error('DB update with task_id failed:', err.message);
      }

      // 3) Attach user to task team (Equipe da tarefa)
      //    IMPORTANT: use { itemtype: 'User', items_id: <user id> }
      if (svc.user_id) {
        try {
          await glpiAddProjectTaskTeam(sessionToken, {
            projecttasks_id: taskId,
            itemtype: 'User',
            items_id: Number(svc.user_id),
          });
        } catch (err) {
          // Do not block the flow if team add fails
          console.error('GLPI add team member failed:',
            err.response?.status,
            JSON.stringify(err.response?.data ?? err.message)
          );
          // Optionally flag status:
          // await enterprisePool.execute(updateQuery, [taskId, 'Assignee Error', rowId]);
        }
      }
    }

    await glpiKillSession(sessionToken);
    res.json({ success: true });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message || 'Erro interno' });
  }
});
// send form from registro_viagem
app.post('/registro-viagem', async (req, res) => {
  const {
    user_id,
    name,
    plate,
    vehicle_type,
    start_km,
    finish_km,
    local_start,
    local_destination,
    reason,
    data_viagem
  } = req.body || {};

  // Required fields
  if (!user_id || !plate || !data_viagem) {
    return res.status(400).json({ error: 'Campos obrigatórios faltando!' });
  }

  try {
    // 1) KM validation and diff
    const start = Number(start_km);
    const end = Number(finish_km);
    if (!Number.isFinite(start) || !Number.isFinite(end)) {
      return res.status(400).json({ error: 'KM inválido' });
    }
    const km_sum = end - start;
    if (km_sum < 0) {
      return res.status(400).json({ error: 'finish_km não pode ser menor que start_km' });
    }

    // 2) Optional date normalization (DATE column expects YYYY-MM-DD)
    let dateOnly = null;
    if (data_viagem) {
      if (/^\d{4}-\d{2}-\d{2}$/.test(data_viagem)) {
        dateOnly = data_viagem;
      } else {
        const d = new Date(data_viagem);
        if (isNaN(d.getTime())) {
          return res.status(400).json({ error: 'data_viagem inválida' });
        }
        const yyyy = d.getUTCFullYear();
        const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
        const dd = String(d.getUTCDate()).padStart(2, '0');
        dateOnly = `${yyyy}-${mm}-${dd}`;
      }
    }

    // 3) Insert
    const sql = `
      INSERT INTO registro_viagem
        (user_id, name, plate, vehicle_type, start_km, finish_km,
         local_start, local_destination, reason, km_sum, data_viagem)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `;

    const params = [
      user_id, name || null, plate, vehicle_type || null, start, end,
      local_start, local_destination, reason, km_sum, dateOnly
    ];

    // Using mysql2/promise:
    const [result] = await enterprisePool.execute(sql, params);
    // result is ResultSetHeader
    const insertId = result.insertId;

    console.log('BODY /registro-viagem:', req.body);

    return res.status(201).json({ success: true, id: insertId, km_sum, data_viagem: dateOnly });
  } catch (err) {
    console.error('POST /registro-viagem error:', err);
    return res.status(500).json({ error: 'Erro ao registrar viagem' });
  }
});

// GET /registro-viagem
app.get('/registro-viagem', async (req, res) => {
  const userId = Number(req.query.user_id);
  const from = req.query.from; // optional YYYY-MM-DD
  const to = req.query.to;     // optional YYYY-MM-DD

  try {
    let sql = `
      SELECT viagem_id, user_id, name, plate, vehicle_type, start_km, finish_km,
             local_start, local_destination, reason, km_sum, data_viagem,
             glpi_subtask_id, photo_docid_inicio, photo_url_inicio, photo_docid_fim, photo_url_fim
      FROM registro_viagem
      WHERE 1=1
    `;
    const params = [];

    if (userId) {
      sql += ' AND user_id = ?';
      params.push(userId);
    }
    if (from) {
      sql += ' AND data_viagem >= ?';
      params.push(from);
    }
    if (to) {
      sql += ' AND data_viagem <= ?';
      params.push(to);
    }

    sql += ' ORDER BY data_viagem DESC, viagem_id DESC';

    const rows = await queryWithRetry(enterprisePool, sql, params);
    res.json(rows);
  } catch (err) {
    console.error('GET /registro-viagem error:', err);
    res.status(500).json({ error: 'Erro ao buscar viagens' });
  }
});

// PUT /registro-viagem/:id
app.put('/registro-viagem/:id', async (req, res) => {
  const viagemId = req.params.id;
  const {
    plate,
    vehicle_type,
    start_km,
    finish_km,
    local_start,
    local_destination,
    reason,
    data_viagem
  } = req.body;

  try {
    // 1) Recalculate km_sum if needed
    let km_sum = null;
    if (start_km != null && finish_km != null) {
      km_sum = Number(finish_km) - Number(start_km);
      if (km_sum < 0) {
        return res.status(400).json({ error: 'finish_km não pode ser menor que start_km' });
      }
    }

    // 2) Normalize date
    let dateOnly = null;
    if (data_viagem) {
      if (/^\d{4}-\d{2}-\d{2}$/.test(data_viagem)) {
        dateOnly = data_viagem;
      } else {
        const d = new Date(data_viagem);
        if (!isNaN(d.getTime())) {
          const yyyy = d.getUTCFullYear();
          const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
          const dd = String(d.getUTCDate()).padStart(2, '0');
          dateOnly = `${yyyy}-${mm}-${dd}`;
        }
      }
    }

    const sql = `
      UPDATE registro_viagem
      SET plate = COALESCE(?, plate),
          vehicle_type = COALESCE(?, vehicle_type),
          start_km = COALESCE(?, start_km),
          finish_km = COALESCE(?, finish_km),
          km_sum = COALESCE(?, km_sum),
          local_start = COALESCE(?, local_start),
          local_destination = COALESCE(?, local_destination),
          reason = COALESCE(?, reason),
          data_viagem = COALESCE(?, data_viagem)
      WHERE viagem_id = ?
    `;

    const params = [
      plate, vehicle_type, start_km, finish_km, km_sum,
      local_start, local_destination, reason, dateOnly,
      viagemId
    ];

    await enterprisePool.execute(sql, params);
    res.json({ success: true });
  } catch (err) {
    console.error('PUT /registro-viagem error:', err);
    res.status(500).json({ error: 'Erro ao atualizar viagem' });
  }
});

// DELETE /registro-viagem/:id
app.delete('/registro-viagem/:id', async (req, res) => {
  const viagemId = req.params.id;
  try {
    const [files] = await enterprisePool.query('SELECT filename FROM enterprise_viagem_arquivos WHERE viagem_id = ?', [viagemId]);
    for (const f of files) {
      const filepath = path.join(STORAGE_PATH, f.filename);
      if (fs.existsSync(filepath)) fs.unlinkSync(filepath);
    }
    await enterprisePool.execute('DELETE FROM enterprise_viagem_arquivos WHERE viagem_id = ?', [viagemId]);
    await enterprisePool.execute('DELETE FROM registro_viagem WHERE viagem_id = ?', [viagemId]);
    res.json({ success: true });
  } catch (err) {
    console.error('DELETE /registro-viagem error:', err);
    res.status(500).json({ error: 'Erro ao excluir viagem' });
  }
});

// DELETE /registro-viagem/:viagemId/file/:fileId
app.delete('/registro-viagem/:viagemId/file/:fileId', async (req, res) => {
  const viagemId = req.params.viagemId;
  const fileId = req.params.fileId;

  try {
    const [rows] = await enterprisePool.query('SELECT filename FROM enterprise_viagem_arquivos WHERE id = ? AND viagem_id = ?', [fileId, viagemId]);
    if (rows.length === 0) return res.status(404).json({ error: 'Arquivo não encontrado' });

    const filepath = path.join(STORAGE_PATH, rows[0].filename);
    if (fs.existsSync(filepath)) fs.unlinkSync(filepath);

    await enterprisePool.execute('DELETE FROM enterprise_viagem_arquivos WHERE id = ?', [fileId]);
    res.json({ success: true });
  } catch (err) {
    console.error('DELETE /registro-viagem file error:', err);
    res.status(500).json({ error: 'Erro ao remover arquivo da viagem' });
  }
});



// GET /file-upload-config
app.get('/file-upload-config', (req, res) => {
  const maxFileSize = parseInt(process.env.MAX_FILE_SIZE, 10) || 2097152; // default 2MB
  const allowedExtensions = (process.env.ALLOWED_EXTENSIONS || 'jpg,jpeg,png,pdf,txt,doc,docx')
    .split(',')
    .map(ext => ext.trim().toLowerCase())
    .filter(Boolean);
  res.json({ maxFileSize, allowedExtensions });
});

// POST /despesas
app.post('/despesas', async (req, res) => {
  try {
    const {
      user_id,
      user_name,
      contrato,
      tipo_de_despesa,
      valor_despesa,
      data_consumo,
      quantidade,
      justificativa
    } = req.body || {};

    // Basic required validation
    if (!user_id || !user_name || !contrato || !tipo_de_despesa ||
      valor_despesa === undefined || valor_despesa === null ||
      !data_consumo || quantidade === undefined || quantidade === null ||
      !justificativa) {
      return res.status(400).json({ error: 'Campos obrigatórios faltando!' });
    }

    // Numbers (accept "123,45" or "123.45")
    const valorNum = Number(
      typeof valor_despesa === 'string'
        ? valor_despesa.replace(',', '.')
        : valor_despesa
    );
    const qtdNum = Number.parseInt(String(quantidade), 10);
    if (Number.isNaN(valorNum) || Number.isNaN(qtdNum)) {
      return res.status(400).json({ error: 'Valor/Quantidade inválidos' });
    }

    // Date -> YYYY-MM-DD
    let dateOnly;
    if (/^\d{4}-\d{2}-\d{2}$/.test(data_consumo)) {
      dateOnly = data_consumo;
    } else {
      const d = new Date(data_consumo);
      if (Number.isNaN(d.getTime())) {
        return res.status(400).json({ error: 'data_consumo inválida' });
      }
      const yyyy = d.getUTCFullYear();
      const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
      const dd = String(d.getUTCDate()).padStart(2, '0');
      dateOnly = `${yyyy}-${mm}-${dd}`;
    }

    let isInternal = 'nao';
    if (['Lavagem de Veículo', 'Estacionamento', 'EPI', 'Material de Escritório', 'Material de Escritorio'].includes(tipo_de_despesa)) {
      isInternal = 'sim';
    }

    // IMPORTANT: columns count == values count (11)
    const sql = `
      INSERT INTO despesas
        (user_id, user_name, contrato, tipo_de_despesa, valor_despesa,
         data_consumo, quantidade, justificativa, aprovacao, created_at, internal)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `;

    const params = [
      user_id,
      user_name,
      contrato,
      tipo_de_despesa,
      valorNum,
      dateOnly,
      qtdNum,
      justificativa,
      'Aguardando Aprovação', // default status
      new Date(Date.now() - 3 * 60 * 60 * 1000).toISOString().slice(0, 19).replace('T', ' '),
      isInternal
    ];

    // Use the same helper you use elsewhere
    const result = await execOnceWithRetry(sql, params);

    return res.status(201).json({ success: true, id: result.insertId });
  } catch (e) {
    console.error('POST /despesas exception:', e);
    return res.status(500).json({ error: e.message || 'Erro interno' });
  }
});
//get despesas
app.get('/despesas', async (req, res) => {
  const userId = Number(req.query.user_id);
  const from = req.query.from; // optional YYYY-MM-DD
  const to = req.query.to;     // optional YYYY-MM-DD

  if (!userId) {
    return res.status(400).json({ error: 'user_id is required' });
  }

  let sql = `
    SELECT despesa_id, user_id, user_name, contrato, tipo_de_despesa,
           valor_despesa, data_consumo, quantidade, justificativa, aprovacao, aprovacao_motivo, glpi_subtask_id, photo_docid, photo_url
    FROM despesas
    WHERE user_id = ?
  `;
  const params = [userId];

  if (from) {
    sql += ` AND data_consumo >= ?`;
    params.push(from);
  }

  if (to) {
    sql += ` AND data_consumo <= ?`;
    params.push(to);
  }

  sql += ` ORDER BY data_consumo DESC, despesa_id DESC`;

  try {
    const rows = await queryWithRetry(enterprisePool, sql, params);
    res.json(rows);
  } catch (err) {
    console.error('GET /despesas error:', err);
    res.status(500).json({ error: err.message });
  }
});
app.post('/despesas/:id/internal', async (req, res) => {
  const id = req.params.id;
  const { internal } = req.body; // 'sim' ou 'nao'

  if (internal !== 'sim' && internal !== 'nao') {
    return res.status(400).json({ error: "Campo 'internal' deve ser 'sim' ou 'nao'." });
  }

  try {
    const [result] = await enterprisePool.query(
      'UPDATE despesas SET internal = ? WHERE despesa_id = ?',
      [internal, id]
    );

    if (result.affectedRows === 0) {
      return res.status(404).json({ error: 'Despesa não encontrada' });
    }

    res.json({ updated: result.affectedRows });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'Erro ao atualizar flag internal' });
  }
});
// ADMIN list for approval
app.get('/despesas/admin', async (req, res) => {
  try {
    const tipo = req.query.tipo ? String(req.query.tipo) : null; // 'Refeição' | 'Hospedagem'
    const userId = req.query.user_id ? Number(req.query.user_id) : null;
    const status = req.query.status ? String(req.query.status) : null; // 'Aguardando Aprovação' | 'Aprovado' | 'Reprovado'
    const from = req.query.from || null; // YYYY-MM-DD
    const to = req.query.to || null; // YYYY-MM-DD
    const limit = Math.min(Number(req.query.limit || 50), 200);
    const offset = Math.max(Number(req.query.offset || 0), 0);

    const params = [];
    let sql = `
      SELECT
        despesa_id,
        user_id,
        user_name,
        contrato,
        tipo_de_despesa,
        valor_despesa,
        data_consumo,
        quantidade,
        justificativa,
        aprovacao,
        aprovado_por,
        aprovado_em,
        aprovacao_motivo,
        glpi_subtask_id,
        photo_docid,
        photo_url,
        internal,
        prestacao_realizada 
      FROM despesas
      WHERE 1=1
    `;

    // Add status filter if provided, otherwise show all
    if (status) {
      sql += ` AND aprovacao = ?`;
      params.push(status);
    }

    if (tipo) {
      sql += ` AND tipo_de_despesa = ?`;
      params.push(tipo);
    }
    if (userId) {
      sql += ` AND user_id = ?`;
      params.push(userId);
    }
    if (from) {
      sql += ` AND data_consumo >= ?`;
      params.push(from);
    }
    if (to) {
      sql += ` AND data_consumo <= ?`;
      params.push(to);
    }

    sql += ` ORDER BY data_consumo DESC, despesa_id DESC LIMIT ? OFFSET ?`;
    params.push(limit, offset);

    const rows = await queryWithRetry(enterprisePool, sql, params);
    res.json(rows);
  } catch (err) {
    console.error('GET /despesas/admin error:', err);
    res.status(500).json({ error: err.message });
  }
});
app.put('/despesas/:id/prestacao-realizada', async (req, res) => {
  try {
    const despesaId = Number(req.params.id);
    if (!despesaId) {
      return res.status(400).json({ error: 'Invalid id' });
    }

    const { prestacao_realizada } = req.body || {};

    // Aceita explicitamente apenas 'SIM' ou 'NÃO'
    if (!['SIM', 'NÃO'].includes(prestacao_realizada)) {
      return res.status(400).json({
        error: "prestacao_realizada deve ser 'SIM' ou 'NÃO'",
      });
    }

    const sql = `
      UPDATE despesas
      SET prestacao_realizada = ?
      WHERE despesa_id = ?
    `;
    const params = [prestacao_realizada, despesaId];

    const result = await execOnceWithRetry(sql, params);

    if (!result || !result.affectedRows) {
      return res.status(404).json({ error: 'Despesa não encontrada' });
    }

    // Retorna o registro atualizado (se quiser manter padrão semelhante ao /aprovacao)
    const [row] = await queryWithRetry(
      enterprisePool,
      `SELECT despesa_id, user_id, user_name, contrato, tipo_de_despesa,
              valor_despesa, data_consumo, quantidade, justificativa, aprovacao,
              aprovado_por, aprovado_em, aprovacao_motivo,
              glpi_subtask_id, photo_docid, photo_url,
              prestacao_realizada
       FROM despesas
       WHERE despesa_id = ?`,
      [despesaId]
    );

    return res.json({ success: true, data: row });
  } catch (err) {
    console.error('PUT /despesas/:id/prestacao-realizada error:', err);
    res.status(500).json({ error: err.message });
  }
});

app.put('/despesas/:id/aprovacao', async (req, res) => {
  try {
    const despesaId = Number(req.params.id);
    if (!despesaId) return res.status(400).json({ error: 'Invalid id' });

    const { aprovacao, aprovado_por, aprovacao_motivo } = req.body || {};
    if (!['Aprovado', 'Reprovado'].includes(aprovacao)) {
      return res.status(400).json({ error: 'aprovacao must be Aprovado|Reprovado' });
    }
    if (!aprovado_por || !String(aprovado_por).trim()) {
      return res.status(400).json({ error: 'aprovado_por é obrigatório' });
    }

    const sets = [
      'aprovacao = ?',
      'aprovado_por = ?',
      'aprovado_em = NOW()'
    ];
    const params = [aprovacao, String(aprovado_por).trim()];

    if (aprovacao_motivo !== undefined) {
      sets.push('aprovacao_motivo = ?');
      params.push(String(aprovacao_motivo));
    }

    const sql = `UPDATE despesas SET ${sets.join(', ')} WHERE despesa_id = ?`;
    params.push(despesaId);

    await execOnceWithRetry(sql, params);

    const [row] = await queryWithRetry(
      enterprisePool,
      `SELECT despesa_id, user_id, user_name, contrato, tipo_de_despesa,
              valor_despesa, data_consumo, quantidade, justificativa, aprovacao,
              aprovado_por, aprovado_em, aprovacao_motivo,
              glpi_subtask_id, photo_docid, photo_url
       FROM despesas WHERE despesa_id = ?`,
      [despesaId]
    );
    res.json({ success: true, data: row });
  } catch (err) {
    console.error('PUT /despesas/:id/aprovacao error:', err);
    res.status(500).json({ error: err.message });
  }
});
app.put('/despesas/aprovacao-bulk', async (req, res) => {
  try {
    const { ids, aprovacao, aprovado_por, aprovacao_motivo } = req.body || {};
    if (!Array.isArray(ids) || ids.length === 0) {
      return res.status(400).json({ error: 'ids array required' });
    }
    if (!['Aprovado', 'Reprovado'].includes(aprovacao)) {
      return res.status(400).json({ error: 'aprovacao must be Aprovado|Reprovado' });
    }
    if (!aprovado_por || !String(aprovado_por).trim()) {
      return res.status(400).json({ error: 'aprovado_por é obrigatório' });
    }

    // Build IN list safely
    const placeholders = ids.map(() => '?').join(',');
    const params = [aprovacao, String(aprovado_por).trim()];
    let sql = `
      UPDATE despesas
      SET aprovacao = ?,
          aprovado_por = ?,
          aprovado_em = NOW()
    `;

    if (aprovacao_motivo !== undefined) {
      sql += `, aprovacao_motivo = ?`;
      params.push(String(aprovacao_motivo));
    }

    sql += ` WHERE despesa_id IN (${placeholders}) AND aprovacao = 'Aguardando Aprovação'`;
    params.push(...ids);

    const result = await execOnceWithRetry(sql, params);
    res.json({ success: true, affectedRows: result.affectedRows });
  } catch (err) {
    console.error('PUT /despesas/aprovacao-bulk error:', err);
    res.status(500).json({ error: err.message });
  }
});
// UPDATE despesa (editable fields only)
// Rules:
// - User can edit only when aprovacao != 'Aprovado'
// - If current aprovacao === 'Reprovado' and any edit happens => set to 'Aguardando Aprovação'
app.put('/despesas/:id', async (req, res) => {
  try {
    const despesaId = Number(req.params.id);
    if (!despesaId) {
      return res.status(400).json({ error: 'Invalid despesa id' });
    }

    // Get current row to know approval status
    const [current] = await queryWithRetry(
      enterprisePool,
      'SELECT aprovacao FROM despesas WHERE despesa_id = ?',
      [despesaId]
    );

    if (!current) {
      return res.status(404).json({ error: 'Despesa não encontrada' });
    }

    const currentAprov = current.aprovacao;

    if (currentAprov === 'Aprovado') {
      return res.status(403).json({ error: 'Registro aprovado não pode ser editado.' });
    }

    // Allowed fields
    const {
      tipo_de_despesa,
      valor_despesa,
      data_consumo,
      quantidade,
      justificativa
    } = req.body || {};

    const sets = [];
    const params = [];

    // Validate & normalize only the provided fields
    if (tipo_de_despesa !== undefined) {
      sets.push('tipo_de_despesa = ?');
      params.push(String(tipo_de_despesa));
    }
    if (valor_despesa !== undefined) {
      const valorNum = Number(
        typeof valor_despesa === 'string' ? valor_despesa.replace(',', '.') : valor_despesa
      );
      if (Number.isNaN(valorNum)) {
        return res.status(400).json({ error: 'valor_despesa inválido' });
      }
      sets.push('valor_despesa = ?');
      params.push(valorNum);
    }
    if (data_consumo !== undefined) {
      let dateOnly;
      if (/^\d{4}-\d{2}-\d{2}$/.test(data_consumo)) {
        dateOnly = data_consumo;
      } else {
        const d = new Date(data_consumo);
        if (Number.isNaN(d.getTime())) {
          return res.status(400).json({ error: 'data_consumo inválida' });
        }
        const yyyy = d.getUTCFullYear();
        const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
        const dd = String(d.getUTCDate()).padStart(2, '0');
        dateOnly = `${yyyy}-${mm}-${dd}`;
      }
      sets.push('data_consumo = ?');
      params.push(dateOnly);
    }
    if (quantidade !== undefined) {
      const qtdNum = Number.parseInt(String(quantidade), 10);
      if (Number.isNaN(qtdNum)) {
        return res.status(400).json({ error: 'quantidade inválida' });
      }
      sets.push('quantidade = ?');
      params.push(qtdNum);
    }
    if (justificativa !== undefined) {
      sets.push('justificativa = ?');
      params.push(String(justificativa));
    }

    if (sets.length === 0) {
      return res.status(400).json({ error: 'Nenhum campo para atualizar' });
    }

    // If it was Reprovado and user edited, move to Aguardando Aprovação
    if (currentAprov === 'Reprovado') {
      sets.push('aprovacao = ?');
      params.push('Aguardando Aprovação');
    }

    const sql = `UPDATE despesas SET ${sets.join(', ')} WHERE despesa_id = ?`;
    params.push(despesaId);

    await execOnceWithRetry(sql, params);

    // Return updated row
    const [row] = await queryWithRetry(
      enterprisePool,
      `SELECT despesa_id, user_id, user_name, contrato, tipo_de_despesa,
              valor_despesa, data_consumo, quantidade, justificativa, aprovacao,
              glpi_subtask_id, photo_docid, photo_url
       FROM despesas WHERE despesa_id = ?`,
      [despesaId]
    );

    return res.json({ success: true, data: row });
  } catch (e) {
    console.error('PUT /despesas/:id exception:', e);
    return res.status(500).json({ error: e.message || 'Erro interno' });
  }
});
// GET /glpi/users -> only ENTERPRISE workers (have cdigocargofield filled)
app.get('/glpi/users', async (req, res) => {
  try {
    const rows = await queryWithRetry(
      glpiPool,
      `
      SELECT DISTINCT u.id, u.name
      FROM glpi_users AS u
      INNER JOIN glpi_plugin_fields_usercdcargos AS c
              ON c.items_id = u.id
      WHERE c.cdigocargofield IS NOT NULL
        AND TRIM(c.cdigocargofield) <> ''
        AND u.id != 340
      ORDER BY u.name ASC
      `
    );
    res.json(rows.map(u => ({ id: u.id, name: u.name })));
  } catch (err) {
    console.error('GET /glpi/users error:', err);
    res.status(500).json({ error: err.message });
  }
});

// GET /glpi/users/:id/activities
// GET /glpi/users/:id/activities
app.get('/glpi/users/:id/activities', async (req, res) => {
  const userId = Number(req.params.id);
  if (!userId) return res.status(400).json({ error: 'Invalid user id' });

  if (!Number.isFinite(PROJECT_ID) || PROJECT_ID <= 0) {
    console.error('CONFIG ERROR: PROJECT_ID is not set or invalid in .env');
    return res.status(500).json({ error: 'Server misconfiguration: PROJECT_ID not set' });
  }

  // Add project state info
  const sql = `
    SELECT DISTINCT
      pt.id   AS task_id,
      pt.name AS task_name,
      pt.projectstates_id AS state_id,
      gps.name AS state_name
    FROM glpi_projecttaskteams AS ptt
    INNER JOIN glpi_projecttasks AS pt
      ON pt.id = ptt.projecttasks_id
    LEFT JOIN glpi_projectstates AS gps
      ON gps.id = pt.projectstates_id
    WHERE ptt.items_id = ?
      AND pt.projects_id = ?
      AND (pt.projectstates_id IS NULL OR pt.projectstates_id NOT IN (3, 7, 6))
    ORDER BY pt.name ASC
  `;

  try {
    const tasks = await queryWithRetry(glpiPool, sql, [userId, PROJECT_ID]);
    if (!tasks || tasks.length === 0) return res.json([]);

    console.log(`Found ${tasks.length} GLPI tasks for user ${userId}`);

    // Get the task IDs from GLPI
    const taskIds = tasks.map(t => t.task_id).filter(Boolean);
    console.log('GLPI task IDs:', taskIds);

    // APPROACH 1: Try with direct SQL string (bypass parameter binding)
    const directSql = `
      SELECT task_id, data_conclusao, item
      FROM formas_enviadas
      WHERE task_id IN (${taskIds.join(',')})
    `;

    console.log('Direct SQL approach:', directSql);
    let rows = [];
    try {
      rows = await queryWithRetry(enterprisePool, directSql);
      console.log(`Direct SQL found ${rows.length} records`);
    } catch (directError) {
      console.log('Direct SQL failed:', directError.message);
    }

    // APPROACH 2: If direct SQL works but parameter binding doesn't, try individual queries
    if (rows.length === 0) {
      console.log('Trying individual queries...');
      const individualRows = [];

      for (const taskId of taskIds) {
        try {
          const result = await queryWithRetry(enterprisePool,
            'SELECT task_id, data_conclusao, item FROM formas_enviadas WHERE task_id = ?',
            [taskId]
          );
          if (result && result.length > 0) {
            individualRows.push(...result);
          }
        } catch (indError) {
        }
      }

      rows = individualRows;

    }

    // APPROACH 3: Try with explicit number conversion
    if (rows.length === 0) {
      console.log('Trying with explicit number conversion...');
      const numberTaskIds = taskIds.map(id => Number(id));
      rows = await queryWithRetry(enterprisePool,
        'SELECT task_id, data_conclusao, item FROM formas_enviadas WHERE task_id IN (?)',
        [numberTaskIds]
      );
    }



    // Create a map of task_id -> {data_conclusao, item}
    const byTaskId = new Map((rows || []).map(r => [Number(r.task_id), { data_conclusao: r.data_conclusao, item: r.item }]));

    // Merge the data
    const merged = tasks.map(t => {
      const taskIdNum = Number(t.task_id);
      const formData = byTaskId.get(taskIdNum);


      return {
        task_id: t.task_id,
        task_name: t.task_name,
        state_id: t.state_id,
        state_name: t.state_name,
        data_conclusao: formData?.data_conclusao
          ? new Date(formData.data_conclusao).toISOString()
          : null,
        item: formData?.item || null  // Add ITEM field for search
      };
    });

    res.json(merged);
  } catch (err) {
    console.error('GET /glpi/users/:id/activities error:', err);
    res.status(500).json({ error: err.message });
  }
});
// PANEL USUARIO - > GET /user/tasks/:userId - Get all tasks for a specific user with full details 
app.get('/user/tasks/:userId', async (req, res) => {
  const userId = Number(req.params.userId);
  if (!Number.isFinite(userId) || userId <= 0) {
    return res.status(400).json({ error: 'user id inválido' });
  }

  if (!Number.isFinite(PROJECT_ID) || PROJECT_ID <= 0) {
    return res.status(500).json({ error: 'Server misconfiguration: PROJECT_ID not set' });
  }

  const sql = `
    SELECT DISTINCT
      pt.id,
      pt.name,
      pt.content,
      pt.real_start_date,
      pt.real_end_date,
      pt.plan_start_date,
      pt.plan_end_date,
      pt.date_creation,
      pt.date_mod,
      pt.projects_id,
      pt.projectstates_id,
      st.name AS status_name,
      u_owner.name AS creator_name,

      (SELECT u2.name
         FROM glpi_projecttaskteams ptt2
         JOIN glpi_users u2 ON u2.id = ptt2.items_id
        WHERE ptt2.projecttasks_id = pt.id
          AND ptt2.itemtype = 'User'
        ORDER BY ptt2.id ASC
        LIMIT 1) AS primary_assignee_name

    FROM glpi_projecttaskteams AS ptt
    INNER JOIN glpi_projecttasks AS pt ON pt.id = ptt.projecttasks_id
    LEFT JOIN glpi_users u_owner ON u_owner.id = pt.users_id
    LEFT JOIN glpi_projectstates st ON st.id = pt.projectstates_id
    WHERE ptt.items_id = ?
      AND pt.projects_id = ?
    ORDER BY COALESCE(pt.real_end_date, pt.plan_end_date, pt.date_mod, pt.date_creation) DESC
  `;

  try {
    const tasks = await queryWithRetry(glpiPool, sql, [userId, PROJECT_ID]);
    if (!tasks || tasks.length === 0) return res.json([]);

    const taskIds = tasks.map(t => t.id).filter(Boolean);

    const latestFE = new Map();
    if (taskIds.length > 0) {
      const chunkSize = 1000;
      for (let i = 0; i < taskIds.length; i += chunkSize) {
        const chunk = taskIds.slice(i, i + chunkSize);
        const placeholders = chunk.map(() => '?').join(',');
        const formsSql = `
          SELECT
            fe.task_id,
            fe.lider,
            fe.enviado_em,
            fe.data_conclusao,
            fe.status,
            fe.item,
            fe.comentario,
            fe.quantidade_tarefas,
            fe.data_start_real,
            fe.user_conclude_date,
            fe.data_start_pendente,             -- NEW
            fe.data_end_pendente,               -- NEW
            fe.modo_de_trabalho,
            us.tipo_de_evidencia
          FROM formas_enviadas fe
          LEFT JOIN Tab_6_Tabela_de_servicos_US us
            ON REPLACE(TRIM(us.ITEM), ' ', '') = REPLACE(TRIM(fe.item), ' ', '')
          WHERE fe.task_id IN (${placeholders})
          ORDER BY fe.task_id ASC, fe.id DESC
        `;
        const [forms] = await enterprisePool.query(formsSql, chunk);
        for (const f of forms) {
          if (!latestFE.has(f.task_id)) {
            latestFE.set(f.task_id, {
              lider: f.lider || null,
              enviado_em: f.enviado_em || null,
              data_conclusao: f.data_conclusao || null,
              status: f.status || null,
              item: f.item || null,
              comentario: f.comentario || null,
              quantidade_tarefas: f.quantidade_tarefas || 1,
              data_start_real: f.data_start_real || null,
              user_conclude_date: f.user_conclude_date || null,
              data_start_pendente: f.data_start_pendente || null, // NEW
              data_end_pendente: f.data_end_pendente || null,     // NEW
              modo_de_trabalho: f.modo_de_trabalho || null,
              tipo_de_evidencia: f.tipo_de_evidencia || null,
            });
          }
        }
      }
    }

    // docs (unchanged)
    const tasksWithDocs = new Map();
    const docsChunkSize = 100;
    for (let i = 0; i < taskIds.length; i += docsChunkSize) {
      const chunk = taskIds.slice(i, i + docsChunkSize);
      const placeholders = chunk.map(() => '?').join(',');
      const docsSql = `
        SELECT d.id AS docid, d.name AS doc_name, d.filename, d.mime, d.date_mod, di.items_id
        FROM glpi_documents d
        JOIN glpi_documents_items di ON di.documents_id = d.id
        WHERE di.itemtype = 'ProjectTask' AND di.items_id IN (${placeholders})
        ORDER BY COALESCE(d.date_mod, d.date_creation) DESC
      `;
      const docRows = await queryWithRetry(glpiPool, docsSql, chunk);
      for (const doc of docRows) {
        if (!tasksWithDocs.has(doc.items_id)) tasksWithDocs.set(doc.items_id, []);
        tasksWithDocs.get(doc.items_id).push({
          docid: doc.docid,
          name: doc.doc_name,
          filename: doc.filename,
          mime: doc.mime,
          url: `${process.env.GLPI_FRONT_URL}/front/document.send.php?docid=${doc.docid}`,
          download_url: `/aprovacao/document/${doc.docid}`
        });
      }
    }

    const result = tasks.map(task => {
      const fe = latestFE.get(task.id) || {};
      const documents = tasksWithDocs.get(task.id) || [];
      return {
        id: task.id,
        name: task.name,
        content: task.content,
        plan_start_date: task.plan_start_date,
        plan_end_date: task.plan_end_date,
        real_start_date: task.real_start_date,
        real_end_date: task.real_end_date,
        date_creation: task.date_creation,
        date_mod: task.date_mod,
        projects_id: task.projects_id,
        projectstates_id: task.projectstates_id,
        status_name: task.status_name,
        creator_name: task.creator_name,
        criador_display: task.primary_assignee_name || null,

        // formas_enviadas
        lider: fe.lider || null,
        enviado_em: fe.enviado_em || null,
        data_conclusao: fe.data_conclusao || null,
        status_forma: fe.status || null,
        item: fe.item || null,
        comentario: fe.comentario || null,
        quantidade_tarefas: fe.quantidade_tarefas || 1,
        data_start_real: fe.data_start_real || null,
        user_conclude_date: fe.user_conclude_date || null,
        data_start_pendente: fe.data_start_pendente || null, // NEW
        data_end_pendente: fe.data_end_pendente || null,     // NEW
        modo_de_trabalho: fe.modo_de_trabalho || null,
        tipo_de_evidencia: fe.tipo_de_evidencia || null,

        documents,
        is_editable: task.projectstates_id !== 3
      };
    });

    res.json(result);
  } catch (e) {
    console.error('[User Panel] tasks ERR:', e.message);
    res.status(500).json({ error: e.message });
  }
});

//PANEL USUARIO update
// PUT /user/tasks/:taskId - Update user task + recalc ativo_acumulado_seg
app.put('/user/tasks/:taskId', async (req, res) => {
  const taskId = Number(req.params.taskId);
  const {
    name,
    content,
    real_start_date,     // "YYYY-MM-DD HH:mm:ss" or ISO
    real_end_date,       // "
    comentario,
    quantidade_tarefas,
    projectstates_id,
    data_start_pendente, // "
    data_end_pendente,    // "
    modo_de_trabalho,
    is_admin
  } = req.body || {};

  if (!Number.isFinite(taskId) || taskId <= 0) {
    return res.status(400).json({ error: 'task id inválido' });
  }

  try {
    // 0) Guard + ALSO fetch GLPI's real_start/end for fallback  ⬅️ CHANGED
    const [currentTask] = await queryWithRetry(
      glpiPool,
      'SELECT projectstates_id, real_start_date, real_end_date FROM glpi_projecttasks WHERE id = ?',
      [taskId]
    );

    console.log(`[UPDATE TASK ${taskId}] is_admin received:`, is_admin, typeof is_admin);

    if (!currentTask) return res.status(404).json({ error: 'Task não encontrada' });
    if (Number(currentTask.projectstates_id) === 3 && is_admin !== true && is_admin !== 'true') {
      return res.status(403).json({ error: 'Task fechada não pode ser editada' });
    }

    // ---- helpers ----
    const toMy = (d) => toMySQLDateTime(d);
    const parseMillis = (s) => {
      if (!s) return null;
      const str = String(s).trim();
      if (!str) return null;
      const iso = str.includes('T') ? str : str.replace(' ', 'T');
      const ms = Date.parse(iso);
      return Number.isFinite(ms) ? ms : null;
    };
    const diffSeconds = (aMs, bMs) => {
      if (aMs == null || bMs == null) return 0;
      return Math.max(0, Math.floor((bMs - aMs) / 1000));
    };

    let sessionToken;
    try {
      sessionToken = await glpiInitSession();

      // 1) Update GLPI (only provided fields)
      const glpiFields = {};
      if (name != null) glpiFields.name = name;
      if (content != null) glpiFields.content = content;
      if (real_start_date != null) glpiFields.real_start_date = toMy(real_start_date);
      if (real_end_date != null) glpiFields.real_end_date = toMy(real_end_date);
      if (projectstates_id != null) glpiFields.projectstates_id = Number(projectstates_id);
      if (Object.keys(glpiFields).length > 0) {
        await glpiUpdateProjectTask(sessionToken, taskId, glpiFields);
      }

      // 2) Load latest FE row
      const [feRows] = await enterprisePool.execute(
        `
          SELECT id, data_start_real, user_conclude_date,
                 data_start_pendente, data_end_pendente,
                 ativo_acumulado_seg
          FROM formas_enviadas
          WHERE task_id = ?
          ORDER BY id DESC
          LIMIT 1
        `,
        [taskId]
      );
      const fe = feRows?.[0] || null;

      // 3) Effective values (BODY -> FE -> GLPI)  ⬅️ CHANGED (adds GLPI fallback)
      const effStart = (real_start_date != null)
        ? toMy(real_start_date)
        : (fe?.data_start_real || currentTask.real_start_date || null);

      const effEnd = (real_end_date != null)
        ? toMy(real_end_date)
        : (fe?.user_conclude_date || currentTask.real_end_date || null);

      const effPendS = (data_start_pendente != null)
        ? toMy(data_start_pendente)
        : (fe?.data_start_pendente || null);

      const effPendE = (data_end_pendente != null)
        ? toMy(data_end_pendente)
        : (fe?.data_end_pendente || null);

      // 4) Build FE update set
      const feUpdates = [];
      const feParams = [];

      if (comentario !== undefined) {
        feUpdates.push('comentario = ?'); feParams.push(comentario);
      }
      if (quantidade_tarefas !== undefined) {
        feUpdates.push('quantidade_tarefas = ?'); feParams.push(Number(quantidade_tarefas));
      }
      if (real_start_date !== undefined || (fe && effStart !== fe.data_start_real)) {
        feUpdates.push('data_start_real = ?'); feParams.push(effStart);
      }
      if (real_end_date !== undefined || (fe && effEnd !== fe.user_conclude_date)) {
        feUpdates.push('user_conclude_date = ?'); feParams.push(effEnd);
      }
      if (data_start_pendente !== undefined || (fe && effPendS !== fe.data_start_pendente)) {
        feUpdates.push('data_start_pendente = ?'); feParams.push(effPendS);
      }
      if (data_end_pendente !== undefined || (fe && effPendE !== fe.data_end_pendente)) {
        feUpdates.push('data_end_pendente = ?'); feParams.push(effPendE);
      }
      if (modo_de_trabalho !== undefined) {
        feUpdates.push('modo_de_trabalho = ?'); feParams.push(modo_de_trabalho);
      }

      // 5) Recalculate like /preaprovados/create-task  ⬅️ CHANGED (logic ported)
      // Compute only when we have BOTH start & end (independent of status)
      const sMs = parseMillis(effStart);
      const eMs = parseMillis(effEnd);
      if (sMs != null && eMs != null && eMs >= sMs) {
        const total = diffSeconds(sMs, eMs);
        let pend = 0;

        const psMs = parseMillis(effPendS);
        const peMs = parseMillis(effPendE);
        if (psMs != null && peMs != null && peMs > psMs) {
          const intStart = Math.max(sMs, psMs);
          const intEnd = Math.min(eMs, peMs);
          if (intEnd > intStart) {
            pend = diffSeconds(intStart, intEnd);
          }
        }

        const ativoSeg = Math.max(0, total - pend);
        feUpdates.push('ativo_acumulado_seg = ?');
        feParams.push(ativoSeg);
      }

      // 6) Persist FE (if anything changed)
      if (feUpdates.length > 0) {
        const feSql = `
          UPDATE formas_enviadas
             SET ${feUpdates.join(', ')}
           WHERE task_id = ?
           ORDER BY id DESC
           LIMIT 1
        `;
        feParams.push(taskId);
        await enterprisePool.execute(feSql, feParams);
      }

      // 7) Optional: log status change
      if (projectstates_id != null) {
        await appendStatusLog(taskId, projectstates_id, null, enterprisePool);
      }

      res.json({ success: true, message: 'Task atualizada com sucesso' });
    } finally {
      if (sessionToken) await glpiKillSession(sessionToken);
    }
  } catch (e) {
    console.error('[User Panel] update task ERR:', e.message || e);
    res.status(500).json({ error: e.message || String(e) });
  }
});
// PUT /user/tasks/:taskId/atividade - Update atividade name + item in formas_enviadas and GLPI
app.put('/user/tasks/:taskId/atividade', async (req, res) => {
  const taskId = Number(req.params.taskId);
  const { tarefa, user_id, is_admin } = req.body || {};

  const tarefaText = (tarefa ?? '').toString().trim();
  const userIdNum = Number(user_id);

  if (!Number.isFinite(taskId) || taskId <= 0) {
    return res.status(400).json({ error: 'task id inválido' });
  }
  if (!tarefaText) {
    return res.status(400).json({ error: 'tarefa é obrigatória' });
  }
  if (!Number.isFinite(userIdNum) || userIdNum <= 0) {
    return res.status(400).json({ error: 'user_id é obrigatório' });
  }

  try {
    // Check not closed
    const [currentTask] = await queryWithRetry(
      glpiPool,
      'SELECT projectstates_id FROM glpi_projecttasks WHERE id = ?',
      [taskId]
    );
    console.log(`[UPDATE ATIVIDADE TASK ${taskId}] is_admin received:`, is_admin, typeof is_admin);
    if (!currentTask) return res.status(404).json({ error: 'Task não encontrada' });
    if (currentTask.projectstates_id === 3 && is_admin !== true && is_admin !== 'true') {
      return res.status(403).json({ error: 'Task fechada não pode ser editada' });
    }

    // Resolve cargo
    let cargo = null;
    try {
      const cargoRows = await queryWithRetry(
        glpiPool,
        `
          SELECT TRIM(cdigocargofield) AS cargo
          FROM glpi_plugin_fields_usercdcargos
          WHERE items_id = ?
            AND cdigocargofield IS NOT NULL
            AND TRIM(cdigocargofield) <> ''
          LIMIT 1
        `,
        [userIdNum]
      );
      cargo = (cargoRows?.[0]?.cargo || null);
    } catch (e) {
      console.warn('[PUT /user/tasks/:taskId/atividade] cargo lookup failed:', e?.message);
    }

    // Resolve ITEM from tabela US
    let itemValue = null;
    if (cargo) {
      const [rowsByCargo] = await enterprisePool.execute(
        `
          SELECT ITEM
          FROM Tab_6_Tabela_de_servicos_US
          WHERE ATIVIDADE = ?
            AND TRIM(SUBITEM_NUM) = ?
          ORDER BY ITEM
          LIMIT 1
        `,
        [tarefaText, cargo]
      );
      if (rowsByCargo && rowsByCargo.length) {
        itemValue = String(rowsByCargo[0].ITEM ?? '').trim() || null;
      }
    }
    if (!itemValue) {
      const [rowsAny] = await enterprisePool.execute(
        `SELECT ITEM FROM Tab_6_Tabela_de_servicos_US WHERE ATIVIDADE = ? ORDER BY ITEM LIMIT 1`,
        [tarefaText]
      );
      if (rowsAny && rowsAny.length) {
        itemValue = String(rowsAny[0].ITEM ?? '').trim() || null;
      }
    }

    let sessionToken;
    try {
      // GLPI: update name
      sessionToken = await glpiInitSession();
      await glpiUpdateProjectTask(sessionToken, taskId, { name: tarefaText });

      // formas_enviadas: update latest row
      const feSql = `
        UPDATE formas_enviadas
           SET tipo_servico = ?,
               atividade = ?,
               descricao_detalhada = ?,
               item = ?
         WHERE task_id = ?
         ORDER BY id DESC
         LIMIT 1
      `;
      await enterprisePool.execute(feSql, [
        tarefaText,          // tipo_servico
        tarefaText,          // atividade
        tarefaText,          // descricao_detalhada
        itemValue,           // item (may be null if not found)
        taskId
      ]);

      return res.json({
        success: true,
        tarefa: tarefaText,
        item: itemValue
      });
    } finally {
      if (sessionToken) await glpiKillSession(sessionToken);
    }
  } catch (err) {
    const detail = err?.response?.data ?? err?.message ?? String(err);
    console.error('[PUT /user/tasks/:taskId/atividade] error:', detail);
    return res.status(500).json({ error: 'Falha ao atualizar atividade/item', detail });
  }
});
// GET /user/time-overlap?user_id=123&start=ISO&end=ISO
// Returns { conflicts: [...], inProgress: [...] } for overlap/warning detection.
// Conflicts: tasks whose [data_start_real, user_conclude_date) overlaps [start, end).
// InProgress: tasks with data_start_real but no user_conclude_date on the same day.
// Overlap is STRICT: if A ends at 10:00 and B starts at 10:00 → no conflict.
app.get('/user/time-overlap', async (req, res) => {
  const userId = Number(req.query.user_id);
  const startRaw = req.query.start;
  const endRaw = req.query.end;

  if (!userId || !Number.isFinite(userId) || userId <= 0) {
    return res.status(400).json({ error: 'user_id is required and must be a positive integer' });
  }
  if (!startRaw) {
    return res.status(400).json({ error: 'start is required' });
  }

  const startMs = new Date(startRaw).getTime();
  if (!Number.isFinite(startMs)) {
    return res.status(400).json({ error: 'Invalid start date' });
  }
  const endMs = endRaw ? new Date(endRaw).getTime() : null;
  if (endRaw && !Number.isFinite(endMs)) {
    return res.status(400).json({ error: 'Invalid end date' });
  }

  try {
    // Fetch all tasks for this user on the same calendar day as `start`
    const [rows] = await enterprisePool.execute(
      `SELECT task_id, atividade, data_start_real, user_conclude_date
         FROM formas_enviadas
        WHERE user_id = ?
          AND DATE(data_start_real) = DATE(?)
          AND data_start_real IS NOT NULL
        ORDER BY data_start_real ASC`,
      [userId, startRaw]
    );

    const conflicts = [];
    const inProgress = [];

    for (const row of rows) {
      const existStart = new Date(row.data_start_real).getTime();
      const existEnd = row.user_conclude_date
        ? new Date(row.user_conclude_date).getTime()
        : null;

      const info = {
        task_id: row.task_id,
        atividade: row.atividade,
        data_start_real: row.data_start_real,
        user_conclude_date: row.user_conclude_date,
      };

      if (existEnd === null) {
        // Task still open (no end date) — non-blocking warning
        inProgress.push(info);
        continue;
      }

      // Strict overlap: existing [existStart, existEnd) ∩ new [startMs, endMs)
      // If endMs not provided yet, flag anything whose window contains startMs
      const overlaps = endMs !== null
        ? (existStart < endMs && existEnd > startMs)
        : (existEnd > startMs);

      if (overlaps) conflicts.push(info);
    }

    res.json({ conflicts, inProgress });
  } catch (err) {
    console.error('[GET /user/time-overlap] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// Returns the first/original leader comment for a GLPI task_id.
app.get('/formas-enviadas/by-task/:taskId', async (req, res) => {
  const taskId = Number(req.params.taskId);
  if (!Number.isFinite(taskId) || taskId <= 0) {
    return res.status(400).json({ error: 'taskId inválido' });
  }

  try {
    const [rows] = await enterprisePool.execute(
      `SELECT comentario, user_id, lider, quantidade_tarefas, item, atividade
         FROM formas_enviadas
        WHERE task_id = ?
        LIMIT 1`,
      [taskId]
    );

    if (!rows || rows.length === 0) {
      return res.status(404).json({ error: 'Nenhum comentário encontrado para este task_id' });
    }

    const row = rows[0] || {};
    const full = (row.comentario || '').toString();
    // First/original comment (before any appended updates: "\n\n---\n[ts] Atualização: ...")
    const firstComment = full.split(/\n+---\n/)[0].trim();

    // NEW: prefer 'lider' if present & non-empty; else GLPI user name
    let authorName = null;
    const liderName = (row.lider ?? '').toString().trim();
    if (liderName.length > 0) {
      authorName = liderName;
    } else if (row.user_id) {
      const [u] = await glpiPool.execute(
        'SELECT name FROM glpi_users WHERE id = ? LIMIT 1',
        [row.user_id]
      );
      authorName = (u?.[0]?.name || null);
      if (authorName) authorName = String(authorName).trim();
    }
    let tempoPrevH = null;
    let tipoEvi = null;
    let fracaoDeUs = null;
    let multiploDeUs = null;

    // prefer ITEM lookup (unique). Fallback to ATIVIDADE + user's cargo.
    if (row.item) {
      const [tt] = await enterprisePool.execute(
        `SELECT \`H.h\` AS tempo_previsto_h, tipo_de_evidencia, FRACAO_DE_US, MULTIPLO_DE_US
           FROM Tab_6_Tabela_de_servicos_US
          WHERE ITEM = ?
          LIMIT 1`,
        [row.item]
      );
      if (tt?.length) {
        const raw = tt[0].tempo_previsto_h;
        const num = Number(typeof raw === 'string' ? raw.replace(',', '.') : raw);
        tempoPrevH = Number.isFinite(num) ? num : null;
        tipoEvi = (tt[0].tipo_de_evidencia ?? null);
        if (typeof tipoEvi === 'string') tipoEvi = tipoEvi.trim();
        fracaoDeUs = (tt[0].FRACAO_DE_US ?? null);
        multiploDeUs = (tt[0].MULTIPLO_DE_US ?? null);
      }
    }

    if (tempoPrevH == null || tipoEvi == null) {
      // fallback via ATIVIDADE + cargo
      const [cg] = await glpiPool.execute(
        `SELECT TRIM(cdigocargofield) AS cargo
           FROM glpi_plugin_fields_usercdcargos
          WHERE items_id = ?
            AND cdigocargofield IS NOT NULL
            AND TRIM(cdigocargofield) <> ''
          LIMIT 1`,
        [row.user_id]
      );
      const cargo = cg?.[0]?.cargo || null;

      if (cargo && row.atividade) {
        const [tt2] = await enterprisePool.execute(
          `SELECT \`H.h\` AS tempo_previsto_h, tipo_de_evidencia, FRACAO_DE_US, MULTIPLO_DE_US
             FROM Tab_6_Tabela_de_servicos_US
            WHERE ATIVIDADE = ?
              AND TRIM(SUBITEM_NUM) = ?
            LIMIT 1`,
          [row.atividade, cargo]
        );
        if (tt2?.length) {
          const raw2 = tt2[0].tempo_previsto_h;
          const num2 = Number(typeof raw2 === 'string' ? raw2.replace(',', '.') : raw2);
          tempoPrevH = Number.isFinite(num2) ? num2 : tempoPrevH;
          let te = tt2[0].tipo_de_evidencia ?? null;
          if (typeof te === 'string') te = te.trim();
          tipoEvi = te ?? tipoEvi;
          // Also get fracao/multiplo from fallback if not already set
          if (fracaoDeUs == null) fracaoDeUs = (tt2[0].FRACAO_DE_US ?? null);
          if (multiploDeUs == null) multiploDeUs = (tt2[0].MULTIPLO_DE_US ?? null);
        }
      }
    }
    return res.json({
      task_id: taskId,
      author_name: authorName,           // e.g., "Líder" value first, else GLPI user's name
      comentario_inicial: firstComment,  // only the first/original piece
      comentario_full: full,              // optional (debug)
      quantidade_tarefas: row.quantidade_tarefas ?? null,
      tempo_previsto_h: tempoPrevH,
      tipo_de_evidencia: tipoEvi,
      fracao_de_us: fracaoDeUs,
      multiplo_de_us: multiploDeUs
    });
  } catch (e) {
    console.error('GET /formas-enviadas/by-task ERR:', e);
    return res.status(500).json({ error: 'Erro ao consultar comentário' });
  }
});

// POST /glpi/projecttasks/:id/update
app.post('/glpi/projecttasks/:id/update', async (req, res) => {
  const taskId = Number(req.params.id);
  const {
    projectstates_id,
    comment,
    real_end_date,
    real_start_date,
    user_id,
    data_start_pendente,
    data_end_pendente,
    quantidade_tarefas,
    consider_fhc,
    sobreaviso
  } = req.body || {};

  if (!taskId || !projectstates_id) {
    return res.status(400).json({ error: 'task id and projectstates_id are required' });
  }


  const realEndForDb = toMySQLDateTime(real_end_date);
  const realStartForDb = toMySQLDateTime(real_start_date);
  const pendStartDb = toMySQLDateTime(data_start_pendente);
  const pendEndDb = toMySQLDateTime(data_end_pendente);

  // Enforce real_end_date when closing
  if (Number(projectstates_id) === 7 && !realEndForDb) {
    return res.status(400).json({
      error: 'real_end_date é obrigatório quando status é Aprovação (7).'
    });
  }

  // helpers for diff / overlap
  const ms = (s) => (s ? new Date(s).getTime() : NaN);
  const diffSec = (a, b) => {
    const A = ms(a), B = ms(b);
    if (!Number.isFinite(A) || !Number.isFinite(B)) return null;
    const v = Math.floor((B - A) / 1000);
    return Number.isFinite(v) ? v : null;
  };
  const overlapSec = (a1, a2, b1, b2) => {
    const A1 = ms(a1), A2 = ms(a2), B1 = ms(b1), B2 = ms(b2);
    if (![A1, A2, B1, B2].every(Number.isFinite)) return 0;
    const start = Math.max(A1, B1);
    const end = Math.min(A2, B2);
    return end > start ? Math.floor((end - start) / 1000) : 0;
  };

  let sessionToken;
  try {
    sessionToken = await glpiInitSession();

    // --- 1) Update GLPI first ---
    const glpiFields = { projectstates_id: Number(projectstates_id) };
    if (realEndForDb) glpiFields.real_end_date = realEndForDb;
    if (realStartForDb) glpiFields.real_start_date = realStartForDb;

    if (comment?.trim()) {
      const current = await glpiGetProjectTask(sessionToken, taskId);
      const prevContent = (current?.content ?? '').toString();
      const ts = new Date().toISOString();
      glpiFields.content = `${prevContent}${prevContent ? '\n\n' : ''}---\n[${ts}] Atualização: ${comment}`;
    }

    const glpiResp = await glpiUpdateProjectTask(sessionToken, taskId, glpiFields);

    // --- 2) Load current formas_enviadas row (for stored dates) ---
    const [feRows] = await enterprisePool.execute(
      `SELECT
         comentario,
         status,
         data_start_real,
         user_conclude_date,
         data_start_pendente,
         data_end_pendente
       FROM formas_enviadas
       WHERE task_id = ?
       LIMIT 1`, [taskId]
    );
    if (!feRows || feRows.length === 0) {
      return res.status(404).json({
        success: false,
        error: `No formas_enviadas row found for task_id=${taskId}`,
        glpi_result: glpiResp
      });
    }
    const fe = feRows[0];

    // determine the "effective" times to compute on close
    const effStartReal = realStartForDb || fe.data_start_real || null;
    const effEndReal = realEndForDb || fe.user_conclude_date || null;
    const effPendStart = pendStartDb || fe.data_start_pendente || null;
    const effPendEnd = pendEndDb || fe.data_end_pendente || null;

    // --- 3) Build UPDATE for formas_enviadas (status/comment/dates) ---
    const statusText = mapGlpiStateToStatus(projectstates_id);

    const prevComentario = (fe.comentario || '').toString();
    let newComentario = prevComentario;
    if (comment?.trim()) {
      const ts = new Date().toISOString();
      newComentario = `${prevComentario}${prevComentario ? '\n\n' : ''}---\n[${ts}] Atualização: ${comment}`;
    }
    let modo = null;
    if (Number(projectstates_id) === 7 && realStartForDb && realEndForDb) {
      modo = computeModoDeTrabalho({
        startISO: realStartForDb,
        endISO: realEndForDb,
        considerFhc: Boolean(consider_fhc),
      });
    }
    const finalModo = sobreaviso === 'Sim' ? 'HC' : modo;
    const finalSobreaviso = sobreaviso === 'Sim' ? 'Sim' : 'Nao';

    let sql = `UPDATE formas_enviadas SET status = ?, comentario = ?, sobreaviso = ?`;
    const params = [statusText, newComentario, finalSobreaviso];

    if (realEndForDb) { sql += `, user_conclude_date = ?`; params.push(realEndForDb); }
    if (realStartForDb) { sql += `, data_start_real = ?`; params.push(realStartForDb); }
    if (pendStartDb !== null) { sql += `, data_start_pendente = ?`; params.push(pendStartDb); }
    if (pendEndDb !== null) { sql += `, data_end_pendente = ?`; params.push(pendEndDb); }
    if (user_id) { sql += `, user_id = ?`; params.push(Number(user_id)); }
    if (quantidade_tarefas !== undefined && quantidade_tarefas !== null) {
      const q = Number(
        typeof quantidade_tarefas === 'string'
          ? quantidade_tarefas.replace(',', '.')
          : quantidade_tarefas
      );
      if (Number.isFinite(q) && q >= 1) {
        sql += `, quantidade_tarefas = ?`;
        params.push(q);
      }
    }
    if (finalModo) { sql += `, modo_de_trabalho = ?`; params.push(finalModo); }
    // --- 4) If closing (7) AND we have both real start & end => compute active seconds ---
    let computedActive = null;
    if (Number(projectstates_id) === 7 && effStartReal && effEndReal) {
      const total = diffSec(effStartReal, effEndReal) ?? 0;
      // subtract only the overlap of pendente inside [realStart..realEnd]
      let pend = 0;
      if (effPendStart && effPendEnd) {
        pend = overlapSec(effStartReal, effEndReal, effPendStart, effPendEnd);
      }
      computedActive = Math.max(0, total - pend);
      sql += `, ativo_acumulado_seg = ?`;
      params.push(computedActive);
    }

    sql += ` WHERE task_id = ? LIMIT 1`;
    params.push(taskId);
    let upd;
    let attempts = 0;
    const maxAttempts = 3;
    while (attempts < maxAttempts) {
      attempts++;
      [upd] = await enterprisePool.execute(sql, params);

      if (upd.affectedRows > 0) {
        break; // Success!
      }

      if (attempts < maxAttempts) {
        console.warn(`[GLPI update] task ${taskId} affectedRows=0, retry ${attempts}/${maxAttempts}`);
        await new Promise(resolve => setTimeout(resolve, 100)); // 100ms delay
      }
    }
    if (upd.affectedRows === 0) {
      console.error(`[GLPI update] task ${taskId} DB update failed after ${maxAttempts} attempts`);
      // Don't fail - GLPI is already updated, let second call handle approval fields
      // Just log the issue for monitoring
    }

    // --- 5) Log status change ---
    await appendStatusLog(taskId, projectstates_id, user_id, enterprisePool);

    // Done
    res.json({
      success: true,
      glpi_result: glpiResp,
      computed_ativo_acumulado_seg: computedActive
    });
  } catch (err) {
    console.error('GLPI update error:', err.response?.data || err.message);
    res.status(500).json({ error: 'Failed to update GLPI ProjectTask' });
  } finally {
    if (sessionToken) await glpiKillSession(sessionToken);
  }
});

// GET /sync/task/:taskId - Forces formas_enviadas to match GLPI
app.get('/sync/task/:taskId', async (req, res) => {
  const taskId = Number(req.params.taskId);
  if (!Number.isFinite(taskId) || taskId <= 0) {
    return res.status(400).json({ error: 'invalid task id' });
  }

  let sessionToken;
  try {
    sessionToken = await glpiInitSession();

    // 1. Get true status from GLPI
    const glpiTask = await glpiGetProjectTask(sessionToken, taskId);
    if (!glpiTask || !glpiTask.projectstates_id) {
      return res.status(404).json({ error: 'Task not found in GLPI' });
    }

    // 2. Map state to string
    const statusDesejado = mapGlpiStateToStatus(glpiTask.projectstates_id);

    // 3. Force UPDATE in DB
    const [upd] = await enterprisePool.execute(
      `UPDATE formas_enviadas SET status = ? WHERE task_id = ?`,
      [statusDesejado, taskId]
    );

    res.json({
      success: true,
      synced_status: statusDesejado,
      affected: upd.affectedRows
    });
  } catch (err) {
    console.error(`[SYNC FIX] Error syncing task ${taskId}:`, err?.message || err);
    res.status(500).json({ error: 'Failed to sync task' });
  } finally {
    if (sessionToken) await glpiKillSession(sessionToken);
  }
});

// DELETE /user/tasks/:taskId?user_id=123
app.delete('/user/tasks/:taskId', async (req, res) => {
  const taskId = Number(req.params.taskId);
  const userId = Number(req.query.user_id);
  const isAdmin = req.query.is_admin === 'true';

  if (!Number.isFinite(taskId) || taskId <= 0) {
    return res.status(400).json({ error: 'task id inválido' });
  }
  if (!Number.isFinite(userId) || userId <= 0) {
    return res.status(400).json({ error: 'user_id inválido' });
  }

  try {
    // 1) Check current status in GLPI
    const [taskRow] = await queryWithRetry(
      glpiPool,
      'SELECT projectstates_id FROM glpi_projecttasks WHERE id = ?',
      [taskId]
    );
    if (!taskRow) return res.status(404).json({ error: 'Task não encontrada' });

    if (Number(taskRow.projectstates_id) === 3 && !isAdmin) {
      return res.status(403).json({ error: 'Tarefas aprovadas (status=7) não podem ser removidas.' });
    }

    let sessionToken;
    try {
      sessionToken = await glpiInitSession();

      // 2) Delete GLPI task (best-effort)
      try {
        await glpiDeleteProjectTask(sessionToken, taskId);
      } catch (e) {
        // if GLPI delete fails, stop to avoid orphaning states
        return res.status(500).json({ error: 'Falha ao remover no GLPI', detail: e?.message || e });
      }

      // 3) Delete formas_enviadas rows for this task
      try {
        await enterprisePool.execute('DELETE FROM formas_enviadas WHERE task_id = ?', [taskId]);
      } catch (e) {
        // Roll-forward: GLPI already removed; report but do not throw further
        console.warn('[DELETE /user/tasks/:taskId] formas_enviadas delete warn:', e?.message);
      }

      // 4) Optionally: cleanup logs/attachments for this task (best-effort)
      // await enterprisePool.execute('DELETE FROM status_log WHERE task_id = ?', [taskId]);

      return res.json({ success: true });
    } finally {
      if (sessionToken) await glpiKillSession(sessionToken);
    }
  } catch (e) {
    console.error('[DELETE /user/tasks/:taskId] error:', e?.message || e);
    return res.status(500).json({ error: 'Falha ao remover tarefa', detail: e?.message || String(e) });
  }
});

function buildGlpiBaseUrl() {
  let base = process.env.GLPI_FRONT_URL || '';
  if (!base) throw new Error('GLPI_API_URL is empty');
  // ensure protocol
  if (!/^https?:\/\//i.test(base)) {
    throw new Error(`GLPI_API_URL must include protocol (http/https). Current: "${base}"`);
  }
  // strip trailing slash
  base = base.replace(/\/+$/, '');
  return base;
}

function resourceUrl(resource, id) {
  const base = buildGlpiBaseUrl(); // throws if invalid
  const safeRes = String(resource).replace(/^\/+|\/+$/g, ''); // no leading/trailing slash
  const safeId = String(id).replace(/^\/+|\/+$/g, '');
  return `${base}/apirest.php/${safeRes}/${safeId}`;
}

/**
 * Delete a ProjectTask in GLPI with DELETE, fallback to POST _method=DELETE
 * @param {string} sessionToken
 * @param {number} taskId
 * @returns {Promise<boolean>}
 */
async function glpiDeleteProjectTask(sessionToken, taskId) {
  if (!Number.isFinite(taskId) || taskId <= 0) {
    throw new Error(`Invalid task id: ${taskId}`);
  }
  const url = resourceUrl('ProjectTask', taskId);

  const headers = {
    'Content-Type': 'application/json',
    'Session-Token': sessionToken,
    'App-Token': process.env.APP_TOKEN,
  };

  try {
    // Try real HTTP DELETE first
    await axios.delete(url, { headers, validateStatus: () => true });
    return true;
  } catch (e) {
    // Fallback for servers that block DELETE
    try {
      await axios.post(
        url,
        { _method: 'DELETE' },
        { headers, validateStatus: () => true }
      );
      return true;
    } catch (e2) {
      const why = e2?.response?.data ?? e2?.message ?? String(e2);
      throw new Error(`GLPI delete failed: ${why}`);
    }
  }
}


//fetch pending task
app.get('/formas-enviadas/pendente/:taskId', async (req, res) => {
  const taskId = Number(req.params.taskId);
  if (!Number.isFinite(taskId) || taskId <= 0) {
    return res.status(400).json({ error: 'taskId inválido' });
  }
  try {
    const [rows] = await enterprisePool.execute(
      `SELECT data_start_pendente
         FROM formas_enviadas
        WHERE task_id = ?
        ORDER BY id DESC
        LIMIT 1`,
      [taskId]
    );
    if (!rows || rows.length === 0) {
      // 200 with null keeps client flow simple
      return res.json({ task_id: taskId, data_start_pendente: null });
    }
    // MySQL DATETIME string or null
    const v = rows[0].data_start_pendente
      ? new Date(rows[0].data_start_pendente).toISOString().slice(0, 19).replace('T', ' ')
      : null;
    return res.json({ task_id: taskId, data_start_pendente: v });
  } catch (e) {
    console.error('GET /formas-enviadas/pendente/:taskId ERR:', e);
    return res.status(500).json({ error: 'Erro ao buscar início de Pendente' });
  }
});
// ========= NEW: Upload documents/images and link to GLPI =========
/**
 * POST /upload-documents
 * multipart/form-data:
 *  - despesaId (optional)
 *  - viagemId (optional)
 *
 * Returns: { ok: true, count, attachments: [{ original, url }] }
 */
app.post('/upload-documents', upload.array('files', 10), async (req, res) => {
  const despesaId = req.body.despesaId ? Number(req.body.despesaId) : null;
  const viagemId = req.body.viagemId ? Number(req.body.viagemId) : null;

  console.log(`[Upload] Body:`, JSON.stringify(req.body));
  if (req.files) {
    req.files.forEach((f, i) => console.log(`[Upload] File ${i}: ${f.originalname} (${f.size} bytes)`));
  }

  if (!req.files || req.files.length === 0) {
    return res.status(400).json({ error: 'Nenhum arquivo enviado ou extensão não permitida' });
  }

  const results = [];
  const failed = [];

  try {
    for (const file of req.files) {
      try {
        if (despesaId) {
          const sql = `INSERT INTO enterprise_despesas_arquivos (despesas_id, filename, mimetype, size) VALUES (?, ?, ?, ?)`;
          const [insertResult] = await enterprisePool.execute(sql, [despesaId, file.filename, file.mimetype, file.size]);
          const fileId = insertResult.insertId;

          // Build semantic filename: {despesa_id}_{data_consumo}_{user_name}_{file_id}.{ext}
          let finalFilename = file.filename;
          try {
            const [despesaRows] = await enterprisePool.query(
              'SELECT data_consumo, user_name FROM despesas WHERE despesa_id = ?',
              [despesaId]
            );
            if (despesaRows.length > 0) {
              const { data_consumo, user_name } = despesaRows[0];
              const dateStr = data_consumo
                ? (data_consumo instanceof Date
                  ? `${data_consumo.getFullYear()}-${String(data_consumo.getMonth() + 1).padStart(2, '0')}-${String(data_consumo.getDate()).padStart(2, '0')}`
                  : String(data_consumo).slice(0, 10))
                : 'sem-data';
              const sanitizedName = String(user_name || 'usuario')
                .replace(/[\\/:*?"<>|]/g, ' ')
                .replace(/\s+/g, ' ')
                .trim();
              const ext = path.extname(file.filename);
              finalFilename = `despesa_${despesaId}_${dateStr}_${sanitizedName}_${fileId}${ext}`;
              const oldPath = path.join(STORAGE_PATH, file.filename);
              const newPath = path.join(STORAGE_PATH, finalFilename);
              fs.renameSync(oldPath, newPath);
              await enterprisePool.execute(
                'UPDATE enterprise_despesas_arquivos SET filename = ? WHERE id = ?',
                [finalFilename, fileId]
              );
            }
          } catch (renameErr) {
            console.error('[Upload] Failed to rename despesa file:', renameErr.message);
            // keep original filename already stored in DB
          }

          results.push({
            original: file.originalname,
            optimizedName: finalFilename,
            url: `${process.env.STORAGE_URL}/${finalFilename}`,
            size: file.size
          });
          continue;
        } else if (viagemId) {
          const insertSql = `INSERT INTO enterprise_viagem_arquivos (viagem_id, filename, mimetype, size) VALUES (?, ?, ?, ?)`;
          const [insertResult] = await enterprisePool.execute(insertSql, [viagemId, file.filename, file.mimetype, file.size]);
          const fileId = insertResult.insertId;

          // Build semantic filename: {viagem_id}_{data_viagem}_{name}_{file_id}.{ext}
          let finalFilename = file.filename;
          try {
            const [viagemRows] = await enterprisePool.query(
              'SELECT data_viagem, name FROM registro_viagem WHERE viagem_id = ?',
              [viagemId]
            );
            if (viagemRows.length > 0) {
              const { data_viagem, name } = viagemRows[0];
              const dateStr = data_viagem
                ? (data_viagem instanceof Date
                  ? `${data_viagem.getFullYear()}-${String(data_viagem.getMonth() + 1).padStart(2, '0')}-${String(data_viagem.getDate()).padStart(2, '0')}`
                  : String(data_viagem).slice(0, 10))
                : 'sem-data';
              const sanitizedName = String(name || 'usuario')
                .replace(/[\\/:*?"<>|]/g, ' ')
                .replace(/\s+/g, ' ')
                .trim();
              const ext = path.extname(file.filename);
              finalFilename = `${viagemId}_${dateStr}_${sanitizedName}_${fileId}${ext}`;
              const oldPath = path.join(STORAGE_PATH, file.filename);
              const newPath = path.join(STORAGE_PATH, finalFilename);
              fs.renameSync(oldPath, newPath);
              await enterprisePool.execute(
                'UPDATE enterprise_viagem_arquivos SET filename = ? WHERE id = ?',
                [finalFilename, fileId]
              );
            }
          } catch (renameErr) {
            console.error('[Upload] Failed to rename viagem file:', renameErr.message);
            // keep original filename already stored in DB
          }

          results.push({
            original: file.originalname,
            optimizedName: finalFilename,
            url: `${process.env.STORAGE_URL}/${finalFilename}`,
            size: file.size
          });
          continue;
        }

        results.push({
          original: file.originalname,
          optimizedName: file.filename,
          url: `${process.env.STORAGE_URL}/${file.filename}`,
          size: file.size
        });
      } catch (err) {
        failed.push({ original: file.originalname, error: err.message });
      }
    }

    res.json({
      ok: true,
      count: results.length,
      attachments: results,
      failed
    });
  } catch (err) {
    console.error('Upload error:', err);
    res.status(500).json({ error: err.message || 'Upload failed' });
  }
});

// GET /despesas/:id/files
app.get('/despesas/:id/files', async (req, res) => {
  try {
    const despesaId = Number(req.params.id);
    const [rows] = await enterprisePool.query(
      'SELECT * FROM enterprise_despesas_arquivos WHERE despesas_id = ? ORDER BY id DESC',
      [despesaId]
    );

    // Lazy-migrate old GLPI file if present
    const [[despesa]] = await enterprisePool.query('SELECT photo_url FROM despesas WHERE despesa_id = ?', [despesaId]);
    if (despesa?.photo_url) {
      const docid = extractGlpiDocId(despesa.photo_url);
      if (docid) {
        try {
          const migrated = await migrateGlpiFileToLocal({ docid, entityType: 'despesa', entityId: despesaId, columnToClear: 'photo_url' });
          if (migrated) rows.push({ ...migrated, despesas_id: despesaId });
        } catch (e) {
          console.error(`GLPI migration failed for despesa ${despesaId}:`, e.message);
        }
      }
    }

    res.json(rows.map(r => ({ ...r, url: `${process.env.STORAGE_URL}/${r.filename}` })));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /registro-viagem/:id/files
app.get('/registro-viagem/:id/files', async (req, res) => {
  console.log('>>> HIT /registro-viagem/:id/files', req.params.id);
  try {
    const viagemId = Number(req.params.id);
    const [rows] = await enterprisePool.query(
      'SELECT * FROM enterprise_viagem_arquivos WHERE viagem_id = ? ORDER BY id DESC',
      [viagemId]
    );

    // Lazy-migrate old GLPI files if present
    const [[viagem]] = await enterprisePool.query(
      'SELECT photo_url_inicio, photo_url_fim FROM registro_viagem WHERE viagem_id = ?',
      [viagemId]
    );
    console.log(`[files] viagem ${viagemId} glpi urls:`, viagem?.photo_url_inicio, '|', viagem?.photo_url_fim);
    for (const col of ['photo_url_inicio', 'photo_url_fim']) {
      const url = viagem?.[col];
      if (!url) continue;
      const docid = extractGlpiDocId(url);
      console.log(`[migrate] viagem ${viagemId} col=${col} docid=${docid}`);
      if (!docid) continue;
      try {
        const migrated = await migrateGlpiFileToLocal({ docid, entityType: 'viagem', entityId: viagemId, columnToClear: col });
        if (migrated) rows.push({ ...migrated, viagem_id: viagemId });
        console.log(`[migrate] viagem ${viagemId} col=${col} done → ${migrated.filename}`);
      } catch (e) {
        console.error(`GLPI migration failed for viagem ${viagemId} col ${col}:`, e.message);
      }
    }

    res.json(rows.map(r => ({ ...r, url: `${process.env.STORAGE_URL}/${r.filename}` })));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
// DELETE the single file of a despesa (also adjusts status)
app.delete('/despesas/:despesaId/file/:fileId', async (req, res) => {
  const despesaId = Number(req.params.despesaId);
  const fileId = Number(req.params.fileId);
  if (!Number.isFinite(despesaId) || despesaId <= 0) {
    return res.status(400).json({ error: 'despesaId inválido' });
  }

  try {
    const [rows] = await enterprisePool.query('SELECT filename FROM enterprise_despesas_arquivos WHERE id = ? AND despesas_id = ?', [fileId, despesaId]);
    if (rows.length === 0) return res.status(404).json({ error: 'Arquivo não encontrado' });

    const filepath = path.join(STORAGE_PATH, rows[0].filename);
    if (fs.existsSync(filepath)) fs.unlinkSync(filepath);

    await enterprisePool.execute('DELETE FROM enterprise_despesas_arquivos WHERE id = ?', [fileId]);

    // adjust status
    await enterprisePool.execute(
      `UPDATE despesas SET aprovacao = CASE WHEN aprovacao = 'Reprovado' THEN 'Aguardando Aprovação' ELSE aprovacao END WHERE despesa_id = ?`,
      [despesaId]
    );

    return res.status(200).json({ success: true });
  } catch (err) {
    console.error('DELETE /despesas file error:', err.message);
    return res.status(500).json({ error: err.message || 'Erro ao apagar arquivo' });
  }
});

// Optional: tiny timeout helper so requests don't hang forever
function withTimeout(promise, ms, label = '') {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`DB timeout ${ms}ms ${label}`)), ms)
    ),
  ]);
}
// DELETE /despesas/:id  -> delete local files and remove row
app.delete('/despesas/:id', async (req, res) => {
  const despesaId = Number(req.params.id);
  if (!Number.isFinite(despesaId) || despesaId <= 0) {
    return res.status(400).json({ error: 'despesaId inválido' });
  }

  try {
    const [files] = await enterprisePool.query('SELECT filename FROM enterprise_despesas_arquivos WHERE despesas_id = ?', [despesaId]);
    for (const f of files) {
      const filepath = path.join(STORAGE_PATH, f.filename);
      if (fs.existsSync(filepath)) fs.unlinkSync(filepath);
    }
    await enterprisePool.execute('DELETE FROM enterprise_despesas_arquivos WHERE despesas_id = ?', [despesaId]);

    // Delete despesa row
    await enterprisePool.execute(`DELETE FROM despesas WHERE despesa_id = ?`, [despesaId]);

    return res.json({ success: true, id: despesaId });
  } catch (err) {
    console.error('DELETE /despesas/:id error:', err.message);
    return res.status(500).json({ error: err.message || 'Erro ao excluir despesa' });
  }
});


app.get('/aprovacao/closed-tasks', async (req, res) => {
  const projectId = Number(req.query.project_id || process.env.PROJECT_ID || 599);
  if (!Number.isFinite(projectId) || projectId <= 0) {
    return res.status(400).json({ error: 'project_id inválido' });
  }

  // Parse statuses query param: "3,7,9" => [3, 7, 9], default to [7]
  const statusesParam = req.query.statuses || '7';
  const statuses = statusesParam
    .split(',')
    .map(s => Number(s.trim()))
    .filter(n => Number.isFinite(n) && n > 0);

  if (statuses.length === 0) {
    return res.status(400).json({ error: 'Pelo menos um status deve ser fornecido' });
  }

  const placeholders = statuses.map(() => '?').join(',');
  const sql = `
    SELECT
      pt.id,
      pt.name,
      pt.content,
      pt.real_start_date,
      pt.real_end_date,
      pt.plan_end_date,
      pt.date_mod,
      pt.date_creation,
      pt.projectstates_id,
      pt.projects_id,
      u_owner.name AS creator_name,

      /* Primary assignee via team (User) */
      (SELECT u2.name
         FROM glpi_projecttaskteams ptt2
         JOIN glpi_users u2 ON u2.id = ptt2.items_id
        WHERE ptt2.projecttasks_id = pt.id
          AND ptt2.itemtype = 'User'
        ORDER BY ptt2.id ASC
        LIMIT 1) AS primary_assignee_name,

      /* All assignees (Users) CSV */
      (SELECT GROUP_CONCAT(u3.name ORDER BY u3.name SEPARATOR ', ')
         FROM glpi_projecttaskteams ptt3
         JOIN glpi_users u3 ON u3.id = ptt3.items_id
        WHERE ptt3.projecttasks_id = pt.id
          AND ptt3.itemtype = 'User') AS assignees_users_csv

    FROM glpi_projecttasks pt
    LEFT JOIN glpi_users u_owner ON u_owner.id = pt.users_id
    WHERE pt.projects_id = ?
      AND pt.projectstates_id IN (${placeholders})
    /* Oldest first (as requested) */
    ORDER BY COALESCE(pt.real_end_date, pt.plan_end_date, pt.date_mod, pt.date_creation) ASC
  `;

  try {
    // 1) GLPI tasks (ALL rows – no LIMIT), pass projectId + statuses array
    const rows = await queryWithRetry(glpiPool, sql, [projectId, ...statuses]);

    // 2) Batch fetch latest formas_enviadas per task from ENTERPRISE DB (chunk IN lists)
    const taskIds = rows.map(r => r.id).filter(Boolean);
    const latestByTask = new Map(); // task_id -> latest row

    const chunkSize = 1000;
    for (let i = 0; i < taskIds.length; i += chunkSize) {
      const chunk = taskIds.slice(i, i + chunkSize);
      if (!chunk.length) continue;

      const placeholders = chunk.map(() => '?').join(',');
      const formsSql = `
        SELECT fe.task_id,
               fe.lider,
               fe.enviado_em,
               fe.data_conclusao,
               fe.status,
               fe.item,
               fe.quantidade_tarefas,
               fe.id,
               us.tipo_de_evidencia
          FROM formas_enviadas fe
          LEFT JOIN Tab_6_Tabela_de_servicos_US us
                 ON us.ITEM = fe.item
         WHERE fe.task_id IN (${placeholders})
         ORDER BY fe.task_id ASC, fe.id DESC
      `;
      const [forms] = await enterprisePool.query(formsSql, chunk);

      for (const f of forms) {
        if (!latestByTask.has(f.task_id)) {
          latestByTask.set(f.task_id, {
            lider: f.lider || null,
            enviado_em: f.enviado_em || null,
            data_conclusao: f.data_conclusao || null,
            status: f.status || null,
            item: f.item || null,
            quantidade_tarefas: f.quantidade_tarefas || 1,
            tipo_de_evidencia: f.tipo_de_evidencia || null,
          });
        }
      }
    }

    // 3) Merge
    const enriched = rows.map(r => {
      const assignees =
        r.assignees_users_csv
          ? Array.from(new Set(r.assignees_users_csv.split(', ').filter(Boolean)))
          : [];
      const fe = latestByTask.get(r.id) || {};
      return {
        id: r.id,
        name: r.name,
        content: r.content,
        real_start_date: r.real_start_date,
        real_end_date: r.real_end_date,
        projectstates_id: r.projectstates_id,
        projects_id: r.projects_id,

        // formas_enviadas data
        enviado_em: fe.enviado_em || null,
        data_conclusao: fe.data_conclusao || null,
        lider: fe.lider || null,
        status_forma: fe.status || null,
        item: fe.item || null,
        quantidade_tarefas: fe.quantidade_tarefas || 1,
        tipo_de_evidencia: fe.tipo_de_evidencia || null,

        // GLPI info
        creator_name: r.creator_name,
        criador_display: r.primary_assignee_name || null,
        assignees
      };
    });

    // (Optional) keep the same ASC ordering explicitly on merged date keys:
    enriched.sort((a, b) => {
      const aKey = Date.parse(a.data_conclusao || a.real_end_date || a.plan_end_date || a.date_mod || a.date_creation || 0) || 0;
      const bKey = Date.parse(b.data_conclusao || b.real_end_date || b.plan_end_date || b.date_mod || b.date_creation || 0) || 0;
      return aKey - bKey; // oldest first
    });

    res.json(enriched);
  } catch (e) {
    console.error('[Aprovação] closed-tasks ERR:', e.message);
    res.status(500).json({ error: e.message });
  }
});



// Task details + documents + líder.
// Task details + documents + líder + enviado_em + data_conclusao.
app.get('/aprovacao/tasks/:id', async (req, res) => {
  const taskId = Number(req.params.id);
  if (!Number.isFinite(taskId) || taskId <= 0) {
    return res.status(400).json({ error: 'task id inválido' });
  }

  const taskSql = `
    SELECT
      pt.id,
      pt.name,
      pt.content,
      pt.real_start_date,
      pt.real_end_date,
      pt.plan_start_date,
      pt.plan_end_date,
      pt.date_creation,
      pt.date_mod,
      pt.projects_id,
      st.name AS status_name,

      u_owner.name AS creator_name,

      (SELECT u2.name
         FROM glpi_projecttaskteams ptt2
         JOIN glpi_users u2 ON u2.id = ptt2.items_id
        WHERE ptt2.projecttasks_id = pt.id
          AND ptt2.itemtype = 'User'
        ORDER BY ptt2.id ASC
        LIMIT 1) AS primary_assignee_name,

      (SELECT GROUP_CONCAT(u3.name ORDER BY u3.name SEPARATOR ', ')
         FROM glpi_projecttaskteams ptt3
         JOIN glpi_users u3 ON u3.id = ptt3.items_id
        WHERE ptt3.projecttasks_id = pt.id
          AND ptt3.itemtype = 'User') AS assignees_users_csv

    FROM glpi_projecttasks pt
    LEFT JOIN glpi_users u_owner ON u_owner.id = pt.users_id
    LEFT JOIN glpi_projectstates st ON st.id = pt.projectstates_id
    WHERE pt.id = ?
    LIMIT 1
  `;

  const docsSql = `
    SELECT d.id AS docid, d.name AS doc_name, d.filename, d.mime, d.date_mod
    FROM glpi_documents d
    JOIN glpi_documents_items di ON di.documents_id = d.id
    WHERE di.itemtype = 'ProjectTask' AND di.items_id = ?
    ORDER BY COALESCE(d.date_mod, d.date_creation) DESC
    LIMIT 200
  `;

  try {
    // 1) GLPI task
    const taskRows = await queryWithRetry(glpiPool, taskSql, [taskId]);
    const task = taskRows[0];
    if (!task) return res.status(404).json({ error: 'Task não encontrada' });

    // 2) Latest formas_enviadas row for this task from ENTERPRISE
    const [feRows] = await enterprisePool.query(
      `SELECT fe.task_id,
              fe.lider,
              fe.enviado_em,
              fe.data_conclusao,
              fe.status,
              fe.item,
              fe.quantidade_tarefas,
              us.tipo_de_evidencia
         FROM formas_enviadas fe
         LEFT JOIN Tab_6_Tabela_de_servicos_US us
                ON us.ITEM = fe.item
        WHERE fe.task_id = ?
        ORDER BY fe.id DESC
        LIMIT 1`,
      [taskId]
    );
    const fe = feRows?.[0] || {};

    // 3) Documents
    const docRows = await queryWithRetry(glpiPool, docsSql, [taskId]);
    const documents = (docRows || []).map((d) => ({
      docid: d.docid,
      name: d.doc_name,
      filename: d.filename,
      mime: d.mime,
      url: `${process.env.GLPI_FRONT_URL}/front/document.send.php?docid=${d.docid}`,
      download_url: `/aprovacao/document/${d.docid}`
    }));

    const assignees =
      task.assignees_users_csv
        ? Array.from(new Set(task.assignees_users_csv.split(', ').filter(Boolean)))
        : [];

    res.json({
      id: task.id,
      name: task.name,
      content: task.content,
      plan_start_date: task.plan_start_date,
      plan_end_date: task.plan_end_date,
      real_start_date: task.real_start_date,
      real_end_date: task.real_end_date,
      date_creation: task.date_creation,
      date_mod: task.date_mod,
      projects_id: task.projects_id,
      status_name: task.status_name,

      // from formas_enviadas
      lider: fe.lider || null,
      enviado_em: fe.enviado_em || null,
      data_conclusao: fe.data_conclusao || null,
      status_forma: fe.status || null,
      quantidade_tarefas: fe.quantidade_tarefas ?? null,
      item: fe.item || null,
      tipo_de_evidencia: fe.tipo_de_evidencia || null,

      // GLPI users
      creator_name: task.creator_name,
      criador_display: task.primary_assignee_name || null,

      assignees,
      documents
    });
  } catch (e) {
    console.error('[Aprovação] task details ERR:', e.message);
    res.status(500).json({ error: e.message });
  }
});
// GET /aprovacao/tasks/bulk?ids=123,456,789
// Returns light details for many tasks at once (NO documents).
app.get('/aprovacao/tasks/bulk', async (req, res) => {
  const idsParam = String(req.query.ids || '').trim();
  if (!idsParam) return res.json([]);

  // Parse & dedupe ids (integers only)
  const ids = Array.from(new Set(
    idsParam.split(',').map(s => Number(s.trim())).filter(n => Number.isFinite(n) && n > 0)
  ));
  if (ids.length === 0) return res.json([]);

  // Base task SQL (no documents here)
  const taskSqlBase = `
    SELECT
      pt.id,
      pt.name,
      pt.content,
      pt.real_start_date,
      pt.real_end_date,
      pt.plan_start_date,
      pt.plan_end_date,
      pt.date_creation,
      pt.date_mod,
      pt.projects_id,
      st.name AS status_name,
      u_owner.name AS creator_name,

      /* Primary assignee via team (User) */
      (SELECT u2.name
         FROM glpi_projecttaskteams ptt2
         JOIN glpi_users u2 ON u2.id = ptt2.items_id
        WHERE ptt2.projecttasks_id = pt.id
          AND ptt2.itemtype = 'User'
        ORDER BY ptt2.id ASC
        LIMIT 1) AS primary_assignee_name,

      /* All assignees (Users) CSV */
      (SELECT GROUP_CONCAT(u3.name ORDER BY u3.name SEPARATOR ', ')
         FROM glpi_projecttaskteams ptt3
         JOIN glpi_users u3 ON u3.id = ptt3.items_id
        WHERE ptt3.projecttasks_id = pt.id
          AND ptt3.itemtype = 'User') AS assignees_users_csv
    FROM glpi_projecttasks pt
    LEFT JOIN glpi_users u_owner ON u_owner.id = pt.users_id
    LEFT JOIN glpi_projectstates st ON st.id = pt.projectstates_id
    WHERE pt.id IN ({{IDS}})
  `;

  try {
    // 1) Fetch GLPI tasks in chunks
    const chunkSize = 1000; // safe for MySQL IN()
    const tasksById = new Map();

    for (let i = 0; i < ids.length; i += chunkSize) {
      const chunk = ids.slice(i, i + chunkSize);
      const placeholders = chunk.map(() => '?').join(',');
      const sql = taskSqlBase.replace('{{IDS}}', placeholders);
      const rows = await queryWithRetry(glpiPool, sql, chunk);
      for (const r of rows) tasksById.set(r.id, r);
    }

    // 2) Fetch latest formas_enviadas rows for these tasks (also chunked)
    const latestFE = new Map(); // task_id -> latest row fields
    for (let i = 0; i < ids.length; i += chunkSize) {
      const chunk = ids.slice(i, i + chunkSize);
      const placeholders = chunk.map(() => '?').join(',');
      const formsSql = `
        SELECT
          fe.task_id,
          fe.lider,
          fe.enviado_em,
          fe.data_conclusao,
          fe.status,
          fe.item,
          fe.quantidade_tarefas,
          fe.id,
          us.tipo_de_evidencia
        FROM formas_enviadas fe
        LEFT JOIN Tab_6_Tabela_de_servicos_US us
          ON REPLACE(TRIM(us.ITEM), ' ', '') = REPLACE(TRIM(fe.item), ' ', '')
        WHERE fe.task_id IN (${placeholders})
        ORDER BY fe.task_id ASC, fe.id DESC
      `;

      const [forms] = await enterprisePool.query(formsSql, chunk);
      for (const f of forms) {
        if (!latestFE.has(f.task_id)) {
          latestFE.set(f.task_id, {
            lider: f.lider || null,
            enviado_em: f.enviado_em || null,
            data_conclusao: f.data_conclusao || null,
            status_forma: f.status || null,
            item: f.item || null,
            quantidade_tarefas: f.quantidade_tarefas || 1,
            tipo_de_evidencia: f.tipo_de_evidencia || null,
          });
        }
      }
    }

    // 3) Merge (no docs)
    const result = ids
      .map(id => {
        const t = tasksById.get(id);
        if (!t) return null;
        const fe = latestFE.get(id) || {};
        const assignees = t.assignees_users_csv
          ? Array.from(new Set(t.assignees_users_csv.split(', ').filter(Boolean)))
          : [];
        return {
          id: t.id,
          name: t.name,
          content: t.content,
          plan_start_date: t.plan_start_date,
          plan_end_date: t.plan_end_date,
          real_start_date: t.real_start_date,
          real_end_date: t.real_end_date,
          date_creation: t.date_creation,
          date_mod: t.date_mod,
          projects_id: t.projects_id,
          status_name: t.status_name,
          creator_name: t.creator_name,
          criador_display: t.primary_assignee_name || null,
          assignees,
          // formas_enviadas
          lider: fe.lider || null,
          enviado_em: fe.enviado_em || null,
          data_conclusao: fe.data_conclusao || null,
          status_forma: fe.status_forma || null,
          quantidade_tarefas: fe.quantidade_tarefas || 1,
          item: fe.item || null,
          tipo_de_evidencia: fe.tipo_de_evidencia || null,
        };
      })
      .filter(Boolean);

    res.json(result);
  } catch (e) {
    console.error('[Aprovação] tasks/bulk ERR:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// Record approver name + date + status
app.post('/aprovacao/record', async (req, res) => {
  const { task_id, aprovado_por, aprovado_data, status_forma } = req.body || {};
  if (!task_id || !aprovado_por) {
    return res.status(400).json({ error: 'task_id e aprovado_por obrigatórios' });
  }

  try {
    await enterprisePool.query(
      `
      UPDATE formas_enviadas
         SET aprovado_por = ?,
             aprovado_data = ?,
             /* if status_forma is sent, overwrite; otherwise keep current */
             status = COALESCE(?, status)
       WHERE task_id = ?
       ORDER BY id DESC
       LIMIT 1
      `,
      [aprovado_por, aprovado_data, status_forma ?? null, task_id]
    );
    res.json({ success: true });
  } catch (e) {
    console.error('recordFormApproval ERR:', e);
    res.status(500).json({ error: e.message });
  }
});

// --- DOWNLOAD PROXY FOR GLPI DOCUMENTS ---
// GET /aprovacao/document/:docid -> streams the file to the client
app.get('/aprovacao/document/:docid', async (req, res) => {
  const docid = Number(req.params.docid);
  if (!Number.isFinite(docid) || docid <= 0) {
    return res.status(400).json({ error: 'docid inválido' });
  }

  let sessionToken;

  // headers helper
  const setDownloadHeaders = ({ filename, mime, length, dispositionFromServer, typeFromServer }) => {
    if (dispositionFromServer) {
      res.setHeader('Content-Disposition', dispositionFromServer);
    } else {
      // RFC 5987 for UTF-8 filenames
      const safe = filename.replace(/"/g, "'");
      res.setHeader(
        'Content-Disposition',
        `attachment; filename="${safe}"; filename*=UTF-8''${encodeURIComponent(filename)}`
      );
    }
    res.setHeader('Content-Type', typeFromServer || mime || 'application/octet-stream');
    if (length) res.setHeader('Content-Length', length);
    // avoid caching sensitive files
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
  };


  try {
    // 1) Start REST session
    const initResp = await axios.get(`${process.env.GLPI_URL}/initSession`, {
      headers: {
        'App-Token': process.env.APP_TOKEN,
        Authorization: `user_token ${process.env.USER_TOKEN}`,
      },
      validateStatus: () => true,
    });
    if (initResp.status !== 200 || !initResp.data?.session_token) {
      return res.status(502).json({ error: 'Falha em initSession', detail: initResp.data });
    }
    sessionToken = initResp.data.session_token;

    // 2) Fetch Document metadata (to build nice filename)
    let meta = {};
    try {
      const metaResp = await axios.get(`${process.env.GLPI_URL}/Document/${docid}`, {
        headers: {
          'App-Token': process.env.APP_TOKEN,
          'Session-Token': sessionToken,
        },
        validateStatus: () => true,
      });
      if (metaResp.status === 200 && metaResp.data) {
        meta = metaResp.data;
      }
    } catch (_) {
      // non-fatal
    }

    const stored = (meta.filename || '').toString().trim();
    const display = (meta.name || '').toString().trim();
    const mime = (meta.mime || '').toString().trim() || 'application/octet-stream';
    const displayHasExt = /\.[a-z0-9]{2,8}$/i.test(display);
    let filename = displayHasExt ? display : (stored || `document-${docid}`);
    if (!/\.[a-z0-9]{2,8}$/i.test(filename)) {
      const ext = inferExt(mime);
      if (ext) filename = `${filename}.${ext}`;
    }

    // 3) Try official REST download endpoints first
    const tryRestUrl = async (url) => {
      const r = await axios.get(url, {
        responseType: 'stream',
        headers: {
          'App-Token': process.env.APP_TOKEN,
          'Session-Token': sessionToken,
          Accept: 'application/octet-stream',
        },
        maxRedirects: 3,
        validateStatus: (s) => s >= 200 && s < 400,
      });
      return r;
    };

    const restCandidates = [
      `${process.env.GLPI_URL}/Document/${docid}/download`,
      `${process.env.GLPI_URL}/Document/${docid}?download=1`,
    ];

    let dlResp = null;
    for (const url of restCandidates) {
      try {
        const r = await tryRestUrl(url);
        const ctype = r.headers['content-type'] || '';
        if (!looksLikeHtml(ctype)) {
          dlResp = r;
          break;
        }
      } catch {
        // try next
      }
    }

    // 4) Fallback to Front (some setups require this)
    if (!dlResp) {
      try {
        dlResp = await axios.get(`${glpiFrontBase()}/front/document.send.php?docid=${docid}`, {
          responseType: 'stream',
          headers: {
            'App-Token': process.env.APP_TOKEN,
            'Session-Token': sessionToken,
            Accept: '*/*',
          },
          maxRedirects: 5,
          validateStatus: (s) => s >= 200 && s < 400,
        });
        const ctype = dlResp.headers['content-type'] || '';
        if (looksLikeHtml(ctype)) {
          return res.status(403).json({
            error: 'Acesso negado pelo Front do GLPI (document.send.php).',
            hint:
              'Ative o endpoint REST de download (Document/:id/download) ou libere o acesso ao front para a sessão REST.',
          });
        }
      } catch (e) {
        return res.status(502).json({
          error: 'Falha no download do documento (Front).',
          detail: e?.message || 'unknown',
        });
      }
    }

    // 5) Stream to client with proper headers
    setDownloadHeaders({
      filename,
      mime,
      length: dlResp.headers['content-length'],
      dispositionFromServer: dlResp.headers['content-disposition'],
      typeFromServer: dlResp.headers['content-type'],
    });

    // CRITICAL: await the stream to finish before the 'finally' kills the session!
    await new Promise((resolve, reject) => {
      dlResp.data.pipe(res);
      dlResp.data.on('end', () => {
        resolve();
      });
      dlResp.data.on('error', (err) => {
        console.error('[doc proxy] stream error:', err?.message);
        if (!res.headersSent) {
          res.status(502).json({ error: 'Falha ao transmitir arquivo' });
        }
        reject(err);
      });
      res.on('finish', () => {
        resolve();
      });
      res.on('error', (err) => {
        reject(err);
      });
    });
  } catch (e) {
    console.error('[doc proxy] ERR:', e?.response?.status, e?.response?.data || e?.message);
    if (!res.headersSent) {
      res
        .status(502)
        .json({ error: 'Falha ao baixar documento', detail: e?.message || 'unknown' });
    }
  } finally {
    // close REST session (best effort)
    if (sessionToken) {
      try {
        await axios.get(`${process.env.GLPI_URL}/killSession`, {
          headers: {
            'App-Token': process.env.APP_TOKEN,
            'Session-Token': sessionToken,
          },
        });
      } catch (_) { }
    }
  }
});

// POST /enterprise-medicao-veiculos
app.post('/enterprise-medicao-veiculos', async (req, res) => {
  try {
    const {
      mes, data_inicio, data_fim, solicitante, grupo_enterprise,
      tipo_veiculo, periodo_utiliza, qtd, user, user_id, status,
    } = req.body || {};

    const sql = `
      INSERT INTO enterprise_medicao_veiculos
        (mes, data_inicio, data_fim, solicitante, grupo_enterprise,
         tipo_veiculo, periodo_utiliza, qtd, user, user_id, status, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    `;
    const params = [
      mes ?? null,
      data_inicio ?? null,
      data_fim ?? null,
      solicitante ?? null,
      grupo_enterprise ?? null,
      tipo_veiculo ?? null,
      periodo_utiliza ?? null,
      qtd != null ? Number(qtd) : null,
      user ?? null,
      user_id ?? null,
      status ?? null,
    ];

    const [result] = await enterprisePool.execute(sql, params);
    return res.status(201).json({ success: true, id: result.insertId });
  } catch (e) {
    console.error('POST /enterprise-medicao-veiculos exception:', e);
    return res.status(500).json({ error: e.message || 'Erro interno' });
  }
});

// ========= DOWNLOAD ARQUIVOS (ZIP) =========

/**
 * GET /arquivos/download-list?from=YYYY-MM-DD&to=YYYY-MM-DD
 * Returns JSON with two arrays: despesas files and viagem files in the date range.
 */
app.get('/arquivos/download-list', async (req, res) => {
  const from = req.query.from;
  const to = req.query.to;

  if (!from || !to) {
    return res.status(400).json({ error: 'Parâmetros "from" e "to" são obrigatórios (YYYY-MM-DD).' });
  }

  try {
    const [despesasFiles] = await enterprisePool.query(
      `SELECT cda.id, cda.despesas_id, cda.filename, cda.mimetype, cda.size,
              d.data_consumo, d.user_name
       FROM enterprise_despesas_arquivos cda
       JOIN despesas d ON cda.despesas_id = d.despesa_id
       WHERE d.data_consumo BETWEEN ? AND ?
       ORDER BY d.data_consumo DESC, cda.id DESC`,
      [from, to]
    );

    const [viagensFiles] = await enterprisePool.query(
      `SELECT cva.id, cva.viagem_id, cva.filename, cva.mimetype, cva.size,
              rv.data_viagem, rv.name
       FROM enterprise_viagem_arquivos cva
       JOIN registro_viagem rv ON cva.viagem_id = rv.viagem_id
       WHERE rv.data_viagem BETWEEN ? AND ?
       ORDER BY rv.data_viagem DESC, cva.id DESC`,
      [from, to]
    );

    const storageUrl = process.env.STORAGE_URL || '';
    res.json({
      despesas: despesasFiles.map(r => ({ ...r, url: `${storageUrl}/${r.filename}` })),
      viagens: viagensFiles.map(r => ({ ...r, url: `${storageUrl}/${r.filename}` })),
    });
  } catch (err) {
    console.error('GET /arquivos/download-list error:', err);
    res.status(500).json({ error: err.message });
  }
});

/**
 * GET /arquivos/download-zip?from=YYYY-MM-DD&to=YYYY-MM-DD
 * Streams a ZIP archive containing all files from both tables within the date range.
 * Files are organised into sub-folders: despesas/ and viagens/
 */
app.get('/arquivos/download-zip', async (req, res) => {
  const from = req.query.from;
  const to = req.query.to;

  if (!from || !to) {
    return res.status(400).json({ error: 'Parâmetros "from" e "to" são obrigatórios (YYYY-MM-DD).' });
  }

  try {
    const [despesasFiles] = await enterprisePool.query(
      `SELECT cda.id, cda.filename, cda.mimetype,
              d.data_consumo, d.user_name
       FROM enterprise_despesas_arquivos cda
       JOIN despesas d ON cda.despesas_id = d.despesa_id
       WHERE d.data_consumo BETWEEN ? AND ?
       ORDER BY d.data_consumo DESC, cda.id DESC`,
      [from, to]
    );

    const [viagensFiles] = await enterprisePool.query(
      `SELECT cva.id, cva.filename, cva.mimetype,
              rv.data_viagem, rv.name
       FROM enterprise_viagem_arquivos cva
       JOIN registro_viagem rv ON cva.viagem_id = rv.viagem_id
       WHERE rv.data_viagem BETWEEN ? AND ?
       ORDER BY rv.data_viagem DESC, cva.id DESC`,
      [from, to]
    );

    const totalFiles = despesasFiles.length + viagensFiles.length;
    if (totalFiles === 0) {
      return res.status(404).json({ error: 'Nenhum arquivo encontrado para o período selecionado.' });
    }

    const zipName = `arquivos_${from}_a_${to}.zip`;
    res.setHeader('Content-Type', 'application/zip');
    res.setHeader('Content-Disposition', `attachment; filename="${zipName}"`);

    const archive = archiver('zip', { zlib: { level: 6 } });
    archive.on('error', (err) => {
      console.error('[ZIP] archiver error:', err);
      if (!res.headersSent) {
        res.status(500).json({ error: 'Erro ao gerar arquivo ZIP.' });
      }
    });

    archive.pipe(res);

    // Add despesas files under despesas/ folder
    for (const f of despesasFiles) {
      const filePath = path.join(STORAGE_PATH, f.filename);
      if (!fs.existsSync(filePath)) {
        console.warn(`[ZIP] Despesa file not found on disk: ${filePath}`);
        continue;
      }
      const ext = path.extname(f.filename);
      const dateStr = f.data_consumo
        ? (f.data_consumo instanceof Date
            ? f.data_consumo.toISOString().slice(0, 10)
            : String(f.data_consumo).slice(0, 10))
        : 'sem-data';
      const safeName = String(f.user_name || 'usuario').replace(/[\\/:*?"<>|]/g, '_').trim();
      const archiveName = `despesas/${dateStr}_${safeName}_${f.id}${ext}`;
      archive.file(filePath, { name: archiveName });
    }

    // Add viagem files under viagens/ folder
    for (const f of viagensFiles) {
      const filePath = path.join(STORAGE_PATH, f.filename);
      if (!fs.existsSync(filePath)) {
        console.warn(`[ZIP] Viagem file not found on disk: ${filePath}`);
        continue;
      }
      const ext = path.extname(f.filename);
      const dateStr = f.data_viagem
        ? (f.data_viagem instanceof Date
            ? f.data_viagem.toISOString().slice(0, 10)
            : String(f.data_viagem).slice(0, 10))
        : 'sem-data';
      const safeName = String(f.name || 'usuario').replace(/[\\/:*?"<>|]/g, '_').trim();
      const archiveName = `viagens/${dateStr}_${safeName}_${f.id}${ext}`;
      archive.file(filePath, { name: archiveName });
    }

    await archive.finalize();
  } catch (err) {
    console.error('GET /arquivos/download-zip error:', err);
    if (!res.headersSent) {
      res.status(500).json({ error: err.message });
    }
  }
});

/**
 * DELETE /arquivos/delete-period?from=YYYY-MM-DD&to=YYYY-MM-DD
 * Deletes all files in the date range from the filesystem and database.
 */
app.delete('/arquivos/delete-period', async (req, res) => {
  const from = req.query.from;
  const to = req.query.to;

  if (!from || !to) {
    return res.status(400).json({ error: 'Parâmetros "from" e "to" são obrigatórios (YYYY-MM-DD).' });
  }

  try {
    const [despesasFiles] = await enterprisePool.query(
      `SELECT cda.id, cda.filename
       FROM enterprise_despesas_arquivos cda
       JOIN despesas d ON cda.despesas_id = d.despesa_id
       WHERE d.data_consumo BETWEEN ? AND ?`,
      [from, to]
    );

    const [viagensFiles] = await enterprisePool.query(
      `SELECT cva.id, cva.filename
       FROM enterprise_viagem_arquivos cva
       JOIN registro_viagem rv ON cva.viagem_id = rv.viagem_id
       WHERE rv.data_viagem BETWEEN ? AND ?`,
      [from, to]
    );

    // Unlink from FS
    const allFiles = [...despesasFiles, ...viagensFiles];
    for (const file of allFiles) {
      const filePath = path.join(STORAGE_PATH, file.filename);
      if (fs.existsSync(filePath)) {
        try {
          fs.unlinkSync(filePath);
        } catch (e) {
          console.error('[DELETE] failed to unlink file:', filePath, e.message);
        }
      }
    }

    // Delete from DB
    if (despesasFiles.length > 0) {
      const ids = despesasFiles.map(f => f.id);
      await enterprisePool.query('DELETE FROM enterprise_despesas_arquivos WHERE id IN (?)', [ids]);
    }
    if (viagensFiles.length > 0) {
      const ids = viagensFiles.map(f => f.id);
      await enterprisePool.query('DELETE FROM enterprise_viagem_arquivos WHERE id IN (?)', [ids]);
    }

    res.json({ success: true, count: allFiles.length });
  } catch (err) {
    console.error('DELETE /arquivos/delete-period error:', err);
    res.status(500).json({ error: err.message });
  }
});

// ========= START SERVER =========
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Backend running on http://localhost:${PORT}`);
});
