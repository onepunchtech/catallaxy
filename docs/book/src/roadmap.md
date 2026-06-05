# Roadmap

Completed features are in the [CHANGELOG](https://github.com/onepunch/catallaxy/blob/master/CHANGELOG.md). This page shows what's planned.

## Next

- Management cluster pivot — bootstrap on k3d, self-provision in cloud, migrate state, destroy bootstrap
- Registry mirror integration — configure containerd to use lab Zot as pull-through cache
- Component network policies — built-in components declare cross-namespace allow rules when `networkPolicies.enable`

## Later

- On-premises support (Talos Linux on bare metal)
- Performance benchmarking for large multi-cluster labs
- Computed SBOMs from image set and rendered manifests
- `cata images lock` — resolve tags to digests automatically (lockfile pattern)

## Ideas

- Automated testing framework for lab configurations
- Global image registry rewrite for air-gapped environments
