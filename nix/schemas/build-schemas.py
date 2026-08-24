"""Turn the OpenAPI the flake already pins into the JSON Schema kubeconform reads.

Two inputs, one output directory. The Kubernetes swagger carries every builtin
kind; the CRD YAML each chart ships carries the rest. Both end up as
`<kind><suffix>.json` under a permissive tree and a strict one, where the
suffix is the layout kubeconform derives from a resource's apiVersion, so the
`-schema-location` template is the stock one.

Two sets rather than one flag: kubeconform's `-strict` does not tighten a
schema, it only swaps `{{ .StrictSuffix }}` in the path it looks the schema up
under. Strictness is a property of the file.

Strict here means a field the schema does not declare is an error, which is how
a misspelled key in a resource this repo authors gets caught. It is not applied
where the schema says not to: a CRD subtree marked
`x-kubernetes-preserve-unknown-fields` is free-form by the CRD author's own
declaration, and Crossplane and Argo CD both rely on that.
"""

import json
import os
import sys

import yaml


def _construct_value(loader, node):
    """A bare `=` is a valid YAML scalar that PyYAML has no constructor for.

    Prometheus ships one inside a PromQL expression in its CRDs, and without
    this the whole schema set fails to build over one character.
    """
    return str(node.value)


yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", _construct_value)


def suffix_for(api_version):
    """The `{{ .KindSuffix }}` kubeconform computes from an apiVersion.

    Mirrors schemaPath in kubeconform's pkg/registry/registry.go: the first
    dot-segment of the group, then the version. `apps/v1` gives `-apps-v1`,
    plain `v1` gives `-v1`, and `postgresql.cnpg.io/v1` gives
    `-postgresql-v1`.
    """
    parts = api_version.split("/")
    out = "-" + parts[0].split(".")[0].lower()
    if len(parts) > 1:
        out += "-" + parts[1].lower()
    return out


COMBINATORS = ("anyOf", "oneOf", "allOf", "not")


def strictify(node, close=True):
    """Forbid undeclared fields, except where the CRD author allowed them.

    `close` is false for the immediate body of an anyOf/oneOf/allOf/not
    branch. A branch says "these keys must be present", not "only these keys
    may be": CiliumNetworkPolicy's spec is four anyOf branches naming ingress,
    ingressDeny, egress and egressDeny, crossed with a oneOf naming
    endpointSelector and nodeSelector. Closing a branch makes it forbid every
    key the other branches require, so no policy can satisfy any of them and
    the kind becomes unsatisfiable rather than strict. The branch's siblings
    are still closed, which is where typos are actually caught.
    """
    if isinstance(node, list):
        return [strictify(item, close) for item in node]
    if not isinstance(node, dict):
        return node

    out = {}
    for key, value in node.items():
        if key in COMBINATORS:
            out[key] = strictify(value, close=False)
        elif key == "properties":
            out[key] = {name: strictify(sub) for name, sub in value.items()}
        else:
            out[key] = strictify(value)
    if node.get("x-kubernetes-preserve-unknown-fields") is True:
        out["additionalProperties"] = True
    elif close and "properties" in node and "additionalProperties" not in node:
        out["additionalProperties"] = False
    return out


def allow_null_optional(node):
    """Let an optional field be present and explicitly null.

    Kubernetes accepts `creationTimestamp: null` and `resources: null`, and
    round-tripping a manifest through most tooling produces exactly that, so
    upstream chart output is full of them. The swagger says only what type a
    field has when set, which read literally rejects half of every chart. A
    required field is left alone: null there is a real omission.
    """
    if isinstance(node, list):
        return [allow_null_optional(item) for item in node]
    if not isinstance(node, dict):
        return node

    out = {key: allow_null_optional(value) for key, value in node.items()}
    properties = out.get("properties")
    if not isinstance(properties, dict):
        return out

    required = out.get("required") or []
    for name, sub in properties.items():
        if name in required or not isinstance(sub, dict):
            continue
        kind = sub.get("type")
        if isinstance(kind, str) and kind != "null":
            sub["type"] = [kind, "null"]
        elif kind is None and "$ref" in sub:
            properties[name] = {"oneOf": [{"$ref": sub["$ref"]}, {"type": "null"}]}
    return out


def with_standard_fields(schema):
    """Give a CRD schema the three fields Kubernetes adds to every resource.

    A CRD's `openAPIV3Schema` describes what its author declared, which is
    usually just `spec` and `status`. `apiVersion`, `kind` and `metadata` are
    on the object regardless, so forbidding undeclared fields at the root
    without these would reject every custom resource ever written. Adding them
    rather than exempting the root keeps a misspelled top-level key an error.
    """
    if not isinstance(schema, dict):
        return schema
    properties = dict(schema.get("properties") or {})
    properties.setdefault("apiVersion", {"type": ["string", "null"]})
    properties.setdefault("kind", {"type": ["string", "null"]})
    properties.setdefault("metadata", {"type": ["object", "null"]})
    return dict(schema, properties=properties)


def int_or_string(node):
    """`int-or-string` is a Kubernetes format, not a JSON Schema one."""
    if isinstance(node, list):
        return [int_or_string(item) for item in node]
    if not isinstance(node, dict):
        return node
    if node.get("format") == "int-or-string":
        rest = {k: v for k, v in node.items() if k not in ("format", "type")}
        return dict(rest, oneOf=[{"type": "string"}, {"type": "integer"}])
    return {key: int_or_string(value) for key, value in node.items()}


def write(out_dir, name, schema):
    for tree, transform in (("", lambda s: s), ("-strict", strictify)):
        directory = os.path.join(out_dir, "schemas" + tree)
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, name), "w") as handle:
            json.dump(transform(schema), handle, indent=2)


def from_swagger(out_dir, path):
    with open(path) as handle:
        swagger = json.load(handle)

    definitions = allow_null_optional(int_or_string(swagger.get("definitions", {})))

    for tree in ("", "-strict"):
        directory = os.path.join(out_dir, "schemas" + tree)
        os.makedirs(directory, exist_ok=True)
        body = definitions if tree == "" else strictify(definitions)
        with open(os.path.join(directory, "_definitions.json"), "w") as handle:
            json.dump({"definitions": body}, handle, indent=2)

    written = 0
    for name, definition in definitions.items():
        for gvk in definition.get("x-kubernetes-group-version-kind", []):
            group, version, kind = gvk.get("group", ""), gvk["version"], gvk["kind"]
            api_version = f"{group}/{version}" if group else version
            filename = kind.lower() + suffix_for(api_version) + ".json"
            # A $ref rather than the definition inline: the builtin schemas
            # cross-reference each other heavily, and inlining would expand a
            # 4MB swagger into hundreds of MB of duplicated subtrees.
            for tree in ("", "-strict"):
                directory = os.path.join(out_dir, "schemas" + tree)
                with open(os.path.join(directory, filename), "w") as handle:
                    json.dump({"$ref": f"_definitions.json#/definitions/{name}"}, handle)
            written += 1
    return written


def from_crds(out_dir, paths):
    written = 0
    for path in paths:
        with open(path) as handle:
            for doc in yaml.safe_load_all(handle):
                if not isinstance(doc, dict):
                    continue
                if doc.get("kind") != "CustomResourceDefinition":
                    continue
                spec = doc.get("spec", {})
                kind = spec.get("names", {}).get("kind")
                group = spec.get("group")
                if not kind or not group:
                    continue
                for version in spec.get("versions", []):
                    schema = version.get("schema", {}).get("openAPIV3Schema")
                    if schema is None:
                        continue
                    filename = (
                        kind.lower() + suffix_for(f"{group}/{version['name']}") + ".json"
                    )
                    write(out_dir, filename, with_standard_fields(allow_null_optional(int_or_string(schema))))
                    written += 1
    return written


def main():
    out_dir, swagger, crds = sys.argv[1], sys.argv[2], sys.argv[3:]
    builtins_written = from_swagger(out_dir, swagger)
    crds_written = from_crds(out_dir, crds)
    print(f"{builtins_written} builtin schemas, {crds_written} CRD schemas")
    if builtins_written == 0 or crds_written == 0:
        raise SystemExit("a whole half of the schema set is empty, which cannot be right")


if __name__ == "__main__":
    main()
