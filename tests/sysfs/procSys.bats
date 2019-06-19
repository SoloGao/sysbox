#!/usr/bin/env bats

#
# Testing of common (aka passthrough) handler (this handler handles
# accesses to resources that are namespaced by the Linux kernel
# and for which no actual emulation is required).
#

load ../helpers/run
load ../helpers/fs
load ../helpers/ns

disable_ipv6=/proc/sys/net/ipv6/conf/all/disable_ipv6

function setup() {
  setup_busybox
}

function teardown() {
  teardown_busybox syscont
}

# compares /proc/* listings between a sys-container and unshare-all
# (there are expected to match, except for files emulated by sysvisor-fs)
function compare_syscont_unshare() {
  sc_list=$1
  ns_list=$2

  delta=$(diff --suppress-common-lines <(echo "$sc_list" | sed -e 's/ /\n/g') <(echo "$ns_list" | sed -e 's/ /\n/g') | grep "proc" | sed 's/^< //g')

  for file in $delta; do
    found=false
    for mnt in $SYSFS_PROC_SYS; do
      if [ "$file" == "$mnt" ]; then
        found=true
      fi
    done
    [ "$found" == true ]
  done
}

@test "disable_ipv6 lookup" {

  sv_runc run -d --console-socket $CONSOLE_SOCKET syscont
  [ "$status" -eq 0 ]

  # disable_ipv6
  sv_runc exec syscont sh -c "ls -l $disable_ipv6"
  [ "$status" -eq 0 ]

  verify_root_rw "$output"
  [ "$status" -eq 0 ]
}

@test "disable_ipv6 namespacing" {

  local enable="0"
  local disable="1"

  host_orig_val=$(cat $disable_ipv6)

  sv_runc run -d --console-socket $CONSOLE_SOCKET syscont
  [ "$status" -eq 0 ]

  # By default ipv6 should be enabled within a system container
  # launched by sysvisor-runc directly (e.g., without docker) Note
  # that in system container launched with docker + sysvisor-runc,
  # docker (somehow) disables ipv6.
  sv_runc exec syscont sh -c "cat $disable_ipv6"
  [ "$status" -eq 0 ]
  [ "$output" = "$enable" ]

  # Disable ipv6 in system container and verify
  sv_runc exec syscont sh -c "echo $disable > $disable_ipv6"
  [ "$status" -eq 0 ]

  sv_runc exec syscont sh -c "cat $disable_ipv6"
  [ "$status" -eq 0 ]
  [ "$output" = "$disable" ]

  # Verify that change in sys container did not affect host
  host_val=$(cat $disable_ipv6)
  [ "$host_val" -eq "$host_orig_val" ]

  # Re-enable ipv6 within system container
  sv_runc exec syscont sh -c "echo $enable > $disable_ipv6"
  [ "$status" -eq 0 ]

  sv_runc exec syscont sh -c "cat $disable_ipv6"
  [ "$status" -eq 0 ]
  [ "$output" = "$enable" ]

  # Verify that change in sys container did not affect host
  host_val=$(cat $disable_ipv6)
  [ "$host_val" -eq "$host_orig_val" ]
}

@test "/proc/sys hierarchy" {

  walk_proc="find /proc/sys -print"

  # launch sys container
  sv_runc run -d --console-socket $CONSOLE_SOCKET syscont
  [ "$status" -eq 0 ]

  # get the list of dirs under /proc/sys
  sv_runc exec syscont sh -c "${walk_proc}"
  [ "$status" -eq 0 ]
  sc_proc_sys="$output"

  # unshare all ns and get the list of dirs under /proc/sys
  ns_proc_sys=$(unshare_all sh -c "${walk_proc}")

  compare_syscont_unshare "$sc_proc_sys" "$ns_proc_sys"
}

@test "/proc/sys perm" {

  # this lists all files and dirs under /proc/sys, each as:
  # -rw-r--r-- 1 root root /proc/sys/<path>
  l_proc_sys_files="find /proc/sys -type f -print0 | xargs -0 ls -l | awk '{print \$1 \" \" \$2 \" \" \$3 \" \" \$4 \" \" \$9}'"
  l_proc_sys_dirs="find /proc/sys -type d -print0 | xargs -0 ls -ld | awk '{print \$1 \" \" \$2 \" \" \$3 \" \" \$4 \" \" \$9}'"

  sv_runc run -d --console-socket $CONSOLE_SOCKET syscont
  [ "$status" -eq 0 ]

  sv_runc exec syscont sh -c "${l_proc_sys_files}"
  [ "$status" -eq 0 ]
  sc_proc_sys_files="$output"

  sv_runc exec syscont sh -c "${l_proc_sys_dirs}"
  [ "$status" -eq 0 ]
  sc_proc_sys_dirs="$output"

  ns_proc_sys_files=$(unshare_all sh -c "${l_proc_sys_files}")
  ns_proc_sys_dirs=$(unshare_all sh -c "${l_proc_sys_dirs}")

  compare_syscont_unshare "$sc_proc_sys_files" "$ns_proc_sys_files"
  compare_syscont_unshare "$sc_proc_sys_dirs" "$ns_proc_sys_dirs"
}

# Verify that /proc/sys controls for namespaced kernel resources
# can be modified from within a sys container and have proper
# container-to-host and container-to-container isolation.
@test "/proc/sys namespaced resources" {

  # launch two sys containers (launch the 2nd one with docker to avoid
  # conflict with test setup/teardown functions)

  sv_runc run -d --console-socket $CONSOLE_SOCKET syscont
  [ "$status" -eq 0 ]

  sc2=$(docker_run nestybox/sys-container:debian-plus-docker tail -f /dev/null)

  # For each /proc/sys control associated with a namespaced resource,
  # modify the value in the sys container and check isolation. Then
  # revert the value in the sys container and re-check.

  for entry in "${PROC_SYS_NS[@]}"; do
    eval $entry
    file=${e[0]}
    type=${e[1]}

    # read original values in host and in the sys containers

    host_orig=$(cat "$file")

    sv_runc exec syscont sh -c "cat $file"
    [ "$status" -eq 0 ]
    sc_orig="$output"

    docker exec "$sc2" sh -c "cat $file"
    [ "$status" -eq 0 ]
    sc2_orig="$output"

    # modify value in sys-cont1 (change depends on value type)

    case "$type" in
      BOOL)
        sc_new=$((! $sc_orig))
        ;;

      INT)
        sc_new=$(($sc_orig - 1))
        ;;
    esac

    sv_runc exec syscont sh -c "echo $sc_new > $file"
    [ "$status" -eq 0 ]

    sv_runc exec syscont sh -c "cat $file"
    [ "$status" -eq 0 ]
    [ "$output" == "$sc_new" ]

    # check for proper isolation

    host_val=$(cat "$file")
    [ "$host_val" == "$host_orig" ]

    docker exec "$sc2" sh -c "cat $file"
    [ "$status" -eq 0 ]
    [ "$output" == "$sc2_orig" ]

    # revert value in sys cont

    sv_runc exec syscont sh -c "echo $sc_orig > $file"
    [ "$status" -eq 0 ]

    sv_runc exec syscont sh -c "cat $file"
    [ "$status" -eq 0 ]
    [ "$output" == "$sc_orig" ]

    # re-check isolation

    host_val=$(cat "$file")
    [ "$host_val" == "$host_orig" ]

    docker exec "$sc2" sh -c "cat $file"
    [ "$status" -eq 0 ]
    [ "$output" == "$sc2_orig" ]

  done

  docker_stop "$sc2"
}

# Verify that /proc/sys controls for non-namespaced kernel resources
# can't be modified from within a sys container.
@test "/proc/sys non-namespaced resources" {

  skip "Sysvisor issue #244"

  sv_runc run -d --console-socket $CONSOLE_SOCKET syscont
  [ "$status" -eq 0 ]

  # For each /proc/sys control associated with a namespaced resource,
  # modify the value in the sys container and check isolation. Then
  # revert the value in the sys container and re-check.

  for entry in "${PROC_SYS_NON_NS[@]}"; do
    eval $entry
    file=${e[0]}
    type=${e[1]}

    sv_runc exec syscont sh -c "cat $file"
    [ "$status" -eq 0 ]
    sc_orig="$output"

    case "$type" in
      BOOL)
        sc_new=$((! $sc_orig))
        ;;

      INT)
        sc_new=$(($sc_orig - 1))
        ;;
    esac

    sv_runc exec syscont sh -c "echo $sc_new > $file"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Permission denied" ]]

  done
}

@test "/proc/sys concurrent intra-container access" {

  skip "Sysvisor issue #246"

  num_workers=10

  # worker script (periodically polls a /proc/sys file)
  cat << EOF > ${HOME}/worker.sh
#!/bin/sh
while true; do
  cat /proc/sys/net/netfilter/nf_conntrack_icmp_timeout > "\$1"
  sleep 1
done
EOF

  chmod +x ${HOME}/worker.sh

  sc=$(docker_run \
         --mount type=bind,source="${HOME}"/worker.sh,target=/worker.sh \
         nestybox/sys-container:debian-plus-docker tail -f /dev/null)

  docker exec "$sc" sh -c "cat /proc/sys/net/netfilter/nf_conntrack_icmp_timeout"
  [ "$status" -eq 0 ]
  val="$output"

  for i in $(seq 1 $num_workers); do
    docker exec -d "$sc" sh -c "/worker.sh result_$i.txt"
    [ "$status" -eq 0 ]
  done

  for i in $(seq 1 $num_workers); do
    docker exec "$sc" sh -c "cat result_$i.txt"
    [ "$status" -eq 0 ]
    [ "$output" == "$val" ]
  done

  new_val=$(( $val + 1 ))
  docker exec "$sc" sh -c "echo $new_val > /proc/sys/net/netfilter/nf_conntrack_icmp_timeout"
  [ "$status" -eq 0 ]

  sleep 2

  for i in $(seq 1 $num_workers); do
    docker exec "$sc" sh -c "cat result_$i.txt"
    [ "$status" -eq 0 ]
    [ "$output" == "$new_val" ]
  done

  # cleanup
  docker_stop "$sc"
  rm ${HOME}/worker.sh
}

@test "/proc/sys concurrent inter-container access" {

  num_sc=5
  iter=20

  # this worker script will run in each sys container
  cat << EOF > ${HOME}/worker.sh
#!/bin/sh
for i in \$(seq 1 $iter); do
  echo \$i > /proc/sys/net/netfilter/nf_conntrack_icmp_timeout
  val=\$(cat /proc/sys/net/netfilter/nf_conntrack_icmp_timeout)
  if [ "\$val" != "\$i" ]; then
    echo "fail" > result.txt
    exit
  fi
done
echo "pass" > result.txt
EOF

  chmod +x ${HOME}/worker.sh

  # deploy the sys containers
  for i in $(seq 1 $num_sc); do
    syscont[$i]=$(docker_run \
                    --mount type=bind,source="${HOME}"/worker.sh,target=/worker.sh \
                    nestybox/sys-container:debian-plus-docker tail -f /dev/null)
  done

  # start the worker script
  for sc in ${syscont[@]}; do
    docker exec -d "$sc" sh -c "/worker.sh"
    [ "$status" -eq 0 ]
  done

  # wait for workers to finish (we check the last worker only)
  retry_run 10 1 docker exec ${syscont[$num_sc]} sh -c "cat /result.txt"

  # verify results
  for sc in ${syscont[@]}; do
    docker exec "$sc" sh -c "cat /result.txt"
    [ "$status" -eq 0 ]
    [ "$output" == "pass" ]
  done

  # cleanup
  for sc in ${syscont[@]}; do
    docker_stop "$sc"
  done

  rm ${HOME}/worker.sh
}

@test "/proc/sys access frequency" {

  skip "Sysvisor issue #246"

  # verify sysvisor-fs handles a high access frequency properly
  num_workers=10

  # worker script (periodically polls a /proc/sys file)
  cat << EOF > ${HOME}/worker.sh
#!/bin/sh
while true; do
  cat /proc/sys/net/netfilter/nf_conntrack_icmp_timeout > "\$1"
  sleep 1
done
EOF

  chmod +x ${HOME}/worker.sh

  sc=$(docker_run \
         --mount type=bind,source="${HOME}"/worker.sh,target=/worker.sh \
         nestybox/sys-container:debian-plus-docker tail -f /dev/null)

  docker exec "$sc" sh -c "cat /proc/sys/net/netfilter/nf_conntrack_icmp_timeout"
  [ "$status" -eq 0 ]
  val="$output"

  for i in $(seq 1 $num_workers); do
    docker exec -d "$sc" sh -c "/worker.sh result_$i.txt"
    [ "$status" -eq 0 ]
  done

  for i in $(seq 1 $num_workers); do
    docker exec "$sc" sh -c "cat result_$i.txt"
    [ "$status" -eq 0 ]
    [ "$output" == "$val" ]
  done

  # cleanup
  docker_stop "$sc"
  rm ${HOME}/worker.sh
}
