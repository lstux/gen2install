#!/bin/sh
# Publie des sites statiques GitHub (memes confs que lslng : sites.d/*.json) dans un
# dossier local de ton choix. Chaque site devient <DEST>/<name>/ (index.html a la racine).
#
# Usage : publish.sh [-d DEST] [-l] [conf.json ...]
#         publish.sh                   tous les sites de sites.d/
#         publish.sh -d ~/web sites.d/mathpulse.json
#         publish.sh -l                liste les sites deja publies dans DEST
#
# DEST : -d, ou DEST= dans github-pages.conf (a cote de ce script), ou ~/github-pages-sites.
#
# ATTENTION : la commande "build" de chaque conf est lancee sur ta machine, dans un clone
# frais du depot. Ne lance que des depots dont tu connais le contenu.
#
# Dependances : sh, git, jq, et ce que demandent les builds (python3, Pillow pour Slovingo...).

set -eu
umask 022

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST=""
[ -f "${HERE}/github-pages.conf" ] && . "${HERE}/github-pages.conf"
DEST="${DEST:-${HOME}/github-pages-sites}"

die() { printf "ERREUR : %s\n" "$*" >&2; exit 1; }
usage() {
  printf "Usage : %s [-d DEST] [-l] [conf.json ...]\n" "$(basename "$0")" >&2
  printf "  sans conf : tous les sites de %s/sites.d/\n" "${HERE}" >&2
  exit 1
}

valid_name() {
  case "$1" in ''|-*|*-|*[!a-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 40 ]
}

list_sites() {
  for d in "${DEST}"/*/; do
    [ -f "${d}index.html" ] || continue
    printf "%-20s %s\n" "$(basename "${d}")" "${d%/}"
  done
}

publish_one() {
  conf="$1"
  [ -f "${conf}" ] || die "conf introuvable : ${conf}"
  jq -e . "${conf}" >/dev/null 2>&1 || die "JSON invalide : ${conf}"
  get() { jq -r --arg k "$1" '.[$k] // empty' "${conf}"; }

  repo="$(get repo)"; branch="$(get branch)"; name="$(get name)"; output="$(get output)"
  [ -n "${repo}" ] || die "${conf} : champ repo obligatoire"
  repo="${repo%.git}"
  printf '%s' "${repo}" | grep -Eq '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
    || die "${conf} : repo doit etre https://github.com/<owner>/<repo>"
  [ -n "${name}" ] || name="$(printf '%s' "${repo##*/}" | tr 'A-Z' 'a-z')"
  valid_name "${name}" || die "${conf} : nom de site invalide : '${name}'"
  printf '%s' "${branch}" | grep -Eq '^[A-Za-z0-9._/-]*$' || die "${conf} : caracteres interdits dans branch"
  case "${branch}" in *..*|-*) die "${conf} : branch invalide" ;; esac
  output="${output:-.}"
  case "${output}" in /*|*..*) die "${conf} : output invalide" ;; esac

  mkdir -p "${DEST}"
  work="$(mktemp -d "${TMPDIR:-/tmp}/ghpages.XXXXXX")"
  trap 'rm -rf "${work}"' EXIT INT TERM
  src="${work}/src"

  printf "[%s] clone : %s %s\n" "${name}" "${repo}" "${branch:+(${branch})}"
  GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --single-branch ${branch:+--branch "${branch}"} \
    -c advice.detachedHead=false "${repo}.git" "${src}" || die "${name} : git clone impossible"

  jq -r 'if (.build|type)=="array" then .build[] elif (.build|type)=="string" then .build else empty end' \
    "${conf}" > "${work}/build.list"
  while IFS= read -r cmd <&3; do
    printf "[%s] build : %s\n" "${name}" "${cmd}"
    ( cd "${src}" && timeout 900 sh -ec "${cmd}" </dev/null ) || die "${name} : build en echec : ${cmd}"
  done 3< "${work}/build.list"

  root="${src}/${output}"
  [ -d "${root}" ] || die "${name} : dossier output absent : ${output}"
  [ -f "${root}/index.html" ] || die "${name} : pas d'index.html a la racine de ${output} : rien publie"

  # Pas de liens symboliques, de depot git ni de CI dans ce qui est publie
  nl="$(find "${root}" -type l | wc -l)"
  [ "${nl}" -eq 0 ] || { printf "[%s] attention : %s lien(s) symbolique(s) supprime(s)\n" "${name}" "${nl}"; find "${root}" -type l -delete; }
  rm -rf "${root}/.git" "${root}/.github"
  chmod -R u=rwX,go=rX "${root}"

  # Bascule : staging a cote de la cible, puis echange de dossiers
  stage="${DEST}/.staging-${name}"
  rm -rf "${stage}"
  mv "${root}" "${stage}"
  rm -rf "${DEST}/${name}.old"
  [ -e "${DEST}/${name}" ] && mv "${DEST}/${name}" "${DEST}/${name}.old"
  mv "${stage}" "${DEST}/${name}"
  rm -rf "${DEST}/${name}.old"
  printf "[%s] publie : %s\n" "${name}" "${DEST}/${name}"

  rm -rf "${work}"
  trap - EXIT INT TERM
}

confs=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) [ $# -ge 2 ] || usage; DEST="$2"; shift 2 ;;
    -l) list_sites; exit 0 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *)  confs="${confs} $1"; shift ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git requis"
command -v jq  >/dev/null 2>&1 || die "jq requis"

if [ -z "${confs}" ]; then
  confs="$(ls -1 "${HERE}"/sites.d/*.json)"
fi

for c in ${confs}; do publish_one "${c}"; done
