defmodule FerriWeb.Changelog do
  @moduledoc """
  Compile-time loader for the per-release notes under `.changelogs/`.

  Each version directory (`0.1.5` or `v0.1.5`) holds a `summary.md` whose
  first non-empty line is treated as a human-readable date and whose
  remaining `- `-prefixed lines become bullet points. Non-version entries
  (e.g. `unreleased`, `preamble.md`) are ignored.

  The walk happens at compile time and every `.md` file under
  `.changelogs/` is registered as an `@external_resource`, so editing a
  summary in dev triggers recompilation. The parsed list is baked into the
  BEAM and exposed via `entries/0`.
  """

  defmodule Parser do
    @moduledoc false
    # Pulled into a nested module so the @entries computation in
    # FerriWeb.Changelog can call these helpers — defp on the parent
    # wouldn't be callable from a module attribute on the same module.

    @doc """
    Strips an optional leading `"v"` from a version directory name. Returns
    the bare semver string.

        iex> Parser.normalize_dir("v0.1.5")
        "0.1.5"
        iex> Parser.normalize_dir("0.1.5")
        "0.1.5"
    """
    @spec normalize_dir(String.t()) :: String.t()
    def normalize_dir(dir), do: String.replace_prefix(dir, "v", "")

    @doc """
    Parses a directory name into a list of integer components, suitable as
    a sort key for ordering versions newest-first.

        iex> Parser.parse_version("v0.1.5")
        [0, 1, 5]
    """
    @spec parse_version(String.t()) :: [non_neg_integer()]
    def parse_version(dir) do
      dir
      |> normalize_dir()
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)
    end

    @doc """
    Parses a `summary.md` body into a `t:FerriWeb.Changelog.entry/0`. The
    first non-empty line becomes `:date`; subsequent lines, after stripping
    a leading `"- "`, become bullets.
    """
    @spec parse_summary(String.t(), String.t()) :: FerriWeb.Changelog.entry()
    def parse_summary(version, content) do
      lines =
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {date, rest} =
        case lines do
          [first | rest] -> {first, rest}
          [] -> {"", []}
        end

      bullets =
        rest
        |> Enum.map(&String.trim_leading(&1, "- "))
        |> Enum.reject(&(&1 == ""))

      %{version: version, date: date, bullets: bullets}
    end
  end

  @typedoc """
  Parsed changelog entry for one released version.

  * `:version` — bare semver, e.g. `"0.1.5"` (no leading `v`)
  * `:date` — human-readable date string from `summary.md`
  * `:bullets` — release-note bullet points, in source order
  """
  @type entry :: %{
          version: String.t(),
          date: String.t(),
          bullets: [String.t()]
        }

  @changelog_dir Path.join(File.cwd!(), ".changelogs")

  # Trigger recompile when any changelog markdown file changes.
  for path <- Path.wildcard(Path.join(@changelog_dir, "**/*.md")) do
    @external_resource path
  end

  @entries (if File.dir?(@changelog_dir) do
              @changelog_dir
              |> File.ls!()
              # Match `0.1.5` and `v0.1.5`; reject `unreleased`, `preamble.md`, etc.
              |> Enum.filter(&Regex.match?(~r/^v?\d+\.\d+\.\d+$/, &1))
              |> Enum.sort_by(&Parser.parse_version/1, :desc)
              |> Enum.flat_map(fn dir ->
                summary_path = Path.join([@changelog_dir, dir, "summary.md"])

                case File.read(summary_path) do
                  {:ok, content} ->
                    [Parser.parse_summary(Parser.normalize_dir(dir), content)]

                  {:error, _} ->
                    []
                end
              end)
            else
              []
            end)

  @doc """
  Returns the list of parsed changelog entries, sorted newest-first.

  The list is computed at compile time, so this call is `O(1)` and
  performs no IO at runtime. To refresh in development, save any file
  under `.changelogs/` — that triggers a Mix recompile via the
  `@external_resource` registrations in this module.
  """
  @spec entries :: [entry()]
  def entries, do: @entries
end
