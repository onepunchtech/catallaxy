//! One parser for an image reference.
//!
//! There were two, and they disagreed about what a reference is. The images
//! side wanted whatever a registry API wants after `/manifests/`; the lint
//! side wanted the tag and the digest apart so it could ask whether one is
//! missing. Neither is wrong, so this keeps the parts separate and offers the
//! registry-shaped views as accessors.

/// An image reference, taken apart.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageRef {
    /// `docker.io` when the reference did not name one.
    pub registry: String,
    /// As written, without the registry: `nginx`, `o/r`, `a/b`. Not what a
    /// registry API wants for a bare Docker Hub name; see `api_repository`.
    pub repository: String,
    pub tag: Option<String>,
    pub digest: Option<String>,
}

impl ImageRef {
    pub fn parse(image: &str) -> Self {
        // Digest, then tag, then whatever is left is the repository.
        // Splitting on `@` alone leaves the tag stuck to the repository, which
        // is how a digest-pinned reference once asked a registry for
        // `library/nginx:1.27`.
        let (before_digest, digest) = match image.split_once('@') {
            Some((before, d)) => (before, Some(d.to_string())),
            None => (image, None),
        };

        let (repo_part, tag) = match before_digest.rfind(':') {
            // A colon after the last slash is a tag; one before it is a
            // registry port.
            Some(idx) if !before_digest[idx + 1..].contains('/') => (
                &before_digest[..idx],
                Some(before_digest[idx + 1..].to_string()),
            ),
            _ => (before_digest, None),
        };

        // A first segment with a dot or a colon is a hostname. Anything else
        // is part of the repository and the registry is implicit.
        let (registry, repository) = match repo_part.split_once('/') {
            Some((first, rest)) if first.contains('.') || first.contains(':') => {
                (first.to_string(), rest.to_string())
            }
            _ => ("docker.io".to_string(), repo_part.to_string()),
        };

        Self {
            registry,
            repository,
            tag,
            digest,
        }
    }

    /// What to ask a registry for after `/manifests/`.
    pub fn reference(&self) -> String {
        self.digest
            .clone()
            .or_else(|| self.tag.clone())
            .unwrap_or_else(|| "latest".to_string())
    }

    /// The repository a registry API expects, which for a single-segment
    /// Docker Hub name is not what the reference said.
    pub fn api_repository(&self) -> String {
        if self.registry == "docker.io" && !self.repository.contains('/') {
            format!("library/{}", self.repository)
        } else {
            self.repository.clone()
        }
    }

    /// The same reference against a different registry.
    ///
    /// Built from `repository` rather than `api_repository`, because this
    /// feeds `crane copy`, which resolves a bare Docker Hub name itself and
    /// would otherwise be handed a `library/` prefix the source never had.
    pub fn with_registry(&self, registry: &str) -> String {
        let mut out = format!("{registry}/{}", self.repository);
        if let Some(tag) = &self.tag {
            out.push(':');
            out.push_str(tag);
        }
        if let Some(digest) = &self.digest {
            out.push('@');
            out.push_str(digest);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bare_name_gets_the_implicit_registry() {
        let r = ImageRef::parse("nginx:1.27");
        assert_eq!(r.registry, "docker.io");
        assert_eq!(r.repository, "nginx", "as written");
        assert_eq!(r.api_repository(), "library/nginx", "as the API wants it");
        assert_eq!(r.reference(), "1.27");
        assert_eq!(r.tag.as_deref(), Some("1.27"));
    }

    // The lint asks whether a tag is missing, so this must stay None rather
    // than being filled in with `latest`.
    #[test]
    fn an_untagged_name_carries_no_tag_but_asks_for_latest() {
        let r = ImageRef::parse("nginx");
        assert_eq!(r.tag, None);
        assert_eq!(r.digest, None);
        assert_eq!(r.reference(), "latest");
    }

    #[test]
    fn a_tag_and_a_digest_are_separated_from_the_repository() {
        let r = ImageRef::parse("nginx:1.27@sha256:abc");
        assert_eq!(r.repository, "nginx");
        assert_eq!(r.tag.as_deref(), Some("1.27"));
        assert_eq!(r.digest.as_deref(), Some("sha256:abc"));
        assert_eq!(r.reference(), "sha256:abc", "a fetch asks for the digest");
    }

    #[test]
    fn a_registry_port_is_not_a_tag() {
        let r = ImageRef::parse("localhost:5050/team/app:1.2@sha256:abc");
        assert_eq!(r.registry, "localhost:5050");
        assert_eq!(r.repository, "team/app");
        assert_eq!(r.tag.as_deref(), Some("1.2"));
    }

    #[test]
    fn a_multi_segment_docker_hub_name_needs_no_library_prefix() {
        let r = ImageRef::parse("grafana/grafana:11.4.0");
        assert_eq!(r.registry, "docker.io");
        assert_eq!(r.api_repository(), "grafana/grafana");
    }

    // crane resolves a bare Docker Hub name itself, so retargeting must not
    // hand it a `library/` the source reference never had.
    #[test]
    fn retargeting_keeps_the_repository_as_written() {
        assert_eq!(
            ImageRef::parse("nginx:1.27").with_registry("mirror.test"),
            "mirror.test/nginx:1.27"
        );
        assert_eq!(
            ImageRef::parse("docker.io/library/nginx:1.27@sha256:abc").with_registry("mirror.test"),
            "mirror.test/library/nginx:1.27@sha256:abc"
        );
    }

    #[test]
    fn retargeting_an_untagged_name_adds_nothing() {
        assert_eq!(
            ImageRef::parse("ghcr.io/o/r").with_registry("mirror.test"),
            "mirror.test/o/r"
        );
    }
}
