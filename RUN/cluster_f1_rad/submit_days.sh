#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./submit_days.sh [--dry-run] [START_DAY [END_DAY [INTERVAL]]]

Submit one VVM job per day, including both endpoints.
START_DAY defaults to 30, END_DAY defaults to 15, and INTERVAL defaults to 1.

Options:
  -n, --dry-run  Show the planned changes and commands without changing files
  -h, --help     Show this help
EOF
}

dry_run=false
days=()

while (($# > 0)); do
    case "$1" in
        -n|--dry-run)
            dry_run=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            days+=("$@")
            break
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            days+=("$1")
            ;;
    esac
    shift
done

if ((${#days[@]} > 3)); then
    echo "Error: expected at most START_DAY, END_DAY, and INTERVAL." >&2
    usage >&2
    exit 2
fi

start_day=${days[0]:-30}
end_day=${days[1]:-15}
interval=${days[2]:-1}

if [[ ! $start_day =~ ^[0-9]+$ || ! $end_day =~ ^[0-9]+$ || ! $interval =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: START_DAY and END_DAY must be non-negative integers; INTERVAL must be a positive integer." >&2
    exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

setup_file=vvm.setup
run_file=vvm.run
restart_file=user_codes/restart_module.F
profile_file=user_module.F
steps=216
vvmdir=$(cd -- "$script_dir/../.." && pwd)
datadir=$vvmdir/DATA

for file in "$setup_file" "$run_file" "$restart_file" "$profile_file"; do
    if [[ ! -f $file ]]; then
        echo "Error: required file not found: $script_dir/$file" >&2
        exit 1
    fi
done

exp_pattern='^[[:space:]]*set[[:space:]]+expname[[:space:]]*=[[:space:]]+.*[_-][dD][0-9]+([_-].*)?$'
restart_pattern='^[[:space:]]*INTEGER.*default_restart_it[[:space:]]*=[[:space:]]*72[[:space:]]*\*[[:space:]]*[0-9]+'
profile_pattern="^[[:space:]]*'/work1/umbrella0c/PROFILE/domain_average/RRCE_3km_f00_[0-9]+/'"

require_one_match() {
    local pattern=$1
    local file=$2
    local count

    count=$(grep -Ec "$pattern" "$file" || true)
    if [[ $count -ne 1 ]]; then
        echo "Error: expected exactly one target line in $file; found $count." >&2
        exit 1
    fi
}

require_one_match "$exp_pattern" "$setup_file"
require_one_match "$exp_pattern" "$run_file"
require_one_match "$restart_pattern" "$restart_file"
require_one_match "$profile_pattern" "$profile_file"

if ((start_day <= end_day)); then
    day_step=$interval
else
    day_step=$((-interval))
fi

day=$start_day
while :; do
    echo "===== day $day ====="

    expname=$(sed -E -n \
        "s/^([[:space:]]*set[[:space:]]+expname[[:space:]]*=[[:space:]]+)(.*[_-])([dD])[0-9]+([_-].*)?$/\\2\\3${day}\\4/p" \
        "$setup_file")
    archive_dir=$datadir/$expname/archive
    nc_count=0
    archive_complete=true

    if [[ -d $archive_dir ]]; then
        shopt -s nullglob
        thermodynamic_files=("$archive_dir"/*.L.Thermodynamic-*.nc)
        shopt -u nullglob
        nc_count=${#thermodynamic_files[@]}

        for ((output_step = 0; output_step <= steps; output_step++)); do
            printf -v step_string '%06d' "$output_step"
            matching_files=("$archive_dir"/*.L.Thermodynamic-"$step_string".nc)
            if [[ ! -f ${matching_files[0]} ]]; then
                archive_complete=false
                break
            fi
        done
    else
        archive_complete=false
    fi

    printf 'Found %d Thermodynamic NetCDF file(s) in %s (expected steps 0-%d).\n' \
        "$nc_count" "$archive_dir" "$steps"

    if [[ $archive_complete == true ]]; then
        printf 'Skip day %s: Thermodynamic steps 0-%d already exist.\n' "$day" "$steps"
    elif [[ $dry_run == true ]]; then
        for file in "$setup_file" "$run_file"; do
            planned=$(grep -E "$exp_pattern" "$file" | \
                sed -E "s/^([[:space:]]*set[[:space:]]+expname[[:space:]]*=[[:space:]]+.*[_-])([dD])[0-9]+([_-].*)?$/\\1\\2${day}\\3/")
            printf '[dry-run] %s: %s\n' "$file" "$planned"
        done
        planned=$(grep -E "$restart_pattern" "$restart_file" | \
            sed -E "s/^(.*default_restart_it[[:space:]]*=[[:space:]]*)72[[:space:]]*\*[[:space:]]*[0-9]+(.*)$/\\172*${day}\\2/")
        printf '[dry-run] %s: %s\n' "$restart_file" "$planned"
        planned=$(grep -E "$profile_pattern" "$profile_file" | \
            sed -E "s|(RRCE_3km_f00_)[0-9]+/|\\1${day}/|")
        printf '[dry-run] %s: %s\n' "$profile_file" "$planned"
        echo '[dry-run] ./vvm.setup && ./vvm.run'
    else
        for file in "$setup_file" "$run_file"; do
            sed -E -i \
                "s/^([[:space:]]*set[[:space:]]+expname[[:space:]]*=[[:space:]]+.*[_-])([dD])[0-9]+([_-].*)?$/\\1\\2${day}\\3/" \
                "$file"
        done
        sed -E -i \
            "s/^(.*default_restart_it[[:space:]]*=[[:space:]]*)72[[:space:]]*\*[[:space:]]*[0-9]+(.*)$/\\172*${day}\\2/" \
            "$restart_file"
        sed -E -i \
            "s|(RRCE_3km_f00_)[0-9]+/|\\1${day}/|" \
            "$profile_file"

        ./vvm.setup && ./vvm.run
    fi

    if ((day == end_day)); then
        break
    fi
    next_day=$((day + day_step))
    if ((day_step > 0 && next_day > end_day)); then
        day=$end_day
    elif ((day_step < 0 && next_day < end_day)); then
        day=$end_day
    else
        day=$next_day
    fi
done
