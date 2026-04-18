#!/usr/bin/env bash
# lib/iso.sh — Windows ISO resolution, download, validation, and patching.
# Dockur integration (https://github.com/dockur/windows) is used as the
# primary URL resolver, bypassing Microsoft's browser-gated download flow.
# Requires DOCKUR_WINDOWS_SRC to point to a local clone of dockur/windows.
# Sourced by passthrough-setup.sh; requires lib/common.sh.

WINDOWS_ISO_URL="${WINDOWS_ISO_URL:-https://www.microsoft.com/en-us/software-download/windows11}"
VIRTIO_ISO_URL="${VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/}"
# Path to a local clone of https://github.com/dockur/windows (optional but recommended)
DOCKUR_WINDOWS_SRC="${DOCKUR_WINDOWS_SRC:-/home/${SUDO_USER:-${USER}}/github/windows/src}"
WINHANCE_SOURCE_XML="${WINHANCE_SOURCE_XML:-/home/${SUDO_USER:-${USER}}/Downloads/autounattend.xml}"
WINHANCE_SOURCE_URL="${WINHANCE_SOURCE_URL:-https://raw.githubusercontent.com/memstechtips/UnattendedWinstall/main/autounattend.xml}"
WINHANCE_CACHE_XML="${WINHANCE_CACHE_XML:-/etc/passthrough/source-cache/winhance-autounattend.xml}"


need_download_cmds() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required download command: ${cmd}"
  done
}

validate_iso_file() {
  local path="$1"
  local label="${2:-ISO}"
  local min_size_bytes="${3:-104857600}"
  local size description

  [[ -f "${path}" ]] || return 1
  size="$(file_size_bytes "${path}" || true)"
  [[ -n "${size}" && "${size}" =~ ^[0-9]+$ ]] || {
    warn "Could not determine size for ${label}: ${path}"
    return 1
  }
  if (( size < min_size_bytes )); then
    warn "${label} looks too small to be valid: ${path} (${size} bytes)."
    return 1
  fi

  if command -v file >/dev/null 2>&1; then
    description="$(file -b "${path}" 2>/dev/null || true)"
    case "${description}" in
      *ISO\ 9660*|*UDF\ filesystem*|*DOS/MBR\ boot\ sector*)
        return 0
        ;;
      *HTML*|*XML*|*ASCII\ text*|*Unicode\ text*|*JSON\ text*)
        warn "${label} is not an ISO image: ${path} (${description})"
        return 1
        ;;
    esac
  fi

  return 0
}

validate_winhance_source_xml() {
  local path="$1"
  [[ -f "${path}" ]] || return 1
  grep -q '<Extensions xmlns="urn:winhance:unattend">' "${path}" 2>/dev/null || return 1
  grep -q 'Winhancements\.ps1' "${path}" 2>/dev/null || return 1
}

resolve_winhance_source_xml() {
  local preferred="${1:-}"
  local tmp_output

  if [[ -n "${preferred}" && -f "${preferred}" ]]; then
    validate_winhance_source_xml "${preferred}" || fail "Winhance source XML is not valid: ${preferred}"
    printf '%s\n' "${preferred}"
    return 0
  fi

  if [[ -f "${WINHANCE_CACHE_XML}" ]]; then
    validate_winhance_source_xml "${WINHANCE_CACHE_XML}" || fail "Cached Winhance source XML is invalid: ${WINHANCE_CACHE_XML}"
    printf '%s\n' "${WINHANCE_CACHE_XML}"
    return 0
  fi

  need_download_cmds curl
  ensure_dir "$(dirname "${WINHANCE_CACHE_XML}")"
  tmp_output="$(mktemp "${WINHANCE_CACHE_XML}.tmp.XXXXXX")"
  if run curl -L --fail --output "${tmp_output}" "${WINHANCE_SOURCE_URL}" && validate_winhance_source_xml "${tmp_output}"; then
    mv -f "${tmp_output}" "${WINHANCE_CACHE_XML}"
    log "Cached Winhance source XML at ${WINHANCE_CACHE_XML}"
    printf '%s\n' "${WINHANCE_CACHE_XML}"
    return 0
  fi
  rm -f "${tmp_output}"
  fail "Could not obtain a valid Winhance source XML from ${WINHANCE_SOURCE_URL}"
}

ensure_libvirt_can_traverse_path() {
  local target_path="$1"
  local username="libvirt-qemu"
  local current_dir
  local -a dirs_to_check=()
  local dir

  [[ -e "${target_path}" ]] || return 0
  current_dir="$(dirname "${target_path}")"

  while [[ "${current_dir}" != "/" ]]; do
    dirs_to_check+=("${current_dir}")
    [[ "${current_dir}" == "/home" ]] && break
    current_dir="$(dirname "${current_dir}")"
  done

  local index
  for (( index=${#dirs_to_check[@]}-1; index>=0; index-- )); do
    dir="${dirs_to_check[$index]}"

    if command -v getfacl >/dev/null 2>&1 && getfacl "${dir}" 2>/dev/null | grep -q "user:${username}:.*x"; then
      continue
    fi

    if [[ -x "${dir}" ]]; then
      continue
    fi

    if command -v setfacl >/dev/null 2>&1; then
      if run setfacl --modify "user:${username}:x" "${dir}" 2>/dev/null; then
        ui_note "Granted ${username} traverse access to ${dir}" >&2
        continue
      fi
    fi

    if run chmod o+x "${dir}" 2>/dev/null; then
      ui_note "Granted world traverse access to ${dir}" >&2
      continue
    fi

    warn "Could not grant libvirt access to ${dir}. ${target_path} may not be readable by the VM."
    return 1
  done

  return 0
}

# ---------------------------------------------------------------------------
# Windows ISO download URL resolution
# ---------------------------------------------------------------------------
windows_download_user_agent() {
  local browser_version
  browser_version="$((124 + ($(date +%s) - 1710892800) / 2419200))"
  printf 'Mozilla/5.0 (X11; Linux x86_64; rv:%s.0) Gecko/20100101 Firefox/%s.0\n' "${browser_version}" "${browser_version}"
}

windows_static_download_url() {
  local version_id="${1:-win11x64}"
  local language_id="${2:-en}"

  case "${language_id}" in
    en|en-gb) ;;
    *) return 1 ;;
  esac

  case "${version_id}" in
    win11x64)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso"
      ;;
    win11x64-enterprise-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
      ;;
    win11x64-enterprise-iot-eval|win11x64-enterprise-ltsc-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1.240331-1435.ge_release_CLIENT_IOT_LTSC_EVAL_x64FRE_en-us.iso"
      ;;
    win10x64)
      printf '%s\n' "https://dl.bobpony.com/windows/10/en-us_windows_10_22h2_x64.iso"
      ;;
    win10x64-enterprise-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
      ;;
    win10x64-enterprise-ltsc-eval)
      printf '%s\n' "https://software-download.microsoft.com/download/pr/19044.1288.211006-0501.21h2_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso"
      ;;
    win2025-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26100.1742.240906-0331.ge_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
      ;;
    win2022-eval)
      printf '%s\n' "https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso"
      ;;
    win2019-eval)
      printf '%s\n' "https://software-download.microsoft.com/download/pr/17763.737.190906-2324.rs5_release_svc_refresh_SERVER_EVAL_x64FRE_en-us_1.iso"
      ;;
    win2019-hv)
      printf '%s\n' "https://software-download.microsoft.com/download/pr/17763.557.190612-0019.rs5_release_svc_refresh_SERVERHYPERCORE_OEM_x64FRE_en-us.ISO"
      ;;
    win2016-eval)
      printf '%s\n' "https://software-download.microsoft.com/download/F/3/C/F3C4E1E7-972A-4E22-879E-2AA1FA286A6A/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO"
      ;;
    *) return 1 ;;
  esac
}

resolve_windows_retail_download_url() {
  local version_id="${1:-win11x64}"
  local language_id="${2:-en}"
  local page_url="" windows_version="" download_type="1"
  local user_agent language_name session_id page_html product_edition_id profile sku_json sku_id iso_json iso_url rc

  case "${version_id}" in
    win11x64) windows_version="11" ;;
    win10x64) windows_version="10" ;;
    *) return 1 ;;
  esac

  user_agent="$(windows_download_user_agent)"
  language_name="$(windows_language_name "${language_id}")"
  page_url="https://www.microsoft.com/en-us/software-download/windows${windows_version}"
  [[ "${version_id}" == "win10x64" ]] && page_url+="ISO"
  profile="606624d44113"
  session_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  session_id="${session_id//[![:print:]]/}"

  page_html="$(curl --silent --max-time 30 --user-agent "${user_agent}" --header "Accept:" --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "${page_url}")" || return 1
  product_edition_id="$(printf '%s' "${page_html}" | grep -Eo '<option value="[0-9]+">Windows' | cut -d '"' -f2 | head -n1 | tr -cd '0-9' | head -c 16)"
  [[ -n "${product_edition_id}" ]] || return 1

  curl --silent --max-time 30 --output /dev/null --user-agent "${user_agent}" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- \
    "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=${session_id}" || return 1

  sku_json="$(curl --silent --max-time 30 --request GET --user-agent "${user_agent}" --referer "${page_url}" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- \
    "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=${profile}&ProductEditionId=${product_edition_id}&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}")" || return 1
  { sku_id="$(printf '%s' "${sku_json}" | jq -r --arg LANG "${language_name}" '.Skus?[]? | select(.Language==$LANG).Id' | head -n1)"; rc=$?; } || :
  [[ -n "${sku_id}" && "${sku_id}" != "null" && "${rc}" -eq 0 ]] || return 1

  iso_json="$(curl --silent --max-time 30 --request GET --user-agent "${user_agent}" --referer "${page_url}" --header "Accept:" --max-filesize 100K --proto =https --tlsv1.2 --http1.1 -- \
    "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=${profile}&ProductEditionId=undefined&SKU=${sku_id}&friendlyFileName=undefined&Locale=en-US&sessionID=${session_id}")" || return 1
  [[ -n "${iso_json}" ]] || return 1

  if printf '%s' "${iso_json}" | grep -q "Sentinel marked this request as rejected."; then
    warn "Microsoft blocked the automated retail download request based on your IP address."
    return 1
  fi
  if printf '%s' "${iso_json}" | grep -q "We are unable to complete your request at this time."; then
    warn "Microsoft rejected the automated retail download request at this time."
    return 1
  fi

  { iso_url="$(printf '%s' "${iso_json}" | jq -r '.ProductDownloadOptions?[]? | select(.DownloadType==1).Uri' | head -n1)"; rc=$?; } || :
  [[ -n "${iso_url}" && "${iso_url}" != "null" && "${rc}" -eq 0 ]] || return 1
  printf '%s\n' "${iso_url}"
}

resolve_windows_eval_download_url() {
  local version_id="${1:-win11x64-enterprise-eval}"
  local language_id="${2:-en}"
  local user_agent culture country url html filter links resolved

  case "${version_id}" in
    win11x64-enterprise-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise" ;;
    win11x64-enterprise-iot-eval|win11x64-enterprise-ltsc-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-11-iot-enterprise-ltsc-eval" ;;
    win10x64-enterprise-eval|win10x64-enterprise-ltsc-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-10-enterprise" ;;
    win2025-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025" ;;
    win2022-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022" ;;
    win2019-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2019" ;;
    win2019-hv) url="https://www.microsoft.com/en-us/evalcenter/download-hyper-v-server-2019" ;;
    win2016-eval) url="https://www.microsoft.com/en-us/evalcenter/download-windows-server-2016" ;;
    *) return 1 ;;
  esac

  user_agent="$(windows_download_user_agent)"
  culture="$(windows_language_culture "${language_id}")"
  country="${culture#*-}"
  html="$(curl --silent --max-time 30 --user-agent "${user_agent}" --location --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "${url}")" || return 1
  [[ -n "${html}" ]] || return 1

  filter="https://go.microsoft.com/fwlink/?linkid=[0-9]\\+&clcid=0x[0-9a-z]\\+&culture=${culture,,}&country=${country,,}"
  if ! printf '%s' "${html}" | grep -io "${filter}" >/dev/null; then
    filter="https://go.microsoft.com/fwlink/p/?linkid=[0-9]\\+&clcid=0x[0-9a-z]\\+&culture=${culture,,}&country=${country,,}"
  fi
  links="$(printf '%s' "${html}" | grep -io "${filter}" || true)"
  [[ -n "${links}" ]] || return 1

  case "${version_id}" in
    win11x64-enterprise-eval|win11x64-enterprise-iot-eval|win11x64-enterprise-ltsc-eval|win2025-eval|win2022-eval|win2019-eval|win2019-hv|win2016-eval)
      resolved="$(printf '%s\n' "${links}" | head -n1)"
      ;;
    win10x64-enterprise-eval)
      resolved="$(printf '%s\n' "${links}" | head -n2 | tail -n1)"
      ;;
    win10x64-enterprise-ltsc-eval)
      resolved="$(printf '%s\n' "${links}" | head -n4 | tail -n1)"
      ;;
    *) return 1 ;;
  esac

  [[ -n "${resolved}" ]] || return 1
  curl --silent --max-time 30 --user-agent "${user_agent}" --location --output /dev/null --write-out "%{url_effective}" --head --fail --proto =https --tlsv1.2 --http1.1 -- "${resolved}" || return 1
}

resolve_windows_download_url() {
  local version_id="${1:-win11x64}"
  local language_id="${2:-en}"
  local url=""

  url="$(windows_static_download_url "${version_id}" "${language_id}" || true)"
  if [[ -n "${url}" ]]; then
    printf '%s\n' "${url}"
    return 0
  fi

  case "${version_id}" in
    win10x64|win11x64)
      resolve_windows_retail_download_url "${version_id}" "${language_id}"
      ;;
    win11x64-enterprise-*|win10x64-enterprise-*|win2025-eval|win2022-eval|win2019-eval|win2019-hv|win2016-eval)
      resolve_windows_eval_download_url "${version_id}" "${language_id}" || windows_static_download_url "${version_id}" "${language_id}"
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Dockur mirror URL resolver (preferred over Microsoft direct downloads)
# Requires a local clone of https://github.com/dockur/windows at
# DOCKUR_WINDOWS_SRC. When present, mido.sh resolves third-party mirror
# links so the download skips Microsoft's browser-gated flow entirely.
# ---------------------------------------------------------------------------
dockur_windows_download_url() {
  local version_id="${1:-win11x64}"
  local language_id="${2:-en}"
  local define_sh="${DOCKUR_WINDOWS_SRC}/define.sh"
  local mido_sh="${DOCKUR_WINDOWS_SRC}/mido.sh"
  local description

  [[ -f "${define_sh}" && -f "${mido_sh}" ]] || return 1
  description="Windows $(windows_language_desc "${language_id}")"

  /usr/bin/env bash -lc '
set -euo pipefail
VERSION_ID="$1"
LANGUAGE_ID="$2"
DESCRIPTION="$3"
DEFINE_SH="$4"
MIDO_SH="$5"
PLATFORM="x64"
DEBUG="N"
VERIFY="N"
SUPPORT="https://github.com/dockur/windows"
MIDO_URL=""
info() { :; }
html() { :; }
warn() { printf "%s\n" "$*" >&2; }
error() { printf "%s\n" "$*" >&2; return 1; }
source "$DEFINE_SH"
source "$MIDO_SH"
getWindows "$VERSION_ID" "$LANGUAGE_ID" "$DESCRIPTION" >/dev/null
printf "%s\n" "$MIDO_URL"
' bash "${version_id}" "${language_id}" "${description}" "${define_sh}" "${mido_sh}" 2>/dev/null
}

download_windows_iso() {
  local output_path="$1"
  local version_id="${2:-win11x64}"
  local language_id="${3:-en}"
  local iso_url tmp_output
  local -a curl_download_cmd

  need_download_cmds curl jq
  # Try Dockur mirror first — bypasses Microsoft's browser-gated download
  iso_url="$(dockur_windows_download_url "${version_id}" "${language_id}" || true)"
  if [[ -n "${iso_url}" ]]; then
    log "Resolved Windows ISO URL via Dockur mirror: ${iso_url}"
  else
    log "Dockur source not found at ${DOCKUR_WINDOWS_SRC}; falling back to Microsoft download"
    iso_url="$(resolve_windows_download_url "${version_id}" "${language_id}" || true)"
  fi
  [[ -n "${iso_url}" ]] || {
    warn "Could not resolve a Windows ISO download URL for ${version_id} (${language_id})."
    return 1
  }
  [[ "${iso_url}" == http* ]] || {
    warn "Resolved Windows ISO URL is invalid: ${iso_url}"
    return 1
  }
  log "Resolved Windows ISO URL: ${iso_url}"

  ensure_dir "$(dirname "${output_path}")"
  tmp_output="$(mktemp "${output_path}.tmp.XXXXXX")"
  curl_download_cmd=(curl -L --fail --output "${tmp_output}")
  if [[ -t 1 ]]; then
    curl_download_cmd+=(--progress-bar)
  fi
  curl_download_cmd+=("${iso_url}")
  if run "${curl_download_cmd[@]}" && validate_iso_file "${tmp_output}" "Windows ISO" 536870912; then
    mv -f "${tmp_output}" "${output_path}"
    return 0
  fi
  rm -f "${tmp_output}"
  return 1
}

# ---------------------------------------------------------------------------
# ISO prompt / strategy helpers
# ---------------------------------------------------------------------------
download_virtio_iso() {
  local output_path="$1"
  local iso_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"
  local tmp_output
  local -a curl_download_cmd

  need_download_cmds curl
  log "Resolved Virtio ISO URL: ${iso_url}"

  ensure_dir "$(dirname "${output_path}")"
  tmp_output="$(mktemp "${output_path}.tmp.XXXXXX")"
  curl_download_cmd=(curl -L --fail --output "${tmp_output}")
  if [[ -t 1 ]]; then
    curl_download_cmd+=(--progress-bar)
  fi
  curl_download_cmd+=("${iso_url}")
  if run "${curl_download_cmd[@]}" && validate_iso_file "${tmp_output}" "Virtio ISO" 104857600; then
    mv -f "${tmp_output}" "${output_path}"
    return 0
  fi
  rm -f "${tmp_output}"
  return 1
}

# ---------------------------------------------------------------------------
# ISO prompt / strategy helpers
# ---------------------------------------------------------------------------
prompt_virtio_iso_strategy() {
  local detected="${1:-}"
  local answer

  while :; do
    ui_section "Virtio Media" >&2
    if [[ -n "${detected}" && -f "${detected}" ]]; then
      ui_note "Detected local Virtio ISO: ${detected}" >&2
      ui_note "Choose how you want to continue:" >&2
      answer="$(prompt_menu_choice "Virtio ISO option" "1" \
        "Use detected ISO" \
        "Enter a different ISO path" \
        "Download Virtio ISO automatically")"
      case "${answer}" in
        "Use detected ISO") printf 'detected\n'; return 0 ;;
        "Enter a different ISO path") printf 'manual\n'; return 0 ;;
        "Download Virtio ISO automatically") printf 'download\n'; return 0 ;;
      esac
    else
      ui_note "No local Virtio ISO was detected." >&2
      ui_note "Choose how you want to continue:" >&2
      answer="$(prompt_menu_choice "Virtio ISO option" "1" \
        "Enter a Virtio ISO path" \
        "Download Virtio ISO automatically")"
      case "${answer}" in
        "Enter a Virtio ISO path") printf 'manual\n'; return 0 ;;
        "Download Virtio ISO automatically") printf 'download\n'; return 0 ;;
      esac
    fi
    warn "Choose one of the listed Virtio ISO options."
  done
}

choose_virtio_iso() {
  local detected="${1:-}"
  local strategy answer

  strategy="$(prompt_virtio_iso_strategy "${detected}")"
  case "${strategy}" in
    detected)
      printf '%s\n' "${detected}"
      return 0
      ;;
    manual)
      prompt_iso_path "Virtio ISO path" "" "${VIRTIO_ISO_URL}" "0"
      return 0
      ;;
    download)
      answer="/var/lib/libvirt/images/virtio-win.iso"
      ui_note "Automatic download target: ${answer}" >&2
      if download_virtio_iso "${answer}" >&2; then
        printf '%s\n' "${answer}"
        return 0
      fi
      warn "Automatic Virtio ISO download failed."
      ui_note "Official download page: ${VIRTIO_ISO_URL}" >&2
      prompt_iso_path "Virtio ISO path" "" "${VIRTIO_ISO_URL}" "0"
      return 0
      ;;
  esac

  fail "Could not determine how to obtain the Virtio ISO."
}

prompt_windows_iso_strategy() {
  local detected="${1:-}"
  local answer

  while :; do
    ui_section "Windows Media" >&2
    if [[ -n "${detected}" && -f "${detected}" ]]; then
      ui_note "Detected local Windows ISO: ${detected}" >&2
      ui_note "Choose how you want to continue:" >&2
      answer="$(prompt_menu_choice "Windows ISO option" "1" \
        "Use detected ISO" \
        "Enter a different ISO path" \
        "Download Windows ISO automatically")"
      case "${answer}" in
        "Use detected ISO") printf 'detected\n'; return 0 ;;
        "Enter a different ISO path") printf 'manual\n'; return 0 ;;
        "Download Windows ISO automatically") printf 'download\n'; return 0 ;;
      esac
    else
      ui_note "No local Windows ISO was detected." >&2
      ui_note "Choose how you want to continue:" >&2
      answer="$(prompt_menu_choice "Windows ISO option" "1" \
        "Enter a Windows ISO path" \
        "Download Windows ISO automatically")"
      case "${answer}" in
        "Enter a Windows ISO path") printf 'manual\n'; return 0 ;;
        "Download Windows ISO automatically") printf 'download\n'; return 0 ;;
      esac
    fi
    warn "Choose one of the listed Windows ISO options."
  done
}

choose_windows_iso() {
  local detected="${1:-}"
  local version_id="${2:-win11x64}"
  local language_id="${3:-en}"
  local strategy answer

  strategy="$(prompt_windows_iso_strategy "${detected}")"
  case "${strategy}" in
    detected)
      printf '%s\n' "${detected}"
      return 0
      ;;
    manual)
      prompt_iso_path "Windows ISO path" "" "${WINDOWS_ISO_URL}" "1" "${version_id}" "${language_id}"
      return 0
      ;;
    download)
      answer="/var/lib/libvirt/images/windows-install.iso"
      ui_note "Automatic download target: ${answer}" >&2
      if download_windows_iso "${answer}" "${version_id}" "${language_id}" >&2; then
        printf '%s\n' "${answer}"
        return 0
      fi
      warn "Automatic Windows ISO download failed."
      ui_note "Official download page: ${WINDOWS_ISO_URL}" >&2
      prompt_iso_path "Windows ISO path" "" "${WINDOWS_ISO_URL}" "1" "${version_id}" "${language_id}"
      return 0
      ;;
  esac

  fail "Could not determine how to obtain the Windows ISO."
}

prompt_iso_path() {
  local label="$1"
  local detected="${2:-}"
  local url="$3"
  local required="${4:-0}"
  local version_id="${5:-win11x64}"
  local language_id="${6:-en}"
  local answer

  while :; do
    if [[ -n "${detected}" && -f "${detected}" ]]; then
      answer="$(prompt "${label}" "${detected}")"
    else
      printf '%s\n' "No local ${label,,} detected." >&2
      printf '%s\n' "Official download page: ${url}" >&2
      if [[ "${required}" == "1" ]]; then
        answer="$(prompt "${label}")"
      else
        answer="$(prompt "${label} (leave blank to keep unset)")"
      fi
    fi

    if [[ -z "${answer}" ]]; then
      if [[ "${required}" == "1" ]]; then
        warn "${label} is required."
        printf '%s\n' "Official download page: ${url}" >&2
        continue
      fi
      printf '\n'
      return 0
    fi

    if [[ -f "${answer}" ]]; then
      if [[ "${label}" == *ISO* ]] && ! validate_iso_file "${answer}" "${label}" 104857600; then
        warn "Choose a valid ISO image for ${label}."
        printf '%s\n' "Official download page: ${url}" >&2
        detected=""
        continue
      fi
      ensure_libvirt_can_traverse_path "${answer}"
      printf '%s\n' "${answer}"
      return 0
    fi

    warn "${label} not found at ${answer}"
    printf '%s\n' "Official download page: ${url}" >&2
    detected=""
  done
}
