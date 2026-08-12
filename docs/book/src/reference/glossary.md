# Glossary

One line each, in roughly the order you meet them. The last column names
where the term is actually explained, which is the only place that
explanation is maintained.

## The nouns

| Term        | Means                                                                                                                          | Explained in                                     |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| **Lab**     | Everything: your clusters, the host services supporting them, your secrets, and the plan that builds it all. One `mkLab` call. | [The Model](../understanding/model.md)           |
| **Cluster** | One Kubernetes cluster inside a lab, at `lab.clusters.<name>`. Inside that block, `config` means the cluster, not the lab.     | [The Model](../understanding/model.md)           |
| **Floe**    | One piece of your platform, packaged so you can switch it on with a line of configuration.                                     | [How It Works](../understanding/how-it-works.md) |
| **Bundle**  | A group of Kubernetes resources that install together. One floe usually produces several.                                      | [Bundle Schema](./bundles.md)                    |

## Ordering

| Term       | Means                                                                                                               | Explained in                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| **Wave**   | A set of bundles that can install at the same time, because none is waiting on another. Computed, never written.    | [How It Works](../understanding/how-it-works.md) |
| **Token**  | A short string meaning "this is ready", such as `cert-manager/webhook/ready`. Arbitrary: only the matching matters. | [How It Works](../understanding/how-it-works.md) |
| **Anchor** | "Order me against that", where "that" is a set of nodes an expression selects: a token, a kind, or a bundle name.   | [Anchors and Tokens](./anchors.md)               |

## The overloaded words

Three words mean one thing on a bundle and another on a floe.
[How It Works](../understanding/how-it-works.md) draws the distinction and
is the page to correct if it drifts.

| Term         | On a bundle                     | On a floe                                      |
| ------------ | ------------------------------- | ---------------------------------------------- |
| **provides** | readiness tokens it publishes   | not used                                       |
| **requires** | tokens that must be ready first | names of other floes that must also be enabled |
| **exports**  | not used                        | the typed values other floes can read          |

The bundle forms create ordering edges. The floe form of `requires` produces
an error message, not an edge.

## Building and running

| Term           | Means                                                                                                            | Explained in                                     |
| -------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| **Plan**       | The ordered list of steps that builds or destroys a lab. `lab plan` prints it, `lab up` runs it.                 | [How It Works](../understanding/how-it-works.md) |
| **Step**       | One entry in that list. Most come from the framework, and you can add your own.                                  | [Plan Step Kinds](./step-kinds.md)               |
| **Projection** | One key from an encrypted lab secret, placed into a Kubernetes Secret in a named cluster and namespace.          | [`lab.secrets`](./options/lab.md)                |
| **Aspect**     | Not a framework concept. A convention for a file that switches on one capability in whatever cluster imports it. |                                                  |

## Cloud labs

These only come up when you provision clusters in a cloud.

| Term       | Means                                                                                                                                                               | Explained in                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| **stage1** | The smallest set of manifests a temporary local cluster needs before it can create your real clusters. Derived, not listed.                                         | [`cluster.provisioning`](./options/cluster.md)   |
| **Pivot**  | Moving control of a cloud cluster off the temporary cluster that created it, onto the cluster itself.                                                               | [Plan Step Kinds](./step-kinds.md)               |
| **Owner**  | Which tool is responsible for a bundle, and when.                                                                                                                   | [How It Works](../understanding/how-it-works.md) |
| **Drift**  | A field something other than your CD tool writes, such as a webhook filling in a CA certificate. Declare it and ArgoCD stops reporting the resource as out of sync. | [`cluster.drift`](./options/cluster.md)          |
