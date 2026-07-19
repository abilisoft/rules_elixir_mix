# SPDX-FileCopyrightText: 2026 AbiliSoft
# SPDX-License-Identifier: Apache-2.0

defmodule RulesElixirMix.SourceCatalog do
  @moduledoc false

  @languages %{
    "elixir" => %{
      default: "DEFAULT_ELIXIR_VERSION",
      latest_release: "https://api.github.com/repos/elixir-lang/elixir/releases/latest",
      repository: "elixir-lang/elixir",
      tag_pattern: ~r/\Av(\d+\.\d+(?:\.\d+)*)\z/
    },
    "otp" => %{
      default: "DEFAULT_OTP_VERSION",
      latest_release: "https://api.github.com/repos/erlang/otp/releases/latest",
      repository: "erlang/otp",
      tag_pattern: ~r/\AOTP-(\d+\.\d+(?:\.\d+)*)\z/
    }
  }

  @language_order ["otp", "elixir"]

  def refresh(path, token \\ nil) do
    contents = File.read!(path)

    {updated, releases} =
      Enum.reduce(@language_order, {contents, []}, fn language, {catalog, releases} ->
        release = latest_release(language, token)

        cond do
          current_default(catalog, language) == release.version and
              catalog_contains?(catalog, language, release.version) ->
            {catalog, releases}

          catalog_contains?(catalog, language, release.version) ->
            {update_catalog(catalog, [release]), [release | releases]}

          true ->
            sha256 = release.url |> request(nil) |> sha256()
            release = Map.put(release, :sha256, sha256)
            {update_catalog(catalog, [release]), [release | releases]}
        end
      end)

    if updated != contents do
      File.write!(path, updated)
    end

    Enum.reverse(releases)
  end

  def update_catalog(contents, releases) do
    Enum.reduce(releases, contents, fn release, catalog ->
      language = release.language
      config = language!(language)
      catalog = replace_default(catalog, config.default, release.version)

      if catalog_contains?(catalog, language, release.version) do
        catalog
      else
        insert_release(catalog, release)
      end
    end)
  end

  def release_from_tag(language, tag, sha256 \\ "") do
    config = language!(language)

    version =
      case Regex.run(config.tag_pattern, tag, capture: :all_but_first) do
        [version] -> version
        _ -> raise ArgumentError, "unexpected stable #{language} release tag #{inspect(tag)}"
      end

    strip_prefix =
      case language do
        "otp" -> "otp-#{tag}"
        "elixir" -> "elixir-#{version}"
      end

    %{
      archive_type: "tar.gz",
      language: language,
      sha256: sha256,
      strip_prefix: strip_prefix,
      tag: tag,
      url: "https://github.com/#{config.repository}/archive/refs/tags/#{tag}.tar.gz",
      version: version
    }
  end

  def current_default(contents, language) do
    config = language!(language)
    pattern = ~r/^#{config.default} = "([^"]+)"$/m

    case Regex.scan(pattern, contents, capture: :all_but_first) do
      [[version]] ->
        version

      matches ->
        raise ArgumentError, "expected one #{config.default} assignment, found #{length(matches)}"
    end
  end

  def catalog_contains?(contents, language, version) do
    contents
    |> language_section(language)
    |> String.contains?("        \"#{version}\": struct(\n")
  end

  defp latest_release(language, token) do
    config = language!(language)
    response = config.latest_release |> request(token) |> JSON.decode!()

    case response do
      %{"draft" => false, "prerelease" => false, "tag_name" => tag} when is_binary(tag) ->
        release_from_tag(language, tag)

      _ ->
        raise "GitHub returned an invalid latest stable #{language} release"
    end
  end

  defp insert_release(contents, release) do
    validate_sha256!(release)

    marker = "    \"#{release.language}\": {\n"
    replacement = marker <> render_release(release)
    replace_once(contents, marker, replacement)
  end

  defp render_release(release) do
    """
            "#{release.version}": struct(
                archive_type = "#{release.archive_type}",
                sha256 = "#{release.sha256}",
                strip_prefix = "#{release.strip_prefix}",
                url = "#{release.url}",
            ),
    """
  end

  defp replace_default(contents, name, version) do
    pattern = ~r/^#{name} = "[^"]+"$/m

    case Regex.scan(pattern, contents) do
      [_] -> Regex.replace(pattern, contents, "#{name} = \"#{version}\"")
      matches -> raise ArgumentError, "expected one #{name} assignment, found #{length(matches)}"
    end
  end

  defp validate_sha256!(release) do
    unless String.match?(release.sha256, ~r/\A[0-9a-f]{64}\z/) do
      raise ArgumentError,
            "new #{release.language} release #{release.version} requires a lowercase SHA-256"
    end
  end

  defp language_section(contents, language) do
    marker = "    \"#{language}\": {\n"

    with [_, rest] <- String.split(contents, marker, parts: 2),
         [section, _] <- String.split(rest, "    },\n", parts: 2) do
      section
    else
      _ -> raise ArgumentError, "could not locate #{language} source catalog section"
    end
  end

  defp replace_once(contents, search, replacement) do
    case :binary.matches(contents, search) do
      [_] ->
        String.replace(contents, search, replacement, global: false)

      matches ->
        raise ArgumentError, "expected one catalog insertion point, found #{length(matches)}"
    end
  end

  defp request(url, token) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    headers =
      [
        {~c"accept", ~c"application/vnd.github+json"},
        {~c"user-agent", ~c"rules-elixir-mix-source-catalog"},
        {~c"x-github-api-version", ~c"2022-11-28"}
      ] ++ authorization_header(token)

    options = [
      autoredirect: true,
      ssl: [
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        verify: :verify_peer
      ]
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, options, body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} when status in 200..299 ->
        body

      {:ok, {{_, status, _}, _, body}} ->
        raise "request to #{url} failed with HTTP #{status}: #{String.slice(body, 0, 200)}"

      {:error, reason} ->
        raise "request to #{url} failed: #{inspect(reason)}"
    end
  end

  defp authorization_header(token) when token in [nil, ""], do: []

  defp authorization_header(token) do
    [{~c"authorization", String.to_charlist("Bearer #{token}")}]
  end

  defp sha256(contents) do
    contents
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp language!(language) do
    Map.fetch!(@languages, language)
  rescue
    KeyError -> raise ArgumentError, "unknown source language #{inspect(language)}"
  end
end
