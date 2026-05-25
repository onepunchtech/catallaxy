# Catallaxy Design

## Goals

- Simplify kubernetes
  - initialization
  - management
- Real gitops from the start
- Manage a labratory of k8s clusters declaratively
- Support on prem, cloud and mixed infrastructures
- Extensible
- Repeatable and testable
- Local developer first experience
- Mitigate cloud vender lock in
- Ease on prem pains

## Architecture

### Nixos modules

Nix and nixos modules are the backbone of the design. Rather than working with YAML or helm charts or another tool that eventually leads to interfacing with it through YAML, we choose nix. We will follow the rendered manifest pattern and treat the declaration of a cluster as a build input and the resulting rendered manifests as a build result.

Nixos modules provide extreme flexibility and extensibility and have proven to be scalable in with the NixOS Linux distribution.

Because of their flexibility they can be used in so many different ways with different architectures. In this project it is using them to implement a kind of multipass compiler.

| Pass        | Description                                                                                                                                                            |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Declaration | High level nixos options.<br>The user interface (Cluster and Lab declarations)                                                                                         |
| IRs         | Intermediate representations.<br>K8s API, provisioning IR, diagram IR.<br>Easier for machine analysis and transform to code generated targets than Declaration level   |
| Targets     | Target a specific type of output for another program to consume.<br>e.g. Rendered manifests of raw k8s YAML in the format usable by argocd or fleet or other CD system |

This project must avoid IFDs to keep evaluation quick.

#### Declartion Modules

Catallaxy exposes two modules as a library.

1. Cluster declaration
2. Lab declaration

In the same way that you would use a flake to define a NixOS machine you can use a flake to define either a Cluster, or a Lab which is a collection of clusters managed by one central "Management" cluster.

Each module that has a need to be referenced in some way produces a `*.out` option that holds all the references and makes them readonly. This is different from the NixOS pattern partly for ergonomics because it is clearly documenting intent to the user or other module authors what can be referenced. The main reason however is because often the values that are referenced are computed in some way. So we want the result of the computed references not just what the user defined something as.

##### Cluster Module

Defines the "what" of a kubernetes cluster. Kubernetes is generic and allows for defining a cluster in various ways and has methods for extending it's functionality through CRDs and Operators.
The cluster module has what are considered "sane" defaults for a good way to deploy k8s clusters and workloads favoring k8s native, simplicity, and solid solutions.

The cluster module defines how to describe the cluster itself as well as any extensions components and workloads that will run on that cluster.

##### Lab module

The labs module is about defining a group of clusters that will be managed by a "Management" cluster. This central management cluster can be configured with any of the options of a single cluster for it's own configuration but also has a attrset of clusters it owns provisioning over. This provisioning is configured using CAPI.

#### IRs

The IRs exist because 1. The user level description should be clean and there are internal components that the user should not be concerned with. 2. Translating from the high level description of what a cluster or lab is down to the targets directly can be a complicated tranformation. Instead we rely on the concept that compilers use which is to have a stable core intermediate representation that sits in between the user's AST and the target compiled language.

##### kubernetes

Kubernetes is the core IR where it should be the kubernetes API.
There may need to be more IRs added when more features exist.

At the IR level kubernetes manifests should be grouped by clusters and by phases. A phase is the portion of manifests that get applied together in a group. The phases control the order in which groups of manifests get applied. This can be mapped cleanly to a CI/CD tool.

#### Targets

##### Kapp

##### ArgoCD

##### Fleet

##### Documentation

Documentation will include a variety of details about cluster topology. This ranges from json descriptions to diagram descriptions for static visualization.

##### SBOMs

What is running on your cluster and produce an output that can be feed into vulnerability scanners.

#### Generated modules

The generated modules build a nixos module from a source spec. The generated options are for type safety to aid the module authors and to provide good static checking that values are correct.

- kubernetes API
- helm chart types for values
- CRDs

### Cata CLI

The cata command line utility is a swiss army knife comparable to docker-compose but for kubernetes. It references flakes that define clusters or labs and can use that output to perform it's various functions. This keeps a clean separation between

- nix eval time (evaluate and check configuration)
- nix build time (build rendered manifestst and other targets)
- Runtime application (make the cluster or lab real)
