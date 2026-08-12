# Introduction

Catallaxy is a declarative Kubernetes platform built on the NixOS module
system. You define multi-cluster environments in Nix. The manifests and the
tooling that deploys them come out as build outputs, so there is no
imperative orchestration to write.

## Why the name?

Catallaxy is F.A. Hayek's word for a spontaneous order: a coordinated system
that emerges from independent parts following their own rules rather than
from a central plan. This concept comes from observing the real world. It is
reality that the market is driven by a spontaneous order rather than central
planning. This project came from the same observation that trying to
centrally plan everything is futile and there needs to be a way to
coordinate between teams of people or across automated systems. Nothing in
it holds the deployment plan, because the plan is derived from what each
part declares.

## Why can't Helm charts compose, and why does Catallaxy?

A Helm chart is a templating engine. The problem isn't just with the subpar
templating engine, which requires a lot of cognitive overhead to reason
about. Whatever templating you write has an implicit understanding of the
structure of your cluster, but then that structure is lost once everything
is rendered to YAML. In Catallaxy we preserve the structure. Structure can
be defined by the author and can be whatever the author needs in order to
create a stable API for others to depend on your work.

This abstraction in Catallaxy is called a [floe](./understanding/floes.md).
A floe is designed to encode everything necessary for templating while
preserving the structure. I can provide meaningful details in the form of a
Nix expression to consumers of my floe so that they can guard against what
they need to. For example, as an author, I can encode the meaning of startup
order of my resources.

Catallaxy packages a component as a typed option surface and a declared
interface, and renders manifests from that. The structure survives
packaging, and it gives you a handle to do so much more than just write
YAML. This project exploits the many things we can do when we preserve that
information.

## How do you get more safety before deploying to a cluster?

Kubernetes can be very expensive to operate, and it can be expensive to get
wrong. To minimize getting it wrong we set up test clusters, but often the
clusters are too different to really be a true test. The goal of this
project is to both provide the ability to produce identical clusters and
minimize the number of things that need to get deployed to test for
correctness.

The thesis is that most things can be validated statically, but this depends
on maintaining the structure and author's intent so that it is simple enough
to make assertions on, perform global linting rules, ensure logical
composition, etc.

## Status

Functional and in active use for a multi-cluster platform. The API is still
changing substantially while the right abstractions settle, so expect
breaking changes between minor versions. Feedback and contributions are
welcome.
