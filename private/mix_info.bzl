"""Providers for Mix project metadata and compilation context."""

MixProjectInfo = provider(
    doc = "Metadata and declared project inputs for a compiled Mix application.",
    fields = {
        "lockfile": "The declared Mix lock file, or None.",
        "mix_config": "The mix.exs file defining this Mix project.",
        "mix_env": "The MIX_ENV used to compile this project.",
        "project_entries": "Stable logical mappings for every staged project file.",
        "project_files": "Depset of files needed to evaluate the Mix project outside its compile action.",
    },
)
