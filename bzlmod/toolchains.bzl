"""Bzlmod extension for OTP+Elixir toolchains."""

load("//bzlmod:versions.bzl", "DEFAULT_ELIXIR_VERSION", "DEFAULT_OTP_VERSION", "resolve_source_release")
load(
    "//repositories:elixir_config.bzl",
    "INSTALLATION_TYPE_PREBUILT",
    "INSTALLATION_TYPE_SOURCE",
    _elixir_config = "elixir_config",
)
load("//repositories:prebuilt_archive.bzl", "prebuilt_archive")
load("//repositories:source_archive.bzl", "source_archive")

def _urls(url, mirrors):
    urls = [url] + mirrors
    for candidate in urls:
        if not candidate.startswith("https://"):
            fail("toolchain archives must use HTTPS URLs, got '{}'".format(candidate))
    return urls

def _runtime_label(repository, target):
    return "@{}//:{}".format(repository, target)

def _validate_sha256(value, attribute, name):
    hexadecimal = "0123456789abcdef"
    if len(value) != 64 or any([value[index] not in hexadecimal for index in range(len(value))]):
        fail("toolchain '{}' {} must be a 64-character lowercase hexadecimal SHA-256".format(name, attribute))

def _validate_relative_path(value, attribute, name, allow_empty = False):
    if not value:
        if allow_empty:
            return
        fail("toolchain '{}' {} must not be empty".format(name, attribute))
    if value.startswith("/") or "\\" in value:
        fail("toolchain '{}' {} must be a normalized relative path".format(name, attribute))
    components = value.split("/")
    if "" in components or "." in components or ".." in components:
        fail("toolchain '{}' {} must be a normalized relative path".format(name, attribute))

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
    execution = sorted({str(label): True for label in tag.exec_compatible_with}.keys())
    target_base = tag.target_compatible_with if tag.target_compatible_with else tag.exec_compatible_with
    target = sorted({str(label): True for label in target_base + [tag.runtime_abi]}.keys())
    if not execution:
        fail("toolchain '{}' requires explicit exec_compatible_with OS and CPU constraints".format(tag.name))
    if not any(["//os:" in constraint for constraint in execution]) or not any(["//cpu:" in constraint for constraint in execution]):
        fail("toolchain '{}' exec_compatible_with must include explicit @platforms OS and CPU constraints".format(tag.name))
    for constraints, kind in [(execution, "exec_compatible_with"), (target, "target_compatible_with")]:
        if not any(["//os:" in constraint for constraint in constraints]) or not any(["//cpu:" in constraint for constraint in constraints]):
            fail("toolchain '{}' {} must include explicit @platforms OS and CPU constraints".format(tag.name, kind))
        if not any([constraint.endswith("//os:linux") for constraint in constraints]):
            fail("toolchain '{}' {} must target Linux; the native erlexec contract requires /proc and Unix path lists".format(tag.name, kind))
    execution_cpus = sorted([constraint for constraint in execution if "//cpu:" in constraint])
    target_cpus = sorted([constraint for constraint in target if "//cpu:" in constraint])
    execution_oses = sorted([constraint for constraint in execution if "//os:" in constraint])
    target_oses = sorted([constraint for constraint in target if "//os:" in constraint])
    if execution_oses != target_oses:
        fail("toolchain '{}' source builds require matching execution and target OS constraints".format(tag.name))
    if execution_cpus != target_cpus and not getattr(tag, "cross_compile", False):
        fail("toolchain '{}' requires matching execution and target CPU constraints unless cross_compile=True".format(tag.name))
    return execution, target

def _target_arch(constraints, name):
    architectures = []
    for constraint in constraints:
        if constraint.endswith("//cpu:x86_64"):
            architectures.append("amd64")
        elif constraint.endswith("//cpu:arm64"):
            architectures.append("arm64")
    if len(architectures) != 1:
        fail("toolchain '{}' target_compatible_with must select exactly one supported CPU".format(name))
    return architectures[0]

def _fetch_runtime(name, url, urls, sha256, strip_prefix, archive_type, exported_files):
    _validate_relative_path(strip_prefix, "strip_prefix", name, allow_empty = True)
    for exported_file in exported_files:
        _validate_relative_path(exported_file, "archive file", name)
    prebuilt_archive(
        name = name,
        urls = _urls(url, urls),
        sha256 = sha256,
        strip_prefix = strip_prefix,
        archive_type = archive_type,
        exported_files = exported_files,
    )

def _fetch_source(name, url, urls, sha256, strip_prefix, archive_type):
    _validate_relative_path(strip_prefix, "strip_prefix", name, allow_empty = True)
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
    bootstrap_otp_targets = {}
    bootstrap_runtime_files = {}
    bootstrap_erlexec_files = {}
    bootstrap_boot_files = {}
    bootstrap_version_markers = {}
    bootstrap_fully_static_otps = {}
    bootstrap_exec_constraints = {}
    otp_source_files = {}
    otp_source_directory_manifests = {}
    otp_runtime_files = {}
    otp_targets = {}
    wrapped_otps = {}
    erlexec_files = {}
    otp_boot_files = {}
    otp_version_markers = {}
    elixir_versions = {}
    elixir_runtime_files = {}
    elixir_targets = {}
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
    fully_static_otps = {}
    cross_compiles = {}
    jit_modes = {}
    libcs = {}
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
    target_arches = {}
    defaults = {}
    owners = {}

    for mod in module_ctx.modules:
        for tag in mod.tags.prebuilt_toolchain:
            _claim_name(mod, tag.name, owners)
            provider_prebuilt = bool(tag.otp or tag.elixir)
            archive_prebuilt = bool(
                tag.otp_url or
                tag.otp_urls or
                tag.otp_sha256 or
                tag.otp_strip_prefix or
                tag.otp_type or
                tag.erlexec or
                tag.otp_boot_file or
                tag.otp_version_marker or
                tag.elixir_url or
                tag.elixir_urls or
                tag.elixir_sha256 or
                tag.elixir_strip_prefix or
                tag.elixir_type or
                tag.elixir_home_marker or
                tag.elixir_version_marker or
                tag.otp_fully_static or
                tag.otp_runtime_wrapped,
            )
            if provider_prebuilt == archive_prebuilt:
                fail("prebuilt_toolchain '{}' must declare exactly one of otp+elixir provider targets or checksum-pinned archive fields".format(tag.name))
            if provider_prebuilt:
                if not tag.otp or not tag.elixir:
                    fail("prebuilt_toolchain '{}' provider form requires both otp and elixir".format(tag.name))
                if tag.crypto_sdk or tag.fips != "disabled" or tag.static_crypto_nif:
                    fail("prebuilt_toolchain '{}' provider targets own their OTP crypto/FIPS contract; remove crypto_sdk, fips, and static_crypto_nif from the tag".format(tag.name))
                otp_targets[tag.name] = str(tag.otp)
                elixir_targets[tag.name] = str(tag.elixir)
            else:
                if not all([tag.otp_url, tag.otp_sha256, tag.erlexec, tag.elixir_url, tag.elixir_sha256]):
                    fail("prebuilt_toolchain '{}' archive form requires OTP/Elixir URLs and SHA-256 values plus erlexec".format(tag.name))
                if tag.otp_fully_static == tag.otp_runtime_wrapped:
                    fail("prebuilt_toolchain '{}' archive form must declare exactly one of otp_fully_static=True or otp_runtime_wrapped=True".format(tag.name))
                if tag.otp_runtime_wrapped and not tag.crypto_sdk:
                    fail("prebuilt_toolchain '{}' otp_runtime_wrapped=True requires crypto_sdk".format(tag.name))
                _validate_sha256(tag.otp_sha256, "otp_sha256", tag.name)
                _validate_sha256(tag.elixir_sha256, "elixir_sha256", tag.name)
            types[tag.name] = INSTALLATION_TYPE_PREBUILT
            otp_versions[tag.name] = tag.otp_version
            elixir_versions[tag.name] = tag.elixir_version
            execution, target = _platform_constraints(tag)
            exec_constraints[tag.name] = execution
            target_constraints[tag.name] = target
            target_arches[tag.name] = _target_arch(target, tag.name)
            fips_modes[tag.name] = tag.fips
            static_crypto_nifs[tag.name] = str(tag.static_crypto_nif)
            fully_static_otps[tag.name] = str(tag.otp_fully_static)
            wrapped_otps[tag.name] = str(tag.otp_runtime_wrapped)
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

            if not provider_prebuilt:
                otp_repository = "rules_elixir_mix_otp_{}".format(tag.name)
                otp_version_marker = tag.otp_version_marker or "releases/{}/OTP_VERSION".format(tag.otp_version.split(".")[0])
                _fetch_runtime(
                    otp_repository,
                    tag.otp_url,
                    tag.otp_urls,
                    tag.otp_sha256,
                    tag.otp_strip_prefix,
                    tag.otp_type,
                    [tag.erlexec, otp_version_marker] + ([tag.otp_boot_file] if tag.otp_boot_file else []),
                )
                otp_runtime_files[tag.name] = _runtime_label(otp_repository, "runtime")
                erlexec_files[tag.name] = _runtime_label(otp_repository, tag.erlexec)
                otp_version_markers[tag.name] = _runtime_label(otp_repository, otp_version_marker)
                if tag.otp_boot_file:
                    otp_boot_files[tag.name] = _runtime_label(otp_repository, tag.otp_boot_file)

                elixir_repository = "rules_elixir_mix_elixir_{}".format(tag.name)
                elixir_home_marker = tag.elixir_home_marker or "bin/elixir"
                elixir_version_marker = tag.elixir_version_marker or "VERSION"
                _fetch_runtime(
                    elixir_repository,
                    tag.elixir_url,
                    tag.elixir_urls,
                    tag.elixir_sha256,
                    tag.elixir_strip_prefix,
                    tag.elixir_type,
                    [elixir_home_marker, elixir_version_marker],
                )
                elixir_runtime_files[tag.name] = _runtime_label(elixir_repository, "runtime")
                elixir_home_markers[tag.name] = _runtime_label(elixir_repository, elixir_home_marker)
                elixir_version_markers[tag.name] = _runtime_label(elixir_repository, elixir_version_marker)

        for tag in mod.tags.source_toolchain:
            _claim_name(mod, tag.name, owners)
            provider_bootstrap = bool(tag.bootstrap_otp)
            archive_bootstrap = bool(tag.bootstrap_otp_url or tag.bootstrap_otp_urls or tag.bootstrap_otp_sha256 or tag.bootstrap_otp_version or tag.bootstrap_erlexec)
            if provider_bootstrap == archive_bootstrap:
                fail("source_toolchain '{}' must declare exactly one of bootstrap_otp or the checksum-pinned bootstrap archive fields".format(tag.name))
            if provider_bootstrap:
                if any([tag.bootstrap_otp_url, tag.bootstrap_otp_urls, tag.bootstrap_otp_sha256, tag.bootstrap_otp_version, tag.bootstrap_otp_strip_prefix, tag.bootstrap_otp_type, tag.bootstrap_erlexec, tag.bootstrap_version_marker, tag.bootstrap_boot_file, tag.bootstrap_otp_fully_static]):
                    fail("source_toolchain '{}' provider-backed bootstrap_otp is mutually exclusive with bootstrap archive metadata".format(tag.name))
                bootstrap_otp_targets[tag.name] = str(tag.bootstrap_otp)
            else:
                if not all([tag.bootstrap_otp_url, tag.bootstrap_otp_sha256, tag.bootstrap_otp_version, tag.bootstrap_erlexec]):
                    fail("source_toolchain '{}' archive bootstrap requires bootstrap_otp_url, bootstrap_otp_sha256, bootstrap_otp_version, and bootstrap_erlexec".format(tag.name))
                if not tag.bootstrap_otp_fully_static:
                    fail("source_toolchain '{}' archive bootstrap must declare bootstrap_otp_fully_static=True; dynamic bootstraps require provider-backed OtpInfo".format(tag.name))
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
            if not provider_bootstrap:
                bootstrap_otp_versions[tag.name] = tag.bootstrap_otp_version
                bootstrap_fully_static_otps[tag.name] = str(tag.bootstrap_otp_fully_static)
            elixir_versions[tag.name] = tag.elixir_version
            execution, target = _platform_constraints(tag)
            if tag.libc == "musl" and any([constraint.endswith("//cpu:x86_64") for constraint in target]) and tag.jit != "disabled":
                fail("source_toolchain '{}' must set jit='disabled' for x86-64 musl; OTP's JIT signal stack is unsafe when AT_MINSIGSTKSZ exceeds musl SIGSTKSZ".format(tag.name))
            exec_constraints[tag.name] = execution
            target_constraints[tag.name] = target
            target_arches[tag.name] = _target_arch(target, tag.name)
            bootstrap_execution = sorted({str(label): True for label in tag.bootstrap_exec_compatible_with}.keys())
            if tag.cross_compile and not bootstrap_execution:
                fail("source_toolchain '{}' cross_compile=True requires bootstrap_exec_compatible_with".format(tag.name))
            bootstrap_exec_constraints[tag.name] = bootstrap_execution or execution
            fips_modes[tag.name] = tag.fips
            static_crypto_nifs[tag.name] = str(tag.static_crypto_nif)
            fully_static_otps[tag.name] = str(tag.otp_fully_static)
            cross_compiles[tag.name] = str(tag.cross_compile)
            jit_modes[tag.name] = tag.jit
            libcs[tag.name] = tag.libc
            defaults[tag.name] = tag.default

            if not provider_bootstrap:
                bootstrap_repository = "rules_elixir_mix_bootstrap_otp_{}".format(tag.name)
                bootstrap_version_marker = tag.bootstrap_version_marker or "releases/{}/OTP_VERSION".format(tag.bootstrap_otp_version.split(".")[0])
                _fetch_runtime(
                    bootstrap_repository,
                    tag.bootstrap_otp_url,
                    tag.bootstrap_otp_urls,
                    tag.bootstrap_otp_sha256,
                    tag.bootstrap_otp_strip_prefix,
                    tag.bootstrap_otp_type,
                    [tag.bootstrap_erlexec, bootstrap_version_marker] + ([tag.bootstrap_boot_file] if tag.bootstrap_boot_file else []),
                )
                bootstrap_runtime_files[tag.name] = _runtime_label(bootstrap_repository, "runtime")
                bootstrap_erlexec_files[tag.name] = _runtime_label(bootstrap_repository, tag.bootstrap_erlexec)
                bootstrap_version_markers[tag.name] = _runtime_label(bootstrap_repository, bootstrap_version_marker)
                if tag.bootstrap_boot_file:
                    bootstrap_boot_files[tag.name] = _runtime_label(bootstrap_repository, tag.bootstrap_boot_file)

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
        bootstrap_otp_targets = bootstrap_otp_targets,
        bootstrap_runtime_files = bootstrap_runtime_files,
        bootstrap_erlexec_files = bootstrap_erlexec_files,
        bootstrap_boot_files = bootstrap_boot_files,
        bootstrap_version_markers = bootstrap_version_markers,
        bootstrap_fully_static_otps = bootstrap_fully_static_otps,
        bootstrap_exec_compatible_withs = bootstrap_exec_constraints,
        otp_source_files = otp_source_files,
        otp_source_directory_manifests = otp_source_directory_manifests,
        otp_runtime_files = otp_runtime_files,
        otp_targets = otp_targets,
        wrapped_otps = wrapped_otps,
        erlexec_files = erlexec_files,
        otp_boot_files = otp_boot_files,
        otp_version_markers = otp_version_markers,
        elixir_versions = elixir_versions,
        elixir_runtime_files = elixir_runtime_files,
        elixir_targets = elixir_targets,
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
        fully_static_otps = fully_static_otps,
        cross_compiles = cross_compiles,
        jit_modes = jit_modes,
        libcs = libcs,
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
        target_arches = target_arches,
    )
    root_nondev = module_ctx.root_module_has_non_dev_dependency
    return module_ctx.extension_metadata(
        root_module_direct_deps = ["elixir_config"] if root_nondev else [],
        root_module_direct_dev_deps = [] if root_nondev else ["elixir_config"],
        reproducible = True,
    )

prebuilt_toolchain = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "otp": attr.label(),
    "otp_version": attr.string(mandatory = True),
    "otp_url": attr.string(),
    "otp_urls": attr.string_list(),
    "otp_sha256": attr.string(),
    "otp_strip_prefix": attr.string(),
    "otp_type": attr.string(),
    "erlexec": attr.string(),
    "otp_fully_static": attr.bool(default = False),
    "otp_runtime_wrapped": attr.bool(default = False),
    "otp_boot_file": attr.string(),
    "otp_version_marker": attr.string(),
    "elixir": attr.label(),
    "elixir_version": attr.string(mandatory = True),
    "elixir_url": attr.string(),
    "elixir_urls": attr.string_list(),
    "elixir_sha256": attr.string(),
    "elixir_strip_prefix": attr.string(),
    "elixir_type": attr.string(),
    "elixir_home_marker": attr.string(),
    "elixir_version_marker": attr.string(),
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
    "bootstrap_otp": attr.label(),
    "bootstrap_otp_version": attr.string(),
    "bootstrap_otp_url": attr.string(),
    "bootstrap_otp_urls": attr.string_list(),
    "bootstrap_otp_sha256": attr.string(),
    "bootstrap_otp_strip_prefix": attr.string(),
    "bootstrap_otp_type": attr.string(),
    "bootstrap_erlexec": attr.string(),
    "bootstrap_boot_file": attr.string(),
    "bootstrap_version_marker": attr.string(),
    "bootstrap_otp_fully_static": attr.bool(default = False),
    "bootstrap_exec_compatible_with": attr.label_list(),
    "otp_version": attr.string(default = DEFAULT_OTP_VERSION),
    "otp_url": attr.string(),
    "otp_urls": attr.string_list(),
    "otp_sha256": attr.string(),
    "otp_strip_prefix": attr.string(),
    "otp_type": attr.string(),
    "otp_fully_static": attr.bool(default = False),
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
    "libc": attr.string(mandatory = True, values = ["glibc", "musl"]),
    "elixir_jobs": attr.int(default = 8),
    "elixir_make_options": attr.string_list(),
    "exec_compatible_with": attr.label_list(),
    "target_compatible_with": attr.label_list(),
    "runtime_abi": attr.label(mandatory = True),
    "fips": attr.string(default = "disabled", values = ["disabled", "required"]),
    "static_crypto_nif": attr.bool(default = False),
    "cross_compile": attr.bool(default = False),
    "jit": attr.string(default = "auto", values = ["auto", "disabled", "required"]),
    "default": attr.bool(default = False),
})

elixir_config = module_extension(
    implementation = _toolchains_impl,
    tag_classes = {
        "prebuilt_toolchain": prebuilt_toolchain,
        "source_toolchain": source_toolchain,
    },
)
