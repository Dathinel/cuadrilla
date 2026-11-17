# Fondo legal

No es asesoría legal: resume la licencia y lo que hay que comprobar antes de publicar una versión.

## Licencia del código propio

MIT ([`LICENSE`](../LICENSE)). Todo el código es propio: PowerShell, HTML, CSS y JavaScript. La Oficina dibuja su pixel art por código, sin sprites, fuentes ni imágenes de terceros. No se redistribuye ningún binario: los CLI los instala cada persona con su cuenta y sus términos ([`LICENCIAS.md`](../LICENCIAS.md)).

## Marcas

«Claude», «ChatGPT», «Codex», «Gemini», «Antigravity» y «Devin» se nombran solo para decir con qué programas funciona Cuadrilla (uso nominativo). No se usan sus logotipos ni se sugiere respaldo de Anthropic, OpenAI, Google o Cognition. Los personajes de la Oficina son propios.

## Antes de publicar

1. `git log --all --name-only` no muestra nada de `datos\` salvo `mesa.ejemplo.json`.
2. `git grep -n -i -E "ghp_|github_pat_|password|@gmail|C:\\\\Users\\\\"` no encuentra datos reales (las cadenas falsas de las pruebas y los patrones de `Mesa-Ocultar` son ficticios).
3. Ningún archivo versionado nombra a una persona, una carpeta de un PC concreto, un proyecto privado ni un identificador de sesión.
4. Las capturas, si las hay, se hacen con datos de demostración.
