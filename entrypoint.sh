#!/usr/bin/env bash

# Inspired by concourse/docker-image-resource:
# https://github.com/concourse/docker-image-resource/blob/master/assets/common.sh

set -o errexit -o pipefail -o nounset

[ -z "${KINDONC_DEBUG:-}" ] || set -x

# Waits DOCKERD_TIMEOUT seconds for startup (default: 60)
DOCKERD_TIMEOUT="${DOCKERD_TIMEOUT:-60}"
# Accepts optional DOCKERD_OPTS (default: --data-root /scratch/docker --storage-driver overlay2)
DOCKERD_OPTS="${DOCKERD_OPTS:-}"

# Constants
DOCKERD_PID_FILE="/tmp/docker.pid"
DOCKERD_LOG_FILE="/tmp/docker.log"


cgroups::sanitize() {
  local cgroup="/sys/fs/cgroup"

  mkdir -p "${cgroup}"
  if ! mountpoint -q "${cgroup}"; then
    if ! mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup "${cgroup}"; then
      log::error "Could not make a tmpfs mount. Did you use --privileged?"
      exit 1
    fi
  fi
  mount -o remount,rw "${cgroup}"

  # Skip AppArmor
  # See: https://github.com/moby/moby/commit/de191e86321f7d3136ff42ff75826b8107399497
  export container=docker

  # Mount /sys/kernel/security
  if [[ -d /sys/kernel/security ]] && ! mountpoint -q /sys/kernel/security; then
    if ! mount -t securityfs none /sys/kernel/security; then
      log::error "Could not mount /sys/kernel/security."
      log::error "AppArmor detection and --privileged mode might break."
    fi
  fi

  sed -e 1d /proc/cgroups | while read sys hierarchy num enabled; do
    if [[ "${enabled}" != "1" ]]; then
      # subsystem disabled; skip
      continue
    fi

    grouping="$(cat /proc/self/cgroup | cut -d: -f2 | grep "\\<${sys}\\>")"
    if [[ -z "${grouping}" ]]; then
      # subsystem not mounted anywhere; mount it on its own
      grouping="${sys}"
    fi

    mountpoint="${cgroup}/${grouping}"

    mkdir -p "${mountpoint}"

    # clear out existing mount to make sure new one is read-write
    if mountpoint -q "${mountpoint}"; then
      umount "${mountpoint}"
    fi

    mount -n -t cgroup -o "${grouping}" cgroup "${mountpoint}"

    if [[ "${grouping}" != "${sys}" ]]; then
      if [[ -L "${cgroup}/${sys}" ]]; then
        rm "${cgroup}/${sys}"
      fi

      ln -s "${mountpoint}" "${cgroup}/${sys}"
    fi
  done

  # Initialize systemd cgroup if host isn't using systemd.
  # Workaround for https://github.com/docker/for-linux/issues/219
  if ! [[ -d /sys/fs/cgroup/systemd ]]; then
    mkdir "${cgroup}/systemd"
    mount -t cgroup -o none,name=systemd cgroup "${cgroup}/systemd"
  fi
}

# Setup container environment and start docker daemon in the background.
docker::start() {
  mkdir -p /var/log
  mkdir -p /var/run

  cgroups::sanitize

  # check for /proc/sys being mounted readonly, as systemd does
  if grep '/proc/sys\s\+\w\+\s\+ro,' /proc/mounts >/dev/null; then
    mount -o remount,rw /proc/sys
  fi

  local docker_opts="${DOCKERD_OPTS:-}"

  # Pass through `--garden-mtu` from gardian container
  if [[ "${docker_opts}" != *'--mtu'* ]]; then
    local mtu="$(cat /sys/class/net/$(ip route get 8.8.8.8|awk '{ print $5 }')/mtu)"
    docker_opts+=" --mtu ${mtu}"
  fi

  # Use Concourse's scratch volume to bypass the graph filesystem by default
  if [[ "${docker_opts}" != *'--data-root'* ]] && [[ "${docker_opts}" != *'--graph'* ]]; then
    docker_opts+=' --data-root /scratch/docker'
  fi

  # Set storage driver to overlay2 by default
  # https://kind.sigs.k8s.io/docs/user/known-issues/#docker-on-btrfs
  if [[ "${docker_opts}" != *'--storage-driver'* ]]; then
    docker_opts+=' --storage-driver overlay2'
  fi

  rm -f "${DOCKERD_PID_FILE}"
  touch "${DOCKERD_LOG_FILE}"

  dockerd ${docker_opts} &>"${DOCKERD_LOG_FILE}" &
  echo "$!" > "${DOCKERD_PID_FILE}"
}

# Wait for docker daemon to be healthy
# Timeout after DOCKERD_TIMEOUT seconds
docker::await() {
  local timeout="${DOCKERD_TIMEOUT}"
  local start=${SECONDS}
  timeout=$(( timeout + start ))
  until docker info &>/dev/null; do
    if (( SECONDS >= timeout )); then
      log::error 'Timed out trying to connect to docker daemon.'
      if [[ -f "${DOCKERD_LOG_FILE}" ]]; then
        log::error '---DOCKERD LOGS---'
        log::error "$(cat "${DOCKERD_LOG_FILE}")"
      fi
      exit 1
    fi
    if [[ -f "${DOCKERD_PID_FILE}" ]] && ! kill -0 $(cat "${DOCKERD_PID_FILE}"); then
      log::error 'Docker daemon failed to start.'
      if [[ -f "${DOCKERD_LOG_FILE}" ]]; then
        log::error '---DOCKERD LOGS---'
        log::error "$(cat "${DOCKERD_LOG_FILE}")"
      fi
      exit 1
    fi
    sleep 1
  done
}

# Gracefully stop Docker daemon.
docker::stop() {
  local rc docker_pid start

  rc="${1:-}"

  if [ "$rc" != "0" ]
  then
    log::error "Build failed (${rc}), not stopping docker."
    return "$rc"
  fi

  if ! [[ -f "${DOCKERD_PID_FILE}" ]]; then
    return 0
  fi
  docker_pid="$(cat ${DOCKERD_PID_FILE})"
  if [[ -z "${docker_pid}" ]]; then
    return 0
  fi
  kill -TERM "${docker_pid}"
  start=${SECONDS}
  wait "${docker_pid}"
}

export::node::image() {
  local imageName="$1"

  [ -n "$imageName" ] || {
    log::warn "not exporting node image, we use the upstream's node image"
    return
  }

  log::info "Exporting node image"

  local destDir="${PWD}/exported-node-image"
  local destName="${destDir}/image.tar"

  docker save -o "$destName" "$imageName"
}

export::node::rootfs() {
  local imageName="$1"

  [ -n "$imageName" ] || {
    log::warn "not exporting node rootfs, we use the upstream's node image"
    return
  }

  log::info "Exporting node rootfs"

  (
    local cid

    local destDir="${PWD}/exported-node-rootfs"
    local destDirRootfs="${destDir}/rootfs"

    mkdir -p "$destDirRootfs"

    cid="$( docker create "$imageName" )"
    trap 'docker rm "$cid"' EXIT

    docker inspect "$cid" \
      | jq '.[0] | { user: .Config.User, env: .Config.Env }' \
      > "${destDir}/metadata.json"

    docker export "$cid" \
      | tar -C "$destDirRootfs" -xf -
  )
}

export::node() {
  local imageName="$1"

  [ -z "${EXPORT_NODE_ROOTFS:-}" ] || export::node::rootfs "$imageName"
  [ -z "${EXPORT_NODE_IMAGE:-}" ]  || export::node::image  "$imageName"
}

kind::hack::node_prepper::script() {
  # Get the prepper script's content and remove all comments
  grep -o '^[^#]*' "${PWD}/kind-on-c/node-prepper.sh"
}

kind::hack::node_prepper::runner() {
  local nodes0 nodes1 nodeCmd clusterName \
    nodes=() node pids=() pid

  clusterName="$1"
  nodeCmd="$( kind::hack::node_prepper::script )"

  # get all the nodes currently known by kind
  # remember those nodes for a bit
  nodes0="$( kind get nodes --name "$clusterName" | sort )" || return 1

  mapfile -t nodes <<< "$nodes0"

  # we expect at least 1 node
  [ "${#nodes[@]}" -ge 1 ] || return 2

  # for each node, spawn a background process for doing the preperation for one
  # node keep track of the PIDs
  for node in "${nodes[@]}"
  do
    docker exec "$node" sh -c "$nodeCmd" &
    pids+=( $! )
  done

  # wait for all preperation processes in the background
  # bail out if anyone of those failed
  for pid in "${pids[@]}"
  do
    wait "$pid" || return 3
  done

  # wait a bit, give kind a chance to bring up more nodes
  sleep 5

  # check again which nodes kind knows about
  # if that is different then the list of nodes from the beginning, consider
  # this run failed
  nodes1="$( kind get nodes --name "$clusterName" | sort )" || return 4
  [ "$nodes0" = "$nodes1" ] || return 5

  return 0
}

kind::hack::node_prepper() {
  log::info 'node-prepper starting in the background'

  retry 300 1 kind::hack::node_prepper::runner "$1"

  log::info 'node-prepper was successful on all nodes, shutting down'
}

# Generate a config file for kind
# Either from $KIND_CONFIG or fallback to kind-on-c's default
kind::gen_config() {
  local defaultConfFile="$1"
  local userConf="$2"

  local kindConfFile
  kindConfFile="$( mktemp )"

  if [ -n "$userConf" ]
  then
    if [ -e "$userConf" ]
    then
      cat "$userConf" > "$kindConfFile"
    else
      echo "$userConf" > "$kindConfFile"
    fi
  else
    cat "$defaultConfFile" > "$kindConfFile"
  fi

  echo "$kindConfFile"
}

kubectl::install() {
  local binDir="$1"

  local compiledKubectl="${PWD}/go/src/k8s.io/kubernetes/_output/dockerized/bin/linux/amd64/kubectl"

  if [ -e "$compiledKubectl" ]
  then
    install -m 0750 "$compiledKubectl" "${binDir}/kubectl"
    return 0
  fi

  local urlVer urlKubectl kubectlVer curler

  curler="curl -sL"
  urlVer='https://storage.googleapis.com/kubernetes-release/release/stable.txt'
  kubectlVer="$( $curler "$urlVer" )"
  urlKubectl="https://storage.googleapis.com/kubernetes-release/release/${kubectlVer}/bin/linux/amd64/kubectl"

  install -m 0750 <($curler "$urlKubectl") "${binDir}/kubectl"
}

kind::install() {
  local binDir="$1"
  local kindBin="${PWD}/kind-release/kind-linux-amd64"

  [ -f "$kindBin" ] || {
    log::error "'kind-release' input not configured correctly"
    log::error "   expected the kind binary at '${kindBin}'"
    return 1
  }

  # install kind itself
  install -m 0750 "$kindBin" "${binDir}/kind"
}

metallb::install() {
  [ -n "${INSTALL_METALLB:-}" ] || return 0

  log::info 'Installing MetalLB'

  local metallbConfigMap="${PWD}/kind-on-c/metallb-cm.yaml"
  local metallbSystemConfs=(
    'https://raw.githubusercontent.com/metallb/metallb/v0.9/manifests/namespace.yaml'
    'https://raw.githubusercontent.com/metallb/metallb/v0.9/manifests/metallb.yaml'
  )

  {
    for c in "${metallbSystemConfs[@]}" ; do
      kubectl apply -f "$c"
    done
    kubectl apply -f <( kind::hack::genMetalConfig "$metallbConfigMap" )
    kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
  } >/dev/null
}

kind::hack::genMetalConfig() {
  local orgConfig="$1"
  local kindNetName='kind' # will this change?

  local dockerNet
  local net cidr
  local i1 i2 i3 i4 m1 m2 m3 m4
  local ip0 ip1
  local config

  dockerNet="$( docker network inspect "$kindNetName" | jq -r '.[0].IPAM.Config[0].Subnet' )"
  IFS=/ read -r net cidr <<< "$dockerNet"

  IFS=. read -r i1 i2 i3 i4 <<< "$net"
  IFS=. read -r m1 m2 m3 m4 <<< "$( kind::hack::cidrToNetmask "$cidr" )"

  ip0="$((i1 & m1 | 255-m1)).$((i2 & m2 | 255-m2)).$((i3 & m3 | 255-m3)).$(((i4 & m4)+1))"
  ip1="$((i1 & m1 | 255-m1)).$((i2 & m2 | 255-m2)).$((i3 & m3 | 255-m3)).$(((i4 & m4 | 255-m4)-1))"

  # shellcheck disable=SC2016
  config="$(
    </dev/null oq -i yaml -o yaml -n --arg ip0 "$ip0" --arg ip1 "$ip1" '{
      "address-pools": [{
        "name": "default",
        "protocol": "layer2",
        "addresses": [
          "\($ip0)-\($ip1)"
        ]
      }]
    }'
  )"

  # shellcheck disable=SC2016
  oq -i yaml -o yaml -r --arg c "$config" '.data.config = $c' "${orgConfig}"
}

kind::hack::cidrToNetmask() {
  local value="$(( 0xffffffff ^ ((1 << (32 - ${1})) - 1) ))"
  echo "$(( (value >> 24) & 0xff )).$(( (value >> 16) & 0xff )).$(( (value >> 8) & 0xff )).$(( value & 0xff ))"
}

# With https://github.com/kubernetes-sigs/kind/pull/1029 kind broke the way how
# to handle the kube config file. This approach should work for both, how it
# was handled before and after that change.
kind::kubeconfig::write() {
  local clusterName="$1"
  local file

  file="$( mktemp )"
  kind get kubeconfig --name "$clusterName" > "$file"

  echo "$file"
}

kind::hack::loglevel() {
  local level="$1"
  local kindVersion
  local re='^[0-9]+$'
  local flagName='verbosity'

  [ -n "$level" ] || return 0

  kindVersion=$( kind --version | sed 's/^kind version v*//g' )

  # for versions 0.5.1 and older
  if dpkg --compare-versions "$kindVersion" le '0.5.1'
  then
    re='^(panic|fatal|error|warning|info|debug)$'
    flagName='loglevel'
  fi

  [[ "$level" =~ $re ]] || {
    log::warn "${flagName} '${level}' not allowed, must match '${re}'"
    return 1
  }

  echo "--${flagName}=${level}"
}

kind::start() {
  local imageName="${1}"

  local clusterName="${KIND_CLUSTER_NAME:-kind}"
  local userKindConfig="${KIND_CONFIG:-}"

  local defaultKindConfigFile="${PWD}/kind-on-c/kind-default-config.yaml"

  # generate the config for kind and the logging option
  local kindConfigFile kindLogOpt
  kindConfigFile="$( kind::gen_config "$defaultKindConfigFile" "$userKindConfig" )"
  kindLogOpt="$( kind::hack::loglevel "${KIND_LOGLEVEL:-}" )"

  # prepare kind opts
  local kindOpts
  kindOpts=( --config "$kindConfigFile" --name "$clusterName" --retain )
  [ -z "$kindLogOpt" ] || kindOpts+=( "$kindLogOpt" )
  [ -z "$imageName" ]  || kindOpts+=( --image "$imageName" )

  # start the cluster
  kind::hack::node_prepper "$clusterName" &
  kind create cluster "${kindOpts[@]}"

  # make kubeconfig available
  KUBECONFIG="$( kind::kubeconfig::write "$clusterName" )"
  export KUBECONFIG

  # wait until the default service account is available, so pods can actually
  # be scheduled
  retry 60 1 kubectl -n default get serviceaccount default -o name

  metallb::install

  # tell 'em!
  log::info "cluster available"
  log::info "$( kubectl version | sed 's/^/  /g' )"
  log::info "  kind Version: $(kind version)"
  log::info "  \$KUBECONFIG: ${KUBECONFIG}"
}

kind::image::prepare() {
  local nodeImagePath="${PWD}/node-image/image.tar"
  local k8sSrcPath="${PWD}/go/src/k8s.io/kubernetes"
  local imageName

  # If we have a node image as an input, we will use that, this has precedence
  if [ -e "$nodeImagePath" ]
  then
    log::info "found '${nodeImagePath}', will import and use that as a node image"

    nodeImageName="$( docker image load -q -i "$nodeImagePath" | sed 's/^Loaded image: //' )"

    echo "$nodeImageName"
    return 0
  fi

  # Else, if we have a kubernetes source tree as an input, we will build a node
  # image off of that
  if [ -d "$k8sSrcPath" ]
  then
    log::info "found '${k8sSrcPath}', will use that source tree to build a node image off of"

    local gitTag
    gitTag="$( cd "${k8sSrcPath}" && git describe --dirty )"
    imageName="kind/local-image:${gitTag}"

    (
      export GOPATH="${PWD}/go"
      cd "$GOPATH"
      kind build node-image --image "$imageName" >&2
    )

    echo "$imageName"
    return 0
  fi

  if [ -n "${NODE_IMAGE+x}" ]
  then
      echo "${NODE_IMAGE}"
      return 0
  fi

  # Fallback to not using a special node image, use the default from kind
  # upstream
}

lib::load() {
  local dir

  dir="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )"

  # shellcheck source=./lib.inc.sh
  . "${dir}/lib.inc.sh"
}

log::version() {
  local v
  v="$(
    cd kind-on-c \
      && git describe --dirty --exclude='*' --always 2>/dev/null \
      || echo '<unknown>'
  )"
  log::info "kind-on-c: ${v}"
}

main() {
  lib::load
  log::version

  docker::start
  trap 'docker::stop "$?"' EXIT
  docker::await

  # setup bin dir & path
  local binPath="${PWD}/bin"
  mkdir -p "$binPath"
  export PATH="${PATH}:${binPath}"

  # install kind
  kind::install "$binPath"

  # prepare the node image, if configured
  local imageName
  imageName="$( kind::image::prepare )"

  # run pre start stuff
  if [ -n "${KIND_PRE_START:-}" ]
  then
    # shellcheck disable=SC2016
    log::info 'Running pre start commands from "$KIND_PRE_START"'
    bash -e -u -c "$KIND_PRE_START"
  fi

  # export the node image/rootfs, if configured
  export::node "$imageName"

  if [ -z "${KIND_TESTS:-}" ]
  then
    # shellcheck disable=SC2016
    log::warn '"$KIND_TESTS" not sepcified. Not really running any tests.'
    return 0
  fi

  # install kubectl
  kubectl::install "$binPath"

  # start the cluster
  kind::start "$imageName"

  # shellcheck disable=SC2016
  log::info 'Running tests from "$KIND_TESTS"'
  bash -e -u -c "$KIND_TESTS"
}

main "$@"
