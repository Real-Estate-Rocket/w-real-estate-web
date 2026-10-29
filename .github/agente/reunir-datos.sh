#!/usr/bin/env bash
# Reúne en .diagnostico/ lo necesario para diagnosticar una caída de wrealestate.es:
#   datos.md  → todo lo medido (lo lee el agente).
#   pistas.md → conclusiones automáticas, sin IA (salen en la incidencia aunque no haya agente).
# Lo usa .github/workflows/diagnostico.yml. Necesita GH_TOKEN (lectura de Pages y Actions) y GH_REPO;
# INCIDENCIA es opcional (número de la incidencia «Web caída»).
set -u
D=.diagnostico
mkdir -p "$D"
DATOS="$D/datos.md"
PISTAS="$D/pistas.md"
: > "$DATOS"
: > "$PISTAS"
pista() { echo "- $1" >> "$PISTAS"; }
bloque() { { echo; echo "## $1"; echo '```'; cat; echo '```'; } >> "$DATOS"; }
command -v dig >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq dnsutils; } >/dev/null 2>&1

echo "# Datos medidos el $(TZ=Europe/Madrid date '+%d/%m/%Y a las %H:%M:%S') (hora de España)" >> "$DATOS"

if [ -n "${INCIDENCIA:-}" ]; then
  gh issue view "$INCIDENCIA" --json title,body,createdAt --jq '"Título: \(.title)\nAbierta: \(.createdAt)\n\n\(.body)"' 2>&1 | bloque "Aviso del vigilante (incidencia #$INCIDENCIA)"
fi

# 1. Respuestas HTTP (sin seguir redirecciones, y el título de la página final)
URLS="https://wrealestate.es/ https://wrealestate.es/comprar/ https://wrealestate.es/en/ https://www.wrealestate.es/ http://wrealestate.es/ https://real-estate-rocket.github.io/w-real-estate-web/"
for url in $URLS; do
  echo "### $url"
  curl -sS -I --max-time 20 "$url" 2>&1 | grep -iE '^(HTTP|location|server|content-type|cache-control|last-modified|x-github-request-id)' | tr -d '\r'
  echo "Título tras redirecciones: $(curl -sS -L --max-time 20 "$url" 2>/dev/null | grep -o '<title>[^<]*' | head -1 | sed 's/<title>//')"
  echo
done | bloque "Respuestas HTTP"
estado() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" || true; }
portada=$(estado https://wrealestate.es/)
githubio=$(estado https://real-estate-rocket.github.io/w-real-estate-web/)
if [ "$portada" != "200" ]; then
  pista "La portada https://wrealestate.es/ responde **${portada}** (debería ser 200)."
  if [ "$githubio" = "200" ]; then
    pista "En cambio, https://real-estate-rocket.github.io/w-real-estate-web/ responde 200 sin redirigir al dominio: la web se publica, pero GitHub no la tiene asociada a wrealestate.es."
  fi
fi

# 2. DNS
ESPERADAS="185.199.108.153 185.199.109.153 185.199.110.153 185.199.111.153"
{
  for s in 1.1.1.1 8.8.8.8; do
    echo "== Consultando a $s"
    echo "A wrealestate.es: $(dig +short A wrealestate.es @$s | sort | tr '\n' ' ')"
    echo "AAAA wrealestate.es: $(dig +short AAAA wrealestate.es @$s | sort | tr '\n' ' ')"
    echo "CNAME www.wrealestate.es: $(dig +short CNAME www.wrealestate.es @$s)"
  done
  echo "NS: $(dig +short NS wrealestate.es | sort | tr '\n' ' ')"
  echo "TXT _github-pages-challenge-real-estate-rocket: $(dig +short TXT _github-pages-challenge-real-estate-rocket.wrealestate.es)"
} | bloque "DNS"
a=$(dig +short A wrealestate.es @1.1.1.1 | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$a" != "$ESPERADAS" ]; then
  pista "DNS: los registros A de wrealestate.es son «${a:-ninguno}»; deberían ser los cuatro de GitHub Pages (185.199.108.153 · 109 · 110 · 111), con la nube gris. Se corrige en Cloudflare → DNS."
fi
www=$(dig +short CNAME www.wrealestate.es @1.1.1.1)
if [ "$www" != "real-estate-rocket.github.io." ]; then
  pista "DNS: www.wrealestate.es apunta a «${www:-nada}»; debería ser un CNAME a real-estate-rocket.github.io (nube gris)."
fi

# 3. Certificado HTTPS
cert=$(echo | timeout 20 openssl s_client -servername wrealestate.es -connect wrealestate.es:443 2>/dev/null | openssl x509 -noout -subject -issuer -enddate 2>&1)
echo "$cert" | bloque "Certificado HTTPS"
caduca=$(echo "$cert" | sed -n 's/^notAfter=//p')
if [ -n "$caduca" ]; then
  dias=$(( ( $(date -d "$caduca" +%s) - $(date +%s) ) / 86400 ))
  if [ "$dias" -lt 7 ]; then
    pista "Certificado HTTPS: caduca en $dias días ($caduca). GitHub lo renueva solo si el dominio y el DNS están bien; si no, en Settings → Pages quitar y volver a marcar «Enforce HTTPS»."
  fi
else
  pista "Certificado HTTPS: no se ha podido leer el certificado de wrealestate.es."
fi

# 4. Configuración de GitHub Pages y últimas publicaciones
pages=$(gh api "repos/$GH_REPO/pages" 2>&1)
{ echo "$pages" | jq 'del(.source)' 2>/dev/null || echo "$pages"; } | bloque "Configuración de GitHub Pages"
if echo "$pages" | jq -e '.url' >/dev/null 2>&1; then
  cname=$(echo "$pages" | jq -r '.cname // "ninguno"')
  dominio=$(echo "$pages" | jq -r '.protected_domain_state // "desconocido"')
  if [ "$cname" != "wrealestate.es" ]; then
    pista "GitHub Pages: el dominio personalizado es «$cname» y debería ser wrealestate.es. Fue la causa de la caída de octubre. Un administrador debe ir a Settings → Pages → Custom domain, escribir wrealestate.es, guardar y marcar «Enforce HTTPS»."
  fi
  if [ "$dominio" != "verified" ] && [ "$dominio" != "desconocido" ]; then
    pista "GitHub Pages: el dominio está «$dominio» (debería estar «verified»). Revisar en la organización Real-Estate-Rocket → Settings → Pages → Verified domains, y que siga en Cloudflare el TXT _github-pages-challenge-real-estate-rocket."
  fi
else
  pista "No se ha podido leer la configuración de GitHub Pages: $(echo "$pages" | head -c 200)"
fi
gh api "repos/$GH_REPO/pages/builds?per_page=5" --jq '.[] | "\(.created_at)  \(.status)  \(.commit[0:7])  \(.error.message // "")"' 2>&1 | bloque "Últimas publicaciones de Pages"
gh run list --workflow pages-build-deployment -L 5 2>&1 | bloque "Últimas ejecuciones de «pages build and deployment»"
ultimo=$(gh api "repos/$GH_REPO/pages/builds/latest" --jq '.status + "|" + (.error.message // "")' 2>/dev/null)
if [ "${ultimo%%|*}" = "errored" ]; then
  pista "GitHub Pages: la última publicación falló («${ultimo#*|}»)."
  echo "rehacer=si" >> "$GITHUB_OUTPUT"
fi

# 5. Archivos clave del repositorio
{
  echo "CNAME: $(cat CNAME 2>/dev/null || echo 'NO EXISTE')"
  for f in index.html 404.html .nojekyll comprar/index.html en/index.html propiedades.json; do
    if [ -e "$f" ]; then echo "$f: $(wc -c < "$f") bytes"; else echo "$f: NO EXISTE"; fi
  done
} | bloque "Archivos clave del repositorio"
if [ "$(tr -d '[:space:]' < CNAME 2>/dev/null)" != "wrealestate.es" ]; then
  pista "Repositorio: el archivo CNAME no existe o no dice wrealestate.es. Sin él, GitHub desconecta el dominio."
fi
if [ ! -s index.html ] || [ "$(wc -c < index.html)" -lt 5000 ]; then
  pista "Repositorio: index.html no existe o está casi vacío."
fi
git log -n 15 --date=format:'%d/%m/%Y %H:%M' --format='%h · %ad · %an · %s' --stat=100 2>&1 | head -200 | bloque "Últimos commits"

# 6. Estado de GitHub
gs=$(curl -s --max-time 15 https://www.githubstatus.com/api/v2/components.json)
echo "$gs" | jq -r '.components[] | select(.name | test("Pages|Actions|Git Operations|API Requests")) | "\(.name): \(.status)"' 2>&1 | bloque "Estado de GitHub (githubstatus.com)"
servicio=$(echo "$gs" | jq -r '.components[] | select(.name == "Pages") | .status' 2>/dev/null)
if [ -n "$servicio" ] && [ "$servicio" != "operational" ]; then
  pista "GitHub: el servicio Pages figura como «$servicio» en https://www.githubstatus.com. Si es así, la caída es de GitHub y solo queda esperar."
fi

if [ ! -s "$PISTAS" ]; then
  if [ "$portada" = "200" ]; then
    pista "Ahora mismo todo responde bien: la portada da 200 y ninguna comprobación encuentra nada raro. Pudo ser un corte momentáneo."
  else
    pista "Ninguna comprobación automática explica el fallo."
  fi
fi
{ echo "pistas<<FIN_PISTAS"; cat "$PISTAS"; echo "FIN_PISTAS"; } >> "$GITHUB_OUTPUT"
cat "$PISTAS"
