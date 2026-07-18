"""Pure-Starlark parser for the Hex entries in an Elixir mix.lock file."""

_WORD_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.!?@/"

def _token(kind, value = None):
    return struct(kind = kind, value = value)

def _word_end(text, start):
    end = start
    for index in range(start, len(text)):
        if text[index] not in _WORD_CHARS:
            break
        end = index + 1
    return end

def _quoted(text, start):
    chars = []
    escaped = False
    for index in range(start + 1, len(text)):
        char = text[index]
        if escaped:
            chars.append({"n": "\n", "r": "\r", "t": "\t"}.get(char, char))
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == '"':
            return ("".join(chars), index + 1)
        else:
            chars.append(char)
    fail("unterminated string in mix.lock")

def _line_end(text, start):
    for index in range(start, len(text)):
        if text[index] == "\n":
            return index + 1
    return len(text)

def _tokenize(text):
    tokens = []
    index = 0
    for _ in range(len(text) + 1):
        if index >= len(text):
            break
        char = text[index]
        if char in " \t\r\n":
            index += 1
        elif char == "#":
            index = _line_end(text, index)
        elif text[index:index + 2] == "%{":
            tokens.append(_token("map_open"))
            index += 2
        elif text[index:index + 2] == "=>":
            tokens.append(_token("arrow"))
            index += 2
        elif char in "{}[],":
            tokens.append(_token(char))
            index += 1
        elif char == '"':
            value, index = _quoted(text, index)
            tokens.append(_token("string", value))
        elif char == ":":
            end = _word_end(text, index + 1)
            if end == index + 1:
                # Elixir permits quoted keyword keys in maps, for example
                # %{"plug": {:hex, ...}}. The quoted string is already the
                # map key; its trailing colon has the same role as =>.
                tokens.append(_token("arrow"))
                index += 1
            else:
                tokens.append(_token("atom", text[index + 1:end]))
                index = end
        elif char in _WORD_CHARS:
            end = _word_end(text, index)
            value = text[index:end]
            if end < len(text) and text[end] == ":":
                tokens.append(_token("keyword", value))
                index = end + 1
            else:
                tokens.append(_token("identifier", value))
                index = end
        else:
            fail("unsupported character '{}' at byte {} in mix.lock".format(char, index))
    return tokens

def _map_key(value):
    if type(value) == "string":
        return value
    if type(value) == "struct" and hasattr(value, "kind") and value.kind == "atom":
        return value.value
    fail("unsupported map key in mix.lock")

def _accept_value(state, value):
    if not state["stack"]:
        if state["has_root"]:
            fail("mix.lock contains more than one root value")
        state["root"] = value
        state["has_root"] = True
        return

    container = state["stack"][-1]
    if container["kind"] == "map":
        if container["key"] == None:
            container["key"] = _map_key(value)
        elif not container["after_arrow"]:
            fail("expected => after map key '{}' in mix.lock".format(container["key"]))
        else:
            container["values"][container["key"]] = value
            container["key"] = None
            container["after_arrow"] = False
        return

    keyword = container["keyword"]
    if keyword == None:
        container["values"].append(value)
    else:
        container["values"].append(struct(kind = "keyword", key = keyword, value = value))
        container["keyword"] = None

def _open_container(state, kind):
    if kind == "map":
        state["stack"].append({
            "after_arrow": False,
            "key": None,
            "kind": kind,
            "values": {},
        })
    else:
        state["stack"].append({
            "keyword": None,
            "kind": kind,
            "values": [],
        })

def _close_container(state, token_kind):
    if not state["stack"]:
        fail("unexpected {} in mix.lock".format(token_kind))
    container = state["stack"].pop()
    expected = "]" if container["kind"] == "list" else "}"
    if token_kind != expected:
        fail("expected {}, got {} while parsing mix.lock".format(expected, token_kind))
    if container["kind"] == "map":
        if container["key"] != None:
            fail("map key '{}' has no value in mix.lock".format(container["key"]))
        value = container["values"]
    else:
        if container["keyword"] != None:
            fail("keyword '{}' has no value in mix.lock".format(container["keyword"]))
        value = struct(kind = "tuple", values = container["values"]) if container["kind"] == "tuple" else container["values"]
    _accept_value(state, value)

def _parse_tokens(tokens):
    state = {
        "has_root": False,
        "root": None,
        "stack": [],
    }
    for token in tokens:
        if token.kind == "map_open":
            _open_container(state, "map")
        elif token.kind == "{":
            _open_container(state, "tuple")
        elif token.kind == "[":
            _open_container(state, "list")
        elif token.kind in ["}", "]"]:
            _close_container(state, token.kind)
        elif token.kind == "arrow":
            if not state["stack"] or state["stack"][-1]["kind"] != "map":
                fail("unexpected => in mix.lock")
            container = state["stack"][-1]
            if container["key"] == None or container["after_arrow"]:
                fail("unexpected => in mix.lock map")
            container["after_arrow"] = True
        elif token.kind == "keyword":
            if not state["stack"] or state["stack"][-1]["kind"] == "map":
                fail("unexpected keyword '{}' in mix.lock".format(token.value))
            container = state["stack"][-1]
            if container["keyword"] != None:
                fail("keyword '{}' has no value in mix.lock".format(container["keyword"]))
            container["keyword"] = token.value
        elif token.kind == ",":
            continue
        elif token.kind == "string":
            _accept_value(state, token.value)
        elif token.kind == "atom":
            _accept_value(state, struct(kind = "atom", value = token.value))
        elif token.kind == "identifier":
            value = {
                "false": False,
                "nil": None,
                "true": True,
            }.get(token.value, token.value)
            _accept_value(state, value)
        else:
            fail("unexpected token {} in mix.lock".format(token.kind))

    if state["stack"]:
        fail("unterminated {} in mix.lock".format(state["stack"][-1]["kind"]))
    if not state["has_root"]:
        fail("mix.lock is empty")
    return state["root"]

def _atom(value, context):
    if type(value) != "struct" or not hasattr(value, "kind") or value.kind != "atom":
        fail("expected atom for {} in mix.lock".format(context))
    return value.value

def _keyword(options, name, default = None):
    for option in options:
        if type(option) == "struct" and hasattr(option, "kind") and option.kind == "keyword" and option.key == name:
            return option.value
    return default

def _hex_dep(value):
    if type(value) != "struct" or value.kind != "tuple" or len(value.values) < 3:
        fail("invalid Hex dependency tuple in mix.lock")
    options = value.values[2]
    package = _keyword(options, "hex")
    return struct(
        optional = _keyword(options, "optional", False),
        package = _atom(package, "dependency package") if package != None else _atom(value.values[0], "dependency"),
        runtime = _keyword(options, "runtime", True),
    )

def _manager(managers, package):
    if "mix" in managers:
        return "mix"
    if "rebar3" in managers:
        return "rebar3"
    fail("Hex package '{}' uses unsupported build managers {}".format(package, managers))

def parse_mix_lock(content):
    """Return checksum-pinned Hex package structs from mix.lock content.

    Args:
      content: Complete text of a checked-in Mix lockfile.

    Returns:
      Parsed Hex package structs in deterministic lock-entry order.
    """
    entries = _parse_tokens(_tokenize(content))
    if type(entries) != "dict":
        fail("mix.lock must contain a map")

    packages = []
    for lock_name in sorted(entries.keys()):
        value = entries[lock_name]
        if type(value) != "struct" or value.kind != "tuple" or not value.values:
            fail("lock entry '{}' has an unsupported shape".format(lock_name))
        source_type = _atom(value.values[0], "source type")
        if source_type != "hex":
            fail("lock entry '{}' uses unsupported source type '{}'; import non-Hex sources explicitly as Bazel repositories".format(lock_name, source_type))
        if len(value.values) < 8:
            fail("Hex lock entry '{}' has an unsupported shape".format(lock_name))
        compile_deps = []
        runtime_deps = []
        for dep in value.values[5]:
            parsed = _hex_dep(dep)

            # Optional edges are retained when the optional package is present
            # in this lock graph; the extension filters missing packages.
            destination = runtime_deps if parsed.runtime else compile_deps
            if parsed.package not in destination:
                destination.append(parsed.package)
        package = _atom(value.values[1], "package")
        managers = [_atom(manager, "build manager") for manager in value.values[4]]
        repository = value.values[6]
        if type(repository) != "string" or not repository:
            fail("Hex lock entry '{}' has an invalid repository".format(lock_name))
        packages.append(struct(
            app_name = lock_name,
            package = package,
            version = value.values[2],
            sha256 = value.values[7],
            compile_deps = compile_deps,
            runtime_deps = runtime_deps,
            manager = _manager(managers, package),
            repository = repository,
        ))
    return packages
