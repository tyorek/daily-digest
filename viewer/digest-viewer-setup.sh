# digest-viewer-setup.sh -- run as root on the Homepage container (192.168.99.8).
# Copy this whole file and paste it into the root shell, or save it and run: bash digest-viewer-setup.sh
# Safe to re-run. Sets up:
#   - user "digest" that the agent box can push to over SSH, write-only, into /srv/digest/incoming only (rrsync)
#   - /srv/digest/www (root-owned): the viewer page plus a symlink to the pushed digest.md
#   - digest-viewer.service: python http.server on :8090 as nobody, serving /srv/digest/www read-only

apt-get install -y rsync openssh-server python3

id digest >/dev/null 2>&1 || useradd -r -m -d /srv/digest -s /bin/sh digest
usermod -p '*' digest
mkdir -p /srv/digest/.ssh /srv/digest/incoming /srv/digest/www
chown root:root /srv/digest /srv/digest/.ssh /srv/digest/www
chmod 755 /srv/digest /srv/digest/.ssh /srv/digest/www
chown digest:digest /srv/digest/incoming
chmod 755 /srv/digest/incoming

RRSYNC=$(command -v rrsync || echo /usr/bin/rrsync)
[ -x "$RRSYNC" ] || echo "WARNING: rrsync not found; the agent's push will fail until it's installed"
echo "command=\"$RRSYNC -wo /srv/digest/incoming\",restrict ssh-ed25519 AAAA...REPLACE_WITH_YOUR_PUBLIC_KEY agent@claude-noc-lxc" > /srv/digest/.ssh/authorized_keys
chown root:root /srv/digest/.ssh/authorized_keys
chmod 644 /srv/digest/.ssh/authorized_keys

ln -sfn /srv/digest/incoming/digest.md /srv/digest/www/digest.md

cat > /srv/digest/www/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Daily digest</title>
<style>
  html { scrollbar-color: rgba(149,214,0,.45) #141414; scrollbar-width: thin; }
  :root { --bg: transparent; --fg: #f5f5f5; --muted: #a3a3a3; --line: rgba(149,214,0,.25);
          --ok: #95d600; --warn: #fbbf24; --err: #f87171; --code: rgba(255,255,255,.07); }
  html, body { margin: 0; background: var(--bg); color: var(--fg);
               font: 14px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  body { padding: 12px 16px; }
  header { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between;
           gap: 4px 12px; border-bottom: 1px solid var(--line); padding-bottom: 6px; margin-bottom: 8px; }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  #updated { color: var(--muted); font-size: 12px; }
  #updated.stale { color: var(--warn); }
  #status { border-left: 3px solid var(--muted); padding: 6px 10px; margin: 8px 0 10px;
            background: rgba(255,255,255,.04); border-radius: 0 6px 6px 0; }
  #status.ok { border-color: var(--ok); background: rgba(149,214,0,.08); }
  #status.warn { border-color: var(--warn); background: rgba(251,191,36,.08); }
  #status:empty { display: none; }
  h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted);
       margin: 14px 0 4px; font-weight: 600; }
  h3, h4 { color: var(--ok); font-size: 14px; margin: 10px 0 4px; }
  p { margin: 4px 0; }
  ul, ol { margin: 4px 0; padding-left: 20px; }
  li { margin: 2px 0; }
  code { background: var(--code); padding: 1px 4px; border-radius: 4px;
         font: 12px/1.4 ui-monospace, SFMono-Regular, Consolas, monospace; }
  pre { background: var(--code); padding: 8px 10px; border-radius: 6px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  .err { color: var(--err); }
</style>
</head>
<body>
<header><h1 id="title">Daily digest</h1><span id="updated"></span></header>
<div id="status"></div>
<main id="body"><p style="color:var(--muted)">Loading…</p></main>
<script>
// Renders digest.md (written by the daily-digest agent) as HTML.
// The digest quotes domain names, hostnames and log text, so every string is
// HTML-escaped before any markup is added; nothing from the file is ever
// inserted as raw HTML.
const STALE_HOURS = 26;      // the digest runs daily; older than this means a missed run
const RELOAD_MINUTES = 10;

function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// Inline markup on an already-escaped string: `code`, **bold**, *italic*.
function inline(s) {
  const parts = esc(s).split(/(`[^`]+`)/);
  return parts.map((p, i) => {
    if (i % 2) return '<code>' + p.slice(1, -1) + '</code>';
    return p.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
            .replace(/(^|[\s(])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>');
  }).join('');
}

function render(md) {
  const lines = md.replace(/\r/g, '').split('\n');
  const out = [];
  let list = null, para = [], fence = null, code = [];
  const flushPara = () => { if (para.length) { out.push('<p>' + inline(para.join(' ')) + '</p>'); para = []; } };
  const closeList = () => { if (list) { out.push('</' + list + '>'); list = null; } };

  for (const line of lines) {
    if (fence !== null) {
      if (line.startsWith(fence)) { out.push('<pre><code>' + esc(code.join('\n')) + '</code></pre>'); fence = null; code = []; }
      else code.push(line);
      continue;
    }
    let m;
    if ((m = line.match(/^(`{3,}|~{3,})/))) { flushPara(); closeList(); fence = m[1]; continue; }
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) {
      flushPara(); closeList();
      const lvl = Math.min(m[1].length + 1, 4);   // # -> h2, ## -> h3 ... (page title is the h1)
      out.push('<h' + lvl + '>' + inline(m[2]) + '</h' + lvl + '>');
      continue;
    }
    if ((m = line.match(/^\s*([-*+]|\d+[.)])\s+(.*)$/))) {
      flushPara();
      const type = /\d/.test(m[1]) ? 'ol' : 'ul';
      if (list !== type) { closeList(); out.push('<' + type + '>'); list = type; }
      out.push('<li>' + inline(m[2]) + '</li>');
      continue;
    }
    if (/^\s*$/.test(line)) { flushPara(); closeList(); continue; }
    if (/^\s*(-{3,}|\*{3,})\s*$/.test(line)) { flushPara(); closeList(); continue; }
    if (list && /^\s{2,}\S/.test(line)) {          // continuation of a list item
      out[out.length - 1] = out[out.length - 1].replace(/<\/li>$/, ' ' + inline(line.trim()) + '</li>');
      continue;
    }
    closeList(); para.push(line.trim());
  }
  if (fence !== null) out.push('<pre><code>' + esc(code.join('\n')) + '</code></pre>');
  flushPara(); closeList();
  return out.join('\n');
}

// Pull out the title line and the All clear / Needs attention block so they can
// be shown in the header and the coloured status box; the rest renders below.
function split(md) {
  const lines = md.replace(/\r/g, '').split('\n');
  let title = null, status = [], kind = '', i = 0;
  while (i < lines.length && !lines[i].trim()) i++;
  if (i < lines.length && /^#\s+/.test(lines[i])) { title = lines[i].replace(/^#\s+/, ''); i++; }
  while (i < lines.length && !lines[i].trim()) i++;
  const first = (lines[i] || '').replace(/^[*_\s]+|[*_\s]+$/g, '');
  if (/^all clear/i.test(first)) kind = 'ok';
  else if (/^needs attention/i.test(first)) kind = 'warn';
  if (kind) {
    // Status block runs until the first blank line or heading after it.
    while (i < lines.length && lines[i].trim() && !/^#/.test(lines[i])) status.push(lines[i++]);
  }
  return { title, kind, status: status.join('\n'), rest: lines.slice(i).join('\n') };
}

function age(ms) {
  const h = ms / 3600000;
  if (h < 1) return Math.max(1, Math.round(ms / 60000)) + ' min ago';
  if (h < 48) return Math.round(h) + ' h ago';
  return Math.round(h / 24) + ' days ago';
}

async function load() {
  const upd = document.getElementById('updated');
  try {
    const r = await fetch('digest.md', { cache: 'no-store' });
    if (!r.ok) throw new Error(r.status === 404 ? 'no digest published yet' : 'HTTP ' + r.status);
    const md = await r.text();
    const d = split(md);
    document.getElementById('title').textContent = d.title || 'Daily digest';
    const st = document.getElementById('status');
    st.className = d.kind;
    st.innerHTML = d.kind ? render(d.status) : '';
    document.getElementById('body').innerHTML = render(d.kind ? d.rest : md);
    const lm = r.headers.get('Last-Modified');
    if (lm) {
      const t = new Date(lm), ms = Date.now() - t;
      upd.textContent = 'Updated ' + t.toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) + ' (' + age(ms) + ')';
      upd.className = ms > STALE_HOURS * 3600000 ? 'stale' : '';
      if (upd.className) upd.textContent += ' · stale, check the daily-digest run';
    }
  } catch (e) {
    document.getElementById('body').innerHTML = '<p class="err">Could not load the digest: ' + esc(String(e.message || e)) + '</p>';
  }
}
load();
setInterval(load, RELOAD_MINUTES * 60000);
</script>
</body>
</html>
HTML
chmod 644 /srv/digest/www/index.html

cat > /etc/systemd/system/digest-viewer.service <<'UNIT'
[Unit]
Description=Daily digest viewer (static, read-only)
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
Group=nogroup
ExecStart=/usr/bin/python3 -m http.server 8090 --bind 0.0.0.0 --directory /srv/digest/www
Restart=on-failure
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ssh digest-viewer
systemctl restart digest-viewer
sleep 1
curl -s -o /dev/null -w 'viewer: HTTP %{http_code}\n' http://127.0.0.1:8090/
