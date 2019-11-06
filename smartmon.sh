#!/bin/bash
# Script informed by the collectd monitoring script for smartmontools (using smartctl)
# by Samuel B. <samuel_._behan_(at)_dob_._sk> (c) 2012
# source at: http://devel.dob.sk/collectd-scripts/

# TODO: This probably needs to be a little more complex.  The raw numbers can have more
#       data in them than you'd think.
#       http://arstechnica.com/civis/viewtopic.php?p=22062211

# Formatting done via shfmt -i 2
# https://github.com/mvdan/sh
set -euo pipefail
IFS=$'\n\t'

parse_smartctl_attributes_awk="$(
  cat <<'SMARTCTLAWK'
$1 ~ /^ *[0-9]+$/ && $2 ~ /^[a-zA-Z0-9_-]+$/ {
  gsub(/-/, "_");
  printf "%s_value{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $4
  printf "%s_worst{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $5
  printf "%s_threshold{%s,smart_id=\"%s\"} %d\n", tolower($2), labels, $1, $6
  printf "%s_raw_value{%s,smart_id=\"%s\"} %e\n", tolower($2), labels, $1, $10
}
SMARTCTLAWK
)"

smartmon_attrs="$(
  cat <<'SMARTMONATTRS'
airflow_temperature_cel
command_timeout
current_pending_sector
end_to_end_error
erase_fail_count
g_sense_error_rate
hardware_ecc_recovered
host_reads_mib
host_reads_32mib
host_writes_mib
host_writes_32mib
load_cycle_count
media_wearout_indicator
wear_leveling_count
nand_writes_1gib
offline_uncorrectable
power_cycle_count
power_on_hours
program_fail_count
raw_read_error_rate
reallocated_event_count
reallocated_sector_ct
reported_uncorrect
sata_downshift_count
seek_error_rate
spin_retry_count
spin_up_time
start_stop_count
temperature_case
temperature_celsius
temperature_internal
total_lbas_read
total_lbas_written
udma_crc_error_count
unsafe_shutdown_count
workld_host_reads_perc
workld_media_wear_indic
workload_minutes
SMARTMONATTRS
)"
smartmon_attrs="$(echo ${smartmon_attrs} | xargs | tr ' ' '|')"

parse_smartctl_attributes() {
  local labels="$1"
  local vars="$(echo "${smartmon_attrs}" | xargs | tr ' ' '|')"
  sed 's/^ \+//g' |
    awk -v labels="${labels}" "${parse_smartctl_attributes_awk}" 2>/dev/null |
    grep -iE "(${smartmon_attrs})"
}

parse_smartctl_scsi_attributes() {
  local labels="$1"
  while read line; do
    attr_type="$(echo "${line}" | tr '=' ':' | cut -f1 -d: | sed 's/^ \+//g' | tr ' ' '_')"
    attr_value="$(echo "${line}" | tr '=' ':' | cut -f2 -d: | sed 's/^ \+//g')"
    case "${attr_type}" in
    number_of_hours_powered_up_) power_on="$(echo "${attr_value}" | awk '{ printf "%e\n", $1 }')" ;;
    Current_Drive_Temperature) temp_cel="$(echo ${attr_value} | cut -f1 -d' ' | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_sent_to_initiator_) lbas_read="$(echo ${attr_value} | awk '{ printf "%e\n", $1 }')" ;;
    Blocks_received_from_initiator_) lbas_written="$(echo ${attr_value} | awk '{ printf "%e\n", $1 }')" ;;
    Accumulated_start-stop_cycles) power_cycle="$(echo ${attr_value} | awk '{ printf "%e\n", $1 }')" ;;
    Elements_in_grown_defect_list) grown_defects="$(echo ${attr_value} | awk '{ printf "%e\n", $1 }')" ;;
    esac
  done
  [ ! -z "$power_on" ] && echo "power_on_hours_raw_value{${labels},smart_id=\"9\"} ${power_on}"
  [ ! -z "$temp_cel" ] && echo "temperature_celsius_raw_value{${labels},smart_id=\"194\"} ${temp_cel}"
  [ ! -z "$lbas_read" ] && echo "total_lbas_read_raw_value{${labels},smart_id=\"242\"} ${lbas_read}"
  [ ! -z "$lbas_written" ] && echo "total_lbas_written_raw_value{${labels},smart_id=\"242\"} ${lbas_written}"
  [ ! -z "$power_cycle" ] && echo "power_cycle_count_raw_value{${labels},smart_id=\"12\"} ${power_cycle}"
  [ ! -z "$grown_defects" ] && echo "grown_defects_count_raw_value{${labels},smart_id=\"12\"} ${grown_defects}"
}

parse_smartctl_nvme_attributes() {
  local labels="$1"
  while read line; do
    attr_type="$(echo "${line}" | tr '=' ':' | cut -f1 -d: | sed 's/^ \+//g' | tr ' ' '_')"
    attr_value="$(echo "${line}" | tr '=' ':' | cut -f2 -d: | sed 's/^ \+//g')"
    case "${attr_type}" in
    Available_Spare_Threshold) spare_thresh="$(echo ${attr_value} | tr -d '%'  | awk '{ printf "%e\n", $1 }')" ;;
    Available_Spare) spare="$(echo ${attr_value} | tr -d '%'  | awk '{ printf "%e\n", $1 }')" ;;
    Temperature) temp_cel="$(echo ${attr_value} | cut -f1 -d' ' | awk '{ printf "%e\n", $1 }')" ;;
    Power_On_Hours) power_on="$(echo "${attr_value}" | tr -d ',' | awk '{ printf "%e\n", $1 }')" ;;
    # https://media.kingston.com/support/downloads/MKP_521.6_SMART-DCP1000_attribute.pdf - the number of units read/written are in 1000 multiplies of 512.
    # Multiplying here in order to be consistent with the other drive types and compatible with the https://grafana.com/grafana/dashboards/10664 grafana dashboard
    Data_Units_Read) data_read="$(echo ${attr_value} | cut -f1 -d' ' | tr -d ',' | awk '{ printf "%e\n", $1*1000 }')" ;;
    Data_Units_Written) data_written="$(echo ${attr_value} | cut -f1 -d' ' | tr -d ',' | awk '{ printf "%e\n", $1*1000 }')" ;;
    Power_Cycles) power_cycle="$(echo ${attr_value} | tr -d ',' | awk '{ printf "%e\n", $1 }')" ;;
    # this value indicates the percentage of the nvme subsystem expected life. Values greater than 100 can apear.
    # Translating it to 'wear leveling count' values, in which 100% means unsued disk, and 0% means it is out of expected life.
    # Should be consistent with non-nvme drives and compatible with the https://grafana.com/grafana/dashboards/10664 grafana dashboard
    Percentage_Used) wear="$(echo ${attr_value} | tr -d '%' | awk '{ printf "%e\n", 100-$1 }')" ;;
    esac
  done
  [ ! -z "$spare" ] && echo "available_spare_percent_value{${labels}} ${spare}"
  [ ! -z "$spare_thresh" ] && echo "available_spare_threshold_percent_value{${labels}} ${spare_thresh}"
  [ ! -z "$power_on" ] && echo "power_on_hours_raw_value{${labels}} ${power_on}"
  [ ! -z "$temp_cel" ] && echo "temperature_celsius_raw_value{${labels}} ${temp_cel}"
  [ ! -z "$power_cycle" ] && echo "power_cycle_count_raw_value{${labels}} ${power_cycle}"
  [ ! -z "$data_read" ] && echo "total_lbas_read_raw_value{${labels}} ${data_read}"
  [ ! -z "$data_written" ] && echo "total_lbas_written_raw_value{${labels}} ${data_written}"
  [ ! -z "$wear" ] && echo "wear_leveling_count_value{${labels}} ${wear}"
}

extract_labels_from_smartctl_info() {
  local disk="$1" disk_type="$2"
  local model_family='<None>' device_model='<None>' serial_number='<None>' fw_version='<None>' vendor='<None>' product='<None>' revision='<None>' lun_id='<None>'
  while read line; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_')"
    info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/\\"/')"
    case "${info_type}" in
    Model_Family) model_family="${info_value}" ;;
    Device_Model|Model_Number) device_model="${info_value}" ;;
    Serial_Number) serial_number="${info_value}" ;;
    Firmware_Version) fw_version="${info_value}" ;;
    Vendor) vendor="${info_value}" ;;
    Product) product="${info_value}" ;;
    Revision) revision="${info_value}" ;;
    Logical_Unit_id) lun_id="${info_value}" ;;
    esac
  done
  echo "disk=\"${disk}\",type=\"${disk_type}\",vendor=\"${vendor}\",product=\"${product}\",revision=\"${revision}\",lun_id=\"${lun_id}\",model_family=\"${model_family}\",device_model=\"${device_model}\",serial_number=\"${serial_number}\",firmware_version=\"${fw_version}\""
}

parse_smartctl_info() {
  local -i smart_available=0 smart_enabled=0 smart_healthy=0 sector_size_log=512 sector_size_phy=512
  local labels="$1"
  while read line; do
    info_type="$(echo "${line}" | cut -f1 -d: | tr ' ' '_')"
    info_value="$(echo "${line}" | cut -f2- -d: | sed 's/^ \+//g' | sed 's/"/\\"/')"
    if [[ "${info_type}" == 'SMART_support_is' ]]; then
      case "${info_value:0:7}" in
      Enabled) smart_enabled=1 ;;
      Availab) smart_available=1 ;;
      Unavail) smart_available=0 ;;
      esac
    fi
    if [[ "${info_type}" == 'SMART_overall-health_self-assessment_test_result' ]]; then
      case "${info_value:0:6}" in
      PASSED) smart_healthy=1 ;;
      esac
    elif [[ "${info_type}" == 'SMART_Health_Status' ]]; then
      case "${info_value:0:2}" in
      OK) smart_healthy=1 ;;
      esac
    elif [[ "${info_type}" == 'Sector_Size' ]]; then
        sector_size_log=$(echo "$info_value" | cut -d' ' -f1)
        sector_size_phy=$(echo "$info_value" | cut -d' ' -f1)
    elif [[ "${info_type}" == 'Sector_Sizes' ]]; then
        sector_size_log="$(echo "$info_value" | cut -d' ' -f1)"
        sector_size_phy="$(echo "$info_value" | cut -d' ' -f4)"
    fi
  done
  echo "device_smart_available{${labels}} ${smart_available}"
  echo "device_smart_enabled{${labels}} ${smart_enabled}"
  echo "device_smart_healthy{${labels}} ${smart_healthy}"
  echo "device_sector_size_logical{${labels}} ${sector_size_log}"
  echo "device_sector_size_physical{${labels}} ${sector_size_phy}"
}

output_format_awk="$(
  cat <<'OUTPUTAWK'
BEGIN { v = "" }
v != $1 {
  print "# HELP smartmon_" $1 " SMART metric " $1;
  print "# TYPE smartmon_" $1 " gauge";
  v = $1
}
{print "smartmon_" $0}
OUTPUTAWK
)"

format_output() {
  sort |
    awk -F'{' "${output_format_awk}"
}

smartctl_version="$(smartctl -V | head -n1 | awk '$1 == "smartctl" {print $2}')"

echo "smartctl_version{version=\"${smartctl_version}\"} 1" | format_output

if [[ "$(expr "${smartctl_version}" : '\([0-9]*\)\..*')" -lt 6 ]]; then
  exit
fi

# get both regular and nvme devices
device_list="$(smartctl --scan-open | awk '/^\/dev/{print $1 "|" $3}')"
device_list_nvme="$(smartctl --scan-open -d nvme | awk '/^\/dev/{print $1 "|" $3}')"

for device in ${device_list} ${device_list_nvme}; do
  disk="$(echo ${device} | cut -f1 -d'|')"
  type="$(echo ${device} | cut -f2 -d'|')"
  active=1
  echo "smartctl_run{disk=\"${disk}\",type=\"${type}\"}" "$(TZ=UTC date '+%s')"
  # Check if the device is in a low-power mode
  smartctl -n standby -d "${type}" "${disk}" > /dev/null || active=0
  echo "device_active{disk=\"${disk}\",type=\"${type}\"}" "${active}"
  # Skip further metrics to prevent the disk from spinning up
  test ${active} -eq 0 && continue
  # Get the SMART information and health
  smart_info="$(smartctl -i -H -d "${type}" "${disk}")"
  disk_labels="$(echo "$smart_info" | extract_labels_from_smartctl_info "${disk}" "${type}")"
  echo "$smart_info" | parse_smartctl_info "${disk_labels}"

  # skip this disk if SMART is unavailable
  if echo "$smart_info" | grep -q -E 'SMART support is:\s+Unavailable'; then
    continue
  fi
  # Get the SMART attributes
  case ${type} in
  sat) smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk_labels}" ;;
  sat+megaraid*) smartctl -A -d "${type}" "${disk}" | parse_smartctl_attributes "${disk_labels}" ;;
  scsi) smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk_labels}" ;;
  megaraid*) smartctl -A -d "${type}" "${disk}" | parse_smartctl_scsi_attributes "${disk_labels}" ;;
  nvme) smartctl -A -d "${type}" "${disk}" | parse_smartctl_nvme_attributes "${disk_labels}" ;;
  *)
    echo "disk type is not sat, scsi, nvme or megaraid but ${type}"
    exit
    ;;
  esac
done | format_output