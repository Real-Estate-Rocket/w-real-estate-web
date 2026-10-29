#!/usr/bin/env bash
# Segunda parte del agente de diagnóstico: hace lo que es seguro hacer sin preguntar y publica el informe.
#   · Si la última publicación de Pages falló, la vuelve a lanzar.
#   · Si el agente ha cambiado archivos, los sube a una rama y abre una solicitud de cambios para revisar
#     (nunca toca main directamente).
#   · Publica el informe en la incidencia (o, sin incidencia, en el resumen de la ejecución).
# Variables: GH_TOKEN, GH_REPO, INCIDENCIA, PISTAS, REHACER, CON_IA, INFORME, PARCHE, ARCHIVOS,
#            RESULTADO_ANALISIS, EJECUCION.
set -u
acciones=""

if [ "${REHACER:-}" = "si" ]; then
  if gh api -X POST "repos/$GH_REPO/pages/builds" >/dev/null 2>&1; then
    acciones+="- He vuelto a lanzar la publicación de GitHub Pages porque la última había fallado. Tarda uno o dos minutos."$'\n'
  else
    acciones+="- La última publicación de GitHub Pages falló y no he podido relanzarla. Se relanza haciendo cualquier commit en main."$'\n'
  fi
fi

if [ -n "${PARCHE:-}" ]; then
  rama="agente/arreglo-${INCIDENCIA:-manual}-${GITHUB_RUN_ID}"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git switch -q -c "$rama"
  if echo "$PARCHE" | base64 -d | gunzip | git apply --index && \
     git commit -q -m "Arreglo propuesto por el agente de diagnóstico${INCIDENCIA:+ (incidencia #$INCIDENCIA)}" && \
     git push -q origin "$rama"; then
    cuerpo="Arreglo propuesto automáticamente por el agente de diagnóstico${INCIDENCIA:+ para la incidencia #$INCIDENCIA}.

Revíselo antes de aprobarlo: al aprobarlo se publica en wrealestate.es.

Archivos:
\`\`\`
${ARCHIVOS}
\`\`\`

Ejecución: ${EJECUCION}"
    if url=$(gh pr create --base main --head "$rama" --title "Arreglo de la caída de la web${INCIDENCIA:+ (incidencia #$INCIDENCIA)}" --body "$cuerpo" 2>/dev/null); then
      acciones+="- He preparado el arreglo en una solicitud de cambios. **Revísela y apruébela** para publicarlo: ${url}"$'\n'
    else
      acciones+="- He subido el arreglo a la rama «${rama}». GitHub no deja a la automatización abrir la solicitud de cambios; se abre con un clic aquí: https://github.com/${GH_REPO}/compare/main...${rama}?expand=1"$'\n'
    fi
  else
    acciones+="- El agente propuso cambios en archivos, pero no se han podido aplicar. Están en el registro de la ejecución."$'\n'
  fi
fi

if [ "${CON_IA:-}" = "si" ] && [ -n "${INFORME:-}" ]; then
  analisis="$INFORME"
elif [ "${CON_IA:-}" = "si" ]; then
  analisis="Codex no ha devuelto ningún análisis (resultado del análisis: ${RESULTADO_ANALISIS:-desconocido}). Revise el registro de la ejecución."
else
  analisis="Codex no ha intervenido: falta el secreto OPENAI_API_KEY en el repositorio. Lo añade un administrador en Settings → Secrets and variables → Actions."
fi

informe="## Diagnóstico automático

### Comprobaciones automáticas
${PISTAS:-- No se han podido hacer las comprobaciones (resultado: ${RESULTADO_ANALISIS:-desconocido}).}

### Análisis de Codex
${analisis}

### Acciones
${acciones:-- Ninguna automática.
}
Datos completos y registro: ${EJECUCION}"

if [ -n "${INCIDENCIA:-}" ]; then
  gh issue comment "$INCIDENCIA" --body "$informe"
fi
echo "$informe" >> "$GITHUB_STEP_SUMMARY"
