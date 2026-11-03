#!/bin/sh
# Genere www/lslinux.org/index.html (page d'accueil) depuis sites/sites.d/*.json.
# A lancer sur le PC (jq requis). Champs de presentation lus dans chaque conf :
#   title (defaut : nom du site), desc, icon (emoji), listed:false pour masquer.
# Le lien est https://<name>.lslinux.org/ (name = champ name ou depot en minuscules).
# Usage : sh sites/gen-index.sh [sortie]   (defaut www/lslinux.org/index.html)

set -eu
D="$(dirname "$0")"
OUT="${1:-${D}/../www/lslinux.org/index.html}"
command -v jq >/dev/null 2>&1 || { echo "jq requis" >&2; exit 1; }

cards="$(for f in "${D}"/sites.d/*.json; do
  jq -r '
    select(.listed != false)
    | (.name // (.repo | sub("\\.git$";"") | split("/") | last | ascii_downcase)) as $n
    | "<a class=\"card\" href=\"https://\($n).lslinux.org/\"><span class=\"ico\" aria-hidden=\"true\">\(.icon // "🌐")</span><span class=\"txt\"><b>\(.title // $n | @html)</b><small>\(.desc // "" | @html)</small></span></a>"
  ' "${f}"
done | sort)"

cat > "${OUT}" <<HTML
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>lslinux.org</title>
<meta name="description" content="Hébergement perso, Linux, électronique, embarqué.">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cellipse cx='16' cy='18' rx='10' ry='12' fill='%231d2433'/%3E%3Cellipse cx='16' cy='21' rx='6' ry='8' fill='%23e8eef7'/%3E%3Cpath d='M12 13l4 4 4-4z' fill='%23ff9f1c'/%3E%3C/svg%3E">
<style>
:root{--bg:#0b1220;--fg:#e8eef7;--mut:#8da2c0;--acc:#ff9f1c;--line:#1c2a44;--card:#111b30}
*{box-sizing:border-box}
html{background:var(--bg);color:var(--fg)}
body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2rem;padding:2rem 1rem;
font:16px/1.4 system-ui,sans-serif;
background:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cg fill='none' stroke='%231c2a44' stroke-width='2'%3E%3Cpath d='M0 40h50l12 12h98M80 0v70l14 14v76M0 120h30l12-12h60'/%3E%3C/g%3E%3Cg fill='%231c2a44'%3E%3Ccircle cx='62' cy='52' r='4'/%3E%3Ccircle cx='94' cy='84' r='4'/%3E%3Ccircle cx='42' cy='108' r='4'/%3E%3C/g%3E%3C/svg%3E") var(--bg)}
header{text-align:center}
svg.tux{width:clamp(110px,26vw,170px);height:auto;filter:drop-shadow(0 0 28px #ff9f1c33)}
.wave{transform-origin:128px 82px;animation:wave 2.2s ease-in-out infinite}
@keyframes wave{0%,100%{transform:rotate(0)}50%{transform:rotate(-16deg)}}
h1{margin:.4rem 0 0;font:600 clamp(1.6rem,5vw,2.4rem)/1.1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.02em}
h1 span{color:var(--acc)}
nav{display:grid;grid-template-columns:repeat(auto-fit,minmax(15rem,1fr));gap:.9rem;width:min(52rem,100%)}
a.card{display:flex;gap:.9rem;align-items:center;padding:.9rem 1.1rem;background:var(--card);border:1px solid var(--line);border-radius:.7rem;color:inherit;text-decoration:none;transition:transform .15s,border-color .15s}
a.card:hover,a.card:focus-visible{transform:translateY(-2px);border-color:var(--acc);outline:none}
.ico{font-size:1.9rem;line-height:1}
.txt{display:flex;flex-direction:column}
.txt b{font-size:1.05rem}
.txt small{color:var(--mut)}
footer{color:var(--mut);font:.8rem ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-reduced-motion:reduce){a.card{transition:none}.wave{animation:none}}
</style>
</head>
<body>
<header>
<svg class="tux" viewBox="0 0 160 180" role="img" aria-label="Un pingouin qui salue">
<defs>
<linearGradient id="bd" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#34436b"/><stop offset="1" stop-color="#141b2e"/></linearGradient>
<linearGradient id="bl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#cfd9ea"/></linearGradient>
</defs>
<ellipse cx="80" cy="170" rx="44" ry="6" fill="#000" opacity=".28"/>
<ellipse cx="56" cy="162" rx="17" ry="7" fill="#ff9f1c"/>
<ellipse cx="104" cy="162" rx="17" ry="7" fill="#ff9f1c"/>
<ellipse cx="32" cy="104" rx="11" ry="30" transform="rotate(16 32 82)" fill="#2e3c66"/>
<ellipse cx="80" cy="96" rx="50" ry="66" fill="url(#bd)"/>
<ellipse cx="80" cy="120" rx="33" ry="38" fill="url(#bl)"/>
<g class="wave"><ellipse cx="128" cy="104" rx="11" ry="30" transform="rotate(-28 128 82)" fill="#2e3c66"/></g>
<circle cx="49" cy="70" r="7" fill="#ff7a90" opacity=".4"/>
<circle cx="111" cy="70" r="7" fill="#ff7a90" opacity=".4"/>
<circle cx="64" cy="54" r="11" fill="#fff"/><circle cx="96" cy="54" r="11" fill="#fff"/>
<circle cx="66" cy="55" r="5.5" fill="#0b1220"/><circle cx="94" cy="55" r="5.5" fill="#0b1220"/>
<circle cx="68" cy="52" r="2" fill="#fff"/><circle cx="96" cy="52" r="2" fill="#fff"/>
<path d="M68 66Q80 59 92 66Q92 80 80 85Q68 80 68 66Z" fill="#ffb02e"/>
<path d="M71 73Q80 78 89 73" fill="none" stroke="#e07f00" stroke-width="2" stroke-linecap="round"/>
</svg>
<h1>lslinux<span>.org</span></h1>
</header>
<nav>
${cards}
</nav>
<footer>root@lslng:~# _</footer>
</body>
</html>
HTML
printf "Ecrit : %s (%s sites)\n" "${OUT}" "$(printf '%s\n' "${cards}" | grep -c '<a ')"
