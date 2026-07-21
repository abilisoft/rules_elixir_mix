"""Repository-phase validation for extracted, checksum-pinned trees."""

def validate_extracted_tree(repository_ctx):
    """Reject symlinks whose resolved target is outside the repository.

    Args:
      repository_ctx: Active repository-rule context after extraction.
    """
    root = repository_ctx.path(".")
    root_path = str(root)
    pending = [root]
    for _depth in range(256):
        if not pending:
            return
        next_pending = []
        for directory in pending:
            for entry in directory.readdir(watch = "no"):
                entry_path = str(entry)
                if not entry.exists:
                    fail("extracted archive contains a dangling symlink: {}".format(
                        entry_path.removeprefix(root_path + "/"),
                    ))
                resolved = str(entry.realpath)
                if resolved != entry_path:
                    if resolved != root_path and not resolved.startswith(root_path + "/"):
                        fail("extracted archive symlink escapes its checksum-pinned repository: {} -> {}".format(
                            entry_path.removeprefix(root_path + "/"),
                            resolved,
                        ))
                elif entry.is_dir:
                    next_pending.append(entry)
        pending = next_pending
    fail("extracted archive directory nesting exceeds 256 levels")
