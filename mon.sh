#!/usr/bin/env bash
# fedmon (bash edition) - terminal system monitor for Fedora / KDE Plasma.
# Pure bash: reads /proc and /sys with shell builtins. It only starts other programs for
# `stat` (disk), `nvidia-smi` and `timeout`. Needs bash 5+ and a 256-color UTF-8 terminal.
# Keys: q quit | a cat on/off

REFRESH=2          # seconds between updates
PROC_EVERY=8       # seconds between scans of running programs
DISK_EVERY=10      # disk usage is read every this many samples (it starts a program)
NV_EVERY=3         # seconds between nvidia-smi calls (the most expensive call on a hybrid laptop)
HIST=300           # samples kept for graphs

case ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *) export LC_ALL=C.UTF-8 ;;
esac
shopt -s checkwinsize

# ───────────── colors: one per section ─────────────
E=$'\e'; RST="${E}[0m"; BOLD="${E}[1m"; DIM="${E}[2m"
col() { printf -v "$1" '%s' "${E}[38;5;$2m"; }
col VIOLET 141; col GOLD 221; col PINK 205; col SKY 75; col TEAL 79; col LIME 155
HDR="${E}[1;38;5;231;48;5;98m"       # white on a violet bar
BLK=" ▁▂▃▄▅▆▇█"                       # eight-level bar characters
printf -v SPC '%*s' 500 ''; BAR=${SPC// /■}; HLN=${SPC// /─}   # pre-built runs, sliced by rep()
ACC=$VIOLET                           # "ok" color of the section being drawn

# ───────────── cat art (braille), three sizes ─────────────
ART_S=(
  "⠀⠀⠀⠀⠀⠀⢀⣿⡀⠀⠀⠀⠀⠀⠀⠀"
  "⠀⠀⠀⠀⠀⢀⣾⣿⡇⠀⠀⠀⠀⠀⣠⣿"
  "⠀⠀⠀⠀⠀⣸⣿⣿⡇⠀⠀⠀⢠⣾⣿⡟"
  "⠀⠀⠀⠀⢠⣿⣿⣿⣇⠀⠀⣰⣿⣿⣿⡇"
  "⠀⠀⠀⣴⣿⠿⢿⣿⣿⣿⣾⣿⣿⣿⣿⠃"
  "⠀⠀⢸⣟⠀⢀⡎⣿⣿⡿⢛⠛⢿⣿⣏⠀"
  "⢉⣉⠘⢿⣦⣌⣥⣿⣿⡁⡏⠀⢀⣿⣿⠀"
  "⠉⠀⠀⠀⠙⠿⢿⣿⣿⣿⣶⣶⣾⠿⠁⠀"
  "⠀⠀⠀⠀⠀⠀⠀⠈⠉⠉⠉⠉⠁⢀⠈⠑"
)
ART_M=(
  "⠀⠀⠀⠀⠀⠀⠀⠀⢸⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀"
  "⠀⠀⠀⠀⠀⠀⠀⣤⣿⣿⠀⠀⠀⠀⠀⠀⠀⢀⣶⡆"
  "⠀⠀⠀⠀⠀⠀⢰⣿⣿⣿⠀⠀⠀⠀⠀⠀⣠⣾⣿⡇"
  "⠀⠀⠀⠀⠀⠀⣾⣿⣿⣿⠀⠀⠀⠀⢠⣼⣿⣿⣿⠀"
  "⠀⠀⠀⠀⠀⣰⣿⣿⣿⣿⣄⣀⡀⣠⣿⣿⣿⣿⣿⠀"
  "⠀⠀⠀⢰⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠉⠀"
  "⠀⠀⠀⣾⡿⠉⠀⣤⢻⣿⣿⣿⡿⠿⢿⣿⣿⡟⠀⠀"
  "⠶⠶⠆⣿⣿⡀⠸⠿⢸⣿⣿⠿⢰⠇⠀⠈⣿⣿⠀⠀"
  "⠤⠖⠂⠈⠙⢿⣷⣿⣿⣿⣿⣶⣜⣀⣀⣰⣿⠟⠀⠀"
  "⠀⠀⠀⠀⠀⠀⠛⠛⠿⣿⣿⣿⣿⣿⣿⡿⠛⢀⣀⠀"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠠⡀⠀⠁"
)
ART_L=(
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⣼⣿⣧⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⣼⣿⣿⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⡇"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⣼⣿⣿⣿⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⣼⣿⣿⡇"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⣿⣿⣿⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⣀⣤⣿⣿⣿⡿⠇"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⢰⣾⣿⣿⣿⣿⣿⡇⠀⠀⠀⠀⠀⠀⠀⣀⣿⣿⣿⣿⣿⡇⠀"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⣸⣿⣿⣿⣿⣿⣿⡇⠀⠀⠀⠀⠀⠀⣶⣿⣿⣿⣿⣿⣿⡇⠀"
  "⠀⠀⠀⠀⠀⠀⠀⠀⣀⣿⣿⣿⣿⣿⣿⣿⣷⣆⣀⣀⠀⣀⣶⣿⣿⣿⣿⣿⣿⣿⡇⠀"
  "⠀⠀⠀⠀⠀⠀⣀⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣶⣿⣿⣿⣿⣿⣿⣿⣿⡿⠇⠀"
  "⠀⠀⠀⠀⠀⠀⣿⣿⣿⡟⠛⠛⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠀⠀"
  "⠀⠀⠀⠀⠀⣿⣿⣿⠀⠀⠀⢠⡜⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⠃⠀⠀"
  "⠀⠀⠀⠀⠀⣿⣿⣤⠀⠀⢠⣼⡇⢸⣿⣿⣿⣿⣿⠛⠀⣤⠀⠀⠛⣿⣿⣿⣧⡄⠀⠀"
  "⠛⠛⠛⠛⠀⣿⣿⣿⣤⠀⠘⠛⠃⢸⣿⣿⣿⣿⠛⠀⣿⠛⠀⠀⠀⠀⣿⣿⣿⡇⠀⠀"
  "⣀⣤⠤⠤⠀⠀⠛⠿⣿⣿⣧⣼⣿⣿⣿⣿⣿⣿⣤⣀⠿⠀⠀⠀⠀⣤⣿⣿⡿⠇⠀⠀"
  "⠉⠉⠀⠀⠀⠀⠀⠀⠉⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣶⣶⣶⣶⣶⣿⣿⡏⠁⠀⠀⠀"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠉⠹⠿⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠿⠉⠁⢀⣀⡀⠀"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠀⠀⠀⠈⠉⠱⠶"
  "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢆⡀⠀⠀⠀"
)

# ───────────── data collection ─────────────
declare -a CUR_T CUR_I PREV_T PREV_I P H_CPU H_IN H_NV AN AB AC FREQ_FILES
declare -A COMM
PSCANS=0
NCPU=0

read_cpu_stat() {
  local name u n s id io irq sirq st rest i=0
  while read -r name u n s id io irq sirq st rest; do
    [[ $name == cpu* ]] || break
    CUR_T[i]=$((u+n+s+id+io+irq+sirq+st)); CUR_I[i]=$((id+io)); i=$((i+1))
  done </proc/stat
  NCPU=$((i-1))
}

push() { local -n _a=$1; _a+=("$2"); (( ${#_a[@]} > HIST )) && _a=("${_a[@]:1}"); }

sample_cpu() {
  read_cpu_stat
  local i dt di
  for ((i=0; i<=NCPU; i++)); do
    dt=$((CUR_T[i]-PREV_T[i])); di=$((CUR_I[i]-PREV_I[i]))
    if (( dt > 0 )); then P[i]=$(( (100*(dt-di) + dt/2) / dt )); else P[i]=0; fi
    (( P[i] < 0 )) && P[i]=0; (( P[i] > 100 )) && P[i]=100
    PREV_T[i]=${CUR_T[i]}; PREV_I[i]=${CUR_I[i]}
  done
  usage=${P[0]}
  push H_CPU "$usage"
}

read_mem() {
  local k v rest sf=0
  while read -r k v rest; do
    case $k in
      MemTotal:) MT=$((v*1024)) ;;
      MemAvailable:) MA=$((v*1024)) ;;
      SwapTotal:) ST=$((v*1024)) ;;
      SwapFree:) sf=$((v*1024)) ;;
    esac
  done </proc/meminfo
  MU=$((MT-MA)); SU=$((ST-sf))
}

read_disk() {
  local bs blocks bfree bavail
  read -r bs blocks bfree bavail < <(stat -f -c '%S %b %f %a' /)
  DT=$((blocks*bs)); DU=$(((blocks-bfree)*bs)); DF=$((bavail*bs))
  DP=$(( 100*DU/(DU+DF) ))
}

find_cpu_temp() {
  local hw n f lab
  for hw in /sys/class/hwmon/hwmon*; do
    read -r n 2>/dev/null <"$hw/name" || continue
    [[ $n == coretemp ]] || continue
    for f in "$hw"/temp*_input; do
      lab=; read -r lab 2>/dev/null <"${f%_input}_label"
      if [[ $lab == Package* ]]; then CT_FILE=$f; return; fi
      [[ -z $CT_FILE ]] && CT_FILE=$f
    done
  done
}

find_freq_files() {
  local f
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [[ -r $f ]] && FREQ_FILES+=("$f")
  done
}

find_intel() {
  local d l
  for d in /sys/class/drm/card[0-9]; do
    l=$(readlink "$d/device/driver" 2>/dev/null) || continue
    if [[ ${l##*/} == i915 ]]; then INTEL=$d; return; fi
  done
}

read_cpu_info() {
  local v sum=0 f
  ct=; freq=
  if [[ -n $CT_FILE ]] && read -r v 2>/dev/null <"$CT_FILE"; then ct=$((v/1000)); fi
  if (( ${#FREQ_FILES[@]} )); then
    for f in "${FREQ_FILES[@]}"; do read -r v 2>/dev/null <"$f" && sum=$((sum+v)); done
    freq=$(( sum / ${#FREQ_FILES[@]} / 1000 ))
  fi
}

read_intel() {
  iu=; ifreq=
  [[ -z $INTEL ]] && return
  local rc6 now=${EPOCHREALTIME/[.,]/} wall idle
  read -r rc6 2>/dev/null <"$INTEL/gt/gt0/rc6_residency_ms" || return
  read -r ifreq 2>/dev/null <"$INTEL/gt/gt0/rps_cur_freq_mhz"
  if [[ -n $IRC6 ]]; then
    wall=$(( (now-ITIME)/1000 ))
    if (( wall > 0 )); then
      idle=$(( 100*(rc6-IRC6)/wall )); iu=$((100-idle))
      (( iu < 0 )) && iu=0; (( iu > 100 )) && iu=100
    fi
  fi
  IRC6=$rc6; ITIME=$now
  [[ -n $iu ]] && push H_IN "$iu"
}

read_nvidia() {
  (( HAVE_NV )) || return
  if (( NOW_S - NV_T >= NV_EVERY )); then            # nvidia-smi is a program start: ask every 3s
    NV_T=$NOW_S
    local out a b
    out=$(timeout 2 nvidia-smi --query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>/dev/null)
    IFS=', ' read -r a b <<<"$out"
    if [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]]; then gt=$a; gu=$b; else gt=; gu=; fi
  fi
  [[ -n $gu ]] && push H_NV "$gu"
}

read_battery() {
  bat=; bstat=
  read -r bat 2>/dev/null </sys/class/power_supply/BAT0/capacity
  read -r bstat 2>/dev/null </sys/class/power_supply/BAT0/status
}

read_procs() {      # private RAM (resident minus shared) per program name, biggest first
  local -A tot cnt
  local f pid name res shr priv i k v best bk
  (( PSCANS++ % 20 == 0 )) && COMM=()           # forget cached names now and then (PIDs get reused)
  for f in /proc/[0-9]*/statm; do
    read -r _ res shr _ 2>/dev/null <"$f" || continue
    priv=$(( (res-shr) * PAGE ))
    (( priv > 0 )) || continue
    pid=${f#/proc/}; pid=${pid%/statm}
    name=${COMM[$pid]}
    if [[ -z $name ]]; then
      read -r name 2>/dev/null <"/proc/$pid/comm" || continue
      COMM[$pid]=$name
    fi
    tot["$name"]=$(( ${tot["$name"]:-0} + priv ))
    cnt["$name"]=$(( ${cnt["$name"]:-0} + 1 ))
  done
  AN=(); AB=(); AC=()
  for ((i=0; i<20; i++)); do
    best=0; bk=
    for k in "${!tot[@]}"; do
      v=${tot["$k"]}
      if (( v > best )); then best=$v; bk=$k; fi
    done
    [[ -z $bk ]] && break
    AN+=("$bk"); AB+=("$best"); AC+=("${cnt["$bk"]}"); tot["$bk"]=0
  done
}

read_model() {
  local k v
  MODEL=CPU
  while IFS=: read -r k v; do
    if [[ $k == "model name"* ]]; then
      v=${v//(R)/}; v=${v//(TM)/}; v=${v//CPU/}; v=${v%%@*}
      set -f; set -- $v; set +f
      MODEL=$*; return
    fi
  done </proc/cpuinfo
}

sample() {
  sample_cpu; read_mem; read_cpu_info; read_intel; read_nvidia; read_battery
  read -r UP _ </proc/uptime; UP=${UP%.*}
  read -r L1 L5 L15 _ </proc/loadavg
  SAMPLES=$((SAMPLES+1))
  (( SAMPLES % DISK_EVERY == 1 )) && read_disk            # disk changes slowly
  if (( NOW_S - PROC_T >= PROC_EVERY )); then PROC_T=$NOW_S; read_procs; fi
}

# ───────────── formatting helpers ─────────────
gib() { local x=$(( $1*10 >> 30 )); printf -v G '%d.%d GiB' $((x/10)) $((x%10)); }
fsize() { if (( $1 >= 1<<30 )); then gib "$1"; FS=$G; else printf -v FS '%d MiB' $(( $1 >> 20 )); fi; }
fmt_uptime() {
  local d=$((UP/86400)) h=$((UP%86400/3600)) m=$((UP%3600/60))
  if (( d )); then printf -v UPS '%dd %dh %02dm' $d $h $m; else printf -v UPS '%dh %02dm' $h $m; fi
}

# ───────────── drawing helpers (everything is appended to one frame buffer B) ─────────────
put() { B+="${E}[$1;$2H$3$4$RST"; }                      # row col style text
rep() {             # char count -> REP (a slice of a pre-built run: no loops, no forks)
  local n=$2; (( n > 500 )) && n=500
  if (( n <= 0 )); then REP=; else case $1 in ■) REP=${BAR:0:n} ;; ─) REP=${HLN:0:n} ;; *) REP=${SPC:0:n} ;; esac; fi
}

lvlc() {            # pct warn crit [invert] -> LC: section color, gold when warm, pink when hot
  local l=$1; (( ${4:-0} )) && l=$((100-l))
  if (( l >= $3 )); then LC=$PINK; elif (( l >= $2 )); then LC=$GOLD; else LC=$ACC; fi
}

meter() {           # row col width pct warn crit [invert]
  local w=$3 p=$4 n f
  (( w > 0 )) || return
  if [[ -z $p ]]; then LC=$DIM; rep ■ "$w"; put "$1" "$2" "$DIM" "$REP"; return; fi
  (( p > 100 )) && p=100; (( p < 0 )) && p=0
  n=$(( (p*w + 50) / 100 ))
  lvlc "$p" "$5" "$6" "${7:-0}"
  rep ■ "$n"; f=$REP
  rep ■ $((w-n))
  put "$1" "$2" "$LC" "$f"
  put "$1" $(($2+n)) "$DIM" "$REP"
}

box() {             # row col height width title color
  local r=$1 c=$2 h=$3 w=$4 t=$5 cl=$6 i hl
  rep ─ $((w-2)); hl=$REP
  put "$r" "$c" "$cl" "╭$hl╮"
  for ((i=1; i<h-1; i++)); do put $((r+i)) "$c" "$cl" "│"; put $((r+i)) $((c+w-1)) "$cl" "│"; done
  put $((r+h-1)) "$c" "$cl" "╰$hl╯"
  put "$r" $((c+2)) "$cl" "┤"
  put "$r" $((c+3)) "$cl$BOLD" " $t "
  put "$r" $((c+5+${#t})) "$cl" "├"
}

mini() {            # row col width label pct warn crit color [invert]  - one-line meter
  ACC=$8
  local mx=$(($2+7)) px=$(($2+$3-5)) txt
  printf -v t '%-6s' "$4"; put "$1" "$2" "" "$t"
  meter "$1" "$mx" $((px-mx-1)) "$5" "$6" "$7" "${9:-0}"
  if [[ -z $5 ]]; then LC=$DIM; txt="n/a"; else txt="$5%"; fi
  printf -v t '%5s' "$txt"; put "$1" "$px" "$LC$BOLD" "$t"
}

grow() {            # row ix iw label pct warn crit invert - label + meter + value
  local px=$(($2+$3-6)) mx=$(($2+9)) txt
  printf -v t '%-8s' "$4"; put "$1" $(($2+1)) "" "$t"
  meter "$1" "$mx" $((px-mx-1)) "$5" "$6" "$7" "${8:-0}"
  if [[ -z $5 ]]; then LC=$DIM; txt="n/a"; else txt="$5%"; fi
  printf -v t '%6s' "$txt"; put "$1" "$px" "$LC$BOLD" "$t"
}

spark() {           # row col width history-array-name
  local -n _h=$4
  local n=${#_h[@]} w=$3 start=0 off i v idx line
  (( n > w )) && { start=$((n-w)); n=$w; }
  off=$((w-n)); rep ' ' "$off"; line=$REP
  for ((i=0; i<n; i++)); do
    v=${_h[start+i]}; idx=$(( (v*8+50)/100 )); (( idx < 1 )) && idx=1
    lvlc "$v" 60 85
    line+="$LC${BLK:idx:1}"
  done
  put "$1" "$2" "" "$line"
}

draw_graph() {      # row col height width - CPU history graph, with the cat drawn first (behind it)
  local r0=$1 c0=$2 h=$3 w=$4 n=${#H_CPU[@]} start=0 off i j v tot full part st
  local -a art
  local aw=0 ah=0 ax ay
  if (( SHOW_ART )); then
    if   (( w >= 32 && h >= 18 )); then art=("${ART_L[@]}"); aw=32; ah=18
    elif (( w >= 20 && h >= 11 )); then art=("${ART_M[@]}"); aw=20; ah=11
    elif (( w >= 16 && h >= 9  )); then art=("${ART_S[@]}"); aw=16; ah=9
    fi
    if (( aw )); then
      ax=$(( c0 + (w-aw)/2 )); ay=$(( r0 + (h-ah)/2 ))
      ACC=$VIOLET; lvlc "$usage" 60 85                       # the cat is tinted by CPU load
      for ((j=0; j<ah; j++)); do put $((ay+j)) "$ax" "$DIM$LC" "${art[j]}"; done
    fi
  fi
  ACC=$VIOLET
  (( n > w )) && { start=$((n-w)); n=$w; }
  off=$((w-n))
  for ((i=off; i<w; i++)); do                                # only the cells that are filled
    v=${H_CPU[start+i-off]}
    tot=$(( (v*h*8 + 50)/100 )); (( tot < 1 )) && tot=1
    lvlc "$v" 60 85; st=$LC
    full=$((tot/8)); part=$((tot%8))
    for ((j=0; j<full; j++)); do put $((r0+h-1-j)) $((c0+i)) "$st" "█"; done
    (( part )) && put $((r0+h-1-full)) $((c0+i)) "$st" "${BLK:part:1}"
  done
}

draw_cpu() {
  local r=2 c=1 h=$CPUH w=$COLS
  ACC=$VIOLET
  local ix=$((c+1)) iy=$((r+1)) iw=$((w-2)) ih=$((h-2))
  local gw=$GW
  draw_graph "$iy" "$ix" $((ih-1)) "$gw"
  fmt_uptime; put $((iy+ih-1)) $((ix+1)) "$DIM" "up $UPS"

  local bx=$((ix+gw+1)) bw=$((iw-gw-1)) ft
  if [[ -n $freq ]]; then
    ft="$freq MHz"
    put "$iy" $((bx+bw-${#ft}-5)) "$VIOLET" "┤"
    put "$iy" $((bx+bw-${#ft}-4)) "$VIOLET$BOLD" " $ft "
    put "$iy" $((bx+bw-2)) "$VIOLET" "├"
  fi

  local cx=$((bx+2)) cwid=$((bw-4)) cy=$((iy+1)) ch=$((ih-2)) mw=$((bw-4-15))
  put "$cy" "$cx" "$BOLD" "CPU"
  meter "$cy" $((cx+4)) "$mw" "$usage" 60 85
  printf -v t ' %3d%%' "$usage"; put "$cy" $((cx+4+mw)) "$LC$BOLD" "$t"
  if [[ -n $ct ]]; then lvlc "$ct" 70 85; printf -v t ' %3d°C' "$ct"; else LC=$DIM; t='   n/a'; fi
  put "$cy" $((cx+9+mw)) "$LC$BOLD" "$t"

  local rows_avail=$((ch-2)) cols=$((cwid/16)) cw i idx rr cc px bwid
  (( cols < 1 )) && cols=1; (( cols > 4 )) && cols=4
  cw=$((cwid/cols))
  for ((i=1; i<=NCPU; i++)); do
    idx=$((i-1)); rr=$((idx/cols)); cc=$((idx%cols))
    (( rr >= rows_avail )) && break
    px=$((cx+cc*cw)); bwid=$((cw-9))
    printf -v t 'C%-2d' "$idx"; put $((cy+1+rr)) "$px" "$DIM" "$t"
    meter $((cy+1+rr)) $((px+3)) "$bwid" "${P[i]}" 60 85
    printf -v t ' %3d%%' "${P[i]}"; put $((cy+1+rr)) $((px+3+bwid)) "$LC" "$t"
  done
  put $((cy+ch-1)) "$cx" "$DIM" "LAV: $L1 $L5 $L15"
}

draw_mem() {
  local r=$((2+CPUH)) c=1 h=$BOTH w=$((COLS/2))
  local ix=$((c+1)) iy=$((r+1)) iw=$((w-2)) ih=$((h-2)) cy i n
  local ram=$((100*MU/MT)) sw=
  (( ST > 0 )) && sw=$((100*SU/ST))
  local -a Ll Lp Lw Lc Lk
  Ll=(CPU RAM); Lp=("$usage" "$ram"); Lw=(60 70); Lc=(85 90); Lk=("$VIOLET" "$TEAL")
  if (( ST > 0 )); then Ll+=(Swap); Lp+=("$sw"); Lw+=(30); Lc+=(70); Lk+=("$TEAL"); fi
  Ll+=(Disk); Lp+=("$DP"); Lw+=(75); Lc+=(90); Lk+=("$TEAL")

  if (( iw >= 52 )); then                       # two columns: CPU/RAM/disk left, GPUs right
    local cw=$(( (iw-5)/2 )) rx
    rx=$(( ix+1+cw+3 ))
    for ((i=0; i<${#Ll[@]} && i<ih; i++)); do
      mini $((iy+i)) $((ix+1)) "$cw" "${Ll[i]}" "${Lp[i]}" "${Lw[i]}" "${Lc[i]}" "${Lk[i]}"
    done
    (( ih > 0 )) && mini "$iy" "$rx" "$cw" "GPU 1" "$iu" 60 85 "$SKY"
    (( ih > 2 )) && mini $((iy+2)) "$rx" "$cw" "GPU 2" "$gu" 60 85 "$SKY"
    (( ih > 1 )) && put $((iy+1)) $((rx+7)) "$DIM" "Intel iGPU  ${ifreq:-n/a}${ifreq:+ MHz}"
    if (( ih > 3 )); then
      if [[ -n $gt ]]; then ACC=$SKY; lvlc "$gt" 70 85; put $((iy+3)) $((rx+7)) "$LC" "NVIDIA  ${gt}°C"
      else put $((iy+3)) $((rx+7)) "$DIM" "NVIDIA  n/a"; fi
    fi
    n=${#Ll[@]}; (( n < 4 )) && n=4; cy=$((iy+n))
  else                                          # narrow window: one column
    Ll+=("GPU 1" "GPU 2"); Lp+=("$iu" "$gu"); Lw+=(60 60); Lc+=(85 85); Lk+=("$SKY" "$SKY")
    for ((i=0; i<${#Ll[@]} && i<ih; i++)); do
      mini $((iy+i)) $((ix+1)) $((iw-2)) "${Ll[i]}" "${Lp[i]}" "${Lw[i]}" "${Lc[i]}" "${Lk[i]}"
    done
    cy=$((iy+${#Ll[@]}))
  fi

  local l1 l2=
  gib $MU; l1="RAM $G"; gib $MT; l1+=" / $G"; gib $MA; l1+="  avail $G"
  if (( ST > 0 )); then gib $SU; l2="Swap $G"; gib $ST; l2+=" / $G   "; fi
  gib $DU; l2+="Disk $G"; gib $DT; l2+=" / $G"; gib $DF; l2+="  free $G"
  local line
  for line in "$l1" "$l2"; do
    if (( cy < iy+ih )); then put "$cy" $((ix+1)) "$DIM" "${line:0:$((iw-2))}"; cy=$((cy+1)); fi
  done

  if (( ${#AN[@]} > 0 && cy+1 < iy+ih )); then   # which programs hold the RAM
    ACC=$LIME; put "$cy" $((ix+1)) "$LIME$BOLD" "top apps by RAM"
    local nw=16 mx=$((ix+1+16+1)) bwid vx rows=$((iy+ih-cy-1)) pct nm
    bwid=$((ix+iw-11-mx)); (( bwid > 20 )) && bwid=20; (( bwid < 4 )) && bwid=4
    vx=$((mx+bwid+1))
    for ((i=0; i<rows && i<${#AN[@]}; i++)); do
      nm=${AN[i]}
      if (( AC[i] > 1 )); then nm="${nm:0:12} x${AC[i]}"; else nm=${nm:0:16}; fi
      pct=$((100*AB[i]/MT))
      printf -v t '%-16s' "$nm"; put $((cy+1+i)) $((ix+1)) "" "$t"
      meter $((cy+1+i)) "$mx" "$bwid" "$pct" 15 30
      fsize "${AB[i]}"; printf -v t '%9s' "$FS"; put $((cy+1+i)) "$vx" "$LC$BOLD" "$t"
    done
  fi
}

draw_gpu() {
  local half=$((COLS/2)) r=$((2+CPUH)) h=$BOTH
  local c=$((half+1)) w=$((COLS-half))
  ACC=$SKY
  local ix=$((c+1)) iy=$((r+1)) iw=$((w-2)) ih=$((h-2)) cy gap=0 sw
  cy=$iy; sw=$((iw-16-10)); (( sw < 0 )) && sw=0
  (( ih >= 8 )) && gap=1
  if (( cy+1 < iy+ih )); then
    grow "$cy" "$ix" "$iw" "GPU 1" "$iu" 60 85
    spark $((cy+1)) $((ix+9)) "$sw" H_IN
    put $((cy+1)) $((ix+9+sw+1)) "$DIM" "Intel ${ifreq:-n/a}${ifreq:+ MHz}"
    cy=$((cy+2+gap))
  fi
  if (( cy+1 < iy+ih )); then
    grow "$cy" "$ix" "$iw" "GPU 2" "$gu" 60 85
    spark $((cy+1)) $((ix+9)) "$sw" H_NV
    if [[ -n $gt ]]; then lvlc "$gt" 70 85; put $((cy+1)) $((ix+9+sw+1)) "$LC" "NVIDIA ${gt}°C"
    else put $((cy+1)) $((ix+9+sw+1)) "$DIM" "NVIDIA n/a"; fi
    cy=$((cy+2+gap))
  fi
  if (( cy+1 < iy+ih )); then
    grow "$cy" "$ix" "$iw" "Battery" "$bat" 30 70 1
    put $((cy+1)) $((ix+9)) "$DIM" "${bstat:-n/a}"
  fi
}

layout() {
  local bh=$((ROWS-2))
  CPUH=$(( bh*2/5 )); (( CPUH < 12 )) && CPUH=12
  BOTH=$((bh-CPUH))
  if (( BOTH < 10 )); then CPUH=$((bh-10)); BOTH=10; fi
  GW=$(( (COLS-2)*2/5 ))
}

build_skel() {      # borders and titles; rebuilt only when the window size changes
  local B=
  layout
  local bw=$((COLS-2-GW-1)) half=$((COLS/2))
  box 2 1 "$CPUH" "$COLS" cpu "$VIOLET"
  box 3 $((GW+3)) $((CPUH-2)) "$bw" "${MODEL:0:$((bw-18))}" "$VIOLET"
  box $((2+CPUH)) 1 "$BOTH" "$half" "cpu / ram / gpu" "$TEAL"
  box $((2+CPUH)) $((half+1)) "$BOTH" $((COLS-half)) "gpu / power" "$SKY"
  SKEL=$B; SK_KEY="$ROWS $COLS"
}

draw() {
  B="${E}[?2026h${E}[H${E}[2J"
  if (( ROWS < 24 || COLS < 80 )); then
    put 1 1 "" "Terminal too small (need 80x24)"
  else
    local tstr left=" Fedora Monitor " right
    [[ $SK_KEY == "$ROWS $COLS" ]] || build_skel
    B+=$SKEL
    printf -v tstr '%(%H:%M:%S)T' -1
    if [[ -n $bat ]]; then right=" BAT ${bat}% ${bstat} │ $tstr "; else right=" BAT n/a │ $tstr "; fi
    rep ' ' $((COLS-${#left}-${#right}))
    put 1 1 "$HDR" "$left$REP$right"
    draw_cpu; draw_mem; draw_gpu
    put "$ROWS" 1 "$DIM" " q quit │ a art on/off │ refresh ${REFRESH}s "
  fi
  B+="${E}[?2026l"
  printf '%s' "$B"
}

# ───────────── setup and main loop ─────────────
get_size() { (:;:); ROWS=${LINES:-24}; COLS=${COLUMNS:-80}; }

cleanup() { printf '%s' "${E}[?25h${E}[?1049l${RST}"; [[ -n $OLD_STTY ]] && stty "$OLD_STTY" 2>/dev/null; }

main() {
  [[ -t 0 && -t 1 ]] || { echo "fedmon needs an interactive terminal" >&2; exit 1; }
  PAGE=$(getconf PAGESIZE 2>/dev/null) || PAGE=4096
  command -v nvidia-smi >/dev/null && HAVE_NV=1 || HAVE_NV=0
  find_cpu_temp; find_freq_files; find_intel; read_model
  SHOW_ART=1; SAMPLES=0; NV_T=-100; PROC_T=-100; NEEDSIZE=0
  OLD_STTY=$(stty -g)
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  trap 'NEEDSIZE=1' WINCH
  stty -echo
  printf '%s' "${E}[?1049h${E}[?25l"
  get_size
  read_cpu_stat; PREV_T=("${CUR_T[@]}"); PREV_I=("${CUR_I[@]}")
  read_intel                                # first reading just stores the baseline
  sleep 0.3
  local key now_ms last_ms=0 rem t
  while :; do
    now_ms=$(( ${EPOCHREALTIME/[.,]/} / 1000 )); NOW_S=$((now_ms/1000))
    if (( now_ms - last_ms >= REFRESH*1000 - 50 )); then sample; last_ms=$now_ms; fi
    if (( NEEDSIZE )); then get_size; NEEDSIZE=0; fi
    draw
    rem=$(( last_ms + REFRESH*1000 - ${EPOCHREALTIME/[.,]/}/1000 )); (( rem < 50 )) && rem=50
    printf -v t '%d.%03d' $((rem/1000)) $((rem%1000))
    key=; read -rsn1 -t "$t" key
    case $key in
      q|Q) break ;;
      a|A) SHOW_ART=$((1-SHOW_ART)) ;;
    esac
  done
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main
