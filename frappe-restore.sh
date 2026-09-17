#!/usr/bin/env bash
# =====================================================================
#  iZONE ENTERPRISE - RESTAURACION
#  Gestor de restauraciones para Frappe / ERPNext
#  Origenes soportados: Unidad de Red (CIFS) y Google Drive (rclone)
#  Restaura los respaldos producidos por iZone ENTERPRISE - BACKUPS
#  Version: 1.0.0
#
#  Uso:  sudo ./frappe-restore.sh
# =====================================================================
# Las configuraciones se cargan en tiempo de ejecucion; shellcheck no puede seguirlas.
# shellcheck disable=SC1090
set -uo pipefail

APP_DIR="/etc/izone-restore"
BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/izone-restore"
PREVIO_BASE="/var/backups/izone-restore"
BACKUP_APP_DIR="/etc/izone-backup"      # gestor de respaldos, si esta en este servidor
CRON_TAG="izone-restore"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
BASE="${HOST_SHORT}-restore"
RCLONE_ESPERA=150
NAV_ON=0          # 1 dentro de los asistentes: habilita v=volver, x=cancelar

C_R=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
C_CY=$'\033[0;36m'; C_GR=$'\033[0;32m'; C_RD=$'\033[0;31m'; C_YL=$'\033[0;33m'

say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "  ${C_GR}[OK]${C_R}    $*"; }
err()  { printf '%b\n' "  ${C_RD}[ERROR]${C_R} $*"; }
warn() { printf '%b\n' "  ${C_YL}[AVISO]${C_R} $*"; }
info() { printf '%b\n' "  ${C_CY}[INFO]${C_R}  $*"; }
hr()   { printf '%b\n' "${C_DIM}  ---------------------------------------------------------------${C_R}"; }

banner_izone() {
  say "
${C_CY}${C_B}  ██╗${C_R}███████╗ ██████╗ ███╗   ██╗███████╗
${C_CY}${C_B}  ██║${C_R}╚══███╔╝██╔═══██╗████╗  ██║██╔════╝
${C_CY}${C_B}  ██║${C_R}  ███╔╝ ██║   ██║██╔██╗ ██║█████╗
${C_CY}${C_B}  ██║${C_R} ███╔╝  ██║   ██║██║╚██╗██║██╔══╝
${C_CY}${C_B}  ██║${C_R}███████╗╚██████╔╝██║ ╚████║███████╗
${C_CY}${C_B}  ╚═╝${C_R}╚══════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
${C_B}    E N T E R P R I S E  -  R E S T A U R A C I O N${C_R}
"
  return 0
}

pantalla() {
  clear
  banner_izone
  hr
  printf '%b\n' "  ${C_B}$1${C_R}"
  printf '%b\n' "  ${C_DIM}servidor: ${HOST_SHORT}${C_R}"
  hr
  echo
}

enter() { echo; read -rsp "  Presione ENTER para continuar..." _ || true; echo; }
fin_entrada() { echo; err "Entrada terminada. Saliendo del gestor."; exit 1; }

# --------------------------- Entradas --------------------------------
# Navegacion dentro de los asistentes: 'v' vuelve, 'x' cancela.
# Devuelve 0 si el valor es normal, 2 para volver, 3 para cancelar.
_nav_check() {
  [ "${NAV_ON:-0}" = "1" ] || return 0
  case "${1,,}" in
    v|volver) return 2;;
    x|cancelar) return 3;;
  esac
  return 0
}

pedir() {
  local __var="$1" __txt="$2" __def="${3-}" __in=""
  while true; do
    if [ -n "$__def" ]; then
      read -rp "  ${__txt} [${__def}]: " __in || fin_entrada
      __in="${__in:-$__def}"
    else
      read -rp "  ${__txt}: " __in || fin_entrada
    fi
    __in="$(printf '%s' "$__in" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    _nav_check "$__in"; local __n=$?
    [ "$__n" -ne 0 ] && return "$__n"
    [ -n "$__in" ] && break
    err "Este dato es obligatorio."
  done
  printf -v "$__var" '%s' "$__in"
  return 0
}

pedir_secreto() {
  local __var="$1" __txt="$2" __a="" __b=""
  while true; do
    read -rsp "  ${__txt}: " __a || fin_entrada; echo
    if [ "${NAV_ON:-0}" = "1" ] && { [ "${__a,,}" = "v" ] || [ "${__a,,}" = "x" ]; }; then
      if [ "${__a,,}" = "v" ]; then
        si_no "Escribio 'v'. Quiere volver al paso anterior?" && return 2
      else
        si_no "Escribio 'x'. Quiere cancelar el asistente?" && return 3
      fi
      continue
    fi
    [ -z "$__a" ] && { err "No puede quedar vacia."; continue; }
    read -rsp "  Confirme el dato: " __b || fin_entrada; echo
    [ "$__a" = "$__b" ] && break
    err "No coinciden, intente de nuevo."
  done
  printf -v "$__var" '%s' "$__a"
  return 0
}

si_no() {
  local r=""
  while true; do
    read -rp "  $1 (s/n): " r || fin_entrada
    case "${r,,}" in s|si|y|yes) return 0;; n|no) return 1;; *) err "Responda s o n.";; esac
  done
}

# si/no con navegacion: 0=si 1=no 2=volver 3=cancelar
si_no_nav() {
  local r=""
  while true; do
    read -rp "  $1 (s/n): " r || fin_entrada
    _nav_check "$r"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    case "${r,,}" in s|si|y|yes) return 0;; n|no) return 1;; *) err "Responda s o n.";; esac
  done
}

# Confirmacion fuerte: hay que escribir exactamente el texto indicado.
confirmar_escribiendo() {
  local esperado="$1" leido=""
  say "  ${C_DIM}Para confirmar escriba exactamente: ${C_R}${C_B}${esperado}${C_R}"
  read -rp "  Confirmacion: " leido || fin_entrada
  leido="$(printf '%s' "$leido" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ "$leido" = "$esperado" ]
}

aviso_navegacion() {
  say "  ${C_DIM}En cualquier pregunta: ${C_B}v${C_R}${C_DIM} = volver al paso anterior · ${C_B}x${C_R}${C_DIM} = cancelar${C_R}"
  echo
}

# ------------------------ Horarios y cron ----------------------------
hora_valida() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }

normalizar_hora() {
  local h="${1%%:*}" m="${1##*:}"
  printf '%02d:%02d' "$((10#$h))" "$((10#$m))"
}

ordenar_horarios() { printf '%s\n' $1 | sort -u | paste -sd' ' -; }

pedir_horarios() {
  local entrada lista t valido
  while true; do
    say "  ${C_DIM}Una o varias horas del dia separadas por coma, formato HH:MM (24 horas).${C_R}"
    say "  ${C_DIM}Ejemplo de formato: 02:00,14:00${C_R}"
    read -rp "  Horas de restauracion: " entrada || fin_entrada
    _nav_check "$entrada"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    entrada="${entrada//,/ }"
    lista=""; valido=1
    for t in $entrada; do
      if hora_valida "$t"; then
        lista="${lista}${lista:+ }$(normalizar_hora "$t")"
      else
        err "Hora invalida: '$t'"; valido=0; break
      fi
    done
    if [ "$valido" -eq 1 ] && [ -n "$lista" ]; then
      HORARIOS="$(ordenar_horarios "$lista")"; return 0
    fi
    [ -z "$lista" ] && err "Debe indicar al menos una hora."
  done
}

pedir_dias() {
  local o
  while true; do
    echo
    say "  1) Todos los dias"
    say "  2) Lunes a viernes"
    say "  3) Fin de semana (sabado y domingo)"
    say "  4) Personalizado (formato cron: 0=domingo ... 6=sabado)"
    read -rp "  Dias de ejecucion [1-4]: " o || fin_entrada
    _nav_check "$o"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    case "$o" in
      1) DIAS_CRON="*";   return 0;;
      2) DIAS_CRON="1-5"; return 0;;
      3) DIAS_CRON="6,0"; return 0;;
      4) pedir DIAS_CRON "Valor cron para dia de semana"; return 0;;
      *) err "Opcion invalida.";;
    esac
  done
}

describir_dias() {
  case "$1" in
    "*")   echo "todos los dias";;
    "1-5") echo "lunes a viernes";;
    "6,0"|"0,6") echo "sabado y domingo";;
    *)     echo "cron: $1";;
  esac
}

lineas_cron() {
  local horarios="$1" dias="$2" cmd="$3" log="$4" t m minutos horas
  minutos="$(for t in $horarios; do echo "${t##*:}"; done | sort -u)"
  for m in $minutos; do
    horas="$(for t in $horarios; do
               [ "${t##*:}" = "$m" ] && echo $((10#${t%%:*}))
             done | sort -n -u | paste -sd, -)"
    echo "$((10#$m)) ${horas} * * ${dias} ${cmd} >> ${log} 2>&1"
  done
}

cron_aplicar() {
  local tag="$1" bloque="$2" tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk \
    -v s="# >>> ${CRON_TAG}:${tag} >>>" \
    -v e="# <<< ${CRON_TAG}:${tag} <<<" \
    '$0==s {inb=1; next} $0==e {inb=0; next} inb!=1 {print}' > "$tmp"
  if [ -n "$bloque" ]; then
    {
      echo "# >>> ${CRON_TAG}:${tag} >>>"
      echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      printf '%s\n' "$bloque"
      echo "# <<< ${CRON_TAG}:${tag} <<<"
    } >> "$tmp"
  fi
  crontab "$tmp" && rm -f "$tmp"
}

cron_mostrar() {
  crontab -l 2>/dev/null | awk \
    -v s="# >>> ${CRON_TAG}:${1} >>>" \
    -v e="# <<< ${CRON_TAG}:${1} <<<" \
    '$0==s {inb=1; next} $0==e {inb=0} inb==1 {print "    " $0}'
}

# Escribe el bloque de cron solo si el trabajo es automatico; si no, lo quita.
reprogramar() {
  local conf="$1"
  ( cargar_conf "$conf"
    if [ "${AUTOMATICO:-no}" = "si" ] && [ -n "${HORARIOS:-}" ]; then
      cron_aplicar "$JOB_NOMBRE" \
        "$(lineas_cron "$HORARIOS" "$DIAS_CRON" "${BIN_DIR}/${JOB_NOMBRE}.sh" "$LOG_FILE")"
    else
      cron_aplicar "$JOB_NOMBRE" ""
    fi )
  systemctl restart cron >/dev/null 2>&1
}

# ----------------------- Configuracion -------------------------------
cargar_conf() {
  unset JOB_TIPO JOB_NOMBRE ETIQUETA ORIGEN_CONF MONTAJE_PROPIO \
        SERVIDOR SMB_PORT RECURSO SUBCARPETA UNC MOUNT_POINT CRED_FILE SMB_VERS MOUNT_OPTS \
        RCLONE_REMOTE DEST_PATH RCLONE_CONFIG \
        BENCH_PATH BENCH_USER SITE DB_CRED_FILE DB_FLAG TEMP_LOCAL \
        PREVIO PREVIO_DIR PREVIO_CONSERVAR \
        MIGRAR SCHEDULER MUTE_EMAILS \
        AUTOMATICO HORARIOS DIAS_CRON \
        LOG_FILE RCLONE_LOG STATE_FILE 2>/dev/null
  # shellcheck disable=SC1090
  . "$1"
}

guardar_conf() {
  local f="$1"; shift
  mkdir -p "$APP_DIR"; chmod 750 "$APP_DIR"
  : > "$f"
  {
    echo "# Configuracion generada por iZone ENTERPRISE - RESTAURACION"
    echo "# $(date '+%Y-%m-%d %H:%M:%S')  -  servidor: ${HOST_SHORT}"
    local kv
    for kv in "$@"; do printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}"; done
  } >> "$f"
  chmod 640 "$f"
}

set_conf() {
  local f="$1" k="$2" v="$3" tmp
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    tmp="$(mktemp)"
    awk -v k="$k" -v v="$v" 'BEGIN{FS="="} $1==k {print k "=\"" v "\""; next} {print}' "$f" > "$tmp"
    mv "$tmp" "$f"
  else
    printf '%s="%s"\n' "$k" "$v" >> "$f"
  fi
  chmod 640 "$f"
}

listar_confs() { ls -1 "$APP_DIR"/*.conf 2>/dev/null; }

# Confs del gestor de respaldos presentes en este servidor, filtradas por tipo.
listar_confs_respaldo() {
  local tipo="${1:-}" c t
  for c in "$BACKUP_APP_DIR"/*.conf; do
    [ -f "$c" ] || continue
    t="$( . "$c" >/dev/null 2>&1; printf '%s' "${JOB_TIPO:-}" )"
    [ -z "$tipo" ] || [ "$t" = "$tipo" ] || continue
    printf '%s\n' "$c"
  done
}

resumen_conf_respaldo() {   # imprime "etiqueta|destino"
  ( . "$1" >/dev/null 2>&1
    if [ "${JOB_TIPO:-}" = "red" ]; then
      printf '%s|%s\n' "${ETIQUETA:-?}" "${UNC:-?}"
    else
      printf '%s|%s\n' "${ETIQUETA:-?}" "${RCLONE_REMOTE:-?}:${DEST_PATH:-}"
    fi )
}

pedir_etiqueta() {
  local e
  say "  ${C_DIM}Etiqueta corta que identifique esta restauracion. Se usa en el nombre${C_R}"
  say "  ${C_DIM}del script, la configuracion y el log, para que quien de mantenimiento${C_R}"
  say "  ${C_DIM}sepa de un vistazo cual es. Solo minusculas, numeros y guion.${C_R}"
  say "  ${C_DIM}Ejemplos: staging-diario, copia-capacitacion, recuperacion${C_R}"
  while true; do
    pedir e "Etiqueta del trabajo" || return $?
    e="${e,,}"; e="${e// /-}"; e="${e//_/-}"
    if ! [[ "$e" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      err "Etiqueta invalida. Use minusculas, numeros y guion."
      continue
    fi
    if [ -f "${APP_DIR}/${BASE}-${e}.conf" ]; then
      err "Ya existe un trabajo con la etiqueta '${e}'."
      continue
    fi
    ETIQUETA="$e"; JOB="${BASE}-${e}"; return 0
  done
}

# ------------------------------ Sistema ------------------------------
requiere_root() {
  if [ "$(id -u)" -ne 0 ]; then
    pantalla "PERMISOS INSUFICIENTES"
    err "Este gestor debe ejecutarse como root."
    say  "  Vuelva a iniciarlo con:  ${C_B}sudo $0${C_R}"
    echo; exit 1
  fi
}

asegurar_paquete() {
  local pkg="$1" cmd="$2"
  command -v "$cmd" >/dev/null 2>&1 && { ok "'$pkg' ya esta instalado."; return 0; }
  info "Instalando '$pkg'..."
  apt-get update -qq && apt-get install -y "$pkg" >/dev/null 2>&1
  if command -v "$cmd" >/dev/null 2>&1; then ok "'$pkg' instalado."; return 0
  else err "No se pudo instalar '$pkg'."; return 1; fi
}

# ========================= AYUDAS DE RED =============================
puerto_abierto() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }

explicar_error_mount() {
  local s="$1"
  case "$s" in
    *"error(13)"*)
      err "Permiso denegado."
      say "    ${C_DIM}Revise usuario, contrasena, dominio, y que ese usuario tenga${C_R}"
      say "    ${C_DIM}al menos permiso de Lectura sobre la carpeta compartida.${C_R}"
      say "    ${C_DIM}La contrasena va sin comillas en el archivo de credenciales.${C_R}";;
    *"error(2)"*)
      err "No existe la ruta indicada."
      say "    ${C_DIM}En un NAS Synology la ruta NO incluye el volumen interno (volume1).${C_R}";;
    *"error(112)"*|*"error(101)"*|*"error(113)"*)
      err "No se alcanza el servidor. Revise IP, red o firewall.";;
    *"error(115)"*|*"error(110)"*)
      err "Tiempo agotado. El puerto 445 parece bloqueado.";;
    *"error(95)"*|*"error(5)"*)
      err "El servidor no acepta esa version del protocolo SMB.";;
    *"error(16)"*)
      err "El punto de montaje esta ocupado por otro recurso.";;
    *) err "No se pudo montar el recurso.";;
  esac
  [ -n "$s" ] && printf '%s\n' "$s" | sed 's/^/    /'
}

descubrir_recursos() {
  local p="${5:-445}"
  smbclient -L "//$1" -U "$2%$3" -W "$4" -p "$p" -g -m SMB3 2>/dev/null \
    | awk -F'|' '$1=="Disk" && $2 !~ /\$$/ {print $2}'
}

descubrir_subcarpetas() {
  local p="${6:-445}"
  smbclient "//$1/$2" -U "$3%$4" -W "$5" -p "$p" -c "ls" 2>/dev/null \
    | sed -nE 's/^  (.*[^ ]) +([DAHNRS]+) +[0-9]+ +.*$/\2\t\1/p' \
    | awk -F'\t' '$1 ~ /D/ && $2 != "." && $2 != ".." {print $2}'
}

probar_version_smb() {
  local unc="$1" cred="$2" puerto="${3:-445}" d v extra=""
  [ "$puerto" != "445" ] && extra=",port=${puerto}"
  d="$(mktemp -d)"
  for v in 3.1.1 3.0 2.1; do
    if mount -t cifs "$unc" "$d" \
         -o "ro,credentials=${cred},vers=${v},sec=ntlmssp,iocharset=utf8,nounix,noserverino${extra}" \
         >/dev/null 2>&1; then
      umount "$d" >/dev/null 2>&1; rmdir "$d"; printf '%s' "$v"; return 0
    fi
  done
  rmdir "$d" 2>/dev/null; return 1
}

fstab_escribir() {      # <tag> <unc> <mountpoint> <opts> [mp_anterior]
  local tag="$1" unc="$2" mp="$3" opts="$4" mp_old="${5:-$3}" marca tmp
  marca="# ${CRON_TAG}:${tag}"
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  awk -v m="$marca" -v a="$mp" -v b="$mp_old" '
    $0==m { skip=1; next }
    skip==1 { skip=0; next }
    ($1 !~ /^#/ && ($2==a || $2==b)) { next }
    { print }' /etc/fstab > "$tmp"
  printf '%s\n%s  %s  cifs  %s  0 0\n' "$marca" "${unc// /\\040}" "$mp" "$opts" >> "$tmp"
  cat "$tmp" > /etc/fstab; rm -f "$tmp"
  systemctl daemon-reload >/dev/null 2>&1
}

fstab_quitar() {
  local marca="# ${CRON_TAG}:${1}" mp="$2" tmp
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  awk -v m="$marca" -v mp="$mp" '
    $0==m { skip=1; next } skip==1 { skip=0; next }
    ($1 !~ /^#/ && $2==mp) { next } { print }' /etc/fstab > "$tmp"
  cat "$tmp" > /etc/fstab; rm -f "$tmp"
  systemctl daemon-reload >/dev/null 2>&1
}

# ======================== AYUDAS DE DRIVE =============================
rc() { timeout "$RCLONE_ESPERA" rclone "$@" </dev/null; }

drive_archivo_config() {
  local f
  f="$(rclone config file 2>/dev/null | tail -n 1)"
  [ -n "$f" ] && [ "${f:0:1}" = "/" ] || f="/root/.config/rclone/rclone.conf"
  printf '%s' "$f"
}

drive_escribir_remote() {
  local nombre="$1" token="$2" cid="${3:-}" csec="${4:-}" alcance="${5:-drive.readonly}" cfg tmp
  if ! [[ "$nombre" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    err "El nombre '${nombre}' no es valido para rclone; no se escribio nada."
    return 1
  fi
  cfg="$(drive_archivo_config)"
  mkdir -p "$(dirname "$cfg")"; [ -f "$cfg" ] || : > "$cfg"; chmod 600 "$cfg"
  tmp="$(mktemp)"
  awk -v s="[${nombre}]" '$0==s {skip=1; next} /^\[/ {skip=0} skip!=1 {print}' "$cfg" > "$tmp"
  {
    printf '[%s]\n' "$nombre"
    printf 'type = drive\n'
    [ -n "$cid" ]  && printf 'client_id = %s\n' "$cid"
    [ -n "$csec" ] && printf 'client_secret = %s\n' "$csec"
    printf 'scope = %s\n' "$alcance"
    printf 'token = %s\n' "$token"
    printf '\n'
  } >> "$tmp"
  cat "$tmp" > "$cfg"; rm -f "$tmp"; chmod 600 "$cfg"
  rclone listremotes 2>/dev/null | grep -qx "${nombre}:"
}

drive_crear_remote() {
  local NAV_ON=1 NOMBRE="" CLIENT_ID="" CLIENT_SECRET="" TOKEN="" ALCANCE="drive.readonly"
  local paso=1 estado
  while :; do
    case "$paso" in
      1) drv_cta_nombre;;
      2) drv_cta_credenciales;;
      3) drv_cta_token;;
      *) break;;
    esac
    estado=$?
    case "$estado" in
      0) paso=$((paso+1));;
      2) paso=$((paso-1)); [ "$paso" -lt 1 ] && return 1;;
      3) pantalla "CUENTAS DE GOOGLE DRIVE  >  Cancelado"
         warn "No se conecto ninguna cuenta."; enter; return 1;;
      9) break;;
    esac
  done
  return 0
}

drv_cta_nombre() {
  pantalla "CONECTAR UNA CUENTA  >  [1 de 3] Nombre"
  aviso_navegacion
  say "  Google exige un navegador para autorizar. Este servidor no lo tiene, asi que"
  say "  la autorizacion se hace en su computadora y aqui solo se pega el resultado."
  hr
  say "  ${C_DIM}Etiqueta interna del servidor, no un correo. Solo letras, numeros,${C_R}"
  say "  ${C_DIM}guion y guion bajo. Nombrela por su proposito: izone-backups.${C_R}"
  local r
  while true; do
    pedir NOMBRE "Nombre de la cuenta" "${NOMBRE:-gdrive}" || return $?
    if ! [[ "$NOMBRE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      err "Nombre invalido: rclone rechaza @ . espacios y acentos."
      continue
    fi
    if rclone listremotes 2>/dev/null | grep -qx "${NOMBRE}:"; then
      warn "Ya existe una cuenta llamada '${NOMBRE}'."
      si_no_nav "Desea reemplazarla?"; r=$?
      case "$r" in
        2|3) return "$r";;
        1)   say "  ${C_DIM}Escriba otro nombre.${C_R}"; continue;;
      esac
      rclone config delete "$NOMBRE" >/dev/null 2>&1
    fi
    return 0
  done
}

drv_cta_credenciales() {
  local r
  pantalla "CONECTAR UNA CUENTA  >  [2 de 3] Permisos y credenciales"
  aviso_navegacion
  say "  Este gestor solo necesita ${C_B}leer${C_R} los respaldos. Con permiso de solo"
  say "  lectura, un error aqui no puede borrar nada en el Drive."
  echo
  si_no_nav "Conectar la cuenta en modo solo lectura? (recomendado)"; r=$?
  case "$r" in
    2|3) return "$r";;
    0) ALCANCE="drive.readonly";;
    1) ALCANCE="drive"
       warn "La cuenta quedara con permiso de lectura y escritura."
       say "    ${C_DIM}Necesario solo si la misma cuenta se usara para respaldar.${C_R}"
       sleep 2;;
  esac
  echo
  say "  rclone trae credenciales publicas compartidas por todos sus usuarios. Cuando"
  say "  ese cupo se satura Google responde 'Quota exceeded' y todo se vuelve lento."
  echo
  si_no_nav "Usar credenciales propias de Google? (muy recomendado)"; r=$?
  case "$r" in
    2|3) return "$r";;
    1) CLIENT_ID=""; CLIENT_SECRET=""
       warn "Se usaran las credenciales compartidas de rclone."
       say "    ${C_DIM}Si mas adelante ve esperas largas, vuelva aqui con 'v'.${C_R}"
       sleep 2; return 0;;
  esac
  echo
  say "  ${C_DIM} 1. console.cloud.google.com > cree un proyecto${C_R}"
  say "  ${C_DIM} 2. APIs y servicios > Biblioteca > habilite 'Google Drive API'${C_R}"
  say "  ${C_DIM} 3. Pantalla de consentimiento OAuth > Externo > agregue su cuenta${C_R}"
  say "  ${C_DIM} 4. Credenciales > Crear credenciales > ID de cliente de OAuth${C_R}"
  say "  ${C_DIM}    Tipo de aplicacion: Aplicacion de escritorio${C_R}"
  echo
  pedir CLIENT_ID "ID de cliente" "$CLIENT_ID" || return $?
  pedir CLIENT_SECRET "Secreto de cliente" "$CLIENT_SECRET" || return $?
  return 0
}

drv_cta_token() {
  local salida estado extra=""
  pantalla "CONECTAR UNA CUENTA  >  [3 de 3] Autorizacion"
  aviso_navegacion
  if [ -n "$CLIENT_ID" ]; then
    say "  ${C_DIM}Usando credenciales propias de Google.${C_R}"
  else
    say "  ${C_DIM}Usando las credenciales compartidas de rclone.${C_R}"
    say "  ${C_DIM}Con 'v' vuelve al paso anterior si prefiere usar las propias.${C_R}"
  fi
  say "  ${C_DIM}Permiso solicitado: ${ALCANCE}${C_R}"
  echo
  say "  ${C_B}Paso 1.${C_R} En su computadora con navegador, instale rclone:"
  say "    ${C_DIM}Windows : https://rclone.org/downloads/ y abra PowerShell en esa carpeta${C_R}"
  say "    ${C_DIM}Linux/Mac: sudo -v && curl https://rclone.org/install.sh | sudo bash${C_R}"
  echo
  say "  ${C_B}Paso 2.${C_R} Ejecute alli exactamente:"
  echo
  [ "$ALCANCE" = "drive.readonly" ] && extra=" --drive-scope=drive.readonly"
  if [ -n "$CLIENT_ID" ]; then
    say "        ${C_CY}${C_B}rclone authorize \"drive\"${extra} \"${CLIENT_ID}\" \"${CLIENT_SECRET}\"${C_R}"
  else
    say "        ${C_CY}${C_B}rclone authorize \"drive\"${extra}${C_R}"
  fi
  echo
  say "  ${C_B}Paso 3.${C_R} Copie el bloque entre 'Paste the following' y 'End paste'"
  say "    ${C_DIM}(empieza con { y termina con }) y peguelo aqui en una sola linea.${C_R}"
  echo
  while true; do
    read -rp "  Token: " TOKEN || fin_entrada
    TOKEN="$(printf '%s' "$TOKEN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    _nav_check "$TOKEN"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    if [ -z "$TOKEN" ]; then err "No pego nada."
    elif [ "${TOKEN:0:1}" != "{" ] || [ "${TOKEN: -1}" != "}" ]; then
      err "Debe empezar con '{' y terminar con '}'."
    elif ! printf '%s' "$TOKEN" | grep -q "access_token"; then
      err "Ese texto no parece el token de Google."
    else break; fi
  done

  echo
  info "Registrando la cuenta (maximo ${RCLONE_ESPERA} segundos)..."
  if [ -n "$CLIENT_ID" ]; then
    salida="$(rc config create "$NOMBRE" drive scope="$ALCANCE" token="$TOKEN" \
                client_id="$CLIENT_ID" client_secret="$CLIENT_SECRET" 2>&1)"; estado=$?
  else
    salida="$(rc config create "$NOMBRE" drive scope="$ALCANCE" token="$TOKEN" 2>&1)"; estado=$?
  fi
  case "$estado" in
    0) ok "Cuenta registrada por rclone.";;
    *) if [ "$estado" -eq 124 ]; then warn "rclone no respondio a tiempo."
       else warn "rclone rechazo el comando:"; printf '%s\n' "$salida" | head -n 4 | sed 's/^/    /'; fi
       info "Registrando la configuracion directamente..."
       if drive_escribir_remote "$NOMBRE" "$TOKEN" "$CLIENT_ID" "$CLIENT_SECRET" "$ALCANCE"; then
         ok "Cuenta registrada."
       else
         err "No se pudo registrar."; enter; return 3
       fi;;
  esac

  echo
  info "Verificando el acceso (maximo ${RCLONE_ESPERA} segundos)..."
  salida="$(rc lsd "${NOMBRE}:" 2>&1)"; estado=$?
  case "$estado" in
    0)   ok "Cuenta conectada correctamente."
         printf '%s\n' "$salida" | head -n 5 | sed 's/^/    /';;
    124) warn "La verificacion tardo mas de ${RCLONE_ESPERA} segundos."
         say "    ${C_DIM}La cuenta quedo guardada. Suele ser el limite de peticiones de Google.${C_R}"
         [ -z "$CLIENT_ID" ] && say "    ${C_DIM}Se corrige reconectando con credenciales propias.${C_R}";;
    *)   err "No se pudo usar la cuenta:"
         printf '%s\n' "$salida" | head -n 5 | sed 's/^/    /'
         case "$salida" in
           *"invalid characters"*) say "    ${C_DIM}Nombre invalido. Repita con algo simple.${C_R}";;
           *"oauth2"*|*"invalid_grant"*|*"401"*) say "    ${C_DIM}El token expiro. Genere uno nuevo.${C_R}";;
           *"403"*|*"Quota"*|*"rateLimit"*) say "    ${C_DIM}Limite de cuota: use credenciales propias.${C_R}";;
         esac;;
  esac
  enter
  return 9
}

drive_diagnostico() {
  local r="$1" out ini fin seg est
  pantalla "CUENTAS DE GOOGLE DRIVE  >  Diagnostico"
  say "  Cuenta: ${C_B}${r}${C_R}"
  echo
  if rclone config show "$r" 2>/dev/null | grep -q "^client_id"; then
    ok "Usa credenciales propias de Google."
  else
    warn "Usa las credenciales compartidas de rclone."
    say "    ${C_DIM}Causa habitual de esperas largas y errores 403 'Quota exceeded'.${C_R}"
  fi
  rclone config show "$r" 2>/dev/null | grep "^scope" | sed 's/^/    /'
  echo
  info "Listando la raiz del Drive (maximo ${RCLONE_ESPERA} segundos)..."
  ini="$(date +%s)"; out="$(rc lsd "${r}:" -vv 2>&1)"; est=$?
  fin="$(date +%s)"; seg=$((fin-ini))
  echo
  if printf '%s' "$out" | grep -qi "rateLimitExceeded\|Quota exceeded\|userRateLimitExceeded"; then
    err "Google esta limitando las peticiones (403 Quota exceeded)."
    say "    ${C_DIM}rclone reintenta con esperas crecientes, por eso parece congelado.${C_R}"
    say "    ${C_DIM}Reconecte la cuenta con credenciales propias de Google.${C_R}"
  elif [ "$est" -eq 124 ]; then
    err "No hubo respuesta en ${RCLONE_ESPERA} segundos."
  elif [ "$est" -ne 0 ]; then
    err "rclone devolvio un error:"
    printf '%s\n' "$out" | grep -v "DEBUG" | head -n 8 | sed 's/^/    /'
  else
    ok "Respuesta correcta en ${seg} segundos."
    [ "$seg" -gt 15 ] && warn "Tardo mas de lo normal; revise las credenciales."
    printf '%s\n' "$out" | grep -v "DEBUG\|INFO" | head -n 5 | sed 's/^/    /'
  fi
  enter
}

# Navegador de carpetas del Drive. Aqui solo se elige: nunca se crea nada,
# porque el origen de una restauracion siempre existe de antemano.
drive_elegir_carpeta() {
  local remote="$1" ruta="${2:-}" items=() i op
  while true; do
    pantalla "GOOGLE DRIVE  >  Carpeta de origen"
    say "  Ubicacion actual: ${C_B}${remote}:/${ruta}${C_R}"
    echo
    mapfile -t items < <(rc lsf "${remote}:${ruta}" --dirs-only 2>/dev/null | sed 's:/$::')
    if [ "${#items[@]}" -gt 0 ]; then
      say "  Carpetas aqui dentro:"
      for i in "${!items[@]}"; do say "    $((i+1))) ${items[$i]}"; done
    else
      say "  ${C_DIM}(no hay subcarpetas en esta ubicacion)${C_R}"
    fi
    echo
    say "    ${C_B}a${C_R}) Los respaldos estan en ESTA carpeta"
    [ -n "$ruta" ] && say "    ${C_B}s${C_R}) Subir un nivel"
    say "    ${C_B}r${C_R}) Volver a leer el contenido del Drive"
    say "    ${C_B}m${C_R}) Escribir la ruta completa a mano"
    [ "${NAV_ON:-0}" = "1" ] && say "    ${C_B}v${C_R}) Volver al paso anterior    ${C_B}x${C_R}) Cancelar"
    echo
    read -rp "  Numero para entrar, o letra: " op || fin_entrada
    if [ "${NAV_ON:-0}" = "1" ]; then
      case "${op,,}" in v) return 2;; x) return 3;; esac
    fi
    case "$op" in
      a|A) DEST_PATH="$ruta"; return 0;;
      s|S) if [[ "$ruta" == */* ]]; then ruta="${ruta%/*}"; else ruta=""; fi;;
      r|R) ;;
      m|M) pedir DEST_PATH "Ruta completa dentro del Drive" || return $?
           DEST_PATH="${DEST_PATH#/}"; DEST_PATH="${DEST_PATH%/}"
           return 0;;
      *)   if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le "${#items[@]}" ]; then
             ruta="${ruta}${ruta:+/}${items[$((op-1))]}"
           else err "Opcion invalida."; sleep 1; fi;;
    esac
  done
}

menu_cuentas_drive() {
  command -v rclone >/dev/null 2>&1 || { pantalla "CUENTAS DE GOOGLE DRIVE"; asegurar_paquete rclone rclone || { enter; return 1; }; }
  local op remotes n
  while true; do
    pantalla "CUENTAS DE GOOGLE DRIVE"
    remotes="$(rclone listremotes 2>/dev/null | sed 's/:$//')"
    if [ -n "$remotes" ]; then
      say "  Cuentas registradas en este servidor:"
      printf '%s\n' "$remotes" | sed 's/^/    - /'
      echo
      say "  ${C_DIM}Si este servidor tambien respalda hacia Drive, la cuenta ya esta aqui:${C_R}"
      say "  ${C_DIM}rclone guarda las cuentas en un solo archivo para todo el servidor.${C_R}"
    else
      warn "Todavia no hay ninguna cuenta conectada."
    fi
    echo
    say "   1) Conectar una cuenta"
    say "   2) Diagnosticar una cuenta"
    say "   3) Eliminar una cuenta"
    say "   4) Asistente completo de rclone (avanzado)"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) drive_crear_remote;;
      2) [ -z "$remotes" ] && { err "No hay cuentas."; sleep 1; continue; }
         pedir n "Nombre de la cuenta"; drive_diagnostico "$n";;
      3) [ -z "$remotes" ] && { err "No hay cuentas."; sleep 1; continue; }
         pedir n "Nombre de la cuenta a eliminar"
         if si_no "Confirma eliminar '${n}'?"; then
           rclone config delete "$n" && ok "Eliminada."
           warn "Los trabajos que la usaban dejaran de funcionar."
         fi; enter;;
      4) clear; rclone config; enter;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

# ====================== FRAPPE: SITIO DESTINO =========================
# bench se niega a correr como root en varias versiones, y el propietario del
# bench es quien debe ejecutarlo. Aqui se ejecuta siempre como ese usuario.
run_bench() {
  local a q="" linea
  for a in "$@"; do q="${q} $(printf '%q' "$a")"; done
  linea="cd $(printf '%q' "$BENCH_PATH") && . env/bin/activate && bench${q}"
  if [ "$(id -un)" = "$BENCH_USER" ]; then
    bash -c "$linea"
  else
    su -l "$BENCH_USER" -c "$linea"
  fi
}

pedir_frappe_destino() {
  local encontrados=() sitios=() n i opcion duenio
  echo
  say "  ${C_B}Sitio que se va a sobrescribir${C_R}"
  say "  ${C_DIM}Este es el sitio que quedara reemplazado por el contenido del respaldo.${C_R}"
  echo
  mapfile -t encontrados < <(ls -d /home/*/frappe-bench 2>/dev/null)
  n="${#encontrados[@]}"
  if [ "$n" -gt 0 ]; then
    say "  Benches detectados:"
    for i in "${!encontrados[@]}"; do say "    $((i+1))) ${encontrados[$i]}"; done
    say "    0) Escribir la ruta manualmente"
    read -rp "  Seleccione la ruta del bench: " opcion || fin_entrada
    _nav_check "$opcion"; local nn=$?
    [ "$nn" -ne 0 ] && return "$nn"
    if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "$n" ]; then
      BENCH_PATH="${encontrados[$((opcion-1))]}"
    else
      pedir BENCH_PATH "Ruta absoluta del bench" || return $?
    fi
  else
    warn "No se detectaron carpetas frappe-bench en /home."
    pedir BENCH_PATH "Ruta absoluta del bench" || return $?
  fi
  [ -d "$BENCH_PATH/sites" ] || { err "No existe ${BENCH_PATH}/sites"; enter; return 1; }

  duenio="$(stat -c '%U' "$BENCH_PATH" 2>/dev/null)"
  echo
  say "  ${C_DIM}bench debe ejecutarse con el usuario propietario del bench, no con root.${C_R}"
  pedir BENCH_USER "Usuario que ejecuta bench" "${BENCH_USER:-${duenio:-frappe}}" || return $?
  if ! id "$BENCH_USER" >/dev/null 2>&1; then
    err "El usuario '${BENCH_USER}' no existe en este servidor."
    enter; return 1
  fi

  echo
  mapfile -t sitios < <(find "$BENCH_PATH/sites" -maxdepth 2 -name site_config.json -printf '%h\n' 2>/dev/null | xargs -r -n1 basename)
  if [ "${#sitios[@]}" -gt 0 ]; then
    say "  Sitios detectados:"
    for i in "${!sitios[@]}"; do say "    $((i+1))) ${sitios[$i]}"; done
    say "    0) Escribir el nombre manualmente"
    read -rp "  Seleccione el sitio destino: " opcion || fin_entrada
    _nav_check "$opcion"; local n2=$?
    [ "$n2" -ne 0 ] && return "$n2"
    if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "${#sitios[@]}" ]; then
      SITE="${sitios[$((opcion-1))]}"
    else
      pedir SITE "Nombre exacto del sitio" || return $?
    fi
  else
    warn "No se detectaron sitios en este bench."
    pedir SITE "Nombre exacto del sitio" || return $?
  fi
  return 0
}

# Avisa si el sitio destino es el mismo que algun trabajo de respaldo de este
# servidor respalda: seria restaurar produccion sobre si misma.
alerta_mismo_sitio() {
  local c s encontrado=""
  for c in $(listar_confs_respaldo); do
    s="$( . "$c" >/dev/null 2>&1; printf '%s' "${SITE:-}" )"
    [ "$s" = "$1" ] && encontrado="$( . "$c" >/dev/null 2>&1; printf '%s' "${ETIQUETA:-}" )"
  done
  [ -n "$encontrado" ] && printf '%s' "$encontrado"
  [ -n "$encontrado" ]
}

detectar_flag_db() {
  local salida
  salida="$(run_bench --site "$SITE" restore --help 2>&1)"
  if printf '%s' "$salida" | grep -q -- "--db-root-password"; then
    printf '%s' "--db-root-password"
  elif printf '%s' "$salida" | grep -q -- "--mariadb-root-password"; then
    printf '%s' "--mariadb-root-password"
  else
    printf '%s' ""
  fi
}

probar_password_db() {   # $1 = contrasena
  command -v mysql >/dev/null 2>&1 || return 2
  MYSQL_PWD="$1" mysql --user=root --execute="SELECT 1" >/dev/null 2>&1
}

# ===================== LISTADO DE RESPALDOS ==========================
# Ambos listados devuelven lineas "YYYY-MM-DD HH:MM|<fecha>/<hora>" ordenadas
# de mas reciente a mas antiguo. Se ordena por fecha real y no por nombre,
# porque el nombre de la carpeta lleva el mes en letras y depende del idioma
# del servidor que hizo el respaldo.
listar_respaldos_red() {
  find "$1" -mindepth 2 -maxdepth 2 -type d -printf '%TY-%Tm-%Td %TH:%TM|%P\n' 2>/dev/null | sort -r
}

listar_respaldos_drive() {
  rc lsf "${1}:${2}" --dirs-only -R --max-depth 2 --format "tp" --separator "|" 2>/dev/null \
    | awk -F'|' '{ r=$2; sub(/\/$/,"",r); n=split(r,a,"/"); if (n==2) printf "%s|%s\n", substr($1,1,16), r }' \
    | sort -r
}

asegurar_montaje() {
  mountpoint -q "$1" && return 0
  mount "$1" >/dev/null 2>&1
  mountpoint -q "$1"
}

# Muestra los respaldos disponibles. Devuelve 1 si no hay ninguno.
mostrar_respaldos() {   # $1=tipo  $2=mount|remote  $3=path  $4=cuantos
  local tipo="$1" cuantos="${4:-8}" lineas=() i f r
  if [ "$tipo" = "red" ]; then
    mapfile -t lineas < <(listar_respaldos_red "$2" | head -n "$cuantos")
  else
    mapfile -t lineas < <(listar_respaldos_drive "$2" "$3" | head -n "$cuantos")
  fi
  [ "${#lineas[@]}" -eq 0 ] && return 1
  for i in "${!lineas[@]}"; do
    f="${lineas[$i]%%|*}"; r="${lineas[$i]#*|}"
    printf '%b\n' "    ${C_B}$((i+1))${C_R}) ${r}   ${C_DIM}(${f})${C_R}"
  done
  return 0
}

# ================== GENERADOR DEL SCRIPT DE TRABAJO ==================
generar_script_restauracion() {
  cat > "$2" <<EOF
#!/usr/bin/env bash
# Generado por iZone ENTERPRISE - RESTAURACION
# La configuracion vive en el .conf; no edite valores aqui.
CONF="$1"
EOF
  cat >> "$2" <<'EOF'
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -r "$CONF" ] || { echo "[ERROR] No se encuentra la configuracion: $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
DB_ROOT_PASS=""; ADMIN_PASS=""
if [ -n "${DB_CRED_FILE:-}" ] && [ -r "${DB_CRED_FILE:-}" ]; then
  # shellcheck disable=SC1090
  . "$DB_CRED_FILE"
fi
export RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
limpiar() { [ -n "${TEMP_LOCAL:-}" ] && rm -rf "${TEMP_LOCAL:?}"/* 2>/dev/null; }
fallo() { log "[ERROR] $1"; limpiar; exit "${2:-1}"; }

MODO="ultimo"; RUTA_PEDIDA=""; FORZAR=0; SOLO_LISTAR=0; SIMULAR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --listar)  SOLO_LISTAR=1;;
    --ultimo)  MODO="ultimo";;
    --ruta)    MODO="ruta"; RUTA_PEDIDA="${2:-}"; shift;;
    --forzar)  FORZAR=1;;
    --simular) SIMULAR=1;;
    *) echo "uso: $0 [--listar] [--ultimo] [--ruta <fecha/hora>] [--forzar] [--simular]"; exit 2;;
  esac
  shift
done

# --------------------------- utilidades ------------------------------
run_bench() {
  local a q="" linea
  for a in "$@"; do q="${q} $(printf '%q' "$a")"; done
  linea="cd $(printf '%q' "$BENCH_PATH") && . env/bin/activate && bench${q}"
  if [ "$(id -un)" = "$BENCH_USER" ]; then
    bash -c "$linea"
  else
    su -l "$BENCH_USER" -c "$linea"
  fi
}

montar_origen() {
  [ "${JOB_TIPO}" = "red" ] || return 0
  mountpoint -q "$MOUNT_POINT" && return 0
  log "[AVISO] $MOUNT_POINT no esta montado. Intentando montar..."
  mount "$MOUNT_POINT" >/dev/null 2>&1
  mountpoint -q "$MOUNT_POINT"
}

listar() {
  if [ "${JOB_TIPO}" = "red" ]; then
    find "$MOUNT_POINT" -mindepth 2 -maxdepth 2 -type d \
         -printf '%TY-%Tm-%Td %TH:%TM|%P\n' 2>/dev/null | sort -r
  else
    rclone lsf "${RCLONE_REMOTE}:${DEST_PATH}" --dirs-only -R --max-depth 2 \
      --format "tp" --separator "|" --contimeout 30s --timeout 5m 2>/dev/null \
      | awk -F'|' '{ r=$2; sub(/\/$/,"",r); n=split(r,a,"/"); if (n==2) printf "%s|%s\n", substr($1,1,16), r }' \
      | sort -r
  fi
}

tamano_kb_origen() {   # $1 = ruta relativa
  if [ "${JOB_TIPO}" = "red" ]; then
    du -sk "${MOUNT_POINT}/${1}" 2>/dev/null | awk '{print $1}'
  else
    rclone size "${RCLONE_REMOTE}:${DEST_PATH}/${1}" --json --contimeout 30s --timeout 5m 2>/dev/null \
      | sed -n 's/.*"bytes":[[:space:]]*\([0-9]*\).*/\1/p' | awk '{printf "%d", $1/1024}'
  fi
}

# ------------------------------ listar -------------------------------
if [ "$SOLO_LISTAR" = "1" ]; then
  montar_origen || exit 1
  listar
  exit 0
fi

log "=============================================================="
log "[INICIO] Restauracion '${ETIQUETA}' sobre el sitio ${SITE}"

montar_origen || fallo "No se pudo acceder al origen de los respaldos."

# --------------------- elegir el respaldo ----------------------------
if [ "$MODO" = "ruta" ]; then
  [ -n "$RUTA_PEDIDA" ] || fallo "No se indico la ruta del respaldo."
  RUTA="$RUTA_PEDIDA"
else
  LINEA="$(listar | head -n 1)"
  [ -n "$LINEA" ] || fallo "No se encontro ningun respaldo en el origen."
  RUTA="${LINEA#*|}"
fi
log "[INFO] Respaldo seleccionado: ${RUTA}"

if [ "$MODO" = "ultimo" ] && [ "$FORZAR" != "1" ] && [ -f "${STATE_FILE:-/dev/null}" ]; then
  if [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$RUTA" ]; then
    log "[INFO] Ese respaldo ya fue restaurado antes. No hay nada nuevo que hacer."
    log "[FIN] Sin cambios."
    exit 0
  fi
fi

# ------------------------ espacio en disco ---------------------------
NECESARIO="$(tamano_kb_origen "$RUTA")"
if [ -n "$NECESARIO" ] && [ "$NECESARIO" -gt 0 ] 2>/dev/null; then
  DIR_LIBRE="$TEMP_LOCAL"
  while [ -n "$DIR_LIBRE" ] && [ ! -d "$DIR_LIBRE" ]; do DIR_LIBRE="${DIR_LIBRE%/*}"; done
  [ -n "$DIR_LIBRE" ] || DIR_LIBRE="/"
  LIBRE="$(df -Pk "$DIR_LIBRE" 2>/dev/null | awk 'NR==2 {print $4}')"
  log "[INFO] El respaldo ocupa ${NECESARIO} KB; libres en ${DIR_LIBRE}: ${LIBRE} KB"
  if [ -n "$LIBRE" ] && [ "$LIBRE" -lt "$((NECESARIO + NECESARIO / 10))" ] 2>/dev/null; then
    fallo "No hay espacio suficiente en ${DIR_LIBRE} para traer el respaldo."
  fi
fi

# --------------------- traer el respaldo -----------------------------
mkdir -p "$TEMP_LOCAL" || fallo "No se pudo crear $TEMP_LOCAL"
rm -rf "${TEMP_LOCAL:?}"/*
if [ "${JOB_TIPO}" = "red" ]; then
  [ -d "${MOUNT_POINT}/${RUTA}" ] || fallo "No existe ${MOUNT_POINT}/${RUTA}"
  cp -a "${MOUNT_POINT}/${RUTA}/." "${TEMP_LOCAL}/" || fallo "No se pudo copiar desde la unidad de red."
else
  rclone copy "${RCLONE_REMOTE}:${DEST_PATH}/${RUTA}" "$TEMP_LOCAL" \
    --contimeout 30s --timeout 30m --retries 3 --low-level-retries 10 \
    --log-file="${RCLONE_LOG:-/dev/null}" --log-level INFO \
    || fallo "Fallo la descarga desde ${RCLONE_REMOTE}:${DEST_PATH}/${RUTA}"
fi

# ------------------ verificar lo que llego ---------------------------
SQL=""; PUB=""; PRIV=""
for f in "$TEMP_LOCAL"/*database.sql.gz; do [ -f "$f" ] && { SQL="$f"; break; }; done
if [ -z "$SQL" ]; then
  for f in "$TEMP_LOCAL"/*.sql.gz; do [ -f "$f" ] && { SQL="$f"; break; }; done
fi
[ -n "$SQL" ] || fallo "El respaldo ${RUTA} no contiene ningun archivo .sql.gz"
gzip -t "$SQL" 2>/dev/null || fallo "El archivo de base de datos esta danado: $(basename "$SQL")"
log "[OK] Base de datos verificada: $(basename "$SQL")"

for f in "$TEMP_LOCAL"/*-files.tar; do
  case "$f" in *private-files.tar) continue;; esac
  [ -f "$f" ] && { PUB="$f"; break; }
done
for f in "$TEMP_LOCAL"/*private-files.tar; do [ -f "$f" ] && { PRIV="$f"; break; }; done
[ -n "$PUB" ]  && log "[INFO] Archivos publicos:  $(basename "$PUB")"
[ -n "$PRIV" ] && log "[INFO] Archivos privados:  $(basename "$PRIV")"
[ -z "$PUB" ] && [ -z "$PRIV" ] && log "[AVISO] El respaldo no trae adjuntos; solo se restaura la base de datos."

if [ "$SIMULAR" = "1" ]; then
  log "[INFO] Simulacion: el respaldo es valido y se pudo traer completo."
  log "[INFO] No se toco el sitio ${SITE}."
  limpiar
  log "[FIN] Simulacion terminada."
  exit 0
fi

# ------------- respaldo de seguridad del sitio actual ----------------
SITIO_EXISTE=0
[ -d "${BENCH_PATH}/sites/${SITE}" ] && SITIO_EXISTE=1

if [ "${PREVIO:-si}" = "si" ] && [ "$SITIO_EXISTE" = "1" ]; then
  DEST_PREVIO="${PREVIO_DIR}/$(date +%Y%m%d-%H%M%S)"
  ORIGEN_BK="${BENCH_PATH}/sites/${SITE}/private/backups"
  MARCA="$(mktemp)"
  mkdir -p "$DEST_PREVIO" || fallo "No se pudo crear $DEST_PREVIO"
  log "[INFO] Respaldo de seguridad del sitio actual antes de sobrescribirlo..."
  if run_bench --site "$SITE" backup --with-files >/dev/null 2>&1; then
    find "$ORIGEN_BK" -maxdepth 1 -type f -newer "$MARCA" -exec mv -t "$DEST_PREVIO" {} + 2>/dev/null
    if [ -n "$(ls -A "$DEST_PREVIO" 2>/dev/null)" ]; then
      log "[OK] Respaldo de seguridad en ${DEST_PREVIO}"
    else
      rm -rf "$DEST_PREVIO"
      rm -f "$MARCA"
      fallo "El respaldo de seguridad no genero archivos. No se toca el sitio."
    fi
  else
    rm -rf "$DEST_PREVIO"; rm -f "$MARCA"
    fallo "No se pudo respaldar el sitio actual. No se toca nada."
  fi
  rm -f "$MARCA"
  if [ "${PREVIO_CONSERVAR:-3}" -gt 0 ] 2>/dev/null; then
    ls -1dt "${PREVIO_DIR}"/*/ 2>/dev/null | tail -n +$((PREVIO_CONSERVAR + 1)) \
      | while read -r viejo; do rm -rf "$viejo"; done
  fi
elif [ "${PREVIO:-si}" = "si" ]; then
  log "[AVISO] El sitio ${SITE} aun no existe; no hay nada que respaldar antes."
fi

# --------------------------- restaurar -------------------------------
SALIDA_FINAL=0
[ "$SITIO_EXISTE" = "1" ] && run_bench --site "$SITE" set-maintenance-mode on >/dev/null 2>&1

ARGS=(--site "$SITE" restore "$SQL" --force)
[ -n "$PUB" ]  && ARGS+=(--with-public-files "$PUB")
[ -n "$PRIV" ] && ARGS+=(--with-private-files "$PRIV")
[ -n "${DB_FLAG:-}" ] && [ -n "${DB_ROOT_PASS:-}" ] && ARGS+=("$DB_FLAG" "$DB_ROOT_PASS")

log "[INFO] Restaurando sobre ${SITE}. El sitio queda en mantenimiento mientras dure."
if run_bench "${ARGS[@]}"; then
  log "[OK] Base de datos y adjuntos restaurados desde ${RUTA}"
else
  log "[ERROR] 'bench restore' fallo. El sitio puede haber quedado a medias."
  [ "${PREVIO:-si}" = "si" ] && [ -n "${DEST_PREVIO:-}" ] \
    && log "[ERROR] Para volver atras use el respaldo de seguridad: ${DEST_PREVIO}"
  run_bench --site "$SITE" set-maintenance-mode off >/dev/null 2>&1
  limpiar
  exit 4
fi

# --------------------- ajustes posteriores ---------------------------
if [ "${MIGRAR:-si}" = "si" ]; then
  log "[INFO] Aplicando migraciones (bench migrate)..."
  if run_bench --site "$SITE" migrate; then
    log "[OK] Migraciones aplicadas."
  else
    log "[AVISO] 'bench migrate' fallo. Revise que las apps del servidor coincidan"
    log "[AVISO] con las del servidor de origen y ejecutelo a mano."
    SALIDA_FINAL=5
  fi
fi

case "${SCHEDULER:-no-tocar}" in
  desactivar) run_bench --site "$SITE" disable-scheduler >/dev/null 2>&1 \
                && log "[OK] Programador de tareas desactivado en ${SITE}";;
  activar)    run_bench --site "$SITE" enable-scheduler >/dev/null 2>&1 \
                && log "[OK] Programador de tareas activado en ${SITE}";;
esac

if [ "${MUTE_EMAILS:-no}" = "si" ]; then
  if run_bench --site "$SITE" set-config -p mute_emails 1 >/dev/null 2>&1; then
    log "[OK] Correo saliente silenciado (mute_emails=1)."
  else
    run_bench --site "$SITE" set-config mute_emails 1 >/dev/null 2>&1 \
      && log "[OK] Correo saliente silenciado (mute_emails=1)." \
      || log "[AVISO] No se pudo silenciar el correo saliente. Reviselo a mano."
  fi
fi

if [ -n "${ADMIN_PASS:-}" ]; then
  run_bench --site "$SITE" set-admin-password "$ADMIN_PASS" >/dev/null 2>&1 \
    && log "[OK] Contrasena de Administrator cambiada." \
    || log "[AVISO] No se pudo cambiar la contrasena de Administrator."
fi

run_bench --site "$SITE" clear-cache >/dev/null 2>&1
run_bench --site "$SITE" set-maintenance-mode off >/dev/null 2>&1
log "[OK] Sitio fuera de mantenimiento."

# ---------------------------- cierre ---------------------------------
printf '%s\n' "$RUTA" > "${STATE_FILE:-/dev/null}" 2>/dev/null
chmod 640 "${STATE_FILE:-/dev/null}" 2>/dev/null
limpiar
log "[FIN] Restauracion de '${ETIQUETA}' terminada (codigo ${SALIDA_FINAL})."
exit "$SALIDA_FINAL"
EOF
  chmod 750 "$2"
}

# ================= ASISTENTE: NUEVO TRABAJO ==========================
# Maquina de pasos: cada paso devuelve
#   0 = continuar   2 = volver al paso anterior   3 = cancelar   4 = corregir
#   9 = creado
# En cualquier pregunta se puede escribir 'v' para volver o 'x' para cancelar.

crear_trabajo() {
  local TIPO="$1"
  local ETIQUETA="" JOB="" CONF="" SCRIPT="" LOG_FILE="" RCLONE_LOG="" STATE_FILE="" DB_CRED_FILE=""
  local ORIGEN_CONF="" MONTAJE_PROPIO="no" CRED_FILE=""
  local SRV="" SMB_PORT="445" CIFS_USER="" CIFS_PASS="" CIFS_DOM="" SHARE="" SUB="" UNC=""
  local SMB_VERS="" MOUNT_POINT="" MOUNT_OPTS=""
  local RCLONE_REMOTE="" DEST_PATH=""
  local BENCH_PATH="" BENCH_USER="" SITE="" DB_FLAG="" DB_ROOT_PASS="" ADMIN_PASS="" TEMP_LOCAL=""
  local PREVIO="si" PREVIO_DIR="" PREVIO_CONSERVAR="3"
  local MIGRAR="si" SCHEDULER="no-tocar" MUTE_EMAILS="no"
  local AUTOMATICO="no" HORARIOS="" DIAS_CRON="*"
  local paso=1 estado NAV_ON=1 volver_resumen=0

  while :; do
    case "$paso" in
      1) rst_paso_etiqueta;;
      2) rst_paso_origen;;
      3) rst_paso_verificar;;
      4) rst_paso_destino;;
      5) rst_paso_basedatos;;
      6) rst_paso_previo;;
      7) rst_paso_posterior;;
      8) rst_paso_programacion;;
      9) rst_paso_resumen;;
      *) break;;
    esac
    estado=$?
    case "$estado" in
      0) if [ "$volver_resumen" = "1" ]; then paso=9; volver_resumen=0
         else paso=$((paso+1)); fi;;
      2) volver_resumen=0; paso=$((paso-1))
         [ "$paso" -lt 1 ] && { rst_cancelar; return 0; };;
      3) rst_cancelar; return 0;;
      4) volver_resumen=1;;
      9) break;;
    esac
  done
  return 0
}

rst_cancelar() {
  # Las credenciales propias solo se conservan si el trabajo llego a crearse.
  [ -n "$CRED_FILE" ] && [ "$MONTAJE_PROPIO" = "si" ] && [ -f "$CRED_FILE" ] && [ ! -f "$CONF" ] && rm -f "$CRED_FILE"
  pantalla "NUEVO TRABAJO  >  Cancelado"
  warn "No se creo ningun trabajo. Nada fue restaurado."
  enter
}

# --------------------------- [1] Etiqueta ----------------------------
rst_paso_etiqueta() {
  local titulo="Unidad de Red (CIFS)"
  [ "$TIPO" = "drive" ] && titulo="Google Drive"
  pantalla "NUEVO TRABAJO  >  ${titulo}   [1 de 9]"
  if [ "$TIPO" = "red" ]; then
    if ! command -v mount.cifs >/dev/null 2>&1; then
      info "Verificando dependencias..."
      asegurar_paquete cifs-utils mount.cifs || {
        err "Sin cifs-utils el servidor no puede montar carpetas de red."
        enter; return 3; }
      echo
    fi
  else
    command -v rclone >/dev/null 2>&1 || { asegurar_paquete rclone rclone || { enter; return 3; }; echo; }
  fi
  aviso_navegacion
  say "  ${C_DIM}Un trabajo de restauracion es un origen de respaldos mas un sitio${C_R}"
  say "  ${C_DIM}destino. Puede ejecutarse a mano o quedar programado.${C_R}"
  echo
  pedir_etiqueta || return $?
  CONF="${APP_DIR}/${JOB}.conf";       SCRIPT="${BIN_DIR}/${JOB}.sh"
  LOG_FILE="${LOG_DIR}/${JOB}.log";    RCLONE_LOG="${LOG_DIR}/${JOB}-rclone.log"
  STATE_FILE="${APP_DIR}/${JOB}.state"; DB_CRED_FILE="${APP_DIR}/${JOB}.dbcred"
  PREVIO_DIR="${PREVIO_BASE}/${JOB}"
  TEMP_LOCAL="/var/tmp/${JOB}"
  return 0
}

# ---------------------------- [2] Origen -----------------------------
rst_paso_origen() {
  if [ "$TIPO" = "red" ]; then rst_origen_red; else rst_origen_drive; fi
}

heredar_red() {   # $1 = .conf del gestor de respaldos
  local d=()
  mapfile -t d < <( . "$1" >/dev/null 2>&1
      printf '%s\n' "${SERVIDOR:-}" "${SMB_PORT:-445}" "${RECURSO:-}" "${SUBCARPETA:-}" \
                    "${UNC:-}" "${MOUNT_POINT:-}" "${CRED_FILE:-}" "${SMB_VERS:-3.0}" )
  SRV="${d[0]}"; SMB_PORT="${d[1]}"; SHARE="${d[2]}"; SUB="${d[3]}"
  UNC="${d[4]}"; MOUNT_POINT="${d[5]}"; CRED_FILE="${d[6]}"; SMB_VERS="${d[7]}"
  MOUNT_OPTS=""
  MONTAJE_PROPIO="no"
  ORIGEN_CONF="$1"
}

heredar_drive() {
  local d=()
  mapfile -t d < <( . "$1" >/dev/null 2>&1
      printf '%s\n' "${RCLONE_REMOTE:-}" "${DEST_PATH:-}" )
  RCLONE_REMOTE="${d[0]}"; DEST_PATH="${d[1]}"
  ORIGEN_CONF="$1"
}

rst_origen_red() {
  local confs=() i op res
  pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Origen de los respaldos"
  aviso_navegacion
  mapfile -t confs < <(listar_confs_respaldo red)
  if [ "${#confs[@]}" -gt 0 ]; then
    say "  Este servidor ya respalda hacia estas unidades de red:"
    for i in "${!confs[@]}"; do
      res="$(resumen_conf_respaldo "${confs[$i]}")"
      say "    ${C_B}$((i+1))${C_R}) ${res%%|*}   ${C_DIM}${res#*|}${C_R}"
    done
    say "    ${C_B}0${C_R}) Configurar un origen distinto"
    echo
    say "  ${C_DIM}Al reutilizar un origen ya configurado se aprovechan su montaje y${C_R}"
    say "  ${C_DIM}sus credenciales: no se duplica nada en /etc/fstab.${C_R}"
    echo
    while true; do
      read -rp "  Seleccione el origen: " op || fin_entrada
      _nav_check "$op"; local n=$?
      [ "$n" -ne 0 ] && return "$n"
      if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le "${#confs[@]}" ]; then
        heredar_red "${confs[$((op-1))]}"
        echo; ok "Origen: ${UNC}"
        say "    ${C_DIM}montaje  : ${MOUNT_POINT}${C_R}"
        say "    ${C_DIM}heredado de: $(basename "$ORIGEN_CONF")${C_R}"
        sleep 2; return 0
      elif [ "$op" = "0" ]; then break
      else err "Opcion invalida."; fi
    done
  else
    say "  ${C_DIM}No se encontraron trabajos de respaldo hacia unidades de red en este${C_R}"
    say "  ${C_DIM}servidor, asi que el origen se configura aqui desde cero.${C_R}"
    echo; enter
  fi
  MONTAJE_PROPIO="si"
  ORIGEN_CONF=""
  CRED_FILE="${APP_DIR}/${JOB}.cred"
  rst_origen_red_manual
}

rst_origen_red_manual() {
  local paso=1 estado
  while :; do
    case "$paso" in
      1) orn_servidor;;
      2) orn_credenciales;;
      3) orn_recurso;;
      4) orn_subcarpeta;;
      5) orn_montaje;;
      *) break;;
    esac
    estado=$?
    case "$estado" in
      0) paso=$((paso+1));;
      2) paso=$((paso-1)); [ "$paso" -lt 1 ] && return 2;;
      3) return 3;;
    esac
  done
  return 0
}

orn_servidor() {
  local op preguntar=1
  while true; do
    if [ "$preguntar" = "1" ]; then
      pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Servidor de archivos"
      aviso_navegacion
      say "  ${C_DIM}Direccion del NAS o servidor donde estan los respaldos.${C_R}"
      pedir SRV "Direccion IP o nombre del servidor" "$SRV" || return $?
    fi
    preguntar=1
    SMB_PORT="${SMB_PORT:-445}"
    info "Comprobando ${SRV}:${SMB_PORT}..."
    if puerto_abierto "$SRV" "$SMB_PORT"; then
      ok "El servidor responde en el puerto ${SMB_PORT}."; sleep 1; return 0
    fi
    err "No hay respuesta en ${SRV}:${SMB_PORT}."
    if [ "$SMB_PORT" = "445" ]; then
      say "    ${C_DIM}El 445 es el puerto de las carpetas compartidas. Causas habituales:${C_R}"
      say "    ${C_DIM}- la IP no corresponde a ese NAS${C_R}"
      say "    ${C_DIM}- el servicio SMB esta desactivado en el NAS${C_R}"
      say "    ${C_DIM}- el servidor y el NAS estan en redes distintas, o hay un firewall${C_R}"
      say "    ${C_DIM}Que el NAS abra su interfaz web (5001 en Synology) no implica que${C_R}"
      say "    ${C_DIM}el 445 este disponible: son servicios distintos.${C_R}"
    fi
    echo
    say "   1) Corregir la direccion"
    say "   2) Continuar de todos modos"
    say "   3) SMB llega por otro puerto (NAT o tunel)"
    say "   v) Volver al paso anterior     x) Cancelar"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "${op,,}" in
      1) continue;;
      2) return 0;;
      3) pedir SMB_PORT "Puerto por el que llega SMB" "$SMB_PORT" || return $?
         if ! [[ "$SMB_PORT" =~ ^[0-9]+$ ]] || [ "$SMB_PORT" -lt 1 ] || [ "$SMB_PORT" -gt 65535 ]; then
           err "Puerto invalido."; SMB_PORT=445; sleep 1
         fi
         preguntar=0;;
      v) return 2;;
      x) return 3;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

orn_credenciales() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Credenciales del recurso"
  aviso_navegacion
  say "  ${C_DIM}Usuario creado EN ESE SERVIDOR. Para restaurar basta permiso de${C_R}"
  say "  ${C_DIM}lectura: el recurso se montara en solo lectura.${C_R}"
  pedir CIFS_USER "Usuario" "$CIFS_USER" || return $?
  say "  ${C_DIM}No se muestra mientras escribe. Sin comillas.${C_R}"
  pedir_secreto CIFS_PASS "Contrasena" || return $?
  say "  ${C_DIM}Deje WORKGROUP si la red no tiene Active Directory.${C_R}"
  pedir CIFS_DOM "Dominio o grupo de trabajo" "${CIFS_DOM:-WORKGROUP}" || return $?
  mkdir -p "$APP_DIR" "$LOG_DIR"; chmod 750 "$APP_DIR"
  { echo "username=${CIFS_USER}"; echo "password=${CIFS_PASS}"; echo "domain=${CIFS_DOM}"; } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  ok "Credenciales guardadas."
  sleep 1
  return 0
}

orn_recurso() {
  local recursos=() i opcion
  pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Carpeta compartida"
  aviso_navegacion
  command -v smbclient >/dev/null 2>&1 || asegurar_paquete smbclient smbclient
  if command -v smbclient >/dev/null 2>&1; then
    info "Consultando las carpetas compartidas de ${SRV}..."
    mapfile -t recursos < <(descubrir_recursos "$SRV" "$CIFS_USER" "$CIFS_PASS" "$CIFS_DOM" "$SMB_PORT")
  fi
  if [ "${#recursos[@]}" -gt 0 ]; then
    ok "El servidor publica estas carpetas compartidas:"
    for i in "${!recursos[@]}"; do say "    $((i+1))) ${recursos[$i]}"; done
    say "    0) Escribir el nombre manualmente"
    echo
    while true; do
      read -rp "  Seleccione la carpeta compartida: " opcion || fin_entrada
      _nav_check "$opcion"; local n=$?
      [ "$n" -ne 0 ] && return "$n"
      if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "${#recursos[@]}" ]; then
        SHARE="${recursos[$((opcion-1))]}"; return 0
      elif [ "$opcion" = "0" ]; then
        pedir SHARE "Nombre exacto de la carpeta compartida" "$SHARE" || return $?
        normalizar_recurso; return 0
      else err "Opcion invalida."; fi
    done
  else
    warn "No se pudo obtener la lista de carpetas compartidas."
    say "  ${C_DIM}Revise las credenciales, o escriba el nombre del recurso a mano.${C_R}"
    say "  ${C_DIM}Solo el nombre del recurso, sin // ni la IP.${C_R}"
    pedir SHARE "Nombre exacto de la carpeta compartida" "$SHARE" || return $?
    normalizar_recurso; return 0
  fi
}

# Limpia barras y separa "Recurso/sub/carpeta" en recurso + subcarpeta
normalizar_recurso() {
  SHARE="${SHARE//\\//}"
  SHARE="$(printf '%s' "$SHARE" | sed -e 's#^/*##' -e 's#/*$##' -e 's#//*#/#g')"
  if [[ "$SHARE" == */* ]]; then
    local resto="${SHARE#*/}"
    SHARE="${SHARE%%/*}"
    SUB="${resto}${SUB:+/$SUB}"
    echo
    info "Se interpreta asi:"
    say "    recurso compartido : ${C_B}${SHARE}${C_R}"
    say "    subcarpeta         : ${C_B}${SUB}${C_R}"
    sleep 2
  fi
}

orn_subcarpeta() {
  local subs=() i opcion r
  pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Subcarpeta"
  aviso_navegacion
  say "  Recurso elegido: ${C_B}//${SRV}/${SHARE}${C_R}"
  echo
  say "  ${C_DIM}Debe apuntar a la carpeta que contiene las carpetas de fecha,${C_R}"
  say "  ${C_DIM}no a una fecha concreta.${C_R}"
  echo
  if [ -n "$SUB" ]; then
    say "  Subcarpeta ya indicada: ${C_B}${SUB}${C_R}"
    si_no_nav "Usar esa subcarpeta?"; r=$?
    case "$r" in
      0) UNC="//${SRV}/${SHARE}/${SUB}"; return 0;;
      2|3) return "$r";;
      1) SUB="";;
    esac
    echo
  fi
  si_no_nav "Los respaldos estan dentro de una subcarpeta de '${SHARE}'?"; r=$?
  case "$r" in
    1) SUB=""; UNC="//${SRV}/${SHARE}"; return 0;;
    2|3) return "$r";;
  esac
  command -v smbclient >/dev/null 2>&1 && \
    mapfile -t subs < <(descubrir_subcarpetas "$SRV" "$SHARE" "$CIFS_USER" "$CIFS_PASS" "$CIFS_DOM" "$SMB_PORT")
  if [ "${#subs[@]}" -gt 0 ]; then
    say "  Subcarpetas encontradas:"
    for i in "${!subs[@]}"; do say "    $((i+1))) ${subs[$i]}"; done
    say "    0) Escribir la ruta manualmente"
    while true; do
      read -rp "  Seleccione la subcarpeta: " opcion || fin_entrada
      _nav_check "$opcion"; local n=$?
      [ "$n" -ne 0 ] && return "$n"
      if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "${#subs[@]}" ]; then
        SUB="${subs[$((opcion-1))]}"; break
      elif [ "$opcion" = "0" ]; then
        pedir SUB "Ruta dentro del recurso" "$SUB" || return $?; break
      else err "Opcion invalida."; fi
    done
  else
    warn "No se pudieron listar las subcarpetas."
    pedir SUB "Ruta dentro del recurso" "$SUB" || return $?
  fi
  SUB="${SUB//\\//}"
  SUB="$(printf '%s' "$SUB" | sed -e 's#^/*##' -e 's#/*$##' -e 's#//*#/#g')"
  UNC="//${SRV}/${SHARE}${SUB:+/$SUB}"
  return 0
}

orn_montaje() {
  local d salida r
  pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Prueba de conexion"
  aviso_navegacion
  say "  Recurso: ${C_B}${UNC}${C_R}"
  echo
  info "Probando versiones del protocolo SMB..."
  SMB_VERS="$(probar_version_smb "$UNC" "$CRED_FILE" "$SMB_PORT")"
  if [ -n "$SMB_VERS" ]; then
    ok "Conexion correcta usando SMB ${SMB_VERS}."
  else
    err "Ninguna version de SMB logro conectar."
    d="$(mktemp -d)"
    salida="$(mount -t cifs "$UNC" "$d" -o "ro,credentials=${CRED_FILE},vers=3.0,sec=ntlmssp,iocharset=utf8,nounix,noserverino$([ "$SMB_PORT" != "445" ] && echo ",port=${SMB_PORT}")" 2>&1)"
    rmdir "$d" 2>/dev/null
    echo; explicar_error_mount "$salida"; echo
    say "  ${C_DIM}Con 'v' vuelve atras para corregir la ruta o las credenciales.${C_R}"
    si_no_nav "Guardar la configuracion de todas formas?"; r=$?
    case "$r" in
      1) return 2;;
      2|3) return "$r";;
    esac
    pedir SMB_VERS "Version SMB a registrar" "3.0" || return $?
  fi
  echo
  pedir MOUNT_POINT "Punto de montaje local" "${MOUNT_POINT:-/mnt/${JOB}}" || return $?
  mkdir -p "$MOUNT_POINT"
  MOUNT_OPTS="ro,_netdev,nofail,credentials=${CRED_FILE},vers=${SMB_VERS},sec=ntlmssp,iocharset=utf8,nounix,noserverino"
  [ "$SMB_PORT" != "445" ] && MOUNT_OPTS="${MOUNT_OPTS},port=${SMB_PORT}"
  echo
  info "Registrando el montaje en /etc/fstab (solo lectura)..."
  fstab_escribir "$JOB" "$UNC" "$MOUNT_POINT" "$MOUNT_OPTS"
  umount "$MOUNT_POINT" >/dev/null 2>&1
  salida="$(mount "$MOUNT_POINT" 2>&1)"
  if mountpoint -q "$MOUNT_POINT"; then
    ok "Recurso montado en ${MOUNT_POINT} (solo lectura)."
    say "    ${C_DIM}Montado asi, este servidor no puede alterar ni borrar los respaldos.${C_R}"
  else
    explicar_error_mount "$salida"
    warn "Se guardo la configuracion; corrijala desde el trabajo."
  fi
  enter
  return 0
}

rst_origen_drive() {
  local confs=() i op res arr=() opcion
  pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Origen de los respaldos"
  aviso_navegacion
  mapfile -t confs < <(listar_confs_respaldo drive)
  if [ "${#confs[@]}" -gt 0 ]; then
    say "  Este servidor ya respalda hacia estas carpetas de Google Drive:"
    for i in "${!confs[@]}"; do
      res="$(resumen_conf_respaldo "${confs[$i]}")"
      say "    ${C_B}$((i+1))${C_R}) ${res%%|*}   ${C_DIM}${res#*|}${C_R}"
    done
    say "    ${C_B}0${C_R}) Elegir otra cuenta o carpeta"
    echo
    while true; do
      read -rp "  Seleccione el origen: " op || fin_entrada
      _nav_check "$op"; local n=$?
      [ "$n" -ne 0 ] && return "$n"
      if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le "${#confs[@]}" ]; then
        heredar_drive "${confs[$((op-1))]}"
        echo; ok "Origen: ${RCLONE_REMOTE}:${DEST_PATH}"
        sleep 2; return 0
      elif [ "$op" = "0" ]; then break
      else err "Opcion invalida."; fi
    done
  fi
  ORIGEN_CONF=""
  mapfile -t arr <<< "$(rclone listremotes 2>/dev/null | sed 's/:$//')"
  if [ -z "${arr[0]:-}" ]; then
    pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Cuenta de Google Drive"
    warn "No hay ninguna cuenta de Google Drive conectada en este servidor."
    say "  ${C_DIM}Se necesita una cuenta con acceso de lectura a la carpeta de respaldos.${C_R}"
    echo
    si_no_nav "Conectar una cuenta ahora?"; local r=$?
    case "$r" in 2|3) return "$r";; 1) return 2;; esac
    drive_crear_remote || return 2
    mapfile -t arr <<< "$(rclone listremotes 2>/dev/null | sed 's/:$//')"
    [ -z "${arr[0]:-}" ] && { err "Sigue sin haber cuentas."; enter; return 2; }
  fi
  pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Cuenta de Google Drive"
  aviso_navegacion
  if [ "${#arr[@]}" -eq 1 ]; then
    RCLONE_REMOTE="${arr[0]}"
    ok "Solo hay una cuenta conectada: ${RCLONE_REMOTE}"
  else
    say "  Cuentas conectadas:"
    for i in "${!arr[@]}"; do say "    $((i+1))) ${arr[$i]}"; done
    echo
    while true; do
      read -rp "  Seleccione la cuenta: " opcion || fin_entrada
      _nav_check "$opcion"; local n2=$?
      [ "$n2" -ne 0 ] && return "$n2"
      if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "${#arr[@]}" ]; then
        RCLONE_REMOTE="${arr[$((opcion-1))]}"; break
      fi
      err "Opcion invalida."
    done
  fi
  info "Verificando el acceso..."
  rc lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1 && ok "Acceso confirmado." \
    || warn "No se pudo listar la cuenta; revisela con el diagnostico."
  sleep 1
  DEST_PATH=""
  drive_elegir_carpeta "$RCLONE_REMOTE" || return $?
  DEST_PATH="${DEST_PATH#/}"; DEST_PATH="${DEST_PATH%/}"
  return 0
}

# --------------- [3] Verificar que haya respaldos --------------------
rst_paso_verificar() {
  local r
  pantalla "TRABAJO '${ETIQUETA}'  >  [3 de 9] Respaldos encontrados"
  aviso_navegacion
  if [ "$TIPO" = "red" ]; then
    say "  Origen: ${C_B}${UNC}${C_R}  en ${MOUNT_POINT}"
    echo
    if ! asegurar_montaje "$MOUNT_POINT"; then
      err "El recurso no esta montado en ${MOUNT_POINT}."
      say "    ${C_DIM}Sin montaje no se puede leer ningun respaldo.${C_R}"
      echo
      si_no_nav "Continuar de todos modos?"; r=$?
      case "$r" in 0) return 0;; 1) return 2;; *) return "$r";; esac
    fi
    info "Leyendo el contenido de ${MOUNT_POINT}..."
    echo
    if mostrar_respaldos red "$MOUNT_POINT" "" 8; then
      echo; ok "Se encontraron respaldos con la estructura <fecha>/<hora>."
      say "    ${C_DIM}Se ordenan por fecha real de la carpeta, no por su nombre.${C_R}"
    else
      err "No se encontraron carpetas con la estructura <fecha>/<hora>."
      say "    ${C_DIM}Revise que la subcarpeta apunte a la raiz de los respaldos y no${C_R}"
      say "    ${C_DIM}a una fecha concreta. Con 'v' vuelve a corregir el origen.${C_R}"
      echo
      si_no_nav "Continuar de todos modos?"; r=$?
      case "$r" in 0) ;; 1) return 2;; *) return "$r";; esac
    fi
  else
    say "  Origen: ${C_B}${RCLONE_REMOTE}:${DEST_PATH}${C_R}"
    echo
    info "Leyendo el contenido del Drive..."
    echo
    if mostrar_respaldos drive "$RCLONE_REMOTE" "$DEST_PATH" 8; then
      echo; ok "Se encontraron respaldos con la estructura <fecha>/<hora>."
    else
      err "No se encontraron carpetas con la estructura <fecha>/<hora>."
      say "    ${C_DIM}Revise la carpeta elegida. Con 'v' vuelve a corregir el origen.${C_R}"
      echo
      si_no_nav "Continuar de todos modos?"; r=$?
      case "$r" in 0) ;; 1) return 2;; *) return "$r";; esac
    fi
  fi
  echo
  enter
  return 0
}

# ----------------------- [4] Sitio destino ---------------------------
rst_paso_destino() {
  local etiqueta_bk
  pantalla "TRABAJO '${ETIQUETA}'  >  [4 de 9] Sitio destino"
  aviso_navegacion
  say "  ${C_RD}${C_B}Atencion:${C_R} restaurar reemplaza por completo la base de datos y los"
  say "  adjuntos del sitio que elija aqui. Lo que ese sitio tenga ahora se pierde."
  pedir_frappe_destino || return $?

  if etiqueta_bk="$(alerta_mismo_sitio "$SITE")"; then
    echo; hr
    warn "El sitio '${SITE}' es el mismo que respalda el trabajo '${etiqueta_bk}'"
    warn "de este servidor. Restaurar aqui sobrescribe ese sitio con una copia"
    warn "anterior de si mismo. Es lo correcto para recuperarse de un desastre,"
    warn "y es un error grave si lo que buscaba era refrescar otro sitio."
    hr; echo
    if ! confirmar_escribiendo "$SITE"; then
      err "No coincide. No se acepta el sitio destino."
      enter; return 2
    fi
    ok "Confirmado."
  fi
  echo
  say "  ${C_DIM}Carpeta de trabajo donde se arma el respaldo antes de restaurarlo.${C_R}"
  say "  ${C_DIM}Va en /var/tmp y no en /tmp porque puede pesar varios GB.${C_R}"
  pedir TEMP_LOCAL "Carpeta temporal de trabajo" "${TEMP_LOCAL:-/var/tmp/${JOB}}" || return $?
  return 0
}

# ---------------------- [5] Base de datos ----------------------------
rst_paso_basedatos() {
  local r
  pantalla "TRABAJO '${ETIQUETA}'  >  [5 de 9] Acceso a la base de datos"
  aviso_navegacion
  say "  ${C_DIM}'bench restore' borra y vuelve a crear la base de datos del sitio, y${C_R}"
  say "  ${C_DIM}para eso pide la contrasena de root del motor (MariaDB/MySQL). En una${C_R}"
  say "  ${C_DIM}restauracion programada nadie puede escribirla, asi que se guarda en${C_R}"
  say "  ${C_DIM}${DB_CRED_FILE} con permisos 600.${C_R}"
  echo
  info "Consultando que nombre usa esta version de bench para esa opcion..."
  DB_FLAG="$(detectar_flag_db)"
  if [ -n "$DB_FLAG" ]; then
    ok "Esta version de bench la recibe como '${DB_FLAG}'."
  else
    warn "No se pudo determinar el nombre de la opcion."
    say "    ${C_DIM}Se usara '--db-root-password', el nombre de las versiones actuales.${C_R}"
    DB_FLAG="--db-root-password"
  fi
  echo
  pedir_secreto DB_ROOT_PASS "Contrasena de root de la base de datos" || return $?
  echo
  info "Comprobando la contrasena..."
  probar_password_db "$DB_ROOT_PASS"; r=$?
  case "$r" in
    0) ok "La contrasena funciona contra el motor local.";;
    2) warn "No hay cliente 'mysql' en este servidor; no se pudo comprobar.";;
    *) err "El motor local rechazo esa contrasena."
       say "    ${C_DIM}Puede ser correcta si la base de datos vive en otro servidor.${C_R}"
       echo
       si_no_nav "Usarla de todas formas?"; local r2=$?
       case "$r2" in 1) return 0;; 2|3) return "$r2";; esac;;
  esac
  sleep 1
  return 0
}

# ------------------ [6] Respaldo de seguridad ------------------------
rst_paso_previo() {
  local r v
  pantalla "TRABAJO '${ETIQUETA}'  >  [6 de 9] Respaldo de seguridad"
  aviso_navegacion
  say "  Antes de sobrescribir el sitio, el gestor puede respaldarlo. Es la unica"
  say "  forma de volver atras si el respaldo restaurado no era el que esperaba."
  echo
  say "  ${C_DIM}Se guarda en ${PREVIO_DIR}, fuera de la carpeta de respaldos del sitio,${C_R}"
  say "  ${C_DIM}para que el gestor de respaldos no se lo lleve al NAS o al Drive.${C_R}"
  echo
  si_no_nav "Respaldar el sitio destino antes de cada restauracion?"; r=$?
  case "$r" in
    0) PREVIO="si";;
    1) PREVIO="no"
       echo; warn "Sin respaldo previo no hay vuelta atras."
       say "    ${C_DIM}Razonable solo si el sitio destino es descartable.${C_R}"
       sleep 2; return 0;;
    *) return "$r";;
  esac
  echo
  say "  ${C_DIM}Cuantos respaldos de seguridad conservar. Los mas viejos se borran.${C_R}"
  while true; do
    read -rp "  Respaldos de seguridad a conservar [${PREVIO_CONSERVAR}]: " v || fin_entrada
    v="${v:-$PREVIO_CONSERVAR}"
    _nav_check "$v"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    [[ "$v" =~ ^[0-9]+$ ]] && { PREVIO_CONSERVAR="$v"; break; }
    err "Escriba un numero entero (0 o mayor)."
  done
  return 0
}

# ------------------ [7] Despues de restaurar -------------------------
rst_paso_posterior() {
  local r op
  pantalla "TRABAJO '${ETIQUETA}'  >  [7 de 9] Despues de restaurar"
  aviso_navegacion
  say "  ${C_DIM}Un sitio restaurado llega con la configuracion del sitio de origen:${C_R}"
  say "  ${C_DIM}sus cuentas de correo, sus tareas programadas y sus usuarios.${C_R}"
  echo
  si_no_nav "Ejecutar 'bench migrate' despues de restaurar? (recomendado)"; r=$?
  case "$r" in 0) MIGRAR="si";; 1) MIGRAR="no";; *) return "$r";; esac
  echo
  say "  Programador de tareas del sitio restaurado:"
  say "    1) No tocarlo"
  say "    2) Desactivarlo   ${C_DIM}(evita que una copia ejecute tareas de produccion)${C_R}"
  say "    3) Activarlo"
  while true; do
    read -rp "  Opcion [1-3]: " op || fin_entrada
    _nav_check "$op"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    case "$op" in
      1) SCHEDULER="no-tocar"; break;;
      2) SCHEDULER="desactivar"; break;;
      3) SCHEDULER="activar"; break;;
      *) err "Opcion invalida.";;
    esac
  done
  echo
  say "  ${C_DIM}Si restaura produccion sobre una copia de pruebas, esa copia puede${C_R}"
  say "  ${C_DIM}enviar correos reales a clientes reales. Silenciarlos lo evita.${C_R}"
  si_no_nav "Silenciar el correo saliente del sitio restaurado?"; r=$?
  case "$r" in 0) MUTE_EMAILS="si";; 1) MUTE_EMAILS="no";; *) return "$r";; esac
  echo
  say "  ${C_DIM}La contrasena de Administrator sera la que tenia el sitio de origen.${C_R}"
  si_no_nav "Cambiarla despues de cada restauracion?"; r=$?
  case "$r" in
    0) pedir_secreto ADMIN_PASS "Contrasena para Administrator" || return $?;;
    1) ADMIN_PASS="";;
    *) return "$r";;
  esac
  return 0
}

# ---------------------- [8] Programacion -----------------------------
rst_paso_programacion() {
  local r
  pantalla "TRABAJO '${ETIQUETA}'  >  [8 de 9] Programacion"
  aviso_navegacion
  say "  Un trabajo programado revisa el origen a la hora indicada y, si hay un"
  say "  respaldo mas nuevo que el ultimo restaurado, lo restaura."
  echo
  say "  ${C_DIM}Si no hay nada nuevo no toca el sitio: no repite trabajo ni riesgo.${C_R}"
  say "  ${C_DIM}Mientras dura, el sitio queda en modo mantenimiento. Elija una hora${C_R}"
  say "  ${C_DIM}en la que nadie lo este usando.${C_R}"
  echo
  si_no_nav "Programar la restauracion automatica?"; r=$?
  case "$r" in
    1) AUTOMATICO="no"; HORARIOS=""; DIAS_CRON="*"
       echo; info "El trabajo quedara solo para ejecutarlo a mano desde el menu."
       sleep 2; return 0;;
    2|3) return "$r";;
  esac
  AUTOMATICO="si"
  echo
  pedir_horarios || return $?
  pedir_dias || return $?
  return 0
}

# ---------------------- [9] Revision final ---------------------------
rst_paso_resumen() {
  local op origen
  if [ "$TIPO" = "red" ]; then origen="${UNC}  (${MOUNT_POINT})"
  else origen="${RCLONE_REMOTE}:${DEST_PATH}"; fi
  while true; do
    pantalla "TRABAJO '${ETIQUETA}'  >  [9 de 9] Revision final"
    say "   ${C_B}1${C_R}) Etiqueta        : ${ETIQUETA}"
    say "   ${C_B}2${C_R}) Origen          : ${origen}"
    [ -n "$ORIGEN_CONF" ] && \
    say "                       ${C_DIM}heredado de $(basename "$ORIGEN_CONF")${C_R}"
    say "   ${C_B}3${C_R}) Respaldos       : ${C_DIM}verificados en el paso 3${C_R}"
    say "   ${C_B}4${C_R}) Sitio destino   : ${C_RD}${SITE}${C_R}   ${C_DIM}bench: ${BENCH_PATH}  usuario: ${BENCH_USER}${C_R}"
    say "   ${C_B}5${C_R}) Base de datos   : contrasena de root guardada   ${C_DIM}${DB_FLAG}${C_R}"
    if [ "$PREVIO" = "si" ]; then
      say "   ${C_B}6${C_R}) Respaldo previo : si, conservando ${PREVIO_CONSERVAR}   ${C_DIM}${PREVIO_DIR}${C_R}"
    else
      say "   ${C_B}6${C_R}) Respaldo previo : ${C_RD}no${C_R}"
    fi
    say "   ${C_B}7${C_R}) Despues         : migrate=${MIGRAR}  programador=${SCHEDULER}  correo=$([ "$MUTE_EMAILS" = si ] && echo silenciado || echo intacto)$([ -n "$ADMIN_PASS" ] && echo "  admin=nueva")"
    if [ "$AUTOMATICO" = "si" ]; then
      say "   ${C_B}8${C_R}) Programacion    : ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))"
    else
      say "   ${C_B}8${C_R}) Programacion    : solo manual"
    fi
    echo
    say "   ${C_B}s${C_R}) Crear el trabajo con estos datos"
    say "   ${C_B}x${C_R}) Cancelar sin crear nada"
    echo
    say "  ${C_DIM}Crear el trabajo no restaura nada todavia.${C_R}"
    say "  ${C_DIM}Escriba el numero del dato que quiera corregir.${C_R}"
    read -rp "  Opcion: " op || fin_entrada
    case "${op,,}" in
      s|si) break;;
      x|cancelar) return 3;;
      v) return 2;;
      3) err "Ese paso solo verifica; corrija el origen con 2."; sleep 2;;
      [1-9]) paso="$op"; return 4;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done

  mkdir -p "$APP_DIR" "$LOG_DIR" "$PREVIO_DIR" "$TEMP_LOCAL"; chmod 750 "$APP_DIR" "$PREVIO_DIR"
  {
    printf '# Credenciales de restauracion - iZone ENTERPRISE\n'
    printf 'DB_ROOT_PASS=%q\n' "$DB_ROOT_PASS"
    printf 'ADMIN_PASS=%q\n' "$ADMIN_PASS"
  } > "$DB_CRED_FILE"
  chmod 600 "$DB_CRED_FILE"

  guardar_conf "$CONF" \
    "JOB_TIPO=${TIPO}" "JOB_NOMBRE=${JOB}" "ETIQUETA=${ETIQUETA}" \
    "ORIGEN_CONF=${ORIGEN_CONF}" "MONTAJE_PROPIO=${MONTAJE_PROPIO}" \
    "SERVIDOR=${SRV}" "SMB_PORT=${SMB_PORT}" "RECURSO=${SHARE}" "SUBCARPETA=${SUB}" \
    "UNC=${UNC}" "MOUNT_POINT=${MOUNT_POINT}" "CRED_FILE=${CRED_FILE}" \
    "SMB_VERS=${SMB_VERS}" "MOUNT_OPTS=${MOUNT_OPTS}" \
    "RCLONE_REMOTE=${RCLONE_REMOTE}" "DEST_PATH=${DEST_PATH}" \
    "RCLONE_CONFIG=/root/.config/rclone/rclone.conf" \
    "BENCH_PATH=${BENCH_PATH}" "BENCH_USER=${BENCH_USER}" "SITE=${SITE}" \
    "DB_CRED_FILE=${DB_CRED_FILE}" "DB_FLAG=${DB_FLAG}" "TEMP_LOCAL=${TEMP_LOCAL}" \
    "PREVIO=${PREVIO}" "PREVIO_DIR=${PREVIO_DIR}" "PREVIO_CONSERVAR=${PREVIO_CONSERVAR}" \
    "MIGRAR=${MIGRAR}" "SCHEDULER=${SCHEDULER}" "MUTE_EMAILS=${MUTE_EMAILS}" \
    "AUTOMATICO=${AUTOMATICO}" "HORARIOS=${HORARIOS}" "DIAS_CRON=${DIAS_CRON}" \
    "LOG_FILE=${LOG_FILE}" "RCLONE_LOG=${RCLONE_LOG}" "STATE_FILE=${STATE_FILE}"

  generar_script_restauracion "$CONF" "$SCRIPT"
  touch "$LOG_FILE" "$RCLONE_LOG"; chmod 640 "$LOG_FILE" "$RCLONE_LOG"
  reprogramar "$CONF"

  pantalla "TRABAJO '${ETIQUETA}'  >  Resultado"
  ok "Trabajo '${JOB}' creado."
  say "    script : ${SCRIPT}"
  say "    config : ${CONF}"
  say "    origen : ${origen}"
  say "    destino: sitio ${SITE}"
  say "    log    : ${LOG_FILE}"
  if [ "$AUTOMATICO" = "si" ]; then
    say "    horario: ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))"
  else
    say "    horario: ${C_DIM}sin programacion; se ejecuta desde el menu${C_R}"
  fi
  echo; hr
  say "  ${C_DIM}Nada se ha restaurado todavia.${C_R}"
  echo
  if si_no "Hacer una prueba en seco ahora? (trae el respaldo y lo verifica, sin tocar el sitio)"; then
    hr
    "$SCRIPT" --ultimo --forzar --simular 2>&1 | tee -a "$LOG_FILE" | sed 's/^/  /'
    hr
  fi
  enter
  return 9
}

# ===================== EJECUTAR UNA RESTAURACION =====================
# Pantalla de confirmacion comun a toda restauracion real.
confirmar_restauracion() {   # $1 = ruta del respaldo
  local ruta="$1"
  echo; hr
  say "  ${C_RD}${C_B}Esto reemplaza el sitio '${SITE}' por completo.${C_R}"
  say "  Respaldo a restaurar : ${C_B}${ruta}${C_R}"
  say "  Sitio destino        : ${C_B}${SITE}${C_R}   ${C_DIM}(${BENCH_PATH})${C_R}"
  if [ "${PREVIO:-si}" = "si" ]; then
    say "  Respaldo de seguridad: ${C_GR}si${C_R}, en ${PREVIO_DIR}"
  else
    say "  Respaldo de seguridad: ${C_RD}no${C_R}  ${C_DIM}- no habra vuelta atras${C_R}"
  fi
  say "  El sitio quedara en mantenimiento mientras dure."
  hr; echo
  confirmar_escribiendo "$SITE"
}

correr_script() {   # $@ = argumentos para el script del trabajo
  local scr="${BIN_DIR}/${JOB_NOMBRE}.sh" estado
  [ -x "$scr" ] || { err "No existe el script ${scr}"; enter; return 1; }
  hr
  "$scr" "$@" 2>&1 | tee -a "$LOG_FILE" | sed 's/^/  /'
  estado="${PIPESTATUS[0]}"
  hr
  case "$estado" in
    0) ok "Finalizado correctamente.";;
    5) warn "Restauro, pero 'bench migrate' fallo. Revise el log.";;
    *) err "Finalizo con codigo ${estado}.";;
  esac
  enter
  return "$estado"
}

restaurar_eligiendo() {
  local conf="$1" lineas=() i op f r scr
  cargar_conf "$conf"
  scr="${BIN_DIR}/${JOB_NOMBRE}.sh"
  pantalla "TRABAJO '${ETIQUETA}'  >  Elegir respaldo"
  info "Leyendo los respaldos disponibles en el origen..."
  mapfile -t lineas < <("$scr" --listar 2>/dev/null | head -n 30)
  if [ "${#lineas[@]}" -eq 0 ]; then
    echo; err "No se encontro ningun respaldo en el origen."
    say "    ${C_DIM}Use el diagnostico para ver si el origen esta accesible.${C_R}"
    enter; return 1
  fi
  echo
  say "  Respaldos disponibles, del mas reciente al mas antiguo:"
  echo
  for i in "${!lineas[@]}"; do
    f="${lineas[$i]%%|*}"; r="${lineas[$i]#*|}"
    printf '%b\n' "    ${C_B}$((i+1))${C_R}) ${r}   ${C_DIM}(${f})${C_R}"
  done
  echo
  say "    ${C_B}0${C_R}) Volver sin restaurar"
  echo
  while true; do
    read -rp "  Numero del respaldo a restaurar: " op || fin_entrada
    [ "$op" = "0" ] && return 0
    if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le "${#lineas[@]}" ]; then
      r="${lineas[$((op-1))]#*|}"
      if confirmar_restauracion "$r"; then
        pantalla "TRABAJO '${ETIQUETA}'  >  Restaurando ${r}"
        correr_script --ruta "$r"
      else
        err "No coincide. No se restauro nada."; enter
      fi
      return 0
    fi
    err "Opcion invalida."
  done
}

restaurar_reciente() {
  local conf="$1" linea r scr
  cargar_conf "$conf"
  scr="${BIN_DIR}/${JOB_NOMBRE}.sh"
  pantalla "TRABAJO '${ETIQUETA}'  >  Restaurar el mas reciente"
  info "Buscando el respaldo mas reciente..."
  linea="$("$scr" --listar 2>/dev/null | head -n 1)"
  if [ -z "$linea" ]; then
    echo; err "No se encontro ningun respaldo en el origen."; enter; return 1
  fi
  r="${linea#*|}"
  echo; ok "Mas reciente: ${C_B}${r}${C_R}  ${C_DIM}(${linea%%|*})${C_R}"
  if confirmar_restauracion "$r"; then
    pantalla "TRABAJO '${ETIQUETA}'  >  Restaurando ${r}"
    correr_script --ultimo --forzar
  else
    err "No coincide. No se restauro nada."; enter
  fi
  return 0
}

prueba_en_seco() {
  local conf="$1"
  cargar_conf "$conf"
  pantalla "TRABAJO '${ETIQUETA}'  >  Prueba en seco"
  say "  Trae el respaldo mas reciente, comprueba que el archivo de base de datos"
  say "  no este danado y termina. ${C_B}No toca el sitio ${SITE}.${C_R}"
  echo
  correr_script --ultimo --forzar --simular
}

# ======================= MENU DE UN TRABAJO ==========================
menu_horarios() {
  local conf="$1" op i horas=() nueva lista quitar resto r
  while true; do
    cargar_conf "$conf"
    pantalla "TRABAJO '${ETIQUETA}'  >  Programacion"
    if [ "${AUTOMATICO:-no}" != "si" ]; then
      warn "Este trabajo no esta programado: solo se ejecuta a mano."
      echo
      say "   1) Programarlo"
      say "   0) Volver"
      echo
      read -rp "  Opcion: " op || fin_entrada
      case "$op" in
        1) pedir_horarios && pedir_dias && {
             set_conf "$conf" AUTOMATICO "si"
             set_conf "$conf" HORARIOS "$HORARIOS"
             set_conf "$conf" DIAS_CRON "$DIAS_CRON"
             reprogramar "$conf"; ok "Programado."; sleep 1; };;
        0) return 0;;
        *) err "Opcion invalida."; sleep 1;;
      esac
      continue
    fi
    mapfile -t horas < <(printf '%s\n' $HORARIOS)
    say "  Horas configuradas:"
    for i in "${!horas[@]}"; do say "    $((i+1))) ${horas[$i]}"; done
    say "  Dias: ${C_B}$(describir_dias "$DIAS_CRON")${C_R}"
    echo
    say "  ${C_DIM}Cron generado:${C_R}"; cron_mostrar "$JOB_NOMBRE"
    echo
    say "   1) Agregar una hora"
    say "   2) Quitar una hora"
    say "   3) Cambiar los dias"
    say "   4) Reemplazar toda la lista de horas"
    say "   5) ${C_YL}Desactivar la restauracion automatica${C_R}"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) pedir nueva "Hora a agregar (HH:MM)"
         if ! hora_valida "$nueva"; then err "Hora invalida."; sleep 1; continue; fi
         nueva="$(normalizar_hora "$nueva")"
         if printf '%s\n' "${horas[@]}" | grep -qx "$nueva"; then
           warn "Esa hora ya estaba configurada."; sleep 1; continue
         fi
         lista="$(ordenar_horarios "$HORARIOS $nueva")"
         set_conf "$conf" HORARIOS "$lista"; reprogramar "$conf"
         ok "Agregada ${nueva}."; sleep 1;;
      2) if [ "${#horas[@]}" -le 1 ]; then
           err "Debe quedar al menos una hora. Use 'Reemplazar toda la lista'."; sleep 2; continue
         fi
         read -rp "  Numero de la hora a quitar: " i || fin_entrada
         if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#horas[@]}" ]; then
           quitar="${horas[$((i-1))]}"; resto=""
           for nueva in "${horas[@]}"; do [ "$nueva" = "$quitar" ] || resto="${resto}${resto:+ }${nueva}"; done
           set_conf "$conf" HORARIOS "$resto"; reprogramar "$conf"
           ok "Quitada ${quitar}."; sleep 1
         else err "Numero invalido."; sleep 1; fi;;
      3) pedir_dias
         set_conf "$conf" DIAS_CRON "$DIAS_CRON"; reprogramar "$conf"
         ok "Dias actualizados."; sleep 1;;
      4) pedir_horarios
         set_conf "$conf" HORARIOS "$HORARIOS"; reprogramar "$conf"
         ok "Horarios actualizados."; sleep 1;;
      5) if si_no "Confirma desactivar la restauracion automatica?"; then
           set_conf "$conf" AUTOMATICO "no"; reprogramar "$conf"
           ok "Desactivada. El trabajo sigue disponible para ejecutarlo a mano."
           sleep 2
         fi;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

editar_origen() {
  local conf="$1" nuevo nmp nvers nopts sal nrem
  cargar_conf "$conf"
  if [ "$JOB_TIPO" = "red" ]; then
    pantalla "TRABAJO '${ETIQUETA}'  >  Origen de red"
    say "  Actual : ${C_B}${UNC}${C_R}"
    say "  Montaje: ${MOUNT_POINT}"
    [ -n "$ORIGEN_CONF" ] && say "  ${C_DIM}Heredado de $(basename "$ORIGEN_CONF")${C_R}"
    echo
    say "   1) Montar ahora"
    say "   2) Cambiar la cadena de conexion y el punto de montaje"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " nuevo || fin_entrada
    case "$nuevo" in
      1) systemctl daemon-reload >/dev/null 2>&1
         sal="$(mount "$MOUNT_POINT" 2>&1)"
         if mountpoint -q "$MOUNT_POINT"; then
           ok "Montado."; df -h "$MOUNT_POINT" | tail -n1 | sed 's/^/    /'
         else explicar_error_mount "$sal"; fi;;
      2) if [ "$MONTAJE_PROPIO" != "si" ]; then
           warn "Este montaje pertenece al gestor de respaldos ($(basename "$ORIGEN_CONF"))."
           say "    ${C_DIM}Cambiarlo desde aqui afectaria tambien a los respaldos.${C_R}"
           si_no "Aun asi desea tomarlo bajo control de este trabajo?" || { enter; return 0; }
           MONTAJE_PROPIO="si"; set_conf "$conf" MONTAJE_PROPIO "si"; set_conf "$conf" ORIGEN_CONF ""
         fi
         while true; do
           pedir nuevo "Nueva cadena de conexion"
           nuevo="${nuevo//\\//}"; nuevo="${nuevo%/}"
           [[ "$nuevo" =~ ^//[^/]+/.+ ]] && break
           err "Formato invalido. Debe iniciar con // seguido del servidor y el recurso."
         done
         pedir nmp "Punto de montaje" "$MOUNT_POINT"; mkdir -p "$nmp"
         pedir nvers "Version SMB" "${SMB_VERS:-3.0}"
         nopts="ro,_netdev,nofail,credentials=${CRED_FILE},vers=${nvers},sec=ntlmssp,iocharset=utf8,nounix,noserverino"
         [ -n "${SMB_PORT:-}" ] && [ "$SMB_PORT" != "445" ] && nopts="${nopts},port=${SMB_PORT}"
         umount "$MOUNT_POINT" >/dev/null 2>&1; umount "$nmp" >/dev/null 2>&1
         fstab_escribir "$JOB_NOMBRE" "$nuevo" "$nmp" "$nopts" "$MOUNT_POINT"
         set_conf "$conf" UNC "$nuevo";      set_conf "$conf" MOUNT_POINT "$nmp"
         set_conf "$conf" SMB_VERS "$nvers"; set_conf "$conf" MOUNT_OPTS "$nopts"
         sal="$(mount "$nmp" 2>&1)"
         mountpoint -q "$nmp" && ok "Montado en $nmp (solo lectura)" || explicar_error_mount "$sal";;
      0) return 0;;
    esac
  else
    pantalla "TRABAJO '${ETIQUETA}'  >  Origen en Drive"
    say "  Actual: ${C_B}${RCLONE_REMOTE}:${DEST_PATH}${C_R}"
    echo
    say "  Cuentas conectadas:"; rclone listremotes 2>/dev/null | sed 's/^/    - /'
    echo
    pedir nrem "Cuenta a usar" "$RCLONE_REMOTE"
    if ! rc lsd "${nrem}:" >/dev/null 2>&1; then err "No se pudo acceder a esa cuenta."; enter; return 0; fi
    DEST_PATH=""
    drive_elegir_carpeta "$nrem"
    DEST_PATH="${DEST_PATH#/}"; DEST_PATH="${DEST_PATH%/}"
    set_conf "$conf" RCLONE_REMOTE "$nrem"; set_conf "$conf" DEST_PATH "$DEST_PATH"
    set_conf "$conf" ORIGEN_CONF ""
    ok "Origen actualizado: ${nrem}:${DEST_PATH}"
  fi
  enter
}

editar_posterior() {
  local conf="$1" op r p
  while true; do
    cargar_conf "$conf"
    pantalla "TRABAJO '${ETIQUETA}'  >  Despues de restaurar"
    say "  Sitio destino  : ${C_B}${SITE}${C_R}"
    say "  bench migrate  : ${MIGRAR}"
    say "  Programador    : ${SCHEDULER}"
    say "  Correo saliente: $([ "$MUTE_EMAILS" = si ] && echo "silenciado" || echo "intacto")"
    echo
    say "   1) Cambiar el sitio destino"
    say "   2) Ejecutar 'bench migrate' si/no"
    say "   3) Programador de tareas"
    say "   4) Silenciar el correo saliente si/no"
    say "   5) Contrasena de Administrator despues de restaurar"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) pantalla "TRABAJO '${ETIQUETA}'  >  Sitio destino"
         say "  ${C_RD}${C_B}Cuidado:${C_R} el sitio que elija aqui sera el que se sobrescriba."
         if pedir_frappe_destino; then
           if p="$(alerta_mismo_sitio "$SITE")"; then
             echo; warn "El sitio '${SITE}' es el que respalda el trabajo '${p}' de este servidor."
             confirmar_escribiendo "$SITE" || { err "No coincide. Sin cambios."; enter; continue; }
           fi
           set_conf "$conf" BENCH_PATH "$BENCH_PATH"
           set_conf "$conf" BENCH_USER "$BENCH_USER"
           set_conf "$conf" SITE "$SITE"
           DB_FLAG="$(detectar_flag_db)"
           [ -n "$DB_FLAG" ] && set_conf "$conf" DB_FLAG "$DB_FLAG"
           ok "Sitio destino actualizado."
         fi; enter;;
      2) si_no "Ejecutar 'bench migrate' despues de restaurar?" && r=si || r=no
         set_conf "$conf" MIGRAR "$r"; ok "Actualizado."; sleep 1;;
      3) say "    1) No tocarlo   2) Desactivarlo   3) Activarlo"
         read -rp "  Opcion [1-3]: " r || fin_entrada
         case "$r" in
           1) set_conf "$conf" SCHEDULER "no-tocar";;
           2) set_conf "$conf" SCHEDULER "desactivar";;
           3) set_conf "$conf" SCHEDULER "activar";;
           *) err "Opcion invalida."; sleep 1; continue;;
         esac
         ok "Actualizado."; sleep 1;;
      4) si_no "Silenciar el correo saliente del sitio restaurado?" && r=si || r=no
         set_conf "$conf" MUTE_EMAILS "$r"; ok "Actualizado."; sleep 1;;
      5) if si_no "Cambiar la contrasena de Administrator despues de cada restauracion?"; then
           pedir_secreto p "Contrasena para Administrator"
         else p=""; fi
         actualizar_dbcred "$conf" "" "$p"
         ok "Actualizado."; sleep 1;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

# Reescribe el archivo de credenciales conservando lo que no se cambia.
actualizar_dbcred() {   # $1=conf  $2=db (vacio = conservar)  $3=admin (cadena vacia = borrar)
  local conf="$1" nueva_db="$2" nuevo_admin="$3" db="" adm=""
  cargar_conf "$conf"
  if [ -r "$DB_CRED_FILE" ]; then
    db="$( . "$DB_CRED_FILE" >/dev/null 2>&1; printf '%s' "${DB_ROOT_PASS:-}" )"
    adm="$( . "$DB_CRED_FILE" >/dev/null 2>&1; printf '%s' "${ADMIN_PASS:-}" )"
  fi
  [ -n "$nueva_db" ] && db="$nueva_db"
  adm="$nuevo_admin"
  {
    printf '# Credenciales de restauracion - iZone ENTERPRISE\n'
    printf 'DB_ROOT_PASS=%q\n' "$db"
    printf 'ADMIN_PASS=%q\n' "$adm"
  } > "$DB_CRED_FILE"
  chmod 600 "$DB_CRED_FILE"
}

editar_credenciales() {
  local conf="$1" op u p d sal
  cargar_conf "$conf"
  while true; do
    cargar_conf "$conf"
    pantalla "TRABAJO '${ETIQUETA}'  >  Credenciales"
    say "  Base de datos : ${DB_CRED_FILE}  ${C_DIM}permisos $(stat -c '%a' "$DB_CRED_FILE" 2>/dev/null || echo '?')${C_R}"
    if [ "$JOB_TIPO" = "red" ]; then
      say "  Recurso de red: ${CRED_FILE}  ${C_DIM}permisos $(stat -c '%a' "$CRED_FILE" 2>/dev/null || echo '?')${C_R}"
      [ "$MONTAJE_PROPIO" != "si" ] && say "  ${C_DIM}Las credenciales del recurso pertenecen al gestor de respaldos.${C_R}"
    fi
    echo
    say "   1) Cambiar la contrasena de root de la base de datos"
    [ "$JOB_TIPO" = "red" ] && [ "$MONTAJE_PROPIO" = "si" ] && \
    say "   2) Cambiar las credenciales del recurso compartido"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) pedir_secreto p "Contrasena de root de la base de datos"
         info "Comprobando..."
         probar_password_db "$p"
         case "$?" in
           0) ok "La contrasena funciona.";;
           2) warn "No hay cliente 'mysql'; no se pudo comprobar.";;
           *) err "El motor local la rechazo."
              si_no "Guardarla de todas formas?" || { enter; continue; };;
         esac
         actualizar_dbcred "$conf" "$p" "$( . "$DB_CRED_FILE" >/dev/null 2>&1; printf '%s' "${ADMIN_PASS:-}" )"
         ok "Guardada."; enter;;
      2) [ "$JOB_TIPO" = "red" ] && [ "$MONTAJE_PROPIO" = "si" ] || { err "Opcion invalida."; sleep 1; continue; }
         pedir u "Usuario del recurso compartido"
         pedir_secreto p "Contrasena"
         pedir d "Dominio o grupo de trabajo" "WORKGROUP"
         { echo "username=${u}"; echo "password=${p}"; echo "domain=${d}"; } > "$CRED_FILE"
         chmod 600 "$CRED_FILE"; ok "Credenciales actualizadas."
         umount "$MOUNT_POINT" >/dev/null 2>&1
         sal="$(mount "$MOUNT_POINT" 2>&1)"
         mountpoint -q "$MOUNT_POINT" && ok "Montaje validado." || explicar_error_mount "$sal"
         enter;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

editar_previo() {
  local conf="$1" op v n
  while true; do
    cargar_conf "$conf"
    pantalla "TRABAJO '${ETIQUETA}'  >  Respaldo de seguridad"
    say "  Activo     : $([ "${PREVIO:-si}" = si ] && printf '%b' "${C_GR}si${C_R}" || printf '%b' "${C_RD}no${C_R}")"
    say "  Carpeta    : ${PREVIO_DIR}"
    say "  Se conservan: ${PREVIO_CONSERVAR}"
    n="$(ls -1d "${PREVIO_DIR}"/*/ 2>/dev/null | wc -l)"
    say "  Guardados  : ${n}"
    if [ "$n" -gt 0 ]; then
      echo; say "  ${C_DIM}Del mas reciente al mas antiguo:${C_R}"
      ls -1dt "${PREVIO_DIR}"/*/ 2>/dev/null | head -n 5 | sed 's/^/    /'
      say "  ${C_DIM}Para volver atras: restaure a mano con 'bench restore' desde uno${C_R}"
      say "  ${C_DIM}de esos archivos.${C_R}"
    fi
    echo
    say "   1) Activar o desactivar el respaldo previo"
    say "   2) Cambiar cuantos se conservan"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) if si_no "Respaldar el sitio destino antes de cada restauracion?"; then
           set_conf "$conf" PREVIO "si"
         else
           warn "Sin respaldo previo no hay vuelta atras."
           si_no "Confirma desactivarlo?" && set_conf "$conf" PREVIO "no"
         fi
         ok "Actualizado."; sleep 1;;
      2) read -rp "  Cuantos conservar: " v || fin_entrada
         if [[ "$v" =~ ^[0-9]+$ ]]; then set_conf "$conf" PREVIO_CONSERVAR "$v"; ok "Actualizado."
         else err "Escriba un numero entero."; fi; sleep 1;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

eliminar_trabajo() {
  local conf="$1"
  cargar_conf "$conf"
  pantalla "TRABAJO '${ETIQUETA}'  >  Eliminar"
  warn "Se quitara la programacion, el script y la configuracion."
  say "  ${C_DIM}Los respaldos del origen no se tocan: el montaje es de solo lectura.${C_R}"
  si_no "Confirma eliminar el trabajo '${JOB_NOMBRE}'?" || { enter; return 1; }
  cron_aplicar "$JOB_NOMBRE" ""
  rm -f "${BIN_DIR}/${JOB_NOMBRE}.sh" "$STATE_FILE" "$DB_CRED_FILE"
  if [ "$JOB_TIPO" = "red" ] && [ "${MONTAJE_PROPIO:-no}" = "si" ]; then
    if si_no "Desmontar y quitar la linea de /etc/fstab?"; then
      umount "$MOUNT_POINT" >/dev/null 2>&1
      fstab_quitar "$JOB_NOMBRE" "$MOUNT_POINT"
    fi
    rm -f "$CRED_FILE"
  fi
  if [ -d "${PREVIO_DIR:-}" ] && [ -n "$(ls -A "$PREVIO_DIR" 2>/dev/null)" ]; then
    echo
    warn "Quedan respaldos de seguridad en ${PREVIO_DIR}."
    say "  ${C_DIM}Son la unica copia del sitio anterior a cada restauracion.${C_R}"
    si_no "Borrarlos tambien?" && rm -rf "$PREVIO_DIR"
  fi
  rm -f "$conf"
  systemctl restart cron >/dev/null 2>&1
  ok "Trabajo eliminado."
  enter; return 0
}

menu_trabajo() {
  local conf="$1" op ultimo
  while true; do
    [ -f "$conf" ] || return 0
    cargar_conf "$conf"
    pantalla "TRABAJO: ${ETIQUETA}  [${JOB_TIPO}]"
    if [ "$JOB_TIPO" = "red" ]; then
      say "  Origen  : ${UNC}"
      mountpoint -q "$MOUNT_POINT" \
        && say "  Montaje : ${C_GR}activo${C_R} en ${MOUNT_POINT} ${C_DIM}(solo lectura)${C_R}" \
        || say "  Montaje : ${C_RD}inactivo${C_R} en ${MOUNT_POINT}"
    else
      say "  Origen  : ${RCLONE_REMOTE}:${DEST_PATH}"
    fi
    say "  Destino : sitio ${C_B}${SITE}${C_R}   ${C_DIM}${BENCH_PATH}  (usuario ${BENCH_USER})${C_R}"
    say "  Previo  : $([ "${PREVIO:-si}" = si ] && echo "si, conserva ${PREVIO_CONSERVAR}" || printf '%b' "${C_RD}no${C_R}")"
    if [ "${AUTOMATICO:-no}" = "si" ]; then
      say "  Horario : ${HORARIOS}   ($(describir_dias "$DIAS_CRON"))"
    else
      say "  Horario : ${C_DIM}solo manual${C_R}"
    fi
    ultimo="$(cat "$STATE_FILE" 2>/dev/null)"
    say "  Ultimo  : ${ultimo:-${C_DIM}ninguno restaurado todavia${C_R}}"
    echo
    say "   1) ${C_YL}Restaurar un respaldo de la lista${C_R}"
    say "   2) ${C_YL}Restaurar el mas reciente${C_R}"
    say "   3) Prueba en seco (no toca el sitio)"
    say "   4) Programacion automatica"
    say "   5) Origen de los respaldos"
    say "   6) Sitio destino y acciones posteriores"
    say "   7) Respaldo de seguridad"
    say "   8) Ver configuracion y log"
    say "   9) Credenciales"
    say "   d) ${C_RD}Eliminar este trabajo${C_R}"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "${op,,}" in
      1) restaurar_eligiendo "$conf";;
      2) restaurar_reciente "$conf";;
      3) prueba_en_seco "$conf";;
      4) menu_horarios "$conf";;
      5) editar_origen "$conf";;
      6) editar_posterior "$conf";;
      7) editar_previo "$conf";;
      8) pantalla "TRABAJO '${ETIQUETA}'  >  Configuracion"
         sed 's/^/    /' "$conf"; echo
         if [ "${AUTOMATICO:-no}" = "si" ]; then
           say "  ${C_B}Cron activo:${C_R}"; cron_mostrar "$JOB_NOMBRE"; echo
         fi
         say "  ${C_B}Ultimas lineas del log:${C_R}"
         tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || warn "Sin registros."
         enter;;
      9) editar_credenciales "$conf";;
      d) eliminar_trabajo "$conf" && return 0;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

# ====================== LISTA DE TRABAJOS ============================
menu_trabajos() {
  local op confs=() i
  while true; do
    pantalla "TRABAJOS DE RESTAURACION"
    mapfile -t confs < <(listar_confs)
    if [ "${#confs[@]}" -eq 0 ]; then
      warn "No hay ningun trabajo de restauracion configurado todavia."
      say "  ${C_DIM}Un trabajo es un origen de respaldos mas un sitio destino. Puede${C_R}"
      say "  ${C_DIM}quedar programado para mantener una copia al dia, o guardarse solo${C_R}"
      say "  ${C_DIM}para restaurar a mano cuando haga falta.${C_R}"
    else
      for i in "${!confs[@]}"; do
        ( cargar_conf "${confs[$i]}"
          local origen estado prog
          if [ "$JOB_TIPO" = "red" ]; then
            origen="$UNC"
            mountpoint -q "$MOUNT_POINT" && estado="${C_GR}montado${C_R}" || estado="${C_RD}sin montar${C_R}"
          else
            origen="${RCLONE_REMOTE}:${DEST_PATH}"; estado="${C_DIM}nube${C_R}"
          fi
          if [ "${AUTOMATICO:-no}" = "si" ]; then
            prog="${HORARIOS}  ($(describir_dias "$DIAS_CRON"))"
          else
            prog="solo manual"
          fi
          printf '%b\n' "   ${C_B}$((i+1))) ${ETIQUETA}${C_R}  ${C_DIM}[${JOB_TIPO}]${C_R}  ${estado}"
          printf '%b\n' "       ${C_DIM}origen : ${origen}${C_R}"
          printf '%b\n' "       ${C_DIM}destino: sitio ${SITE}${C_R}"
          printf '%b\n' "       ${C_DIM}horario: ${prog}${C_R}"
        )
      done
    fi
    echo
    say "   ${C_B}r${C_R}) Nuevo trabajo desde una Unidad de Red (CIFS)"
    say "   ${C_B}g${C_R}) Nuevo trabajo desde Google Drive"
    say "   ${C_B}0${C_R}) Volver"
    echo
    read -rp "  Numero del trabajo, o letra: " op || fin_entrada
    case "$op" in
      r|R) crear_trabajo red;;
      g|G) crear_trabajo drive;;
      0)   return 0;;
      *)   if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le "${#confs[@]}" ]; then
             menu_trabajo "${confs[$((op-1))]}"
           else err "Opcion invalida."; sleep 1; fi;;
    esac
  done
}

# ========================== DIAGNOSTICO ==============================
diagnostico() {
  local confs=() i
  mapfile -t confs < <(listar_confs)
  if [ "${#confs[@]}" -eq 0 ]; then
    pantalla "DIAGNOSTICO"; warn "No hay ningun trabajo de restauracion configurado."; enter; return 0
  fi
  for i in "${!confs[@]}"; do
    pantalla "DIAGNOSTICO  ($((i+1)) de ${#confs[@]})"
    ( cargar_conf "${confs[$i]}"
      local n scr ult
      say "  ${C_B}${C_CY}== ${ETIQUETA}  [${JOB_TIPO}] ==${C_R}"
      echo
      say "  ${C_B}Origen${C_R}"
      if [ "$JOB_TIPO" = "red" ]; then
        say "  ${C_DIM}recurso: ${UNC}${C_R}"
        if mountpoint -q "$MOUNT_POINT"; then
          ok "montado en $MOUNT_POINT"
          df -h "$MOUNT_POINT" | tail -n1 | sed 's/^/    /'
          case "${MOUNT_OPTS:-}" in ro,*|*,ro,*|*,ro) ok "montado en solo lectura";; esac
          n="$(listar_respaldos_red "$MOUNT_POINT" | wc -l)"
          if [ "$n" -gt 0 ]; then
            ok "respaldos visibles: ${n}"
            say "  ${C_DIM}mas recientes:${C_R}"
            listar_respaldos_red "$MOUNT_POINT" | head -n 3 | sed 's/|/   /' | sed 's/^/    /'
          else err "no se ve ningun respaldo con estructura <fecha>/<hora>"; fi
        else err "NO montado en $MOUNT_POINT"; fi
        [ -f "$CRED_FILE" ] && ok "credenciales del recurso: permisos $(stat -c '%a' "$CRED_FILE")" \
                            || err "faltan las credenciales del recurso: $CRED_FILE"
        if [ "${MONTAJE_PROPIO:-no}" = "si" ]; then
          grep -q "$MOUNT_POINT" /etc/fstab && ok "entrada propia en /etc/fstab" || err "sin entrada en /etc/fstab"
        else
          say "  ${C_DIM}montaje heredado de $(basename "${ORIGEN_CONF:-?}")${C_R}"
          [ -f "${ORIGEN_CONF:-}" ] && ok "el trabajo de respaldo de origen sigue existiendo" \
                                    || warn "el trabajo de respaldo de origen ya no existe"
        fi
      else
        export RCLONE_CONFIG
        rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:" \
          && ok "cuenta '${RCLONE_REMOTE}' registrada" || err "cuenta '${RCLONE_REMOTE}' no existe"
        if rc lsd "${RCLONE_REMOTE}:${DEST_PATH}" >/dev/null 2>&1; then
          ok "acceso a ${RCLONE_REMOTE}:${DEST_PATH}"
          n="$(listar_respaldos_drive "$RCLONE_REMOTE" "$DEST_PATH" | wc -l)"
          if [ "$n" -gt 0 ]; then
            ok "respaldos visibles: ${n}"
            say "  ${C_DIM}mas recientes:${C_R}"
            listar_respaldos_drive "$RCLONE_REMOTE" "$DEST_PATH" | head -n 3 | sed 's/|/   /' | sed 's/^/    /'
          else err "no se ve ningun respaldo con estructura <fecha>/<hora>"; fi
        else err "sin acceso a ${RCLONE_REMOTE}:${DEST_PATH}"; fi
      fi
      echo
      say "  ${C_B}Sitio destino${C_R}"
      [ -d "$BENCH_PATH" ] && ok "bench: $BENCH_PATH" || err "No existe el bench: $BENCH_PATH"
      [ -f "$BENCH_PATH/env/bin/activate" ] && ok "entorno virtual presente" || err "Falta env/bin/activate"
      id "$BENCH_USER" >/dev/null 2>&1 && ok "usuario de bench: $BENCH_USER" || err "El usuario $BENCH_USER no existe"
      [ -d "$BENCH_PATH/sites/$SITE" ] && ok "sitio: $SITE" || warn "aun no existe el sitio: $SITE"
      [ -f "$DB_CRED_FILE" ] && ok "credenciales de base de datos: permisos $(stat -c '%a' "$DB_CRED_FILE")" \
                             || err "faltan las credenciales de base de datos"
      scr="${BIN_DIR}/${JOB_NOMBRE}.sh"
      [ -x "$scr" ] && ok "script de restauracion presente" || err "falta el script $scr"
      echo
      say "  ${C_B}Seguridad y programacion${C_R}"
      if [ "${PREVIO:-si}" = "si" ]; then
        n="$(ls -1d "${PREVIO_DIR}"/*/ 2>/dev/null | wc -l)"
        ok "respaldo previo activo; guardados: ${n} de ${PREVIO_CONSERVAR}"
        [ -d "$PREVIO_DIR" ] && du -sh "$PREVIO_DIR" 2>/dev/null | sed 's/^/    /'
      else
        warn "respaldo previo desactivado: una restauracion no tiene vuelta atras"
      fi
      if [ "${AUTOMATICO:-no}" = "si" ]; then
        n="$(cron_mostrar "$JOB_NOMBRE")"
        if [ -n "$n" ]; then ok "cron activo:"; printf '%s\n' "$n"
        else err "marcado como automatico pero sin entradas de cron"; fi
        systemctl is-active --quiet cron 2>/dev/null && ok "servicio cron: activo" || err "servicio cron: inactivo"
      else
        say "  ${C_DIM}sin programacion automatica${C_R}"
      fi
      ult="$(cat "$STATE_FILE" 2>/dev/null)"
      [ -n "$ult" ] && ok "ultimo respaldo restaurado: ${ult}" || warn "todavia no se ha restaurado nada"
      if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        echo; say "  ${C_DIM}ultimas lineas del log:${C_R}"
        tail -n 6 "$LOG_FILE" | sed 's/^/    /'
      fi )
    enter
  done
}

# ========================= MENU PRINCIPAL ============================
menu_principal() {
  local op n_trabajos n_cuentas n_auto
  while true; do
    pantalla "MENU PRINCIPAL"
    n_trabajos="$(listar_confs | wc -l)"
    n_cuentas="$(rclone listremotes 2>/dev/null | wc -l)"
    n_auto="$(grep -l '^AUTOMATICO="si"' "$APP_DIR"/*.conf 2>/dev/null | wc -l)"
    say "   1) Trabajos de restauracion  ${C_DIM}-${C_R} ${n_trabajos} configurado(s), ${n_auto} programado(s)"
    say "   2) Cuentas de Google Drive   ${C_DIM}-${C_R} ${n_cuentas} conectada(s)"
    say "   3) Diagnostico"
    say "   0) Salir"
    echo
    say "  ${C_DIM}Restaurar reemplaza por completo la base de datos y los adjuntos del${C_R}"
    say "  ${C_DIM}sitio destino. Antes de hacerlo, el gestor respalda ese sitio para${C_R}"
    say "  ${C_DIM}que siempre haya vuelta atras.${C_R}"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) menu_trabajos;;
      2) menu_cuentas_drive;;
      3) diagnostico;;
      0) clear; say "  ${C_CY}iZone Enterprise - Restauracion${C_R}. Hasta luego.\n"; exit 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

requiere_root
mkdir -p "$APP_DIR" "$LOG_DIR" "$PREVIO_BASE"; chmod 750 "$APP_DIR" "$PREVIO_BASE"
menu_principal