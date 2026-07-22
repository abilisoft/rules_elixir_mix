"""Module extension for checksum-pinned Hex package repositories."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//repositories:source_archive.bzl", "source_archive")
load(":common.bzl", "format_deps_str", "package_build_file_content")
load(":hex_package.bzl", "hex_package_repo", "hex_package_tag")
load(":mix_deps_repo.bzl", "mix_deps_repo")
load(":mix_lock.bzl", "parse_mix_lock")

def _elixir_packages_impl(module_ctx):
    """Implementation of the elixir_packages module extension."""

    http_file(
        name = "rebar3",
        urls = ["https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3"],
        sha256 = "af85aab41f9fd74bdd6341ebdf6fe9c88077aab9f8eac82371583fa02f2b0bdf",
        downloaded_file_path = "rebar3",
        executable = False,
    )

    # Always provide hex_pm repository automatically
    # This ensures hex is available as a dependency for all mix_library targets
    source_archive(
        name = "hex_pm",
        urls = ["https://github.com/hexpm/hex/archive/refs/tags/v2.5.1.tar.gz"],
        strip_prefix = "hex-2.5.1",
        sha256 = "bdd6ef2015aa6e50a1c21212e098e8cbe7317da65f067955d154d890532742ae",
        archive_type = "tar.gz",
        build_file_content = """
load("@rules_elixir_mix//:defs.bzl", "mix_library")

mix_library(
    name = "lib",
    app_name = "hex",
    srcs = glob(["src/*.erl", "src/*.xrl", "src/*.hrl", "lib/**/*.ex"]),
    data = ["lib/hex/http/ca-bundle.crt"],
    mix_config = ":mix.exs",
    deps = [],
    warnings_as_errors = False,
    visibility = ["//visibility:public"],
)
""",
    )

    packages = []
    lock_tags = []

    # Collect all Hex package declarations from all modules.
    for mod in module_ctx.modules:
        for lock in mod.tags.mix_lock:
            lock_tags.append(lock)
        for dep in mod.tags.hex_package:
            if dep.build_file and dep.build_file_content:
                fail("build_file and build_file_content cannot be set simultaneously for {}".format(dep.name))
            if dep.sha256 and dep.integrity:
                fail("sha256 and integrity are mutually exclusive for {}".format(dep.name))
            packages.append({
                "name": dep.name,
                "pkg": dep.pkg,
                "version": dep.version,
                "sha256": dep.sha256,
                "integrity": dep.integrity,
                "build_file": dep.build_file,
                "build_file_content": dep.build_file_content,
                "patches": dep.patches,
                "patch_args": dep.patch_args,
                "explicit_deps": dep.explicit_deps,
                "compile_deps": dep.compile_deps,
                "manager": dep.manager,
                "native_build": dep.native_build,
                "precompiled_native_artifacts": [str(label) for label in dep.precompiled_native_artifacts],
                "precompiled_native_files": [str(label) for label in dep.precompiled_native_files],
                "module": mod,
                "repository_name": dep.repository_name,
                "repository_url": dep.repository_url,
            })

    # Deduplicate identical declarations by repository name, but fail on
    # conflicts. Bazel repository names are global within the extension output;
    # silently taking the first incompatible package makes cache keys and action
    # inputs surprising.
    seen = {}
    deduped = []
    for pkg in packages:
        if pkg["name"] not in seen:
            seen[pkg["name"]] = pkg
            deduped.append(pkg)
        elif not _same_hex_package(seen[pkg["name"]], pkg):
            existing = seen[pkg["name"]]
            fail("Conflicting hex_package declarations for {} from {} and {}".format(
                pkg["name"],
                existing["module"].name,
                pkg["module"].name,
            ))

    # Fetch all packages
    for pkg in deduped:
        hex_package_repo(
            name = pkg["name"],
            pkg = pkg["pkg"],
            version = pkg["version"],
            sha256 = pkg["sha256"],
            integrity = pkg["integrity"],
            build_file = pkg["build_file"],
            build_file_content = pkg["build_file_content"],
            patches = pkg["patches"],
            patch_args = pkg["patch_args"],
            explicit_deps = pkg["explicit_deps"],
            compile_deps = pkg["compile_deps"],
            manager = pkg["manager"],
            native_build = pkg["native_build"],
            precompiled_native_artifacts = pkg["precompiled_native_artifacts"],
            precompiled_native_files = pkg["precompiled_native_files"],
            repository_name = pkg["repository_name"],
            repository_url = pkg["repository_url"],
        )

    generated_hubs = []
    generated_identities = {}
    generated_repository_names = {}
    for lock in lock_tags:
        specs = parse_mix_lock(module_ctx.read(lock.lockfile))
        repository_urls = dict(lock.repositories)
        by_package = {spec.package: spec for spec in specs}
        unknown_native_packages = [package for package in lock.native_build_packages if package not in by_package]
        if unknown_native_packages:
            fail("native_build_packages contains packages absent from mix.lock: {}".format(sorted(unknown_native_packages)))
        labels = {}
        pending = list(specs)
        for _ in range(len(specs) + 1):
            next_pending = []
            progress = False
            for spec in pending:
                dependency_packages = [
                    dep
                    for dep in spec.compile_deps + spec.runtime_deps
                    if dep in by_package
                ]
                unresolved = [dep for dep in dependency_packages if dep not in labels]
                if unresolved:
                    next_pending.append(spec)
                    continue
                compile_deps = [labels[dep] for dep in spec.compile_deps if dep in labels]
                runtime_deps = [labels[dep] for dep in spec.runtime_deps if dep in labels]
                native_artifact = lock.precompiled_native_artifacts.get(spec.package)
                native_artifacts = [str(native_artifact)] if native_artifact else []
                native_file = lock.precompiled_native_files.get(spec.package)
                native_files = [str(native_file)] if native_file else []
                native_build = spec.package in lock.native_build_packages and not native_artifacts and not native_files
                if (native_artifacts or native_files) and spec.manager != "mix":
                    fail("precompiled native inputs are only supported for Mix package '{}'".format(spec.package))
                if native_artifacts and native_files:
                    fail("package '{}' cannot use both precompiled_native_artifacts and precompiled_native_files".format(spec.package))
                identity = repr([
                    spec.app_name,
                    spec.package,
                    spec.version,
                    spec.sha256,
                    spec.manager,
                    compile_deps,
                    runtime_deps,
                    native_artifacts,
                    native_files,
                    native_build,
                    spec.repository,
                    repository_urls.get(spec.repository),
                ])
                if spec.repository not in repository_urls:
                    fail("mix.lock repository '{}' for package '{}' has no explicit URL mapping".format(
                        spec.repository,
                        spec.package,
                    ))
                if identity in generated_identities:
                    repository_name = generated_identities[identity]
                else:
                    repository_name = _generated_repository_name(spec, identity, generated_repository_names)
                    generated_identities[identity] = repository_name
                    generated_repository_names[repository_name] = identity
                    hex_package_repo(
                        name = repository_name,
                        pkg = spec.package,
                        version = spec.version,
                        sha256 = spec.sha256,
                        integrity = None,
                        manager = spec.manager,
                        repository_name = spec.repository,
                        repository_url = repository_urls[spec.repository],
                        build_file = None,
                        build_file_content = package_build_file_content(
                            app_name = spec.app_name,
                            manager = spec.manager,
                            package = spec.package,
                            explicit_deps_str = format_deps_str(runtime_deps),
                            compile_deps_str = format_deps_str(compile_deps),
                            native_build = native_build,
                            precompiled_native_artifacts_str = format_deps_str(native_artifacts),
                            precompiled_native_files_str = format_deps_str(native_files),
                            repository = spec.repository,
                            sha256 = spec.sha256,
                            version = spec.version,
                        ),
                        patches = [],
                        patch_args = ["-p0"],
                    )
                labels[spec.package] = "@{}//:{}".format(repository_name, spec.app_name)
                progress = True
            if not next_pending:
                break
            if not progress:
                fail("mix.lock contains a dependency cycle among {}".format([spec.package for spec in next_pending]))
            pending = next_pending

        mix_deps_repo(
            name = lock.name,
            packages = {
                spec.app_name: labels[spec.package]
                for spec in specs
            },
        )
        generated_hubs.append(lock.name)

    direct_repositories = ["hex_pm"] + generated_hubs
    return module_ctx.extension_metadata(
        root_module_direct_deps = direct_repositories if module_ctx.root_module_has_non_dev_dependency else [],
        root_module_direct_dev_deps = [] if module_ctx.root_module_has_non_dev_dependency else direct_repositories,
        reproducible = True,
    )

def _sanitize_repository_part(value):
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
    return "".join([value[index] if value[index] in allowed else "_" for index in range(len(value))])

def _generated_repository_name(spec, identity, existing):
    base = "rules_elixir_mix_lock_{}_{}_{}_{}".format(
        _sanitize_repository_part(spec.package),
        _sanitize_repository_part(spec.version),
        spec.sha256[:16],
        spec.manager,
    )
    if base not in existing or existing[base] == identity:
        return base
    for suffix in range(2, 10000):
        candidate = "{}_{}".format(base, suffix)
        if candidate not in existing or existing[candidate] == identity:
            return candidate
    fail("too many generated repository-name collisions for {}".format(base))

def _same_str_list(a, b):
    return [str(x) for x in a] == [str(x) for x in b]

def _same_hex_package(a, b):
    return (
        a["pkg"] == b["pkg"] and
        a["version"] == b["version"] and
        a["sha256"] == b["sha256"] and
        a["integrity"] == b["integrity"] and
        str(a["build_file"]) == str(b["build_file"]) and
        a["build_file_content"] == b["build_file_content"] and
        _same_str_list(a["patches"], b["patches"]) and
        a["patch_args"] == b["patch_args"] and
        _same_str_list(a["explicit_deps"], b["explicit_deps"]) and
        _same_str_list(a["compile_deps"], b["compile_deps"]) and
        a["manager"] == b["manager"] and
        a["native_build"] == b["native_build"] and
        a["precompiled_native_artifacts"] == b["precompiled_native_artifacts"] and
        a["precompiled_native_files"] == b["precompiled_native_files"] and
        a["repository_name"] == b["repository_name"] and
        a["repository_url"] == b["repository_url"]
    )

# The module extension
elixir_packages = module_extension(
    implementation = _elixir_packages_impl,
    tag_classes = {
        "hex_package": hex_package_tag,
        "mix_lock": tag_class(attrs = {
            "name": attr.string(default = "mix_deps"),
            "lockfile": attr.label(mandatory = True, allow_single_file = [".lock"]),
            "repositories": attr.string_dict(default = {
                "hexpm": "https://repo.hex.pm",
            }),
            "precompiled_native_artifacts": attr.string_keyed_label_dict(allow_files = True),
            "precompiled_native_files": attr.string_keyed_label_dict(allow_files = True),
            "native_build_packages": attr.string_list(),
        }),
    },
)
