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

  Four live blocks compose the pinned status region (top-to-bottom):
    :separator  — horizontal rule between log output and the status UI
    :progress   — label + progress bar + counter
    :spinner    — animated braille frame + rotating sci-fi phrase
    :recent     — last-N rolling list of completed items

  Non-matching stdin lines route through IO.puts. Owl is the group leader
  for this process, so those puts land above the pinned blocks.

  The spinner animates on its own timer via a linked background process
  that calls Owl.LiveScreen.update(:spinner, ...) every 100ms. When the
  main process exits, the link tears the ticker down with it.
  """

  @separator_block :separator
  @progress_block :progress
  @spinner_block :spinner
  @recent_block :recent

  # Braille spinner frames (same set as lib/tui.sh tui:with-spinner).
  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  # Rotate phrases every N ticks. At 100ms/tick, 25 ticks = 2.5s per phrase.
  @frames_per_phrase 25
  @tick_ms 100

  # Same sci-fi phrase set as lib/tui.sh. Shuffled per run so each invocation
  # gets a different order.
  @phrases [
    "Reversing the polarity of the context window",
    "Recalibrating the embedding matrix flux",
    "Initializing quantum token shuffler",
    "Stabilizing token interference",
    "Aligning latent vector manifold",
    "Charging semantic field resonator",
    "Inverting prompt entropy",
    "Redirecting gradient descent pathways",
    "Synchronizing the decoder attention",
    "Calibrating neural activation dampener",
    "Polarizing self-attention mechanism",
    "Recharging photonic energy in the deep learning nodes",
    "Fluctuating the vector space harmonics",
    "Boosting the backpropagation neutrino field",
    "Cross-referencing the hallucination core",
    "Reticulating splines"
  ]

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

  def render_separator({width}) do
    # A horizontal rule that's visually linked to the progress bar width.
    # width is the number of cells inside [brackets]; add 2 for the brackets
    # themselves so the rule is flush with the bar.
    String.duplicate("─", width + 2)
  end

  def render_spinner({tick, phrases}) do
    frame = Enum.at(@frames, rem(tick, length(@frames)))

    phrase =
      case phrases do
        [] -> ""
        _ -> Enum.at(phrases, rem(div(tick, @frames_per_phrase), length(phrases)))
      end

    "#{frame} #{phrase}"
  end

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

  # Background ticker loop. Bumps the spinner state every @tick_ms ms,
  # which triggers Owl to re-render the :spinner block. The loop never
  # terminates on its own — it gets killed by a linked exit from the
  # main process when run/1 returns.
  defp spinner_tick(tick, phrases) do
    Owl.LiveScreen.update(@spinner_block, {tick, phrases})
    Process.sleep(@tick_ms)
    spinner_tick(tick + 1, phrases)
  end

  #---------------------------------------------------------------------------
  # Main
  #---------------------------------------------------------------------------

  def run(opts) do
    # Capture the real stdin (original group leader) BEFORE rewiring the
    # group leader to Owl. The group leader handles both reads and writes,
    # so if we just point it at Owl, IO.stream(:stdio, ...) asks Owl for
    # input — which it can't serve (:enotsup). By reading from the saved
    # original GL explicitly, stdin still works while all output flows
    # through Owl's cursor-aware coordination.
    stdin_device = Process.group_leader()

    # Route output through LiveScreen so log lines (IO.puts / Logger)
    # interleave with the live region correctly. Without this, bare IO.puts
    # writes bypass Owl's cursor bookkeeping — blocks get redrawn at stale
    # offsets and labels leak into scrollback on every update.
    case Process.whereis(Owl.LiveScreen) do
      nil -> :ok
      pid -> Process.group_leader(self(), pid)
    end

    # Blocks render top-to-bottom in the order they're added. The separator
    # sits between scrolling log output above and the pinned status UI below.
    Owl.LiveScreen.add_block(@separator_block,
      state: {opts.width},
      render: &render_separator/1
    )

    phrases = Enum.shuffle(@phrases)

    Owl.LiveScreen.add_block(@spinner_block,
      state: {0, phrases},
      render: &render_spinner/1
    )

    Owl.LiveScreen.add_block(@progress_block,
      state: {0, opts.total, opts.width, opts.label},
      render: &render_progress/1
    )

    Owl.LiveScreen.add_block(@recent_block,
      state: [],
      render: &render_recent/1
    )

    # Animate the spinner on a background ticker. spawn_link ties its
    # lifetime to this process — when run/1 returns and the main flow
    # exits, the ticker gets an exit signal and dies.
    spawn_link(fn -> spinner_tick(0, phrases) end)

    # Read stdin line by line from the saved original GL. IO.stream returns
    # :eof when the writer closes, which terminates the stream.
    final_state =
      IO.stream(stdin_device, :line)
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

# Force-enable ANSI output. When stdin is a pipe (which is our entire use
# case), IO.ANSI.enabled? falls back to checking the :standard_io group
# leader, which inherits tty status from stdin and returns false. Owl's
# LiveScreen checks that flag and degrades to a non-interactive "just
# print updates as they come" mode, defeating the whole point. Setting
# the :elixir, :ansi_enabled app env to true makes IO.ANSI.enabled? skip
# the group-leader check and trust us.
Application.put_env(:elixir, :ansi_enabled, true)

Mix.install([{:owl, "~> 0.12"}])

# Owl starts LiveScreen as part of its application supervision tree; calling
# ensure_all_started here guarantees it's up before we add blocks.
{:ok, _} = Application.ensure_all_started(:owl)

Working.run(opts)
