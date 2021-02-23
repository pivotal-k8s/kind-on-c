# `KINDONC!!` a.k.a. `kind-on-c` a.k.a. `kind on concourse`

![KINDONC!! POW!!][logo]

[logo]: kindonc.jpg

This is a [concourse] [task][concourse-task] which uses [kind] to start a
[kubernetes] cluster locally for users to run their tests against.

Users can choose to run whichever [kubernetes] version [kind] uses by default,
or use a specific [kubernetes] version by providing the [kubernetes] source
tree checked out at a specific version. 

It is heavily based on [concourse-dcind] and of course uses [kind]. This is really just plumbing ...

# Usage

## Run whatever `kind` thinks is cool ...

```yaml
jobs:
- name: kind
  plan:
  - in_parallel:
    - get: kind-on-c
    - get: kind-release
      params:
        globs:
        - kind-linux-amd64
  - task: run-kind
    privileged: true
    file: kind-on-c/kind.yaml
    params:
      KIND_TESTS: |
        # your actual tests go here!
        kubectl get nodes -o wide

resources:
- name: kind-release
  type: github-release
  source:
    owner: kubernetes-sigs
    repository: kind
    access_token: <some github token>
    pre_release: true
- name: kind-on-c
  type: git
  source:
    uri: https://github.com/pivotal-k8s/kind-on-c
```

This uses the `kind` binary, provided by the `kind-release` resource, to create
a kubernetes cluster. It will use the [node image] from the kind team.
The version of `kind` in use and thus, indirectly, the kubernetes version
deployed can be controlled by pinning the `kind-release` resource to a specific
version.

When the cluster is up and running, any commands configured in `$KIND_TESTS`
will run. The environment is setup with `$KUBECONFIG` which points to the
client configuration for the deployed kubernetes cluster. Also the most recent
(stable) version of kubectl will be downloaded and put into the `$PATH`,
therefore `kubectl <something>` will *just work™️*.

## Build and run your own kubernetes ...

```yaml
jobs:
- name: kind
  plan:
  - in_parallel:
    - get: k8s-git
    - get: kind-on-c
    - get: kind-release
      params:
        globs:
        - kind-linux-amd64
  - task: run-kind
    privileged: true
    file: kind-on-c/kind.yaml
    params:
      KIND_TESTS: |
        # your actual tests go here!
        kubectl get nodes -o wide

resources:
- name: k8s-git
  type: git
  source:
    uri: https://github.com/kubernetes/kubernetes
- name: kind-release
  type: github-release
  source:
    owner: kubernetes-sigs
    repository: kind
    access_token: <some github token>
    pre_release: true
- name: kind-on-c
  type: git
  source:
    uri: https://github.com/pivotal-k8s/kind-on-c
```

If the task finds an [task input] named `k8s-git` it treats that as a
kubernetes source tree and tells kind to create a [node image] off of that. You
can just use a git resource, and pin it to a specific commit if need be, if you
want to run a specific kubernetes version.

In this case, also `kubectl` is compiled on the fly and therefore exactly
matches the version of kubernetes deployed.

# User configurations

- `KIND_TESTS`  
  ... this is the important piece: configure, what YOU actually want to run
  against the cluster! E.g.:
  ```yaml
  KIND_TESTS: |
    kubectl get nodes -o jsonpath="{..name}" | grep -q 'worker2' || {
      echo >&2 "Expected node 'worker2' not found"
      return 1
    }
  ```
  _Note_: The tests will run in bash with the options `errexit` & `nounset`
- `KIND_CONFIG`  
  ... is the config kind when creating the cluster. Optional. If not specified,
  the [default config](kind-default-config.yaml) is used, but can be
  overwritten with something like:
  ```yaml
  KIND_CONFIG: |
    kind: Cluster
    apiVersion: kind.x-k8s.io/v1alpha4
    nodes:
    - role: control-plane
    - role: worker
    - role: worker
  ```
  _Note_: potentially the config you specify will be patched with things that
  are essential for kind-on-c to work properly.
- <a id="out-rootfs"></a> `EXPORT_NODE_ROOTFS`  
  If this parameter is set, the [node image] built by kind is made
  available as an output in the format of a rootfs.
  This output can be consumed by other steps and used to run a task off of.  
  See also [the ouput `exported-node-rootfs`](#out-exported-node-rootfs).  
  _Note_: If the task is configured to use upstream kind's default [node image],
  this feature is not available. A warning is printed and the output is kept
  empty.
- <a id="out-oci"></a> `EXPORT_NODE_IMAGE`  
  If this parameter is set, the [node image] built by kind is made
  available as an output in the format of an OCI image.
  This output can be consumed by other steps and e.g. pushed to a registry.
  This might come in handy if you want to run multiple tests against the same
  version of kubernetes in parallel. You could have one step which builds the
  [node image], exports it as and OCI image, and pushes it to a registry and then
  some more parallel jobs that consume that image. With that approach you don't
  need to compile the smae [node image] over and over.
  See also [the ouput `exported-node-image`](#out-exported-node-image).
  _Note_: If the task is configured to use upstream kind's default [node image],
  this feature is not available. A warning is printed and the output is kept
  empty.
- <a id="install-metallb"></a> `INSTALL_METALLB`
  If this parameter is set, [metallb] is installed onto the cluster. This
  allows users to deploy services of type `LoadBalancer` and get an
  `EXTERNAL-IP` for those.  This external IP can be used to connect to a
  exposed service from the task container, thus from code running in
  `KIND_TESTS`.
- `KIND_PRE_START`
  ... if you want or need to run something just before the kind cluster is
  started
- `DOCKERD_OPTS`
  ... if you need to add some configs when starting the docker daemon
- `DOCKERD_TIMEOUT`
  ... how long do you want to wait for docker to come up?
- `KINDONC_DEBUG`
  ... if you want to see all the ugly things that are happening to bring up docker and to run kind
- `KIND_LOGLEVEL`
  ... make kind more or less verbose when it is doing its business.
  For kind `<= 0.5.1` this value is used for the `--loglevel` option and needs to be one of `panic`, `fatal`, `error`, `warning`, `info`, `debug`.
  For kind `> 0.5.1` this value is used for the `--verbosity` option and needs to be and integer.
- `KIND_CLUSTER_NAME`
  ... in case you want to change kind's cluster name -- you actually should not need to do that ...
- `NODE_IMAGE`
  ... in case you want to pull the kind node image from somewhere else ...

# Well known task inputs & outputs

## Inputs

- `kind-on-c`, _mandatory_
  The file tree of this repo. At least the [task file](./kind.yaml) and [the
  entrypoint](./entrypoint.sh) will (or should) be used from this input, in
  future potentially more.
  This input is typically provided by a git resource that is pulling this very
  git repo.
- `kind-release`, _mandatory_
  Must prrovide the kind binary, named `kind-linux-amd64`.
  This should either be backed by a github-release resource or a earlier task
  that compiles kind from the source.
- `k8s-git`, _optional_  
  Must provide a git source tree of kubernetes. When configured, the [node image]
  will be built off of the checked-out revision of kubernetes.
  This is typically a git resource, pointing to (a fork of) [k/k](https://github.com/kubernetes/kubernetes).
- `node-image`, _optional_
  Must provide an OCI image `image.tar` that will be used as a [node image]. This
  can be an image generated via
  [`EXPORT_NODE_IMAGE`](#out-oci)/[`exported-node-image`](#out-exported-node-image)
  or any other OCI image that can be used as [node image] for kind.
- `inputs`, _optional_  
  If this task depends on other resources, aggregate them into the `inputs`
  input. More about that in [Aggregated inputs & outputs](#agg-ins-and-outs).

## Outputs

The task generates all the outputs in this list, however depending on the
task's configuration it may leave certain (or even all) outputs empty.

- <a id="out-exported-node-image"></a> `exported-node-image`  
  If the task is [configured to output the node image as an OCI
  image](#out-oci), this output will be populated. 
  A following step can consume this output and e.g. the `registry-image`
  resource could be used to push the [node image] into a registry.
  ```yaml
  jobs:
  - name: kind
    plan:
    - task: run-kind
      privileged: true
      file: kind-on-c/kind.yaml
      params:
        EXPORT_NODE_IMAGE: 1
    - put: image-repo  # this is a registry-image resource
      params:
        image: exported-node-image/image.tar
  ```
- <a id="out-exported-node-rootfs"></a> `exported-node-rootfs`  
  If the task is [configured to output the node image as a
  rootfs](#out-rootfs), this output will be populated with a rootfs and a
  minimal `metadata.json`.
  With that it is possible to use the [node image] as a task image for a
  following concourse task.
  ```yaml
  jobs:
  - name: kind
    plan:
    - task: run-kind
      privileged: true
      file: kind-on-c/kind.yaml
      params:
        EXPORT_NODE_ROOTFS: 1
    - task: do something with the node rootfs
      image: exported-node-rootfs
      config:
        platform: linux
        run:
          path: bash
          args:
          - -xeuc
          - |
            echo "Concourse is now running the image we built with kind"
  ```
- `outputs`  
  If users want to create further outputs, they can do so by aggregating them
  in the `ouputs` output. More about that in [Aggregated inputs &
  outputs](#agg-ins-and-outs).

# Bring your own task image

Chances are good, that you need some additional tools to run your
`KIND_TESTS`. To do that, you can use a custom task image.

You can e.g. use the `registry-image` resource to pull in your custom image and
then override kind-on-c's default image by providing its rootfs to the
kind-on-c task via the [`image`][img-dir] directive. This overrides the image that is
configured in the task config.

When it comes to creating the image, you can base it on the default kind-on-c
image and add your additional tools and things as another layer.  For that you
can follow the image's `ci-latest` tag, which gets updated every time we push a
new task image. Or you can extract all information (repo and digest) of the
default task image from the task config file.

When you want to bring a entirely different image which is not based on
kind-on-c's default task image, you need to check which dependencies we need in
the [Dockerfile](./Dockerfile).


For e.g. static binaries you could, instead of providing a custom image, have
concourse pull down all the needed things and provide them to the task via the
`inputs` input. Also, of course, nothing stand in the way to use both a custom
image and provide certain things via `inputs`.

```yaml
jobs:
- name: kind
  plan:
  - in_parallel:
    - get: custom-kind-on-c-image
    - get: kind-on-c
    - get: kind-release
    - get: other-custom-things
  - task: run-kind
    privileged: true
    file: kind-on-c/kind.yaml
    image: custom-kind-on-c-image # This overrides the image from the task config file
    input_mapping:
      inputs: other-custom-things
    params:
      KIND_TESTS: # use custom things either from the image or from inputs

resources:
- name: custom-kind-on-c-image
  type: registry-image
  source: {repository: my-custom-image, tag: "1.13"}
- name: other-custom-things
  type: some-resource-type
  source: {...}
```

# <a id="agg-ins-and-outs"></a> Aggregated inputs & outputs

Currently this task only allows for a *fixed set of inputs and outputs* (some
inputs are optional, some output might be kept empty). This set cannot be
changed by users of kind-on-c.

Still users need to be able to provide one or more of their own resources to be
consumed by this task as inputs or generate one or more outputs by this task. 

A workaround for this are (what I call now) aggregated inputs & outputs:

Users can use as many input resources they want, they however need to aggregate
them into the one input `inputs` for this task. Likewise, if that is something
a user needs to do, they can place all their outputs into the single `outputs`
output and have a later task split them apart again, into separate, individual
outputs.

After all, inputs and outputs are eventually "just directories" on disk and
therefore relatively easy to manipulate if need be.

## Example usage of aggregated inputs and outputs

The following (contrived) example shows how this could be used:
- aggregates the resources `input-res-1`, `input-res-2`, and `input-res-3` into the input `inputs`
- the kind-on-c task uses the input `inputs`
- the kind-on-c task uses the output `outputs` and places `artifacts`, `metrics`, and `logs` in there
- the last task consumes the `outputs` output of the kind-on-c task, splits
  those up and makes them available as separate outputs `artifacts`, `metrics`,
  and `logs`
- all of the `put` resources just care about one of the individual outputs

```yaml
plan:
- in_parallel:
  - get: kind-on-c
  - get: input-res-1
    trigger: true
  - get: input-res-2
    trigger: true
  - get: input-res-3
- task: aggregate inputs for kind-on-c
  config:
    platform: linux
    image_resource:
      type: registry-image
      source: { repository: bash }
    inputs:
    - name: input-res-1
    - name: input-res-2
    - name: input-res-3
    outputs:
    - name: inputs # this will be the aggregated inputs for kind-on-c
    run:
      path: bash
      args:
      - -xeuc
      - |
        cp -a input-res-1 inputs/
        cp -a input-res-2 inputs/
        cp -a input-res-3 inputs/
- task: kind-on-c
  privileged: true
  file: kind-on-c/kind.yaml
  params:
    KIND_TESTS: |
      # your actual tests go here!
      cp -a some/artifacts outputs
      cp -a some/metrics   outputs
      cp -a some/logs      outputs
- task: split aggregated outputs of kind-on-c
  config:
    platform: linux
    image_resource:
      type: registry-image
      source: { repository: bash }
    inputs:
    - name: outputs
    outputs:
    - name: artifacts
    - name: metrics
    - name: logs
    run:
      path: bash
      args:
      - -xeuc
      - |
        cp -a outputs/artifacts/* artifacts
        cp -a outputs/metrics/*   metrics
        cp -a outputs/logs/*      logs
- in_parallel:
  - put: artifactory          # using only the artifacts output of the last task
    params:
      folder: artifacts
  - put: lftp-log-dump        # using only the log output of the previous task
    params:
      files: "logs/*.log"
  - put: swift-metrics-store  # using only the metrics output of the previous task
    params:
      from: "metrics/(.*)"
```

## But why?

kind-on-c made the design decision to use a [task file](kind.yaml). This is
mostly to have an easy way to specify the specific version of the kind-on-c
image, have [the pipeline](ci) automatically update it, and track which commit
has been tested with which version of the image.

[concourse] however does not allow to mix settings (e.g. inputs) from a task
file with inline configuration in the task config.

Therefore, for now at least, kind-on-c is opting for specifying the set of
allowed/available inputs/outputs, which might mean a bit of overhead for the
users.

[concourse-dcind]: https://github.com/karlkfi/concourse-dcind
[concourse]: https://concourse-ci.org/
[concourse-task]: https://concourse-ci.org/tasks.html
[task input]: https://concourse-ci.org/tasks.html#task-inputs
[kind]: https://kind.sigs.k8s.io/
[kubernetes]: https://kubernetes.io/
[node image]: https://kind.sigs.k8s.io/docs/design/node-image/
[metallb]: https://metallb.universe.tf/
[img-dir]: https://concourse-ci.org/jobs.html#schema.step.task-step.image
