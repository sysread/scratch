#!/usr/bin/env elixir

#-------------------------------------------------------------------------------
# Progress helper
#
# Reads JSONL-or-plain-text lines from stdin. Lines matching --match advance
# a progress bar and feed a rolling "recent" list. Non-matching lines print
# as log output that scrolls above the live region.
#
# Uses Owl.LiveScreen, which pins the progress/list blocks to the bottom of
# the terminal and lets regular IO.puts scroll above them naturally. This
# gives us the classic "long-running job with status at the bottom and a
# streaming log above" UX without any manual cursor math.
#
# Examples:
#
#   # Simple: 10 things to do, each "done" line on stdin counts one
#   seq 1 10 | sed 's/^/done /' | working.exs --total 10 --match '^done'
#
#   # Extract a capture group for the recent list:
#   ... | working.exs --total 50 --match '^ok '        \
#                     --extract '^ok (\S+)'             \
#                     --label 'Indexing files'
#
# Flags:
#   --total N        Denominator for the progress bar (required)
#   --match REGEX    Lines matching this regex count as completions (required)
#   --extract REGEX  Optional: take capture group 1 from matched line for the
#                    recent list. Defaults to the full matched line.
#   --recent N       How many recent completions to display (default 3)
#   --label TEXT     Title shown above the progress bar (default "Working")
#   --width N        Progress bar width in cells (default 30)
#
# Exit: when stdin closes, the live region is cleared and the final state
# is printed once as a summary line above where the blocks used to be.
#-------------------------------------------------------------------------------

defmodule Working do
  @moduledoc """
  Progress display wrapping Owl.LiveScreen.

  Two live blocks (:progress, :recent) are updated as matching lines arrive.
  Non-matching lines route through IO.puts which Owl redirects to appear
  above the live region.
  """

  @progress_block :progress
  @recent_block :recent

  @usage """
  Usage: working.exs --total N --match REGEX [options]

  Progress helper — reads stdin, matched lines advance the progress bar
  and feed a rolling "recent" list, non-matched lines scroll above the
  live region as log output.

  Required:
    --total N         Denominator for the progress bar
    --match REGEX     Lines matching this regex count as completions

  Optional:
    --extract REGEX   Capture group 1 of matched line shown in the list
                      (default: full matched line)
    --recent N        How many recent completions to display (default 3)
    --label TEXT      Title above the progress bar (default "Working")
    --width N         Progress bar width in cells (default 30)
    -h, --help        Show this help

  Example:
    seq 1 10 | sed 's/^/done /' | working.exs --total 10 --match '^done'
  """

  def parse_args(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          total: :integer,
          match: :string,
          extract: :string,
          recent: :integer,
          label: :string,
          width: :integer,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    if opts[:help] do
      IO.puts(@usage)
      System.halt(0)
    end

    unless invalid == [] do
      die("unrecognized option(s): #{inspect(invalid)}\n\n#{@usage}")
    end

    total = opts[:total] || die("--total is required\n\n#{@usage}")
    match = opts[:match] || die("--match is required\n\n#{@usage}")

    %{
      total: total,
      match: safe_compile!(match, "--match"),
      extract: opts[:extract] && safe_compile!(opts[:extract], "--extract"),
      recent_max: opts[:recent] || 3,
      label: opts[:label] || "Working",
      width: opts[:width] || 30
    }
  end

  defp safe_compile!(pattern, flag) do
    case Regex.compile(pattern) do
      {:ok, re} -> re
      {:error, {reason, pos}} -> die("#{flag}: invalid regex at #{pos}: #{reason}")
    end
  end

  defp die(msg) do
    IO.puts(:stderr, "working: #{msg}")
    System.halt(2)
  end

  #---------------------------------------------------------------------------
  # Rendering
  #---------------------------------------------------------------------------

  def render_progress({done, total, width, label}) do
    pct =
      if total > 0 do
        min(100, trunc(done * 100 / total))
      else
        0
      end

    filled = min(width, trunc(done * width / max(total, 1)))

    # Show a leading arrow while incomplete so the bar reads "=====>    ".
    # Complete bar has no arrow.
    {bar, tail_pad} =
      cond do
        done >= total -> {String.duplicate("=", width), 0}
        filled == 0 -> {"", width}
        true -> {String.duplicate("=", filled - 1) <> ">", width - filled}
      end

    padded = bar <> String.duplicate(" ", tail_pad)
    counter = "[#{done}/#{total} - #{pct}%]"

    "#{label}\n[#{padded}]#{counter}"
  end

  def render_recent(recent) do
    # Owl treats an empty string as "remove the block". Render a single
    # blank line instead so the block area stays reserved (avoids the
    # progress bar jumping up when the first item lands).
    case recent do
      [] -> " "
      items -> items |> Enum.map(&"  - #{&1}") |> Enum.join("\n")
    end
  end

  #---------------------------------------------------------------------------
  # Line handling
  #---------------------------------------------------------------------------

  def extract_item(line, nil), do: line

  def extract_item(line, regex) do
    case Regex.run(regex, line) do
      [_, captured | _] -> captured
      # No capture group matched; fall back to the full line
      _ -> line
    end
  end

  def process_line(line, {done, recent, opts}) do
    if Regex.match?(opts.match, line) do
      item = extract_item(line, opts.extract)
      new_done = done + 1
      # Newest first; keep only the last N
      new_recent = [item | recent] |> Enum.take(opts.recent_max)

      Owl.LiveScreen.update(
        @progress_block,
        {new_done, opts.total, opts.width, opts.label}
      )

      Owl.LiveScreen.update(@recent_block, new_recent)

      {new_done, new_recent, opts}
    else
      # Non-matching line scrolls above the live region.
      # IO.puts routes through Owl which handles the clear/reprint dance.
      IO.puts(line)
      {done, recent, opts}
    end
  end

  #---------------------------------------------------------------------------
  # Main
  #---------------------------------------------------------------------------

  def run(opts) do
    Owl.LiveScreen.add_block(@progress_block,
      state: {0, opts.total, opts.width, opts.label},
      render: &render_progress/1
    )

    Owl.LiveScreen.add_block(@recent_block,
      state: [],
      render: &render_recent/1
    )

    # Read stdin line by line. IO.stream returns :eof when the writer
    # closes, which terminates the stream.
    final_state =
      IO.stream(:stdio, :line)
      |> Stream.map(&String.trim_trailing/1)
      |> Enum.reduce({0, [], opts}, &process_line/2)

    # Flush pending renders, then detach the live region so the final
    # summary prints cleanly at the end.
    Owl.LiveScreen.await_render()

    {done, _recent, _opts} = final_state
    IO.puts(:stderr, "done: #{done}/#{opts.total}")
  end
end

# Parse args BEFORE Mix.install so `--help` and arg validation don't pay
# the dependency-resolution startup cost. Mix.install warm-starts in ~1s on
# a cached install, but cold starts pull Owl from hex; no reason to incur
# that when the user just wants to read -h.
opts = Working.parse_args(System.argv())

Mix.install([{:owl, "~> 0.12"}])

# Owl starts LiveScreen as part of its application supervision tree; calling
# ensure_all_started here guarantees it's up before we add blocks.
{:ok, _} = Application.ensure_all_started(:owl)

Working.run(opts)
