"""Bzlmod extension for OTP+Elixir toolchains."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//bzlmod:versions.bzl", "DEFAULT_ELIXIR_VERSION", "DEFAULT_OTP_VERSION", "resolve_source_release")
load(
    "//repositories:elixir_config.bzl",
    "INSTALLATION_TYPE_PREBUILT",
    "INSTALLATION_TYPE_SOURCE",
    _elixir_config = "elixir_config",
)
load("//repositories:source_archive.bzl", "source_archive")

def _runtime_build_file(executables):
    return """package(default_visibility = [\"//visibility:public\"])

exports_files({executables})

filegroup(
    name = \"runtime\",
    srcs = glob([\"**\"], exclude = [\"BUILD.bazel\"]),
)
""".format(executables = repr(executables))

def _urls(url, mirrors):
    return [url] + mirrors

def _runtime_label(repository, target):
    return "@{}//:{}".format(repository, target)

def _validate_sha256(value, attribute, name):
    hexadecimal = "0123456789abcdefABCDEF"
    if len(value) != 64 or any([value[index] not in hexadecimal for index in range(len(value))]):
        fail("toolchain '{}' {} must be a non-empty 64-character hexadecimal SHA-256".format(name, attribute))

def _claim_name(mod, name, owners):
    if not name:
        fail("toolchain names must not be empty")
    if name in owners:
        fail("toolchain '{}' is declared by both {} and {}".format(name, owners[name].name, mod.name))
    owners[name] = mod

def _platform_constraints(tag):
    runtime_abi = str(tag.runtime_abi)
    if "//os:" in runtime_abi or "//cpu:" in runtime_abi:
        fail("toolchain '{}' runtime_abi must be a dedicated constraint value, not an OS or CPU constraint".format(tag.name))
    execution = sorted({str(label): True for label in tag.exec_compatible_with + [tag.runtime_abi]}.keys())
    target = sorted({str(label): True for label in tag.target_compatible_with + [tag.runtime_abi]}.keys()) if tag.target_compatible_with else execution
    if not execution:
        fail("toolchain '{}' requires explicit exec_compatible_with OS and CPU constraints".format(tag.name))
    if not any(["//os:" in constraint for constraint in execution]) or not any(["//cpu:" in constraint for constraint in execution]):
        fail("toolchain '{}' exec_compatible_with must include explicit @platforms OS and CPU constraints".format(tag.name))
    if not any([constraint.endswith("//os:linux") for constraint in execution]):
        fail("toolchain '{}' must target Linux; the native erlexec launcher contract currently requires /proc and Unix path lists".format(tag.name))
    if target != execution:
        fail("toolchain '{}' must use the same execution and target platform constraints; cross-compiling ERTS/NIFs is not supported".format(tag.name))
    return execution, target

def _fetch_runtime(name, url, urls, sha256, strip_prefix, archive_type, executables):
    kwargs = {
        "name": name,
        "urls": _urls(url, urls),
        "sha256": sha256,
        "strip_prefix": strip_prefix,
        "build_file_content": _runtime_build_file(executables),
    }
    if archive_type:
        kwargs["type"] = archive_type
    http_archive(**kwargs)

def _fetch_source(name, url, urls, sha256, strip_prefix, archive_type):
    source_archive(
        name = name,
        urls = _urls(url, urls),
        sha256 = sha256,
        strip_prefix = strip_prefix,
        archive_type = archive_type,
    )

def _toolchains_impl(module_ctx):
    types = {}
    otp_versions = {}
    bootstrap_otp_versions = {}
    bootstrap_runtime_files = {}
    bootstrap_erlexec_files = {}
    bootstrap_version_markers = {}
    otp_source_files = {}
    otp_source_directory_manifests = {}
    otp_runtime_files = {}
    erlexec_files = {}
    otp_version_markers = {}
    elixir_versions = {}
    elixir_runtime_files = {}
    elixir_home_markers = {}
    elixir_version_markers = {}
    elixir_source_files = {}
    bash_files = {}
    make_files = {}
    posix_tool_files = {}
    perl_files = {}
    crypto_sdk_files = {}
    fips_modes = {}
    static_crypto_nifs = {}
    configure_options = {}
    make_options = {}
    copts = {}
    cxxopts = {}
    linkopts = {}
    jobs = {}
    elixir_jobs = {}
    elixir_make_options = {}
    exec_constraints = {}
    target_constraints = {}
    defaults = {}
    owners = {}

    for mod in module_ctx.modules:
        for tag in mod.tags.prebuilt_toolchain:
            _claim_name(mod, tag.name, owners)
            _validate_sha256(tag.otp_sha256, "otp_sha256", tag.name)
            _validate_sha256(tag.elixir_sha256, "elixir_sha256", tag.name)
            types[tag.name] = INSTALLATION_TYPE_PREBUILT
            otp_versions[tag.name] = tag.otp_version
            elixir_versions[tag.name] = tag.elixir_version
            execution, target = _platform_constraints(tag)
            exec_constraints[tag.name] = execution
            target_constraints[tag.name] = target
            fips_modes[tag.name] = tag.fips
            static_crypto_nifs[tag.name] = str(tag.static_crypto_nif)
            defaults[tag.name] = tag.default
            if tag.crypto_sdk:
                crypto_sdk_files[tag.name] = str(tag.crypto_sdk)
            if any([tag.bash, tag.make, tag.perl, tag.posix_tools]):
                if not all([tag.bash, tag.make, tag.perl, tag.posix_tools]):
                    fail("prebuilt_toolchain '{}' native Bash, Make, Perl, and POSIX tools must be declared together".format(tag.name))
                bash_files[tag.name] = str(tag.bash)
                make_files[tag.name] = str(tag.make)
                perl_files[tag.name] = str(tag.perl)
                posix_tool_files[tag.name] = [str(label) for label in tag.posix_tools]

            otp_repository = "rules_elixir_mix_otp_{}".format(tag.name)
            otp_version_marker = tag.otp_version_marker or "releases/{}/OTP_VERSION".format(tag.otp_version.split(".")[0])
            _fetch_runtime(
                otp_repository,
                tag.otp_url,
                tag.otp_urls,
                tag.otp_sha256,
                tag.otp_strip_prefix,
                tag.otp_type,
                [tag.erlexec, otp_version_marker],
            )
            otp_runtime_files[tag.name] = _runtime_label(otp_repository, "runtime")
            erlexec_files[tag.name] = _runtime_label(otp_repository, tag.erlexec)
            otp_version_markers[tag.name] = _runtime_label(otp_repository, otp_version_marker)

            elixir_repository = "rules_elixir_mix_elixir_{}".format(tag.name)
            elixir_version_marker = tag.elixir_version_marker or "VERSION"
            _fetch_runtime(
                elixir_repository,
                tag.elixir_url,
                tag.elixir_urls,
                tag.elixir_sha256,
                tag.elixir_strip_prefix,
                tag.elixir_type,
                [tag.elixir_home_marker, elixir_version_marker],
            )
            elixir_runtime_files[tag.name] = _runtime_label(elixir_repository, "runtime")
            elixir_home_markers[tag.name] = _runtime_label(elixir_repository, tag.elixir_home_marker)
            elixir_version_markers[tag.name] = _runtime_label(elixir_repository, elixir_version_marker)

        for tag in mod.tags.source_toolchain:
            _claim_name(mod, tag.name, owners)
            _validate_sha256(tag.bootstrap_otp_sha256, "bootstrap_otp_sha256", tag.name)
            otp_source = resolve_source_release(
                language = "otp",
                version = tag.otp_version,
                url = tag.otp_url,
                sha256 = tag.otp_sha256,
                strip_prefix = tag.otp_strip_prefix,
                archive_type = tag.otp_type,
            )
            elixir_source = resolve_source_release(
                language = "elixir",
                version = tag.elixir_version,
                url = tag.elixir_url,
                sha256 = tag.elixir_sha256,
                strip_prefix = tag.elixir_strip_prefix,
                archive_type = tag.elixir_type,
            )
            _validate_sha256(otp_source.sha256, "otp_sha256", tag.name)
            _validate_sha256(elixir_source.sha256, "elixir_sha256", tag.name)
            if not tag.posix_tools:
                fail("source_toolchain '{}' requires a declared hermetic posix_tools bundle".format(tag.name))
            types[tag.name] = INSTALLATION_TYPE_SOURCE
            otp_versions[tag.name] = tag.otp_version
            bootstrap_otp_versions[tag.name] = tag.bootstrap_otp_version
            elixir_versions[tag.name] = tag.elixir_version
            execution, target = _platform_constraints(tag)
            exec_constraints[tag.name] = execution
            target_constraints[tag.name] = target
            fips_modes[tag.name] = tag.fips
            static_crypto_nifs[tag.name] = str(tag.static_crypto_nif)
            defaults[tag.name] = tag.default

            bootstrap_repository = "rules_elixir_mix_bootstrap_otp_{}".format(tag.name)
            bootstrap_version_marker = tag.bootstrap_version_marker or "releases/{}/OTP_VERSION".format(tag.bootstrap_otp_version.split(".")[0])
            _fetch_runtime(
                bootstrap_repository,
                tag.bootstrap_otp_url,
                tag.bootstrap_otp_urls,
                tag.bootstrap_otp_sha256,
                tag.bootstrap_otp_strip_prefix,
                tag.bootstrap_otp_type,
                [tag.bootstrap_erlexec, bootstrap_version_marker],
            )
            bootstrap_runtime_files[tag.name] = _runtime_label(bootstrap_repository, "runtime")
            bootstrap_erlexec_files[tag.name] = _runtime_label(bootstrap_repository, tag.bootstrap_erlexec)
            bootstrap_version_markers[tag.name] = _runtime_label(bootstrap_repository, bootstrap_version_marker)

            otp_repository = "rules_elixir_mix_otp_sources_{}".format(tag.name)
            _fetch_source(
                otp_repository,
                otp_source.url,
                tag.otp_urls,
                otp_source.sha256,
                otp_source.strip_prefix,
                otp_source.archive_type,
            )
            otp_source_files[tag.name] = _runtime_label(otp_repository, "runtime")
            otp_source_directory_manifests[tag.name] = _runtime_label(otp_repository, "source_directories.manifest")

            elixir_repository = "rules_elixir_mix_elixir_sources_{}".format(tag.name)
            _fetch_runtime(
                elixir_repository,
                elixir_source.url,
                tag.elixir_urls,
                elixir_source.sha256,
                elixir_source.strip_prefix,
                elixir_source.archive_type,
                [],
            )
            elixir_source_files[tag.name] = _runtime_label(elixir_repository, "runtime")

            bash_files[tag.name] = str(tag.bash)
            make_files[tag.name] = str(tag.make)
            posix_tool_files[tag.name] = [str(label) for label in tag.posix_tools]
            perl_files[tag.name] = str(tag.perl)
            if tag.crypto_sdk:
                crypto_sdk_files[tag.name] = str(tag.crypto_sdk)
            configure_options[tag.name] = tag.configure_options
            make_options[tag.name] = tag.make_options
            copts[tag.name] = tag.copts
            cxxopts[tag.name] = tag.cxxopts
            linkopts[tag.name] = tag.linkopts
            jobs[tag.name] = str(tag.jobs)
            elixir_jobs[tag.name] = str(tag.elixir_jobs)
            elixir_make_options[tag.name] = tag.elixir_make_options

    if not types:
        fail("declare at least one checksum-pinned prebuilt_toolchain or source_toolchain before use_repo")
    default_names = sorted([name for name in types if defaults[name]])
    if len(types) == 1:
        default_name = sorted(types.keys())[0]
    elif len(default_names) == 1:
        default_name = default_names[0]
    else:
        fail("declare exactly one toolchain with default=True when multiple toolchains are configured")

    _elixir_config(
        name = "elixir_config",
        types = types,
        default_name = default_name,
        otp_versions = otp_versions,
        bootstrap_otp_versions = bootstrap_otp_versions,
        bootstrap_runtime_files = bootstrap_runtime_files,
        bootstrap_erlexec_files = bootstrap_erlexec_files,
        bootstrap_version_markers = bootstrap_version_markers,
        otp_source_files = otp_source_files,
        otp_source_directory_manifests = otp_source_directory_manifests,
        otp_runtime_files = otp_runtime_files,
        erlexec_files = erlexec_files,
        otp_version_markers = otp_version_markers,
        elixir_versions = elixir_versions,
        elixir_runtime_files = elixir_runtime_files,
        elixir_home_markers = elixir_home_markers,
        elixir_version_markers = elixir_version_markers,
        elixir_source_files = elixir_source_files,
        bash_files = bash_files,
        make_files = make_files,
        posix_tool_files = posix_tool_files,
        perl_files = perl_files,
        crypto_sdk_files = crypto_sdk_files,
        fips_modes = fips_modes,
        static_crypto_nifs = static_crypto_nifs,
        configure_options = configure_options,
        make_options = make_options,
        copts = copts,
        cxxopts = cxxopts,
        linkopts = linkopts,
        jobs = jobs,
        elixir_jobs = elixir_jobs,
        elixir_make_options = elixir_make_options,
        exec_compatible_withs = exec_constraints,
        target_compatible_withs = target_constraints,
    )
    root_nondev = module_ctx.root_module_has_non_dev_dependency
    return module_ctx.extension_metadata(
        root_module_direct_deps = ["elixir_config"] if root_nondev else [],
        root_module_direct_dev_deps = [] if root_nondev else ["elixir_config"],
        reproducible = True,
    )

prebuilt_toolchain = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "otp_version": attr.string(mandatory = True),
    "otp_url": attr.string(mandatory = True),
    "otp_urls": attr.string_list(),
    "otp_sha256": attr.string(mandatory = True),
    "otp_strip_prefix": attr.string(),
    "otp_type": attr.string(),
    "erlexec": attr.string(mandatory = True),
    "otp_version_marker": attr.string(),
    "elixir_version": attr.string(mandatory = True),
    "elixir_url": attr.string(mandatory = True),
    "elixir_urls": attr.string_list(),
    "elixir_sha256": attr.string(mandatory = True),
    "elixir_strip_prefix": attr.string(),
    "elixir_type": attr.string(),
    "elixir_home_marker": attr.string(default = "bin/elixir"),
    "elixir_version_marker": attr.string(default = "VERSION"),
    "exec_compatible_with": attr.label_list(),
    "target_compatible_with": attr.label_list(),
    "runtime_abi": attr.label(mandatory = True),
    "fips": attr.string(default = "disabled", values = ["disabled", "required"]),
    "static_crypto_nif": attr.bool(default = False),
    "crypto_sdk": attr.label(),
    "bash": attr.label(),
    "make": attr.label(),
    "posix_tools": attr.label_list(),
    "perl": attr.label(),
    "default": attr.bool(default = False),
})

source_toolchain = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "bootstrap_otp_version": attr.string(mandatory = True),
    "bootstrap_otp_url": attr.string(mandatory = True),
    "bootstrap_otp_urls": attr.string_list(),
    "bootstrap_otp_sha256": attr.string(mandatory = True),
    "bootstrap_otp_strip_prefix": attr.string(),
    "bootstrap_otp_type": attr.string(),
    "bootstrap_erlexec": attr.string(mandatory = True),
    "bootstrap_version_marker": attr.string(),
    "otp_version": attr.string(default = DEFAULT_OTP_VERSION),
    "otp_url": attr.string(),
    "otp_urls": attr.string_list(),
    "otp_sha256": attr.string(),
    "otp_strip_prefix": attr.string(),
    "otp_type": attr.string(),
    "elixir_version": attr.string(default = DEFAULT_ELIXIR_VERSION),
    "elixir_url": attr.string(),
    "elixir_urls": attr.string_list(),
    "elixir_sha256": attr.string(),
    "elixir_strip_prefix": attr.string(),
    "elixir_type": attr.string(),
    "bash": attr.label(mandatory = True),
    "make": attr.label(mandatory = True),
    "posix_tools": attr.label_list(mandatory = True),
    "perl": attr.label(mandatory = True),
    "crypto_sdk": attr.label(),
    "configure_options": attr.string_list(),
    "make_options": attr.string_list(),
    "copts": attr.string_list(),
    "cxxopts": attr.string_list(),
    "linkopts": attr.string_list(),
    "jobs": attr.int(default = 8),
    "elixir_jobs": attr.int(default = 8),
    "elixir_make_options": attr.string_list(),
    "exec_compatible_with": attr.label_list(),
    "target_compatible_with": attr.label_list(),
    "runtime_abi": attr.label(mandatory = True),
    "fips": attr.string(default = "disabled", values = ["disabled", "required"]),
    "static_crypto_nif": attr.bool(default = False),
    "default": attr.bool(default = False),
})

elixir_config = module_extension(
    implementation = _toolchains_impl,
    tag_classes = {
        "prebuilt_toolchain": prebuilt_toolchain,
        "source_toolchain": source_toolchain,
    },
)
